//! The edit log: what was done to a text, one entry for each transaction
//! it accepted.

use std::borrow::Cow;
use std::collections::VecDeque;
use std::error::Error;
use std::fmt;

use crate::patch::{self, Edit, Patch};
use crate::snapshot::Revision;

/// Who made an edit: an opaque number the caller supplies when it applies a
/// transaction.
///
/// The crate stores it in the transaction's log entry and returns it from
/// there. No function of the crate reads its value: what a number stands
/// for is the caller's table. The default is 0, which to the crate means
/// nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Origin(u64);

impl Origin {
    /// The origin with the value `value`.
    pub const fn new(value: u64) -> Self {
        Self(value)
    }

    /// The value the origin was made with.
    pub const fn get(self) -> u64 {
        self.0
    }
}

/// One applied transaction, as the log holds it.
#[derive(Debug)]
struct Entry {
    /// Who applied it.
    origin: Origin,
    /// What it changed: one edit for each run of deletes and inserts
    /// between two retains, in order.
    edits: Box<[Edit]>,
}

/// The entries of one text, oldest first.
#[derive(Debug, Default)]
pub(crate) struct Log {
    /// The revision the log reaches back to: it holds the entry of every
    /// later revision and of no other.
    horizon: Revision,
    /// The entries. The one for the revision `r` is at index
    /// `r - horizon - 1`, so no entry stores its revision.
    entries: VecDeque<Entry>,
}

impl Log {
    /// Records the transaction that produced the next revision.
    pub(crate) fn record(&mut self, origin: Origin, edits: Box<[Edit]>) {
        self.entries.push_back(Entry { origin, edits });
    }

    /// The revision the log reaches back to.
    pub(crate) fn horizon(&self) -> Revision {
        self.horizon
    }

    /// The entry of the transaction that produced `revision`. `None` for a
    /// revision at or before the horizon, which the log holds no entry for
    /// (revision 0 is one: no transaction produced it), and for a revision
    /// the text has not reached.
    pub(crate) fn entry(&self, revision: Revision) -> Option<LogEntry<'_>> {
        let after_horizon = revision.get().checked_sub(self.horizon.get())?;
        let index = usize::try_from(after_horizon.checked_sub(1)?).ok()?;
        let entry = self.entries.get(index)?;
        Some(LogEntry { revision, entry })
    }

    /// What changed between `since` and `current`, the text's revision, as
    /// one patch.
    pub(crate) fn changes_since(
        &self,
        since: Revision,
        current: Revision,
    ) -> Result<Patch, LogError> {
        if since > current {
            return Err(LogError::Unknown);
        }
        // The entries of the revisions after `since`.
        let skipped = since.get() - self.horizon.get();
        let first = usize::try_from(skipped).map_or(self.entries.len(), |skipped| {
            skipped.min(self.entries.len())
        });
        Ok(Patch {
            from: since,
            to: current,
            edits: self.coalesced(first, self.entries.len()).into_owned(),
        })
    }

    /// The edits of the entries from the index `first` up to, not
    /// including, `end`, as one set.
    ///
    /// The entries are composed pairwise as a balanced tree, so an edit is
    /// walked once for each level of the tree and not once for each entry
    /// after its own.
    fn coalesced(&self, first: usize, end: usize) -> Cow<'_, [Edit]> {
        match end.saturating_sub(first) {
            0 => Cow::Borrowed(&[]),
            1 => self
                .entries
                .get(first)
                .map_or(Cow::Borrowed(&[]), |entry| Cow::Borrowed(&*entry.edits)),
            count => {
                let middle = first + count / 2;
                let earlier = self.coalesced(first, middle);
                let later = self.coalesced(middle, end);
                Cow::Owned(patch::compose(&earlier, &later))
            }
        }
    }
}

/// Why the log could not answer for a revision.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogError {
    /// The text has not reached the revision.
    Unknown,
}

impl fmt::Display for LogError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Unknown => "the text has not reached the revision",
        })
    }
}

impl Error for LogError {}

/// A consumer's place in a text's log: the revision it last saw
/// ([`Text::subscribe`](crate::Text::subscribe),
/// [`Text::pull`](crate::Text::pull)).
///
/// Nothing is registered with the text: a subscription is a revision the
/// consumer keeps, so it costs the text nothing and there is nothing to
/// release.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Subscription {
    /// The revision the consumer last saw.
    pub(crate) seen: Revision,
}

impl Subscription {
    /// The revision the consumer last saw: the text's when it subscribed
    /// or last pulled.
    pub fn revision(&self) -> Revision {
        self.seen
    }
}

/// One entry of a text's log: an applied transaction
/// ([`Text::entry`](crate::Text::entry)).
#[derive(Debug, Clone, Copy)]
pub struct LogEntry<'a> {
    /// The revision the transaction produced.
    revision: Revision,
    /// What the log holds of it.
    entry: &'a Entry,
}

impl<'a> LogEntry<'a> {
    /// The revision the transaction produced.
    pub fn revision(&self) -> Revision {
        self.revision
    }

    /// The origin the transaction was applied with.
    pub fn origin(&self) -> Origin {
        self.entry.origin
    }

    /// What the transaction changed: one edit for each run of deletes and
    /// inserts between two retains of its change set, in order. The old
    /// span of an edit is a range of the text before the transaction and
    /// the new span a range of the text after it. Empty for a transaction
    /// that changed nothing.
    pub fn edits(&self) -> &'a [Edit] {
        &self.entry.edits
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::patch::tests::span;
    use crate::{Change, ChangeSet, Text, Transaction};

    /// Rows with characters of one, two and four bytes and both line
    /// endings, in 20 bytes. Row 0 is "héllo\r", row 1 starts at 8 and row
    /// 2 at 15; "é" is the bytes 1 and 2, "ö" 9 and 10, "😀" 15 to 18.
    const MIXED: &str = "héllo\r\nwörld\n😀x";

    /// An insert of `text`.
    fn insert(text: &str) -> Change {
        Change::Insert(text.to_owned())
    }

    /// The edits the log holds for `changes` applied to a text holding
    /// [`MIXED`].
    fn logged(changes: &[Change]) -> Vec<Edit> {
        let mut text = Text::from(MIXED);
        let transaction = Transaction::new(changes.iter().cloned().collect());
        let revision = text.apply(&transaction, Origin::new(1)).expect("it fits");
        let entry = text.entry(revision).expect("the transaction's entry");
        entry.edits().to_vec()
    }

    #[test]
    fn an_insertion_with_a_line_feed_in_it_is_an_empty_old_range_and_a_new_one_across_rows() {
        let edits = logged(&[Change::Retain(3), insert("a\nb"), Change::Retain(17)]);

        assert_eq!(
            edits,
            [Edit {
                old: span(3, 3, (0, 3), (0, 3)),
                new: span(3, 6, (0, 3), (1, 1)),
            }]
        );
    }

    #[test]
    fn a_deletion_across_a_line_feed_is_an_old_range_across_rows_and_an_empty_new_one() {
        let edits = logged(&[Change::Retain(5), Change::Delete(4), Change::Retain(11)]);

        assert_eq!(
            edits,
            [Edit {
                old: span(5, 9, (0, 5), (1, 1)),
                new: span(5, 5, (0, 5), (0, 5)),
            }]
        );
    }

    #[test]
    fn a_replacement_inside_a_row_is_one_edit_with_both_ranges() {
        // Pushed as a delete and then an insert: it is still one edit.
        let edits = logged(&[
            Change::Retain(11),
            Change::Delete(2),
            insert("RLX"),
            Change::Retain(7),
        ]);

        assert_eq!(
            edits,
            [Edit {
                old: span(11, 13, (1, 3), (1, 5)),
                new: span(11, 14, (1, 3), (1, 6)),
            }]
        );
    }

    #[test]
    fn the_changes_of_one_transaction_are_one_edit_each_in_the_coordinates_of_both_texts() {
        // The text becomes "héa\nbllöRLXd\n😀x": row 1 starts at 5.
        let edits = logged(&[
            Change::Retain(3),
            insert("a\nb"),
            Change::Retain(2),
            Change::Delete(4),
            Change::Retain(2),
            insert("RLX"),
            Change::Delete(2),
            Change::Retain(7),
        ]);

        assert_eq!(
            edits,
            [
                Edit {
                    old: span(3, 3, (0, 3), (0, 3)),
                    new: span(3, 6, (0, 3), (1, 1)),
                },
                // The second and the third start at different offsets and
                // points in the two texts.
                Edit {
                    old: span(5, 9, (0, 5), (1, 1)),
                    new: span(8, 8, (1, 3), (1, 3)),
                },
                Edit {
                    old: span(11, 13, (1, 3), (1, 5)),
                    new: span(10, 13, (1, 5), (1, 8)),
                },
            ]
        );
    }

    #[test]
    fn edits_at_the_start_and_at_the_end_of_the_text_are_recorded() {
        let edits = logged(&[Change::Delete(1), Change::Retain(19), insert("\n")]);

        assert_eq!(
            edits,
            [
                Edit {
                    old: span(0, 1, (0, 0), (0, 1)),
                    new: span(0, 0, (0, 0), (0, 0)),
                },
                Edit {
                    old: span(20, 20, (2, 5), (2, 5)),
                    new: span(19, 20, (2, 5), (3, 0)),
                },
            ]
        );
    }

    #[test]
    fn a_transaction_that_changes_nothing_has_an_entry_with_no_edit() {
        assert_eq!(logged(&[Change::Retain(20)]), []);
    }

    #[test]
    fn replace_records_the_entry_its_transaction_records() {
        let mut replaced = Text::from(MIXED);
        replaced
            .replace(11..13, "RLX")
            .expect("a range of two positions");
        let replaced = replaced.entry(Revision(1)).expect("the edit's entry");

        assert_eq!(
            replaced.edits(),
            logged(&[
                Change::Retain(11),
                insert("RLX"),
                Change::Delete(2),
                Change::Retain(7),
            ])
        );
        assert_eq!(replaced.revision(), Revision(1));
    }

    /// A text made as "héllo\nwörld" and then changed four times, to
    /// "\nhXYllo\nwörld!": "A\n" is inserted at the start, "é" is replaced
    /// by "XY", "!" is added at the end, and the "A" is deleted.
    fn changed_four_times() -> Text {
        let mut text = Text::from("héllo\nwörld");
        text.replace(0..0, "A\n").expect("an insert at the start");
        let replaced = [
            Change::Retain(3),
            Change::Delete(2),
            insert("XY"),
            Change::Retain(10),
        ];
        text.apply(
            &Transaction::new(replaced.into_iter().collect()),
            Origin::new(7),
        )
        .expect("it fits");
        let added = [Change::Retain(15), insert("!")];
        text.apply(
            &Transaction::new(added.into_iter().collect()),
            Origin::new(9),
        )
        .expect("it fits");
        text.replace(0..1, "").expect("a delete at the start");
        assert_eq!(text.current().to_string(), "\nhXYllo\nwörld!");
        text
    }

    #[test]
    fn what_changed_since_a_revision_is_one_patch_of_ranges_of_the_text_then_and_now() {
        let text = changed_four_times();

        // The "A" that was inserted and then deleted is in no edit.
        assert_eq!(
            text.changes_since(Revision(0)),
            Ok(Patch {
                from: Revision(0),
                to: Revision(4),
                edits: vec![
                    Edit {
                        old: span(0, 0, (0, 0), (0, 0)),
                        new: span(0, 1, (0, 0), (1, 0)),
                    },
                    Edit {
                        old: span(1, 3, (0, 1), (0, 3)),
                        new: span(2, 4, (1, 1), (1, 3)),
                    },
                    Edit {
                        old: span(13, 13, (1, 6), (1, 6)),
                        new: span(14, 15, (2, 6), (2, 7)),
                    },
                ],
            })
        );
        // Since "A\nhXYllo\nwörld".
        assert_eq!(
            text.changes_since(Revision(2)),
            Ok(Patch {
                from: Revision(2),
                to: Revision(4),
                edits: vec![
                    Edit {
                        old: span(0, 1, (0, 0), (0, 1)),
                        new: span(0, 0, (0, 0), (0, 0)),
                    },
                    Edit {
                        old: span(15, 15, (2, 6), (2, 6)),
                        new: span(14, 15, (2, 6), (2, 7)),
                    },
                ],
            })
        );
    }

    #[test]
    fn what_changed_since_the_revision_before_is_the_last_entry() {
        let text = changed_four_times();
        let last = text
            .entry(Revision(4))
            .expect("the last transaction's entry");

        let patch = text.changes_since(Revision(3)).expect("a revision reached");

        assert_eq!(patch.from, Revision(3));
        assert_eq!(patch.to, Revision(4));
        assert_eq!(patch.edits, last.edits());
    }

    #[test]
    fn nothing_changed_since_the_current_revision() {
        let text = changed_four_times();

        assert_eq!(
            text.changes_since(Revision(4)),
            Ok(Patch {
                from: Revision(4),
                to: Revision(4),
                edits: Vec::new(),
            })
        );
        assert_eq!(
            Text::from("héllo").changes_since(Revision(0)),
            Ok(Patch {
                from: Revision(0),
                to: Revision(0),
                edits: Vec::new(),
            })
        );
    }

    #[test]
    fn transactions_that_change_nothing_make_an_empty_patch_that_spans_them() {
        let mut text = Text::from("héllo");
        text.replace(3..3, "").expect("a position");
        text.replace(0..0, "").expect("a position");

        assert_eq!(
            text.changes_since(Revision(0)),
            Ok(Patch {
                from: Revision(0),
                to: Revision(2),
                edits: Vec::new(),
            })
        );
    }

    #[test]
    fn what_changed_since_a_revision_the_text_has_not_reached_is_unknown() {
        let text = changed_four_times();

        assert_eq!(text.changes_since(Revision(5)), Err(LogError::Unknown));
        assert_eq!(
            text.changes_since(Revision(u64::MAX)),
            Err(LogError::Unknown)
        );
    }

    #[test]
    fn a_subscriber_pulls_one_patch_of_what_changed_since_it_last_pulled() {
        let mut text = Text::from("héllo\nwörld");
        let mut subscription = text.subscribe();
        assert_eq!(subscription.revision(), Revision(0));

        // After no edit.
        let nothing = text.pull(&mut subscription).expect("a revision reached");
        assert_eq!((nothing.from, nothing.to), (Revision(0), Revision(0)));
        assert_eq!(nothing.edits, []);

        // After several: one patch.
        text.replace(0..0, "A\n").expect("an insert at the start");
        text.replace(15..15, "!").expect("an insert at the end");
        text.replace(0..1, "").expect("a delete at the start");
        let several = text.pull(&mut subscription);
        assert_eq!(several, text.changes_since(Revision(0)));
        let several = several.expect("a revision reached");
        assert_eq!((several.from, several.to), (Revision(0), Revision(3)));
        assert_eq!(
            several.edits,
            [
                Edit {
                    old: span(0, 0, (0, 0), (0, 0)),
                    new: span(0, 1, (0, 0), (1, 0)),
                },
                Edit {
                    old: span(13, 13, (1, 6), (1, 6)),
                    new: span(14, 15, (2, 6), (2, 7)),
                },
            ]
        );
        assert_eq!(subscription.revision(), Revision(3));

        // A second pull has nothing left.
        let again = text.pull(&mut subscription).expect("a revision reached");
        assert_eq!((again.from, again.to), (Revision(3), Revision(3)));
        assert_eq!(again.edits, []);

        // And the next one starts where the last ended.
        text.replace(0..1, "").expect("a delete at the start");
        let next = text.pull(&mut subscription).expect("a revision reached");
        assert_eq!((next.from, next.to), (Revision(3), Revision(4)));
        assert_eq!(
            next.edits,
            [Edit {
                old: span(0, 1, (0, 0), (1, 0)),
                new: span(0, 0, (0, 0), (0, 0)),
            }]
        );
    }

    #[test]
    fn a_subscriber_sees_only_what_came_after_it_subscribed() {
        let mut text = Text::from("héllo");
        text.replace(0..0, "x").expect("an insert at the start");
        let mut subscription = text.subscribe();
        assert_eq!(subscription.revision(), Revision(1));
        text.replace(7..7, "y").expect("an insert at the end");

        let patch = text.pull(&mut subscription).expect("a revision reached");

        assert_eq!((patch.from, patch.to), (Revision(1), Revision(2)));
        assert_eq!(
            patch.edits,
            [Edit {
                old: span(7, 7, (0, 7), (0, 7)),
                new: span(7, 8, (0, 7), (0, 8)),
            }]
        );
    }

    #[test]
    fn many_entries_coalesce_into_one_patch() {
        // Each transaction inserts one byte at the start, so every one
        // touches the one before it.
        let mut text = Text::from("héllo");
        for _ in 0..37 {
            text.replace(0..0, "x").expect("an insert at the start");
        }

        let patch = text.changes_since(Revision(0)).expect("a revision reached");

        assert_eq!(
            patch.edits,
            [Edit {
                old: span(0, 0, (0, 0), (0, 0)),
                new: span(0, 37, (0, 0), (0, 37)),
            }]
        );
        // From an odd revision, so the halves are uneven.
        let later = text.changes_since(Revision(8)).expect("a revision reached");
        assert_eq!(
            later.edits,
            [Edit {
                old: span(0, 0, (0, 0), (0, 0)),
                new: span(0, 29, (0, 0), (0, 29)),
            }]
        );
    }

    #[test]
    fn the_horizon_of_a_text_whose_log_is_whole_is_revision_zero() {
        let mut text = Text::from(MIXED);
        assert_eq!(text.horizon(), Revision(0));

        text.replace(0..0, "x").expect("an insert at the start");

        assert_eq!(text.horizon(), Revision(0));
    }

    #[test]
    fn an_origin_gives_back_the_value_it_was_made_with() {
        assert_eq!(Origin::new(7).get(), 7);
        assert_eq!(Origin::new(u64::MAX).get(), u64::MAX);
        assert_eq!(Origin::default().get(), 0);
        assert_eq!(Origin::default(), Origin::new(0));
    }

    /// A transaction that inserts `inserted` at the start of `text`.
    fn inserting(text: &Text, inserted: &str) -> Transaction {
        let changes = ChangeSet::replacing(text.current().len(), 0..0, inserted)
            .expect("an insert at the start");
        Transaction::new(changes)
    }

    #[test]
    fn an_entry_has_the_revision_its_transaction_produced_and_the_origin_it_was_applied_with() {
        let mut text = Text::from("héllo");
        let first = inserting(&text, "a");
        let first = text.apply(&first, Origin::new(7)).expect("it fits");
        let second = inserting(&text, "b");
        let second = text.apply(&second, Origin::new(u64::MAX)).expect("it fits");

        let entry = text.entry(first).expect("the first transaction's entry");
        assert_eq!(entry.revision(), first);
        assert_eq!(entry.origin(), Origin::new(7));
        let entry = text.entry(second).expect("the second transaction's entry");
        assert_eq!(entry.revision(), second);
        assert_eq!(entry.origin(), Origin::new(u64::MAX));
    }

    #[test]
    fn there_is_no_entry_for_revision_zero_or_for_a_revision_the_text_has_not_reached() {
        let mut text = Text::from("héllo");
        let start = text.current().revision();
        assert!(text.entry(start).is_none());

        let transaction = inserting(&text, "a");
        let reached = text.apply(&transaction, Origin::new(1)).expect("it fits");

        assert!(text.entry(start).is_none());
        assert!(text.entry(reached).is_some());
        assert!(text.entry(Revision(2)).is_none());
        assert!(text.entry(Revision(u64::MAX)).is_none());
    }

    #[test]
    fn a_refused_transaction_leaves_no_entry() {
        let mut text = Text::from("héllo");
        let short = Transaction::new(ChangeSet::replacing(3, 0..0, "x").expect("in order"));

        assert!(text.apply(&short, Origin::new(1)).is_err());

        assert!(text.entry(Revision(1)).is_none());
    }

    #[test]
    fn replace_is_recorded_with_the_default_origin() {
        let mut text = Text::from("héllo");
        text.replace(0..0, "x").expect("an insert at the start");

        let entry = text.entry(Revision(1)).expect("the edit's entry");
        assert_eq!(entry.origin(), Origin::default());
    }
}
