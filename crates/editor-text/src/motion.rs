//! Motions: from a position of a text to another.
//!
//! A motion is a read of a snapshot ([`Snapshot::motion`]). Every one moves
//! by the text's cell, the unit a selection is counted in (the private
//! module `cell`), so a step forward moves over exactly what an inclusive
//! cursor covers. A motion walks the rope from the position it is given, a
//! cell at a time, and builds nothing: no string, no list of the text's
//! cells.
//!
//! These are primitives. Which key runs which, a count as repetition, the
//! column a cursor wants and keeping a cursor off a line break are the
//! editor's rules, and are not here.

use std::ops::Range;

use crate::snapshot::Snapshot;
use crate::word;

/// A motion: a way from one position of a text to another
/// ([`Snapshot::motion`]). In each row of the tables, `p` is the position
/// the motion is asked from and `n` the length of the text.
///
/// A *cell start* is a position where a cell starts: every position but the
/// one between a carriage return and the line feed after it. The end of the
/// text is no cell start.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Motion {
    /// The first cell start after `p`, or `n`. It is where the cell at `p`
    /// ends, so it is the end of what an inclusive cursor at `p` covers.
    NextCell,
    /// The last cell start before `p`, or 0.
    PreviousCell,
    /// Where `p`'s row starts.
    LineStart,
    /// Where the content of `p`'s row ends: where its line break starts, or
    /// `n` in the last row. From between a carriage return and its line
    /// feed it is the position before `p`.
    LineEnd,
    /// The first position of the content of `p`'s row whose character is
    /// not a blank (a space or a tab); where the content ends when there is
    /// none, so the row's start on an empty line.
    LineFirstNonBlank,
    /// The start of the text: 0.
    TextStart,
    /// The end of the text: `n`.
    TextEnd,
}

impl Snapshot {
    /// Where `motion` leads from the position `offset`. The answer is a
    /// position of the text. `None` unless `offset` is a position, whichever
    /// motion it is.
    ///
    /// The line break is a cell like any other, so a motion by cells crosses
    /// lines, and no answer is clamped: where there is nothing further the
    /// answer is the end of the text going forward and 0 going back.
    pub fn motion(&self, motion: Motion, offset: usize) -> Option<usize> {
        if !self.is_char_boundary(offset) {
            return None;
        }
        Some(match motion {
            Motion::NextCell => self.cell_end(offset),
            Motion::PreviousCell => self.cell_start_before(offset),
            Motion::LineStart => self.row_of_position(offset)?.1,
            Motion::LineEnd => self.content_at(offset)?.end,
            Motion::LineFirstNonBlank => self.first_non_blank(self.content_at(offset)?),
            Motion::TextStart => 0,
            Motion::TextEnd => self.len(),
        })
    }

    /// The content of the row the position `offset` is in. `None` when
    /// `offset` is not a position.
    fn content_at(&self, offset: usize) -> Option<Range<usize>> {
        let (row, _) = self.row_of_position(offset)?;
        self.row_content(row)
    }

    /// The first position of `content`, the content of a row, whose
    /// character is not a blank; its end when there is none.
    fn first_non_blank(&self, content: Range<usize>) -> usize {
        let mut at = content.start;
        while at < content.end {
            match self.char_at(at) {
                Some(character) if word::is_blank(character) => at += character.len_utf8(),
                _ => break,
            }
        }
        at
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Text;

    /// Four rows, thirty bytes. The combining acute (U+0301) is two bytes
    /// and "😀" four.
    ///
    /// | Row | Bytes | Holds |
    /// |---|---|---|
    /// | 0 | 0 to 10 | `foo.bar`, two spaces at 7 and 8, `x` at 9; then a carriage return at 10 and a line feed at 11 |
    /// | 1 | 12 | Nothing: a carriage return at 12 and a line feed at 13. An empty line |
    /// | 2 | 14 to 26 | A tab at 14, `s` at 15, `e` at 16, the combining acute at 17, `😀` at 19, `!` at 23, a space at 24, `y` at 25; then a line feed at 26 |
    /// | 3 | 27 to 30 | `end`, with no line break |
    const FIXTURE: &str = "foo.bar  x\r\n\r\n\tse\u{301}😀! y\nend";

    /// Every position of [`FIXTURE`]. The offsets 18, 20, 21 and 22 are
    /// inside a character; 11 and 13 are positions and not cell starts.
    const POSITIONS: [usize; 27] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 19, 23, 24, 25, 26, 27, 28,
        29, 30,
    ];

    /// Every position of `text`, in order.
    fn positions(text: &str) -> Vec<usize> {
        (0..=text.len())
            .filter(|&offset| text.is_char_boundary(offset))
            .collect()
    }

    /// Where `motion` leads from every position of `text`, in order.
    fn answers(text: &str, motion: Motion) -> Vec<usize> {
        let snapshot = Text::from(text).snapshot();
        positions(text)
            .into_iter()
            .map(|offset| {
                snapshot
                    .motion(motion, offset)
                    .expect("a motion from a position")
            })
            .collect()
    }

    /// Every motion, to ask what holds of them all.
    const MOTIONS: [Motion; 7] = [
        Motion::NextCell,
        Motion::PreviousCell,
        Motion::LineStart,
        Motion::LineEnd,
        Motion::LineFirstNonBlank,
        Motion::TextStart,
        Motion::TextEnd,
    ];

    #[test]
    fn the_fixture_has_the_positions_its_tables_are_written_for() {
        assert_eq!(FIXTURE.len(), 30);
        assert_eq!(positions(FIXTURE), POSITIONS);
    }

    #[test]
    fn the_next_cell_is_the_first_cell_start_after_the_position_or_the_end_of_the_text() {
        assert_eq!(
            answers(FIXTURE, Motion::NextCell),
            [
                1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 12, 14, 14, 15, 16, 17, 19, 23, 24, 25, 26, 27,
                28, 29, 30, 30
            ]
        );
        assert_eq!(
            answers("a\r\n\r\nb", Motion::NextCell),
            [1, 3, 3, 5, 5, 6, 6]
        );
        // A character of four bytes is one step.
        assert_eq!(answers("a😀b", Motion::NextCell), [1, 5, 6, 6]);
    }

    #[test]
    fn the_previous_cell_is_the_last_cell_start_before_the_position_or_the_start_of_the_text() {
        assert_eq!(
            answers(FIXTURE, Motion::PreviousCell),
            [
                0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 12, 12, 14, 15, 16, 17, 19, 23, 24, 25,
                26, 27, 28, 29
            ]
        );
        assert_eq!(
            answers("a\r\n\r\nb", Motion::PreviousCell),
            [0, 0, 1, 1, 3, 3, 5]
        );
        assert_eq!(answers("a😀b", Motion::PreviousCell), [0, 0, 1, 5]);
    }

    #[test]
    fn the_start_of_a_line_is_where_the_positions_row_starts() {
        assert_eq!(
            answers(FIXTURE, Motion::LineStart),
            [
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 12, 12, 14, 14, 14, 14, 14, 14, 14, 14, 14, 27,
                27, 27, 27
            ]
        );
        // The position of a line feed belongs to the row it ends.
        assert_eq!(
            answers("ab\r\ncd", Motion::LineStart),
            [0, 0, 0, 0, 4, 4, 4]
        );
        assert_eq!(
            answers("a\n \t\n\nb\n", Motion::LineStart),
            [0, 0, 2, 2, 2, 5, 6, 6, 8]
        );
    }

    #[test]
    fn the_end_of_a_line_is_where_its_content_ends_before_its_line_break() {
        assert_eq!(
            answers(FIXTURE, Motion::LineEnd),
            [
                10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 12, 12, 26, 26, 26, 26, 26, 26, 26,
                26, 26, 30, 30, 30, 30
            ]
        );
        // From between a carriage return and its line feed it is the
        // position before.
        assert_eq!(answers("ab\r\ncd", Motion::LineEnd), [2, 2, 2, 2, 6, 6, 6]);
        assert_eq!(
            answers("a\r\n\r\nb", Motion::LineEnd),
            [1, 1, 1, 3, 3, 6, 6]
        );
        assert_eq!(
            answers("a\n \t\n\nb\n", Motion::LineEnd),
            [1, 1, 4, 4, 4, 5, 7, 7, 8]
        );
        // A carriage return with no line feed after it is content.
        assert_eq!(answers("x\r", Motion::LineEnd), [2, 2, 2]);
        // The empty last row of a text that ends in a line feed.
        assert_eq!(answers("\n", Motion::LineEnd), [0, 1]);
    }

    #[test]
    fn the_first_non_blank_of_a_line_is_past_its_spaces_and_tabs_or_at_the_end_of_its_content() {
        assert_eq!(
            answers(FIXTURE, Motion::LineFirstNonBlank),
            [
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 12, 12, 15, 15, 15, 15, 15, 15, 15, 15, 15, 27,
                27, 27, 27
            ]
        );
        assert_eq!(
            answers("ab\r\ncd", Motion::LineFirstNonBlank),
            [0, 0, 0, 0, 4, 4, 4]
        );
        // A line of blanks only, an empty line and the empty last row.
        assert_eq!(
            answers("a\n \t\n\nb\n", Motion::LineFirstNonBlank),
            [0, 0, 4, 4, 4, 5, 6, 6, 8]
        );
        assert_eq!(answers("  ", Motion::LineFirstNonBlank), [2, 2, 2]);
        // A carriage return is no blank, alone, and is no content before a
        // line feed.
        assert_eq!(answers("x\r", Motion::LineFirstNonBlank), [0, 0, 0]);
        assert_eq!(answers(" \r", Motion::LineFirstNonBlank), [1, 1, 1]);
        assert_eq!(answers(" \r\n", Motion::LineFirstNonBlank), [1, 1, 1, 3]);
        // A character of two bytes after the blanks.
        assert_eq!(answers("\t é", Motion::LineFirstNonBlank), [2, 2, 2, 2]);
    }

    #[test]
    fn the_start_and_the_end_of_the_text_are_the_same_from_every_position() {
        assert_eq!(answers(FIXTURE, Motion::TextStart), [0; 27]);
        assert_eq!(answers(FIXTURE, Motion::TextEnd), [30; 27]);
        assert_eq!(answers("a\n", Motion::TextEnd), [2, 2, 2]);
    }

    #[test]
    fn every_motion_in_an_empty_text_stays_at_its_one_position() {
        for motion in MOTIONS {
            assert_eq!(answers("", motion), [0], "{motion:?}");
        }
    }

    #[test]
    fn a_motion_from_an_offset_that_is_no_position_has_no_answer() {
        let snapshot = Text::from(FIXTURE).snapshot();

        for motion in MOTIONS {
            // Inside the combining acute and inside "😀", past the end, and
            // as far past it as an offset goes.
            for offset in [18, 20, 21, 22, 31, usize::MAX] {
                assert_eq!(snapshot.motion(motion, offset), None, "{motion:?} {offset}");
            }
            assert_eq!(Text::new().snapshot().motion(motion, 1), None, "{motion:?}");
        }
    }
}
