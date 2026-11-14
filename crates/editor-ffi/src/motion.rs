//! A motion as it crosses the boundary: a tag, and for the two motions
//! that take them a count of rows and a column.
//!
//! What a motion answers is the text's rule (`editor_text::Motion`), pinned
//! by `editor-text`'s own tests. This module names a motion by a number:
//!
//! | Tag | Motion |
//! |---|---|
//! | 0 | The next cell |
//! | 1 | The previous cell |
//! | 2 | The next start of a word |
//! | 3 | The next end of a word |
//! | 4 | The previous start of a word |
//! | 5 | The previous end of a word |
//! | 6 to 9 | The same four for a WORD |
//! | 10 | The start of the line |
//! | 11 | The end of the line |
//! | 12 | The first non-blank of the line |
//! | 13 | The start of the text |
//! | 14 | The end of the text |
//! | 15 | Rows up, with a count and a column |
//! | 16 | Rows down, with a count and a column |
//!
//! A motion is built from its tag and the enum is never matched on here,
//! so a motion the text gains later changes nothing in this crate until it
//! is given a tag.

use editor_text::{Motion, WordKind};

/// How many tags name a motion: the tags from 0 up to, not including,
/// this.
pub const TAGS: u8 = 17;

/// The motion `tag` stands for, if it is one. `count` and `column` are
/// read for the two motions by rows and for no other. One that no `usize`
/// holds is read as the largest, which means the same: a motion by rows
/// stops at the first or the last row and at the end of a row's content.
pub fn motion_of(tag: u8, count: u64, column: u64) -> Option<Motion> {
    let count = usize::try_from(count).unwrap_or(usize::MAX);
    let column = usize::try_from(column).unwrap_or(usize::MAX);
    Some(match tag {
        0 => Motion::NextCell,
        1 => Motion::PreviousCell,
        2 => Motion::NextWordStart(WordKind::Word),
        3 => Motion::NextWordEnd(WordKind::Word),
        4 => Motion::PreviousWordStart(WordKind::Word),
        5 => Motion::PreviousWordEnd(WordKind::Word),
        6 => Motion::NextWordStart(WordKind::BigWord),
        7 => Motion::NextWordEnd(WordKind::BigWord),
        8 => Motion::PreviousWordStart(WordKind::BigWord),
        9 => Motion::PreviousWordEnd(WordKind::BigWord),
        10 => Motion::LineStart,
        11 => Motion::LineEnd,
        12 => Motion::LineFirstNonBlank,
        13 => Motion::TextStart,
        14 => Motion::TextEnd,
        15 => Motion::RowsUp { count, column },
        16 => Motion::RowsDown { count, column },
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_tag_names_the_motion_its_row_of_the_table_says() {
        let named: Vec<_> = (0..TAGS).map(|tag| motion_of(tag, 3, 5)).collect();

        assert_eq!(
            named,
            [
                Motion::NextCell,
                Motion::PreviousCell,
                Motion::NextWordStart(WordKind::Word),
                Motion::NextWordEnd(WordKind::Word),
                Motion::PreviousWordStart(WordKind::Word),
                Motion::PreviousWordEnd(WordKind::Word),
                Motion::NextWordStart(WordKind::BigWord),
                Motion::NextWordEnd(WordKind::BigWord),
                Motion::PreviousWordStart(WordKind::BigWord),
                Motion::PreviousWordEnd(WordKind::BigWord),
                Motion::LineStart,
                Motion::LineEnd,
                Motion::LineFirstNonBlank,
                Motion::TextStart,
                Motion::TextEnd,
                Motion::RowsUp {
                    count: 3,
                    column: 5
                },
                Motion::RowsDown {
                    count: 3,
                    column: 5
                },
            ]
            .map(Some)
        );
    }

    #[test]
    fn a_tag_that_names_no_motion_is_refused() {
        assert_eq!(motion_of(TAGS, 0, 0), None);
        assert_eq!(motion_of(u8::MAX, 0, 0), None);
    }

    #[test]
    fn a_count_and_a_column_reach_the_two_motions_by_rows_and_are_kept_apart() {
        assert_eq!(
            motion_of(15, 7, 2),
            Some(Motion::RowsUp {
                count: 7,
                column: 2
            })
        );
        assert_eq!(
            motion_of(16, 0, 9),
            Some(Motion::RowsDown {
                count: 0,
                column: 9
            })
        );
        // The largest a word holds is the largest there is.
        assert_eq!(
            motion_of(16, u64::MAX, u64::MAX),
            Some(Motion::RowsDown {
                count: usize::MAX,
                column: usize::MAX
            })
        );
    }

    #[test]
    fn a_count_and_a_column_change_no_other_motion() {
        for tag in 0..15 {
            assert_eq!(
                motion_of(tag, 0, 0),
                motion_of(tag, u64::MAX, 4),
                "tag {tag}"
            );
        }
    }
}
