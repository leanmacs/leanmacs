//! The edit log: what was done to a text, one entry for each transaction
//! it accepted.

use std::collections::VecDeque;

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
}

/// The entries of one text, oldest first.
#[derive(Debug, Default)]
pub(crate) struct Log {
    /// The entries. The one for the revision `r` is at index `r - 1`, so no
    /// entry stores its revision.
    entries: VecDeque<Entry>,
}

impl Log {
    /// Records the transaction that produced the next revision.
    pub(crate) fn record(&mut self, origin: Origin) {
        self.entries.push_back(Entry { origin });
    }

    /// The entry of the transaction that produced `revision`. `None` for
    /// revision 0, which no transaction produced, and for a revision the
    /// text has not reached.
    pub(crate) fn entry(&self, revision: Revision) -> Option<LogEntry<'_>> {
        let index = usize::try_from(revision.get().checked_sub(1)?).ok()?;
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ChangeSet, Text, Transaction};

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
