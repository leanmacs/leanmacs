//! Properties of the motions: every motion from every position of a
//! generated text, compared with a reference on the `String`.
//!
//! The reference goes by another route than the crate. It lists the cells
//! of the whole string first, and then picks from the list: the first after
//! a position, the last before it. The crate lists nothing and walks from
//! the position.

use editor_text::{Motion, Selection, SelectionRange, Shape, Snapshot};
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
        let mut cell_starts = Vec::new();
        let mut characters = string.char_indices().peekable();
        while let Some((start, character)) = characters.next() {
            cell_starts.push(start);
            // A carriage return and the line feed after it are one cell.
            if character == '\r' && characters.peek().is_some_and(|&(_, next)| next == '\n') {
                characters.next();
            }
        }
        Self {
            len: string.len(),
            cell_starts,
        }
    }

    /// What `motion` answers from the position `offset`.
    fn motion(&self, motion: Motion, offset: usize) -> usize {
        match motion {
            Motion::NextCell => first_after(&self.cell_starts, offset).unwrap_or(self.len),
            Motion::PreviousCell => last_before(&self.cell_starts, offset).unwrap_or(0),
            Motion::TextStart => 0,
            Motion::TextEnd => self.len,
        }
    }
}

/// Every motion the properties ask.
fn motions() -> Vec<Motion> {
    vec![
        Motion::NextCell,
        Motion::PreviousCell,
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
    check(128, text_and_edits(), |(initial, steps)| {
        let (snapshot, string) = edited(initial, &steps);
        let reference = Reference::of(&string);

        // To two past the end: those offsets are not positions either.
        for offset in 0..=string.len() + 2 {
            for motion in motions() {
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
