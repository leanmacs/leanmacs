//! The edit log: what was done to a text, one entry for each transaction
//! it accepted.

use std::borrow::Cow;
use std::collections::VecDeque;
use std::error::Error;
use std::fmt;
use std::ops::Range;

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
        let first = self.index_after(since).ok_or(LogError::Forgotten)?;
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

    /// The index of the entry of the revision after `revision`, which is
    /// one past the last when `revision` is the newest the log has an
    /// entry for, or later. `None` for a revision before the horizon.
    fn index_after(&self, revision: Revision) -> Option<usize> {
        let after_horizon = revision.get().checked_sub(self.horizon.get())?;
        let index = usize::try_from(after_horizon).unwrap_or(usize::MAX);
        Some(index.min(self.entries.len()))
    }

    /// Drops the entries of the revisions up to and including `through`,
    /// and moves the horizon there. A revision at or before the horizon
    /// changes nothing. `current` is the text's revision; a later one is
    /// [`LogError::Unknown`].
    pub(crate) fn forget(&mut self, through: Revision, current: Revision) -> Result<(), LogError> {
        if through > current {
            return Err(LogError::Unknown);
        }
        if let Some(dropped) = self.index_after(through).filter(|&dropped| dropped > 0) {
            self.entries.drain(..dropped);
            self.horizon = through;
        }
        Ok(())
    }

    /// Where the bytes of `range`, a range of the text as it is now, came
    /// from: the range cut into pieces, in order, each with the entry that
    /// inserted its bytes, or as earlier than the log reaches. Neighbours
    /// with one source are one piece.
    ///
    /// The log is walked from its newest entry back, carrying the pieces
    /// no entry has claimed yet in the coordinates of the text before the
    /// entry being looked at. So the cost is the entries walked times the
    /// pieces carried, and nothing is kept beside the text for it.
    pub(crate) fn trace(&self, range: Range<usize>) -> Vec<Attribution> {
        let mut found = Vec::new();
        // The pieces not yet claimed: each as a range of the text after the
        // entry about to be looked at, and where it starts in the text now.
        let mut unclaimed = Vec::new();
        if !range.is_empty() {
            unclaimed.push((range.clone(), range.start));
        }
        let mut revision = self.horizon.get().wrapping_add(self.entries.len() as u64);
        for entry in self.entries.iter().rev() {
            if unclaimed.is_empty() {
                break;
            }
            let source = Source::Entry {
                revision: Revision(revision),
                origin: entry.origin,
            };
            let mut before = Vec::with_capacity(unclaimed.len());
            for (piece, now) in unclaimed {
                entry.claim(piece, now, source, &mut found, &mut before);
            }
            unclaimed = before;
            revision = revision.wrapping_sub(1);
        }
        let earlier = Source::Earlier(self.horizon);
        found.extend(unclaimed.into_iter().map(|(piece, now)| Attribution {
            range: now..now + piece.len(),
            source: earlier,
        }));
        found.sort_unstable_by_key(|piece| piece.range.start);
        // Neighbours with one source are one piece.
        let mut merged: Vec<Attribution> = Vec::with_capacity(found.len());
        for piece in found {
            match merged.last_mut() {
                Some(last)
                    if last.source == piece.source && last.range.end == piece.range.start =>
                {
                    last.range.end = piece.range.end;
                }
                _ => merged.push(piece),
            }
        }
        merged
    }
}

impl Entry {
    /// Splits `piece`, a range of the text after this entry's transaction
    /// that starts at the offset `now` of the text as it is now. The parts
    /// inside an edit's new span were inserted by the transaction: they go
    /// to `claimed`, as ranges of the text now, with `source`. The rest
    /// was there before: it goes to `before`, as ranges of the text before
    /// the transaction.
    fn claim(
        &self,
        piece: Range<usize>,
        now: usize,
        source: Source,
        claimed: &mut Vec<Attribution>,
        before: &mut Vec<(Range<usize>, usize)>,
    ) {
        // The edits that end at or before the piece only shift it.
        let passed = self
            .edits
            .partition_point(|edit| edit.new.end <= piece.start);
        // Where the two texts last lined up: just after the last edit
        // passed. Text from there to the next edit is in both.
        let (mut new_kept, mut old_kept) = match passed.checked_sub(1).map(|last| &self.edits[last])
        {
            Some(last) => (last.new.end, last.old.end),
            None => (0, 0),
        };
        // Where the walk is, in the text after and in the text now.
        let (mut at, mut now) = (piece.start, now);
        for edit in &self.edits[passed..] {
            if edit.new.start >= piece.end {
                break;
            }
            // What is before the edit was there before the transaction.
            if edit.new.start > at {
                let kept = at - new_kept + old_kept..edit.new.start - new_kept + old_kept;
                before.push((kept, now));
                now += edit.new.start - at;
                at = edit.new.start;
            }
            // What is inside the edit's new span the transaction inserted.
            let inside = edit.new.end.min(piece.end);
            if inside > at {
                claimed.push(Attribution {
                    range: now..now + (inside - at),
                    source,
                });
                now += inside - at;
                at = inside;
            }
            (new_kept, old_kept) = (edit.new.end, edit.old.end);
        }
        if piece.end > at {
            let kept = at - new_kept + old_kept..piece.end - new_kept + old_kept;
            before.push((kept, now));
        }
    }
}

/// Why the log could not answer for a revision.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogError {
    /// The text has not reached the revision.
    Unknown,
    /// The revision is before the log's horizon: the entries that led from
    /// it were dropped ([`Text::forget`](crate::Text::forget)).
    Forgotten,
}

impl fmt::Display for LogError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Unknown => "the text has not reached the revision",
            Self::Forgotten => "the log no longer reaches back to the revision",
        })
    }
}

/// Where a piece of a text came from ([`Text::trace`](crate::Text::trace)).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Source {
    /// A transaction the log holds inserted the bytes.
    Entry {
        /// The revision the transaction produced.
        revision: Revision,
        /// The origin the transaction was applied with.
        origin: Origin,
    },
    /// The bytes were already in the text at this revision, which is as far
    /// back as the log reaches: its horizon. For a log that is whole that
    /// is revision 0, the text as it was made.
    Earlier(Revision),
}

/// One piece of a traced range, and where its bytes came from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attribution {
    /// The bytes, as a range of the text as it is now.
    pub range: Range<usize>,
    /// Where they came from.
    pub source: Source,
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

    /// A piece `range` written by the transaction that produced `revision`,
    /// applied with the origin `origin`.
    fn written(range: Range<usize>, revision: u64, origin: u64) -> Attribution {
        Attribution {
            range,
            source: Source::Entry {
                revision: Revision(revision),
                origin: Origin::new(origin),
            },
        }
    }

    /// A piece `range` that was in the text at `revision`, where the log
    /// starts.
    fn earlier(range: Range<usize>, revision: u64) -> Attribution {
        Attribution {
            range,
            source: Source::Earlier(Revision(revision)),
        }
    }

    /// Applies `changes` to `text` with the origin `origin`.
    fn apply(text: &mut Text, changes: &[Change], origin: u64) {
        let transaction = Transaction::new(changes.iter().cloned().collect());
        text.apply(&transaction, Origin::new(origin))
            .expect("it fits");
    }

    #[test]
    fn a_trace_names_the_revision_and_the_origin_that_wrote_each_piece() {
        // "\nhXYllo\nwörld!"
        let text = changed_four_times();

        assert_eq!(
            text.trace(0..15),
            Some(vec![
                // The line feed of the "A\n" that `replace` inserted. The
                // "A" was deleted, and is in no piece.
                written(0..1, 1, 0),
                earlier(1..2, 0),
                written(2..4, 2, 7),
                earlier(4..14, 0),
                written(14..15, 3, 9),
            ])
        );
    }

    #[test]
    fn a_trace_of_part_of_the_text_is_cut_to_the_range() {
        let text = changed_four_times();

        assert_eq!(
            text.trace(3..9),
            Some(vec![written(3..4, 2, 7), earlier(4..9, 0)])
        );
        assert_eq!(text.trace(5..7), Some(vec![earlier(5..7, 0)]));
        assert_eq!(text.trace(14..15), Some(vec![written(14..15, 3, 9)]));
    }

    #[test]
    fn a_piece_inside_a_replacement_of_a_replacement_is_the_later_entrys() {
        let mut text = Text::from("abcdef");
        // "aWXYZef", then "aWqZef".
        apply(
            &mut text,
            &[
                Change::Retain(1),
                insert("WXYZ"),
                Change::Delete(3),
                Change::Retain(2),
            ],
            1,
        );
        apply(
            &mut text,
            &[
                Change::Retain(2),
                insert("q"),
                Change::Delete(2),
                Change::Retain(3),
            ],
            2,
        );

        assert_eq!(
            text.trace(0..6),
            Some(vec![
                earlier(0..1, 0),
                written(1..2, 1, 1),
                written(2..3, 2, 2),
                written(3..4, 1, 1),
                earlier(4..6, 0),
            ])
        );
    }

    #[test]
    fn neighbouring_pieces_with_one_source_are_one_piece() {
        let mut text = Text::from("abc");
        // "aXbYc": two inserts of one transaction, with "b" between them.
        apply(
            &mut text,
            &[
                Change::Retain(1),
                insert("X"),
                Change::Retain(1),
                insert("Y"),
                Change::Retain(1),
            ],
            5,
        );
        assert_eq!(
            text.trace(0..5),
            Some(vec![
                earlier(0..1, 0),
                written(1..2, 1, 5),
                earlier(2..3, 0),
                written(3..4, 1, 5),
                earlier(4..5, 0),
            ])
        );

        // "aXYc": the two now touch.
        apply(
            &mut text,
            &[Change::Retain(2), Change::Delete(1), Change::Retain(2)],
            6,
        );
        assert_eq!(
            text.trace(0..4),
            Some(vec![
                earlier(0..1, 0),
                written(1..3, 1, 5),
                earlier(3..4, 0)
            ])
        );

        // "ac": so do the two pieces the text was made with.
        apply(
            &mut text,
            &[Change::Retain(1), Change::Delete(2), Change::Retain(1)],
            6,
        );
        assert_eq!(text.trace(0..2), Some(vec![earlier(0..2, 0)]));
    }

    #[test]
    fn pieces_two_transactions_wrote_with_one_origin_stay_two() {
        let mut text = Text::from("abc");
        apply(&mut text, &[insert("X"), Change::Retain(3)], 5);
        apply(
            &mut text,
            &[Change::Retain(1), insert("Y"), Change::Retain(3)],
            5,
        );

        assert_eq!(
            text.trace(0..5),
            Some(vec![
                written(0..1, 1, 5),
                written(1..2, 2, 5),
                earlier(2..5, 0)
            ])
        );
    }

    #[test]
    fn an_empty_range_traces_to_nothing() {
        let text = changed_four_times();

        assert_eq!(text.trace(0..0), Some(Vec::new()));
        assert_eq!(text.trace(3..3), Some(Vec::new()));
        assert_eq!(text.trace(15..15), Some(Vec::new()));
        assert_eq!(Text::new().trace(0..0), Some(Vec::new()));
    }

    // The range is the point of the test: it is one a caller can pass.
    #[expect(clippy::reversed_empty_ranges)]
    #[test]
    fn a_range_that_is_not_two_positions_in_order_has_no_trace() {
        // "\nhXYllo\nwörld!": "ö" is the bytes 9 and 10.
        let text = changed_four_times();

        assert_eq!(text.trace(4..2), None);
        assert_eq!(text.trace(0..10), None);
        assert_eq!(text.trace(10..15), None);
        assert_eq!(text.trace(0..16), None);
        assert_eq!(text.trace(16..16), None);
        assert_eq!(text.trace(usize::MAX..usize::MAX), None);
    }

    #[test]
    fn forgetting_drops_the_entries_up_to_a_revision_and_moves_the_horizon_there() {
        let mut text = changed_four_times();

        assert_eq!(text.forget(Revision(2)), Ok(()));

        assert_eq!(text.horizon(), Revision(2));
        assert!(text.entry(Revision(1)).is_none());
        assert!(text.entry(Revision(2)).is_none());
        let third = text.entry(Revision(3)).expect("an entry after the horizon");
        assert_eq!(third.revision(), Revision(3));
        assert_eq!(third.origin(), Origin::new(9));
        assert_eq!(
            third.edits(),
            [Edit {
                old: span(15, 15, (2, 6), (2, 6)),
                new: span(15, 16, (2, 6), (2, 7)),
            }]
        );
        assert!(text.entry(Revision(4)).is_some());
        // The text is as it was.
        assert_eq!(text.current().to_string(), "\nhXYllo\nwörld!");
        assert_eq!(text.current().revision(), Revision(4));
    }

    #[test]
    fn what_changed_since_a_revision_before_the_horizon_is_forgotten() {
        let mut text = changed_four_times();
        let since_two = text.changes_since(Revision(2));
        let since_three = text.changes_since(Revision(3));
        text.forget(Revision(2)).expect("a revision reached");

        assert_eq!(text.changes_since(Revision(0)), Err(LogError::Forgotten));
        assert_eq!(text.changes_since(Revision(1)), Err(LogError::Forgotten));
        // From the horizon on, the answers are what they were.
        assert!(since_two.is_ok());
        assert_eq!(text.changes_since(Revision(2)), since_two);
        assert_eq!(text.changes_since(Revision(3)), since_three);
        assert_eq!(text.changes_since(Revision(5)), Err(LogError::Unknown));
    }

    #[test]
    fn a_subscriber_behind_the_horizon_is_refused_and_stays_where_it_was() {
        let mut text = Text::from("héllo");
        let mut behind = text.subscribe();
        text.replace(0..0, "x").expect("an insert at the start");
        let mut at_the_horizon = text.subscribe();
        text.replace(0..0, "y").expect("an insert at the start");
        text.forget(Revision(1)).expect("a revision reached");

        assert_eq!(text.pull(&mut behind), Err(LogError::Forgotten));
        assert_eq!(behind.revision(), Revision(0));
        let patch = text.pull(&mut at_the_horizon).expect("not forgotten");
        assert_eq!((patch.from, patch.to), (Revision(1), Revision(2)));
        assert_eq!(at_the_horizon.revision(), Revision(2));
    }

    #[test]
    fn bytes_written_at_or_before_the_horizon_trace_to_earlier_than_the_horizon() {
        let mut text = changed_four_times();
        text.forget(Revision(2)).expect("a revision reached");

        // The line feed revision 1 wrote, the "XY" revision 2 wrote and the
        // bytes the text was made with are one piece now.
        assert_eq!(
            text.trace(0..15),
            Some(vec![earlier(0..14, 2), written(14..15, 3, 9)])
        );
    }

    #[test]
    fn forgetting_a_revision_the_text_has_not_reached_is_unknown_and_changes_nothing() {
        let mut text = changed_four_times();

        assert_eq!(text.forget(Revision(5)), Err(LogError::Unknown));
        assert_eq!(text.forget(Revision(u64::MAX)), Err(LogError::Unknown));

        assert_eq!(text.horizon(), Revision(0));
        assert!(text.entry(Revision(1)).is_some());
    }

    #[test]
    fn forgetting_at_or_below_the_horizon_changes_nothing() {
        let mut text = changed_four_times();
        assert_eq!(text.forget(Revision(0)), Ok(()));
        assert_eq!(text.horizon(), Revision(0));
        assert!(text.entry(Revision(1)).is_some());
        text.forget(Revision(2)).expect("a revision reached");

        assert_eq!(text.forget(Revision(2)), Ok(()));
        assert_eq!(text.forget(Revision(1)), Ok(()));
        assert_eq!(text.forget(Revision(0)), Ok(()));

        assert_eq!(text.horizon(), Revision(2));
        assert!(text.entry(Revision(3)).is_some());
        assert!(text.changes_since(Revision(2)).is_ok());
    }

    #[test]
    fn a_log_forgotten_whole_goes_on_recording() {
        let mut text = changed_four_times();
        text.forget(Revision(4)).expect("the current revision");

        assert_eq!(text.horizon(), Revision(4));
        assert_eq!(
            text.changes_since(Revision(4)),
            Ok(Patch {
                from: Revision(4),
                to: Revision(4),
                edits: Vec::new(),
            })
        );
        assert_eq!(text.trace(0..15), Some(vec![earlier(0..15, 4)]));

        apply(&mut text, &[insert("z"), Change::Retain(15)], 3);

        let entry = text.entry(Revision(5)).expect("the new entry");
        assert_eq!(entry.origin(), Origin::new(3));
        let patch = text.changes_since(Revision(4)).expect("the horizon");
        assert_eq!(patch.edits, entry.edits());
        assert_eq!(
            text.trace(0..16),
            Some(vec![written(0..1, 5, 3), earlier(1..16, 4)])
        );
        assert_eq!(text.changes_since(Revision(3)), Err(LogError::Forgotten));
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
