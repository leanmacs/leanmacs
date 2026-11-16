//! A bracket and a quote as they cross the boundary: each a tag.
//!
//! What a pair answers is the text's rule (`editor_text::Snapshot::unmatched`,
//! `editor_text::Snapshot::quoted`), pinned by `editor-text`'s own tests.
//! This module names a kind by a number:
//!
//! | Tag | Bracket | Quote |
//! |---|---|---|
//! | 0 | `(` `)` | `"` |
//! | 1 | `[` `]` | `'` |
//! | 2 | `{` `}` | `` ` `` |
//!
//! A kind is built from its tag and the enums are never matched on here, so
//! a kind the text gains later changes nothing in this crate until it is
//! given a tag.

use editor_text::{Bracket, Quote};

/// What a read of a pair answered, as it crosses the boundary: the status
/// [`editor_ffi_snapshot_unmatched`](crate::snapshot::editor_ffi_snapshot_unmatched)
/// and [`editor_ffi_snapshot_quoted`](crate::snapshot::editor_ffi_snapshot_quoted)
/// return.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PairStatus {
    /// Found: the out parameters hold the answer.
    Found = 0,
    /// The text has no such bracket or string. The out parameters are
    /// untouched.
    NotFound = 1,
    /// Refused: the offset is not a position of the text, or the tag names
    /// no kind. The out parameters are untouched.
    Refused = 2,
}

/// How many tags name a bracket, and how many a quote: the tags from 0 up
/// to, not including, this.
pub const TAGS: u8 = 3;

/// The bracket `tag` stands for, if it is one.
pub fn bracket_of(tag: u8) -> Option<Bracket> {
    Some(match tag {
        0 => Bracket::Round,
        1 => Bracket::Square,
        2 => Bracket::Curly,
        _ => return None,
    })
}

/// The quote `tag` stands for, if it is one.
pub fn quote_of(tag: u8) -> Option<Quote> {
    Some(match tag {
        0 => Quote::Double,
        1 => Quote::Single,
        2 => Quote::Back,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_tag_names_the_bracket_and_the_quote_its_row_of_the_table_says() {
        let brackets: Vec<_> = (0..TAGS).map(bracket_of).collect();
        let quotes: Vec<_> = (0..TAGS).map(quote_of).collect();

        assert_eq!(
            brackets,
            [Bracket::Round, Bracket::Square, Bracket::Curly].map(Some)
        );
        assert_eq!(
            quotes,
            [Quote::Double, Quote::Single, Quote::Back].map(Some)
        );
    }

    #[test]
    fn a_tag_that_names_no_bracket_and_no_quote_is_refused() {
        assert_eq!(bracket_of(TAGS), None);
        assert_eq!(bracket_of(u8::MAX), None);
        assert_eq!(quote_of(TAGS), None);
        assert_eq!(quote_of(u8::MAX), None);
    }
}
