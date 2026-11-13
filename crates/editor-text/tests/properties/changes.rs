//! Properties of change sets and transactions: each drives a [`Text`] and
//! a `String` with the same generated change sets and compares the two.

use editor_text::{ApplyError, Origin, Text, Transaction};
use proptest::prelude::*;

use crate::{applied, check, initial_text, walks};

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
