//! Properties of the edit log: each drives a [`Text`] and a `String` with
//! the same generated transactions, and compares what the log says with a
//! reference computed from the strings.

use std::ops::Range;

use editor_text::{
    Attribution, Change, ChangeSet, Edit, LogError, Origin, Point, Revision, Source, Span, Text,
    Transaction,
};
use proptest::collection::vec;
use proptest::prelude::*;

use crate::{applied, check, floor, initial_text_to_walk, patched, walks};

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

#[test]
fn a_subscriber_that_skips_edits_gets_one_equivalent_patch() {
    /// The most transactions in a case.
    const WALKS: usize = 10;
    // Whether the subscriber that skips pulls after each transaction.
    let pulls = vec(prop::bool::weighted(0.3), WALKS);

    check(
        256,
        (initial_text_to_walk(), walks(WALKS), pulls),
        |(initial, walks, pulls)| {
            let mut reference = initial;
            let mut text = Text::from(reference.as_str());
            let mut skipping = text.subscribe();
            let mut following = text.subscribe();
            // What the text held when `skipping` last pulled, and the
            // composition of the change sets accepted since.
            let mut seen = reference.clone();
            let mut skipped: Option<ChangeSet> = None;

            // One more round than there are transactions, in which
            // `skipping` always pulls.
            for index in 0..=walks.len() {
                if let Some(walk) = walks.get(index) {
                    let changes = walk.changes(&reference);
                    let transaction = Transaction::new(changes.clone());
                    let before = text.current().revision();
                    let result = text.apply(&transaction, Origin::default());

                    // The subscriber that pulls every time sees each entry
                    // alone.
                    let alone = text.pull(&mut following);
                    let Ok(alone) = alone else {
                        return Err(TestCaseError::fail("a subscriber was refused"));
                    };
                    prop_assert_eq!(alone.from, before);
                    prop_assert_eq!(alone.to, text.current().revision());
                    match (result, applied(&changes, &reference)) {
                        (Ok(revision), Some(made)) => {
                            let entry = text.entry(revision).map(|entry| entry.edits());
                            prop_assert_eq!(Some(alone.edits.as_slice()), entry);
                            skipped = match skipped {
                                Some(earlier) => earlier.compose(&changes),
                                None => Some(changes),
                            };
                            prop_assert!(skipped.is_some(), "the change sets compose");
                            reference = made;
                        }
                        (Err(_), None) => prop_assert_eq!(&alone.edits, &[]),
                        _ => return Err(TestCaseError::fail("the text and the string disagree")),
                    }
                }
                if !pulls.get(index).copied().unwrap_or(true) {
                    continue;
                }

                let since = skipping.revision();
                let patch = text.pull(&mut skipping);

                let Ok(patch) = patch else {
                    return Err(TestCaseError::fail("a subscriber was refused"));
                };
                prop_assert_eq!(patch.from, since);
                prop_assert_eq!(patch.to, text.current().revision());
                prop_assert_eq!(skipping.revision(), text.current().revision());
                // One patch, equal to the edits of everything skipped done
                // at once, with points from the two strings.
                let expected = match skipped.take() {
                    Some(skipped) => edits_of(&skipped, &seen, &reference),
                    None => Vec::new(),
                };
                prop_assert_eq!(&patch.edits, &expected);
                prop_assert_eq!(&patched(&seen, &reference, &patch.edits), &reference);
                check_input_edits(&seen, &reference, &patch.edits)?;
                seen.clone_from(&reference);
            }
            Ok(())
        },
    );
}

/// Who wrote each byte of a text, kept beside the string: the revision and
/// the origin of the transaction that inserted it, or revision 0 for a
/// byte the text was made with. It is spliced with every change set, and
/// is what a trace is compared with.
#[derive(Debug, Clone)]
struct Authors(Vec<(u64, u64)>);

impl Authors {
    /// The authors of a text just made holding `initial`.
    fn of(initial: &str) -> Self {
        Self(vec![(0, 0); initial.len()])
    }

    /// Splices the authors as `changes` splices the text: what is retained
    /// keeps its author, and what is inserted is written at `revision` by
    /// `origin`.
    fn apply(&mut self, changes: &ChangeSet, revision: u64, origin: u64) {
        let mut next = Vec::with_capacity(changes.len_after());
        let mut at = 0;
        for change in changes.changes() {
            match change {
                Change::Retain(len) => {
                    next.extend_from_slice(&self.0[at..at + len]);
                    at += len;
                }
                Change::Delete(len) => at += len,
                Change::Insert(text) => {
                    next.extend(std::iter::repeat_n((revision, origin), text.len()));
                }
            }
        }
        self.0 = next;
    }

    /// The trace of `range` these authors expect from a log whose horizon
    /// is `horizon`: the authors of the range's bytes, with a byte written
    /// at or before the horizon as earlier than it, and equal neighbours
    /// as one piece.
    fn trace(&self, range: Range<usize>, horizon: u64) -> Vec<Attribution> {
        let mut pieces: Vec<Attribution> = Vec::new();
        for offset in range {
            let (revision, origin) = self.0[offset];
            let source = if revision <= horizon {
                Source::Earlier(Revision::new(horizon))
            } else {
                Source::Entry {
                    revision: Revision::new(revision),
                    origin: Origin::new(origin),
                }
            };
            match pieces.last_mut() {
                Some(last) if last.source == source => last.range.end = offset + 1,
                _ => pieces.push(Attribution {
                    range: offset..offset + 1,
                    source,
                }),
            }
        }
        pieces
    }
}

/// Two numbers cut down to a range of two positions of `reference`, in
/// order.
fn fitted_range(reference: &str, (one, other): (usize, usize)) -> Range<usize> {
    let one = floor(reference, one % (reference.len() + 1));
    let other = floor(reference, other % (reference.len() + 1));
    one.min(other)..one.max(other)
}

/// The ranges to trace in a case, before they are cut down to the text.
fn ranges() -> impl Strategy<Value = Vec<(usize, usize)>> {
    vec((any::<usize>(), any::<usize>()), 4)
}

#[test]
fn a_range_traces_back_to_the_entries_that_produced_it() {
    /// The most transactions in a case.
    const WALKS: usize = 8;

    check(
        256,
        (
            initial_text_to_walk(),
            walks(WALKS),
            origins(WALKS),
            ranges(),
        ),
        |(initial, walks, origins, ranges)| {
            let mut reference = initial;
            let mut text = Text::from(reference.as_str());
            let mut authors = Authors::of(&reference);

            for (walk, origin) in walks.iter().zip(origins) {
                let changes = walk.changes(&reference);
                let result = text.apply(&Transaction::new(changes.clone()), Origin::new(origin));
                if let (Ok(revision), Some(made)) = (result, applied(&changes, &reference)) {
                    authors.apply(&changes, revision.get(), origin);
                    reference = made;
                }

                // Each range of the text as it is now names, piece by
                // piece, the entry that wrote it, and so its origin.
                for &range in &ranges {
                    let range = fitted_range(&reference, range);
                    let trace = text.trace(range.clone());
                    prop_assert_eq!(trace, Some(authors.trace(range, 0)));
                }
                let whole = text.trace(0..reference.len());
                prop_assert_eq!(whole, Some(authors.trace(0..reference.len(), 0)));
                prop_assert_eq!(text.trace(0..reference.len() + 1), None);
            }
            Ok(())
        },
    );
}

#[test]
fn forgetting_keeps_everything_after_the_horizon() {
    /// The most transactions in a case.
    const WALKS: usize = 10;
    // After how many transactions to forget, and which of the revisions
    // reached by then to forget through, as a number to cut down.
    let forget = (0..=WALKS, any::<usize>());

    check(
        256,
        (
            initial_text_to_walk(),
            walks(WALKS),
            origins(WALKS),
            forget,
            ranges(),
        ),
        |(initial, walks, origins, (forget_after, forget_through), ranges)| {
            let mut reference = initial;
            // Two texts driven alike: one forgets, and one keeps its log
            // whole to say what the answers were.
            let mut text = Text::from(reference.as_str());
            let mut whole = Text::from(reference.as_str());
            let mut authors = Authors::of(&reference);
            let forget_after = forget_after.min(walks.len());

            // One more round than there are transactions, so that the last
            // place to forget is after them all.
            let rounds = walks.iter().zip(&origins).map(Some).chain([None]);
            for (index, round) in rounds.enumerate() {
                if index == forget_after {
                    let reached = text.current().revision().get();
                    let through = Revision::new(forget_through as u64 % (reached + 1));
                    prop_assert_eq!(text.forget(through), Ok(()));
                    prop_assert_eq!(text.horizon(), through);
                }
                let Some((walk, &origin)) = round else {
                    break;
                };
                let changes = walk.changes(&reference);
                let transaction = Transaction::new(changes.clone());
                let result = text.apply(&transaction, Origin::new(origin));
                prop_assert_eq!(result, whole.apply(&transaction, Origin::new(origin)));
                if let (Ok(revision), Some(made)) = (result, applied(&changes, &reference)) {
                    authors.apply(&changes, revision.get(), origin);
                    reference = made;
                }
            }

            let horizon = text.horizon();
            let current = text.current().revision();
            prop_assert_eq!(&text.current().to_string(), &reference);
            prop_assert_eq!(current, whole.current().revision());
            for revision in (0..=current.get()).map(Revision::new) {
                // A patch from the horizon on is what it was; one from
                // before it is refused.
                let patch = text.changes_since(revision);
                if revision < horizon {
                    prop_assert_eq!(patch, Err(LogError::Forgotten));
                } else {
                    prop_assert_eq!(patch, whole.changes_since(revision));
                }
                // An entry after the horizon is what it was; the others
                // are gone.
                let entry = text.entry(revision);
                let kept = whole.entry(revision).filter(|_| revision > horizon);
                prop_assert_eq!(
                    entry.map(|entry| (entry.revision(), entry.origin(), entry.edits())),
                    kept.map(|entry| (entry.revision(), entry.origin(), entry.edits()))
                );
            }
            let ahead = Revision::new(current.get() + 1);
            prop_assert_eq!(text.changes_since(ahead), Err(LogError::Unknown));
            prop_assert_eq!(text.forget(ahead), Err(LogError::Unknown));
            // A trace names later bytes as before, and the others as
            // earlier than the horizon.
            let mut ranges: Vec<_> = ranges
                .into_iter()
                .map(|range| fitted_range(&reference, range))
                .collect();
            ranges.push(0..reference.len());
            for range in ranges {
                let trace = text.trace(range.clone());
                prop_assert_eq!(trace, Some(authors.trace(range.clone(), horizon.get())));
                prop_assert_eq!(whole.trace(range.clone()), Some(authors.trace(range, 0)));
            }
            Ok(())
        },
    );
}
