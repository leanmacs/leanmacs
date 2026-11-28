//! Layout: from a published scene ([`scene`]) to a frame ([`frame`]), and
//! the layout queries the editor asks in the same call ([`query`]).
//!
//! The crate is pure: it does no I/O, reads no clock and starts no thread.
//! It measures text only through the [`shaper::Shaper`] port it defines,
//! whose published fake is [`shaper::fake::CellShaper`] and whose contract
//! check is [`shaper::contract`]. The root `clippy.toml` refuses a line of
//! it, a test included, that names a real file, a process or a clock.
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
//!   inside a tab's spaces, and by the cells of a visual line, whatever
//!   the order of its glyphs and however many characters a glyph draws
//!   ([`line`](mod@line)), and how entries are kept, broken again and
//!   moved through edits ([`wrap`]);
//! - what a face sets, the precedence by which the faces over a run merge
//!   attribute by attribute, the fall-through to the default face and to
//!   the base values, and which attributes are the font and which are paint
//!   ([`face`]);
//! - which spans each decoration source gives, that a cursor covers
//!   nothing, how spans merge into styled runs, and that a run is in the
//!   font its faces resolve to, lowest layer first ([`decoration`]); that
//!   a text's own spans are drawn under the decorations and the selection,
//!   asked only for the rows shown, and wrapped by the rows and lines
//!   queries as the frame wraps them ([`frame`], and this module's tests);
//!   and the contract of [`scene::TextSpans`] ([`scene::spans_contract`]);
//! - the scale: a length a face states is in points; a length and a font
//!   at a scale ([`shaper::Length::scaled`], [`shaper::FontSpec::scaled`]);
//!   that a font is asked of the shaper at the scale last set
//!   ([`Layout::set_scale`], [`decoration`]); that the same theme at scale
//!   2 gives rows twice as tall and lines twice as wide, in rectangles
//!   that are still physical pixels, and that the queries answer at the
//!   scale (`tests/scale.rs`); and that a change of scale alone shapes
//!   every row shown again and the scale a layout has shapes none
//!   (`tests/counters.rs`);
//! - a view's padding and the echo's: points multiplied at the layout's
//!   scale, unrounded ([`Layout::padding_pixels`]); the text, the cursors
//!   and the selections moved in by it, the text wrapped at the width less
//!   it and filling the height less it, a status row's fields inset by it
//!   with its background across the view, and the rows query taking it off
//!   by the same rule (`tests/padding.rs`, `tests/heights.rs`);
//! - the rows a view shows, at most one for each pixel of its height
//!   whatever height a font gives its lines, where a move goes, with
//!   its goal x, and where a position is drawn, padding and row heights
//!   included ([`query`], `tests/spot.rs`);
//! - the frame: rows from a view's anchor stacked by height, cursor and
//!   selection geometry read from cells (a cursor a share of its glyph, a
//!   selection an area for each stretch of a row it covers), the paint
//!   each run, cursor and view resolves to,
//!   content hashes that cover paint and that a cursor move leaves alone,
//!   the status row at a view's bottom, its fields on their sides, each
//!   padded in a box of its face's background, exactly as tall as
//!   [`Layout::heights`] says, and the text rows that fit above it, which
//!   are the rows query's at the height that remains (`tests/heights.rs`),
//!   decorations asked for the rows shown only, the shaper's
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
//! - the round trip of a position through the layers (`tests/layers.rs`);
//! - measuring a run: its width in its faces over the default face, in
//!   whole points rounded up, at any scale, its tabs expanded and nothing
//!   after a line feed ([`Layout::measure`], `tests/measure.rs`);
//! - blocks: where a view's blocks are drawn, that each of their lines
//!   counts among the lines that fit, the first-row rule, that the rows
//!   query and the spot count them as the frame draws them and a move
//!   does not, and that cursors and selections are on text rows only
//!   ([`query`], "Blocks"; `tests/blocks.rs`); and that a frame that shows
//!   the same blocks again shapes none of them (`tests/counters.rs`);
//! - gutter marks: a column before the text, each mark beside every visual
//!   line of the rows its range covers in its face over `gutter`, the rows,
//!   spot and move queries taking the column off as the frame does, and
//!   mark rows kept apart from text rows ([`frame`], "The gutter";
//!   `tests/gutter.rs`);
//! - folds: which rows a view's folds cover and which of them show, and
//!   the mapping of a position to a fold point and back ([`folds`]); a
//!   fold drawn as one unbroken placeholder row in its own faces, holding
//!   every position of its rows at x 0, the rows, move and spot queries
//!   counting it as one line, a cursor and a selection on it, and the
//!   blocks and gutter marks beside it ([`query`], "Folds";
//!   `tests/folds.rs`); that folding and unfolding shapes the placeholder
//!   alone (`tests/counters.rs`); and the round trip of a position
//!   through the fold layer (`tests/layers.rs`);
//! - align-to stops: a row cut at its stops into cells, each shaped on its
//!   own and placed at its stop or after the cell before it, a stop at or
//!   past the width breaking the row before its cell, which starts the
//!   next visual line at x 0, a long cell hanging under its stop, and the
//!   gap before a stop belonging to the character before it (`align`);
//!   a view's stops in points, at the scale, the rows, spot and move
//!   queries laying a row out under the last frame's stops, and cells of
//!   one column lining up whatever the widths before them
//!   (`tests/align.rs`); what a change of a stop shapes and breaks
//!   (`tests/counters.rs`), and the round trip of a position through a
//!   row with stops (`tests/layers.rs`);
//! - translated spans: a text made of pieces of other texts draws each
//!   source's own spans at every piece of it, cut at the pieces' edges,
//!   each source resolved once, and keeps the contract of
//!   [`scene::TextSpans`] ([`translated`]).
//!
//! The adapter-neutral rules of shaping are [`shaper::contract`]'s, which
//! every real adapter runs. No crate downstream pins the fake's geometry.

mod align;
mod blocks;
pub mod cache;
pub mod decoration;
pub mod face;
pub mod folds;
pub mod frame;
pub mod layer;
pub mod line;
pub mod query;
pub mod scene;
pub mod shaper;
pub mod tabs;
pub mod translated;
pub mod wrap;

use std::collections::HashMap;
use std::ops::Range;

use crate::blocks::{BlockLayout, Blocks, ViewBeside, ViewBlocks, ViewFolds};
use crate::cache::{Counters, StatusKept, Texts, state};
use crate::folds::FoldSnapshot;
use editor_text::Text;

use crate::decoration::{
    DecorationSource, FaceSpanSource, Span, Styles, TextSpansSource, fonts_of,
};
use crate::face::{FaceDef, SELECTION_FACE};
use crate::line::font_runs;
use crate::query::{
    Around, Beside, Moved, QueryError, RowRange, Shown, Spot, Walker, relative_stops,
};
use crate::scene::{Decoration, Padding, TextKey, TextRef, ViewId};
use crate::shaper::{FontId, ShapeInput, ShapedLine, Shaper};
use crate::tabs::{DEFAULT_TAB_WIDTH, boundary_at_or_before, expand, row_content, segment_count};
use crate::wrap::Outcome;

/// `points` in pixels at `scale`: the points times the scale, unrounded.
/// The one rule [`Layout::padding_pixels`] and the stops a query lays a
/// row out under both follow.
fn pixels(points: u32, scale: f32) -> f32 {
    points as f32 * scale
}

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
    /// What is kept of each block, apart from the texts (`blocks`).
    blocks: Blocks<S::Shaped>,
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
            blocks: HashMap::new(),
        }
    }

    /// Takes `definitions` as what the faces look like from now on: every
    /// later frame, query and [`heights`](Layout::heights) answer is in
    /// them, as if a scene had carried them, though no frame is laid out.
    /// A caller that sizes views by the heights before it publishes a
    /// scene with new faces defines them first. The definitions a layout
    /// already has change nothing. What is kept of a text is not dropped:
    /// an entry keeps the font runs it was shaped with, so a row is shaped
    /// again exactly when its faces now come to other fonts, and a change
    /// of paint shapes nothing.
    pub fn define(&mut self, definitions: &[FaceDef]) {
        if self.styles.define(definitions) {
            self.base = self.styles.style(&self.shaper, &[]).font;
        }
    }

    /// Takes `scale` as the scale to lay out at from now on: how many
    /// physical pixels a point of a face's lengths is, which is the scale
    /// factor of the target the frames are drawn on. A layout begins at 1,
    /// and a scale that is not a finite number above 0 is taken as 1.
    ///
    /// Frames and queries are both at the scale last set, so a query
    /// after a change answers at the new scale with no frame between.
    /// What is kept of a text is not dropped: an entry keeps the font
    /// runs it was shaped with, and at another scale every run is in
    /// another font, so each row is shaped again when a frame or a query
    /// next reaches it, and the scale a layout already has shapes
    /// nothing.
    pub fn set_scale(&mut self, scale: f32) {
        if self.styles.set_scale(scale) {
            self.base = self.styles.style(&self.shaper, &[]).font;
        }
    }

    /// The scale it lays out at ([`Layout::set_scale`]).
    pub fn scale(&self) -> f32 {
        self.styles.scale()
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

    /// `points` of padding in pixels at the scale this layout lays out at
    /// ([`Layout::set_scale`]): `points` times the scale, unrounded, as a
    /// status field's padding is. Frames and queries both take a padding
    /// off through this, so the two cannot disagree ([`frame`], "The
    /// padding").
    pub fn padding_pixels(&self, points: u32) -> f32 {
        pixels(points, self.scale())
    }

    /// The rows of `text` a view `width` pixels wide and `height` tall,
    /// its content inset by `padding` (in points), shows from the visual
    /// line that holds `anchor`, as many as fit whole, fewer at the end of
    /// the text. The padding is taken off as the frame takes it off: twice
    /// [`Layout::padding_pixels`] of `across` and once of `gutter` from the
    /// width, and twice of `down` and once of `top` from the height, at 0
    /// at least.
    pub fn rows_shown(
        &mut self,
        text: &TextRef,
        width: f32,
        height: f32,
        padding: Padding,
        anchor: usize,
    ) -> Result<Vec<RowRange>, QueryError> {
        self.rows_shown_with_blocks(text, width, height, padding, anchor, Around::default())
    }

    /// [`Layout::rows_shown`] in a view with `around`'s blocks between its
    /// rows and its folds: the text rows it shows, each block line counted
    /// among the lines that fit by the rule the frame shows them by, and
    /// each shown fold one row ([`query`], "Blocks" and "Folds"). With no
    /// block and no fold it is [`Layout::rows_shown`].
    pub fn rows_shown_with_blocks(
        &mut self,
        text: &TextRef,
        width: f32,
        height: f32,
        padding: Padding,
        anchor: usize,
        around: Around<'_>,
    ) -> Result<Vec<RowRange>, QueryError> {
        let width = self.text_width(width, padding);
        let height = self.text_height(height, padding);
        self.query(text, width, around, |walker, beside| {
            let shown = walker.shown(height, anchor, beside)?;
            Ok(shown
                .into_iter()
                .filter_map(|shown| match shown {
                    Shown::Text(visual) => Some(walker.range(visual)),
                    Shown::Block { .. } => None,
                })
                .collect())
        })
    }

    /// The position of `text` `lines` visual lines below `position` (above
    /// when negative) in a view `width` pixels wide whose text is inset
    /// `across` points from each side, aiming for the x `goal`, or for the
    /// position's own when there is none; and the goal to pass to the next
    /// move. A move past the first or the last line stops there. A move
    /// only wraps, so it takes no height: the width it wraps at is
    /// `width` less twice [`Layout::padding_pixels`] of `across`, as the
    /// frame's. The goal is from the text's left, not the view's.
    pub fn lines_from(
        &mut self,
        text: &TextRef,
        width: f32,
        across: u32,
        position: usize,
        lines: i64,
        goal: Option<f32>,
    ) -> Result<Moved, QueryError> {
        let padding = Padding {
            across,
            ..Padding::default()
        };
        self.lines_from_padded(
            text,
            width,
            padding,
            position,
            lines,
            goal,
            Around::default(),
        )
    }

    /// [`Layout::lines_from`] in a view whose content is inset by
    /// `padding`, with `around`'s folds: the width it wraps at is `width`
    /// less twice [`Layout::padding_pixels`] of `across` and once of
    /// `gutter`, as the frame's, and each shown fold is one line, landed on
    /// at its start ([`query`], "Folds"). The padding down is not looked
    /// at: a move takes no height. Nor are `around`'s blocks: a block holds
    /// no position.
    #[expect(
        clippy::too_many_arguments,
        reason = "a view's geometry, its folds and the move, each an input of where the move lands"
    )]
    pub fn lines_from_padded(
        &mut self,
        text: &TextRef,
        width: f32,
        padding: Padding,
        position: usize,
        lines: i64,
        goal: Option<f32>,
        around: Around<'_>,
    ) -> Result<Moved, QueryError> {
        let width = self.text_width(width, padding);
        let folds = Around {
            blocks: &[],
            folds: around.folds,
        };
        self.query(text, width, folds, |walker, _| {
            walker.lines_from(position, lines, goal)
        })
    }

    /// Where `position` of `text` is drawn in a view `width` pixels wide
    /// and `height` tall, its content inset by `padding` (in points), that
    /// shows from the visual line that holds `anchor`: from the view's own
    /// top left, the x of the position's left edge and the y of the top of
    /// the row that holds it, the padding included, and that row's height.
    /// None when the position is not among the rows
    /// [`rows_shown`](Layout::rows_shown) answers for the same view, which
    /// includes a position before the anchor. It is the same walk, and
    /// each row before the position counts at the height the frame draws
    /// it at, so a taller row pushes the rows after it down by its own
    /// height.
    pub fn spot(
        &mut self,
        text: &TextRef,
        width: f32,
        height: f32,
        padding: Padding,
        anchor: usize,
        position: usize,
    ) -> Result<Option<Spot>, QueryError> {
        self.spot_with_blocks(
            text,
            width,
            height,
            padding,
            anchor,
            position,
            Around::default(),
        )
    }

    /// [`Layout::spot`] in a view with `around`'s blocks between its rows
    /// and its folds: a position below a block is lower by the block's
    /// lines, each at the height the frame draws it at, and a position a
    /// fold covers is at its placeholder's x 0 ([`query`], "Blocks" and
    /// "Folds"). With no block and no fold it is [`Layout::spot`].
    #[expect(
        clippy::too_many_arguments,
        reason = "a view's geometry, its blocks and folds and the position, each an input of where the position is drawn"
    )]
    pub fn spot_with_blocks(
        &mut self,
        text: &TextRef,
        width: f32,
        height: f32,
        padding: Padding,
        anchor: usize,
        position: usize,
        around: Around<'_>,
    ) -> Result<Option<Spot>, QueryError> {
        let left = self.text_left(padding);
        let down = self.first_row(padding);
        let width = self.text_width(width, padding);
        let height = self.text_height(height, padding);
        self.query(text, width, around, |walker, beside| {
            Ok(walker
                .spot(height, anchor, position, beside)?
                .map(|spot| Spot {
                    x: left + spot.x,
                    y: down + spot.y,
                    height: spot.height,
                }))
        })
    }

    /// How wide `text` is, laid out in `decorations` (bytes of `text`,
    /// each a face) over the default face, unbroken: in whole points, so a
    /// caller that computes align-to stops from it never handles a scale
    /// ([`scene`], "Align-to stops").
    ///
    /// The run is `text` up to its first line feed, without a carriage
    /// return before it, its tabs expanded from column 0 by the tab
    /// layer's rule ([`tabs`]). Its faces are resolved as a block's are,
    /// in the faces as last defined and at the scale last set, so it
    /// measures what a row of the same text in the same faces draws.
    /// The width is in pixels divided by the scale, rounded to the
    /// nearest 64th and then up to a whole point. Nothing is kept, and no
    /// counter counts it.
    pub fn measure(&mut self, text: &str, decorations: &[Decoration]) -> u32 {
        let run = text.split('\n').next().unwrap_or_default();
        let run = if run.len() < text.len() {
            run.strip_suffix('\r').unwrap_or(run)
        } else {
            run
        };
        let snapshot = Text::from(run).snapshot();
        let spans: Vec<Span> = decorations
            .iter()
            .map(|decoration| {
                let start = boundary_at_or_before(&snapshot, decoration.start);
                Span {
                    bytes: start..boundary_at_or_before(&snapshot, decoration.stop).max(start),
                    face: self.styles.intern(&decoration.face),
                }
            })
            .collect();
        let source = FaceSpanSource::new(spans);
        let sources: [&dyn DecorationSource; 1] = [&source];
        let fonts = fonts_of(
            &sources,
            &snapshot,
            0..run.len(),
            &self.styles,
            &self.shaper,
            self.base,
        );
        let expanded = expand(run, self.tab_width);
        let runs = font_runs(&expanded, run.len(), &fonts, self.base);
        let shaped = self.shaper.shape(&ShapeInput {
            text: expanded.text().to_owned(),
            runs,
        });
        let width: f32 = shaped.break_lines(None).iter().map(|line| line.width).sum();
        let sixty_fourths = (f64::from(width) / f64::from(self.scale()) * 64.0).round();
        // A float cast to a whole number stops at the number's ends.
        (sixty_fourths / 64.0).ceil() as u32
    }

    /// `extent` less `points` of padding at each end, in pixels at the
    /// layout's scale, and 0 at least.
    pub(crate) fn inset(&self, extent: f32, points: u32) -> f32 {
        (extent - 2.0 * self.padding_pixels(points)).max(0.0)
    }

    /// The width a view's text rows wrap at of `width`, with `padding`:
    /// `width` less `across` at each side and `gutter` at the left, in
    /// pixels at the layout's scale, and 0 at least ([`frame`], "The
    /// gutter").
    pub(crate) fn text_width(&self, width: f32, padding: Padding) -> f32 {
        (self.inset(width, padding.across) - self.padding_pixels(padding.gutter)).max(0.0)
    }

    /// How far right from a view's left its text rows start, with
    /// `padding`: `across` and `gutter`, in pixels at the layout's scale.
    pub(crate) fn text_left(&self, padding: Padding) -> f32 {
        self.padding_pixels(padding.across) + self.padding_pixels(padding.gutter)
    }

    /// The height a view's text rows fill of `height`, with `padding`:
    /// `height` less `down` above and below and `top` above, in pixels at
    /// the layout's scale, and 0 at least ([`frame`], "The padding").
    pub(crate) fn text_height(&self, height: f32, padding: Padding) -> f32 {
        (self.inset(height, padding.down) - self.padding_pixels(padding.top)).max(0.0)
    }

    /// How far down from a view's top its first text row starts, with
    /// `padding`: `top` and `down`, in pixels at the layout's scale.
    pub(crate) fn first_row(&self, padding: Padding) -> f32 {
        self.padding_pixels(padding.top) + self.padding_pixels(padding.down)
    }

    /// Runs `ask` on a walker over what is kept of `text` at `width`, with
    /// the text's own spans resolved for its snapshot, as the frame of that
    /// snapshot resolves them, under the selections and decorations of the
    /// last frame that showed it, in the faces as they are now, with the
    /// lines of `around`'s blocks before each row and its folds shown
    /// (the walk's `beside`), and counts the work.
    fn query<T>(
        &mut self,
        text: &TextRef,
        width: f32,
        around: Around<'_>,
        ask: impl FnOnce(&mut Walker<'_, S>, &mut dyn Beside) -> T,
    ) -> T {
        let own = TextSpansSource::of(&mut self.styles, text);
        let mut view_blocks = ViewBlocks::new(around.blocks, &text.snapshot, &mut self.styles);
        let mut view_folds = ViewFolds::new(around.folds, &mut self.styles);
        let folds = FoldSnapshot::new(&text.snapshot, around.folds);
        let scale = self.scale();
        let mut state = state(&mut self.texts, text, self.tab_width, Some(width));
        let state = &mut *state;
        // Lowest layer first: the text's own spans, the decorations, then
        // the selections.
        let mut sources: Vec<&dyn DecorationSource> = Vec::new();
        if let Some(own) = &own {
            sources.push(own);
        }
        // The last frame's stops, in pixels at the scale as it is now.
        let mut stops: Vec<(usize, f32)> = Vec::new();
        if let Some(last) = &state.sources {
            sources.push(&last.decorations);
            sources.push(&last.selections);
            stops.extend(
                last.stops
                    .iter()
                    .map(|(offset, x)| (*offset, pixels(*x, scale))),
            );
        }
        let stops_of = |bytes: Range<usize>| relative_stops(&stops, &bytes);
        let (styles, shaper, base) = (&self.styles, &self.shaper, self.base);
        let snapshot = &text.snapshot;
        let fonts = |bytes| fonts_of(&sources, snapshot, bytes, styles, shaper, base);
        let mut block_layout = BlockLayout {
            store: &mut self.blocks,
            shaper,
            styles,
            base,
            tab_width: self.tab_width,
            width,
            counters: &mut self.counters,
        };
        let mut beside = ViewBeside {
            blocks: &mut view_blocks,
            folds: &mut view_folds,
            layout: &mut block_layout,
        };
        let mut seen: HashMap<(usize, usize), Outcome> = HashMap::new();
        let answer = ask(
            &mut Walker {
                shaper,
                wrap: &mut state.wrap,
                folds: &folds,
                base,
                fonts: &fonts,
                stops: &stops_of,
                outcome: &mut |row, segment, outcome| {
                    seen.entry((row, segment)).or_insert(outcome);
                },
            },
            &mut beside,
        );
        self.counters.add(&seen);
        answer
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use editor_text::Text;

    use crate::Layout;
    use crate::face::{Color, Face, FaceDef};
    use crate::scene::{
        Decoration, FixedSpans, Padding, Rect, Scene, TextKey, TextRef, View, ViewId,
    };
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

    /// `abcdefgh` with its own span of `big` over its first four bytes,
    /// and a layout in which `big` is twice the base size.
    fn spanned() -> (TextRef, Layout<CellShaper>) {
        let spans = FixedSpans::new(&["big"], vec![(0..4, 0)]);
        let text = TextRef::fixed(TextKey(7), Text::from("abcdefgh").snapshot())
            .with_spans(Arc::new(spans));
        let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
        layout.define(&[FaceDef {
            name: "big".to_owned(),
            face: sized(32),
        }]);
        (text, layout)
    }

    /// The byte ranges of the rows the frame of a view of `text` 40 wide
    /// and 160 tall shows.
    fn frame_rows(layout: &mut Layout<CellShaper>, text: &TextRef) -> Vec<(usize, usize)> {
        let scene = Scene {
            views: vec![View {
                id: ViewId(1),
                rect: Rect {
                    x: 0,
                    y: 0,
                    width: 40,
                    height: 160,
                },
                text: Some(text.clone()),
                ..View::default()
            }],
            ..Scene::default()
        };
        layout.frame(&scene).views[0]
            .rows
            .iter()
            .map(|row| (row.bytes.start, row.bytes.end))
            .collect()
    }

    #[test]
    fn the_rows_query_wraps_text_spans_as_the_frame_does() {
        let (text, mut layout) = spanned();
        let asked = |layout: &mut Layout<CellShaper>| {
            layout
                .rows_shown(&text, 40.0, 160.0, Padding::default(), 0)
                .unwrap()
                .iter()
                .map(|row| (row.start, row.stop))
                .collect::<Vec<_>>()
        };
        // Before any frame of the text: the big glyphs are two to a row.
        let before = asked(&mut layout);
        let framed = frame_rows(&mut layout, &text);
        assert_eq!(framed, vec![(0, 2), (2, 4), (4, 8)]);
        assert_eq!(before, framed);
        // And after one.
        assert_eq!(asked(&mut layout), framed);
    }

    #[test]
    fn the_lines_query_wraps_text_spans_as_the_frame_does() {
        let (text, mut layout) = spanned();
        let moved = |layout: &mut Layout<CellShaper>, position: usize, lines: i64| {
            layout
                .lines_from(&text, 40.0, 0, position, lines, Some(0.0))
                .unwrap()
                .position
        };
        // Down from the start, one row at a time, and back up: each lands
        // on the start of one of the frame's rows.
        assert_eq!(moved(&mut layout, 0, 1), 2);
        assert_eq!(moved(&mut layout, 2, 1), 4);
        assert_eq!(frame_rows(&mut layout, &text), vec![(0, 2), (2, 4), (4, 8)]);
        assert_eq!(moved(&mut layout, 4, -1), 2);
        assert_eq!(moved(&mut layout, 2, -1), 0);
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
        assert_eq!(
            layout
                .rows_shown(&text, 40.0, 48.0, Padding::default(), 0)
                .unwrap()
                .len(),
            2
        );
        // A scene that carries no faces keeps them.
        let mut kept = scene(sized(32));
        kept.faces = None;
        layout.frame(&kept);
        assert_eq!(
            layout
                .rows_shown(&text, 40.0, 48.0, Padding::default(), 0)
                .unwrap()
                .len(),
            2
        );
        // The face made paint only: three rows of 16.
        let red = Face {
            foreground: Some(Color::rgb(9, 0, 0)),
            ..Face::default()
        };
        layout.frame(&scene(red));
        assert_eq!(
            layout
                .rows_shown(&text, 40.0, 48.0, Padding::default(), 0)
                .unwrap()
                .len(),
            3
        );
        // A query is in the default face's font too: at twice the base
        // size a glyph is 20 across and a row 32 tall, so a view 20 wide
        // and 64 tall shows `a` and `b`, each on a row.
        layout.frame(&Scene {
            views: scene(Face::default()).views,
            ..defining("default", sized(32))
        });
        let rows = layout
            .rows_shown(&text, 20.0, 64.0, Padding::default(), 0)
            .unwrap();
        assert_eq!(
            rows.iter()
                .map(|row| (row.start, row.stop))
                .collect::<Vec<_>>(),
            vec![(0, 1), (1, 2)]
        );
    }
}
