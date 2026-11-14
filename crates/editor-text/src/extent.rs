//! What a selection covers: its ranges read against a text.
//!
//! The ends of a range say where two cursors are. What is selected between
//! them depends on the selection's [`Shape`] and on the text: where a
//! character ends, where a row does. The crate docs have the table.

use std::ops::Range;

use crate::selection::{Selection, SelectionRange, Shape};
use crate::snapshot::Snapshot;

impl Snapshot {
    /// The ranges of bytes `selection` covers in this text, by its
    /// [`Shape`]:
    ///
    /// | Shape | Covers, for a range from `start` to `end` |
    /// |---|---|
    /// | [`Shape::Exclusive`] | `start..end` |
    /// | [`Shape::Inclusive`] | From `start` through the cell at `end` |
    /// | [`Shape::Line`] | From the start of `start`'s row to the end of `end`'s row, and through its line feed if it has one |
    /// | [`Shape::Block`] | For each row from `start`'s to `end`'s, one extent: with the anchor's and the head's columns counted in cells from their rows' starts, from the lower column through the cell at the higher, cut off at the row's content. A row too short for the lower column gives an empty extent at the end of its content |
    ///
    /// A cell is one character, or a carriage return and the line feed
    /// after it together; at the end of the text there is none, so a
    /// cursor there covers nothing. A row's content is its bytes without
    /// its line break. An end that is past its row's content is not moved:
    /// clamping is the caller's.
    ///
    /// The extents come back sorted by start and then by end, and two of
    /// them are one when the later starts before the earlier ends or both
    /// start at one offset. Extents that only touch stay two. An extent
    /// may be empty.
    ///
    /// `None` unless every end of every range is a position of the text.
    pub fn extents(&self, selection: &Selection) -> Option<Vec<Range<usize>>> {
        if !selection.fits(self) {
            return None;
        }
        let mut extents = Vec::with_capacity(selection.ranges().len());
        for range in selection.ranges() {
            let (start, end) = (range.start(), range.end());
            match selection.shape() {
                Shape::Exclusive => extents.push(start..end),
                Shape::Inclusive => extents.push(start..self.cell_end(end)),
                Shape::Line => {
                    let first = self.offset_to_point(start)?.row;
                    let last = self.offset_to_point(end)?.row;
                    extents.push(self.row_range(first)?.start..self.row_end(last)?);
                }
                Shape::Block => self.block(range, &mut extents)?,
            }
        }
        Some(merged(extents))
    }

    /// Where the row `row` ends, its line feed included if it has one:
    /// where the next row starts, or the end of the text. `None` when the
    /// text has no such row.
    fn row_end(&self, row: usize) -> Option<usize> {
        let end = self.row_range(row)?.end;
        // A row that ends before the text does ends at a line feed.
        Some(end + usize::from(end < self.len()))
    }

    /// Adds to `extents` what the block whose corners are the ends of
    /// `range` covers, an extent for each of its rows. `None` unless both
    /// ends are positions.
    fn block(&self, range: &SelectionRange, extents: &mut Vec<Range<usize>>) -> Option<()> {
        let anchor = self.offset_to_point(range.anchor)?;
        let head = self.offset_to_point(range.head)?;
        let one = self.cell_column(anchor.row, range.anchor)?;
        let other = self.cell_column(head.row, range.head)?;
        let (lower, higher) = (one.min(other), one.max(other));
        for row in anchor.row.min(head.row)..=anchor.row.max(head.row) {
            let content = self.row_content(row)?;
            // Walk the row's cells: to the lower column, and then through
            // the cell at the higher, stopping where the content does.
            let mut at = content.start;
            let mut column = 0;
            while column < lower && at < content.end {
                at = self.cell_end(at);
                column += 1;
            }
            let from = at;
            while column <= higher && at < content.end {
                at = self.cell_end(at);
                column += 1;
            }
            extents.push(from..at);
        }
        Some(())
    }
}

/// `extents` sorted by start and then by end, with every two that overlap
/// made one: the later starts before the earlier ends, or both start at
/// one offset.
fn merged(mut extents: Vec<Range<usize>>) -> Vec<Range<usize>> {
    extents.sort_unstable_by_key(|extent| (extent.start, extent.end));
    let mut merged: Vec<Range<usize>> = Vec::with_capacity(extents.len());
    for extent in extents {
        match merged.last_mut() {
            Some(last) if extent.start < last.end || extent.start == last.start => {
                last.end = last.end.max(extent.end);
            }
            _ => merged.push(extent),
        }
    }
    merged
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Text;

    /// What the selection of shape `shape` with `ranges`, given as anchor
    /// and head, covers in `text`.
    fn extents(text: &str, shape: Shape, ranges: &[(usize, usize)]) -> Option<Vec<Range<usize>>> {
        let ranges = ranges
            .iter()
            .map(|&(anchor, head)| SelectionRange::new(anchor, head))
            .collect();
        let selection = Selection::shaped(shape, ranges, 0).expect("at least one range");
        Text::from(text).snapshot().extents(&selection)
    }

    /// The one extent `start..end`, as [`extents`] gives it.
    fn one(start: usize, end: usize) -> Option<Vec<Range<usize>>> {
        Some(std::iter::once(start..end).collect())
    }

    /// What the normal-state cursor on the character at `offset` covers in
    /// `text`: an inclusive range with equal ends.
    fn cursor(text: &str, offset: usize) -> Option<Vec<Range<usize>>> {
        extents(text, Shape::Inclusive, &[(offset, offset)])
    }

    #[test]
    fn a_cursor_on_the_last_character_of_a_line_covers_it_and_not_the_line_break() {
        assert_eq!(cursor("ab\ncd", 1), one(1, 2));
        // With a carriage return and a line feed, the last character is
        // still "b".
        assert_eq!(cursor("ab\r\ncd", 1), one(1, 2));
        // The last line, which has no line break.
        assert_eq!(cursor("ab\ncd", 4), one(4, 5));
    }

    #[test]
    fn a_cursor_on_an_empty_line_covers_its_line_break() {
        assert_eq!(cursor("a\n\nb", 2), one(2, 3));
        assert_eq!(cursor("a\r\n\r\nb", 3), one(3, 5));
        assert_eq!(cursor("\nb", 0), one(0, 1));
    }

    #[test]
    fn a_cursor_at_the_end_of_the_buffer_covers_nothing() {
        // An empty text.
        assert_eq!(cursor("", 0), one(0, 0));
        // After the last character.
        assert_eq!(cursor("ab", 2), one(2, 2));
        // On the empty last row of a text that ends in a line feed.
        assert_eq!(cursor("ab\n", 3), one(3, 3));
        assert_eq!(cursor("ab\r\n", 4), one(4, 4));
    }

    #[test]
    fn a_cursor_on_a_line_break_covers_all_of_it() {
        assert_eq!(cursor("ab\ncd", 2), one(2, 3));
        assert_eq!(cursor("ab\r\ncd", 2), one(2, 4));
    }

    #[test]
    fn a_cursor_on_a_character_of_four_bytes_covers_the_four() {
        assert_eq!(cursor("a😀b", 1), one(1, 5));
    }

    #[test]
    fn an_exclusive_range_covers_from_its_lower_end_up_to_its_higher() {
        assert_eq!(extents("abcde", Shape::Exclusive, &[(1, 3)]), one(1, 3));
        assert_eq!(extents("abcde", Shape::Exclusive, &[(3, 1)]), one(1, 3));
        // A bar cursor covers nothing.
        assert_eq!(extents("abcde", Shape::Exclusive, &[(2, 2)]), one(2, 2));
    }

    #[test]
    fn an_inclusive_range_covers_both_its_ends_whichever_way_it_points() {
        assert_eq!(extents("abcde", Shape::Inclusive, &[(1, 3)]), one(1, 4));
        assert_eq!(extents("abcde", Shape::Inclusive, &[(3, 1)]), one(1, 4));
        // Through a character of two bytes, and through a line break.
        assert_eq!(extents("aéb", Shape::Inclusive, &[(0, 1)]), one(0, 3));
        assert_eq!(extents("ab\r\ncd", Shape::Inclusive, &[(4, 1)]), one(1, 5));
    }

    #[test]
    fn a_line_wise_range_covers_its_rows_and_the_line_feed_of_the_last() {
        let text = "ab\ncd\nef";

        // One row, wherever in it the ends are.
        assert_eq!(extents(text, Shape::Line, &[(4, 4)]), one(3, 6));
        assert_eq!(extents(text, Shape::Line, &[(3, 5)]), one(3, 6));
        // Several rows, in either direction.
        assert_eq!(extents(text, Shape::Line, &[(1, 4)]), one(0, 6));
        assert_eq!(extents(text, Shape::Line, &[(4, 1)]), one(0, 6));
        // The last row has no line feed: the extent stops at the text's
        // end.
        assert_eq!(extents(text, Shape::Line, &[(7, 7)]), one(6, 8));
        assert_eq!(extents(text, Shape::Line, &[(0, 8)]), one(0, 8));
    }

    #[test]
    fn a_line_wise_range_on_an_empty_row_covers_its_line_break() {
        assert_eq!(extents("a\n\nb", Shape::Line, &[(2, 2)]), one(2, 3));
        // The empty last row, and an empty text, have none.
        assert_eq!(extents("ab\n", Shape::Line, &[(3, 3)]), one(3, 3));
        assert_eq!(extents("", Shape::Line, &[(0, 0)]), one(0, 0));
    }

    #[test]
    fn a_line_wise_range_covers_both_bytes_of_a_carriage_return_and_line_feed() {
        assert_eq!(extents("ab\r\ncd", Shape::Line, &[(0, 0)]), one(0, 4));
        assert_eq!(extents("ab\r\ncd\r\n", Shape::Line, &[(5, 2)]), one(0, 8));
    }

    #[test]
    fn a_block_covers_the_columns_between_its_corners_on_each_of_its_rows() {
        let text = "abcd\nx\nabcd";
        let block = Some(vec![1..3, 6..6, 8..10]);

        // From column 1 of the first row to column 2 of the third: the row
        // between is too short, and gives an empty extent at its end.
        assert_eq!(extents(text, Shape::Block, &[(1, 9)]), block);
        assert_eq!(extents(text, Shape::Block, &[(9, 1)]), block);
        // The other two corners of the same rectangle.
        assert_eq!(extents(text, Shape::Block, &[(2, 8)]), block);
        assert_eq!(extents(text, Shape::Block, &[(8, 2)]), block);
    }

    #[test]
    fn a_block_is_cut_off_at_the_content_of_a_shorter_row() {
        // Columns 1 to 3: the second row has only columns 0 and 1.
        assert_eq!(
            extents("abcde\nxy\nabcde", Shape::Block, &[(1, 12)]),
            Some(vec![1..4, 7..8, 10..13])
        );
        // One row, and one cell.
        assert_eq!(extents("abcde", Shape::Block, &[(3, 1)]), one(1, 4));
        assert_eq!(extents("abcde", Shape::Block, &[(2, 2)]), one(2, 3));
        // An empty row inside the block, and a block on an empty text.
        assert_eq!(
            extents("ab\n\nab", Shape::Block, &[(0, 5)]),
            Some(vec![0..2, 3..3, 4..6])
        );
        assert_eq!(extents("", Shape::Block, &[(0, 0)]), one(0, 0));
    }

    #[test]
    fn a_block_counts_its_columns_in_cells_and_leaves_line_breaks_out() {
        // "é" is two bytes and one column.
        assert_eq!(
            extents("aéb\nabc", Shape::Block, &[(1, 7)]),
            Some(vec![1..4, 6..8])
        );
        // Rows that end in a carriage return and a line feed: neither
        // byte is content.
        assert_eq!(
            extents("abcd\r\nxy\r\nabcd", Shape::Block, &[(1, 12)]),
            Some(vec![1..3, 7..8, 11..13])
        );
        // A corner on a line break is past its row's content.
        assert_eq!(
            extents("ab\r\nabcd", Shape::Block, &[(2, 4)]),
            Some(vec![0..2, 4..7])
        );
    }

    #[test]
    fn the_extents_of_several_ranges_come_back_in_order() {
        assert_eq!(
            extents("abcdef", Shape::Inclusive, &[(4, 4), (0, 1)]),
            Some(vec![0..2, 4..5])
        );
        // Extents that only touch stay two.
        assert_eq!(
            extents("abcdef", Shape::Inclusive, &[(0, 1), (2, 3)]),
            Some(vec![0..2, 2..4])
        );
        assert_eq!(
            extents("ab\ncd\nef", Shape::Line, &[(7, 7), (0, 0)]),
            Some(vec![0..3, 6..8])
        );
    }

    #[test]
    fn extents_that_overlap_are_one() {
        // Two line-wise ranges on one row.
        assert_eq!(
            extents("abcd\nef", Shape::Line, &[(0, 0), (2, 3)]),
            one(0, 5)
        );
        // A second block inside the columns of the first, on its last row.
        assert_eq!(
            extents("abcdef\nabcdef", Shape::Block, &[(4, 8), (10, 10)]),
            Some(vec![1..5, 8..12])
        );
    }

    #[test]
    fn an_empty_extent_that_touches_another_stays_apart() {
        // A corner on the line break of the short row, and a block on the
        // row after.
        assert_eq!(
            extents("abcd\nx\nabcd", Shape::Block, &[(2, 6), (8, 8)]),
            Some(vec![1..3, 6..6, 8..9])
        );
        // The empty last row after a row that is selected line-wise.
        assert_eq!(
            extents("ab\n", Shape::Line, &[(0, 0), (3, 3)]),
            Some(vec![0..3, 3..3])
        );
    }

    #[test]
    fn a_selection_with_an_end_that_is_no_position_covers_nothing_that_can_be_said() {
        for shape in [
            Shape::Exclusive,
            Shape::Inclusive,
            Shape::Line,
            Shape::Block,
        ] {
            // 2 is inside "é", and 7 is past the end.
            assert_eq!(extents("héllo", shape, &[(0, 2)]), None, "{shape:?}");
            assert_eq!(extents("héllo", shape, &[(2, 2)]), None, "{shape:?}");
            assert_eq!(
                extents("héllo", shape, &[(0, 1), (4, 7)]),
                None,
                "{shape:?}"
            );
            assert_eq!(extents("", shape, &[(1, 1)]), None, "{shape:?}");
            assert!(extents("héllo", shape, &[(0, 6)]).is_some(), "{shape:?}");
        }
    }
}
