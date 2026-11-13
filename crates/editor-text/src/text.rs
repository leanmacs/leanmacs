//! A text: the one writer.

use std::error::Error;
use std::fmt;
use std::ops::Range;

use crate::rope::Rope;
use crate::snapshot::{Revision, Snapshot};

/// Text that can be edited.
#[derive(Default)]
pub struct Text {
    /// The text as it is now.
    current: Snapshot,
}

/// Why an edit was refused: its range is not two positions of the text in
/// order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BadRange;

impl fmt::Display for BadRange {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("the range is not two positions of the text in order")
    }
}

impl Error for BadRange {}

impl Text {
    /// An empty text.
    pub fn new() -> Self {
        Self::default()
    }

    /// The text as it is now, borrowed: a read that keeps nothing.
    pub fn current(&self) -> &Snapshot {
        &self.current
    }

    /// Replaces the bytes of `range` with `text`. An empty range inserts,
    /// and an empty `text` deletes. An accepted edit adds one to the
    /// revision, one that changes nothing included.
    ///
    /// Refused, changing nothing, unless both ends of the range are
    /// positions of the text and the start is not after the end. The range
    /// is checked before the text is touched, so an edit is all or nothing.
    pub fn replace(&mut self, range: Range<usize>, text: &str) -> Result<(), BadRange> {
        let Range { start, end } = range;
        let rope = &mut self.current.rope;
        // `is_char_boundary` is false past the end, so this also keeps both
        // offsets within the text.
        if start > end || !rope.is_char_boundary(start) || !rope.is_char_boundary(end) {
            return Err(BadRange);
        }
        if !rope.replace(start, end, text) {
            return Err(BadRange);
        }
        self.current.revision = self.current.revision.next();
        Ok(())
    }
}

impl From<&str> for Text {
    fn from(text: &str) -> Self {
        Self {
            current: Snapshot {
                rope: Rope::from_str(text),
                revision: Revision::default(),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::snapshot::Revision;

    /// "é" and "ö" are two bytes each, so byte offsets and character counts
    /// differ from the second character on: in "héllo" the offsets 0, 1, 3,
    /// 4, 5 and 6 are character boundaries, and 2 is inside "é".
    const TEXT: &str = "héllo wörld";

    /// Two lines, with characters of one to four bytes and a line ending of
    /// each kind.
    const LINES: &str = "héllo wörld\n😀 a line that ends in a carriage return and a line feed\r\n";

    /// A text long enough that the rope holds it in many pieces: a few
    /// hundred kilobytes of [`LINES`].
    fn long_text() -> String {
        LINES.repeat(4_000)
    }

    #[test]
    fn a_text_reads_back_the_string_it_was_made_from() {
        for text in [TEXT, "", "a\0b", "😀", "\r\n", &long_text()] {
            assert_eq!(Text::from(text).current().to_string(), text);
        }
    }

    #[test]
    fn a_new_text_is_empty() {
        let text = Text::new();

        assert_eq!(text.current().to_string(), "");
        assert_eq!(text.current().len(), 0);
        assert!(text.current().is_empty());
    }

    #[test]
    fn the_length_of_a_text_is_in_bytes() {
        assert_eq!(Text::from(TEXT).current().len(), 13);
        assert_eq!(Text::from("😀").current().len(), 4);
        assert!(!Text::from(TEXT).current().is_empty());
        assert_eq!(
            Text::from(long_text().as_str()).current().len(),
            long_text().len()
        );
    }

    #[test]
    fn a_character_boundary_is_an_offset_within_the_text_that_is_not_inside_a_character() {
        let text = Text::from("héllo");
        let snapshot = text.current();

        for boundary in [0, 1, 3, 4, 5, 6] {
            assert!(snapshot.is_char_boundary(boundary), "{boundary}");
        }
        assert!(!snapshot.is_char_boundary(2));
        assert!(!snapshot.is_char_boundary(7));
        assert!(!snapshot.is_char_boundary(usize::MAX));
        assert!(Text::new().current().is_char_boundary(0));
        assert!(!Text::new().current().is_char_boundary(1));
    }

    #[test]
    fn the_character_boundaries_of_a_long_text_are_those_of_its_string() {
        let string = long_text();
        let text = Text::from(string.as_str());

        for offset in (0..=string.len() + 2).step_by(7) {
            assert_eq!(
                text.current().is_char_boundary(offset),
                string.is_char_boundary(offset),
                "{offset}"
            );
        }
    }

    /// What `text` holds now.
    fn read(text: &Text) -> String {
        text.current().to_string()
    }

    #[test]
    fn replace_inserts_at_a_byte_offset_when_the_range_is_empty() {
        let mut text = Text::from(TEXT);

        assert_eq!(text.replace(3..3, "XY"), Ok(()));
        assert_eq!(read(&text), "héXYllo wörld");
        assert_eq!(text.replace(0..0, "<"), Ok(()));
        assert_eq!(read(&text), "<héXYllo wörld");
        assert_eq!(text.replace(16..16, ">"), Ok(()));
        assert_eq!(read(&text), "<héXYllo wörld>");
    }

    #[test]
    fn replace_deletes_its_byte_range_when_the_text_is_empty() {
        let mut text = Text::from(TEXT);

        assert_eq!(text.replace(1..3, ""), Ok(()));
        assert_eq!(read(&text), "hllo wörld");
        assert_eq!(text.replace(5..11, ""), Ok(()));
        assert_eq!(read(&text), "hllo ");
    }

    #[test]
    fn replace_puts_the_text_in_place_of_its_byte_range() {
        let mut text = Text::from(TEXT);

        assert_eq!(text.replace(7..13, "there"), Ok(()));
        assert_eq!(read(&text), "héllo there");
    }

    #[test]
    fn replace_refuses_an_offset_inside_a_character_and_changes_nothing() {
        let mut text = Text::from(TEXT);

        assert_eq!(text.replace(2..2, "x"), Err(BadRange));
        assert_eq!(text.replace(0..2, ""), Err(BadRange));
        assert_eq!(text.replace(2..3, ""), Err(BadRange));
        assert_eq!(read(&text), TEXT);
    }

    #[test]
    fn replace_refuses_an_offset_past_the_end_and_changes_nothing() {
        let mut text = Text::from(TEXT);

        assert_eq!(
            text.replace(TEXT.len() + 1..TEXT.len() + 1, "x"),
            Err(BadRange)
        );
        assert_eq!(text.replace(0..TEXT.len() + 1, ""), Err(BadRange));
        assert_eq!(text.replace(usize::MAX..usize::MAX, "x"), Err(BadRange));
        assert_eq!(read(&text), TEXT);
    }

    // The range is the point of the test: it is one a caller can pass.
    #[expect(clippy::reversed_empty_ranges)]
    #[test]
    fn replace_refuses_a_backwards_range_and_changes_nothing() {
        let mut text = Text::from(TEXT);

        assert_eq!(text.replace(3..1, "x"), Err(BadRange));
        assert_eq!(read(&text), TEXT);
    }

    #[test]
    fn replace_edits_a_text_held_in_many_pieces() {
        let mut string = long_text();
        let mut text = Text::from(string.as_str());
        let middle = LINES.len() * 2_000;
        let end = middle + LINES.len() * 40;

        assert_eq!(text.replace(middle..end, "😀\r\n"), Ok(()));
        string.replace_range(middle..end, "😀\r\n");
        assert_eq!(read(&text), string);
        assert_eq!(text.replace(middle + 1..middle + 1, "x"), Err(BadRange));
        assert_eq!(read(&text), string);
    }

    #[test]
    fn a_new_text_is_at_revision_zero() {
        assert_eq!(Text::new().current().revision(), Revision::default());
        assert_eq!(Text::from(TEXT).current().revision().get(), 0);
    }

    #[test]
    fn every_accepted_edit_adds_one_to_the_revision_one_that_changes_nothing_included() {
        let mut text = Text::from(TEXT);

        text.replace(3..3, "XY").expect("an insert at a boundary");
        assert_eq!(text.current().revision().get(), 1);
        text.replace(0..1, "").expect("a delete between boundaries");
        assert_eq!(text.current().revision().get(), 2);
        text.replace(0..0, "")
            .expect("an edit that changes nothing");
        assert_eq!(text.current().revision().get(), 3);
    }

    #[test]
    fn a_refused_edit_adds_nothing_to_the_revision() {
        let mut text = Text::from(TEXT);
        text.replace(0..0, "x").expect("an insert at the start");

        assert_eq!(text.replace(3..3, "x"), Err(BadRange));
        assert_eq!(text.replace(0..99, ""), Err(BadRange));
        assert_eq!(text.current().revision().get(), 1);
    }

    #[test]
    fn a_later_revision_compares_greater() {
        let mut text = Text::from(TEXT);
        let before = text.current().revision();
        text.replace(0..0, "x").expect("an insert at the start");

        assert!(text.current().revision() > before);
    }
}
