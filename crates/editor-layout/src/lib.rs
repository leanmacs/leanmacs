//! Layout: from a published scene to a frame, and the layout queries the
//! editor asks in the same call.
//!
//! The crate is pure: it does no I/O, reads no clock and starts no thread.
//! It measures text only through the [`shaper::Shaper`] port it defines,
//! whose published fake is [`shaper::fake::CellShaper`] and whose contract
//! check is [`shaper::contract`]. Its `clippy.toml` refuses a line of it, a
//! test included, that names a real file, a process or a clock.
//!
//! # The rules this crate pins
//!
//! Its tests pin layout's rules, on the fake shaper:
//!
//! - the fake's own geometry: one glyph per character, an advance and a
//!   line height per font, greedy breaks with at least one glyph per line
//!   ([`shaper::fake`]);
//! - tab stops, the cut of a long row into segments and the content of a
//!   row ([`tabs`]);
//! - where a position is in a laid-out row: at a wrap, at a row's end,
//!   inside a tab's spaces ([`line`](mod@line)), and how entries are kept, broken
//!   again and moved through edits ([`wrap`]);
//! - which spans each decoration source gives, that a cursor covers
//!   nothing, how spans merge into styled runs and which font a run is in
//!   ([`decoration`]);
//! - the rows a view shows and where a move goes, with its goal x
//!   ([`query`]);
//! - the round trip of a position through the layers (`tests/layers.rs`).
//!
//! The adapter-neutral rules of shaping are [`shaper::contract`]'s, which
//! every real adapter runs. No crate downstream pins the fake's geometry.

pub mod decoration;
pub mod layer;
pub mod line;
pub mod query;
pub mod shaper;
pub mod tabs;
pub mod wrap;

use editor_text::Snapshot;

use crate::query::{Moved, QueryError, RowRange, Walker};
use crate::shaper::Shaper;
use crate::tabs::{DEFAULT_TAB_WIDTH, TabSnapshot};
use crate::wrap::WrapLayer;

/// Layout: a shaper and what is laid out with it.
pub struct Layout<S: Shaper> {
    /// The shaper.
    shaper: S,
    /// The tab width, in columns.
    tab_width: usize,
}

impl<S: Shaper> Layout<S> {
    /// A layout measuring with `shaper`, with tabs [`DEFAULT_TAB_WIDTH`]
    /// columns wide.
    pub fn new(shaper: S) -> Self {
        Self {
            shaper,
            tab_width: DEFAULT_TAB_WIDTH,
        }
    }

    /// The shaper.
    pub fn shaper(&self) -> &S {
        &self.shaper
    }

    /// The rows of `text` a view `width` pixels wide and `height` tall
    /// shows from the visual line that holds `anchor`, as many as fit
    /// whole, fewer at the end of the text.
    pub fn rows_shown(
        &mut self,
        text: &Snapshot,
        width: f32,
        height: f32,
        anchor: usize,
    ) -> Result<Vec<RowRange>, QueryError> {
        let mut wrap = WrapLayer::new(TabSnapshot::new(text.clone(), self.tab_width), Some(width));
        let mut walker = Walker {
            shaper: &self.shaper,
            wrap: &mut wrap,
            fonts: &[],
            outcome: &mut |_| {},
        };
        let rows = walker.rows_shown(height, anchor)?;
        Ok(rows
            .into_iter()
            .map(|visual| walker.range(visual))
            .collect())
    }

    /// The position of `text` `lines` visual lines below `position` (above
    /// when negative) in a view `width` pixels wide, aiming for the x
    /// `goal`, or for the position's own when there is none; and the goal
    /// to pass to the next move. A move past the first or the last line
    /// stops there.
    pub fn lines_from(
        &mut self,
        text: &Snapshot,
        width: f32,
        position: usize,
        lines: i64,
        goal: Option<f32>,
    ) -> Result<Moved, QueryError> {
        let mut wrap = WrapLayer::new(TabSnapshot::new(text.clone(), self.tab_width), Some(width));
        Walker {
            shaper: &self.shaper,
            wrap: &mut wrap,
            fonts: &[],
            outcome: &mut |_| {},
        }
        .lines_from(position, lines, goal)
    }
}
