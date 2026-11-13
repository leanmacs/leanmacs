//! The edit log: what was done to a text, one entry for each transaction
//! it accepted.

use std::collections::VecDeque;

use crate::patch::Edit;
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

impl LogEntry<'_> {
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
    pub fn edits(&self) -> &[Edit] {
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
