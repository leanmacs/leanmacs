//! The cell: the unit a cursor is on.
//!
//! A cell is one character, or a carriage return and the line feed after
//! it together. A character is a Unicode scalar value, as everywhere in
//! this crate: not an extended grapheme cluster, so a letter and a
//! combining mark after it are two cells. This module is the one place
//! that says so. What a selection covers ([`Snapshot::extents`]) is
//! counted in cells, and so must the motions that move a cursor be.

use std::ops::Range;

use crate::snapshot::Snapshot;

impl Snapshot {
    /// Where the cell that starts at the position `offset` ends: after the
    /// character there, or after the line feed when the character is a
    /// carriage return with a line feed after it. At the end of the text,
    /// where no cell starts, it is the end of the text.
    pub(crate) fn cell_end(&self, offset: usize) -> usize {
        let len = match self.char_at(offset) {
            None => 0,
            Some('\r') if self.char_at(offset.saturating_add(1)) == Some('\n') => 2,
            Some(character) => character.len_utf8(),
        };
        offset.saturating_add(len)
    }

    /// The content of the row `row`: its bytes without its line break, so
    /// without the carriage return of a row that ends in a carriage return
    /// and a line feed. A carriage return with no line feed after it is
    /// content. `None` when the text has no such row.
    pub(crate) fn row_content(&self, row: usize) -> Option<Range<usize>> {
        let Range { start, end } = self.row_range(row)?;
        // A row that ends before the text does ends at a line feed.
        let before_a_line_feed = end < self.len();
        let ends_in_a_return =
            before_a_line_feed && end > start && self.char_at(end - 1) == Some('\r');
        Some(start..end - usize::from(ends_in_a_return))
    }

    /// The character that starts at the position `offset`. `None` at the
    /// end of the text and past it, and for an offset inside a character.
    fn char_at(&self, offset: usize) -> Option<char> {
        let (chunk, start) = self.chunk_at(offset)?;
        chunk.get(offset.checked_sub(start)?..)?.chars().next()
    }
}

#[cfg(test)]
mod tests {
    use crate::Text;

    /// Where the cell at each of `offsets` ends in `text`.
    fn cell_ends(text: &str, offsets: &[usize]) -> Vec<usize> {
        let snapshot = Text::from(text).snapshot();
        offsets
            .iter()
            .map(|&offset| snapshot.cell_end(offset))
            .collect()
    }

    #[test]
    fn a_cell_is_one_character_whatever_its_length_in_bytes() {
        // One, two, three and four bytes.
        assert_eq!(cell_ends("aé€😀b", &[0, 1, 3, 6, 10]), [1, 3, 6, 10, 11]);
    }

    #[test]
    fn a_carriage_return_and_the_line_feed_after_it_are_one_cell() {
        assert_eq!(cell_ends("a\r\nb", &[0, 1, 3]), [1, 3, 4]);
        assert_eq!(cell_ends("\r\n", &[0]), [2]);
        assert_eq!(cell_ends("\r\n\r\n", &[0, 2]), [2, 4]);
    }

    #[test]
    fn a_carriage_return_alone_is_a_cell() {
        assert_eq!(cell_ends("a\rb", &[1]), [2]);
        assert_eq!(cell_ends("a\r", &[1]), [2]);
        assert_eq!(cell_ends("\r\r\n", &[0, 1]), [1, 3]);
    }

    #[test]
    fn the_line_feed_of_a_carriage_return_and_line_feed_is_a_cell_when_started_at() {
        assert_eq!(cell_ends("a\r\nb", &[2]), [3]);
        assert_eq!(cell_ends("a\nb", &[1]), [2]);
    }

    #[test]
    fn at_the_end_of_the_text_a_cell_ends_where_it_starts() {
        assert_eq!(cell_ends("", &[0]), [0]);
        assert_eq!(cell_ends("ab", &[2]), [2]);
        assert_eq!(cell_ends("ab\n", &[3]), [3]);
    }

    #[test]
    fn a_cell_in_a_text_of_many_pieces_ends_as_in_the_string() {
        // A few hundred kilobytes, with a line break of each kind.
        let string = "héllo 😀\r\nwörld\n".repeat(20_000);
        let snapshot = Text::from(string.as_str()).snapshot();
        let mut offset = 0;
        let mut cells = 0_usize;

        while offset < string.len() {
            let rest = &string[offset..];
            let expected = if rest.starts_with("\r\n") {
                2
            } else {
                rest.chars().next().map_or(0, char::len_utf8)
            };
            assert_eq!(snapshot.cell_end(offset), offset + expected, "{offset}");
            offset += expected;
            cells += 1;
        }
        assert_eq!(cells, 14 * 20_000);
    }

    #[test]
    fn the_content_of_a_row_is_its_bytes_without_its_line_break() {
        let snapshot = Text::from("ab\ncd\r\n\r\n\re\r\nf\r").snapshot();

        assert_eq!(snapshot.row_content(0), Some(0..2));
        assert_eq!(snapshot.row_content(1), Some(3..5));
        // A row that is only its line break.
        assert_eq!(snapshot.row_content(2), Some(7..7));
        // A carriage return alone is content, where it does not end a row
        // and where it ends the text.
        assert_eq!(snapshot.row_content(3), Some(9..11));
        assert_eq!(snapshot.row_content(4), Some(13..15));
        assert_eq!(snapshot.row_content(5), None);
        assert_eq!(Text::new().snapshot().row_content(0), Some(0..0));
    }
}
