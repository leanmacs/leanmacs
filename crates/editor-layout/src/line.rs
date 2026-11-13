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
//! - Every visual line holds a position, so each can be scrolled to and a
//!   move of one line reaches the next. A line the shaper breaks off inside
//!   a tab's spaces, which the tab's spaces end as well, would hold none,
//!   since the position after the tab is the next line's start: it is not
//!   kept, and those spaces of the tab are not drawn. It takes a view
//!   narrower than a tab. The exception is such a line at the row's end,
//!   which holds the row's end and is kept.

use std::ops::Range;
use std::sync::Arc;

use crate::layer::Bias;
use crate::shaper::{FontId, FontRun, ShapeInput, ShapedLine, Shaper, VisualLine};
use crate::tabs::Expanded;

/// One laid-out segment of a buffer row.
pub struct LineEntry<L> {
    /// The segment's bytes, relative to its row's start.
    bytes: Range<usize>,
    /// Its text with tabs expanded.
    expanded: Expanded,
    /// The font runs it was shaped with, in the expanded text.
    runs: Vec<FontRun>,
    /// The shaper's generation it was shaped under.
    generation: u64,
    /// The shaped line.
    shaped: Arc<L>,
    /// The width it is broken at.
    width: Option<f32>,
    /// Its visual lines at that width.
    lines: Vec<Arc<VisualLine>>,
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
    /// The font of each span of the segment that is not in the default
    /// font, as bytes relative to the segment's start; later spans are
    /// over earlier ones.
    pub fonts: &'a [(Range<usize>, FontId)],
}

/// The font runs of a segment `len` bytes long whose text expanded is
/// `expanded`, under the spans `fonts` (bytes relative to the segment's
/// start): the default font wherever no span names another, neighbours of
/// one font made one run. An empty text has one empty run, in the font of
/// a span at its start.
pub fn font_runs(
    expanded: &Expanded,
    len: usize,
    fonts: &[(Range<usize>, FontId)],
) -> Vec<FontRun> {
    let text_len = expanded.text().len();
    if len == 0 {
        let font = fonts
            .iter()
            .rev()
            .find(|(bytes, _)| bytes.start == 0)
            .map_or(FontId::default(), |(_, font)| *font);
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
            .map_or(FontId::default(), |(_, font)| *font);
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

/// The visual lines `shaped` breaks into at `width`, each one that holds a
/// position: `expanded` is the text it was shaped from, and `last` whether
/// the segment is its row's last.
///
/// A line the shaper breaks off inside a tab's spaces starts after the tab.
/// When the tab's spaces reach its end too, no position is on it, unless it
/// ends the row and so holds the row's end: such a line is left out, and
/// those spaces of the tab are not drawn. The first line is always kept.
fn visual_lines<L: ShapedLine>(
    shaped: &L,
    expanded: &Expanded,
    width: Option<f32>,
    last: bool,
) -> Vec<Arc<VisualLine>> {
    let lines = shaped.break_lines(width);
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
    let runs = font_runs(&source.expanded, source.bytes.len(), source.fonts);
    let shaped = Arc::new(shaper.shape(&ShapeInput {
        text: source.expanded.text().to_owned(),
        runs: runs.clone(),
    }));
    LineEntry {
        bytes: source.bytes,
        runs,
        generation: shaper.generation(),
        lines: visual_lines(&*shaped, &source.expanded, width, source.last),
        expanded: source.expanded,
        shaped,
        width,
        last: source.last,
    }
}

impl<L: ShapedLine> LineEntry<L> {
    /// This entry broken again at `width`, sharing its shaped line.
    #[must_use]
    pub fn rebreak(&self, width: Option<f32>) -> Self {
        Self {
            bytes: self.bytes.clone(),
            expanded: self.expanded.clone(),
            runs: self.runs.clone(),
            generation: self.generation,
            shaped: Arc::clone(&self.shaped),
            width,
            lines: visual_lines(&*self.shaped, &self.expanded, width, self.last),
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
    /// give the font runs it was shaped with.
    pub fn shaped_with(&self, fonts: &[(Range<usize>, FontId)]) -> bool {
        let default = |runs: &[FontRun]| runs.iter().all(|run| run.font == FontId::default());
        if fonts.is_empty() {
            return default(&self.runs);
        }
        font_runs(&self.expanded, self.bytes.len(), fonts) == self.runs
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

    /// The x of `offset`, relative to the row's start, on visual line
    /// `index`: the left edge of the glyph that draws it, or the line's
    /// width past its last glyph.
    pub fn x_of(&self, index: usize, offset: usize) -> f32 {
        self.x_of_column(index, self.column(offset))
    }

    /// The x of the expanded column `column` on visual line `index`.
    pub fn x_of_column(&self, index: usize, column: usize) -> f32 {
        let Some(line) = self.lines.get(index) else {
            return 0.0;
        };
        if column >= line.bytes.end {
            return line.width;
        }
        line.glyphs
            .iter()
            .rev()
            .find(|glyph| glyph.cluster <= column)
            .map_or(0.0, |glyph| glyph.x)
    }

    /// The expanded column on visual line `index` at `x`: the cluster of
    /// the glyph `x` is in, or the line's end past its last glyph.
    pub fn column_at(&self, index: usize, x: f32) -> Option<usize> {
        let line = self.lines.get(index)?;
        Some(
            line.glyphs
                .iter()
                .find(|glyph| x < glyph.x + glyph.advance)
                .map_or(line.bytes.end, |glyph| glyph.cluster),
        )
    }

    /// The offset, relative to the row's start, on visual line `index`
    /// that `x` aims for: the start of the glyph `x` is in; past the last
    /// glyph, the row's end on the line that holds it, and the last
    /// glyph's start on any other line.
    pub fn offset_at(&self, index: usize, x: f32) -> usize {
        let (Some(line), Some(bytes)) = (self.lines.get(index), self.line_bytes(index)) else {
            return self.bytes.end;
        };
        let glyph = match line.glyphs.iter().find(|glyph| x < glyph.x + glyph.advance) {
            Some(glyph) => glyph,
            None if self.holds_the_end(index) => return bytes.end,
            None => match line.glyphs.last() {
                Some(glyph) => glyph,
                None => return bytes.start,
            },
        };
        let offset = self.bytes.start + self.expanded.offset(glyph.cluster, Bias::Before);
        offset.clamp(bytes.start, bytes.end)
    }
}

#[cfg(test)]
mod tests {
    use std::ops::Range;

    use editor_text::Text;

    use super::{LineEntry, Source, lay_out};
    use crate::shaper::FontId;
    use crate::shaper::fake::{CellLine, CellShaper};
    use crate::tabs::{TabSnapshot, expand, row_content};

    /// Row `row` of `text` laid out with tabs 4 wide on cells 10 by 16,
    /// with `fonts`, at `width`.
    fn row_with(
        text: &str,
        row: usize,
        fonts: &[(Range<usize>, FontId)],
        width: Option<f32>,
    ) -> LineEntry<CellLine> {
        let shaper = CellShaper::new(10.0, 16.0).with_font(FontId(1), 20.0, 32.0);
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
            },
            width,
        )
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
        let entry = row_with("ab\n\ncd", 1, &[(0..0, FontId(1))], Some(40.0));
        assert_eq!(lines(&entry), vec![0..0]);
        assert_eq!(entry.lines()[0].height, 32.0);
        // A later span is over an earlier one.
        let spans = [(0..0, FontId(1)), (0..0, FontId(0))];
        let entry = row_with("ab\n\ncd", 1, &spans, Some(40.0));
        assert_eq!(entry.lines()[0].height, 16.0);
    }

    #[test]
    fn a_span_in_another_font_is_shaped_in_it() {
        let entry = row_with("abcd", 0, &[(1..3, FontId(1))], None);
        let fonts: Vec<FontId> = entry.lines()[0]
            .glyphs
            .iter()
            .map(|glyph| glyph.font)
            .collect();
        assert_eq!(fonts, vec![FontId(0), FontId(1), FontId(1), FontId(0)]);
        assert_eq!(entry.lines()[0].height, 32.0);
        assert_eq!(glyph_x(&entry, 3), 50.0);
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
