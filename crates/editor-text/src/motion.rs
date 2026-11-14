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
use crate::word::{self, WordKind};

/// A motion: a way from one position of a text to another
/// ([`Snapshot::motion`]). Below, `p` is the position the motion is asked
/// from and `n` the length of the text.
///
/// A *cell start* is a position where a cell starts: every position but the
/// one between a carriage return and the line feed after it. The end of the
/// text is no cell start.
///
/// A *word* is a longest run of neighbouring cells that are all word
/// characters or all punctuation, and a *WORD* a longest run of cells that
/// are not blank ([`WordKind`]). A blank is a space or a tab, and a line
/// break separates words as a blank does; but the line break of an *empty
/// line*, a row with no content that has a line break, is a word alone, of
/// either kind. A word *starts* where its first cell starts and *ends*
/// where its last cell starts: the position of a cursor on its last
/// character, not the position after it. "After" and "before" are strict,
/// so from a word's start the next start is the next word's.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Motion {
    /// The first cell start after `p`, or `n`. It is where the cell at `p`
    /// ends, so it is the end of what an inclusive cursor at `p` covers.
    NextCell,
    /// The last cell start before `p`, or 0.
    PreviousCell,
    /// The first start of a word of the kind after `p`, or `n`. The line
    /// break of an empty line is a word alone, and so a start.
    NextWordStart(WordKind),
    /// The first end of a word of the kind after `p`, or `n`. Empty lines
    /// are passed over: the line break of one is no end here.
    NextWordEnd(WordKind),
    /// The last start of a word of the kind before `p`, or 0.
    PreviousWordStart(WordKind),
    /// The last end of a word of the kind before `p`, or 0. The line break
    /// of an empty line is a word alone, and so an end.
    PreviousWordEnd(WordKind),
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
            Motion::NextWordStart(kind) => self.next_word_start(kind, offset),
            Motion::NextWordEnd(kind) => self.next_word_end(kind, offset),
            Motion::PreviousWordStart(kind) => self.previous_word_start(kind, offset),
            Motion::PreviousWordEnd(kind) => self.previous_word_end(kind, offset),
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

    /// What the cell that starts at the cell start `start` is to a word
    /// motion of `kind`. `None` at the end of the text, where no cell
    /// starts.
    fn cell_at(&self, kind: WordKind, start: usize) -> Option<Cell> {
        let character = self.char_at(start)?;
        let line_break = character == '\n'
            || (character == '\r' && self.char_at(start.saturating_add(1)) == Some('\n'));
        Some(if !line_break {
            word::class(kind, character).map_or(Cell::Separator, Cell::Of)
        } else if start == 0 || self.char_before(start) == Some('\n') {
            // The line break starts its row, so the row has no content.
            Cell::EmptyLine
        } else {
            Cell::Separator
        })
    }

    /// The first start of a word of `kind` after the position `offset`, or
    /// the end of the text.
    fn next_word_start(&self, kind: WordKind, offset: usize) -> usize {
        // The first cell start after the position, and the cell before it:
        // the one the position is at or, between a carriage return and its
        // line feed, inside.
        let mut at = self.cell_end(offset);
        let mut before = self.cell_at(kind, self.cell_start_before(at));
        while let Some(here) = self.cell_at(kind, at) {
            if here.starts_word_after(before) {
                return at;
            }
            before = Some(here);
            at = self.cell_end(at);
        }
        self.len()
    }

    /// The last start of a word of `kind` before the position `offset`, or
    /// 0.
    fn previous_word_start(&self, kind: WordKind, offset: usize) -> usize {
        let mut at = self.cell_start_before(offset);
        let mut here = self.cell_at(kind, at);
        // At 0 the answer is 0 whether a word starts there or not.
        while at > 0 {
            let start = self.cell_start_before(at);
            let before = self.cell_at(kind, start);
            if here.is_some_and(|here| here.starts_word_after(before)) {
                return at;
            }
            (at, here) = (start, before);
        }
        0
    }

    /// The first end of a word of `kind` after the position `offset`, the
    /// line breaks of empty lines not counted, or the end of the text.
    fn next_word_end(&self, kind: WordKind, offset: usize) -> usize {
        let mut at = self.cell_end(offset);
        let mut here = self.cell_at(kind, at);
        while let Some(cell) = here {
            let end = self.cell_end(at);
            let after = self.cell_at(kind, end);
            if cell != Cell::EmptyLine && cell.ends_word_before(after) {
                return at;
            }
            (at, here) = (end, after);
        }
        self.len()
    }

    /// The last end of a word of `kind` before the position `offset`, or 0.
    fn previous_word_end(&self, kind: WordKind, offset: usize) -> usize {
        // The last cell start before the position, and the cell after it:
        // the one at the position or, between a carriage return and its
        // line feed, after the line feed.
        let mut at = self.cell_start_before(offset);
        let mut after = self.cell_at(kind, self.cell_end(at));
        // At 0 the answer is 0 whether a word ends there or not.
        while at > 0 {
            let here = self.cell_at(kind, at);
            if here.is_some_and(|here| here.ends_word_before(after)) {
                return at;
            }
            after = here;
            at = self.cell_start_before(at);
        }
        0
    }
}

/// What a cell is to a word motion.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Cell {
    /// It is in no word: a blank, or the line break of a row that has
    /// content.
    Separator,
    /// The line break of an empty line: a word alone.
    EmptyLine,
    /// A character of a word, with its class: neighbours of one class are
    /// in one word.
    Of(word::Class),
}

impl Cell {
    /// Whether a word starts at this cell, which comes after the cell
    /// `before`, or after none at the start of the text.
    fn starts_word_after(self, before: Option<Cell>) -> bool {
        match self {
            Cell::Separator => false,
            Cell::EmptyLine => true,
            Cell::Of(_) => before != Some(self),
        }
    }

    /// Whether a word ends at this cell, which comes before the cell
    /// `after`, or before none at the end of the text.
    fn ends_word_before(self, after: Option<Cell>) -> bool {
        match self {
            Cell::Separator => false,
            Cell::EmptyLine => true,
            Cell::Of(_) => after != Some(self),
        }
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
    const MOTIONS: [Motion; 15] = [
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

    /// What the motion `motion` makes for a word and for a WORD answers
    /// from every position of `text`.
    fn answers_of_both(text: &str, motion: fn(WordKind) -> Motion) -> [Vec<usize>; 2] {
        [
            answers(text, motion(WordKind::Word)),
            answers(text, motion(WordKind::BigWord)),
        ]
    }

    #[test]
    fn the_next_word_start_is_the_first_start_of_a_word_after_the_position() {
        // The words: `foo` at 0, `.` at 3, `bar` at 4, `x` at 9, the empty
        // line at 12, `s`, `e`, the combining acute and "😀" at 15, `!` at
        // 23, `y` at 25 and `end` at 27.
        assert_eq!(
            answers(FIXTURE, Motion::NextWordStart(WordKind::Word)),
            [
                3, 3, 3, 4, 9, 9, 9, 9, 9, 12, 12, 12, 15, 15, 15, 23, 23, 23, 23, 25, 25, 27, 27,
                30, 30, 30, 30
            ]
        );
    }

    #[test]
    fn the_next_big_word_start_passes_over_punctuation_inside_a_run_that_has_no_blank() {
        // The WORDs: `foo.bar` at 0, `x` at 9, the empty line at 12, the
        // run from `s` to `!` at 15, `y` at 25 and `end` at 27.
        assert_eq!(
            answers(FIXTURE, Motion::NextWordStart(WordKind::BigWord)),
            [
                9, 9, 9, 9, 9, 9, 9, 9, 9, 12, 12, 12, 15, 15, 15, 25, 25, 25, 25, 25, 25, 27, 27,
                30, 30, 30, 30
            ]
        );
    }

    #[test]
    fn the_previous_word_start_is_the_last_start_of_a_word_before_the_position() {
        assert_eq!(
            answers(FIXTURE, Motion::PreviousWordStart(WordKind::Word)),
            [
                0, 0, 0, 0, 3, 4, 4, 4, 4, 4, 9, 9, 9, 12, 12, 12, 15, 15, 15, 15, 23, 23, 25, 25,
                27, 27, 27
            ]
        );
        assert_eq!(
            answers(FIXTURE, Motion::PreviousWordStart(WordKind::BigWord)),
            [
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9, 9, 9, 12, 12, 12, 15, 15, 15, 15, 15, 15, 25, 25,
                27, 27, 27
            ]
        );
    }

    #[test]
    fn a_line_of_blanks_holds_no_word_and_an_empty_line_is_one() {
        // Rows: `a`, a space and a tab, an empty line, `b`, and the empty
        // last row, which has no cell.
        let text = "a\n \t\n\nb\n";
        let starts = vec![5, 5, 5, 5, 5, 6, 8, 8, 8];
        assert_eq!(
            answers_of_both(text, Motion::NextWordStart),
            [starts.clone(), starts]
        );
        let starts = vec![0, 0, 0, 0, 0, 0, 5, 6, 6];
        assert_eq!(
            answers_of_both(text, Motion::PreviousWordStart),
            [starts.clone(), starts]
        );
    }

    #[test]
    fn each_of_two_empty_lines_in_a_row_is_a_word() {
        let starts = vec![2, 2, 3, 4, 5, 5];
        assert_eq!(
            answers_of_both("a\n\n\nb", Motion::NextWordStart),
            [starts.clone(), starts]
        );
        let starts = vec![0, 0, 0, 2, 3, 4];
        assert_eq!(
            answers_of_both("a\n\n\nb", Motion::PreviousWordStart),
            [starts.clone(), starts]
        );
        // With a carriage return and a line feed, and from between the two.
        assert_eq!(
            answers("\r\n\r\n", Motion::NextWordStart(WordKind::Word)),
            [2, 2, 4, 4, 4]
        );
        assert_eq!(
            answers("\r\n\r\n", Motion::PreviousWordStart(WordKind::Word)),
            [0, 0, 0, 2, 2]
        );
        assert_eq!(
            answers("a\r\n\r\nb", Motion::NextWordStart(WordKind::Word)),
            [3, 3, 3, 5, 5, 6, 6]
        );
    }

    #[test]
    fn a_text_that_is_one_line_break_holds_one_word_and_its_empty_last_row_none() {
        assert_eq!(
            answers_of_both("\n", Motion::NextWordStart),
            [[1, 1], [1, 1]]
        );
        assert_eq!(
            answers_of_both("\n", Motion::PreviousWordStart),
            [[0, 0], [0, 0]]
        );
    }

    #[test]
    fn a_text_of_blanks_only_has_no_word_start() {
        for text in ["  ", " \t\n \n"] {
            let positions = positions(text).len();
            assert_eq!(
                answers_of_both(text, Motion::NextWordStart),
                [vec![text.len(); positions], vec![text.len(); positions]],
                "{text:?}"
            );
            assert_eq!(
                answers_of_both(text, Motion::PreviousWordStart),
                [vec![0; positions], vec![0; positions]],
                "{text:?}"
            );
        }
    }

    #[test]
    fn a_carriage_return_with_no_line_feed_after_it_is_punctuation() {
        assert_eq!(
            answers_of_both("x\r", Motion::NextWordStart),
            [[1, 2, 2], [2, 2, 2]]
        );
        assert_eq!(
            answers_of_both("x\r", Motion::PreviousWordStart),
            [[0, 0, 1], [0, 0, 0]]
        );
    }

    #[test]
    fn the_next_word_end_is_the_first_last_cell_of_a_word_after_the_position() {
        // Where the words end: `foo` at 2, `.` at 3, `bar` at 6, `x` at 9,
        // the run from `s` at "😀", 19, `!` at 23, `y` at 25 and `end` at
        // 29. The empty line at 12 is passed over.
        assert_eq!(
            answers(FIXTURE, Motion::NextWordEnd(WordKind::Word)),
            [
                2, 2, 3, 6, 6, 6, 9, 9, 9, 19, 19, 19, 19, 19, 19, 19, 19, 19, 23, 25, 25, 29, 29,
                29, 29, 30, 30
            ]
        );
        // Where the WORDs end: `foo.bar` at 6, `x` at 9, the run from `s`
        // at `!`, 23, `y` at 25 and `end` at 29.
        assert_eq!(
            answers(FIXTURE, Motion::NextWordEnd(WordKind::BigWord)),
            [
                6, 6, 6, 6, 6, 6, 9, 9, 9, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 25, 25, 29, 29,
                29, 29, 30, 30
            ]
        );
    }

    #[test]
    fn the_previous_word_end_is_the_last_last_cell_of_a_word_before_the_position() {
        // The empty line at 12 is an end here.
        assert_eq!(
            answers(FIXTURE, Motion::PreviousWordEnd(WordKind::Word)),
            [
                0, 0, 0, 2, 3, 3, 3, 6, 6, 6, 9, 9, 9, 12, 12, 12, 12, 12, 12, 19, 23, 23, 25, 25,
                25, 25, 29
            ]
        );
        assert_eq!(
            answers(FIXTURE, Motion::PreviousWordEnd(WordKind::BigWord)),
            [
                0, 0, 0, 0, 0, 0, 0, 6, 6, 6, 9, 9, 9, 12, 12, 12, 12, 12, 12, 12, 23, 23, 25, 25,
                25, 25, 29
            ]
        );
    }

    #[test]
    fn the_next_word_end_passes_over_an_empty_line_and_the_previous_stops_on_one() {
        let ends = vec![3, 3, 3, 4, 4];
        assert_eq!(
            answers_of_both("a\n\nb", Motion::NextWordEnd),
            [ends.clone(), ends]
        );
        let ends = vec![0, 0, 0, 2, 3];
        assert_eq!(
            answers_of_both("a\n\nb", Motion::PreviousWordEnd),
            [ends.clone(), ends]
        );
        // With carriage returns, and from between one and its line feed.
        assert_eq!(
            answers("a\r\n\r\nb", Motion::NextWordEnd(WordKind::Word)),
            [5, 5, 5, 5, 5, 6, 6]
        );
        assert_eq!(
            answers("a\r\n\r\nb", Motion::PreviousWordEnd(WordKind::Word)),
            [0, 0, 0, 0, 3, 3, 5]
        );
        // A line of blanks holds no end, and neither does the empty last
        // row.
        let ends = vec![6, 6, 6, 6, 6, 6, 8, 8, 8];
        assert_eq!(
            answers_of_both("a\n \t\n\nb\n", Motion::NextWordEnd),
            [ends.clone(), ends]
        );
        let ends = vec![0, 0, 0, 0, 0, 0, 5, 6, 6];
        assert_eq!(
            answers_of_both("a\n \t\n\nb\n", Motion::PreviousWordEnd),
            [ends.clone(), ends]
        );
    }

    #[test]
    fn a_word_of_one_cell_ends_where_it_starts() {
        assert_eq!(
            answers_of_both("a b", Motion::NextWordEnd),
            [[2, 2, 3, 3], [2, 2, 3, 3]]
        );
        assert_eq!(
            answers_of_both("a b", Motion::PreviousWordEnd),
            [[0, 0, 0, 2], [0, 0, 0, 2]]
        );
        // A carriage return alone is punctuation, a word after `x` and a
        // part of the WORD.
        assert_eq!(
            answers_of_both("x\r", Motion::NextWordEnd),
            [[1, 2, 2], [1, 2, 2]]
        );
        assert_eq!(
            answers_of_both("x\r", Motion::PreviousWordEnd),
            [[0, 0, 1], [0, 0, 1]]
        );
    }

    #[test]
    fn past_the_last_word_of_the_text_the_next_end_is_the_end_of_the_text() {
        assert_eq!(
            answers_of_both("ab cd", Motion::NextWordEnd),
            [[1, 4, 4, 4, 5, 5], [1, 4, 4, 4, 5, 5]]
        );
        assert_eq!(
            answers_of_both("ab cd", Motion::PreviousWordEnd),
            [[0, 0, 1, 1, 1, 4], [0, 0, 1, 1, 1, 4]]
        );
        // A text that ends in blanks, and one that ends in a line break.
        assert_eq!(
            answers("ab  ", Motion::NextWordEnd(WordKind::Word)),
            [1, 4, 4, 4, 4]
        );
        assert_eq!(
            answers("ab\n", Motion::NextWordEnd(WordKind::Word)),
            [1, 3, 3, 3]
        );
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
