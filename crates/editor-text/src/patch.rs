//! Edits: what a transaction changed, as ranges of the text before it and
//! of the text after it, with no text.

use std::ops::Range;

use crate::point::Point;
use crate::snapshot::{Revision, Snapshot};

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

/// What changed in a text between two of its revisions, as one set of
/// edits ([`Text::changes_since`](crate::Text::changes_since)).
///
/// The old span of each edit is a range of the text at `from` and the new
/// span a range of the text at `to`. The edits are in order, and no two
/// overlap or touch, in either text: changes that came to overlap or touch
/// are one edit. Text that was inserted after `from` and deleted again by
/// `to` is in none.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Patch {
    /// The revision the patch starts from.
    pub from: Revision,
    /// The revision the patch reaches: the text's when it was asked.
    pub to: Revision,
    /// What changed, in order.
    pub edits: Vec<Edit>,
}

/// The edits that do `first` and then `then`: `first` is from one text to a
/// second, `then` from the second to a third, and the result from the
/// first to the third.
///
/// The walk is over the second text. Edits of `first`, by their new spans,
/// and of `then`, by their old spans, that overlap or touch there form a
/// cluster, and a cluster is one edit of the result. Where a cluster
/// starts or ends in text that one side kept, its place in that side's
/// outer text is found by moving on from the last place the two texts were
/// known to line up: a coordinate plus the extent between two later
/// coordinates of one text. That is exact for points, and nothing is ever
/// moved backwards across a line, which a point cannot be.
///
/// An edit left with both spans empty, text that `first` inserted and
/// `then` deleted, is dropped.
pub(crate) fn compose(first: &[Edit], then: &[Edit]) -> Vec<Edit> {
    let mut composed = Vec::with_capacity(first.len() + then.len());
    let (mut first, mut then) = (first.iter().peekable(), then.iter().peekable());
    // Where each side's two texts last lined up: just after the last edit
    // of that side the walk has passed. `first` is from the old text to
    // the middle one, and `then` from the middle one to the new.
    let (mut old_kept, mut middle_kept_by_first) = (Coordinate::START, Coordinate::START);
    let (mut middle_kept_by_then, mut new_kept) = (Coordinate::START, Coordinate::START);
    loop {
        // Where the next cluster starts in the middle text, and in each
        // outer text: at an edit's own start if the edit starts the
        // cluster, and otherwise in text that side kept.
        let from_first = first.peek().map(|edit| Coordinate::start(&edit.new));
        let from_then = then.peek().map(|edit| Coordinate::start(&edit.old));
        let start = match (from_first, from_then) {
            (Some(from_first), Some(from_then)) => from_first.min(from_then),
            (Some(start), None) | (None, Some(start)) => start,
            (None, None) => return composed,
        };
        let old_start = match first.peek() {
            Some(edit) if edit.new.start == start.offset => Coordinate::start(&edit.old),
            _ => old_kept.moved(middle_kept_by_first, start),
        };
        let new_start = match then.peek() {
            Some(edit) if edit.old.start == start.offset => Coordinate::start(&edit.new),
            _ => new_kept.moved(middle_kept_by_then, start),
        };
        // Take every edit that starts within the cluster or at its end.
        let mut end = start;
        let (mut has_first, mut has_then) = (false, false);
        loop {
            if let Some(edit) = first.next_if(|edit| edit.new.start <= end.offset) {
                end = end.max(Coordinate::end(&edit.new));
                old_kept = Coordinate::end(&edit.old);
                middle_kept_by_first = Coordinate::end(&edit.new);
                has_first = true;
            } else if let Some(edit) = then.next_if(|edit| edit.old.start <= end.offset) {
                end = end.max(Coordinate::end(&edit.old));
                middle_kept_by_then = Coordinate::end(&edit.old);
                new_kept = Coordinate::end(&edit.new);
                has_then = true;
            } else {
                break;
            }
        }
        // A side with no edit in the cluster kept all of it.
        let old_end = if has_first {
            old_kept.moved(middle_kept_by_first, end)
        } else {
            old_start.moved(start, end)
        };
        let new_end = if has_then {
            new_kept.moved(middle_kept_by_then, end)
        } else {
            new_start.moved(start, end)
        };
        let edit = Edit {
            old: Coordinate::span(old_start, old_end),
            new: Coordinate::span(new_start, new_end),
        };
        if !(edit.old.is_empty() && edit.new.is_empty()) {
            composed.push(edit);
        }
    }
}

/// A place in one text: an offset with its point.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Coordinate {
    /// The byte offset.
    offset: usize,
    /// The point of the offset.
    point: Point,
}

impl Coordinate {
    /// The start of every text.
    const START: Self = Self {
        offset: 0,
        point: Point::new(0, 0),
    };

    /// Where `span` starts.
    fn start(span: &Span) -> Self {
        Self {
            offset: span.start,
            point: span.start_point,
        }
    }

    /// Where `span` ends.
    fn end(span: &Span) -> Self {
        Self {
            offset: span.end,
            point: span.end_point,
        }
    }

    /// The span from `start` to `end`.
    fn span(start: Self, end: Self) -> Span {
        Span {
            start: start.offset,
            end: end.offset,
            start_point: start.point,
            end_point: end.point,
        }
    }

    /// The later of two places of one text.
    fn max(self, other: Self) -> Self {
        if other.offset > self.offset {
            other
        } else {
            self
        }
    }

    /// The earlier of two places of one text.
    fn min(self, other: Self) -> Self {
        if other.offset < self.offset {
            other
        } else {
            self
        }
    }

    /// This place moved on by the extent from `from` to `to`, two places of
    /// another text with `from` not after `to`. The bytes between them are
    /// the bytes that follow this place in its own text.
    ///
    /// Within a row the column moves on by the bytes; across rows the
    /// column is `to`'s, since both count from the same line feed.
    fn moved(self, from: Self, to: Self) -> Self {
        let rows = to.point.row - from.point.row;
        let point = if rows == 0 {
            Point::new(
                self.point.row,
                self.point.column + (to.point.column - from.point.column),
            )
        } else {
            Point::new(self.point.row + rows, to.point.column)
        };
        Self {
            offset: self.offset + (to.offset - from.offset),
            point,
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

    /// An edit of a text of one row, where a point is row 0 and the offset.
    fn flat(old: Range<usize>, new: Range<usize>) -> Edit {
        Edit {
            old: span(old.start, old.end, (0, old.start), (0, old.end)),
            new: span(new.start, new.end, (0, new.start), (0, new.end)),
        }
    }

    #[test]
    fn composing_with_no_edit_gives_the_other_patch() {
        let edits = [flat(2..3, 2..5), flat(8..10, 10..10)];

        assert_eq!(compose(&edits, &[]), edits);
        assert_eq!(compose(&[], &edits), edits);
        assert_eq!(compose(&[], &[]), []);
    }

    #[test]
    fn edits_that_are_apart_stay_two_each_moved_into_the_outer_texts() {
        // The first replaces one byte by three; the second deletes two
        // bytes further on, which were at 8 before the first.
        assert_eq!(
            compose(&[flat(2..3, 2..5)], &[flat(10..12, 10..10)]),
            [flat(2..3, 2..5), flat(8..10, 10..10)]
        );
        // The other way round: the second is before the first, whose new
        // range is at 8 once two bytes before it are gone.
        assert_eq!(
            compose(&[flat(10..11, 10..13)], &[flat(2..4, 2..2)]),
            [flat(2..4, 2..2), flat(10..11, 8..11)]
        );
    }

    #[test]
    fn edits_that_overlap_are_one() {
        // Four bytes are inserted at 2; then two of them and the two bytes
        // after them are replaced by one.
        assert_eq!(
            compose(&[flat(2..2, 2..6)], &[flat(4..8, 4..5)]),
            [flat(2..4, 2..5)]
        );
    }

    #[test]
    fn edits_that_touch_are_one() {
        // Two bytes are inserted at 2, and the byte after them is deleted.
        assert_eq!(
            compose(&[flat(2..2, 2..4)], &[flat(4..5, 4..4)]),
            [flat(2..3, 2..4)]
        );
        // Two bytes are inserted at 5, and the two before them deleted.
        assert_eq!(
            compose(&[flat(5..5, 5..7)], &[flat(3..5, 3..3)]),
            [flat(3..5, 3..5)]
        );
        // A deletion, and an insertion at the point it collapsed to.
        assert_eq!(
            compose(&[flat(3..6, 3..3)], &[flat(3..3, 3..4)]),
            [flat(3..6, 3..4)]
        );
    }

    #[test]
    fn text_that_is_inserted_and_then_deleted_is_in_no_edit() {
        assert_eq!(compose(&[flat(2..2, 2..5)], &[flat(2..5, 2..2)]), []);
        // Part of it: one byte of the three is left.
        assert_eq!(
            compose(&[flat(2..2, 2..5)], &[flat(3..5, 3..3)]),
            [flat(2..2, 2..3)]
        );
        // The edits around the cancelled one are kept.
        assert_eq!(
            compose(
                &[flat(0..1, 0..0), flat(3..3, 2..5), flat(9..9, 11..12)],
                &[flat(2..5, 2..2)]
            ),
            [flat(0..1, 0..0), flat(9..9, 8..9)]
        );
    }

    #[test]
    fn several_edits_of_the_second_inside_one_of_the_first_are_one() {
        // Ten bytes are inserted at 1. Of them, one is deleted, one is
        // replaced by two, and one more is inserted: eleven are left.
        assert_eq!(
            compose(
                &[flat(1..1, 1..11)],
                &[flat(2..3, 2..2), flat(5..6, 4..6), flat(9..9, 9..10)]
            ),
            [flat(1..1, 1..12)]
        );
    }

    #[test]
    fn several_edits_of_the_first_inside_one_of_the_second_are_one() {
        // A deletion, an insertion and a replacement, which make fourteen
        // bytes of eleven; then all fourteen are replaced by one.
        assert_eq!(
            compose(
                &[flat(1..2, 1..1), flat(4..4, 3..5), flat(8..9, 9..12)],
                &[flat(0..14, 0..1)]
            ),
            [flat(0..11, 0..1)]
        );
    }

    #[test]
    fn edits_that_are_apart_keep_their_points_across_a_line_feed() {
        // "ab\ncd\nef" becomes "aX\nYb\ncd\nef", which becomes
        // "aX\nYb\ncf".
        let first = [Edit {
            old: span(1, 1, (0, 1), (0, 1)),
            new: span(1, 4, (0, 1), (1, 1)),
        }];
        let then = [Edit {
            old: span(7, 10, (2, 1), (3, 1)),
            new: span(7, 7, (2, 1), (2, 1)),
        }];

        assert_eq!(
            compose(&first, &then),
            [
                Edit {
                    old: span(1, 1, (0, 1), (0, 1)),
                    new: span(1, 4, (0, 1), (1, 1)),
                },
                // "d\ne" was at 4 to 7, on rows 1 and 2, before the insert.
                Edit {
                    old: span(4, 7, (1, 1), (2, 1)),
                    new: span(7, 7, (2, 1), (2, 1)),
                },
            ]
        );
    }

    #[test]
    fn edits_that_overlap_keep_their_points_across_a_line_feed() {
        // "ab\ncd\nef" becomes "aX\nYb\ncd\nef", which becomes "aXd\nef".
        let first = [Edit {
            old: span(1, 1, (0, 1), (0, 1)),
            new: span(1, 4, (0, 1), (1, 1)),
        }];
        let then = [Edit {
            old: span(2, 7, (0, 2), (2, 1)),
            new: span(2, 2, (0, 2), (0, 2)),
        }];

        // "b\nc" became "X".
        assert_eq!(
            compose(&first, &then),
            [Edit {
                old: span(1, 4, (0, 1), (1, 1)),
                new: span(1, 2, (0, 1), (0, 2)),
            }]
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
