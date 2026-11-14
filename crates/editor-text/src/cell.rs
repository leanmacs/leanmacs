//! The cell: the unit a cursor is on.
//!
//! A cell is one character, or a carriage return and the line feed after
//! it together. A character is a Unicode scalar value, as everywhere in
//! this crate: not an extended grapheme cluster, so a letter and a
//! combining mark after it are two cells. This module is the one place
//! that says so. What a selection covers ([`Snapshot::extents`]) is
//! counted in cells, and the motions that move a cursor
//! ([`Snapshot::motion`]) step by them, forward and back.

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

    /// Where the last cell that starts before the position `offset`
    /// starts: at the character that ends there, or at the carriage return
    /// before it when that character is a line feed with one. From between
    /// a carriage return and its line feed it is the carriage return. At
    /// the start of the text, where no cell is before, it is 0. This is
    /// the step back that [`Snapshot::cell_end`] is the step forward of.
    pub(crate) fn cell_start_before(&self, offset: usize) -> usize {
        let Some(character) = self.char_before(offset) else {
            return 0;
        };
        let start = offset - character.len_utf8();
        let paired = character == '\n' && self.char_before(start) == Some('\r');
        start - usize::from(paired)
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

    /// A copy of the content of the row `row`: the row without its line
    /// break, so without its line feed and without the carriage return
    /// before that line feed. A carriage return with no line feed after it
    /// is content. `None` when the text has no such row. It reads the
    /// row's pieces and no more of the text.
    pub fn row_to_string(&self, row: usize) -> Option<String> {
        self.slice_to_string(self.row_content(row)?)
    }

    /// The character that starts at the position `offset`. `None` at the
    /// end of the text and past it, and for an offset inside a character.
    pub(crate) fn char_at(&self, offset: usize) -> Option<char> {
        let (chunk, start) = self.chunk_at(offset)?;
        chunk.get(offset.checked_sub(start)?..)?.chars().next()
    }

    /// The character that ends at the position `offset`. `None` at the
    /// start of the text and past its end, and for an offset inside a
    /// character.
    pub(crate) fn char_before(&self, offset: usize) -> Option<char> {
        // A piece ends on a character boundary, so the piece that holds
        // the byte before the offset holds all of the character.
        let (chunk, start) = self.chunk_at(offset.checked_sub(1)?)?;
        chunk.get(..offset.checked_sub(start)?)?.chars().next_back()
    }
}

#[cfg(test)]
mod tests {
    use crate::Text;

    /// Where the last cell before each of `offsets` starts in `text`.
    fn cell_starts_before(text: &str, offsets: &[usize]) -> Vec<usize> {
        let snapshot = Text::from(text).snapshot();
        offsets
            .iter()
            .map(|&offset| snapshot.cell_start_before(offset))
            .collect()
    }

    #[test]
    fn the_cell_before_is_one_character_whatever_its_length_in_bytes() {
        // One, two, three and four bytes.
        assert_eq!(
            cell_starts_before("aé€😀b", &[1, 3, 6, 10, 11]),
            [0, 1, 3, 6, 10]
        );
    }

    #[test]
    fn a_carriage_return_and_the_line_feed_after_it_are_stepped_back_over_as_one() {
        assert_eq!(cell_starts_before("a\r\nb", &[1, 3, 4]), [0, 1, 3]);
        assert_eq!(cell_starts_before("\r\n", &[2]), [0]);
        assert_eq!(cell_starts_before("\r\n\r\n", &[2, 4]), [0, 2]);
    }

    #[test]
    fn a_carriage_return_alone_is_stepped_back_over_alone() {
        assert_eq!(cell_starts_before("a\rb", &[2, 3]), [1, 2]);
        assert_eq!(cell_starts_before("a\r", &[2]), [1]);
        assert_eq!(cell_starts_before("\r\r\n", &[1, 3]), [0, 1]);
    }

    #[test]
    fn from_between_a_carriage_return_and_its_line_feed_the_cell_before_is_theirs() {
        assert_eq!(cell_starts_before("a\r\nb", &[2]), [1]);
        // A line feed alone is a cell of its own.
        assert_eq!(cell_starts_before("a\nb", &[2]), [1]);
        assert_eq!(cell_starts_before("\n\n", &[1, 2]), [0, 1]);
    }

    #[test]
    fn at_the_start_of_the_text_no_cell_is_before() {
        assert_eq!(cell_starts_before("", &[0]), [0]);
        assert_eq!(cell_starts_before("ab", &[0]), [0]);
        assert_eq!(cell_starts_before("\r\n", &[0]), [0]);
    }

    #[test]
    fn a_text_of_many_pieces_is_walked_back_from_its_end_cell_by_cell() {
        // A few hundred kilobytes, with a line break of each kind.
        let string = "héllo 😀\r\nwörld\n".repeat(20_000);
        let snapshot = Text::from(string.as_str()).snapshot();
        // Where every cell starts, by walking forward.
        let mut starts = Vec::new();
        let mut offset = 0;
        while offset < string.len() {
            starts.push(offset);
            offset = snapshot.cell_end(offset);
        }
        assert_eq!(starts.len(), 14 * 20_000);

        let mut offset = string.len();
        for &start in starts.iter().rev() {
            assert_eq!(snapshot.cell_start_before(offset), start, "{offset}");
            offset = start;
        }
        assert_eq!(offset, 0);
    }

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

    #[test]
    fn a_row_is_read_as_its_content_without_its_line_break() {
        let snapshot = Text::from("ab\ncd\r\n\r\n\re\r\nf\r").snapshot();

        assert_eq!(snapshot.row_to_string(0).as_deref(), Some("ab"));
        assert_eq!(snapshot.row_to_string(1).as_deref(), Some("cd"));
        // A row that is only its line break.
        assert_eq!(snapshot.row_to_string(2).as_deref(), Some(""));
        // A carriage return alone is read, where it does not end a row and
        // where it ends the text.
        assert_eq!(snapshot.row_to_string(3).as_deref(), Some("\re"));
        assert_eq!(snapshot.row_to_string(4).as_deref(), Some("f\r"));
    }

    #[test]
    fn a_row_with_characters_of_several_bytes_and_the_empty_last_row_are_read() {
        let snapshot = Text::from("héllo 😀\r\nwörld\n").snapshot();

        assert_eq!(snapshot.row_to_string(0).as_deref(), Some("héllo 😀"));
        assert_eq!(snapshot.row_to_string(1).as_deref(), Some("wörld"));
        assert_eq!(snapshot.row_to_string(2).as_deref(), Some(""));
        assert_eq!(Text::new().snapshot().row_to_string(0).as_deref(), Some(""));
    }

    #[test]
    fn a_row_the_text_does_not_have_is_not_read() {
        let snapshot = Text::from("ab\ncd").snapshot();

        assert_eq!(snapshot.row_to_string(2), None);
        assert_eq!(snapshot.row_to_string(usize::MAX), None);
        assert_eq!(Text::new().snapshot().row_to_string(1), None);
    }

    #[test]
    fn a_row_of_a_text_held_in_many_pieces_is_read_across_the_pieces() {
        // One row longer than a piece, between two short ones.
        let long = "héllo wörld 😀 ".repeat(2_000);
        let string = format!("first\r\n{long}\r\nlast");
        let snapshot = Text::from(string.as_str()).snapshot();

        assert!(snapshot.chunks().count() > 4);
        assert_eq!(snapshot.row_to_string(0).as_deref(), Some("first"));
        assert_eq!(snapshot.row_to_string(1).as_deref(), Some(long.as_str()));
        assert_eq!(snapshot.row_to_string(2).as_deref(), Some("last"));
    }
}
