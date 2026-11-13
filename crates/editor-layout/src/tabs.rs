//! The tab layer: each buffer row cut into segments, and each tab of a
//! segment expanded into spaces up to the next tab stop.
//!
//! **Tabs are expanded before shaping** (decided in the display pipeline's
//! phase 1): a tab becomes spaces up to the next multiple of the tab width
//! in columns, a column being one cell of `editor-text` (a character; a
//! carriage return and its line feed are never in a segment). So the
//! shaper never sees a tab and needs no tab stops, which Parley does not
//! have. On a monospace font the glyph after a tab is at the stop in
//! pixels; on a proportional font it is at the stop counted in spaces,
//! which is the known limit of this choice.
//!
//! **A long row is cut into segments** of at most [`SEGMENT_BYTES`]: each
//! cut is at the last character boundary at or before a multiple of it,
//! counted from the row's start. Each segment is shaped and broken on its
//! own and starts a new visual line, and tab columns restart at its start.
//! So laying out the rows around a position of a row of N bytes costs the
//! segments those rows touch, not N; the forced break every
//! [`SEGMENT_BYTES`] on such a row is the price. What the shaper is handed
//! is a segment with its tabs expanded, so a segment of tabs alone is up
//! to the tab width times [`SEGMENT_BYTES`] long.
//!
//! **A row's content** is its bytes without its line feed and without the
//! carriage return before that line feed. A carriage return alone is a
//! character like any other.
//!
//! A point of this layer is a [`TabPoint`]: a row, a segment of it and a
//! byte column in that segment's expanded text. A position between a
//! carriage return and its line feed is the row's end: it converts to the
//! point of the content's end, which converts back to the content's end.

use std::ops::Range;

use editor_text::Snapshot;

use crate::layer::{Bias, Layer, LayerEdit};

/// The tab width a layout starts with, in columns.
pub const DEFAULT_TAB_WIDTH: usize = 8;

/// The longest a segment of a row is, in bytes.
pub const SEGMENT_BYTES: usize = 4096;

/// A point of the tab layer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct TabPoint {
    /// The buffer row.
    pub row: usize,
    /// The segment of the row.
    pub segment: usize,
    /// The byte offset in the segment's expanded text.
    pub column: usize,
}

/// One tab of an [`Expanded`] text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Tab {
    /// Its byte offset in the source.
    offset: usize,
    /// Where its spaces start in the expanded text.
    start: usize,
    /// Where they end.
    end: usize,
}

/// A text with its tabs expanded, and the way between its offsets and the
/// source's.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Expanded {
    /// The expanded text.
    text: String,
    /// Its tabs, in order.
    tabs: Vec<Tab>,
}

/// `source` with each tab expanded into spaces up to the next multiple of
/// `tab_width` columns, columns counted in characters from its start. A
/// tab width of 0 is taken as 1.
pub fn expand(source: &str, tab_width: usize) -> Expanded {
    let tab_width = tab_width.max(1);
    let mut text = String::with_capacity(source.len());
    let mut tabs = Vec::new();
    let mut column = 0;
    for (offset, character) in source.char_indices() {
        if character == '\t' {
            let spaces = tab_width - column % tab_width;
            let start = text.len();
            text.extend(std::iter::repeat_n(' ', spaces));
            tabs.push(Tab {
                offset,
                start,
                end: text.len(),
            });
            column += spaces;
        } else {
            text.push(character);
            column += 1;
        }
    }
    Expanded { text, tabs }
}

impl Expanded {
    /// The expanded text.
    pub fn text(&self) -> &str {
        &self.text
    }

    /// The offset in the expanded text of the source's offset `offset`,
    /// which is a character boundary of the source.
    pub fn column(&self, offset: usize) -> usize {
        let before = self.tabs.partition_point(|tab| tab.offset < offset);
        match before.checked_sub(1).map(|index| self.tabs[index]) {
            Some(tab) => tab.end + (offset - tab.offset - 1),
            None => offset,
        }
    }

    /// The source's offset at the expanded text's offset `column`. Inside a
    /// tab's spaces it is the tab's offset with [`Bias::Before`] and the
    /// offset after the tab with [`Bias::After`].
    pub fn offset(&self, column: usize, bias: Bias) -> usize {
        let before = self.tabs.partition_point(|tab| tab.end <= column);
        if let Some(tab) = self.tabs.get(before)
            && tab.start < column
        {
            return match bias {
                Bias::Before => tab.offset,
                Bias::After => tab.offset + 1,
            };
        }
        match before.checked_sub(1).map(|index| self.tabs[index]) {
            Some(tab) => tab.offset + 1 + (column - tab.end),
            None => column,
        }
    }
}

/// The content of `row`: its bytes without its line feed and without the
/// carriage return before that line feed. `None` when the text has no such
/// row.
pub fn row_content(snapshot: &Snapshot, row: usize) -> Option<Range<usize>> {
    let range = snapshot.row_range(row)?;
    let before_a_line_feed = range.end < snapshot.len();
    let ends_in_a_return = before_a_line_feed
        && range.end > range.start
        && snapshot
            .slice_to_string(range.end - 1..range.end)
            .as_deref()
            == Some("\r");
    Some(range.start..range.end - usize::from(ends_in_a_return))
}

/// The last character boundary of `snapshot` at or before `offset`.
fn boundary_at_or_before(snapshot: &Snapshot, offset: usize) -> usize {
    let mut at = offset.min(snapshot.len());
    while !snapshot.is_char_boundary(at) {
        at -= 1;
    }
    at
}

/// Where the cut before segment `index` of the content `content` is: its
/// start for segment 0, and otherwise the last character boundary at or
/// before `content.start + index * SEGMENT_BYTES`, or `None` past the
/// content's last segment.
fn cut(snapshot: &Snapshot, content: &Range<usize>, index: usize) -> Option<usize> {
    let at = content
        .start
        .checked_add(index.checked_mul(SEGMENT_BYTES)?)?;
    if index == 0 {
        Some(content.start)
    } else if at < content.end {
        Some(boundary_at_or_before(snapshot, at))
    } else {
        None
    }
}

/// How many segments the content `content` of a row is cut into: at least
/// one.
pub fn segment_count(snapshot: &Snapshot, content: &Range<usize>) -> usize {
    let _ = snapshot;
    let len = content.end.saturating_sub(content.start);
    len.saturating_sub(1) / SEGMENT_BYTES + 1
}

/// The bytes of segment `index` of the content `content`. `None` past its
/// last segment.
pub fn segment_range(
    snapshot: &Snapshot,
    content: &Range<usize>,
    index: usize,
) -> Option<Range<usize>> {
    let start = cut(snapshot, content, index)?;
    let end = cut(snapshot, content, index + 1).unwrap_or(content.end);
    Some(start..end.max(start))
}

/// The segment of the content `content` that holds the position `offset`:
/// a position at a cut is the start of the later segment, and the content's
/// end, and any offset past it, is in the last.
pub fn segment_of(snapshot: &Snapshot, content: &Range<usize>, offset: usize) -> usize {
    let last = segment_count(snapshot, content) - 1;
    let guess = (offset.saturating_sub(content.start) / SEGMENT_BYTES).min(last);
    // The cut after `guess` is at or before the multiple after it, so the
    // position may already be past it.
    match cut(snapshot, content, guess + 1) {
        Some(next) if offset >= next => guess + 1,
        _ => guess,
    }
}

/// The tab layer's snapshot: a buffer snapshot read with a tab width.
#[derive(Clone)]
pub struct TabSnapshot {
    /// The buffer's snapshot.
    buffer: Snapshot,
    /// The tab width, in columns.
    tab_width: usize,
}

impl TabSnapshot {
    /// `buffer` read with tabs `tab_width` columns wide.
    pub fn new(buffer: Snapshot, tab_width: usize) -> Self {
        Self { buffer, tab_width }
    }

    /// The buffer's snapshot.
    pub fn buffer(&self) -> &Snapshot {
        &self.buffer
    }

    /// The tab width, in columns.
    pub fn tab_width(&self) -> usize {
        self.tab_width
    }

    /// Segment `segment` of row `row`: its bytes in the buffer, and its
    /// text expanded. `None` when there is no such segment.
    pub fn segment(&self, row: usize, segment: usize) -> Option<(Range<usize>, Expanded)> {
        let content = row_content(&self.buffer, row)?;
        let bytes = segment_range(&self.buffer, &content, segment)?;
        let source = self.buffer.slice_to_string(bytes.clone())?;
        Some((bytes, expand(&source, self.tab_width)))
    }

    /// The point at the buffer position `offset`. `None` when `offset` is
    /// not a position of the buffer.
    pub fn to_tab(&self, offset: usize) -> Option<TabPoint> {
        let row = self.buffer.offset_to_point(offset)?.row;
        let content = row_content(&self.buffer, row)?;
        let segment = segment_of(&self.buffer, &content, offset);
        let (bytes, expanded) = self.segment(row, segment)?;
        let column = expanded.column(offset.min(bytes.end) - bytes.start);
        Some(TabPoint {
            row,
            segment,
            column,
        })
    }

    /// The buffer position at `point`, by [`Expanded::offset`]'s rule for
    /// a column inside a tab. `None` when the buffer has no such row or
    /// segment, or the column is past the segment's expanded text or inside
    /// a character of it.
    pub fn to_buffer(&self, point: TabPoint, bias: Bias) -> Option<usize> {
        let (bytes, expanded) = self.segment(point.row, point.segment)?;
        if !expanded.text().is_char_boundary(point.column) {
            return None;
        }
        Some(bytes.start + expanded.offset(point.column, bias))
    }

    /// The point at the end of row `row`'s last segment.
    fn row_end(&self, row: usize) -> Option<TabPoint> {
        let content = row_content(&self.buffer, row)?;
        let segment = segment_count(&self.buffer, &content) - 1;
        let (_, expanded) = self.segment(row, segment)?;
        Some(TabPoint {
            row,
            segment,
            column: expanded.text().len(),
        })
    }
}

/// The tab layer: the buffer below, a tab width.
#[derive(Clone)]
pub struct TabLayer {
    /// The snapshot last taken.
    snapshot: TabSnapshot,
}

impl TabLayer {
    /// A tab layer over `buffer` with tabs `tab_width` columns wide.
    pub fn new(buffer: Snapshot, tab_width: usize) -> Self {
        Self {
            snapshot: TabSnapshot::new(buffer, tab_width),
        }
    }

    /// A tab layer that last took `snapshot`.
    pub fn over(snapshot: TabSnapshot) -> Self {
        Self { snapshot }
    }

    /// The snapshot last taken.
    pub fn snapshot(&self) -> &TabSnapshot {
        &self.snapshot
    }
}

impl Layer for TabLayer {
    type Below = Snapshot;
    type BelowPoint = usize;
    type Snapshot = TabSnapshot;
    type Point = TabPoint;

    /// An edit of the buffer is an edit of the tab layer from its start's
    /// point to the end of its end's row: every tab after it on that row
    /// may be expanded differently, and a cut after it moved.
    fn sync(
        &mut self,
        below: &Snapshot,
        edits: &[LayerEdit<usize>],
    ) -> (TabSnapshot, Vec<LayerEdit<TabPoint>>) {
        let tab_width = self.snapshot.tab_width;
        let old = std::mem::replace(
            &mut self.snapshot,
            TabSnapshot::new(below.clone(), tab_width),
        );
        let new = &self.snapshot;
        let mut out: Vec<LayerEdit<TabPoint>> = Vec::with_capacity(edits.len());
        for edit in edits {
            let points = (|| {
                let old_start = old.to_tab(edit.old.start)?;
                let old_end = old.row_end(old.to_tab(edit.old.end)?.row)?;
                let new_start = new.to_tab(edit.new.start)?;
                let new_end = new.row_end(new.to_tab(edit.new.end)?.row)?;
                Some(LayerEdit {
                    old: old_start..old_end,
                    new: new_start..new_end,
                })
            })();
            let Some(edit) = points else { continue };
            match out.last_mut() {
                Some(last) if last.old.end >= edit.old.start => {
                    last.old.end = last.old.end.max(edit.old.end);
                    last.new.end = last.new.end.max(edit.new.end);
                }
                _ => out.push(edit),
            }
        }
        (new.clone(), out)
    }

    fn to_layer(&self, point: usize, _bias: Bias) -> Option<TabPoint> {
        self.snapshot.to_tab(point)
    }

    fn to_below(&self, point: TabPoint, bias: Bias) -> Option<usize> {
        self.snapshot.to_buffer(point, bias)
    }
}

#[cfg(test)]
mod tests {
    use editor_text::Text;

    use super::{
        Bias, Expanded, SEGMENT_BYTES, TabLayer, TabPoint, expand, row_content, segment_count,
        segment_of, segment_range,
    };
    use crate::layer::{Layer, LayerEdit};

    /// The expanded text of `source` with tab width 4.
    fn expanded(source: &str) -> Expanded {
        expand(source, 4)
    }

    #[test]
    fn a_tab_becomes_spaces_up_to_the_next_stop() {
        assert_eq!(expanded("a\tb").text(), "a   b");
        assert_eq!(expanded("abcd\te").text(), "abcd    e");
        assert_eq!(expanded("\t\tx").text(), "        x");
    }

    #[test]
    fn columns_are_counted_in_characters_not_bytes() {
        // é is two bytes and one column, so the tab takes three columns.
        assert_eq!(expanded("é\tb").text(), "é   b");
    }

    #[test]
    fn an_offset_after_a_tab_is_moved_on_by_its_spaces() {
        let text = expanded("a\tb\tc");
        // a, the tab at 1, b at 2 and the tab at 3.
        assert_eq!(text.column(0), 0);
        assert_eq!(text.column(1), 1);
        assert_eq!(text.column(2), 4);
        assert_eq!(text.column(3), 5);
        assert_eq!(text.column(4), 8);
        assert_eq!(text.column(5), 9);
    }

    #[test]
    fn a_column_inside_a_tab_goes_back_to_the_tab_or_past_it_by_its_bias() {
        let text = expanded("a\tb");
        assert_eq!(text.offset(1, Bias::Before), 1);
        assert_eq!(text.offset(1, Bias::After), 1);
        assert_eq!(text.offset(2, Bias::Before), 1);
        assert_eq!(text.offset(3, Bias::After), 2);
        assert_eq!(text.offset(4, Bias::Before), 2);
    }

    #[test]
    fn a_row_ends_before_a_carriage_return_and_its_line_feed() {
        let snapshot = Text::from("ab\r\ncd\re\n").snapshot();
        assert_eq!(row_content(&snapshot, 0), Some(0..2));
        // A carriage return alone is a character.
        assert_eq!(row_content(&snapshot, 1), Some(4..8));
        assert_eq!(row_content(&snapshot, 2), Some(9..9));
        assert_eq!(row_content(&snapshot, 3), None);
    }

    #[test]
    fn a_long_row_is_cut_at_the_last_boundary_before_each_multiple() {
        // "é" is two bytes, so a cut at an odd byte moves back one.
        let row = format!("a{}", "é".repeat(SEGMENT_BYTES));
        let snapshot = Text::from(row.as_str()).snapshot();
        let content = row_content(&snapshot, 0).unwrap();
        assert_eq!(segment_count(&snapshot, &content), 3);
        assert_eq!(segment_range(&snapshot, &content, 0), Some(0..4095));
        assert_eq!(
            segment_range(&snapshot, &content, 1),
            Some(4095..2 * SEGMENT_BYTES - 1)
        );
        assert_eq!(
            segment_range(&snapshot, &content, 2),
            Some(2 * SEGMENT_BYTES - 1..row.len())
        );
        assert_eq!(segment_range(&snapshot, &content, 3), None);
        // A position at a cut is in the later segment, the end in the last.
        assert_eq!(segment_of(&snapshot, &content, 4093), 0);
        assert_eq!(segment_of(&snapshot, &content, 4095), 1);
        assert_eq!(segment_of(&snapshot, &content, row.len()), 2);
    }

    #[test]
    fn a_row_of_exactly_one_segment_is_not_cut() {
        let snapshot = Text::from("x".repeat(SEGMENT_BYTES).as_str()).snapshot();
        let content = row_content(&snapshot, 0).unwrap();
        assert_eq!(segment_count(&snapshot, &content), 1);
        let empty = Text::from("").snapshot();
        assert_eq!(segment_count(&empty, &row_content(&empty, 0).unwrap()), 1);
    }

    #[test]
    fn tab_columns_restart_at_a_segment() {
        let row = format!("{}\tb", "a".repeat(SEGMENT_BYTES + 1));
        let layer = TabLayer::new(Text::from(row.as_str()).snapshot(), 4);
        let (_, second) = layer.snapshot().segment(0, 1).unwrap();
        // The second segment is "a\tb": the tab is at its column 1.
        assert_eq!(second.text(), "a   b");
    }

    #[test]
    fn the_position_between_a_return_and_its_line_feed_is_the_rows_end() {
        let layer = TabLayer::new(Text::from("a\tb\r\nc").snapshot(), 4);
        let end = TabPoint {
            row: 0,
            segment: 0,
            column: 5,
        };
        assert_eq!(layer.to_layer(3, Bias::Before), Some(end));
        assert_eq!(layer.to_layer(4, Bias::Before), Some(end));
        assert_eq!(layer.to_below(end, Bias::Before), Some(3));
    }

    #[test]
    fn an_edit_of_the_buffer_is_an_edit_to_its_rows_end_in_the_tab_layer() {
        let mut text = Text::from("ab\tc\nd");
        let mut layer = TabLayer::new(text.snapshot(), 4);
        let before = text.snapshot().revision();
        text.replace(1..1, "x").unwrap();
        let patch = text.changes_since(before).unwrap();
        let edits: Vec<LayerEdit<usize>> = patch
            .edits
            .iter()
            .map(|edit| LayerEdit {
                old: edit.old.start..edit.old.end,
                new: edit.new.start..edit.new.end,
            })
            .collect();
        let (snapshot, out) = layer.sync(&text.snapshot(), &edits);
        assert_eq!(snapshot.segment(0, 0).unwrap().1.text(), "axb c");
        let point = |column| TabPoint {
            row: 0,
            segment: 0,
            column,
        };
        assert_eq!(
            out,
            vec![LayerEdit {
                old: point(1)..point(5),
                new: point(1)..point(5),
            }]
        );
    }
}
