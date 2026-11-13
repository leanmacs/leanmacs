//! Change sets: an edit as a walk over the text.
//!
//! The crate docs give the rules: what a change is, the one form a change
//! set is kept in, and when a change set fits a text.

use std::iter::Peekable;
use std::ops::Range;
use std::slice;

use crate::rope::Rope;
use crate::snapshot::Snapshot;

/// Which side of text inserted at a position the position stays on when it
/// is mapped through a change set ([`ChangeSet::map`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Bias {
    /// The position stays before the inserted text.
    Before,
    /// The position goes after the inserted text.
    After,
}

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

    /// The change set that does this one and then `then`: applying it to a
    /// text this one fits makes what applying this one and then `then`
    /// makes. Text this one inserts and `then` deletes is in neither.
    ///
    /// `None` unless `then` is for the length this one makes, and cuts no
    /// character this one inserts. Whether `then` cuts a character this one
    /// retains is not looked at: only a text can say.
    pub fn compose(&self, then: &ChangeSet) -> Option<ChangeSet> {
        if self.len_after != then.len_before {
            return None;
        }
        // The walk is over the text between the two: what this one makes
        // and `then` is for. Each side holds what is left of its change.
        let mut composed = ChangeSet::new();
        let mut made = self.changes.iter().map(Rest::of);
        let mut taken = then.changes.iter().map(Rest::of);
        let (mut first, mut second) = (made.next(), taken.next());
        loop {
            match (first, second) {
                (None, None) => return Some(composed),
                // What the first deletes was never in the text between.
                (Some(Rest::Delete(len)), _) => {
                    composed.delete(len);
                    first = made.next();
                }
                // What the second inserts is not in it either.
                (_, Some(Rest::Insert(text))) => {
                    composed.insert(text);
                    second = taken.next();
                }
                // One ran out before the other: the lengths saturated.
                (None, Some(_)) | (Some(_), None) => return None,
                (Some(Rest::Retain(kept)), Some(Rest::Retain(len))) => {
                    let both = kept.min(len);
                    composed.retain(both);
                    first = Rest::Retain(kept - both).or_next(&mut made);
                    second = Rest::Retain(len - both).or_next(&mut taken);
                }
                (Some(Rest::Retain(kept)), Some(Rest::Delete(len))) => {
                    let both = kept.min(len);
                    composed.delete(both);
                    first = Rest::Retain(kept - both).or_next(&mut made);
                    second = Rest::Delete(len - both).or_next(&mut taken);
                }
                (Some(Rest::Insert(text)), Some(Rest::Retain(len))) => {
                    let both = text.len().min(len);
                    let (kept, rest) = text.split_at_checked(both)?;
                    composed.insert(kept);
                    first = Rest::Insert(rest).or_next(&mut made);
                    second = Rest::Retain(len - both).or_next(&mut taken);
                }
                (Some(Rest::Insert(text)), Some(Rest::Delete(len))) => {
                    let both = text.len().min(len);
                    let (_, rest) = text.split_at_checked(both)?;
                    first = Rest::Insert(rest).or_next(&mut made);
                    second = Rest::Delete(len - both).or_next(&mut taken);
                }
            }
        }
    }

    /// The change set that undoes this one on the text this one makes of
    /// `before`: a retain stays, a delete becomes an insert of the bytes it
    /// removed, read from `before`, and an insert becomes a delete of its
    /// length. `None` unless this change set fits `before`.
    ///
    /// The inverse fits the text this one makes, and its own inverse on
    /// that text is this change set.
    pub fn invert(&self, before: &Snapshot) -> Option<ChangeSet> {
        if !self.fits(&before.rope) {
            return None;
        }
        let mut inverse = ChangeSet::new();
        let mut at = 0_usize;
        for change in &self.changes {
            match change {
                Change::Retain(len) => {
                    inverse.retain(*len);
                    at = at.saturating_add(*len);
                }
                Change::Delete(len) => {
                    let end = at.saturating_add(*len);
                    for removed in before.chunks_in(at..end)? {
                        inverse.insert(removed);
                    }
                    at = end;
                }
                Change::Insert(text) => inverse.delete(text.len()),
            }
        }
        Some(inverse)
    }

    /// Where the offset `offset` of the text this change set is for is in
    /// the text it makes. `None` for an offset past
    /// [`len_before`](Self::len_before). Whether an offset is a position is
    /// the text's to say; for a change set that fits its text, a position
    /// maps to a position.
    ///
    /// | Where the offset is | [`Bias::Before`] | [`Bias::After`] |
    /// |---|---|---|
    /// | In retained text, or at its start with nothing inserted there | Moves with the text | The same |
    /// | Where text is inserted and nothing deleted | Stays before the inserted text | Goes after it |
    /// | At the start of, or inside, a range that is replaced | The start of the replacement | The end of the replacement |
    /// | At the start of, or inside, a range that is deleted with nothing inserted | The point the range collapsed to | The same |
    /// | At the end of a deleted or replaced range | After the replacement | The same |
    ///
    /// Mapping through a composition is not always mapping through each
    /// change set in turn: a position that must survive several edits is
    /// mapped at each one.
    pub fn map(&self, offset: usize, bias: Bias) -> Option<usize> {
        if offset > self.len_before {
            return None;
        }
        // Where the walk is, in the text before and in the text after.
        let (mut old, mut new) = (0_usize, 0_usize);
        let mut changes = self.changes.iter().peekable();
        while let Some(change) = changes.next() {
            match change {
                Change::Retain(len) => {
                    let end = old.saturating_add(*len);
                    if offset < end {
                        return Some(new.saturating_add(offset - old));
                    }
                    old = end;
                    new = new.saturating_add(*len);
                }
                Change::Delete(len) => {
                    let end = old.saturating_add(*len);
                    if offset < end {
                        return Some(new);
                    }
                    old = end;
                }
                Change::Insert(text) => {
                    // In the normal form, a delete after an insert is the
                    // range the insert replaces.
                    let replaced = match changes.next_if(|next| matches!(next, Change::Delete(_))) {
                        Some(Change::Delete(len)) => *len,
                        _ => 0,
                    };
                    let end = old.saturating_add(replaced);
                    let after = new.saturating_add(text.len());
                    if offset == old || offset < end {
                        return Some(match bias {
                            Bias::Before => new,
                            Bias::After => after,
                        });
                    }
                    old = end;
                    new = after;
                }
            }
        }
        Some(new)
    }

    /// A mapper through this change set: [`map`](Self::map) for many
    /// positions in one pass ([`Mapper`]).
    pub fn mapper(&self) -> Mapper<'_> {
        Mapper {
            changes: self,
            next: 0,
            old: 0,
            new: 0,
            last: 0,
        }
    }

    /// Whether the change set fits the text of `rope`: it is for the text's
    /// length, and every boundary between two of its changes is a character
    /// boundary of the text.
    pub(crate) fn fits(&self, rope: &Rope) -> bool {
        if self.len_before != rope.len() {
            return false;
        }
        let mut at = 0_usize;
        self.changes.iter().all(|change| match change {
            Change::Retain(len) | Change::Delete(len) => {
                at = at.saturating_add(*len);
                rope.is_char_boundary(at)
            }
            Change::Insert(_) => true,
        })
    }

    /// Makes the changes to `rope`, and returns whether it made them all.
    ///
    /// The caller has checked that the change set [fits](Self::fits) the
    /// rope, which is all a step below can fail on. So false is not
    /// expected; it is returned, and not a panic, because the rope reports
    /// its refusals. The rope may then be changed in part: the caller
    /// applies to a clone.
    pub(crate) fn apply_to(&self, rope: &mut Rope) -> bool {
        // Where the walk is, in the text as changed so far.
        let mut at = 0_usize;
        self.changes.iter().all(|change| match change {
            Change::Retain(len) => {
                at = at.saturating_add(*len);
                true
            }
            Change::Delete(len) => rope.replace(at, at.saturating_add(*len), ""),
            Change::Insert(text) => {
                let inserted = rope.replace(at, at, text);
                at = at.saturating_add(text.len());
                inserted
            }
        })
    }

    /// The ranges the change set changes, in order: for each run of deletes
    /// and inserts between two retains, the range of the text before that
    /// is replaced and the range of the text after that replaces it. One
    /// of the two may be empty, and not both.
    pub(crate) fn runs(&self) -> Runs<'_> {
        Runs {
            changes: self.changes.iter().peekable(),
            old: 0,
            new: 0,
        }
    }
}

/// Maps positions through one change set, keeping its place in it
/// ([`ChangeSet::mapper`]).
///
/// [`Mapper::map`] gives what [`ChangeSet::map`] gives, for any offsets in
/// any order. Asked in rising order, all of them together cost one walk of
/// the change set, where [`ChangeSet::map`] walks it for each; an offset
/// lower than the one before starts the walk again.
#[derive(Debug, Clone)]
pub struct Mapper<'a> {
    /// The change set positions are mapped through.
    changes: &'a ChangeSet,
    /// The index of the change the walk is at: every earlier one is
    /// wholly before the last offset asked.
    next: usize,
    /// Where that change starts in the text before.
    old: usize,
    /// Where that change starts in the text after.
    new: usize,
    /// The last offset asked that was within the length.
    last: usize,
}

impl Mapper<'_> {
    /// Where `offset` is in the text the change set makes:
    /// [`ChangeSet::map`] of the same offset and bias.
    pub fn map(&mut self, offset: usize, bias: Bias) -> Option<usize> {
        if offset > self.changes.len_before {
            return None;
        }
        // Every change the walk has passed ends at or before the last
        // offset asked, and none of them inserts at it. So the walk is
        // still right for that offset and any later one, and for no
        // earlier one.
        if offset < self.last {
            (self.next, self.old, self.new) = (0, 0, 0);
        }
        self.last = offset;
        let changes = &self.changes.changes;
        // The change the offset is found in is not passed: a later offset
        // may be in it too.
        loop {
            #[cfg(test)]
            steps::step();
            match changes.get(self.next) {
                None => return Some(self.new),
                Some(Change::Retain(len)) => {
                    let end = self.old.saturating_add(*len);
                    if offset < end {
                        return Some(self.new.saturating_add(offset - self.old));
                    }
                    self.old = end;
                    self.new = self.new.saturating_add(*len);
                    self.next += 1;
                }
                Some(Change::Delete(len)) => {
                    let end = self.old.saturating_add(*len);
                    if offset < end {
                        return Some(self.new);
                    }
                    self.old = end;
                    self.next += 1;
                }
                Some(Change::Insert(text)) => {
                    // In the normal form, a delete after an insert is the
                    // range the insert replaces.
                    let replaced = match changes.get(self.next + 1) {
                        Some(Change::Delete(len)) => Some(*len),
                        _ => None,
                    };
                    let end = self.old.saturating_add(replaced.unwrap_or(0));
                    let after = self.new.saturating_add(text.len());
                    if offset == self.old || offset < end {
                        return Some(match bias {
                            Bias::Before => self.new,
                            Bias::After => after,
                        });
                    }
                    self.old = end;
                    self.new = after;
                    self.next += if replaced.is_some() { 2 } else { 1 };
                }
            }
        }
    }
}

/// What the mappers of a test cost: how many times they looked at a place
/// in their change set. It is counted in tests only, and for each thread on
/// its own, so tests that run side by side do not count each other's.
///
/// A mapper looks once at the place each answer is found at, and once at
/// each change it passes. So offsets asked in rising order cost no more
/// than the offsets asked plus the changes, and a mapper that started
/// again for each would cost the two multiplied.
#[cfg(test)]
pub(crate) mod steps {
    use std::cell::Cell;

    thread_local! {
        /// The looks counted on this thread so far.
        static TAKEN: Cell<usize> = const { Cell::new(0) };
    }

    /// Counts one look.
    pub(super) fn step() {
        TAKEN.with(|taken| taken.set(taken.get().saturating_add(1)));
    }

    /// What `work` gives, and how many looks the mappers it ran on this
    /// thread took.
    pub(crate) fn during<T>(work: impl FnOnce() -> T) -> (T, usize) {
        let before = TAKEN.with(Cell::get);
        let done = work();
        (done, TAKEN.with(Cell::get).saturating_sub(before))
    }
}

/// The changed ranges of a change set ([`ChangeSet::runs`]).
pub(crate) struct Runs<'a> {
    /// The changes not yet walked.
    changes: Peekable<slice::Iter<'a, Change>>,
    /// Where the walk is in the text before.
    old: usize,
    /// Where the walk is in the text after.
    new: usize,
}

impl Iterator for Runs<'_> {
    type Item = (Range<usize>, Range<usize>);

    fn next(&mut self) -> Option<Self::Item> {
        // The retains before the run.
        while let Some(Change::Retain(len)) = self.changes.peek() {
            self.old = self.old.saturating_add(*len);
            self.new = self.new.saturating_add(*len);
            self.changes.next();
        }
        let (old_start, new_start) = (self.old, self.new);
        while let Some(change) = self
            .changes
            .next_if(|change| !matches!(change, Change::Retain(_)))
        {
            match change {
                Change::Delete(len) => self.old = self.old.saturating_add(*len),
                Change::Insert(text) => self.new = self.new.saturating_add(text.len()),
                Change::Retain(_) => {}
            }
        }
        // In the normal form every change has a length, so a run that has a
        // change has a range that is not empty.
        (self.old > old_start || self.new > new_start)
            .then_some((old_start..self.old, new_start..self.new))
    }
}

/// What is left of one change while two change sets are composed.
#[derive(Clone, Copy)]
enum Rest<'a> {
    /// Bytes still to keep.
    Retain(usize),
    /// Bytes still to remove.
    Delete(usize),
    /// Text still to put in.
    Insert(&'a str),
}

impl<'a> Rest<'a> {
    /// The whole of `change`.
    fn of(change: &'a Change) -> Self {
        match change {
            Change::Retain(len) => Self::Retain(*len),
            Change::Delete(len) => Self::Delete(*len),
            Change::Insert(text) => Self::Insert(text),
        }
    }

    /// This, or the next of `changes` when nothing of this is left.
    fn or_next(self, changes: &mut impl Iterator<Item = Self>) -> Option<Self> {
        let left = match self {
            Self::Retain(len) | Self::Delete(len) => len,
            Self::Insert(text) => text.len(),
        };
        if left == 0 {
            changes.next()
        } else {
            Some(self)
        }
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

    /// The change set of `changes`.
    fn set(changes: &[Change]) -> ChangeSet {
        changes.iter().cloned().collect()
    }

    #[test]
    fn composing_an_insert_with_a_delete_of_it_is_the_identity() {
        let first = set(&[Change::Retain(1), insert("xy"), Change::Retain(2)]);
        let then = set(&[Change::Retain(1), Change::Delete(2), Change::Retain(2)]);

        assert_eq!(first.compose(&then), Some(set(&[Change::Retain(3)])));
    }

    #[test]
    fn composing_a_delete_with_an_insert_where_it_collapsed_is_a_replacement() {
        let first = set(&[Change::Retain(1), Change::Delete(2), Change::Retain(1)]);
        let then = set(&[Change::Retain(1), insert("Z"), Change::Retain(1)]);

        assert_eq!(
            first.compose(&then),
            Some(set(&[
                Change::Retain(1),
                insert("Z"),
                Change::Delete(2),
                Change::Retain(1)
            ]))
        );
    }

    #[test]
    fn a_composition_does_the_first_and_then_the_second() {
        // "abcd" becomes "abXYcd", which becomes "bX-Ycd".
        let first = set(&[Change::Retain(2), insert("XY"), Change::Retain(2)]);
        let then = set(&[
            Change::Delete(1),
            Change::Retain(2),
            insert("-"),
            Change::Retain(3),
        ]);

        let composed = first.compose(&then).expect("the lengths agree");

        assert_eq!(
            composed,
            set(&[
                Change::Delete(1),
                Change::Retain(1),
                insert("X-Y"),
                Change::Retain(2)
            ])
        );
        assert_eq!(composed.len_before(), 4);
        assert_eq!(composed.len_after(), 6);
    }

    #[test]
    fn composing_with_the_identity_changes_nothing() {
        let changes = set(&[Change::Retain(2), insert("XY"), Change::Delete(2)]);

        assert_eq!(
            set(&[Change::Retain(4)]).compose(&changes),
            Some(changes.clone())
        );
        assert_eq!(
            changes.compose(&set(&[Change::Retain(4)])),
            Some(changes.clone())
        );
        assert_eq!(
            ChangeSet::new().compose(&ChangeSet::new()),
            Some(ChangeSet::new())
        );
    }

    #[test]
    fn a_composition_is_none_when_the_second_is_for_another_length() {
        let first = set(&[Change::Retain(1), insert("xy"), Change::Retain(2)]);

        assert_eq!(first.compose(&set(&[Change::Retain(3)])), None);
        assert_eq!(first.compose(&set(&[Change::Retain(6)])), None);
        assert_eq!(first.compose(&ChangeSet::new()), None);
    }

    #[test]
    fn a_composition_is_none_when_the_second_cuts_a_character_the_first_inserted() {
        // "é" is two bytes.
        let first = set(&[insert("é")]);

        assert_eq!(
            first.compose(&set(&[Change::Retain(1), Change::Delete(1)])),
            None
        );
        assert_eq!(
            first.compose(&set(&[Change::Delete(1), Change::Retain(1)])),
            None
        );
        assert_eq!(
            first.compose(&set(&[Change::Retain(1), insert("x"), Change::Retain(1)])),
            None
        );
        assert_eq!(
            first.compose(&set(&[Change::Delete(2)])),
            Some(ChangeSet::new())
        );
    }

    /// A snapshot of `text`.
    fn snapshot(text: &str) -> Snapshot {
        crate::Text::from(text).snapshot()
    }

    #[test]
    fn the_inverse_of_a_retain_is_the_retain() {
        let before = snapshot("héllo");

        assert_eq!(
            set(&[Change::Retain(6)]).invert(&before),
            Some(set(&[Change::Retain(6)]))
        );
    }

    #[test]
    fn the_inverse_of_a_delete_inserts_the_bytes_it_removed() {
        let before = snapshot("héllo");
        let changes = set(&[Change::Retain(1), Change::Delete(2), Change::Retain(3)]);

        assert_eq!(
            changes.invert(&before),
            Some(set(&[Change::Retain(1), insert("é"), Change::Retain(3)]))
        );
    }

    #[test]
    fn the_inverse_of_an_insert_deletes_its_length() {
        let before = snapshot("héllo");
        let changes = set(&[Change::Retain(1), insert("😀"), Change::Retain(5)]);

        assert_eq!(
            changes.invert(&before),
            Some(set(&[
                Change::Retain(1),
                Change::Delete(4),
                Change::Retain(5)
            ]))
        );
    }

    #[test]
    fn the_inverse_of_a_replacement_puts_back_what_was_replaced() {
        let before = snapshot("héllo");
        let changes = set(&[insert("HE"), Change::Delete(3), Change::Retain(3)]);

        assert_eq!(
            changes.invert(&before),
            Some(set(&[insert("hé"), Change::Delete(2), Change::Retain(3)]))
        );
    }

    #[test]
    fn the_inverse_of_a_delete_of_many_pieces_is_one_insert() {
        let line = "a line with an é in it\n";
        let string = line.repeat(8_000);
        let before = snapshot(&string);
        let middle = line.len() * 4_000;
        let changes = set(&[
            Change::Retain(line.len()),
            Change::Delete(middle),
            Change::Retain(string.len() - middle - line.len()),
        ]);

        let inverse = changes.invert(&before).expect("it fits");

        assert_eq!(
            inverse,
            set(&[
                Change::Retain(line.len()),
                insert(&string[line.len()..line.len() + middle]),
                Change::Retain(string.len() - middle - line.len()),
            ])
        );
    }

    #[test]
    fn there_is_no_inverse_for_a_snapshot_the_change_set_does_not_fit() {
        let before = snapshot("héllo");

        // Short, long, and a boundary inside "é".
        assert_eq!(set(&[Change::Retain(5)]).invert(&before), None);
        assert_eq!(set(&[Change::Delete(7)]).invert(&before), None);
        assert_eq!(
            set(&[Change::Retain(2), Change::Delete(4)]).invert(&before),
            None
        );
        assert_eq!(
            set(&[Change::Delete(2), Change::Retain(4)]).invert(&before),
            None
        );
    }

    /// A change set over ten bytes with one of each case of the mapping:
    /// text inserted at 2, the bytes 4 and 5 replaced by three, and the
    /// bytes 7 and 8 deleted. It makes eleven bytes.
    fn mapped() -> ChangeSet {
        set(&[
            Change::Retain(2),
            insert("XY"),
            Change::Retain(2),
            insert("PQR"),
            Change::Delete(2),
            Change::Retain(1),
            Change::Delete(2),
            Change::Retain(1),
        ])
    }

    /// Where `changes` maps `offset` to, with each bias: before, then after.
    fn both(changes: &ChangeSet, offset: usize) -> (Option<usize>, Option<usize>) {
        (
            changes.map(offset, Bias::Before),
            changes.map(offset, Bias::After),
        )
    }

    #[test]
    fn a_position_in_retained_text_moves_with_the_text() {
        let changes = mapped();

        assert_eq!(both(&changes, 0), (Some(0), Some(0)));
        assert_eq!(both(&changes, 1), (Some(1), Some(1)));
        assert_eq!(both(&changes, 3), (Some(5), Some(5)));
        assert_eq!(both(&changes, 10), (Some(11), Some(11)));
    }

    #[test]
    fn a_position_where_text_is_inserted_stays_before_it_or_goes_after_it_by_its_bias() {
        assert_eq!(both(&mapped(), 2), (Some(2), Some(4)));

        // At the start and at the end of the text.
        let ends = set(&[insert("A"), Change::Retain(3), insert("BC")]);
        assert_eq!(both(&ends, 0), (Some(0), Some(1)));
        assert_eq!(both(&ends, 3), (Some(4), Some(6)));
    }

    #[test]
    fn a_position_at_the_start_of_or_inside_a_replaced_range_goes_to_an_end_of_the_replacement() {
        let changes = mapped();

        assert_eq!(both(&changes, 4), (Some(6), Some(9)));
        assert_eq!(both(&changes, 5), (Some(6), Some(9)));
    }

    #[test]
    fn a_position_at_the_start_of_or_inside_a_deleted_range_goes_where_the_range_collapsed() {
        let changes = mapped();

        assert_eq!(both(&changes, 7), (Some(10), Some(10)));
        assert_eq!(both(&changes, 8), (Some(10), Some(10)));
    }

    #[test]
    fn a_position_at_the_end_of_a_deleted_or_replaced_range_goes_after_the_replacement() {
        let changes = mapped();

        assert_eq!(both(&changes, 6), (Some(9), Some(9)));
        assert_eq!(both(&changes, 9), (Some(10), Some(10)));

        // A range replaced, and one deleted, at the end of the text.
        let replaced = set(&[Change::Retain(1), insert("xyz"), Change::Delete(2)]);
        assert_eq!(both(&replaced, 3), (Some(4), Some(4)));
        let deleted = set(&[Change::Retain(1), Change::Delete(2)]);
        assert_eq!(both(&deleted, 3), (Some(1), Some(1)));
    }

    #[test]
    fn an_offset_past_the_length_the_change_set_is_for_maps_to_nothing() {
        assert_eq!(both(&mapped(), 11), (None, None));
        assert_eq!(both(&mapped(), usize::MAX), (None, None));
        assert_eq!(both(&ChangeSet::new(), 0), (Some(0), Some(0)));
        assert_eq!(both(&ChangeSet::new(), 1), (None, None));
    }

    #[test]
    fn mapping_through_a_composition_is_not_always_mapping_through_each_in_turn() {
        // On "abc": "ab" is deleted, then "Y" is inserted where it was.
        let first = set(&[Change::Delete(2), Change::Retain(1)]);
        let then = set(&[insert("Y"), Change::Retain(1)]);
        let composed = first.compose(&then).expect("the lengths agree");

        // The end of the deleted range collapses to 0, which is then before
        // the insertion; in the composition it is the end of a replaced
        // range, which is after the replacement.
        let through_first = first.map(2, Bias::Before).expect("within the length");
        assert_eq!(then.map(through_first, Bias::Before), Some(0));
        assert_eq!(composed.map(2, Bias::Before), Some(1));
    }

    #[test]
    fn mapping_through_a_change_set_whose_lengths_saturated_does_not_panic() {
        let changes = set(&[
            Change::Retain(usize::MAX),
            insert("x"),
            Change::Delete(usize::MAX),
            Change::Retain(usize::MAX),
        ]);

        assert!(changes.map(usize::MAX, Bias::After).is_some());
        assert!(changes.map(usize::MAX - 1, Bias::Before).is_some());
    }

    /// Where a mapper through [`mapped`] maps each of `asked`, in that
    /// order.
    fn mapped_in_one_pass(asked: &[(usize, Bias)]) -> Vec<Option<usize>> {
        let changes = mapped();
        let mut mapper = changes.mapper();
        asked
            .iter()
            .map(|&(offset, bias)| mapper.map(offset, bias))
            .collect()
    }

    #[test]
    fn a_mapper_asked_in_rising_order_maps_each_offset_as_the_change_set_does() {
        let asked: Vec<_> = (0..=10).map(|offset| (offset, Bias::Before)).collect();
        assert_eq!(
            mapped_in_one_pass(&asked),
            [0, 1, 2, 5, 6, 6, 9, 10, 10, 10, 11].map(Some)
        );

        let asked: Vec<_> = (0..=10).map(|offset| (offset, Bias::After)).collect();
        assert_eq!(
            mapped_in_one_pass(&asked),
            [0, 1, 4, 5, 9, 9, 9, 10, 10, 10, 11].map(Some)
        );
    }

    #[test]
    fn a_mapper_asked_a_lower_offset_than_the_last_starts_again() {
        let asked = [
            (10, Bias::Before),
            (2, Bias::After),
            (5, Bias::Before),
            (4, Bias::After),
            (0, Bias::Before),
            (9, Bias::After),
        ];

        assert_eq!(mapped_in_one_pass(&asked), [11, 4, 6, 9, 0, 10].map(Some));
    }

    #[test]
    fn a_mapper_asked_in_rising_order_walks_the_change_set_once() {
        // A hundred replacements, three bytes apart: three hundred changes.
        let changes = built(|changes| {
            for _ in 0..100 {
                changes.retain(2);
                changes.delete(1);
                changes.insert("xy");
            }
        });
        // Every offset, with each bias, in rising order.
        let asked: Vec<_> = (0..=changes.len_before())
            .flat_map(|offset| [(offset, Bias::Before), (offset, Bias::After)])
            .collect();

        let (answers, looks) = steps::during(|| {
            let mut mapper = changes.mapper();
            asked
                .iter()
                .map(|&(offset, bias)| mapper.map(offset, bias))
                .collect::<Vec<_>>()
        });

        let one_by_one: Vec<_> = asked
            .iter()
            .map(|&(offset, bias)| changes.map(offset, bias))
            .collect();
        assert_eq!(answers, one_by_one);
        // One look where each answer is found, and one at each change
        // passed, which is passed once. A walk begun again for each offset
        // would take tens of thousands.
        let bound = asked.len() + changes.changes().len();
        assert!(looks <= bound, "{looks} looks, and the bound is {bound}");
    }

    #[test]
    fn a_mapper_asked_twice_at_one_offset_answers_each_bias() {
        let asked = [
            (2, Bias::Before),
            (2, Bias::After),
            (2, Bias::Before),
            // Past the insertion at 2, and back to it.
            (3, Bias::Before),
            (2, Bias::After),
            (4, Bias::After),
            (4, Bias::Before),
            (5, Bias::After),
            (5, Bias::Before),
        ];

        assert_eq!(
            mapped_in_one_pass(&asked),
            [2, 4, 2, 5, 4, 9, 6, 9, 6].map(Some)
        );
    }

    #[test]
    fn a_mapper_asked_past_the_length_answers_nothing_and_keeps_its_place() {
        let asked = [
            (3, Bias::Before),
            (11, Bias::Before),
            (usize::MAX, Bias::After),
            (3, Bias::Before),
            (10, Bias::After),
        ];

        assert_eq!(
            mapped_in_one_pass(&asked),
            [Some(5), None, None, Some(5), Some(11)]
        );
        assert_eq!(ChangeSet::new().mapper().map(0, Bias::After), Some(0));
        assert_eq!(ChangeSet::new().mapper().map(1, Bias::After), None);
    }

    #[test]
    fn a_mapper_through_a_change_set_whose_lengths_saturated_does_not_panic() {
        let changes = set(&[
            Change::Retain(usize::MAX),
            insert("x"),
            Change::Delete(usize::MAX),
            Change::Retain(usize::MAX),
        ]);
        let mut mapper = changes.mapper();

        assert!(mapper.map(usize::MAX - 1, Bias::Before).is_some());
        assert!(mapper.map(usize::MAX, Bias::After).is_some());
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
