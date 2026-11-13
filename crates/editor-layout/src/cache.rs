//! What layout keeps between calls, per text, and what it counts.
//!
//! Each text a scene or a query names (by its [`TextKey`]) has a wrap
//! layer: the segments laid out so far, at the last width asked. Frames and
//! queries read and fill the same entries, so a query after a frame lays
//! out nothing the frame laid out, and a frame after a query likewise.
//!
//! # Counters
//!
//! [`Counters`] count the work, for the performance gates. Each frame or
//! query counts each segment it reaches once, by how it got it the first
//! time: `shaped` (shaped and broken), `broken` (a kept shaped line broken
//! again at another width; a shaped segment counts here too) or `reused`
//! (a kept entry as it was).

use std::collections::HashMap;

use crate::decoration::{FaceSpanSource, SelectionSource};
use crate::scene::{TextKey, TextRef};
use crate::shaper::ShapedLine;
use crate::tabs::TabSnapshot;
use crate::wrap::{Outcome, WrapLayer};

/// The work layout has done, since it was made.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Counters {
    /// Segments shaped.
    pub shaped: u64,
    /// Segments broken into visual lines: once each time one is shaped,
    /// and once each time a kept one is broken again at another width.
    pub broken: u64,
    /// Segments used as they were kept.
    pub reused: u64,
}

impl Counters {
    /// Adds the outcome of each segment one call reached.
    pub(crate) fn add(&mut self, seen: &HashMap<(usize, usize), Outcome>) {
        for outcome in seen.values() {
            match outcome {
                Outcome::Shaped => {
                    self.shaped += 1;
                    self.broken += 1;
                }
                Outcome::Broken => self.broken += 1,
                Outcome::Reused => self.reused += 1,
            }
        }
    }
}

/// What layout keeps of one text.
pub(crate) struct TextState<L> {
    /// Its wrap layer.
    pub wrap: WrapLayer<L>,
    /// The selections and decorations of the last frame that showed it,
    /// so that a query shapes a row in the fonts the frame did. Read only
    /// while the text is at the revision they were laid out at.
    pub sources: Option<(SelectionSource, FaceSpanSource)>,
}

/// What layout keeps, by text.
pub(crate) type Texts<L> = HashMap<TextKey, TextState<L>>;

/// The state of `text`, ready to lay it out at `width`: what is kept of
/// it when that is of the snapshot's revision, and otherwise a fresh one.
pub(crate) fn state<'a, L: ShapedLine>(
    texts: &'a mut Texts<L>,
    text: &TextRef,
    tab_width: usize,
    width: Option<f32>,
) -> &'a mut TextState<L> {
    let revision = text.snapshot.revision();
    let state = texts.entry(text.key).or_insert_with(|| TextState {
        wrap: WrapLayer::new(TabSnapshot::new(text.snapshot.clone(), tab_width), width),
        sources: None,
    });
    if state.wrap.tabs().buffer().revision() != revision {
        *state = TextState {
            wrap: WrapLayer::new(TabSnapshot::new(text.snapshot.clone(), tab_width), width),
            sources: None,
        };
    }
    state.wrap.set_width(width);
    state
}
