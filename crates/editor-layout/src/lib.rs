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
//!   line height per font, greedy breaks with at least one glyph per line,
//!   and a resolved font per spec ([`shaper::fake`]);
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
//!   nothing, how spans merge into styled runs, and that a run is in the
//!   font its faces resolve to, lowest layer first ([`decoration`]);
//! - the rows a view shows, at most one for each pixel of its height
//!   whatever height a font gives its lines, and where a move goes, with
//!   its goal x ([`query`]);
//! - the frame: rows from a view's anchor stacked by height, cursor and
//!   selection geometry, the paint each run, cursor and view resolves to,
//!   content hashes that cover paint and that a cursor move leaves alone,
//!   the status row at a view's bottom and the text rows that fit above
//!   it, decorations asked for the rows shown only, the shaper's
//!   generation and its table of resolved fonts carried by the frame, with
//!   every glyph naming an entry ([`frame`]), and the fixture frame
//!   checked in at `tests/display/frame.expected`
//!   (`tests/frame_fixture.rs`);
//! - what is kept between calls and what it costs, by the counters
//!   ([`cache`], `tests/counters.rs`): a change of a face's paint shapes
//!   and breaks nothing, a change of its font shapes the rows drawn in
//!   it and no other, and a face whose lines have no height costs a row
//!   for each pixel of the view, not the text; moved through patches or
//!   rebuilt when none can be had (`tests/patches.rs`), and the bound on a
//!   very long row (`tests/long_line.rs`);
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

use crate::cache::{Counters, StatusKept, Texts, state};
use crate::decoration::{DecorationSource, Styles, fonts_of};
use crate::face::{FaceDef, SELECTION_FACE};
use crate::query::{Moved, QueryError, RowRange, Walker};
use crate::scene::{TextKey, TextRef, ViewId};
use crate::shaper::{FontId, Shaper};
use crate::tabs::{DEFAULT_TAB_WIDTH, row_content, segment_count};
use crate::wrap::Outcome;

/// Layout: a shaper and what is laid out with it.
pub struct Layout<S: Shaper> {
    /// The shaper.
    shaper: S,
    /// The tab width, in columns.
    tab_width: usize,
    /// The faces: the definitions of the last scene that carried any, and
    /// what each stack of them comes to.
    styles: Styles,
    /// The base font: the default face's, which every byte no other face
    /// puts in another font is shaped in.
    base: FontId,
    /// The work done so far.
    counters: Counters,
    /// What is kept of each text.
    texts: Texts<S::Shaped>,
    /// What is kept of each view's status row.
    status: HashMap<ViewId, StatusKept>,
}

impl<S: Shaper> Layout<S> {
    /// A layout measuring with `shaper`, with tabs [`DEFAULT_TAB_WIDTH`]
    /// columns wide and no face defined.
    pub fn new(shaper: S) -> Self {
        let mut styles = Styles::default();
        styles.intern(SELECTION_FACE);
        let base = styles.style(&shaper, &[]).font;
        Self {
            shaper,
            tab_width: DEFAULT_TAB_WIDTH,
            styles,
            base,
            counters: Counters::default(),
            texts: HashMap::new(),
            status: HashMap::new(),
        }
    }

    /// Takes `definitions` as what the faces look like from now on. What
    /// is kept of a text is not dropped: an entry keeps the font runs it
    /// was shaped with, so a row is shaped again exactly when its faces
    /// now come to other fonts, and a change of paint shapes nothing.
    pub(crate) fn define(&mut self, definitions: &[FaceDef]) {
        if self.styles.define(definitions) {
            self.base = self.styles.style(&self.shaper, &[]).font;
        }
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
    /// heights, and each other one line of the default face's font. It
    /// lays nothing out, and is corrected as rows are laid out.
    pub fn height_estimate(&self, text: &TextRef, width: f32) -> f32 {
        let snapshot = &text.snapshot;
        let kept = self
            .texts
            .get(&text.key)
            .filter(|state| state.wrap.tabs().buffer().revision() == snapshot.revision());
        let line_height = self.shaper.metrics(self.base).line_height;
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

    /// Runs `ask` on a walker over what is kept of `text` at `width`, with
    /// the selections and decorations of the last frame that showed it in
    /// the faces as they are now, and counts the work.
    fn query<T>(
        &mut self,
        text: &TextRef,
        width: f32,
        ask: impl FnOnce(&mut Walker<'_, S>) -> T,
    ) -> T {
        let mut state = state(&mut self.texts, text, self.tab_width, Some(width));
        let state = &mut *state;
        // Lowest layer first: the decorations, then the selections.
        let sources: Vec<&dyn DecorationSource> = match &state.sources {
            Some((selections, decorations)) => vec![decorations, selections],
            None => Vec::new(),
        };
        let (styles, shaper, base) = (&self.styles, &self.shaper, self.base);
        let snapshot = &text.snapshot;
        let fonts = |bytes| fonts_of(&sources, snapshot, bytes, styles, shaper, base);
        let mut seen: HashMap<(usize, usize), Outcome> = HashMap::new();
        let answer = ask(&mut Walker {
            shaper: &self.shaper,
            wrap: &mut state.wrap,
            base,
            fonts: &fonts,
            outcome: &mut |row, segment, outcome| {
                seen.entry((row, segment)).or_insert(outcome);
            },
        });
        self.counters.add(&seen);
        answer
    }
}

#[cfg(test)]
mod tests {
    use editor_text::Text;

    use crate::Layout;
    use crate::face::{Color, Face, FaceDef};
    use crate::scene::{Decoration, Rect, Scene, TextKey, TextRef, View, ViewId};
    use crate::shaper::Length;
    use crate::shaper::fake::CellShaper;

    /// A scene of no view that defines `name` as `face`.
    fn defining(name: &str, face: Face) -> Scene {
        Scene {
            faces: Some(vec![FaceDef {
                name: name.to_owned(),
                face,
            }]),
            ..Scene::default()
        }
    }

    /// A face of the size `pixels` and nothing else.
    fn sized(pixels: u32) -> Face {
        Face {
            size: Some(Length::pixels(pixels)),
            ..Face::default()
        }
    }

    #[test]
    fn a_row_not_laid_out_is_estimated_at_the_default_faces_line_height() {
        let text = TextRef::fixed(TextKey(1), Text::from("a\nb\nc\nd\ne").snapshot());
        let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
        assert_eq!(layout.height_estimate(&text, 40.0), 5.0 * 16.0);
        // The default face at twice the base size: lines twice as tall.
        layout.frame(&defining("default", sized(32)));
        assert_eq!(layout.height_estimate(&text, 40.0), 5.0 * 32.0);
        // Another face's size is not the default's.
        layout.frame(&defining("other", sized(32)));
        assert_eq!(layout.height_estimate(&text, 40.0), 5.0 * 16.0);
    }

    #[test]
    fn a_query_after_a_change_of_faces_lays_out_in_the_new_ones() {
        let text = TextRef::fixed(TextKey(1), Text::from("ab\ncd\nef").snapshot());
        // The second row is in the face `tall`.
        let scene = |tall: Face| Scene {
            views: vec![View {
                id: ViewId(1),
                rect: Rect {
                    x: 0,
                    y: 0,
                    width: 40,
                    height: 160,
                },
                text: Some(text.clone()),
                decorations: vec![Decoration {
                    start: 3,
                    stop: 5,
                    face: "tall".to_owned(),
                }],
                ..View::default()
            }],
            ..defining("tall", tall)
        };
        let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
        layout.frame(&scene(sized(32)));
        // The rows are 16, 32 and 16 tall: 48 pixels hold two.
        assert_eq!(layout.rows_shown(&text, 40.0, 48.0, 0).unwrap().len(), 2);
        // A scene that carries no faces keeps them.
        let mut kept = scene(sized(32));
        kept.faces = None;
        layout.frame(&kept);
        assert_eq!(layout.rows_shown(&text, 40.0, 48.0, 0).unwrap().len(), 2);
        // The face made paint only: three rows of 16.
        let red = Face {
            foreground: Some(Color::rgb(9, 0, 0)),
            ..Face::default()
        };
        layout.frame(&scene(red));
        assert_eq!(layout.rows_shown(&text, 40.0, 48.0, 0).unwrap().len(), 3);
        // A query is in the default face's font too: at twice the base
        // size a glyph is 20 across and a row 32 tall, so a view 20 wide
        // and 64 tall shows `a` and `b`, each on a row.
        layout.frame(&Scene {
            views: scene(Face::default()).views,
            ..defining("default", sized(32))
        });
        let rows = layout.rows_shown(&text, 20.0, 64.0, 0).unwrap();
        assert_eq!(
            rows.iter()
                .map(|row| (row.start, row.stop))
                .collect::<Vec<_>>(),
            vec![(0, 1), (1, 2)]
        );
    }
}
