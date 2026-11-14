//! Rows and points: where an offset is as a row and a column, and back.
//!
//! The crate docs give the rules: what a row is, and what a point counts.
//! Every conversion here answers only for a position and clamps nothing.

use std::ops::Range;

use crate::snapshot::Snapshot;

/// A position as a row and a column counted in bytes of UTF-8 from the
/// row's start. This is the point tree-sitter speaks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Point {
    /// Which row, from 0.
    pub row: usize,
    /// How many bytes into the row.
    pub column: usize,
}

impl Point {
    /// The point at `column` bytes into the row `row`.
    pub const fn new(row: usize, column: usize) -> Self {
        Self { row, column }
    }
}

/// A position as a row and a column counted in UTF-16 code units from the
/// row's start. This is the point a language server speaks. It is a type of
/// its own so that a column in one unit is never read as the other.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct PointUtf16 {
    /// Which row, from 0.
    pub row: usize,
    /// How many UTF-16 code units into the row.
    pub column: usize,
}

impl PointUtf16 {
    /// The point at `column` UTF-16 code units into the row `row`.
    pub const fn new(row: usize, column: usize) -> Self {
        Self { row, column }
    }
}

/// A position as a row and a column counted in cells from the row's start:
/// how many cells of the row start before the position. This is the column
/// a block's corners are counted in, and the one a motion to another row
/// is given ([`Motion::RowsUp`](crate::Motion::RowsUp)). It is a type of
/// its own so that a column in one unit is never read as another.
///
/// A cell is one character, or a carriage return and the line feed after it
/// together, so the column is the number of characters of the row before
/// the position. In a row whose content has `k` cells and that ends in a
/// carriage return and a line feed, column `k` is the carriage return's
/// position, where the content ends, and column `k + 1` the position
/// between the two bytes, which the line break's cell starts before.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct PointCells {
    /// Which row, from 0.
    pub row: usize,
    /// How many cells into the row.
    pub column: usize,
}

impl PointCells {
    /// The point at `column` cells into the row `row`.
    pub const fn new(row: usize, column: usize) -> Self {
        Self { row, column }
    }
}

impl Snapshot {
    /// How many rows the text has: one more than its line feeds. An empty
    /// text has one row, and a text that ends in a line feed has an empty
    /// last row.
    pub fn row_count(&self) -> usize {
        self.rope.row_count()
    }

    /// The bytes of the row `row`, without the line feed that ends it. A
    /// carriage return before that line feed is in the range: it is a
    /// character of the row. `None` when the text has no such row.
    pub fn row_range(&self, row: usize) -> Option<Range<usize>> {
        let start = self.rope.row_start(row)?;
        // The next row starts one past this row's line feed; the last row
        // has none and ends with the text.
        let end = match self.rope.row_start(row.checked_add(1)?) {
            Some(next) => next - 1,
            None => self.len(),
        };
        Some(start..end)
    }

    /// The point of the position `offset`, with its column in bytes. `None`
    /// when `offset` is not a position.
    pub fn offset_to_point(&self, offset: usize) -> Option<Point> {
        let (row, start) = self.row_of_position(offset)?;
        Some(Point::new(row, offset - start))
    }

    /// The offset of `point`. `None` when `point` names no position: the
    /// text has no such row, or the column is past the row's end or inside
    /// a character. The column just past a row's last character is the
    /// position before its line feed, and the next column is refused, not
    /// carried into the next row.
    pub fn point_to_offset(&self, point: Point) -> Option<usize> {
        let row = self.row_range(point.row)?;
        let offset = row.start.checked_add(point.column)?;
        (offset <= row.end && self.is_char_boundary(offset)).then_some(offset)
    }

    /// The point of the position `offset`, with its column in UTF-16 code
    /// units. `None` when `offset` is not a position.
    pub fn offset_to_point_utf16(&self, offset: usize) -> Option<PointUtf16> {
        let (row, start) = self.row_of_position(offset)?;
        let column = self.rope.utf16_of(offset)? - self.rope.utf16_of(start)?;
        Some(PointUtf16::new(row, column))
    }

    /// The offset of `point`. `None` when `point` names no position: the
    /// text has no such row, or the column is past the row's end or between
    /// the two code units of one character.
    pub fn point_utf16_to_offset(&self, point: PointUtf16) -> Option<usize> {
        let row = self.row_range(point.row)?;
        let units = self.rope.utf16_of(row.start)?.checked_add(point.column)?;
        if units > self.rope.utf16_of(row.end)? {
            return None;
        }
        let offset = self.rope.offset_of_utf16(units)?;
        // A count that falls inside a character comes back as the
        // character's start, which is fewer units in.
        (self.rope.utf16_of(offset)? == units).then_some(offset)
    }

    /// The point of the position `offset`, with its column in cells. `None`
    /// when `offset` is not a position. It walks the row from its start, so
    /// it costs the cells before the position in its row.
    pub fn offset_to_point_cells(&self, offset: usize) -> Option<PointCells> {
        let (row, _) = self.row_of_position(offset)?;
        Some(PointCells::new(row, self.cell_column(row, offset)?))
    }

    /// The offset of `point`. `None` when `point` names no position: the
    /// text has no such row, or the column is past the row's end. The
    /// column just past a row's last character is the position before its
    /// line feed, and the next column is refused, not carried into the next
    /// row.
    pub fn point_cells_to_offset(&self, point: PointCells) -> Option<usize> {
        let row = self.row_range(point.row)?;
        // Within a row's bytes, which stop before its line feed, every
        // character starts a cell, so a column further on is a character
        // further on.
        let mut offset = row.start;
        for _ in 0..point.column {
            if offset >= row.end {
                return None;
            }
            offset += self.char_at(offset)?.len_utf8();
        }
        Some(offset)
    }

    /// How many cells of the row `row` start before the position `offset`,
    /// which is in that row. `None` when the text has no such row.
    pub(crate) fn cell_column(&self, row: usize, offset: usize) -> Option<usize> {
        let mut at = self.row_range(row)?.start;
        let mut column = 0;
        while at < offset {
            let end = self.cell_end(at);
            if end == at {
                // The end of the text: no cell is left to count.
                break;
            }
            at = end;
            column += 1;
        }
        Some(column)
    }

    /// The row that holds the position `offset`, and the offset that row
    /// starts at. `None` when `offset` is not a position.
    pub(crate) fn row_of_position(&self, offset: usize) -> Option<(usize, usize)> {
        if !self.is_char_boundary(offset) {
            return None;
        }
        let row = self.rope.row_of(offset)?;
        Some((row, self.rope.row_start(row)?))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Text;

    /// Three rows. The first ends in a carriage return and a line feed, and
    /// the last has no line feed. "é" and "ö" are two bytes and one UTF-16
    /// unit each; "😀" is four bytes and two units.
    ///
    /// | Row | Bytes | Holds |
    /// |---|---|---|
    /// | 0 | 0 to 7 | `héllo\r`, then the line feed at 7 |
    /// | 1 | 8 to 14 | `wörld`, then the line feed at 14 |
    /// | 2 | 15 to 20 | `😀x` |
    const TEXT: &str = "héllo\r\nwörld\n😀x";

    /// Every position of [`TEXT`], with its row and its column in bytes and
    /// in UTF-16 code units.
    const POSITIONS: &[(usize, usize, usize, usize)] = &[
        (0, 0, 0, 0),
        (1, 0, 1, 1),
        (3, 0, 3, 2),
        (4, 0, 4, 3),
        (5, 0, 5, 4),
        (6, 0, 6, 5),
        (7, 0, 7, 6),
        (8, 1, 0, 0),
        (9, 1, 1, 1),
        (11, 1, 3, 2),
        (12, 1, 4, 3),
        (13, 1, 5, 4),
        (14, 1, 6, 5),
        (15, 2, 0, 0),
        (19, 2, 4, 2),
        (20, 2, 5, 3),
    ];

    /// The column in cells of each position of [`POSITIONS`], in order. The
    /// carriage return of row 0 is at column 5, where the row's content
    /// ends, and the position between it and its line feed at column 6.
    const CELL_COLUMNS: [usize; 16] = [0, 1, 2, 3, 4, 5, 6, 0, 1, 2, 3, 4, 5, 0, 1, 2];

    /// The offsets of [`TEXT`] that are inside a character, and two past
    /// its end.
    const NOT_POSITIONS: &[usize] = &[2, 10, 16, 17, 18, 21, usize::MAX];

    /// A snapshot of `text`.
    fn snapshot(text: &str) -> Snapshot {
        Text::from(text).snapshot()
    }

    #[test]
    fn a_text_has_one_more_row_than_it_has_line_feeds() {
        assert_eq!(snapshot("").row_count(), 1);
        assert_eq!(snapshot("a").row_count(), 1);
        assert_eq!(snapshot("a\n").row_count(), 2);
        assert_eq!(snapshot("\n\n").row_count(), 3);
        assert_eq!(snapshot(TEXT).row_count(), 3);
    }

    #[test]
    fn a_carriage_return_starts_no_row_alone_or_before_a_line_feed() {
        assert_eq!(snapshot("a\rb").row_count(), 1);
        assert_eq!(snapshot("a\rb").row_range(0), Some(0..3));
        assert_eq!(snapshot("a\r\nb").row_count(), 2);
        assert_eq!(snapshot("a\r\nb").row_range(0), Some(0..2));
        assert_eq!(snapshot("a\r\nb").row_range(1), Some(3..4));
    }

    #[test]
    fn a_row_is_its_bytes_without_the_line_feed_that_ends_it() {
        let text = snapshot(TEXT);

        assert_eq!(text.row_range(0), Some(0..7));
        assert_eq!(text.row_range(1), Some(8..14));
        assert_eq!(text.row_range(2), Some(15..20));
    }

    #[test]
    fn an_empty_text_has_one_empty_row_and_a_text_that_ends_in_a_line_feed_an_empty_last_row() {
        assert_eq!(snapshot("").row_range(0), Some(0..0));
        assert_eq!(snapshot("a\n").row_range(0), Some(0..1));
        assert_eq!(snapshot("a\n").row_range(1), Some(2..2));
    }

    #[test]
    fn a_row_the_text_does_not_have_has_no_range() {
        assert_eq!(snapshot("").row_range(1), None);
        assert_eq!(snapshot(TEXT).row_range(3), None);
        assert_eq!(snapshot(TEXT).row_range(usize::MAX), None);
    }

    #[test]
    fn the_point_of_a_position_counts_its_column_in_bytes_from_the_rows_start() {
        let text = snapshot(TEXT);

        for &(offset, row, column, _) in POSITIONS {
            assert_eq!(
                text.offset_to_point(offset),
                Some(Point::new(row, column)),
                "{offset}"
            );
        }
    }

    #[test]
    fn the_utf16_point_of_a_position_counts_its_column_in_code_units_from_the_rows_start() {
        let text = snapshot(TEXT);

        for &(offset, row, _, column) in POSITIONS {
            assert_eq!(
                text.offset_to_point_utf16(offset),
                Some(PointUtf16::new(row, column)),
                "{offset}"
            );
        }
    }

    #[test]
    fn the_cells_point_of_a_position_counts_the_cells_of_its_row_that_start_before_it() {
        let text = snapshot(TEXT);

        for (&(offset, row, _, _), column) in POSITIONS.iter().zip(CELL_COLUMNS) {
            assert_eq!(
                text.offset_to_point_cells(offset),
                Some(PointCells::new(row, column)),
                "{offset}"
            );
        }
    }

    #[test]
    fn a_cells_point_that_names_a_position_has_its_offset() {
        let text = snapshot(TEXT);

        for (&(offset, row, _, _), column) in POSITIONS.iter().zip(CELL_COLUMNS) {
            assert_eq!(
                text.point_cells_to_offset(PointCells::new(row, column)),
                Some(offset),
                "row {row}, cells column {column}"
            );
        }
    }

    #[test]
    fn an_offset_that_is_not_a_position_has_no_point_in_cells() {
        let text = snapshot(TEXT);

        for &offset in NOT_POSITIONS {
            assert_eq!(text.offset_to_point_cells(offset), None, "{offset}");
        }
    }

    #[test]
    fn a_cells_point_past_the_end_of_its_row_or_in_a_row_the_text_lacks_has_no_offset() {
        let text = snapshot(TEXT);

        // Row 0 has the columns 0 to 6, row 1 the columns 0 to 5 and row 2
        // the columns 0 to 2; one more would be the start of the next row
        // if columns ran on.
        assert_eq!(text.point_cells_to_offset(PointCells::new(0, 7)), None);
        assert_eq!(text.point_cells_to_offset(PointCells::new(1, 6)), None);
        assert_eq!(text.point_cells_to_offset(PointCells::new(2, 3)), None);
        assert_eq!(
            text.point_cells_to_offset(PointCells::new(1, usize::MAX)),
            None
        );
        assert_eq!(text.point_cells_to_offset(PointCells::new(3, 0)), None);
        assert_eq!(
            text.point_cells_to_offset(PointCells::new(usize::MAX, 0)),
            None
        );
        assert_eq!(
            snapshot("").point_cells_to_offset(PointCells::new(0, 0)),
            Some(0)
        );
        assert_eq!(
            snapshot("").point_cells_to_offset(PointCells::new(0, 1)),
            None
        );
    }

    #[test]
    fn in_a_row_that_ends_in_a_carriage_return_and_a_line_feed_the_column_past_the_content_is_the_carriage_return()
     {
        // The content of row 0, `ab`, has two cells. Column 2 is where it
        // ends, at the carriage return; column 3 is the position between
        // the carriage return and the line feed, which the line break's
        // cell starts before; and there is no column 4.
        let text = snapshot("ab\r\ncd");

        assert_eq!(text.point_cells_to_offset(PointCells::new(0, 2)), Some(2));
        assert_eq!(text.point_cells_to_offset(PointCells::new(0, 3)), Some(3));
        assert_eq!(text.point_cells_to_offset(PointCells::new(0, 4)), None);
        assert_eq!(text.offset_to_point_cells(2), Some(PointCells::new(0, 2)));
        assert_eq!(text.offset_to_point_cells(3), Some(PointCells::new(0, 3)));
        assert_eq!(text.offset_to_point_cells(4), Some(PointCells::new(1, 0)));
        // With a line feed alone, the column past the content is the last.
        let text = snapshot("ab\ncd");
        assert_eq!(text.point_cells_to_offset(PointCells::new(0, 2)), Some(2));
        assert_eq!(text.point_cells_to_offset(PointCells::new(0, 3)), None);
        // A carriage return with no line feed after it is a cell of the
        // content.
        let text = snapshot("a\rb");
        assert_eq!(text.offset_to_point_cells(2), Some(PointCells::new(0, 2)));
        assert_eq!(text.point_cells_to_offset(PointCells::new(0, 3)), Some(3));
    }

    #[test]
    fn an_offset_that_is_not_a_position_has_no_point_in_either_unit() {
        let text = snapshot(TEXT);

        for &offset in NOT_POSITIONS {
            assert_eq!(text.offset_to_point(offset), None, "{offset}");
            assert_eq!(text.offset_to_point_utf16(offset), None, "{offset}");
        }
    }

    #[test]
    fn a_point_that_names_a_position_has_its_offset_in_either_unit() {
        let text = snapshot(TEXT);

        for &(offset, row, bytes, units) in POSITIONS {
            assert_eq!(
                text.point_to_offset(Point::new(row, bytes)),
                Some(offset),
                "row {row}, byte column {bytes}"
            );
            assert_eq!(
                text.point_utf16_to_offset(PointUtf16::new(row, units)),
                Some(offset),
                "row {row}, UTF-16 column {units}"
            );
        }
    }

    #[test]
    fn a_point_in_a_row_the_text_does_not_have_has_no_offset() {
        let text = snapshot(TEXT);

        assert_eq!(text.point_to_offset(Point::new(3, 0)), None);
        assert_eq!(text.point_to_offset(Point::new(usize::MAX, 0)), None);
        assert_eq!(text.point_utf16_to_offset(PointUtf16::new(3, 0)), None);
        assert_eq!(
            text.point_utf16_to_offset(PointUtf16::new(usize::MAX, 0)),
            None
        );
        assert_eq!(snapshot("").point_to_offset(Point::new(1, 0)), None);
    }

    #[test]
    fn a_point_past_the_end_of_its_row_has_no_offset_and_is_not_carried_into_the_next_row() {
        let text = snapshot(TEXT);

        // Row 0 is seven bytes and six units long; one more would be the
        // start of row 1 if columns ran on.
        assert_eq!(text.point_to_offset(Point::new(0, 8)), None);
        assert_eq!(text.point_utf16_to_offset(PointUtf16::new(0, 7)), None);
        assert_eq!(text.point_to_offset(Point::new(2, 6)), None);
        assert_eq!(text.point_utf16_to_offset(PointUtf16::new(2, 4)), None);
        assert_eq!(text.point_to_offset(Point::new(1, usize::MAX)), None);
        assert_eq!(
            text.point_utf16_to_offset(PointUtf16::new(1, usize::MAX)),
            None
        );
        assert_eq!(snapshot("").point_to_offset(Point::new(0, 1)), None);
    }

    #[test]
    fn a_byte_column_inside_a_character_has_no_offset() {
        let text = snapshot(TEXT);

        assert_eq!(text.point_to_offset(Point::new(0, 2)), None);
        assert_eq!(text.point_to_offset(Point::new(1, 2)), None);
        for column in 1..4 {
            assert_eq!(text.point_to_offset(Point::new(2, column)), None);
        }
    }

    #[test]
    fn a_utf16_column_between_the_two_units_of_a_character_has_no_offset() {
        let text = snapshot(TEXT);

        assert_eq!(text.point_utf16_to_offset(PointUtf16::new(2, 1)), None);
    }

    #[test]
    fn the_character_a_raw_byte_is_kept_as_is_four_bytes_and_two_utf16_units() {
        // "a", the character the byte 0xFF is kept as, "b", a line feed and
        // "c".
        let text = snapshot("a\u{10DCFF}b\nc");

        assert_eq!(text.offset_to_point(5), Some(Point::new(0, 5)));
        assert_eq!(text.offset_to_point_utf16(5), Some(PointUtf16::new(0, 3)));
        assert_eq!(text.point_utf16_to_offset(PointUtf16::new(0, 3)), Some(5));
        assert_eq!(text.point_utf16_to_offset(PointUtf16::new(0, 2)), None);
        for inside in 2..5 {
            assert_eq!(text.offset_to_point(inside), None);
        }
        assert_eq!(text.offset_to_point_utf16(7), Some(PointUtf16::new(1, 0)));
    }

    #[test]
    fn points_in_a_text_held_in_many_pieces_are_counted_across_the_pieces() {
        let line = "héllo wörld 😀\r\n";
        let string = line.repeat(2_000);
        let text = snapshot(&string);
        // The "w" of row 1,500: seven bytes and six units into it.
        let offset = line.len() * 1_500 + 7;

        assert_eq!(text.row_count(), 2_001);
        assert_eq!(
            text.row_range(1_500),
            Some(line.len() * 1_500..line.len() * 1_501 - 1)
        );
        assert_eq!(text.offset_to_point(offset), Some(Point::new(1_500, 7)));
        assert_eq!(
            text.offset_to_point_utf16(offset),
            Some(PointUtf16::new(1_500, 6))
        );
        assert_eq!(text.point_to_offset(Point::new(1_500, 7)), Some(offset));
        assert_eq!(
            text.point_utf16_to_offset(PointUtf16::new(1_500, 6)),
            Some(offset)
        );
        assert_eq!(
            text.offset_to_point_cells(offset),
            Some(PointCells::new(1_500, 6))
        );
        assert_eq!(
            text.point_cells_to_offset(PointCells::new(1_500, 6)),
            Some(offset)
        );
        assert_eq!(
            text.offset_to_point(string.len()),
            Some(Point::new(2_000, 0))
        );
    }
}
