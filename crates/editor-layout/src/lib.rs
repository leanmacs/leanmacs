//! Layout: from a published scene ([`scene`]) to a frame ([`frame`]), and
//! the layout queries the editor asks in the same call ([`query`]).
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
//! - what a face sets, the precedence by which the faces over a run merge
//!   attribute by attribute, the fall-through to the default face and to
//!   the base values, and which attributes are the font and which are paint
//!   ([`face`]);
//! - which spans each decoration source gives, that a cursor covers
//!   nothing, how spans merge into styled runs and which font a run is in
//!   ([`decoration`]);
//! - the rows a view shows and where a move goes, with its goal x
//!   ([`query`]);
//! - the frame: rows from a view's anchor stacked by height, cursor and
//!   selection geometry, content hashes that a cursor move leaves alone,
//!   decorations asked for the rows shown only ([`frame`]), and the fixture
//!   frame checked in at `tests/display/frame.expected`
//!   (`tests/frame_fixture.rs`);
//! - what is kept between calls and what it costs, by the counters
//!   ([`cache`], `tests/counters.rs`), moved through patches or rebuilt
//!   when none can be had (`tests/patches.rs`), and the bound on a very
//!   long row (`tests/long_line.rs`);
//! - the round trip of a position through the layers (`tests/layers.rs`).
//!
//! The adapter-neutral rules of shaping are [`shaper::contract`]'s, which
//! every real adapter runs. No crate downstream pins the fake's geometry.

pub mod cache;
pub mod decoration;
pub mod face;
pub mod frame;
pub mod layer;
pub mod line;
pub mod query;
pub mod scene;
pub mod shaper;
pub mod tabs;
pub mod wrap;

use std::collections::HashMap;

use crate::cache::{Counters, Texts, state};
use crate::decoration::{DecorationSource, FaceTable, fonts_of};
use crate::face::SELECTION_FACE;
use crate::query::{Moved, QueryError, RowRange, Walker};
use crate::scene::{TextKey, TextRef};
use crate::shaper::{FontId, Shaper};
use crate::tabs::{DEFAULT_TAB_WIDTH, row_content, segment_count};
use crate::wrap::Outcome;

/// Layout: a shaper and what is laid out with it.
pub struct Layout<S: Shaper> {
    /// The shaper.
    shaper: S,
    /// The tab width, in columns.
    tab_width: usize,
    /// The faces named so far.
    faces: FaceTable,
    /// The work done so far.
    counters: Counters,
    /// What is kept of each text.
    texts: Texts<S::Shaped>,
}

impl<S: Shaper> Layout<S> {
    /// A layout measuring with `shaper`, with tabs [`DEFAULT_TAB_WIDTH`]
    /// columns wide.
    pub fn new(shaper: S) -> Self {
        let mut faces = FaceTable::default();
        faces.intern(SELECTION_FACE);
        Self {
            shaper,
            tab_width: DEFAULT_TAB_WIDTH,
            faces,
            counters: Counters::default(),
            texts: HashMap::new(),
        }
    }

    /// The faces named so far: the selection face first, then each in the
    /// order a scene first named it.
    pub fn faces(&self) -> &FaceTable {
        &self.faces
    }

    /// The faces, to set a face's font in a test until faces resolve to
    /// fonts (phase 2).
    pub fn faces_mut(&mut self) -> &mut FaceTable {
        &mut self.faces
    }

    /// The shaper.
    pub fn shaper(&self) -> &S {
        &self.shaper
    }

    /// The work done so far.
    pub fn counters(&self) -> Counters {
        self.counters
    }

    /// How many texts layout keeps entries of.
    pub fn texts_kept(&self) -> usize {
        self.texts.len()
    }

    /// How many segments layout keeps laid out of the text `key`.
    pub fn entries_kept(&self, key: TextKey) -> usize {
        self.texts.get(&key).map_or(0, |state| state.wrap.len())
    }

    /// The height of the whole of `text` laid out `width` pixels wide, in
    /// pixels: each segment kept at that width counts its visual lines'
    /// heights, and each other one line of the default height. It lays
    /// nothing out, and is corrected as rows are laid out.
    pub fn height_estimate(&self, text: &TextRef, width: f32) -> f32 {
        let snapshot = &text.snapshot;
        let kept = self
            .texts
            .get(&text.key)
            .filter(|state| state.wrap.tabs().buffer().revision() == snapshot.revision());
        let line_height = self.shaper.metrics(FontId::default()).line_height;
        let mut height = 0.0;
        for row in 0..snapshot.row_count() {
            let Some(content) = row_content(snapshot, row) else {
                continue;
            };
            for segment in 0..segment_count(snapshot, &content) {
                height += kept
                    .and_then(|state| state.wrap.kept(row, segment))
                    .filter(|entry| entry.width() == Some(width))
                    .map_or(line_height, |entry| {
                        entry.lines().iter().map(|line| line.height).sum()
                    });
            }
        }
        height
    }

    /// The rows of `text` a view `width` pixels wide and `height` tall
    /// shows from the visual line that holds `anchor`, as many as fit
    /// whole, fewer at the end of the text.
    pub fn rows_shown(
        &mut self,
        text: &TextRef,
        width: f32,
        height: f32,
        anchor: usize,
    ) -> Result<Vec<RowRange>, QueryError> {
        self.query(text, width, |walker| {
            let rows = walker.rows_shown(height, anchor)?;
            Ok(rows
                .into_iter()
                .map(|visual| walker.range(visual))
                .collect())
        })
    }

    /// The position of `text` `lines` visual lines below `position` (above
    /// when negative) in a view `width` pixels wide, aiming for the x
    /// `goal`, or for the position's own when there is none; and the goal
    /// to pass to the next move. A move past the first or the last line
    /// stops there.
    pub fn lines_from(
        &mut self,
        text: &TextRef,
        width: f32,
        position: usize,
        lines: i64,
        goal: Option<f32>,
    ) -> Result<Moved, QueryError> {
        self.query(text, width, |walker| {
            walker.lines_from(position, lines, goal)
        })
    }

    /// Runs `ask` on a walker over what is kept of `text` at `width`, in
    /// the fonts of the last frame that showed it, and counts the work.
    fn query<T>(
        &mut self,
        text: &TextRef,
        width: f32,
        ask: impl FnOnce(&mut Walker<'_, S>) -> T,
    ) -> T {
        let mut state = state(&mut self.texts, text, self.tab_width, Some(width));
        let state = &mut *state;
        let sources: Vec<&dyn DecorationSource> = match &state.sources {
            Some((selections, decorations)) => vec![selections, decorations],
            None => Vec::new(),
        };
        let faces = &self.faces;
        let snapshot = &text.snapshot;
        let fonts = |bytes| fonts_of(&sources, snapshot, bytes, faces);
        let mut seen: HashMap<(usize, usize), Outcome> = HashMap::new();
        let answer = ask(&mut Walker {
            shaper: &self.shaper,
            wrap: &mut state.wrap,
            base: FontId::default(),
            fonts: &fonts,
            outcome: &mut |row, segment, outcome| {
                seen.entry((row, segment)).or_insert(outcome);
            },
        });
        self.counters.add(&seen);
        answer
    }
}
