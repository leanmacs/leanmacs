//! Change sets: an edit as a walk over the text.
//!
//! The crate docs give the rules: what a change is, the one form a change
//! set is kept in, and when a change set fits a text.

use std::ops::Range;

/// One step of a change set's walk over the text. Lengths are in bytes of
/// the text's UTF-8.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Change {
    /// Keep the next bytes as they are.
    Retain(usize),
    /// Remove the next bytes.
    Delete(usize),
    /// Put this text in at this point.
    Insert(String),
}

/// An edit to a text of one length: changes that walk it from its start to
/// its end, keeping, removing and inserting.
///
/// A change set is built by pushing changes, and is always in one normal
/// form, so two change sets that do the same thing in the same places are
/// equal:
///
/// - no change has length zero;
/// - no two neighbours are of one kind;
/// - between two retains there is at most one insert and one delete, the
///   insert first.
///
/// The default change set has no change: it is the identity for an empty
/// text.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ChangeSet {
    /// The changes, in the normal form.
    changes: Vec<Change>,
    /// The length of the text this is for: what is retained and deleted.
    len_before: usize,
    /// The length of the text this makes: what is retained and inserted.
    len_after: usize,
}

impl ChangeSet {
    /// A change set with no change.
    pub fn new() -> Self {
        Self::default()
    }

    /// The change set for a text of `len` bytes that replaces the bytes of
    /// `range` with `text` and keeps the rest. `None` unless the range is in
    /// order and within `len`.
    pub fn replacing(len: usize, range: Range<usize>, text: &str) -> Option<Self> {
        let Range { start, end } = range;
        if start > end || end > len {
            return None;
        }
        let mut changes = Self::new();
        changes.retain(start);
        changes.insert(text);
        changes.delete(end - start);
        changes.retain(len - end);
        Some(changes)
    }

    /// Keeps the next `len` bytes. Joins a retain it follows; a length of
    /// zero adds nothing.
    ///
    /// A length that would overflow saturates, here and in the other
    /// pushes. The change set is then for a text longer than any there is,
    /// so it fits none.
    pub fn retain(&mut self, len: usize) {
        if len == 0 {
            return;
        }
        self.len_before = self.len_before.saturating_add(len);
        self.len_after = self.len_after.saturating_add(len);
        match self.changes.last_mut() {
            Some(Change::Retain(last)) => *last = last.saturating_add(len),
            _ => self.changes.push(Change::Retain(len)),
        }
    }

    /// Removes the next `len` bytes. Joins a delete it follows; a length of
    /// zero adds nothing.
    pub fn delete(&mut self, len: usize) {
        if len == 0 {
            return;
        }
        self.len_before = self.len_before.saturating_add(len);
        match self.changes.last_mut() {
            Some(Change::Delete(last)) => *last = last.saturating_add(len),
            _ => self.changes.push(Change::Delete(len)),
        }
    }

    /// Puts `text` in at this point. An empty text adds nothing.
    ///
    /// Text inserted where bytes were just deleted goes before the delete,
    /// and joins an insert already there: the two are one replaced range,
    /// whichever was pushed first.
    pub fn insert(&mut self, text: &str) {
        if text.is_empty() {
            return;
        }
        self.len_after = self.len_after.saturating_add(text.len());
        match self.changes.as_mut_slice() {
            [.., Change::Insert(last)] | [.., Change::Insert(last), Change::Delete(_)] => {
                last.push_str(text);
            }
            [.., Change::Delete(_)] => {
                let before_the_delete = self.changes.len() - 1;
                self.changes
                    .insert(before_the_delete, Change::Insert(text.to_owned()));
            }
            _ => self.changes.push(Change::Insert(text.to_owned())),
        }
    }

    /// The changes, in order, in the normal form.
    pub fn changes(&self) -> &[Change] {
        &self.changes
    }

    /// The length in bytes of the text this change set is for.
    pub fn len_before(&self) -> usize {
        self.len_before
    }

    /// The length in bytes of the text this change set makes.
    pub fn len_after(&self) -> usize {
        self.len_after
    }

    /// Whether the change set changes nothing: it only retains.
    pub fn is_identity(&self) -> bool {
        // In the normal form, retains alone are at most one change.
        matches!(self.changes.as_slice(), [] | [Change::Retain(_)])
    }
}

impl FromIterator<Change> for ChangeSet {
    fn from_iter<I: IntoIterator<Item = Change>>(changes: I) -> Self {
        let mut set = Self::new();
        for change in changes {
            match change {
                Change::Retain(len) => set.retain(len),
                Change::Delete(len) => set.delete(len),
                Change::Insert(text) => set.insert(&text),
            }
        }
        set
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The change set the pushes of `build` make.
    fn built(build: impl FnOnce(&mut ChangeSet)) -> ChangeSet {
        let mut changes = ChangeSet::new();
        build(&mut changes);
        changes
    }

    /// An insert of `text`.
    fn insert(text: &str) -> Change {
        Change::Insert(text.to_owned())
    }

    #[test]
    fn a_new_change_set_has_no_change_and_is_for_an_empty_text() {
        let changes = ChangeSet::new();

        assert_eq!(changes.changes(), &[]);
        assert_eq!(changes.len_before(), 0);
        assert_eq!(changes.len_after(), 0);
        assert_eq!(changes, ChangeSet::default());
    }

    #[test]
    fn the_changes_read_back_in_the_order_they_were_pushed() {
        let changes = built(|changes| {
            changes.retain(3);
            changes.insert("XY");
            changes.delete(2);
            changes.retain(10);
        });

        assert_eq!(
            changes.changes(),
            &[
                Change::Retain(3),
                insert("XY"),
                Change::Delete(2),
                Change::Retain(10)
            ]
        );
    }

    #[test]
    fn a_change_of_length_zero_is_dropped() {
        let changes = built(|changes| {
            changes.retain(0);
            changes.delete(0);
            changes.insert("");
            changes.retain(2);
            changes.insert("");
            changes.delete(0);
            changes.retain(0);
        });

        assert_eq!(changes.changes(), &[Change::Retain(2)]);
    }

    #[test]
    fn neighbours_of_one_kind_are_merged() {
        let changes = built(|changes| {
            changes.retain(1);
            changes.retain(2);
            changes.delete(3);
            changes.delete(4);
            changes.retain(5);
            changes.insert("hé");
            changes.insert("llo");
        });

        assert_eq!(
            changes.changes(),
            &[
                Change::Retain(3),
                Change::Delete(7),
                Change::Retain(5),
                insert("héllo")
            ]
        );
    }

    #[test]
    fn neighbours_that_a_dropped_change_stood_between_are_merged() {
        let changes = built(|changes| {
            changes.retain(1);
            changes.insert("");
            changes.retain(2);
        });

        assert_eq!(changes.changes(), &[Change::Retain(3)]);
    }

    #[test]
    fn an_insert_after_a_delete_goes_before_it() {
        let changes = built(|changes| {
            changes.retain(1);
            changes.delete(2);
            changes.insert("x");
            changes.retain(1);
        });

        assert_eq!(
            changes.changes(),
            &[
                Change::Retain(1),
                insert("x"),
                Change::Delete(2),
                Change::Retain(1)
            ]
        );
        assert_eq!(
            changes,
            built(|changes| {
                changes.retain(1);
                changes.insert("x");
                changes.delete(2);
                changes.retain(1);
            })
        );
    }

    #[test]
    fn an_insert_after_an_insert_and_a_delete_joins_the_insert() {
        let changes = built(|changes| {
            changes.insert("a");
            changes.delete(2);
            changes.insert("b");
            changes.delete(1);
            changes.insert("c");
        });

        assert_eq!(changes.changes(), &[insert("abc"), Change::Delete(3)]);
    }

    #[test]
    fn the_length_before_is_what_is_retained_and_deleted() {
        let changes = built(|changes| {
            changes.retain(3);
            changes.insert("héllo");
            changes.delete(2);
            changes.retain(10);
        });

        assert_eq!(changes.len_before(), 15);
    }

    #[test]
    fn the_length_after_is_what_is_retained_and_inserted_in_bytes() {
        let changes = built(|changes| {
            changes.retain(3);
            changes.insert("héllo");
            changes.delete(2);
            changes.retain(10);
        });

        assert_eq!(changes.len_after(), 19);
    }

    #[test]
    fn replacing_an_empty_range_inserts() {
        assert_eq!(
            ChangeSet::replacing(5, 2..2, "xy"),
            Some(built(|changes| {
                changes.retain(2);
                changes.insert("xy");
                changes.retain(3);
            }))
        );
        assert_eq!(
            ChangeSet::replacing(0, 0..0, "xy"),
            Some(built(|changes| changes.insert("xy")))
        );
    }

    #[test]
    fn replacing_with_an_empty_text_deletes() {
        assert_eq!(
            ChangeSet::replacing(5, 1..4, ""),
            Some(built(|changes| {
                changes.retain(1);
                changes.delete(3);
                changes.retain(1);
            }))
        );
    }

    #[test]
    fn replacing_puts_the_text_in_place_of_the_range() {
        let changes = ChangeSet::replacing(5, 0..5, "xyz").expect("a range within the length");

        assert_eq!(changes.changes(), &[insert("xyz"), Change::Delete(5)]);
        assert_eq!(changes.len_before(), 5);
        assert_eq!(changes.len_after(), 3);
    }

    #[test]
    fn replacing_nothing_with_nothing_is_the_identity_for_the_length() {
        let changes = ChangeSet::replacing(5, 2..2, "").expect("a range within the length");

        assert_eq!(changes.changes(), &[Change::Retain(5)]);
        assert!(changes.is_identity());
    }

    // The range is the point of the test: it is one a caller can pass.
    #[expect(clippy::reversed_empty_ranges)]
    #[test]
    fn replacing_is_none_for_a_range_that_is_backwards_or_past_the_length() {
        assert_eq!(ChangeSet::replacing(5, 3..1, "x"), None);
        assert_eq!(ChangeSet::replacing(5, 6..6, "x"), None);
        assert_eq!(ChangeSet::replacing(5, 0..6, ""), None);
        assert_eq!(ChangeSet::replacing(5, usize::MAX..usize::MAX, "x"), None);
    }

    #[test]
    fn collecting_changes_gives_what_pushing_them_gives() {
        let collected: ChangeSet = [
            Change::Retain(1),
            Change::Retain(0),
            Change::Delete(2),
            insert("x"),
            insert(""),
            insert("y"),
            Change::Retain(1),
            Change::Retain(1),
        ]
        .into_iter()
        .collect();

        assert_eq!(
            collected,
            built(|changes| {
                changes.retain(1);
                changes.insert("xy");
                changes.delete(2);
                changes.retain(2);
            })
        );
    }

    #[test]
    fn a_push_that_would_overflow_saturates_and_does_not_panic() {
        let changes = built(|changes| {
            changes.retain(usize::MAX);
            changes.retain(2);
            changes.delete(usize::MAX);
            changes.delete(usize::MAX);
            changes.insert("x");
        });

        assert_eq!(
            changes.changes(),
            &[
                Change::Retain(usize::MAX),
                insert("x"),
                Change::Delete(usize::MAX)
            ]
        );
        assert_eq!(changes.len_before(), usize::MAX);
        assert_eq!(changes.len_after(), usize::MAX);
    }

    #[test]
    fn a_change_set_that_only_retains_is_the_identity() {
        assert!(ChangeSet::new().is_identity());
        assert!(built(|changes| changes.retain(7)).is_identity());
        assert!(!built(|changes| changes.insert("x")).is_identity());
        assert!(!built(|changes| changes.delete(1)).is_identity());
        assert!(
            !built(|changes| {
                changes.retain(1);
                changes.delete(1);
                changes.retain(1);
            })
            .is_identity()
        );
    }
}
