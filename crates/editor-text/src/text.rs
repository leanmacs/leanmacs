//! A text: the one writer.

use crate::rope::Rope;
use crate::snapshot::Snapshot;

/// Text that can be edited.
#[derive(Default)]
pub struct Text {
    /// The text as it is now.
    current: Snapshot,
}

impl Text {
    /// An empty text.
    pub fn new() -> Self {
        Self::default()
    }

    /// The text as it is now, borrowed: a read that keeps nothing.
    pub fn current(&self) -> &Snapshot {
        &self.current
    }
}

impl From<&str> for Text {
    fn from(text: &str) -> Self {
        Self {
            current: Snapshot {
                rope: Rope::from_str(text),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// "é" and "ö" are two bytes each, so byte offsets and character counts
    /// differ from the second character on: in "héllo" the offsets 0, 1, 3,
    /// 4, 5 and 6 are character boundaries, and 2 is inside "é".
    const TEXT: &str = "héllo wörld";

    /// A text long enough that the rope holds it in more than one piece: a
    /// few hundred kilobytes, with characters of one to four bytes and line
    /// endings of each kind.
    fn long_text() -> String {
        "héllo wörld\n😀 a line that ends in a carriage return and a line feed\r\n".repeat(4_000)
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
}
