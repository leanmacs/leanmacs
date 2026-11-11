//! Text search: the example of options and a byte range crossing the
//! boundary.

use std::ops::Range;

/// The byte offsets of the first occurrence of `needle` in `haystack` at or
/// after the byte offset `start` (the beginning, if `None`).
///
/// `None` when there is no such occurrence, and when `start` is past the end
/// of `haystack` or inside a character.
pub fn find(haystack: &str, needle: &str, start: Option<usize>) -> Option<Range<usize>> {
    let start = start.unwrap_or(0);
    let found = start + haystack.get(start..)?.find(needle)?;
    Some(found..found + needle.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// "é" and "ö" are two bytes each, so byte offsets and character counts
    /// differ from the second character on.
    const HAYSTACK: &str = "héllo wörld, hello";

    #[test]
    fn find_returns_the_byte_offsets_of_the_first_match() {
        assert_eq!(find(HAYSTACK, "llo", None), Some(3..6));
        assert_eq!(find(HAYSTACK, "wörld", None), Some(7..13));
    }

    #[test]
    fn find_starts_looking_at_the_start_offset() {
        assert_eq!(find(HAYSTACK, "llo", Some(3)), Some(3..6));
        assert_eq!(find(HAYSTACK, "llo", Some(4)), Some(17..20));
    }

    #[test]
    fn find_returns_nothing_when_there_is_no_match() {
        assert_eq!(find(HAYSTACK, "zzz", None), None);
        assert_eq!(find(HAYSTACK, "llo", Some(18)), None);
    }

    #[test]
    fn find_returns_nothing_for_a_start_past_the_end() {
        assert_eq!(find(HAYSTACK, "llo", Some(HAYSTACK.len() + 1)), None);
    }

    #[test]
    fn find_returns_nothing_for_a_start_inside_a_character() {
        assert_eq!(find(HAYSTACK, "llo", Some(2)), None);
    }
}
