//! Properties of anchors and of the markers a text holds: each drives a
//! [`Text`](editor_text::Text) and a `String` with the same generated
//! change sets, and compares where the text put its markers with where
//! [`ChangeSet::map`] puts each position, one at a time.

use editor_text::{Bias, ChangeSet};
use proptest::collection::vec;
use proptest::prelude::*;

use crate::{check, initial_text_to_walk, walk};

/// Either bias.
pub(crate) fn bias() -> impl Strategy<Value = Bias> {
    prop_oneof![Just(Bias::Before), Just(Bias::After)]
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
