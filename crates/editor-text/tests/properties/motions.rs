//! Properties of the motions: every motion from every position of a
//! generated text, compared with a reference on the `String`.
//!
//! The reference goes by another route than the crate. It lists the cells,
//! the rows and the words of the whole string first, and then picks from a
//! list: the first after a position, the last before it. The crate lists
//! nothing and walks from the position. What a word character is is stated
//! here again, in the reference's own words.

use editor_text::{Motion, Selection, SelectionRange, Shape, Snapshot, WordKind};
use proptest::collection::vec;
use proptest::prelude::*;
use proptest::sample::select;
use proptest::test_runner::TestCaseError;

use crate::{Step, check, edited, steps};

/// The pieces a text for the motions is made of: words, an underscore,
/// digits, punctuation, spaces, tabs, each line ending, a carriage return
/// alone, characters of two and four bytes, a letter with a combining mark,
/// the character a raw byte is kept as, and NUL.
const FRAGMENTS: &[&str] = &[
    "",
    "a",
    "foo",
    "bar_1",
    "_",
    "42",
    ".",
    "!?",
    "(",
    " ",
    "  ",
    "\t",
    "\n",
    "\n",
    "\r\n",
    "\r",
    "é",
    "e\u{301}",
    "😀",
    "\u{10DCFF}",
    "\0",
];

/// A text to move in, and the edits to make to it first: seven in eight
/// are short, and the eighth is a short text repeated until the rope holds
/// it in many pieces.
fn text_and_edits() -> impl Strategy<Value = (String, Vec<Step>)> {
    let short = || vec(select(FRAGMENTS), 0..=24).prop_map(|pieces| pieces.concat());
    let text = prop_oneof![
        7 => short(),
        1 => (short(), 20..200_usize).prop_map(|(text, times)| text.repeat(times)),
    ];
    (text, steps(8))
}

/// Where everything a motion asks about is in a string, listed in one walk
/// over its characters. Every list is in rising order.
struct Reference {
    /// The length of the string.
    len: usize,
    /// Where every cell starts: a character, or a carriage return and the
    /// line feed after it together.
    cell_starts: Vec<usize>,
    /// The character of each cell, in the order of `cell_starts`; `None`
    /// for a line break.
    cell_characters: Vec<Option<char>>,
    /// Every row.
    rows: Vec<Row>,
    /// Its words.
    words: Words,
    /// Its WORDs.
    big_words: Words,
}

/// The words of one kind of a string.
#[derive(Debug, Default)]
struct Words {
    /// Where each starts: at its first cell.
    starts: Vec<usize>,
    /// Where each ends: at its last cell.
    ends: Vec<usize>,
    /// Where each ends, but for the words that are the line break of an
    /// empty line.
    ends_with_content: Vec<usize>,
}

/// One word of a string.
struct Word {
    /// Where its first cell starts.
    start: usize,
    /// Where its last cell starts.
    last: usize,
    /// Whether it is the line break of an empty line.
    empty: bool,
}

/// Whether `character`, which is no blank, is a word character; for a
/// WORD every such character is of the one class.
fn is_word_character(kind: WordKind, character: char) -> bool {
    match kind {
        WordKind::Word => {
            character.is_ascii_alphanumeric() || character == '_' || u32::from(character) >= 0x80
        }
        WordKind::BigWord => true,
    }
}

/// One row of a string.
#[derive(Debug, Clone, Copy)]
struct Row {
    /// Where it starts.
    start: usize,
    /// Where its content ends: where its line break starts, or the end of
    /// the string.
    content: usize,
}

/// The first of `sorted`, which is in rising order, after `offset`.
fn first_after(sorted: &[usize], offset: usize) -> Option<usize> {
    sorted
        .get(sorted.partition_point(|&at| at <= offset))
        .copied()
}

/// The last of `sorted`, which is in rising order, before `offset`.
fn last_before(sorted: &[usize], offset: usize) -> Option<usize> {
    sorted[..sorted.partition_point(|&at| at < offset)]
        .last()
        .copied()
}

impl Reference {
    /// The reference for `string`.
    fn of(string: &str) -> Self {
        let (mut cell_starts, mut cell_characters) = (Vec::new(), Vec::new());
        let mut rows = Vec::new();
        let mut row_start = 0;
        let mut characters = string.char_indices().peekable();
        while let Some((start, character)) = characters.next() {
            cell_starts.push(start);
            // A carriage return and the line feed after it are one cell.
            let paired =
                character == '\r' && characters.peek().is_some_and(|&(_, next)| next == '\n');
            if paired {
                characters.next();
            }
            if paired || character == '\n' {
                cell_characters.push(None);
                rows.push(Row {
                    start: row_start,
                    content: start,
                });
                row_start = start + 1 + usize::from(paired);
            } else {
                cell_characters.push(Some(character));
            }
        }
        rows.push(Row {
            start: row_start,
            content: string.len(),
        });
        let mut reference = Self {
            len: string.len(),
            cell_starts,
            cell_characters,
            rows,
            words: Words::default(),
            big_words: Words::default(),
        };
        reference.words = reference.list(WordKind::Word);
        reference.big_words = reference.list(WordKind::BigWord);
        reference
    }

    /// The words of `kind`, listed in one walk over the cells: a longest
    /// run of cells of one class, or the line break of a row with no
    /// content, alone. A blank and any other line break are in none.
    fn list(&self, kind: WordKind) -> Words {
        let mut words: Vec<Word> = Vec::new();
        // The class of the word the cell before is in, when it is in a
        // run.
        let mut open = None;
        for (&start, &character) in self.cell_starts.iter().zip(&self.cell_characters) {
            match character {
                None => {
                    if self.row_of(start).start == start {
                        words.push(Word {
                            start,
                            last: start,
                            empty: true,
                        });
                    }
                    open = None;
                }
                Some(' ' | '\t') => open = None,
                Some(character) => {
                    let class = is_word_character(kind, character);
                    match words.last_mut() {
                        Some(word) if open == Some(class) => word.last = start,
                        _ => words.push(Word {
                            start,
                            last: start,
                            empty: false,
                        }),
                    }
                    open = Some(class);
                }
            }
        }
        Words {
            starts: words.iter().map(|word| word.start).collect(),
            ends: words.iter().map(|word| word.last).collect(),
            ends_with_content: words
                .iter()
                .filter(|word| !word.empty)
                .map(|word| word.last)
                .collect(),
        }
    }

    /// The words of `kind`.
    fn words(&self, kind: WordKind) -> &Words {
        match kind {
            WordKind::Word => &self.words,
            WordKind::BigWord => &self.big_words,
        }
    }

    /// The row the position `offset` is in: the last that starts at or
    /// before it.
    fn row_of(&self, offset: usize) -> Row {
        let after = self.rows.partition_point(|row| row.start <= offset);
        self.rows[after - 1]
    }

    /// The cells of the content of `row`, each as where it starts and its
    /// character.
    fn content_of(&self, row: Row) -> impl Iterator<Item = (usize, Option<char>)> + '_ {
        let first = self.cell_starts.partition_point(|&start| start < row.start);
        let after = self
            .cell_starts
            .partition_point(|&start| start < row.content);
        (first..after).map(|index| (self.cell_starts[index], self.cell_characters[index]))
    }

    /// What `motion` answers from the position `offset`.
    fn motion(&self, motion: Motion, offset: usize) -> usize {
        match motion {
            Motion::NextCell => first_after(&self.cell_starts, offset).unwrap_or(self.len),
            Motion::PreviousCell => last_before(&self.cell_starts, offset).unwrap_or(0),
            Motion::NextWordStart(kind) => {
                first_after(&self.words(kind).starts, offset).unwrap_or(self.len)
            }
            Motion::NextWordEnd(kind) => {
                first_after(&self.words(kind).ends_with_content, offset).unwrap_or(self.len)
            }
            Motion::PreviousWordStart(kind) => {
                last_before(&self.words(kind).starts, offset).unwrap_or(0)
            }
            Motion::PreviousWordEnd(kind) => {
                last_before(&self.words(kind).ends, offset).unwrap_or(0)
            }
            Motion::LineStart => self.row_of(offset).start,
            Motion::LineEnd => self.row_of(offset).content,
            Motion::LineFirstNonBlank => {
                let row = self.row_of(offset);
                self.content_of(row)
                    .find(|&(_, character)| !matches!(character, Some(' ' | '\t')))
                    .map_or(row.content, |(start, _)| start)
            }
            Motion::TextStart => 0,
            Motion::TextEnd => self.len,
            Motion::RowsUp { count, column } => {
                self.at_column(self.row_index_of(offset).saturating_sub(count), column)
            }
            Motion::RowsDown { count, column } => {
                let row = self.row_index_of(offset).saturating_add(count);
                self.at_column(row.min(self.rows.len() - 1), column)
            }
        }
    }

    /// Which row the position `offset` is in.
    fn row_index_of(&self, offset: usize) -> usize {
        self.rows.partition_point(|row| row.start <= offset) - 1
    }

    /// Where the cell `column` of the content of the row `row` starts, or
    /// where the content ends when it has no such cell.
    fn at_column(&self, row: usize, column: usize) -> usize {
        let row = self.rows[row];
        self.content_of(row)
            .nth(column)
            .map_or(row.content, |(start, _)| start)
    }
}

/// A count of rows or a column for a row motion: small ones, which land
/// inside a text, and the largest there is.
fn count_or_column() -> impl Strategy<Value = usize> {
    prop_oneof![
        8 => 0..12_usize,
        1 => Just(usize::MAX),
    ]
}

/// The row motions, up and down, with each count and column of `rows`.
fn row_motions(rows: &[(usize, usize)]) -> Vec<Motion> {
    rows.iter()
        .flat_map(|&(count, column)| {
            [
                Motion::RowsUp { count, column },
                Motion::RowsDown { count, column },
            ]
        })
        .collect()
}

/// Every motion the properties ask that takes no count and no column.
fn motions() -> Vec<Motion> {
    vec![
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
    ]
}

/// Where what an inclusive cursor at the position `offset` covers ends.
fn cursor_end(snapshot: &Snapshot, offset: usize) -> Result<usize, TestCaseError> {
    let cursor = Selection::shaped(
        Shape::Inclusive,
        vec![SelectionRange::new(offset, offset)],
        0,
    )
    .ok_or_else(|| TestCaseError::fail("a cursor is a selection"))?;
    match snapshot.extents(&cursor).as_deref() {
        Some([extent]) => Ok(extent.end),
        other => Err(TestCaseError::fail(format!(
            "a cursor at {offset} covers {other:?}"
        ))),
    }
}

#[test]
fn every_motion_agrees_with_a_reference_on_a_string_at_every_position() {
    let rows = vec((count_or_column(), count_or_column()), 3);

    check(128, (text_and_edits(), rows), |((initial, steps), rows)| {
        let (snapshot, string) = edited(initial, &steps);
        let reference = Reference::of(&string);
        let mut motions = motions();
        motions.extend(row_motions(&rows));

        // To two past the end: those offsets are not positions either.
        for offset in 0..=string.len() + 2 {
            for &motion in &motions {
                let answer = snapshot.motion(motion, offset);
                if string.is_char_boundary(offset) {
                    prop_assert_eq!(
                        answer,
                        Some(reference.motion(motion, offset)),
                        "{:?} from {}",
                        motion,
                        offset
                    );
                    // Every answer is a position.
                    prop_assert!(answer.is_some_and(|answer| string.is_char_boundary(answer)));
                } else {
                    prop_assert_eq!(answer, None, "{:?} from {}", motion, offset);
                }
            }
        }
        Ok(())
    });
}

#[test]
fn the_next_cell_is_where_what_an_inclusive_cursor_covers_ends() {
    check(128, text_and_edits(), |(initial, steps)| {
        let (snapshot, string) = edited(initial, &steps);

        for offset in (0..=string.len()).filter(|&offset| string.is_char_boundary(offset)) {
            prop_assert_eq!(
                snapshot.motion(Motion::NextCell, offset),
                Some(cursor_end(&snapshot, offset)?),
                "from {}",
                offset
            );
        }
        Ok(())
    });
}

#[test]
fn a_row_motion_of_no_rows_at_a_positions_own_column_gives_the_position_back() {
    // A column in cells is counted by walking the row, so asking every
    // position of a row costs the square of its length, and a generated
    // text may be one row: the long texts are kilobytes here.
    let short = || vec(select(FRAGMENTS), 0..=24).prop_map(|pieces| pieces.concat());
    let text = prop_oneof![
        7 => short(),
        1 => (short(), 20..60_usize).prop_map(|(text, times)| text.repeat(times)),
    ];

    check(128, (text, steps(8)), |(initial, steps)| {
        let (snapshot, string) = edited(initial, &steps);
        let reference = Reference::of(&string);

        for offset in (0..=string.len()).filter(|&offset| string.is_char_boundary(offset)) {
            let Some(point) = snapshot.offset_to_point_cells(offset) else {
                return Err(TestCaseError::fail(format!("{offset} has no point")));
            };
            for stay in [
                Motion::RowsDown {
                    count: 0,
                    column: point.column,
                },
                Motion::RowsUp {
                    count: 0,
                    column: point.column,
                },
            ] {
                // A position in or after its row's line break is past the
                // content, which the motion never passes.
                let content = reference.row_of(offset).content;
                prop_assert_eq!(
                    snapshot.motion(stay, offset),
                    Some(offset.min(content)),
                    "{:?} from {}",
                    stay,
                    offset
                );
            }
        }
        Ok(())
    });
}
