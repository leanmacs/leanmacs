//! Properties of change sets and transactions: each drives a [`Text`] and
//! a `String` with the same generated change sets and compares the two.

use editor_text::{ApplyError, Bias, Change, ChangeSet, Origin, Text, Transaction};
use proptest::prelude::*;
use proptest::test_runner::TestCaseError;

use crate::{applied, check, fitted_walk, fitted_walks, initial_text, initial_text_to_walk, walks};

/// A text holding `initial` after `changes` are applied to it one after the
/// other, read back.
fn text_after(initial: &str, changes: &[&ChangeSet]) -> Result<String, TestCaseError> {
    let mut text = Text::from(initial);
    for &changes in changes {
        let result = text.apply(&Transaction::new(changes.clone()), Origin::default());
        prop_assert!(
            result.is_ok(),
            "{:?} on {:?}",
            changes,
            text.current().to_string()
        );
    }
    Ok(text.current().to_string())
}

#[test]
fn applying_the_composition_is_applying_one_then_the_other() {
    check(
        256,
        (initial_text(), fitted_walk(), fitted_walk()),
        |(initial, first, second)| {
            let first = first.changes(&initial);
            let middle = applied(&first, &initial).expect("a fitted change set");
            let second = second.changes(&middle);
            let last = applied(&second, &middle).expect("a fitted change set");

            let composed = first.compose(&second);

            let Some(composed) = composed else {
                return Err(TestCaseError::fail("the two do not compose"));
            };
            prop_assert_eq!(composed.len_before(), initial.len());
            prop_assert_eq!(composed.len_after(), last.len());
            let at_once = text_after(&initial, &[&composed])?;
            let in_turn = text_after(&initial, &[&first, &second])?;
            prop_assert_eq!(&at_once, &in_turn);
            prop_assert_eq!(&at_once, &last);
            Ok(())
        },
    );
}

#[test]
fn composition_is_associative() {
    check(
        256,
        (initial_text(), fitted_walk(), fitted_walk(), fitted_walk()),
        |(initial, first, second, third)| {
            let first = first.changes(&initial);
            let one = applied(&first, &initial).expect("a fitted change set");
            let second = second.changes(&one);
            let two = applied(&second, &one).expect("a fitted change set");
            let third = third.changes(&two);
            let three = applied(&third, &two).expect("a fitted change set");

            let left = first.compose(&second).and_then(|both| both.compose(&third));
            let right = second.compose(&third).and_then(|both| first.compose(&both));

            prop_assert!(left.is_some());
            prop_assert_eq!(&left, &right);
            let all = left.expect("checked above");
            prop_assert_eq!(text_after(&initial, &[&all])?, three);
            Ok(())
        },
    );
}

/// Runs `law` for each of `walks` along a text that starts as `initial`:
/// with the text before the change set, the change set, its inverse on that
/// text, and the text after.
fn along_inverses(
    initial: String,
    walks: &[crate::Walk],
    law: impl Fn(&mut Text, &str, &ChangeSet, &ChangeSet, &str) -> Result<(), TestCaseError>,
) -> Result<(), TestCaseError> {
    let mut reference = initial;
    let mut text = Text::from(reference.as_str());
    for walk in walks {
        let changes = walk.changes(&reference);
        let made = applied(&changes, &reference).expect("a fitted change set");
        let before = text.snapshot();

        let inverse = changes.invert(&before);

        let Some(inverse) = inverse else {
            return Err(TestCaseError::fail("a change set that fits has no inverse"));
        };
        let result = text.apply(&Transaction::new(changes.clone()), Origin::default());
        prop_assert!(result.is_ok());
        law(&mut text, &reference, &changes, &inverse, &made)?;
        prop_assert_eq!(&text.current().to_string(), &made);
        reference = made;
    }
    Ok(())
}

#[test]
fn applying_the_inverse_undoes_the_change() {
    check(
        256,
        (initial_text(), fitted_walks(6)),
        |(initial, walks)| {
            along_inverses(initial, &walks, |text, before, changes, inverse, after| {
                prop_assert_eq!(inverse.len_before(), after.len());
                prop_assert_eq!(inverse.len_after(), before.len());

                let undone = text.apply(&Transaction::new(inverse.clone()), Origin::default());

                prop_assert!(undone.is_ok());
                prop_assert_eq!(&text.current().to_string(), before);
                // Done again, so that the next change set is for a text
                // that has been edited.
                let redone = text.apply(&Transaction::new(changes.clone()), Origin::default());
                prop_assert!(redone.is_ok());
                Ok(())
            })
        },
    );
}

#[test]
fn the_inverse_of_the_inverse_is_the_change() {
    check(
        256,
        (initial_text(), fitted_walks(6)),
        |(initial, walks)| {
            along_inverses(initial, &walks, |text, _, changes, inverse, _| {
                let after = text.snapshot();

                let again = inverse.invert(&after);

                prop_assert_eq!(again.as_ref(), Some(changes));
                Ok(())
            })
        },
    );
}

/// For each byte of the text `changes` is for, the offset the byte has in
/// the text `changes` makes, when the byte is retained.
fn retained(changes: &ChangeSet) -> Vec<Option<usize>> {
    let mut offsets = Vec::with_capacity(changes.len_before());
    let mut new = 0;
    for change in changes.changes() {
        match change {
            Change::Retain(len) => {
                offsets.extend((new..new + len).map(Some));
                new += len;
            }
            Change::Delete(len) => offsets.extend(std::iter::repeat_n(None, *len)),
            Change::Insert(text) => new += text.len(),
        }
    }
    offsets
}

#[test]
fn a_mapped_position_keeps_its_retained_neighbour() {
    check(
        256,
        (initial_text_to_walk(), fitted_walk()),
        |(initial, walk)| {
            let changes = walk.changes(&initial);
            let retained = retained(&changes);
            prop_assert_eq!(retained.len(), initial.len());

            for offset in (0..=initial.len()).filter(|&offset| initial.is_char_boundary(offset)) {
                // A position before a byte that stays is still before it,
                // when it sticks to what follows.
                if let Some(&Some(new)) = retained.get(offset) {
                    prop_assert_eq!(changes.map(offset, Bias::After), Some(new), "{}", offset);
                }
                // A position after a byte that stays is still after it,
                // when it sticks to what precedes.
                if let Some(&Some(new)) = offset.checked_sub(1).and_then(|last| retained.get(last))
                {
                    prop_assert_eq!(
                        changes.map(offset, Bias::Before),
                        Some(new + 1),
                        "{}",
                        offset
                    );
                }
            }
            Ok(())
        },
    );
}

#[test]
fn mapping_is_monotone_and_lands_on_positions() {
    check(
        256,
        (initial_text_to_walk(), fitted_walk()),
        |(initial, walk)| {
            let changes = walk.changes(&initial);
            let made = applied(&changes, &initial).expect("a fitted change set");
            let mut last = (0, 0);

            for offset in (0..=initial.len()).filter(|&offset| initial.is_char_boundary(offset)) {
                let before = changes.map(offset, Bias::Before);
                let after = changes.map(offset, Bias::After);

                let (Some(before), Some(after)) = (before, after) else {
                    return Err(TestCaseError::fail(format!("{offset} maps to nothing")));
                };
                prop_assert!(made.is_char_boundary(before), "{} to {}", offset, before);
                prop_assert!(made.is_char_boundary(after), "{} to {}", offset, after);
                prop_assert!(before <= after, "{}", offset);
                prop_assert!(last.0 <= before && last.1 <= after, "{}", offset);
                last = (before, after);
            }
            prop_assert_eq!(changes.map(0, Bias::Before), Some(0));
            prop_assert_eq!(changes.map(initial.len(), Bias::After), Some(made.len()));
            prop_assert_eq!(changes.map(initial.len() + 1, Bias::Before), None);
            prop_assert_eq!(changes.map(initial.len() + 1, Bias::After), None);
            Ok(())
        },
    );
}

#[test]
fn applying_a_change_set_agrees_with_a_string() {
    check(256, (initial_text(), walks(12)), |(initial, walks)| {
        let mut reference = initial;
        let mut text = Text::from(reference.as_str());
        let mut accepted = 0;

        for walk in walks {
            let changes = walk.changes(&reference);
            let expected = applied(&changes, &reference);

            let result = text.apply(&Transaction::new(changes), Origin::default());

            match expected {
                Some(made) => {
                    accepted += 1;
                    prop_assert_eq!(result.map(|revision| revision.get()), Ok(accepted));
                    reference = made;
                }
                None => prop_assert_eq!(result, Err(ApplyError::BadChange)),
            }
            prop_assert_eq!(&text.current().to_string(), &reference);
            prop_assert_eq!(text.current().len(), reference.len());
            prop_assert_eq!(text.current().revision().get(), accepted);
        }
        Ok(())
    });
}
