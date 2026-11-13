//! Edits: what a transaction changed, as ranges of the text before it and
//! of the text after it, with no text.

use std::ops::Range;

use crate::point::Point;
use crate::snapshot::Snapshot;

/// A range of one text, as byte offsets and as points with their columns in
/// bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Span {
    /// The offset the range starts at.
    pub start: usize,
    /// The offset the range ends at, not included.
    pub end: usize,
    /// The point of `start`.
    pub start_point: Point,
    /// The point of `end`.
    pub end_point: Point,
}

impl Span {
    /// The span of `range` in `snapshot`. `None` unless both ends are
    /// positions of it.
    pub(crate) fn of(snapshot: &Snapshot, range: Range<usize>) -> Option<Self> {
        Some(Self {
            start: range.start,
            end: range.end,
            start_point: snapshot.offset_to_point(range.start)?,
            end_point: snapshot.offset_to_point(range.end)?,
        })
    }

    /// Whether the range holds no byte.
    pub fn is_empty(&self) -> bool {
        self.start == self.end
    }
}

/// One changed range: the bytes of `old`, a range of the text before, were
/// replaced by the bytes of `new`, a range of the text after. An insertion
/// has an empty `old` and a deletion an empty `new`.
///
/// Both spans carry their points, four in all, because the same change
/// starts at different points in the two texts when another change of the
/// same transaction comes before it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Edit {
    /// The range that was replaced, in the text before.
    pub old: Span,
    /// The range that replaced it, in the text after.
    pub new: Span,
}

/// An edit in the form an incremental parser takes it (tree-sitter's
/// `InputEdit`): a start, and the end before and after, each as a byte
/// offset and as a point with its column in bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct InputEdit {
    /// Where the change starts.
    pub start_byte: usize,
    /// Where the replaced bytes ended, before the change.
    pub old_end_byte: usize,
    /// Where the bytes that replaced them end, after the change.
    pub new_end_byte: usize,
    /// The point of `start_byte`.
    pub start_point: Point,
    /// The point of `old_end_byte`, before the change.
    pub old_end_point: Point,
    /// The point of `new_end_byte`, after the change.
    pub new_end_point: Point,
}

impl Edit {
    /// This edit for a parser that is given the edits of one entry, or of
    /// one patch, in order.
    ///
    /// By the time the parser is given this edit it has been given the ones
    /// before it, so its tree is of the new text up to this edit and of the
    /// old text from it. The start is therefore the new start, and the old
    /// end is the new start moved on by the extent of the old range.
    pub fn input_edit(&self) -> InputEdit {
        // The fields are public, so the arithmetic saturates: an edit that
        // was not read from a log gives a wrong answer, not a panic.
        let old = &self.old;
        let rows = old.end_point.row.saturating_sub(old.start_point.row);
        let old_end_point = if rows == 0 {
            let columns = old.end_point.column.saturating_sub(old.start_point.column);
            Point::new(
                self.new.start_point.row,
                self.new.start_point.column.saturating_add(columns),
            )
        } else {
            Point::new(
                self.new.start_point.row.saturating_add(rows),
                old.end_point.column,
            )
        };
        InputEdit {
            start_byte: self.new.start,
            old_end_byte: self
                .new
                .start
                .saturating_add(old.end.saturating_sub(old.start)),
            new_end_byte: self.new.end,
            start_point: self.new.start_point,
            old_end_point,
            new_end_point: self.new.end_point,
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// The span from `start` to `end`, whose points are the two (row,
    /// column) pairs.
    pub(crate) fn span(
        start: usize,
        end: usize,
        start_point: (usize, usize),
        end_point: (usize, usize),
    ) -> Span {
        Span {
            start,
            end,
            start_point: Point::new(start_point.0, start_point.1),
            end_point: Point::new(end_point.0, end_point.1),
        }
    }

    #[test]
    fn the_span_of_a_range_has_the_points_of_its_ends() {
        // Row 1 starts at 8; "é" is the bytes 1 and 2.
        let snapshot = crate::Text::from("héllo\r\nwörld").snapshot();

        assert_eq!(
            Span::of(&snapshot, 3..11),
            Some(span(3, 11, (0, 3), (1, 3)))
        );
        assert_eq!(Span::of(&snapshot, 8..8), Some(span(8, 8, (1, 0), (1, 0))));
        assert_eq!(Span::of(&snapshot, 2..3), None);
        assert_eq!(Span::of(&snapshot, 3..15), None);
    }

    #[test]
    fn a_span_is_empty_when_it_holds_no_byte() {
        assert!(span(3, 3, (0, 3), (0, 3)).is_empty());
        assert!(!span(3, 4, (0, 3), (1, 0)).is_empty());
    }

    #[test]
    fn the_parser_form_of_an_insertion_ends_where_it_starts_before_the_change() {
        let edit = Edit {
            old: span(3, 3, (0, 3), (0, 3)),
            new: span(3, 6, (0, 3), (1, 1)),
        };

        assert_eq!(
            edit.input_edit(),
            InputEdit {
                start_byte: 3,
                old_end_byte: 3,
                new_end_byte: 6,
                start_point: Point::new(0, 3),
                old_end_point: Point::new(0, 3),
                new_end_point: Point::new(1, 1),
            }
        );
    }

    #[test]
    fn the_parser_form_of_a_deletion_across_a_line_feed_ends_on_a_later_row_before_the_change() {
        let edit = Edit {
            old: span(5, 9, (0, 5), (1, 1)),
            new: span(5, 5, (0, 5), (0, 5)),
        };

        assert_eq!(
            edit.input_edit(),
            InputEdit {
                start_byte: 5,
                old_end_byte: 9,
                new_end_byte: 5,
                start_point: Point::new(0, 5),
                old_end_point: Point::new(1, 1),
                new_end_point: Point::new(0, 5),
            }
        );
    }

    #[test]
    fn the_parser_form_of_a_replacement_inside_a_row_stays_on_the_row() {
        let edit = Edit {
            old: span(11, 13, (1, 3), (1, 5)),
            new: span(11, 14, (1, 3), (1, 6)),
        };

        assert_eq!(
            edit.input_edit(),
            InputEdit {
                start_byte: 11,
                old_end_byte: 13,
                new_end_byte: 14,
                start_point: Point::new(1, 3),
                old_end_point: Point::new(1, 5),
                new_end_point: Point::new(1, 6),
            }
        );
    }

    #[test]
    fn the_parser_form_of_an_edit_no_log_gave_does_not_panic() {
        let backwards = Edit {
            old: span(9, 5, (usize::MAX, 9), (0, 0)),
            new: span(usize::MAX, 0, (usize::MAX, usize::MAX), (0, 0)),
        };

        assert_eq!(backwards.input_edit().start_byte, usize::MAX);
    }

    #[test]
    fn the_parser_form_starts_at_the_new_start_and_moves_the_old_end_by_the_old_extent() {
        // An edit after others of its transaction: it starts at 5 on row 0
        // of the old text and at 8 on row 1 of the new.
        let across_rows = Edit {
            old: span(5, 9, (0, 5), (1, 1)),
            new: span(8, 8, (1, 3), (1, 3)),
        };
        assert_eq!(
            across_rows.input_edit(),
            InputEdit {
                start_byte: 8,
                old_end_byte: 12,
                new_end_byte: 8,
                start_point: Point::new(1, 3),
                old_end_point: Point::new(2, 1),
                new_end_point: Point::new(1, 3),
            }
        );

        let within_a_row = Edit {
            old: span(11, 13, (1, 3), (1, 5)),
            new: span(10, 13, (1, 5), (1, 8)),
        };
        assert_eq!(
            within_a_row.input_edit(),
            InputEdit {
                start_byte: 10,
                old_end_byte: 12,
                new_end_byte: 13,
                start_point: Point::new(1, 5),
                old_end_point: Point::new(1, 7),
                new_end_point: Point::new(1, 8),
            }
        );
    }
}
