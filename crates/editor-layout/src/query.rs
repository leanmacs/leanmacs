//! The two layout queries the editor asks in the same call: the rows a view
//! shows from its scroll anchor, and the position some visual lines away
//! from a position. Both lay out on demand whatever they reach.
//!
//! They answer by layout's rules ([`line`](mod@crate::line)): a position at
//! a wrap is the start of the later visual line, only a row's last visual
//! line holds the row's end, and the position between a carriage return
//! and its line feed is the row's end. A move aims for an x (Vim's
//! "curswant"): the glyph the x is in, or past a line's last glyph its end
//! on the line that holds the row's end and its last glyph on any other.
//!
//! A refusal is [`QueryError::BadPosition`] for an offset that is not a
//! position of the text. An unknown snapshot is the binding's refusal:
//! layout is handed a snapshot or nothing.

use std::ops::Range;
use std::sync::Arc;

use editor_text::Snapshot;

use crate::line::LineEntry;
use crate::shaper::{FontId, Shaper};
use crate::tabs::{row_content, segment_of, segment_range};
use crate::wrap::{Outcome, WrapLayer};

/// One visual row: the bytes from `start` up to `stop`, without its line
/// break.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RowRange {
    /// The byte offset of its first character.
    pub start: usize,
    /// The byte offset where its characters stop.
    pub stop: usize,
}

/// Where a move went.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Moved {
    /// The position it reached.
    pub position: usize,
    /// The x it aimed for, to pass to the next move.
    pub goal: f32,
}

/// Why a query was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QueryError {
    /// An offset is not a position of the text.
    BadPosition,
}

/// A visual line of a text: a row, a segment of it, a line of that.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct Visual {
    /// The buffer row.
    pub row: usize,
    /// The segment of the row.
    pub segment: usize,
    /// The visual line of the segment.
    pub line: usize,
}

/// Walks the visual lines of one text, laying out each segment it reaches
/// in a wrap layer, and reports how it got each one.
pub(crate) struct Walker<'a, S: Shaper> {
    /// The shaper.
    pub shaper: &'a S,
    /// The text's wrap layer.
    pub wrap: &'a mut WrapLayer<S::Shaped>,
    /// The spans in another font, by absolute bytes, in order.
    pub fonts: &'a [(Range<usize>, FontId)],
    /// Told how each segment was got.
    pub outcome: &'a mut dyn FnMut(Outcome),
}

impl<S: Shaper> Walker<'_, S> {
    /// The text.
    pub fn snapshot(&self) -> Snapshot {
        self.wrap.tabs().buffer().clone()
    }

    /// `row`'s `segment`, laid out.
    pub fn entry(&mut self, row: usize, segment: usize) -> Option<Arc<LineEntry<S::Shaped>>> {
        let fonts = if self.fonts.is_empty() {
            Vec::new()
        } else {
            let snapshot = self.wrap.tabs().buffer();
            let content = row_content(snapshot, row)?;
            let bytes = segment_range(snapshot, &content, segment)?;
            relative_spans(self.fonts, &bytes)
        };
        let (entry, outcome) = self.wrap.entry(self.shaper, row, segment, &fonts)?;
        (self.outcome)(outcome);
        Some(entry)
    }

    /// Where `row` starts.
    fn row_start(&self, row: usize) -> usize {
        self.wrap
            .tabs()
            .buffer()
            .row_range(row)
            .map_or(0, |range| range.start)
    }

    /// The visual line that holds the position `offset`, and the x of it.
    pub fn locate(&mut self, offset: usize) -> Result<(Visual, f32), QueryError> {
        let snapshot = self.snapshot();
        if offset > snapshot.len() || !snapshot.is_char_boundary(offset) {
            return Err(QueryError::BadPosition);
        }
        let row = snapshot
            .offset_to_point(offset)
            .ok_or(QueryError::BadPosition)?
            .row;
        let content = row_content(&snapshot, row).ok_or(QueryError::BadPosition)?;
        let segment = segment_of(&snapshot, &content, offset);
        let entry = self.entry(row, segment).ok_or(QueryError::BadPosition)?;
        let relative = offset - content.start;
        let line = entry.line_of(relative);
        Ok((Visual { row, segment, line }, entry.x_of(line, relative)))
    }

    /// The visual line after `visual`, if there is one.
    pub fn next(&mut self, visual: Visual) -> Option<Visual> {
        let entry = self.entry(visual.row, visual.segment)?;
        if visual.line + 1 < entry.lines().len() {
            return Some(Visual {
                line: visual.line + 1,
                ..visual
            });
        }
        if visual.segment + 1 < self.wrap.segments(visual.row)? {
            return Some(Visual {
                segment: visual.segment + 1,
                line: 0,
                ..visual
            });
        }
        (visual.row + 1 < self.wrap.tabs().buffer().row_count()).then_some(Visual {
            row: visual.row + 1,
            segment: 0,
            line: 0,
        })
    }

    /// The visual line before `visual`, if there is one.
    pub fn previous(&mut self, visual: Visual) -> Option<Visual> {
        if visual.line > 0 {
            return Some(Visual {
                line: visual.line - 1,
                ..visual
            });
        }
        let (row, segment) = if visual.segment > 0 {
            (visual.row, visual.segment - 1)
        } else if visual.row > 0 {
            (visual.row - 1, self.wrap.segments(visual.row - 1)? - 1)
        } else {
            return None;
        };
        let lines = self.entry(row, segment)?.lines().len();
        Some(Visual {
            row,
            segment,
            line: lines - 1,
        })
    }

    /// The bytes of `visual`, without its line break.
    pub fn range(&mut self, visual: Visual) -> RowRange {
        let start = self.row_start(visual.row);
        let bytes = self
            .entry(visual.row, visual.segment)
            .and_then(|entry| entry.line_bytes(visual.line))
            .unwrap_or(0..0);
        RowRange {
            start: start + bytes.start,
            stop: start + bytes.end,
        }
    }

    /// How tall `visual` is.
    pub fn height(&mut self, visual: Visual) -> f32 {
        self.entry(visual.row, visual.segment)
            .and_then(|entry| entry.lines().get(visual.line).map(|line| line.height))
            .unwrap_or(0.0)
    }

    /// The visual lines from the one that holds `anchor`, as many as fit
    /// `height` pixels whole, fewer at the end of the text.
    pub fn rows_shown(&mut self, height: f32, anchor: usize) -> Result<Vec<Visual>, QueryError> {
        let (mut visual, _) = self.locate(anchor)?;
        let mut rows = Vec::new();
        let mut used = 0.0;
        loop {
            let tall = self.height(visual);
            if used + tall > height {
                break;
            }
            used += tall;
            rows.push(visual);
            match self.next(visual) {
                Some(next) => visual = next,
                None => break,
            }
        }
        Ok(rows)
    }

    /// The position `lines` visual lines from `position`, aiming for
    /// `goal`, or for the position's own x when there is none.
    pub fn lines_from(
        &mut self,
        position: usize,
        lines: i64,
        goal: Option<f32>,
    ) -> Result<Moved, QueryError> {
        let (mut visual, x) = self.locate(position)?;
        let goal = goal.unwrap_or(x);
        for _ in 0..lines.unsigned_abs() {
            let step = if lines > 0 {
                self.next(visual)
            } else {
                self.previous(visual)
            };
            match step {
                Some(next) => visual = next,
                None => break,
            }
        }
        let entry = self
            .entry(visual.row, visual.segment)
            .ok_or(QueryError::BadPosition)?;
        Ok(Moved {
            position: self.row_start(visual.row) + entry.offset_at(visual.line, goal),
            goal,
        })
    }
}

/// The spans of `fonts` (absolute bytes) that touch `bytes`, clipped to it
/// and made relative to its start. On an empty range, a span that starts
/// there.
pub(crate) fn relative_spans(
    fonts: &[(Range<usize>, FontId)],
    bytes: &Range<usize>,
) -> Vec<(Range<usize>, FontId)> {
    fonts
        .iter()
        .filter(|(span, _)| {
            (span.start < bytes.end && bytes.start < span.end)
                || (bytes.is_empty() && span.start == bytes.start)
        })
        .map(|(span, font)| {
            let start = span.start.max(bytes.start) - bytes.start;
            let end = span.end.min(bytes.end).max(span.start.max(bytes.start)) - bytes.start;
            (start..end, *font)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use editor_text::Text;

    use super::{Moved, QueryError, RowRange};
    use crate::Layout;
    use crate::shaper::fake::CellShaper;

    /// A layout on cells 10 by 16.
    fn layout() -> Layout<CellShaper> {
        Layout::new(CellShaper::new(10.0, 16.0))
    }

    /// The rows of `text` a view `columns` cells wide and `rows` tall shows
    /// from `anchor`, as pairs.
    fn rows(text: &str, columns: u32, rows: u32, anchor: usize) -> Vec<(usize, usize)> {
        let snapshot = Text::from(text).snapshot();
        layout()
            .rows_shown(&snapshot, columns as f32 * 10.0, rows as f32 * 16.0, anchor)
            .unwrap()
            .into_iter()
            .map(|RowRange { start, stop }| (start, stop))
            .collect()
    }

    /// Where `position` of `text` goes `lines` down in a view `columns`
    /// wide, aiming for `goal`.
    fn moved(text: &str, columns: u32, position: usize, lines: i64, goal: Option<f32>) -> Moved {
        let snapshot = Text::from(text).snapshot();
        layout()
            .lines_from(&snapshot, columns as f32 * 10.0, position, lines, goal)
            .unwrap()
    }

    /// Just the position of [`moved`].
    fn to(text: &str, columns: u32, position: usize, lines: i64) -> usize {
        moved(text, columns, position, lines, None).position
    }

    #[test]
    fn a_view_shows_the_rows_that_fit_from_its_anchor() {
        assert_eq!(
            rows("ab\ncd\nef\ngh", 4, 3, 3),
            vec![(3, 5), (6, 8), (9, 11)]
        );
        assert_eq!(rows("ab\ncd", 4, 10, 0), vec![(0, 2), (3, 5)]);
        // A view shorter than a row shows none.
        let snapshot = Text::from("ab").snapshot();
        assert_eq!(layout().rows_shown(&snapshot, 40.0, 15.0, 0), Ok(vec![]));
    }

    #[test]
    fn a_wrapped_line_is_a_row_per_visual_line_and_an_anchor_starts_its_row() {
        assert_eq!(rows("abcdefgh\nij", 4, 3, 0), vec![(0, 4), (4, 8), (9, 11)]);
        assert_eq!(rows("abcdefgh\nij", 4, 2, 6), vec![(4, 8), (9, 11)]);
        // A position at a wrap is the start of the later row.
        assert_eq!(rows("abcdefgh\nij", 4, 1, 4), vec![(4, 8)]);
    }

    #[test]
    fn an_empty_text_and_a_trailing_line_feed_are_an_empty_row() {
        assert_eq!(rows("", 4, 3, 0), vec![(0, 0)]);
        assert_eq!(rows("ab\n", 4, 3, 0), vec![(0, 2), (3, 3)]);
    }

    #[test]
    fn rows_are_byte_ranges_and_a_line_break_with_a_return_is_left_out() {
        assert_eq!(rows("é😀ab", 2, 3, 2), vec![(0, 6), (6, 8)]);
        assert_eq!(rows("ab\r\ncd", 4, 3, 0), vec![(0, 2), (4, 6)]);
        // The position between the return and the line feed is the row's
        // end, on its row.
        assert_eq!(rows("ab\r\ncd", 4, 1, 3), vec![(0, 2)]);
    }

    #[test]
    fn a_move_keeps_the_x_it_aimed_for_across_a_shorter_line() {
        let text = "abcdef\nab\nabcdefghij\nxyz";
        // From d (x 30) down: "ab" ends at x 20, so the move stops at its
        // end, and the goal 30 is passed back.
        assert_eq!(
            moved(text, 10, 3, 1, None),
            Moved {
                position: 9,
                goal: 30.0
            }
        );
        assert_eq!(moved(text, 10, 9, 1, Some(30.0)).position, 13);
        assert_eq!(to(text, 10, 3, 2), 13);
    }

    #[test]
    fn a_move_counts_visual_lines_of_wrapped_rows() {
        let text = "abcdef\nab\nabcdefghij\nxyz";
        // At width 4: abcd | ef | ab | abcd | efgh | ij | xyz.
        assert_eq!(to(text, 4, 1, 1), 5);
        // On a line that does not hold its row's end, the last glyph.
        assert_eq!(moved(text, 4, 6, -1, Some(100.0)).position, 3);
        // From b of "ab" (x 10) three lines down is j of "ij", and back.
        assert_eq!(to(text, 4, 8, 3), 19);
        assert_eq!(to(text, 4, 19, -3), 8);
    }

    #[test]
    fn a_move_past_the_first_or_the_last_line_stops_there() {
        let text = "abcdef\nab\nabcdefghij\nxyz";
        assert_eq!(to(text, 4, 9, -5), 2);
        assert_eq!(to(text, 4, 1, -1), 1);
        assert_eq!(to(text, 4, 12, 9), 23);
        assert_eq!(to(text, 4, 22, 1), 22);
        assert_eq!(to(text, 4, 15, 0), 15);
    }

    #[test]
    fn a_move_from_between_a_return_and_its_line_feed_is_from_the_rows_end() {
        assert_eq!(
            moved("abc\r\nabcdef", 10, 4, 1, None),
            Moved {
                position: 8,
                goal: 30.0
            }
        );
    }

    #[test]
    fn an_offset_that_is_not_a_position_is_refused() {
        let snapshot = Text::from("é\nab").snapshot();
        let mut layout = layout();
        assert_eq!(
            layout.rows_shown(&snapshot, 40.0, 16.0, 1),
            Err(QueryError::BadPosition)
        );
        assert_eq!(
            layout.rows_shown(&snapshot, 40.0, 16.0, 6),
            Err(QueryError::BadPosition)
        );
        assert_eq!(
            layout.lines_from(&snapshot, 40.0, 1, 1, None),
            Err(QueryError::BadPosition)
        );
    }
}
