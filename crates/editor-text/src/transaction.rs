//! A transaction: a change set, and the selection before and after it.

use std::error::Error;
use std::fmt;

use crate::change::ChangeSet;
use crate::selection::Selection;

/// A change set and, optionally, the selection before it and the selection
/// after it. It is what [`Text::apply`](crate::Text::apply) takes.
///
/// A selection is optional because a formatter's transaction, an agent's or
/// a reload's has none. Who applies the transaction is not part of it: the
/// [`Origin`](crate::Origin) is an argument of applying, so the inverse of
/// one author's transaction, applied by another's undo, is the other's.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Transaction {
    /// What to do to the text.
    changes: ChangeSet,
    /// The selection in the text before the changes.
    before: Option<Selection>,
    /// The selection in the text after the changes.
    after: Option<Selection>,
}

impl Transaction {
    /// The transaction of `changes`, with no selection before or after.
    pub fn new(changes: ChangeSet) -> Self {
        Self {
            changes,
            before: None,
            after: None,
        }
    }

    /// This transaction with `selection` as the selection before it: ranges
    /// of the text the change set is for.
    pub fn with_before(mut self, selection: Selection) -> Self {
        self.before = Some(selection);
        self
    }

    /// This transaction with `selection` as the selection after it: ranges
    /// of the text the change set makes.
    pub fn with_after(mut self, selection: Selection) -> Self {
        self.after = Some(selection);
        self
    }

    /// What the transaction does to the text.
    pub fn changes(&self) -> &ChangeSet {
        &self.changes
    }

    /// The selection before the changes, if the transaction has one.
    pub fn before(&self) -> Option<&Selection> {
        self.before.as_ref()
    }

    /// The selection after the changes, if the transaction has one.
    pub fn after(&self) -> Option<&Selection> {
        self.after.as_ref()
    }
}

impl From<ChangeSet> for Transaction {
    fn from(changes: ChangeSet) -> Self {
        Self::new(changes)
    }
}

/// Why a transaction was refused ([`Text::apply`](crate::Text::apply)).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApplyError {
    /// The change set does not fit the text: it is for another length, or a
    /// boundary between two of its changes is inside a character.
    BadChange,
    /// An end of a range of the selection before is not a position of the
    /// text before the changes, or one of the selection after is not a
    /// position of the text after them.
    BadSelection,
}

impl fmt::Display for ApplyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::BadChange => "the change set does not fit the text",
            Self::BadSelection => "a selection's end is not a position of its text",
        })
    }
}

impl Error for ApplyError {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::selection::SelectionRange;

    /// A selection of the one range `anchor..head`.
    fn selection(anchor: usize, head: usize) -> Selection {
        Selection::new(vec![SelectionRange::new(anchor, head)], 0).expect("one range")
    }

    /// A change set that inserts "x" at the start of a text of three bytes.
    fn changes() -> ChangeSet {
        ChangeSet::replacing(3, 0..0, "x").expect("a range in order within the length")
    }

    #[test]
    fn a_new_transaction_has_its_change_set_and_no_selection() {
        let transaction = Transaction::new(changes());

        assert_eq!(transaction.changes(), &changes());
        assert_eq!(transaction.before(), None);
        assert_eq!(transaction.after(), None);
        assert_eq!(Transaction::from(changes()), transaction);
    }

    #[test]
    fn a_transaction_carries_the_selections_it_is_given() {
        let transaction = Transaction::new(changes())
            .with_before(selection(0, 3))
            .with_after(selection(4, 1));

        assert_eq!(transaction.changes(), &changes());
        assert_eq!(transaction.before(), Some(&selection(0, 3)));
        assert_eq!(transaction.after(), Some(&selection(4, 1)));
    }
}
