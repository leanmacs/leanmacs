//! Properties of anchors and of the markers a text holds: each drives a
//! [`Text`](editor_text::Text) and a `String` with the same generated
//! change sets, and compares where the text put its markers with where
//! [`ChangeSet::map`] puts each position, one at a time.

use editor_text::{
    Anchor, Bias, ChangeSet, Marker, MarkerId, Origin, Selection, Text, Transaction,
};
use proptest::collection::vec;
use proptest::prelude::*;
use proptest::test_runner::TestCaseError;

use crate::selections::{Parts, in_form, parts};
use crate::{Walk, applied, check, floor, initial_text, initial_text_to_walk, walk, walks};

/// Either bias.
pub(crate) fn bias() -> impl Strategy<Value = Bias> {
    prop_oneof![Just(Bias::Before), Just(Bias::After)]
}

/// Up to `anchors` anchors, each an offset to cut down to a text and a
/// bias. One in four is at the same number as the one before it, so that
/// anchors often share an offset.
fn anchor_picks(anchors: usize) -> impl Strategy<Value = Vec<(usize, Bias)>> {
    vec((any::<usize>(), bias(), 0..4_u8), 0..=anchors).prop_map(|picks| {
        let mut last = 0;
        picks
            .into_iter()
            .map(|(pick, bias, again)| {
                if again != 0 {
                    last = pick;
                }
                (last, bias)
            })
            .collect()
    })
}

/// One transaction a text was given while it held markers.
struct Moved<'a, M> {
    /// The markers before the transaction, in the order they were made.
    before: &'a [M],
    /// The same markers after it.
    after: &'a [M],
    /// What the transaction was to do.
    changes: &'a ChangeSet,
    /// The text after it, which is the text before it when it was refused.
    text: &'a str,
    /// Whether the text accepted it.
    accepted: bool,
}

/// Marks a text that holds `initial` with `markers`, each fitted to the
/// text by `fit`, applies `walks` to it one after the other, fitted and
/// not, and runs `law` on each with the markers read back before and
/// after it.
fn along_marked<P, M: Clone>(
    initial: String,
    picks: &[P],
    walks: &[Walk],
    fit: impl Fn(&P, &str) -> Marker,
    read: impl Fn(&Marker) -> Option<M>,
    law: impl Fn(Moved<'_, M>) -> Result<(), TestCaseError>,
) -> Result<(), TestCaseError> {
    let mut reference = initial;
    let mut text = Text::from(reference.as_str());
    let mut ids: Vec<MarkerId> = Vec::new();
    for pick in picks {
        let id = text.mark(fit(pick, &reference));
        prop_assert!(id.is_ok(), "a fitted marker was refused: {:?}", id);
        ids.extend(id);
    }
    let held = |text: &Text| -> Result<Vec<M>, TestCaseError> {
        let markers: Vec<M> = ids
            .iter()
            .filter_map(|&id| text.marker(id).and_then(&read))
            .collect();
        prop_assert_eq!(markers.len(), ids.len(), "a marker is gone or another kind");
        Ok(markers)
    };
    for walk in walks {
        let changes = walk.changes(&reference);
        let made = applied(&changes, &reference);
        let before = held(&text)?;

        let result = text.apply(&Transaction::new(changes.clone()), Origin::default());

        prop_assert_eq!(result.is_ok(), made.is_some());
        reference = made.unwrap_or(reference);
        prop_assert_eq!(&text.current().to_string(), &reference);
        law(Moved {
            before: &before,
            after: &held(&text)?,
            changes: &changes,
            text: &reference,
            accepted: result.is_ok(),
        })?;
    }
    Ok(())
}

/// [`along_marked`] for a text that holds anchors.
fn along_anchors(
    (initial, picks, walks): (String, Vec<(usize, Bias)>, Vec<Walk>),
    law: impl Fn(Moved<'_, Anchor>) -> Result<(), TestCaseError>,
) -> Result<(), TestCaseError> {
    along_marked(
        initial,
        &picks,
        &walks,
        |&(pick, bias), reference| {
            Marker::Anchor(Anchor::new(
                floor(reference, pick % (reference.len() + 1)),
                bias,
            ))
        },
        |marker| match marker {
            Marker::Anchor(anchor) => Some(*anchor),
            Marker::Selection(_) => None,
        },
        law,
    )
}

/// A text, anchors for it to hold, and transactions to apply to it.
fn text_anchors_and_walks() -> impl Strategy<Value = (String, Vec<(usize, Bias)>, Vec<Walk>)> {
    (initial_text(), anchor_picks(12), walks(8))
}

#[test]
fn anchors_stay_in_bounds_through_random_transactions() {
    check(512, text_anchors_and_walks(), |case| {
        along_anchors(case, |moved| {
            for anchor in moved.after {
                // A position of the text: within it, and not inside a
                // character.
                prop_assert!(
                    moved.text.is_char_boundary(anchor.offset),
                    "{:?} in a text of {} bytes",
                    anchor,
                    moved.text.len()
                );
            }
            Ok(())
        })
    });
}

#[test]
fn a_texts_anchors_are_where_mapping_each_one_puts_it() {
    check(512, text_anchors_and_walks(), |case| {
        along_anchors(case, |moved| {
            for (before, after) in moved.before.iter().zip(moved.after) {
                let expected = if moved.accepted {
                    before.map(moved.changes)
                } else {
                    // A refused transaction moves nothing.
                    Some(*before)
                };
                prop_assert_eq!(Some(*after), expected);
            }
            Ok(())
        })
    });
}

/// Checks, after every transaction, each two anchors that were in order
/// before it and whose biases, the earlier's and then the later's,
/// `related` picks: the earlier must not be after the later.
fn the_order_is_kept(related: impl Fn(Bias, Bias) -> bool) {
    check(512, text_anchors_and_walks(), |case| {
        along_anchors(case, |moved| {
            let anchors = moved.before.iter().zip(moved.after);
            for (earlier_before, earlier_after) in anchors.clone() {
                for (later_before, later_after) in anchors.clone() {
                    if earlier_before.offset <= later_before.offset
                        && related(earlier_before.bias, later_before.bias)
                    {
                        prop_assert!(
                            earlier_after.offset <= later_after.offset,
                            "{:?} and {:?} became {:?} and {:?}",
                            earlier_before,
                            later_before,
                            earlier_after,
                            later_after
                        );
                    }
                }
            }
            Ok(())
        })
    });
}

#[test]
fn two_anchors_of_one_bias_never_pass_each_other() {
    the_order_is_kept(|earlier, later| earlier == later);
}

#[test]
fn an_anchor_that_stays_before_inserted_text_never_passes_one_that_goes_after_it() {
    the_order_is_kept(|earlier, later| earlier == Bias::Before && later == Bias::After);
}

#[test]
fn marked_selections_stay_sorted_and_merged() {
    check(
        512,
        (initial_text(), vec(parts(5, usize::MAX), 0..=4), walks(8)),
        |(initial, picks, walks)| {
            along_marked(
                initial,
                &picks,
                &walks,
                |parts: &Parts, reference| {
                    let mut parts = parts.clone();
                    for (anchor, head) in &mut parts.ranges {
                        *anchor = floor(reference, *anchor % (reference.len() + 1));
                        *head = floor(reference, *head % (reference.len() + 1));
                    }
                    Marker::Selection(parts.selection())
                },
                |marker| match marker {
                    Marker::Selection(selection) => Some(selection.clone()),
                    Marker::Anchor(_) => None,
                },
                |moved: Moved<'_, Selection>| {
                    for (before, after) in moved.before.iter().zip(moved.after) {
                        // Every end is a position of the text.
                        for range in after.ranges() {
                            prop_assert!(moved.text.is_char_boundary(range.anchor));
                            prop_assert!(moved.text.is_char_boundary(range.head));
                        }
                        // Sorted, and ranges the edit brought together
                        // are one.
                        prop_assert!(in_form(after), "{:?}", after);
                        prop_assert_eq!(after.shape(), before.shape());
                        let expected = if moved.accepted {
                            before.map(moved.changes)
                        } else {
                            Some(before.clone())
                        };
                        prop_assert_eq!(Some(after), expected.as_ref());
                    }
                    Ok(())
                },
            )
        },
    );
}

#[test]
fn one_pass_mapping_is_mapping_one_by_one() {
    check(
        256,
        (
            initial_text_to_walk(),
            walk(),
            vec((any::<usize>(), bias()), 0..=64),
        ),
        |(initial, walk, picks)| {
            // Fitted to the text or not: a mapper asks nothing of a text.
            let changes: ChangeSet = walk.changes(&initial);
            // Every offset the change set is for, and two past it.
            let reach = changes.len_before() + 3;

            // In rising order, each offset with both biases.
            let mut mapper = changes.mapper();
            for offset in 0..reach {
                for bias in [Bias::Before, Bias::After, Bias::Before] {
                    prop_assert_eq!(
                        mapper.map(offset, bias),
                        changes.map(offset, bias),
                        "{} {:?} in order",
                        offset,
                        bias
                    );
                }
            }
            // In any order, on the mapper the walk above left at the end
            // and on a new one.
            for mut mapper in [mapper, changes.mapper()] {
                for &(pick, bias) in &picks {
                    let offset = pick % reach;
                    prop_assert_eq!(
                        mapper.map(offset, bias),
                        changes.map(offset, bias),
                        "{} {:?} out of order",
                        offset,
                        bias
                    );
                }
            }
            Ok(())
        },
    );
}
