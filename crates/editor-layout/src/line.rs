//! One layout object per segment of a buffer row: its tabs expanded, its
//! font runs, the shaped line the shaper gave back, and its breaks at one
//! width.
//!
//! A [`LineEntry`] holds no absolute offset and no `y`: its bytes are
//! relative to its row's start, so an edit on another row moves it without
//! touching it. It is immutable; a change of width makes a new entry that
//! shares the shaped line ([`LineEntry::rebreak`]), so a frame that holds
//! the old one keeps it as it was.
//!
//! # Align-to stops
//!
//! A segment laid out with align-to stops ([`Source::stops`]) is cut at
//! their columns into cells, each shaped on its own in the font runs that
//! fall in it, and its visual lines are the cells' pieces placed by
//! `align`'s rules. The entry keeps each cell's
//! shaped line and the cut, with each stop's x: the same cut at other xs,
//! or at another width, is broken and placed again without shaping
//! ([`LineEntry::rebreak_with`]); another cut is shaped again. A stop at
//! the segment's end, or past it, has no character after it in the
//! segment and does nothing.
//!
//! # Wrap indents
//!
//! A segment laid out under a wrap indent ([`Source::indent`]) has its
//! visual lines placed by `align`'s rules ("Wrap indents"): the first at
//! the first-line indent, broken at the room right of it, and the rest at
//! the continuation indent. A hanging indent's lead cuts the segment as a
//! stop does, into the leading span and the text after it, each shaped
//! on its own, unless a stop is at its column. The entry keeps the indent:
//! another lead is another cut, which shapes it again, and other pixels
//! break and place it again without shaping ([`LineEntry::rebreak_with`]).
//! A row with no stop and no lead is shaped as one line and placed as the
//! one cell of the row, so every row is placed by the same rules.
//!
//! # Cells
//!
//! A position, a cursor and a selection are found by a visual line's
//! **cells** ([`Cells`]), one for each character the line holds, and never
//! by its glyphs as they are listed. A shaper's glyphs are in the order
//! they are drawn in, which is not the order of the text where text runs
//! right to left; one glyph may draw several characters (a ligature); and
//! one cluster may be several glyphs (a letter and its mark) and several
//! characters.
//!
//! - The glyphs of one cluster are one box: from the first one's pen
//!   position, across all their advances.
//! - The box holds the characters from its cluster's offset up to the
//!   next cluster's on the line, or to the line's end.
//! - Each of those characters is a cell with an even share of the box, in
//!   the order of the text from the box's left. So the second character
//!   of a ligature of two is at the middle of its glyph, as a caret is
//!   placed by a browser, and a cursor can stand between a letter and its
//!   combining mark, since a cell is a character
//!   (`docs/design/text-and-display.md`, open questions).
//! - The x of a position is its cell's left edge, and of a line's end the
//!   line's width; an x aims for the cell it is in.
//!
//! In a row with align-to stops, the last glyph before a stop on the line
//! it shares with the stop's cell is as wide as the gap to the stop
//! (`align`), so its cell is too: a cursor on that
//! character spans the gap, and an x in the gap aims for it.
//!
//! On a shaper that gives a glyph for each character, in the order of the
//! text, a cell is a glyph. Three things need the direction of a cluster,
//! which the port's glyph does not carry, and are not right for
//! right-to-left text: the cells of a right-to-left cluster of several
//! characters are placed left to right; a position on a right-to-left
//! cell is at the cell's left edge, though the character starts at its
//! right; and the end of a line that ends in right-to-left text is at the
//! line's right edge.
//!
//! # Where a position is
//!
//! - A position at a wrap is the start of the later visual line.
//! - Only the last visual line of a row's last segment holds the position
//!   at the row's end; the last visual line of an earlier segment ends
//!   where the next segment starts, which is that segment's.
//! - A visual line that starts inside a tab's spaces starts after the tab:
//!   the tab's position is on the visual line its first space is on. The
//!   later line still draws the rest of the tab's spaces
//!   ([`LineEntry::drawn_bytes`]).
//! - A position at a break before a stop's cell (the overflow rule of
//!   `align`) is the start of the later line, as at a
//!   wrap.
//! - A visual line's glyphs and width include the indent it starts at, so
//!   an x left of the indent aims for the line's first character, and an
//!   empty row under an indent has its position at the first-line indent,
//!   its line's width.
//! - Every visual line holds a position, so each can be scrolled to and a
//!   move of one line reaches the next. A line the shaper breaks off inside
//!   a tab's spaces, which the tab's spaces end as well, would hold none,
//!   since the position after the tab is the next line's start: it is not
//!   kept, and those spaces of the tab are not drawn. It takes a view
//!   narrower than a tab. The exception is such a line at the row's end,
//!   which holds the row's end and is kept.

use std::ops::Range;
use std::sync::Arc;

use crate::align::{Cut, Kind, Placement, Rest, place};
use crate::indent::{SegmentIndent, SegmentRest};
use crate::layer::Bias;
use crate::shaper::{FontId, FontRun, ShapeInput, ShapedLine, Shaper, VisualLine};
use crate::tabs::Expanded;

/// One character of a visual line, as the box it is drawn in: the cell a
/// position, a cursor and a selection are found by.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Cell {
    /// The byte offset of the character in the segment's expanded text.
    pub column: usize,
    /// Its left edge, in pixels from the visual line's left edge.
    pub x: f32,
    /// How far across it is.
    pub width: f32,
}

/// The cells of one visual line, in the order they are drawn in, from the
/// line's left edge.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Cells {
    /// The cells, left to right.
    cells: Vec<Cell>,
    /// Whether they are in the order of their columns too, as they are on
    /// a line with no reordered text.
    in_text_order: bool,
}

impl Cells {
    /// The cells of `line`, whose glyphs' clusters are offsets of `text`.
    ///
    /// The glyphs of one cluster are one box, from the first one's pen
    /// position across all their advances. The box holds the characters of
    /// `text` from its cluster's offset to the next cluster's on the line,
    /// or to the line's end, and each of them has an even share of it, in
    /// the order of the text from the left.
    fn of(line: &VisualLine, text: &str) -> Self {
        // Each cluster's box, in the order its first glyph is drawn in.
        let mut boxes: Vec<Cell> = Vec::new();
        for glyph in &line.glyphs {
            match boxes.last_mut() {
                Some(last) if last.column == glyph.cluster => last.width += glyph.advance,
                _ => boxes.push(Cell {
                    column: glyph.cluster,
                    x: glyph.x,
                    width: glyph.advance,
                }),
            }
        }
        // Where each cluster's characters stop: at the next cluster of the
        // line in the text's order.
        let mut starts: Vec<usize> = boxes.iter().map(|cluster| cluster.column).collect();
        starts.sort_unstable();
        starts.dedup();
        let mut cells = Vec::with_capacity(boxes.len());
        for cluster in boxes {
            let next = starts.partition_point(|start| *start <= cluster.column);
            let end = starts.get(next).copied().unwrap_or(line.bytes.end);
            let characters = text
                .get(cluster.column..end.max(cluster.column))
                .map_or(0, |held| held.chars().count())
                .max(1);
            let width = cluster.width / characters as f32;
            let held = text.get(cluster.column..).unwrap_or_default();
            let offsets = held.char_indices().map(|(offset, _)| offset);
            // A cluster that is no offset of the text is one cell.
            for (index, offset) in offsets.chain([0]).take(characters).enumerate() {
                cells.push(Cell {
                    column: cluster.column + offset,
                    x: cluster.x + index as f32 * width,
                    width,
                });
            }
        }
        let in_text_order = cells.windows(2).all(|pair| pair[0].column < pair[1].column);
        Self {
            cells,
            in_text_order,
        }
    }

    /// The cells, left to right.
    pub fn cells(&self) -> &[Cell] {
        &self.cells
    }

    /// The cell that holds `column`: the one whose character starts at or
    /// last before it.
    fn holding(&self, column: usize) -> Option<&Cell> {
        if self.in_text_order {
            let after = self.cells.partition_point(|cell| cell.column <= column);
            return self.cells[..after].last();
        }
        self.cells
            .iter()
            .filter(|cell| cell.column <= column)
            .max_by_key(|cell| cell.column)
    }

    /// The leftmost cell `x` is in or left of.
    fn at(&self, x: f32) -> Option<&Cell> {
        self.cells.iter().find(|cell| x < cell.x + cell.width)
    }

    /// What the characters of `columns` cover of the line: the left and
    /// the right edge of each run of cells next to each other on the line
    /// that all hold one of them, from the left. Text in one direction is
    /// one run; a range that crosses a change of direction may be several,
    /// with cells it does not hold between them.
    pub fn covered(&self, columns: Range<usize>) -> Vec<(f32, f32)> {
        let mut runs: Vec<(f32, f32)> = Vec::new();
        let mut open = false;
        for cell in &self.cells {
            let held = columns.contains(&cell.column);
            match runs.last_mut() {
                Some(run) if held && open => run.1 = cell.x + cell.width,
                _ if held => runs.push((cell.x, cell.x + cell.width)),
                _ => {}
            }
            open = held;
        }
        runs
    }
}

/// What a segment was shaped into: one line, or one for each cell of a
/// row cut at its align-to stops.
enum Shaped<L> {
    /// The whole segment, shaped as one line.
    Whole(Arc<L>),
    /// Each cell of the cut, shaped on its own, by the cut's order; none
    /// for a cell of no column.
    Cells(Arc<[Option<L>]>),
}

impl<L> Clone for Shaped<L> {
    fn clone(&self) -> Self {
        match self {
            Self::Whole(line) => Self::Whole(Arc::clone(line)),
            Self::Cells(cells) => Self::Cells(Arc::clone(cells)),
        }
    }
}

/// One laid-out segment of a buffer row.
pub struct LineEntry<L> {
    /// The segment's bytes, relative to its row's start.
    bytes: Range<usize>,
    /// Its text with tabs expanded.
    expanded: Expanded,
    /// The font runs it was shaped with, in the expanded text.
    runs: Vec<FontRun>,
    /// The cells it is cut into at its stops and its lead, with each
    /// stop's x; none when it has no stop or lead that does anything.
    cuts: Vec<Cut>,
    /// The wrap indent it is placed under.
    indent: Option<SegmentIndent>,
    /// The shaper's generation it was shaped under.
    generation: u64,
    /// What it was shaped into.
    shaped: Shaped<L>,
    /// The width it is broken at.
    width: Option<f32>,
    /// Its visual lines at that width.
    lines: Vec<Arc<VisualLine>>,
    /// The cells of each of those lines.
    cells: Vec<Cells>,
    /// Whether it is its row's last segment.
    last: bool,
}

/// What a segment is laid out from.
pub struct Source<'a> {
    /// The segment's bytes, relative to its row's start.
    pub bytes: Range<usize>,
    /// Its text with tabs expanded.
    pub expanded: Expanded,
    /// Whether it is its row's last segment.
    pub last: bool,
    /// The font of each span of the segment that is not in the base font,
    /// as bytes relative to the segment's start; later spans are over
    /// earlier ones.
    pub fonts: &'a [(Range<usize>, FontId)],
    /// The base font: the font of every byte no span of `fonts` covers.
    pub base: FontId,
    /// Its align-to stops: each a byte offset relative to the segment's
    /// start, a character boundary, and an x in pixels from the start of
    /// the segment's first visual line, in the order of their offsets
    /// with none twice at one offset (`align`).
    pub stops: &'a [(usize, f32)],
    /// Its wrap indent, if one covers its row (`indent`).
    pub indent: Option<SegmentIndent>,
}

/// The cells of a segment `len` bytes long whose text expanded is
/// `expanded`, cut at `stops` (bytes relative to the segment's start, in
/// order) and at the lead of `indent`: cell 0 from the start to the first
/// cut, each later one from its cut to the next or the end. A stop or a
/// lead at or past the end has no character after it and does nothing,
/// nor does a lead of no byte; of two stops at one column the later wins,
/// and a lead at a stop's column marks the stop's cell as the hang. None
/// when nothing cuts it.
pub(crate) fn cuts_of(
    expanded: &Expanded,
    len: usize,
    stops: &[(usize, f32)],
    indent: Option<SegmentIndent>,
) -> Vec<Cut> {
    let mut starts: Vec<(usize, Kind)> = Vec::new();
    for &(offset, x) in stops.iter().filter(|(offset, _)| *offset < len) {
        let column = expanded.column(offset);
        let kind = Kind::Stop { x, hangs: false };
        match starts.last_mut() {
            Some(last) if last.0 == column => last.1 = kind,
            _ => starts.push((column, kind)),
        }
    }
    if let Some(SegmentIndent {
        rest: SegmentRest::Lead(lead),
        ..
    }) = indent
        && 0 < lead
        && lead < len
    {
        let column = expanded.column(lead);
        let at = starts.partition_point(|(start, _)| *start < column);
        match starts.get_mut(at) {
            Some((start, Kind::Stop { hangs, .. })) if *start == column => *hangs = true,
            _ => starts.insert(at, (column, Kind::Lead)),
        }
    }
    let Some(&(first, _)) = starts.first() else {
        return Vec::new();
    };
    let end = expanded.text().len();
    let mut cuts = vec![Cut {
        columns: 0..first,
        kind: Kind::First,
    }];
    for (index, &(column, kind)) in starts.iter().enumerate() {
        let next = starts.get(index + 1).map_or(end, |(next, _)| *next);
        cuts.push(Cut {
            columns: column..next,
            kind,
        });
    }
    cuts
}

/// Where the lines of a segment under `indent` start, by `align`'s rules.
fn placement(indent: Option<SegmentIndent>) -> Placement {
    indent.map_or(Placement::NONE, |indent| Placement {
        first: indent.first,
        rest: match indent.rest {
            SegmentRest::Pixels(x) => Rest::Pixels(x),
            SegmentRest::Lead(_) => Rest::Lead,
        },
    })
}

/// The font runs of `runs` that fall in `columns`, clipped to them and
/// made relative to their start.
fn cell_runs(runs: &[FontRun], columns: &Range<usize>) -> Vec<FontRun> {
    runs.iter()
        .filter(|run| run.bytes.start < columns.end && columns.start < run.bytes.end)
        .map(|run| FontRun {
            bytes: run.bytes.start.max(columns.start) - columns.start
                ..run.bytes.end.min(columns.end) - columns.start,
            font: run.font,
        })
        .collect()
}

/// The font runs of a segment `len` bytes long whose text expanded is
/// `expanded`, under the spans `fonts` (bytes relative to the segment's
/// start): the font `base` wherever no span names another, neighbours of
/// one font made one run. An empty text has one empty run, in the font of
/// a span at its start.
pub fn font_runs(
    expanded: &Expanded,
    len: usize,
    fonts: &[(Range<usize>, FontId)],
    base: FontId,
) -> Vec<FontRun> {
    let text_len = expanded.text().len();
    if len == 0 {
        let font = fonts
            .iter()
            .rev()
            .find(|(bytes, _)| bytes.start == 0)
            .map_or(base, |(_, font)| *font);
        return vec![FontRun { bytes: 0..0, font }];
    }
    // The spans in the expanded text, clipped to it.
    let spans: Vec<(Range<usize>, FontId)> = fonts
        .iter()
        .filter(|(bytes, _)| bytes.start < len && bytes.start < bytes.end)
        .map(|(bytes, font)| {
            let end = bytes.end.min(len);
            (expanded.column(bytes.start)..expanded.column(end), *font)
        })
        .collect();
    let mut cuts: Vec<usize> = spans
        .iter()
        .flat_map(|(bytes, _)| [bytes.start, bytes.end])
        .chain([0, text_len])
        .collect();
    cuts.sort_unstable();
    cuts.dedup();
    let mut runs: Vec<FontRun> = Vec::new();
    for pair in cuts.windows(2) {
        let (start, end) = (pair[0], pair[1]);
        let font = spans
            .iter()
            .rev()
            .find(|(bytes, _)| bytes.start <= start && end <= bytes.end)
            .map_or(base, |(_, font)| *font);
        match runs.last_mut() {
            Some(last) if last.font == font => last.bytes.end = end,
            _ => runs.push(FontRun {
                bytes: start..end,
                font,
            }),
        }
    }
    runs
}

/// The visual lines `shaped`, shaped from `expanded`, breaks into at
/// `width` under `placement`, placed by `align`'s rules: its cells by
/// `cuts` when it was shaped cell by cell, and the whole line as the one
/// cell of the row when it was not.
fn broken<L: ShapedLine>(
    shaped: &Shaped<L>,
    cuts: &[Cut],
    placement: Placement,
    expanded: &Expanded,
    width: Option<f32>,
) -> Vec<VisualLine> {
    match shaped {
        Shaped::Whole(line) => {
            let whole = [Cut {
                columns: 0..expanded.text().len(),
                kind: Kind::First,
            }];
            place(&whole, width, placement, |_, widths| {
                line.break_lines_in(widths)
            })
        }
        Shaped::Cells(cells) => place(cuts, width, placement, |index, widths| {
            cells
                .get(index)
                .and_then(Option::as_ref)
                .map_or_else(Vec::new, |cell: &L| cell.break_lines_in(widths))
        }),
    }
}

/// The visual lines `shaped` breaks into at `width` under `indent`, its
/// cells placed by `cuts`, each one that holds a position: `expanded` is the text it was
/// shaped from, and `last` whether the segment is its row's last.
///
/// A line the shaper breaks off inside a tab's spaces starts after the tab.
/// When the tab's spaces reach its end too, no position is on it, unless it
/// ends the row and so holds the row's end: such a line is left out, and
/// those spaces of the tab are not drawn. The first line is always kept.
fn visual_lines<L: ShapedLine>(
    shaped: &Shaped<L>,
    cuts: &[Cut],
    indent: Option<SegmentIndent>,
    expanded: &Expanded,
    width: Option<f32>,
    last: bool,
) -> Vec<Arc<VisualLine>> {
    let lines = broken(shaped, cuts, placement(indent), expanded, width);
    let count = lines.len();
    lines
        .into_iter()
        .enumerate()
        .filter(|(index, line)| {
            // The column of the first position at or after the line's
            // start: past the tab it starts inside.
            let first = expanded.column(expanded.offset(line.bytes.start, Bias::After));
            let holds_the_end = last && index + 1 == count;
            *index == 0 || first < line.bytes.end || (first == line.bytes.end && holds_the_end)
        })
        .map(|(_, line)| Arc::new(line))
        .collect()
}

/// Lays `source` out with `shaper` at `width`.
pub fn lay_out<S: Shaper>(
    shaper: &S,
    source: Source<'_>,
    width: Option<f32>,
) -> LineEntry<S::Shaped> {
    let runs = font_runs(
        &source.expanded,
        source.bytes.len(),
        source.fonts,
        source.base,
    );
    let cuts = cuts_of(
        &source.expanded,
        source.bytes.len(),
        source.stops,
        source.indent,
    );
    let text = source.expanded.text();
    let shaped = if cuts.is_empty() {
        Shaped::Whole(Arc::new(shaper.shape(&ShapeInput {
            text: text.to_owned(),
            runs: runs.clone(),
        })))
    } else {
        let cells: Vec<Option<S::Shaped>> = cuts
            .iter()
            .map(|cut| {
                (!cut.columns.is_empty()).then(|| {
                    shaper.shape(&ShapeInput {
                        text: text[cut.columns.clone()].to_owned(),
                        runs: cell_runs(&runs, &cut.columns),
                    })
                })
            })
            .collect();
        Shaped::Cells(cells.into())
    };
    let lines = visual_lines(
        &shaped,
        &cuts,
        source.indent,
        &source.expanded,
        width,
        source.last,
    );
    LineEntry {
        bytes: source.bytes,
        runs,
        cuts,
        indent: source.indent,
        generation: shaper.generation(),
        cells: cells_of(&lines, &source.expanded),
        lines,
        expanded: source.expanded,
        shaped,
        width,
        last: source.last,
    }
}

/// The cells of each of `lines`, which were shaped from `expanded`.
fn cells_of(lines: &[Arc<VisualLine>], expanded: &Expanded) -> Vec<Cells> {
    lines
        .iter()
        .map(|line| Cells::of(line, expanded.text()))
        .collect()
}

impl<L: ShapedLine> LineEntry<L> {
    /// This entry broken again at `width`, sharing its shaped line.
    #[must_use]
    pub fn rebreak(&self, width: Option<f32>) -> Self {
        self.rebroken(width, self.cuts.clone(), self.indent)
    }

    /// This entry broken again at `width`, its cells placed at `stops`
    /// (as [`Source::stops`]) and its lines under `indent`, sharing what
    /// it was shaped into. The caller gives stops and an indent that cut
    /// it as it was cut ([`LineEntry::shaped_with`]): only the stops' xs
    /// and the indent's pixels may differ.
    #[must_use]
    pub fn rebreak_with(
        &self,
        width: Option<f32>,
        stops: &[(usize, f32)],
        indent: Option<SegmentIndent>,
    ) -> Self {
        let cuts = cuts_of(&self.expanded, self.bytes.len(), stops, indent);
        self.rebroken(width, cuts, indent)
    }

    /// This entry broken again at `width`, cut into `cuts`, under
    /// `indent`.
    fn rebroken(&self, width: Option<f32>, cuts: Vec<Cut>, indent: Option<SegmentIndent>) -> Self {
        let lines = visual_lines(
            &self.shaped,
            &cuts,
            indent,
            &self.expanded,
            width,
            self.last,
        );
        Self {
            bytes: self.bytes.clone(),
            expanded: self.expanded.clone(),
            runs: self.runs.clone(),
            cuts,
            indent,
            generation: self.generation,
            shaped: self.shaped.clone(),
            width,
            cells: cells_of(&lines, &self.expanded),
            lines,
            last: self.last,
        }
    }
}

impl<L> LineEntry<L> {
    /// The segment's bytes, relative to its row's start.
    pub fn bytes(&self) -> Range<usize> {
        self.bytes.clone()
    }

    /// The font runs it was shaped with.
    pub fn runs(&self) -> &[FontRun] {
        &self.runs
    }

    /// Whether the spans `fonts` (bytes relative to the segment's start)
    /// over the base font `base` give the font runs it was shaped with,
    /// and the align-to stops `stops` (as [`Source::stops`]) and the lead
    /// of `indent` cut it into the cells it was shaped in, whatever the
    /// stops' xs and the indent's pixels.
    pub fn shaped_with(
        &self,
        fonts: &[(Range<usize>, FontId)],
        base: FontId,
        stops: &[(usize, f32)],
        indent: Option<SegmentIndent>,
    ) -> bool {
        let cuts = cuts_of(&self.expanded, self.bytes.len(), stops, indent);
        let same_cut = cuts.len() == self.cuts.len()
            && cuts
                .iter()
                .zip(&self.cuts)
                .all(|(cut, kept)| cut.columns == kept.columns);
        if !same_cut {
            return false;
        }
        if fonts.is_empty() {
            return self.runs.iter().all(|run| run.font == base);
        }
        font_runs(&self.expanded, self.bytes.len(), fonts, base) == self.runs
    }

    /// Whether its cells are placed at the xs of `stops` (as
    /// [`Source::stops`]) and its lines under `indent`: whether they cut it
    /// as it is cut, each stop at the x it is placed at, and the indent
    /// puts its lines where they are.
    pub fn placed_at(&self, stops: &[(usize, f32)], indent: Option<SegmentIndent>) -> bool {
        cuts_of(&self.expanded, self.bytes.len(), stops, indent) == self.cuts
            && placement(indent) == placement(self.indent)
    }

    /// The shaper's generation it was shaped under.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// The width it is broken at.
    pub fn width(&self) -> Option<f32> {
        self.width
    }

    /// Whether it is its row's last segment.
    pub fn is_last(&self) -> bool {
        self.last
    }

    /// Its text with tabs expanded.
    pub fn expanded(&self) -> &Expanded {
        &self.expanded
    }

    /// Its visual lines.
    pub fn lines(&self) -> &[Arc<VisualLine>] {
        &self.lines
    }

    /// The bytes of visual line `index`, relative to the row's start,
    /// without the row's line break. `None` past its last.
    pub fn line_bytes(&self, index: usize) -> Option<Range<usize>> {
        let start = self.line_start(index)?;
        let end = self.line_start(index + 1).unwrap_or(self.bytes.end);
        Some(start..end)
    }

    /// Where visual line `index` starts, relative to the row's start: after
    /// a tab whose spaces it starts inside.
    fn line_start(&self, index: usize) -> Option<usize> {
        let line = self.lines.get(index)?;
        Some(self.bytes.start + self.expanded.offset(line.bytes.start, Bias::After))
    }

    /// The bytes, relative to the row's start, of the characters visual
    /// line `index` draws any of: its own ([`LineEntry::line_bytes`]), and
    /// before them the tab whose spaces it starts inside, which is on the
    /// earlier line. `None` past its last.
    pub fn drawn_bytes(&self, index: usize) -> Option<Range<usize>> {
        let line = self.lines.get(index)?;
        let start = self.expanded.offset(line.bytes.start, Bias::Before);
        let end = self.expanded.offset(line.bytes.end, Bias::After);
        Some(self.bytes.start + start..self.bytes.start + end)
    }

    /// Whether visual line `index` holds the position at the row's end.
    pub fn holds_the_end(&self, index: usize) -> bool {
        self.last && index + 1 == self.lines.len()
    }

    /// The visual line that holds `offset`, relative to the row's start: a
    /// position at a wrap is in the later line.
    pub fn line_of(&self, offset: usize) -> usize {
        self.line_of_column(self.column(offset))
    }

    /// The visual line that holds the expanded column `column`.
    pub fn line_of_column(&self, column: usize) -> usize {
        self.lines
            .partition_point(|line| line.bytes.start <= column)
            .saturating_sub(1)
    }

    /// The expanded column of `offset`, relative to the row's start, kept
    /// within the segment.
    pub fn column(&self, offset: usize) -> usize {
        let offset = offset.clamp(self.bytes.start, self.bytes.end);
        self.expanded.column(offset - self.bytes.start)
    }

    /// The cells of visual line `index`, left to right. `None` past its
    /// last.
    pub fn cells(&self, index: usize) -> Option<&Cells> {
        self.cells.get(index)
    }

    /// The cell of visual line `index` that holds the expanded column
    /// `column`. `None` at or past the line's end, where there is no
    /// character, and before its first cell.
    pub fn cell_of_column(&self, index: usize, column: usize) -> Option<Cell> {
        let (line, cells) = (self.lines.get(index)?, self.cells.get(index)?);
        if column >= line.bytes.end {
            return None;
        }
        cells.holding(column).copied()
    }

    /// The x of `offset`, relative to the row's start, on visual line
    /// `index`: the left edge of the cell that holds it, or the line's
    /// width at its end.
    pub fn x_of(&self, index: usize, offset: usize) -> f32 {
        self.x_of_column(index, self.column(offset))
    }

    /// The x of the expanded column `column` on visual line `index`: the
    /// left edge of the cell that holds it, the line's width at or past
    /// its end, and 0 before its first cell.
    pub fn x_of_column(&self, index: usize, column: usize) -> f32 {
        let (Some(line), Some(cells)) = (self.lines.get(index), self.cells.get(index)) else {
            return 0.0;
        };
        if column >= line.bytes.end {
            return line.width;
        }
        cells.holding(column).map_or(0.0, |cell| cell.x)
    }

    /// The expanded column on visual line `index` at `x`: the column of
    /// the cell `x` is in, or the line's end past its last cell.
    pub fn column_at(&self, index: usize, x: f32) -> Option<usize> {
        let (line, cells) = (self.lines.get(index)?, self.cells.get(index)?);
        Some(cells.at(x).map_or(line.bytes.end, |cell| cell.column))
    }

    /// The offset, relative to the row's start, on visual line `index`
    /// that `x` aims for: the character of the cell `x` is in; past the
    /// rightmost cell, the row's end on the line that holds it, and the
    /// rightmost cell's character on any other line.
    pub fn offset_at(&self, index: usize, x: f32) -> usize {
        let (Some(cells), Some(bytes)) = (self.cells.get(index), self.line_bytes(index)) else {
            return self.bytes.end;
        };
        let cell = match cells.at(x) {
            Some(cell) => cell,
            None if self.holds_the_end(index) => return bytes.end,
            None => match cells.cells().last() {
                Some(cell) => cell,
                None => return bytes.start,
            },
        };
        let offset = self.bytes.start + self.expanded.offset(cell.column, Bias::Before);
        offset.clamp(bytes.start, bytes.end)
    }
}

#[cfg(test)]
mod tests {
    use std::ops::Range;

    use editor_text::Text;

    use super::{Cell, LineEntry, Source, lay_out};
    use crate::shaper::fake::{CellLine, CellShaper};
    use crate::shaper::scripted::{ScriptedLine, ScriptedShaper, glyph, line};
    use crate::shaper::{FontId, FontSpec, Glyph, ResolvedFontId, Shaper};
    use crate::tabs::{TabSnapshot, expand, row_content};

    /// The font of the family `tall` of [`shaper`], whose cells are 20 by
    /// 32: font 1, the first the shaper is asked for.
    const TALL: FontId = FontId(1);

    /// A shaper on cells 10 by 16, with [`TALL`].
    fn shaper() -> CellShaper {
        let shaper = CellShaper::new(10.0, 16.0).with_family("tall", 20.0, 32.0);
        let tall = shaper.font(&FontSpec {
            family: Some("tall".to_owned()),
            ..FontSpec::default()
        });
        assert_eq!(tall, TALL);
        shaper
    }

    /// Row `row` of `text` laid out with tabs 4 wide on cells 10 by 16,
    /// with `fonts` over font 0, at `width`.
    fn row_with(
        text: &str,
        row: usize,
        fonts: &[(Range<usize>, FontId)],
        width: Option<f32>,
    ) -> LineEntry<CellLine> {
        row_in(text, row, fonts, FontId(0), width)
    }

    /// Row `row` of `text` laid out with tabs 4 wide on cells 10 by 16,
    /// with `fonts` over the base font `base`, at `width`.
    fn row_in(
        text: &str,
        row: usize,
        fonts: &[(Range<usize>, FontId)],
        base: FontId,
        width: Option<f32>,
    ) -> LineEntry<CellLine> {
        let shaper = shaper();
        let tabs = TabSnapshot::new(Text::from(text).snapshot(), 4);
        let content = row_content(tabs.buffer(), row).unwrap();
        let (bytes, expanded) = tabs.segment(row, 0).unwrap();
        let start = bytes.start - content.start;
        lay_out(
            &shaper,
            Source {
                bytes: start..start + bytes.len(),
                expanded,
                last: true,
                fonts,
                base,
                stops: &[],
                indent: None,
            },
            width,
        )
    }

    /// The font each glyph of the first visual line of `entry` is drawn
    /// in.
    fn glyph_fonts(entry: &LineEntry<CellLine>) -> Vec<ResolvedFontId> {
        entry.lines()[0]
            .glyphs
            .iter()
            .map(|glyph| glyph.font)
            .collect()
    }

    /// The fonts the fake draws runs in `fonts` in.
    fn drawn(fonts: &[FontId]) -> Vec<ResolvedFontId> {
        fonts
            .iter()
            .map(|font| CellShaper::resolved_of(*font))
            .collect()
    }

    /// Row 0 of `text` in the default font at `width`.
    fn row(text: &str, width: Option<f32>) -> LineEntry<CellLine> {
        row_with(text, 0, &[], width)
    }

    /// The bytes of each visual line of `entry`.
    fn lines(entry: &LineEntry<CellLine>) -> Vec<Range<usize>> {
        (0..entry.lines().len())
            .map(|index| entry.line_bytes(index).unwrap())
            .collect()
    }

    /// The x of the glyph that draws the character at `offset`.
    fn glyph_x(entry: &LineEntry<CellLine>, offset: usize) -> f32 {
        let index = entry.line_of(offset);
        entry.x_of(index, offset)
    }

    /// Row 0 of `text`, unbroken, on a shaper that shapes it to the one
    /// visual line of `glyphs`: what a real shaper gives and the fake never
    /// does.
    fn scripted(text: &str, glyphs: Vec<Glyph>) -> LineEntry<ScriptedLine> {
        let shaper = ScriptedShaper::new(10.0, 16.0).with(text, vec![line(0..text.len(), glyphs)]);
        lay_out(
            &shaper,
            Source {
                bytes: 0..text.len(),
                expanded: expand(text, 4),
                last: true,
                fonts: &[],
                base: FontId(0),
                stops: &[],
                indent: None,
            },
            None,
        )
    }

    /// The x of each of `offsets` on the first visual line of `entry`.
    fn xs<L>(entry: &LineEntry<L>, offsets: &[usize]) -> Vec<f32> {
        offsets
            .iter()
            .map(|offset| entry.x_of(0, *offset))
            .collect()
    }

    /// The offset each of `xs` aims for on the first visual line of
    /// `entry`.
    fn offsets<L>(entry: &LineEntry<L>, xs: &[f32]) -> Vec<usize> {
        xs.iter().map(|x| entry.offset_at(0, *x)).collect()
    }

    #[test]
    fn glyphs_in_reverse_cluster_order_give_each_position_its_own_glyph() {
        // `abcd` drawn right to left: d is the leftmost glyph.
        let glyphs = vec![
            glyph('d', 3, 0.0, 10.0),
            glyph('c', 2, 10.0, 10.0),
            glyph('b', 1, 20.0, 10.0),
            glyph('a', 0, 30.0, 10.0),
        ];
        let entry = scripted("abcd", glyphs);
        // Each position is at the left edge of its own glyph, and the
        // line's end at its width.
        assert_eq!(xs(&entry, &[0, 1, 2, 3]), vec![30.0, 20.0, 10.0, 0.0]);
        assert_eq!(entry.x_of(0, 4), 40.0);
        // And each x aims for the character drawn there.
        assert_eq!(offsets(&entry, &[5.0, 15.0, 25.0, 35.0]), vec![3, 2, 1, 0]);
        assert_eq!(entry.offset_at(0, 100.0), 4);
        assert_eq!(entry.column_at(0, 15.0), Some(2));
        assert_eq!(entry.column_at(0, 100.0), Some(4));
    }

    #[test]
    fn a_line_of_two_directions_gives_each_position_its_own_glyph() {
        // `ab` left to right, then `cd` right to left: a, b, d, c.
        let glyphs = vec![
            glyph('a', 0, 0.0, 10.0),
            glyph('b', 1, 10.0, 10.0),
            glyph('d', 3, 20.0, 10.0),
            glyph('c', 2, 30.0, 10.0),
        ];
        let entry = scripted("abcd", glyphs);
        assert_eq!(xs(&entry, &[0, 1, 2, 3]), vec![0.0, 10.0, 30.0, 20.0]);
        assert_eq!(offsets(&entry, &[5.0, 15.0, 25.0, 35.0]), vec![0, 1, 3, 2]);
    }

    #[test]
    fn a_glyph_that_draws_two_characters_is_split_evenly_between_them() {
        // `afib` with `fi` one glyph 20 across: the second character of
        // the glyph is at its middle, and an x in its second half aims for
        // the second character.
        let glyphs = vec![
            glyph('a', 0, 0.0, 10.0),
            glyph('f', 1, 10.0, 20.0),
            glyph('b', 3, 30.0, 10.0),
        ];
        let entry = scripted("afib", glyphs);
        assert_eq!(
            xs(&entry, &[0, 1, 2, 3, 4]),
            vec![0.0, 10.0, 20.0, 30.0, 40.0]
        );
        assert_eq!(
            offsets(&entry, &[5.0, 12.0, 19.0, 20.0, 29.0, 35.0]),
            vec![0, 1, 1, 2, 2, 3]
        );
        assert_eq!(entry.column_at(0, 25.0), Some(2));
        // A glyph that draws the line's last characters ends at the line's
        // width.
        let entry = scripted(
            "afi",
            vec![glyph('a', 0, 0.0, 10.0), glyph('f', 1, 10.0, 20.0)],
        );
        assert_eq!(xs(&entry, &[1, 2, 3]), vec![10.0, 20.0, 30.0]);
        assert_eq!(offsets(&entry, &[25.0, 100.0]), vec![2, 3]);
    }

    #[test]
    fn a_cluster_of_two_glyphs_is_one_box() {
        // `e`, a combining mark, `x`: the letter and its mark are one
        // cluster of two glyphs, 6 and 4 across, and of two characters, so
        // the box is 10 across and each character has half of it.
        let glyphs = vec![
            glyph('e', 0, 0.0, 6.0),
            glyph('\u{301}', 0, 6.0, 4.0),
            glyph('x', 3, 10.0, 10.0),
        ];
        let entry = scripted("e\u{301}x", glyphs);
        assert_eq!(xs(&entry, &[0, 1, 3, 4]), vec![0.0, 5.0, 10.0, 20.0]);
        assert_eq!(
            offsets(&entry, &[2.0, 4.9, 5.0, 6.5, 9.0, 12.0]),
            vec![0, 0, 1, 1, 1, 3]
        );
        // A mark of no advance changes nothing: the box is the letter's.
        let glyphs = vec![
            glyph('e', 0, 0.0, 10.0),
            glyph('\u{301}', 0, 10.0, 0.0),
            glyph('x', 3, 10.0, 10.0),
        ];
        let entry = scripted("e\u{301}x", glyphs);
        assert_eq!(xs(&entry, &[0, 1, 3]), vec![0.0, 5.0, 10.0]);
    }

    /// A cell at `column`, from `x`, `width` across.
    fn cell(column: usize, x: f32, width: f32) -> Cell {
        Cell { column, x, width }
    }

    #[test]
    fn a_cluster_that_is_no_offset_of_the_text_is_one_cell() {
        // A shaper should give no such cluster. A line that has one is
        // still laid out, and the glyph still has a cell: one, as wide as
        // the glyph, where the glyph says it is.
        //
        // `é` is two bytes, so 1 is inside it and no character starts
        // there.
        let glyphs = vec![glyph('é', 1, 0.0, 10.0), glyph('b', 2, 10.0, 10.0)];
        let entry = scripted("éb", glyphs);
        let cells = entry.cells(0).expect("a line").cells();
        assert_eq!(cells, [cell(1, 0.0, 10.0), cell(2, 10.0, 10.0)]);
        assert_eq!(entry.column_at(0, 5.0), Some(1));
        // A cluster past the text's end.
        let glyphs = vec![
            glyph('a', 0, 0.0, 10.0),
            glyph('b', 1, 10.0, 10.0),
            glyph('c', 7, 20.0, 6.0),
        ];
        let entry = scripted("ab", glyphs);
        let cells = entry.cells(0).expect("a line").cells();
        assert_eq!(
            cells,
            [cell(0, 0.0, 10.0), cell(1, 10.0, 10.0), cell(7, 20.0, 6.0)]
        );
        assert_eq!(entry.column_at(0, 22.0), Some(7));
    }

    #[test]
    fn a_glyph_per_character_in_order_is_a_cell_per_glyph() {
        // What the fake gives: every answer is the glyph's own.
        let entry = row("aé😀b", None);
        assert_eq!(
            xs(&entry, &[0, 1, 3, 7, 8]),
            vec![0.0, 10.0, 20.0, 30.0, 40.0]
        );
        // An offset inside a character is that character's.
        assert_eq!(xs(&entry, &[2, 5]), vec![10.0, 20.0]);
        assert_eq!(
            offsets(&entry, &[0.0, 15.0, 29.9, 30.0, 99.0]),
            vec![0, 1, 3, 7, 8]
        );
    }

    #[test]
    fn a_line_wider_than_the_view_wraps_at_the_glyphs_that_fit() {
        assert_eq!(
            lines(&row("abcdefghij", Some(40.0))),
            vec![0..4, 4..8, 8..10]
        );
        // No partial glyph: 45 pixels hold four, as 40 do.
        assert_eq!(
            lines(&row("abcdefghij", Some(45.0))),
            vec![0..4, 4..8, 8..10]
        );
        assert_eq!(lines(&row("abcdefghij", None)), vec![0..10]);
    }

    #[test]
    fn the_glyph_after_a_tab_starts_at_the_next_stop() {
        assert_eq!(glyph_x(&row("a\tb", None), 2), 40.0);
        assert_eq!(glyph_x(&row("abcd\te", None), 5), 80.0);
        // A tab at a stop moves a whole stop.
        assert_eq!(glyph_x(&row("\tx", None), 1), 40.0);
        assert_eq!(glyph_x(&row("\t\tx", None), 2), 80.0);
    }

    #[test]
    fn a_carriage_return_before_a_line_feed_is_not_laid_out() {
        let entry = row("ab\r\ncd", None);
        assert_eq!(lines(&entry), vec![0..2]);
        assert_eq!(entry.lines()[0].glyphs.len(), 2);
        // A carriage return alone is a character.
        assert_eq!(row("a\rb", None).lines()[0].glyphs.len(), 3);
    }

    #[test]
    fn an_empty_row_is_one_empty_visual_line_of_the_default_height() {
        let entry = row_with("ab\n\ncd", 1, &[], Some(40.0));
        assert_eq!(lines(&entry), vec![0..0]);
        assert_eq!(entry.lines()[0].height, 16.0);
    }

    #[test]
    fn an_empty_row_is_as_tall_as_the_font_of_a_span_at_its_start() {
        let entry = row_with("ab\n\ncd", 1, &[(0..0, TALL)], Some(40.0));
        assert_eq!(lines(&entry), vec![0..0]);
        assert_eq!(entry.lines()[0].height, 32.0);
        // A later span is over an earlier one.
        let spans = [(0..0, TALL), (0..0, FontId(0))];
        let entry = row_with("ab\n\ncd", 1, &spans, Some(40.0));
        assert_eq!(entry.lines()[0].height, 16.0);
    }

    #[test]
    fn a_span_in_another_font_is_shaped_in_it() {
        let entry = row_with("abcd", 0, &[(1..3, TALL)], None);
        assert_eq!(
            glyph_fonts(&entry),
            drawn(&[FontId(0), TALL, TALL, FontId(0)])
        );
        assert_eq!(entry.lines()[0].height, 32.0);
        assert_eq!(glyph_x(&entry, 3), 50.0);
    }

    #[test]
    fn a_segment_under_a_base_that_is_not_font_0_is_shaped_in_it() {
        // No span: every byte is in the base font.
        let entry = row_in("abc", 0, &[], TALL, None);
        assert_eq!(glyph_fonts(&entry), drawn(&[TALL; 3]));
        assert_eq!(entry.lines()[0].height, 32.0);
        assert_eq!(glyph_x(&entry, 2), 40.0);
        // A span of font 0 is in font 0, and the rest in the base.
        let entry = row_in("abc", 0, &[(1..2, FontId(0))], TALL, None);
        assert_eq!(glyph_fonts(&entry), drawn(&[TALL, FontId(0), TALL]));
        // An empty row is as tall as the base font.
        let entry = row_in("ab\n\ncd", 1, &[], TALL, Some(40.0));
        assert_eq!(entry.lines()[0].height, 32.0);
    }

    #[test]
    fn a_kept_entry_was_shaped_with_the_same_spans_over_the_same_base_only() {
        let plain = row_in("abc", 0, &[], FontId(0), None);
        assert!(plain.shaped_with(&[], FontId(0), &[], None));
        assert!(!plain.shaped_with(&[], TALL, &[], None));
        // A span that names the base font changes nothing.
        assert!(plain.shaped_with(&[(1..2, FontId(0))], FontId(0), &[], None));
        let tall = row_in("abc", 0, &[], TALL, None);
        assert!(tall.shaped_with(&[], TALL, &[], None));
        assert!(!tall.shaped_with(&[], FontId(0), &[], None));
        // The same spans over another base are other runs.
        let spanned = row_in("abc", 0, &[(1..2, TALL)], FontId(0), None);
        assert!(spanned.shaped_with(&[(1..2, TALL)], FontId(0), &[], None));
        assert!(!spanned.shaped_with(&[(1..2, TALL)], TALL, &[], None));
        assert!(tall.shaped_with(&[(1..2, TALL)], TALL, &[], None));
    }

    #[test]
    fn a_wrap_inside_a_tabs_spaces_leaves_the_tab_on_the_earlier_line() {
        // "ab" and the tab's two spaces are four cells; at width 30 the
        // second space is on the next line, which starts after the tab.
        let entry = row("ab\tc", Some(30.0));
        assert_eq!(lines(&entry), vec![0..3, 3..4]);
        assert_eq!(entry.line_of(2), 0);
        assert_eq!(entry.line_of(3), 1);
    }

    #[test]
    fn a_line_that_starts_inside_a_tabs_spaces_draws_the_tab_too() {
        // The second of the tab's two spaces starts the second line.
        let entry = row("ab\tc", Some(30.0));
        assert_eq!(entry.line_bytes(1), Some(3..4));
        assert_eq!(entry.drawn_bytes(0), Some(0..3));
        assert_eq!(entry.drawn_bytes(1), Some(2..4));
        // A line that starts with a tab's first space draws its own bytes.
        let entry = row("abc\td", Some(30.0));
        assert_eq!(entry.line_bytes(1), Some(3..5));
        assert_eq!(entry.drawn_bytes(1), Some(3..5));
        assert_eq!(entry.drawn_bytes(2), None);
    }

    #[test]
    fn a_line_of_a_tabs_spaces_that_holds_no_position_is_not_kept() {
        // The tab is columns 1 to 4. At two columns the shaper breaks
        // "a ", two of the tab's spaces, "b": the spaces alone hold no
        // position, so they are no line.
        let entry = row("a\tb", Some(20.0));
        assert_eq!(lines(&entry), vec![0..2, 2..3]);
        assert_eq!(entry.lines()[1].glyphs.len(), 1);
        assert_eq!(
            [0, 1, 2, 3].map(|offset| entry.line_of(offset)),
            [0, 0, 1, 1]
        );
        // At one column the tab's first space is a line, the tab's own;
        // its other two are none.
        let entry = row("a\tb", Some(10.0));
        assert_eq!(lines(&entry), vec![0..1, 1..2, 2..3]);
        assert_eq!(
            [0, 1, 2, 3].map(|offset| entry.line_of(offset)),
            [0, 1, 2, 2]
        );
        // The tab's last spaces at a row's end hold the row's end.
        let entry = row("a\t", Some(20.0));
        assert_eq!(lines(&entry), vec![0..2, 2..2]);
        assert_eq!(entry.line_of(2), 1);
        assert_eq!(entry.x_of(1, 2), 20.0);
        // At the end of a segment that is not its row's last they hold
        // nothing: the end is the next segment's start.
        let cut = lay_out(
            &CellShaper::new(10.0, 16.0),
            Source {
                bytes: 0..2,
                expanded: expand("a\t", 4),
                last: false,
                fonts: &[],
                base: FontId(0),
                stops: &[],
                indent: None,
            },
            Some(20.0),
        );
        assert_eq!(lines(&cut), vec![0..2]);
        // Broken again at another width, the same rule.
        let entry = row("a\tb", None).rebreak(Some(20.0));
        assert_eq!(lines(&entry), vec![0..2, 2..3]);
    }

    #[test]
    fn a_position_at_a_wrap_is_on_the_later_line_and_the_end_on_the_last() {
        let entry = row("abcdef", Some(40.0));
        assert_eq!(entry.line_of(3), 0);
        assert_eq!(entry.line_of(4), 1);
        assert_eq!(entry.line_of(6), 1);
        assert_eq!(entry.x_of(1, 4), 0.0);
        assert_eq!(entry.x_of(1, 6), 20.0);
    }

    #[test]
    fn an_x_aims_for_the_glyph_it_is_in_and_past_the_last_for_the_end() {
        let entry = row("abcdef", Some(40.0));
        assert_eq!(entry.offset_at(0, 0.0), 0);
        assert_eq!(entry.offset_at(0, 19.0), 1);
        // Past the last glyph of a line that does not hold the end: the
        // last glyph.
        assert_eq!(entry.offset_at(0, 100.0), 3);
        // On the line that holds the end: the end.
        assert_eq!(entry.offset_at(1, 100.0), 6);
        // Inside a tab's spaces: the tab.
        assert_eq!(row("a\tb", None).offset_at(0, 25.0), 1);
    }

    #[test]
    fn a_width_change_breaks_the_kept_line_again() {
        let entry = row("abcdefghij", Some(40.0));
        let wider = entry.rebreak(Some(100.0));
        assert_eq!(lines(&wider), vec![0..10]);
        assert_eq!(lines(&entry), vec![0..4, 4..8, 8..10]);
    }
}
