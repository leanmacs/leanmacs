//! Property tests of the crate, through its public API alone.
//!
//! Each property drives a [`Text`] and a reference, a `String`, with the
//! same generated steps and compares the two.
//!
//! # Deterministic and hermetic
//!
//! Every property runs through [`check`], which fixes what decides a pass:
//! the number of cases and the generator's seed. It turns failure
//! persistence off, so no `proptest-regressions` file is written beside the
//! sources. `proptest`'s default configuration reads `PROPTEST_*` variables
//! from the environment, so the `proptest!` macro is not used, and every
//! collection strategy below states its own size. The library is built
//! without its default features: no fork, no timeout, no temporary file.
//! What the environment can still change is how a failure is shrunk and
//! printed.
//!
//! # What the generators favour
//!
//! Text that breaks index code: characters of one to four bytes (the last
//! is two UTF-16 units), every line ending, the escape characters a raw
//! byte is kept as, U+FFFD, NUL and the empty string. One case in eight
//! is a text of kilobytes to hundreds of kilobytes, which the rope holds
//! in many pieces.

use std::fmt::Debug;
use std::ops::Range;

use editor_text::{Change, ChangeSet, Edit, Point, PointCells, PointUtf16, Snapshot, Text};
use proptest::collection::vec;
use proptest::prelude::*;
use proptest::sample::select;
use proptest::test_runner::{Config, RngAlgorithm, TestCaseError, TestRng, TestRunner};

mod anchors;
mod changes;
mod excerpts;
mod files;
mod inverses;
mod log;
mod motions;
mod selections;

/// Runs `property` on `cases` values of `strategy`, from a fixed seed, and
/// panics with the smallest failing value if one fails.
fn check<S>(cases: u32, strategy: S, property: impl Fn(S::Value) -> Result<(), TestCaseError>)
where
    S: Strategy,
    S::Value: Debug,
{
    let config = Config {
        cases,
        failure_persistence: None,
        ..Config::default()
    };
    let mut runner =
        TestRunner::new_with_rng(config, TestRng::deterministic_rng(RngAlgorithm::ChaCha));
    if let Err(failure) = runner.run(&strategy, property) {
        panic!("{failure}");
    }
}

/// The pieces a generated text is made of.
const FRAGMENTS: &[&str] = &[
    "",
    "a",
    "b",
    " ",
    "hello",
    "\n",
    "\n",
    "\r",
    "\r\n",
    "\0",
    // Two, three and four bytes; the last is two UTF-16 units.
    "é",
    "ö",
    "€",
    "😀",
    "\u{FFFD}",
    // The characters the bytes 0x80 and 0xFF are kept as.
    "\u{10DC80}",
    "\u{10DCFF}",
];

/// A text of up to `fragments` pieces of [`FRAGMENTS`].
fn short_text(fragments: usize) -> impl Strategy<Value = String> {
    vec(select(FRAGMENTS), 0..=fragments).prop_map(|pieces| pieces.concat())
}

/// A text to start from: seven in eight are short, and the eighth is a
/// short text repeated until the rope holds it in many pieces.
fn initial_text() -> impl Strategy<Value = String> {
    initial_text_repeated(200..4_000)
}

/// [`initial_text`], with the long texts shorter: tens of kilobytes at
/// most, still in many pieces. For the properties that visit every offset
/// of the text.
fn initial_text_to_walk() -> impl Strategy<Value = String> {
    initial_text_repeated(20..400)
}

/// A text to start from: seven in eight are short, and the eighth is a
/// short text repeated a number of times in `times`.
fn initial_text_repeated(times: Range<usize>) -> impl Strategy<Value = String> {
    prop_oneof![
        7 => short_text(24),
        1 => (short_text(24), times).prop_map(|(text, times)| text.repeat(times)),
    ]
}

/// One generated edit, before it is fitted to a text.
#[derive(Debug, Clone)]
struct Step {
    /// Where the range starts, as a number to cut down to the text.
    start: usize,
    /// Where the range ends, likewise.
    end: usize,
    /// Whether to move both offsets onto character boundaries and put them
    /// in order, so that the edit is one the text accepts.
    fitted: bool,
    /// What to put in place of the range.
    insert: String,
}

impl Step {
    /// The range this step names in `reference`. Unfitted, an offset may be
    /// inside a character, up to two past the end, or after the other one.
    fn range(&self, reference: &str) -> (usize, usize) {
        let reach = reference.len() + 3;
        let (start, end) = (self.start % reach, self.end % reach);
        if !self.fitted {
            return (start, end);
        }
        let (start, end) = (floor(reference, start), floor(reference, end));
        (start.min(end), start.max(end))
    }
}

/// The last character boundary of `reference` at or before `offset`.
fn floor(reference: &str, offset: usize) -> usize {
    let mut offset = offset.min(reference.len());
    while !reference.is_char_boundary(offset) {
        offset -= 1;
    }
    offset
}

/// Up to `steps` edits, three in four of them fitted.
fn steps(steps: usize) -> impl Strategy<Value = Vec<Step>> {
    let step = (
        any::<usize>(),
        any::<usize>(),
        prop::bool::weighted(0.75),
        short_text(6),
    )
        .prop_map(|(start, end, fitted, insert)| Step {
            start,
            end,
            fitted,
            insert,
        });
    vec(step, 0..=steps)
}

/// Whether a replace of `start..end` is one a text holding `reference`
/// accepts: both offsets are character boundaries within it, in order.
fn accepts(reference: &str, start: usize, end: usize) -> bool {
    start <= end && reference.is_char_boundary(start) && reference.is_char_boundary(end)
}

/// One generated change set, before it is fitted to a text.
#[derive(Debug, Clone)]
struct Walk {
    /// How far into the text the first change is, as a number to cut down
    /// to the text.
    start: usize,
    /// The changes to make from there on, in order.
    strides: Vec<Stride>,
    /// What to insert at the end of the text.
    tail: String,
    /// Whether the change set is cut to the text, so that the text accepts
    /// it, and otherwise how it ends.
    end: WalkEnd,
}

/// One change of a [`Walk`] over the next bytes of the text.
#[derive(Debug, Clone)]
struct Stride {
    /// What to do with the bytes.
    kind: StrideKind,
    /// One less than how many bytes, before they are cut to the text.
    len: usize,
    /// What to insert, for the kinds that insert.
    insert: String,
}

/// What a [`Stride`] does with its bytes.
#[derive(Debug, Clone, Copy)]
enum StrideKind {
    /// Keeps them.
    Retain,
    /// Removes them.
    Delete,
    /// Inserts before them and keeps them.
    Insert,
    /// Puts the insert in their place.
    Replace,
}

/// How a [`Walk`] ends.
#[derive(Debug, Clone, Copy)]
enum WalkEnd {
    /// Every length is moved onto a character boundary and the rest of the
    /// text is retained: a change set the text accepts.
    Fitted,
    /// The lengths are taken as generated, so one may cut a character or
    /// run past the end; the rest of the text is retained.
    Raw,
    /// As `Raw`, and the last byte of the rest is not retained.
    Short,
    /// As `Raw`, and one byte more than the rest is retained.
    Long,
}

impl Walk {
    /// The change set this walk makes over `reference`.
    fn changes(&self, reference: &str) -> ChangeSet {
        let fitted = matches!(self.end, WalkEnd::Fitted);
        let len = reference.len();
        let mut changes = ChangeSet::new();
        let mut at = if fitted {
            floor(reference, self.start % (len + 1))
        } else {
            self.start % (len + 3)
        };
        changes.retain(at);
        for stride in &self.strides {
            if at >= len {
                break;
            }
            let mut end = at + 1 + stride.len;
            if fitted {
                end = end.min(len);
                while !reference.is_char_boundary(end) {
                    end += 1;
                }
            }
            match stride.kind {
                StrideKind::Retain => changes.retain(end - at),
                StrideKind::Delete => changes.delete(end - at),
                StrideKind::Insert => {
                    changes.insert(&stride.insert);
                    changes.retain(end - at);
                }
                StrideKind::Replace => {
                    changes.delete(end - at);
                    changes.insert(&stride.insert);
                }
            }
            at = end;
        }
        let rest = len.saturating_sub(at);
        changes.retain(match self.end {
            WalkEnd::Fitted | WalkEnd::Raw => rest,
            WalkEnd::Short => rest.saturating_sub(1),
            WalkEnd::Long => rest + 1,
        });
        changes.insert(&self.tail);
        changes
    }
}

/// A change set to fit to a text: three in four are fitted.
fn walk() -> impl Strategy<Value = Walk> {
    walk_ending(prop_oneof![
        9 => Just(WalkEnd::Fitted),
        1 => Just(WalkEnd::Raw),
        1 => Just(WalkEnd::Short),
        1 => Just(WalkEnd::Long),
    ])
}

/// A change set that is fitted to its text, so the text accepts it.
fn fitted_walk() -> impl Strategy<Value = Walk> {
    walk_ending(Just(WalkEnd::Fitted))
}

/// A change set to fit to a text, which ends as `end` says.
fn walk_ending(end: impl Strategy<Value = WalkEnd>) -> impl Strategy<Value = Walk> {
    let stride = (
        select(
            &[
                StrideKind::Retain,
                StrideKind::Retain,
                StrideKind::Delete,
                StrideKind::Insert,
                StrideKind::Replace,
            ][..],
        ),
        0..6_usize,
        short_text(2),
    )
        .prop_map(|(kind, len, insert)| Stride { kind, len, insert });
    let tail = prop_oneof![
        2 => Just(String::new()),
        1 => short_text(2),
    ];
    (any::<usize>(), vec(stride, 0..=6), tail, end).prop_map(|(start, strides, tail, end)| Walk {
        start,
        strides,
        tail,
        end,
    })
}

/// Up to `walks` change sets, three in four of them fitted.
fn walks(walks: usize) -> impl Strategy<Value = Vec<Walk>> {
    vec(walk(), 0..=walks)
}

/// Up to `walks` change sets, each fitted to its text.
fn fitted_walks(walks: usize) -> impl Strategy<Value = Vec<Walk>> {
    vec(fitted_walk(), 0..=walks)
}

/// `old` with each edit's old range replaced by the bytes of its new range
/// in `new`.
fn patched(old: &str, new: &str, edits: &[Edit]) -> String {
    let mut made = String::new();
    let mut kept_from = 0;
    for edit in edits {
        made.push_str(&old[kept_from..edit.old.start]);
        made.push_str(&new[edit.new.start..edit.new.end]);
        kept_from = edit.old.end;
    }
    made.push_str(&old[kept_from..]);
    made
}

/// What `changes` makes of `reference`, applied naively: `None` unless the
/// change set is for the string's length and every boundary between its
/// changes is a character boundary of the string.
fn applied(changes: &ChangeSet, reference: &str) -> Option<String> {
    if changes.len_before() != reference.len() {
        return None;
    }
    let mut made = String::new();
    let mut at = 0_usize;
    for change in changes.changes() {
        match change {
            Change::Retain(len) => {
                let end = at.checked_add(*len)?;
                made.push_str(reference.get(at..end)?);
                at = end;
            }
            Change::Delete(len) => {
                let end = at.checked_add(*len)?;
                reference.get(at..end)?;
                at = end;
            }
            Change::Insert(text) => made.push_str(text),
        }
    }
    Some(made)
}

#[test]
fn edits_agree_with_a_string() {
    check(256, (initial_text(), steps(16)), |(initial, steps)| {
        let mut reference = initial;
        let mut text = Text::from(reference.as_str());
        let mut accepted = 0;

        for step in steps {
            let (start, end) = step.range(&reference);
            let expected = accepts(&reference, start, end);

            let result = text.replace(start..end, &step.insert);

            prop_assert_eq!(result.is_ok(), expected, "replace {}..{}", start, end);
            if expected {
                reference.replace_range(start..end, &step.insert);
                accepted += 1;
            }
            prop_assert_eq!(&text.current().to_string(), &reference);
            prop_assert_eq!(text.current().len(), reference.len());
            prop_assert_eq!(text.current().revision().get(), accepted);
        }
        Ok(())
    });
}

#[test]
fn a_snapshot_is_unaffected_by_later_edits() {
    /// The most edits in a case.
    const STEPS: usize = 16;
    // Whether to take a snapshot before each step, and after the last.
    let takes = vec(any::<bool>(), STEPS + 1);

    check(
        256,
        (initial_text(), steps(STEPS), takes),
        |(initial, steps, takes)| {
            let mut reference = initial;
            let mut text = Text::from(reference.as_str());
            let mut accepted = 0;
            // Each snapshot, with what the text held and its revision then.
            let mut taken = Vec::new();

            for (index, step) in steps.iter().enumerate() {
                if takes[index] {
                    taken.push((text.snapshot(), reference.clone(), accepted));
                }
                let (start, end) = step.range(&reference);
                if text.replace(start..end, &step.insert).is_ok() {
                    reference.replace_range(start..end, &step.insert);
                    accepted += 1;
                }
            }
            if takes[steps.len()] {
                taken.push((text.snapshot(), reference.clone(), accepted));
            }

            for (snapshot, expected, revision) in &taken {
                prop_assert_eq!(&snapshot.to_string(), expected);
                prop_assert_eq!(snapshot.revision().get(), *revision);
            }
            drop(text);
            for (snapshot, expected, revision) in &taken {
                prop_assert_eq!(&snapshot.clone().to_string(), expected);
                prop_assert_eq!(snapshot.len(), expected.len());
                prop_assert_eq!(snapshot.revision().get(), *revision);
            }
            Ok(())
        },
    );
}

/// A text to ask positions of, and what it holds: `initial` after `steps`.
/// The edits matter: they leave the rope's pieces uneven, as a text that
/// was only ever loaded does not.
fn edited(initial: String, steps: &[Step]) -> (Snapshot, String) {
    let mut reference = initial;
    let mut text = Text::from(reference.as_str());
    for step in steps {
        let (start, end) = step.range(&reference);
        if text.replace(start..end, &step.insert).is_ok() {
            reference.replace_range(start..end, &step.insert);
        }
    }
    (text.snapshot(), reference)
}

/// The strategy of the properties about positions: a text to walk, and the
/// edits to make to it first.
fn text_and_edits() -> impl Strategy<Value = (String, Vec<Step>)> {
    (initial_text_to_walk(), steps(8))
}

/// Where everything in a string is, from one walk over its characters:
/// what the conversions are compared with.
struct Reference {
    /// The bytes of each row, without the line feed that ends it.
    rows: Vec<Range<usize>>,
    /// For each offset from 0 to the string's length: `None` inside a
    /// character, and otherwise the row, the column in bytes and the column
    /// in UTF-16 code units.
    places: Vec<Option<(usize, usize, usize)>>,
}

impl Reference {
    /// The reference for `string`. A row ends at a line feed and nowhere
    /// else.
    fn of(string: &str) -> Self {
        let mut rows = Vec::new();
        let mut places = vec![None; string.len() + 1];
        let (mut row_start, mut units) = (0, 0);
        for (offset, character) in string.char_indices() {
            places[offset] = Some((rows.len(), offset - row_start, units));
            if character == '\n' {
                rows.push(row_start..offset);
                row_start = offset + 1;
                units = 0;
            } else {
                units += character.len_utf16();
            }
        }
        places[string.len()] = Some((rows.len(), string.len() - row_start, units));
        rows.push(row_start..string.len());
        Self { rows, places }
    }

    /// The place of `offset`; `None` inside a character and past the end.
    fn place(&self, offset: usize) -> Option<(usize, usize, usize)> {
        self.places.get(offset).copied().flatten()
    }

    /// The point of `offset` with its column in bytes.
    fn point(&self, offset: usize) -> Option<Point> {
        self.place(offset)
            .map(|(row, column, _)| Point::new(row, column))
    }

    /// The point of `offset` with its column in UTF-16 code units.
    fn point_utf16(&self, offset: usize) -> Option<PointUtf16> {
        self.place(offset)
            .map(|(row, _, column)| PointUtf16::new(row, column))
    }

    /// The offset of the position at the byte column `column` of `row`.
    fn offset(&self, row: usize, column: usize) -> Option<usize> {
        let range = self.rows.get(row)?;
        let offset = range.start.checked_add(column)?;
        (offset <= range.end && self.place(offset).is_some()).then_some(offset)
    }

    /// For each UTF-16 column of `row`, from 0 to its length in bytes and
    /// two past it: the offset of the position there, or `None` when the
    /// column is between the two units of a character or past the row's
    /// end. A row has no more code units than bytes. Empty for a row the
    /// string does not have.
    fn offsets_utf16(&self, row: usize) -> Vec<Option<usize>> {
        let Some(range) = self.rows.get(row) else {
            return Vec::new();
        };
        let mut offsets = vec![None; range.len() + 3];
        for offset in range.start..=range.end {
            if let Some((_, _, units)) = self.place(offset) {
                offsets[units] = Some(offset);
            }
        }
        offsets
    }
}

#[test]
fn byte_points_round_trip_at_every_position() {
    check(256, text_and_edits(), |(initial, steps)| {
        let (snapshot, string) = edited(initial, &steps);

        // To two past the end: those offsets are not positions either.
        for offset in 0..=string.len() + 2 {
            match snapshot.offset_to_point(offset) {
                Some(point) => {
                    prop_assert!(string.is_char_boundary(offset), "{} has a point", offset);
                    prop_assert_eq!(snapshot.point_to_offset(point), Some(offset));
                }
                None => prop_assert!(!string.is_char_boundary(offset), "{} has none", offset),
            }
        }
        Ok(())
    });
}

#[test]
fn utf16_points_round_trip_at_every_position() {
    check(256, text_and_edits(), |(initial, steps)| {
        let (snapshot, string) = edited(initial, &steps);

        for offset in 0..=string.len() + 2 {
            match snapshot.offset_to_point_utf16(offset) {
                Some(point) => {
                    prop_assert!(string.is_char_boundary(offset), "{} has a point", offset);
                    prop_assert_eq!(snapshot.point_utf16_to_offset(point), Some(offset));
                }
                None => prop_assert!(!string.is_char_boundary(offset), "{} has none", offset),
            }
        }
        Ok(())
    });
}

#[test]
fn cell_points_round_trip_at_every_position_and_count_the_characters_before_it_in_its_row() {
    // A column in cells is counted by walking the row, so asking every
    // position of a row costs the square of its length, and a generated
    // text may be one row: the long texts are kilobytes here, still in
    // several pieces.
    let text = (initial_text_repeated(20..100), steps(8));

    check(256, text, |(initial, steps)| {
        let (snapshot, string) = edited(initial, &steps);
        let reference = Reference::of(&string);
        // For each position, how many characters of its row are before it:
        // within a row every character starts a cell.
        let mut characters = vec![0; string.len() + 1];
        let mut column = 0;
        for (offset, character) in string.char_indices() {
            characters[offset] = column;
            column = if character == '\n' { 0 } else { column + 1 };
        }
        characters[string.len()] = column;

        // To two past the end: those offsets are not positions either.
        for offset in 0..=string.len() + 2 {
            let expected = reference
                .place(offset)
                .zip(characters.get(offset))
                .map(|((row, _, _), &column)| PointCells::new(row, column));
            let point = snapshot.offset_to_point_cells(offset);
            prop_assert_eq!(point, expected, "{}", offset);
            if let Some(point) = point {
                prop_assert_eq!(snapshot.point_cells_to_offset(point), Some(offset));
            }
        }
        // The last column of a row is the position before its line feed,
        // or the end of the text, and the next names nothing.
        for (row, range) in reference.rows.iter().enumerate() {
            let last = characters[range.end];
            prop_assert_eq!(
                snapshot.point_cells_to_offset(PointCells::new(row, last)),
                Some(range.end)
            );
            prop_assert_eq!(
                snapshot.point_cells_to_offset(PointCells::new(row, last + 1)),
                None
            );
        }
        prop_assert_eq!(
            snapshot.point_cells_to_offset(PointCells::new(reference.rows.len(), 0)),
            None
        );
        Ok(())
    });
}

#[test]
fn a_point_that_converts_names_the_offset_that_converts_back() {
    // Rows and columns as numbers to cut down to the text: some land on a
    // position, and some inside a character, past a row's end or in a row
    // the text does not have.
    let points = vec((any::<usize>(), any::<usize>()), 0..=64);

    check(
        256,
        (text_and_edits(), points),
        |((initial, steps), points)| {
            let (snapshot, string) = edited(initial, &steps);
            let reference = Reference::of(&string);

            for (row, column) in points {
                let row = row % (reference.rows.len() + 2);
                let row_length = reference.rows.get(row).map_or(0, |row| row.len());
                let column = column % (row_length + 3);

                let point = Point::new(row, column);
                if let Some(offset) = snapshot.point_to_offset(point) {
                    prop_assert_eq!(snapshot.offset_to_point(offset), Some(point));
                }
                let point = PointUtf16::new(row, column);
                if let Some(offset) = snapshot.point_utf16_to_offset(point) {
                    prop_assert_eq!(snapshot.offset_to_point_utf16(offset), Some(point));
                }
                // The start of a row the text has always converts, in both
                // units, so a conversion that refuses everything does not
                // pass.
                let has_row = row < reference.rows.len();
                let start = snapshot.point_to_offset(Point::new(row, 0));
                prop_assert_eq!(start.is_some(), has_row);
                let start = snapshot.point_utf16_to_offset(PointUtf16::new(row, 0));
                prop_assert_eq!(start.is_some(), has_row);
            }
            Ok(())
        },
    );
}

#[test]
fn conversions_agree_with_a_reference_computed_from_the_string() {
    check(256, text_and_edits(), |(initial, steps)| {
        let (snapshot, string) = edited(initial, &steps);
        let reference = Reference::of(&string);

        prop_assert_eq!(snapshot.row_count(), reference.rows.len());
        for (row, range) in reference.rows.iter().enumerate() {
            prop_assert_eq!(snapshot.row_range(row), Some(range.clone()));
        }
        prop_assert_eq!(snapshot.row_range(reference.rows.len()), None);

        for offset in 0..=string.len() + 2 {
            prop_assert_eq!(
                snapshot.is_char_boundary(offset),
                reference.place(offset).is_some()
            );
            prop_assert_eq!(snapshot.offset_to_point(offset), reference.point(offset));
            prop_assert_eq!(
                snapshot.offset_to_point_utf16(offset),
                reference.point_utf16(offset)
            );
        }

        // Every row and one the text does not have, and in each every
        // column to two past the row's end.
        for row in 0..=reference.rows.len() {
            let length = reference.rows.get(row).map_or(0, |row| row.len());
            let offsets_utf16 = reference.offsets_utf16(row);
            for column in 0..=length + 2 {
                prop_assert_eq!(
                    snapshot.point_to_offset(Point::new(row, column)),
                    reference.offset(row, column),
                    "row {}, byte column {}",
                    row,
                    column
                );
                prop_assert_eq!(
                    snapshot.point_utf16_to_offset(PointUtf16::new(row, column)),
                    offsets_utf16.get(column).copied().flatten(),
                    "row {}, UTF-16 column {}",
                    row,
                    column
                );
            }
        }
        Ok(())
    });
}

#[test]
fn chunks_and_slices_agree_with_the_string() {
    // Ranges and offsets as numbers to cut down to the text.
    let ranges = vec((any::<usize>(), any::<usize>()), 0..=16);

    check(
        256,
        (text_and_edits(), ranges),
        |((initial, steps), ranges)| {
            let (snapshot, string) = edited(initial, &steps);

            prop_assert_eq!(&snapshot.chunks().collect::<String>(), &string);
            prop_assert!(snapshot.chunks().all(|chunk| !chunk.is_empty()));

            let reach = string.len() + 3;
            for (start, end) in ranges {
                let (start, end) = (start % reach, end % reach);

                // A slice of a string is `None` exactly when the range is
                // not two character boundaries in order.
                let expected = string.get(start..end);
                let chunks = snapshot.chunks_in(start..end);
                prop_assert_eq!(chunks.is_some(), expected.is_some());
                if let (Some(chunks), Some(expected)) = (chunks, expected) {
                    prop_assert_eq!(&chunks.collect::<String>(), expected);
                }
                let slice = snapshot.slice_to_string(start..end);
                prop_assert_eq!(slice.as_deref(), expected);

                match snapshot.chunk_at(start) {
                    Some((chunk, at)) => {
                        prop_assert!(at <= start && start <= at + chunk.len());
                        prop_assert!(start < at + chunk.len() || start == string.len());
                        prop_assert_eq!(chunk.as_bytes(), &string.as_bytes()[at..at + chunk.len()]);
                    }
                    None => prop_assert!(start > string.len()),
                }
            }
            Ok(())
        },
    );
}

/// The pieces a generated file is made of: valid text, bytes that are
/// never valid, sequences cut short, an overlong form, an encoded
/// surrogate, reserved code points validly encoded, and every line ending.
const BYTE_FRAGMENTS: &[&[u8]] = &[
    b"",
    b"a",
    b"hello ",
    b"\n",
    b"\r\n",
    b"\r",
    b"\0",
    "é".as_bytes(),
    "€".as_bytes(),
    "😀".as_bytes(),
    "\u{FFFD}".as_bytes(),
    b"\xFF",
    b"\xFE",
    b"\x80",
    b"\xE9",
    // "€" and "😀" without their last byte.
    b"\xE2\x82",
    b"\xF0\x9F\x98",
    b"\xC0\xAF",
    b"\xED\xA0\x80",
    "\u{10DC80}".as_bytes(),
    "\u{10DCFF}".as_bytes(),
    // The first three bytes of a reserved code point.
    b"\xF4\x8D\xB2",
];

/// The bytes of a file: any bytes at all; or pieces of [`BYTE_FRAGMENTS`];
/// or, one time in eight, such pieces repeated until the rope holds the
/// text in many pieces.
fn file_bytes() -> impl Strategy<Value = Vec<u8>> {
    let pieces = || vec(select(BYTE_FRAGMENTS), 0..=24).prop_map(|pieces| pieces.concat());
    prop_oneof![
        3 => vec(any::<u8>(), 0..=64),
        4 => pieces(),
        1 => (pieces(), 20_usize..400).prop_map(|(bytes, times)| bytes.repeat(times)),
    ]
}

/// The bytes a string is saved as, character by character: the reference
/// [`Snapshot::to_bytes`] is compared with. A character in
/// `U+10DC80..=U+10DCFF` is the one byte it stands for, and any other is
/// its UTF-8.
fn saved(text: &str) -> Vec<u8> {
    let mut bytes = Vec::new();
    for character in text.chars() {
        match u32::from(character) {
            escape @ 0x10_DC80..=0x10_DCFF => bytes.push((escape - 0x10_DC00) as u8),
            _ => bytes.extend_from_slice(character.encode_utf8(&mut [0; 4]).as_bytes()),
        }
    }
    bytes
}

#[test]
fn any_bytes_loaded_and_saved_unchanged_are_identical() {
    check(1_024, file_bytes(), |bytes| {
        let text = Text::from_bytes(&bytes);
        let snapshot = text.snapshot();

        prop_assert_eq!(&snapshot.to_bytes(), &bytes);
        prop_assert_eq!(&snapshot.byte_chunks().collect::<Vec<_>>().concat(), &bytes);
        // The text is what the reference saves as the same bytes, so the
        // two directions are not merely each other's inverse.
        prop_assert_eq!(&saved(&snapshot.to_string()), &bytes);
        Ok(())
    });
}

#[test]
fn bytes_that_are_valid_utf8_with_no_reserved_code_point_load_as_that_text() {
    check(256, initial_text_to_walk(), |string| {
        // The generated text holds escapes, which are reserved code points;
        // without them it must load as itself.
        let string: String = string
            .chars()
            .filter(|character| !(0x10_DC80..=0x10_DCFF).contains(&u32::from(*character)))
            .collect();

        let snapshot = Text::from_bytes(string.as_bytes()).snapshot();

        prop_assert_eq!(&snapshot.to_string(), &string);
        prop_assert_eq!(&snapshot.to_bytes(), string.as_bytes());
        Ok(())
    });
}

#[test]
fn an_insert_into_loaded_bytes_saves_as_the_bytes_before_it_the_string_and_the_bytes_after() {
    check(
        512,
        (file_bytes(), any::<usize>(), short_text(6)),
        |(bytes, position, insert)| {
            let mut text = Text::from_bytes(&bytes);
            let string = text.current().to_string();
            let position = floor(&string, position % (string.len() + 1));
            let (before, after) = (saved(&string[..position]), saved(&string[position..]));
            // The position falls between two bytes of the file.
            prop_assert_eq!([before.as_slice(), after.as_slice()].concat(), bytes);

            prop_assert_eq!(text.replace(position..position, &insert), Ok(()));

            let expected = [before, saved(&insert), after].concat();
            prop_assert_eq!(text.current().to_bytes(), expected);
            Ok(())
        },
    );
}
