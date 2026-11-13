//! Properties of the edit log: each drives a [`Text`] and a `String` with
//! the same generated transactions, and compares what the log says with a
//! reference computed from the strings.

use std::ops::Range;

use editor_text::{Change, ChangeSet, Edit, Origin, Point, Span, Text, Transaction};
use proptest::collection::vec;
use proptest::prelude::*;

use crate::{applied, check, initial_text_to_walk, walks};

/// The point of the position `offset` of `text`, by counting its line
/// feeds.
fn point_of(text: &str, offset: usize) -> Point {
    let before = &text.as_bytes()[..offset];
    let row = before.iter().filter(|&&byte| byte == b'\n').count();
    let row_start = before
        .iter()
        .rposition(|&byte| byte == b'\n')
        .map_or(0, |line_feed| line_feed + 1);
    Point::new(row, offset - row_start)
}

/// The span of `range` in `text`, with its points counted from the string.
fn span_of(text: &str, range: Range<usize>) -> Span {
    Span {
        start: range.start,
        end: range.end,
        start_point: point_of(text, range.start),
        end_point: point_of(text, range.end),
    }
}

/// The edits of `changes`, which made `new` of `old`: one for each run of
/// deletes and inserts between two retains, with every point counted from
/// the two strings.
fn edits_of(changes: &ChangeSet, old: &str, new: &str) -> Vec<Edit> {
    let mut edits = Vec::new();
    // Where the walk is in each string, and where the run it is in began.
    let (mut old_at, mut new_at) = (0, 0);
    let mut run: Option<(usize, usize)> = None;
    let mut close = |run: &mut Option<(usize, usize)>, old_at: usize, new_at: usize| {
        if let Some((old_start, new_start)) = run.take() {
            edits.push(Edit {
                old: span_of(old, old_start..old_at),
                new: span_of(new, new_start..new_at),
            });
        }
    };
    for change in changes.changes() {
        match change {
            Change::Retain(len) => {
                close(&mut run, old_at, new_at);
                old_at += len;
                new_at += len;
            }
            Change::Delete(len) => {
                run.get_or_insert((old_at, new_at));
                old_at += len;
            }
            Change::Insert(text) => {
                run.get_or_insert((old_at, new_at));
                new_at += text.len();
            }
        }
    }
    close(&mut run, old_at, new_at);
    edits
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

/// Checks the parser form of each of `edits`, which make `new` of `old`,
/// taken in order: before an edit the parser's text is the new text up to
/// the edit and the old text from it.
fn check_input_edits(old: &str, new: &str, edits: &[Edit]) -> Result<(), TestCaseError> {
    for edit in edits {
        let input = edit.input_edit();
        let before = format!("{}{}", &new[..edit.new.start], &old[edit.old.start..]);
        let after = format!("{}{}", &new[..edit.new.end], &old[edit.old.end..]);

        prop_assert_eq!(input.start_byte, edit.new.start);
        prop_assert_eq!(input.start_point, point_of(&before, input.start_byte));
        prop_assert_eq!(
            input.old_end_byte,
            edit.new.start + (edit.old.end - edit.old.start)
        );
        prop_assert_eq!(input.old_end_point, point_of(&before, input.old_end_byte));
        prop_assert_eq!(input.new_end_byte, edit.new.end);
        prop_assert_eq!(input.new_end_point, point_of(&after, input.new_end_byte));
        // What the edit did to the parser's text is what it says.
        prop_assert_eq!(
            &before[..input.start_byte],
            &after[..input.start_byte],
            "the text before the edit"
        );
        prop_assert_eq!(
            &before[input.old_end_byte..],
            &after[input.new_end_byte..],
            "the text after the edit"
        );
    }
    Ok(())
}

/// The origins to apply the transactions of a case with, one for each.
fn origins(transactions: usize) -> impl Strategy<Value = Vec<u64>> {
    vec(any::<u64>(), transactions)
}

#[test]
fn the_logged_edits_agree_with_a_reference_computed_from_the_texts() {
    /// The most transactions in a case.
    const WALKS: usize = 8;

    check(
        256,
        (initial_text_to_walk(), walks(WALKS), origins(WALKS)),
        |(initial, walks, origins)| {
            let mut reference = initial;
            let mut text = Text::from(reference.as_str());

            for (walk, origin) in walks.iter().zip(origins) {
                let changes = walk.changes(&reference);
                let Some(made) = applied(&changes, &reference) else {
                    continue;
                };
                let transaction = Transaction::new(changes.clone());

                let revision = text.apply(&transaction, Origin::new(origin));

                let Ok(revision) = revision else {
                    return Err(TestCaseError::fail("a change set that fits was refused"));
                };
                let Some(entry) = text.entry(revision) else {
                    return Err(TestCaseError::fail("an applied transaction has no entry"));
                };
                prop_assert_eq!(entry.revision(), revision);
                prop_assert_eq!(entry.origin(), Origin::new(origin));
                let edits = entry.edits();
                // Every range and every point, from the two strings.
                let expected = edits_of(&changes, &reference, &made);
                prop_assert_eq!(edits, expected.as_slice());
                prop_assert_eq!(&patched(&reference, &made, edits), &made);
                check_input_edits(&reference, &made, edits)?;
                reference = made;
            }
            Ok(())
        },
    );
}
