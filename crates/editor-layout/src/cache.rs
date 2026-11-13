//! What layout keeps between calls, per text, and what it counts.
//!
//! **Entries are moved through patches, not cleared.** They are keyed by
//! buffer row, and a [`Patch`] says which rows each edit replaced, so the
//! entries of untouched rows move by the rows an edit added or removed
//! (`Layer::sync`). Patches are pulled through the [`Changes`](crate::scene::Changes) port of the
//! view's [`TextRef`]. When there is no patch to pull (the log has
//! forgotten the revision kept, or the text is gone), the text's state is
//! rebuilt lazily from the snapshot at hand: correct, at the cost of
//! shaping the visible rows once. A snapshot older than what is kept is
//! laid out in a scratch state that is thrown away, so the kept state
//! never moves backwards. A publish drops the state of every text its
//! scene does not name.
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
use std::ops::{Deref, DerefMut};

use editor_text::{Patch, Snapshot};

use crate::decoration::{FaceSpanSource, SelectionSource};
use crate::layer::{Layer, LayerEdit};
use crate::scene::{TextKey, TextRef};
use crate::shaper::ShapedLine;
use crate::tabs::{TabLayer, TabSnapshot};
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

/// What layout keeps of one text for one call: the kept state, or, for
/// a snapshot older than what is kept, a scratch state thrown away after
/// the call, so the kept one never moves backwards.
pub(crate) enum Held<'a, L> {
    /// The kept state.
    Kept(&'a mut TextState<L>),
    /// A scratch state.
    Scratch(Box<TextState<L>>),
}

impl<L> Deref for Held<'_, L> {
    type Target = TextState<L>;

    fn deref(&self) -> &TextState<L> {
        match self {
            Self::Kept(state) => state,
            Self::Scratch(state) => state,
        }
    }
}

impl<L> DerefMut for Held<'_, L> {
    fn deref_mut(&mut self) -> &mut TextState<L> {
        match self {
            Self::Kept(state) => state,
            Self::Scratch(state) => state,
        }
    }
}

impl<L: ShapedLine> TextState<L> {
    /// Nothing laid out of `snapshot` yet.
    fn fresh(snapshot: &Snapshot, tab_width: usize, width: Option<f32>) -> Self {
        Self {
            wrap: WrapLayer::new(TabSnapshot::new(snapshot.clone(), tab_width), width),
            sources: None,
        }
    }

    /// Moves the entries to `snapshot` through `patch`, which goes from the
    /// kept revision to the snapshot's.
    fn move_through(&mut self, snapshot: &Snapshot, patch: &Patch) {
        let edits: Vec<LayerEdit<usize>> = patch
            .edits
            .iter()
            .map(|edit| LayerEdit {
                old: edit.old.start..edit.old.end,
                new: edit.new.start..edit.new.end,
            })
            .collect();
        let mut tabs = TabLayer::over(self.wrap.tabs().clone());
        let (moved, tab_edits) = tabs.sync(snapshot, &edits);
        self.wrap.sync(&moved, &tab_edits);
        self.sources = None;
    }
}

/// The state of `text`, ready to lay it out at `width`:
///
/// - what is kept, when it is of the snapshot's revision;
/// - what is kept moved through the patch from its revision to the
///   snapshot's, pulled through `text.changes`;
/// - rebuilt from the snapshot when that patch cannot be had (the log has
///   forgotten it, the text is gone, or it does not reach the snapshot's
///   revision);
/// - a scratch state for a snapshot older than what is kept.
pub(crate) fn state<'a, L: ShapedLine>(
    texts: &'a mut Texts<L>,
    text: &TextRef,
    tab_width: usize,
    width: Option<f32>,
) -> Held<'a, L> {
    let snapshot = &text.snapshot;
    let revision = snapshot.revision();
    let state = texts
        .entry(text.key)
        .or_insert_with(|| TextState::fresh(snapshot, tab_width, width));
    let kept = state.wrap.tabs().buffer().revision();
    if kept > revision {
        return Held::Scratch(Box::new(TextState::fresh(snapshot, tab_width, width)));
    }
    if kept < revision {
        match text.changes.since(kept) {
            Some(patch) if patch.from == kept && patch.to == revision => {
                state.move_through(snapshot, &patch);
            }
            _ => *state = TextState::fresh(snapshot, tab_width, width),
        }
    }
    state.wrap.set_width(width);
    Held::Kept(state)
}
