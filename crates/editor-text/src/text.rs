//! A text: the one writer.

use std::error::Error;
use std::fmt;
use std::ops::Range;

use crate::change::ChangeSet;
use crate::log::{Log, LogEntry, LogError, Origin, Subscription};
use crate::patch::{Edit, Patch, Span};
use crate::rope::Rope;
use crate::snapshot::{Revision, Snapshot};
use crate::transaction::{ApplyError, Transaction};

/// Text that can be edited.
#[derive(Default)]
pub struct Text {
    /// The text as it is now.
    current: Snapshot,
    /// What was done to the text to make it what it is now.
    log: Log,
}

/// Why an edit was refused: its range is not two positions of the text in
/// order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BadRange;

impl fmt::Display for BadRange {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("the range is not two positions of the text in order")
    }
}

impl Error for BadRange {}

impl Text {
    /// An empty text.
    pub fn new() -> Self {
        Self::default()
    }

    /// The text as it is now, borrowed: a read that keeps nothing.
    pub fn current(&self) -> &Snapshot {
        &self.current
    }

    /// The text as it is now, to keep: later edits do not change what the
    /// snapshot holds. It shares the text with this one and copies none of
    /// it, so it costs the same whatever the text's length.
    pub fn snapshot(&self) -> Snapshot {
        self.current.clone()
    }

    /// Replaces the bytes of `range` with `text`. An empty range inserts,
    /// and an empty `text` deletes. An accepted edit adds one to the
    /// revision, one that changes nothing included.
    ///
    /// Refused, changing nothing, unless both ends of the range are
    /// positions of the text and the start is not after the end. The range
    /// is checked before the text is touched, so an edit is all or nothing.
    ///
    /// This is [`apply`](Self::apply) of the transaction with that one
    /// change and no selection, with the default [`Origin`]: it is in the
    /// log like any other. An edit that wants an origin is applied as a
    /// transaction.
    pub fn replace(&mut self, range: Range<usize>, text: &str) -> Result<(), BadRange> {
        // The ends are checked here, and not left to the transaction: when
        // nothing is deleted and nothing inserted the change set is the
        // identity, which has no boundary at the range for it to refuse.
        // `is_char_boundary` is false past the end.
        let rope = &self.current.rope;
        if !rope.is_char_boundary(range.start) || !rope.is_char_boundary(range.end) {
            return Err(BadRange);
        }
        let changes = ChangeSet::replacing(self.current.len(), range, text).ok_or(BadRange)?;
        match self.apply(&Transaction::new(changes), Origin::default()) {
            Ok(_) => Ok(()),
            Err(_) => Err(BadRange),
        }
    }

    /// Applies `transaction`, recording `origin` as who made the edit, and
    /// returns the revision it produced. This is the one way a text
    /// changes.
    ///
    /// An accepted transaction adds one to the revision, however many
    /// changes it has, one that changes nothing included.
    ///
    /// A refused transaction changes nothing: the text, its revision and
    /// its log are as they were. The checks are made in this order:
    ///
    /// 1. the change set fits the text, or it is [`ApplyError::BadChange`]:
    ///    it is for the text's length, and every boundary between two of
    ///    its changes is a position;
    /// 2. every end of the selection before, if there is one, is a position
    ///    of the text as it is, or it is [`ApplyError::BadSelection`];
    /// 3. every end of the selection after, if there is one, is a position
    ///    of the text the changes make, or it is
    ///    [`ApplyError::BadSelection`].
    pub fn apply(
        &mut self,
        transaction: &Transaction,
        origin: Origin,
    ) -> Result<Revision, ApplyError> {
        let changes = transaction.changes();
        if !changes.fits(&self.current.rope) {
            return Err(ApplyError::BadChange);
        }
        if transaction
            .before()
            .is_some_and(|selection| !selection.fits(&self.current))
        {
            return Err(ApplyError::BadSelection);
        }
        // The changes are made to a clone, which shares the text's nodes and
        // copies only those it changes. It takes the text's place once
        // everything is accepted, so a refusal has nothing to undo.
        let mut next = Snapshot {
            rope: self.current.rope.clone(),
            revision: self.current.revision.next(),
        };
        if !changes.apply_to(&mut next.rope) {
            return Err(ApplyError::BadChange);
        }
        if transaction
            .after()
            .is_some_and(|selection| !selection.fits(&next))
        {
            return Err(ApplyError::BadSelection);
        }
        // The old points are read from the text as it is and the new ones
        // from the clone. Every end is a boundary between two changes, which
        // the fit made a position, so no span is expected to be missing.
        let mut edits = Vec::with_capacity(changes.runs().count());
        for (old, new) in changes.runs() {
            let (Some(old), Some(new)) = (Span::of(&self.current, old), Span::of(&next, new))
            else {
                return Err(ApplyError::BadChange);
            };
            edits.push(Edit { old, new });
        }
        self.log.record(origin, edits.into_boxed_slice());
        self.current = next;
        Ok(self.current.revision)
    }

    /// The log's entry for the transaction that produced `revision`: who
    /// applied it. `None` for revision 0, which no transaction produced,
    /// and for a revision the text has not reached.
    pub fn entry(&self, revision: Revision) -> Option<LogEntry<'_>> {
        self.log.entry(revision)
    }

    /// The revision the log reaches back to: the log holds the entry of
    /// every later revision, and none for this one or an earlier one. 0
    /// for a log that is whole.
    pub fn horizon(&self) -> Revision {
        self.log.horizon()
    }

    /// What changed in the text since the revision `since`, as one patch:
    /// however many transactions were applied, their changes are coalesced
    /// into one set of edits whose old spans are ranges of the text at
    /// `since` and whose new spans are ranges of the text now. Empty when
    /// `since` is the current revision.
    ///
    /// [`LogError::Unknown`] for a revision the text has not reached.
    pub fn changes_since(&self, since: Revision) -> Result<Patch, LogError> {
        self.log.changes_since(since, self.current.revision)
    }

    /// A subscription that has seen the text as it is now.
    pub fn subscribe(&self) -> Subscription {
        Subscription {
            seen: self.current.revision,
        }
    }

    /// What changed since `subscription` last looked
    /// ([`changes_since`](Self::changes_since) of its revision), and moves
    /// it to now. A subscription that is refused stays where it was.
    pub fn pull(&self, subscription: &mut Subscription) -> Result<Patch, LogError> {
        let patch = self.changes_since(subscription.seen)?;
        subscription.seen = patch.to;
        Ok(patch)
    }
}

impl From<&str> for Text {
    fn from(text: &str) -> Self {
        Self {
            current: Snapshot {
                rope: Rope::from_str(text),
                revision: Revision::default(),
            },
            log: Log::default(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::change::Change;
    use crate::selection::{Selection, SelectionRange};
    use crate::snapshot::Revision;

    /// "é" and "ö" are two bytes each, so byte offsets and character counts
    /// differ from the second character on: in "héllo" the offsets 0, 1, 3,
    /// 4, 5 and 6 are character boundaries, and 2 is inside "é".
    const TEXT: &str = "héllo wörld";

    /// Two lines, with characters of one to four bytes and a line ending of
    /// each kind.
    const LINES: &str = "héllo wörld\n😀 a line that ends in a carriage return and a line feed\r\n";

    /// A text long enough that the rope holds it in many pieces: a few
    /// hundred kilobytes of [`LINES`].
    fn long_text() -> String {
        LINES.repeat(4_000)
    }

    #[test]
    fn a_text_reads_back_the_string_it_was_made_from() {
        for text in [TEXT, "", "a\0b", "😀", "\r\n", &long_text()] {
            assert_eq!(Text::from(text).current().to_string(), text);
        }
    }

    #[test]
    fn a_new_text_is_empty() {
        let text = Text::new();

        assert_eq!(text.current().to_string(), "");
        assert_eq!(text.current().len(), 0);
        assert!(text.current().is_empty());
    }

    #[test]
    fn the_length_of_a_text_is_in_bytes() {
        assert_eq!(Text::from(TEXT).current().len(), 13);
        assert_eq!(Text::from("😀").current().len(), 4);
        assert!(!Text::from(TEXT).current().is_empty());
        assert_eq!(
            Text::from(long_text().as_str()).current().len(),
            long_text().len()
        );
    }

    #[test]
    fn a_character_boundary_is_an_offset_within_the_text_that_is_not_inside_a_character() {
        let text = Text::from("héllo");
        let snapshot = text.current();

        for boundary in [0, 1, 3, 4, 5, 6] {
            assert!(snapshot.is_char_boundary(boundary), "{boundary}");
        }
        assert!(!snapshot.is_char_boundary(2));
        assert!(!snapshot.is_char_boundary(7));
        assert!(!snapshot.is_char_boundary(usize::MAX));
        assert!(Text::new().current().is_char_boundary(0));
        assert!(!Text::new().current().is_char_boundary(1));
    }

    #[test]
    fn the_character_boundaries_of_a_long_text_are_those_of_its_string() {
        let string = long_text();
        let text = Text::from(string.as_str());

        for offset in (0..=string.len() + 2).step_by(7) {
            assert_eq!(
                text.current().is_char_boundary(offset),
                string.is_char_boundary(offset),
                "{offset}"
            );
        }
    }

    /// What `text` holds now.
    fn read(text: &Text) -> String {
        text.current().to_string()
    }

    #[test]
    fn replace_inserts_at_a_byte_offset_when_the_range_is_empty() {
        let mut text = Text::from(TEXT);

        assert_eq!(text.replace(3..3, "XY"), Ok(()));
        assert_eq!(read(&text), "héXYllo wörld");
        assert_eq!(text.replace(0..0, "<"), Ok(()));
        assert_eq!(read(&text), "<héXYllo wörld");
        assert_eq!(text.replace(16..16, ">"), Ok(()));
        assert_eq!(read(&text), "<héXYllo wörld>");
    }

    #[test]
    fn replace_deletes_its_byte_range_when_the_text_is_empty() {
        let mut text = Text::from(TEXT);

        assert_eq!(text.replace(1..3, ""), Ok(()));
        assert_eq!(read(&text), "hllo wörld");
        assert_eq!(text.replace(5..11, ""), Ok(()));
        assert_eq!(read(&text), "hllo ");
    }

    #[test]
    fn replace_puts_the_text_in_place_of_its_byte_range() {
        let mut text = Text::from(TEXT);

        assert_eq!(text.replace(7..13, "there"), Ok(()));
        assert_eq!(read(&text), "héllo there");
    }

    #[test]
    fn replace_refuses_an_offset_inside_a_character_and_changes_nothing() {
        let mut text = Text::from(TEXT);

        assert_eq!(text.replace(2..2, "x"), Err(BadRange));
        assert_eq!(text.replace(0..2, ""), Err(BadRange));
        assert_eq!(text.replace(2..3, ""), Err(BadRange));
        assert_eq!(read(&text), TEXT);
    }

    #[test]
    fn replace_refuses_an_offset_past_the_end_and_changes_nothing() {
        let mut text = Text::from(TEXT);

        assert_eq!(
            text.replace(TEXT.len() + 1..TEXT.len() + 1, "x"),
            Err(BadRange)
        );
        assert_eq!(text.replace(0..TEXT.len() + 1, ""), Err(BadRange));
        assert_eq!(text.replace(usize::MAX..usize::MAX, "x"), Err(BadRange));
        assert_eq!(read(&text), TEXT);
    }

    // The range is the point of the test: it is one a caller can pass.
    #[expect(clippy::reversed_empty_ranges)]
    #[test]
    fn replace_refuses_a_backwards_range_and_changes_nothing() {
        let mut text = Text::from(TEXT);

        assert_eq!(text.replace(3..1, "x"), Err(BadRange));
        assert_eq!(read(&text), TEXT);
    }

    #[test]
    fn replace_edits_a_text_held_in_many_pieces() {
        let mut string = long_text();
        let mut text = Text::from(string.as_str());
        let middle = LINES.len() * 2_000;
        let end = middle + LINES.len() * 40;

        assert_eq!(text.replace(middle..end, "😀\r\n"), Ok(()));
        string.replace_range(middle..end, "😀\r\n");
        assert_eq!(read(&text), string);
        assert_eq!(text.replace(middle + 1..middle + 1, "x"), Err(BadRange));
        assert_eq!(read(&text), string);
    }

    #[test]
    fn a_new_text_is_at_revision_zero() {
        assert_eq!(Text::new().current().revision(), Revision::default());
        assert_eq!(Text::from(TEXT).current().revision().get(), 0);
    }

    #[test]
    fn every_accepted_edit_adds_one_to_the_revision_one_that_changes_nothing_included() {
        let mut text = Text::from(TEXT);

        text.replace(3..3, "XY").expect("an insert at a boundary");
        assert_eq!(text.current().revision().get(), 1);
        text.replace(0..1, "").expect("a delete between boundaries");
        assert_eq!(text.current().revision().get(), 2);
        text.replace(0..0, "")
            .expect("an edit that changes nothing");
        assert_eq!(text.current().revision().get(), 3);
    }

    #[test]
    fn a_refused_edit_adds_nothing_to_the_revision() {
        let mut text = Text::from(TEXT);
        text.replace(0..0, "x").expect("an insert at the start");

        assert_eq!(text.replace(3..3, "x"), Err(BadRange));
        assert_eq!(text.replace(0..99, ""), Err(BadRange));
        assert_eq!(text.current().revision().get(), 1);
    }

    #[test]
    fn a_later_revision_compares_greater() {
        let mut text = Text::from(TEXT);
        let before = text.current().revision();
        text.replace(0..0, "x").expect("an insert at the start");

        assert!(text.current().revision() > before);
    }

    #[test]
    fn replace_refuses_to_replace_nothing_with_nothing_inside_a_character() {
        let mut text = Text::from(TEXT);

        assert_eq!(text.replace(2..2, ""), Err(BadRange));
        assert_eq!(read(&text), TEXT);
        assert_eq!(text.current().revision().get(), 0);
    }

    /// Rows with characters of one, two and four bytes and both line
    /// endings, in 20 bytes: "é" is the bytes 1 and 2, "ö" 9 and 10, and
    /// "😀" 15 to 18.
    const MIXED: &str = "héllo\r\nwörld\n😀x";

    /// An insert of `text`.
    fn insert(text: &str) -> Change {
        Change::Insert(text.to_owned())
    }

    /// The transaction of `changes`, with no selection.
    fn transaction(changes: &[Change]) -> Transaction {
        Transaction::new(changes.iter().cloned().collect())
    }

    /// A selection of the one range from `anchor` to `head`.
    fn selection(anchor: usize, head: usize) -> Selection {
        Selection::new(vec![SelectionRange::new(anchor, head)], 0).expect("one range")
    }

    /// Changes over [`MIXED`]: "é" becomes "e", "w" becomes "W", and "😀"
    /// goes.
    fn several() -> Transaction {
        transaction(&[
            Change::Retain(1),
            Change::Delete(2),
            insert("e"),
            Change::Retain(5),
            insert("W"),
            Change::Delete(1),
            Change::Retain(6),
            Change::Delete(4),
            Change::Retain(1),
        ])
    }

    /// Applies `transaction` to a text holding [`MIXED`] and checks that it
    /// is refused with `error` and that the text and its revision are as
    /// they were.
    fn assert_refused(transaction: &Transaction, error: ApplyError) {
        let mut text = Text::from(MIXED);

        assert_eq!(
            text.apply(transaction, Origin::new(1)),
            Err(error),
            "{transaction:?}"
        );
        assert_eq!(read(&text), MIXED, "{transaction:?}");
        assert_eq!(text.current().revision().get(), 0, "{transaction:?}");
    }

    #[test]
    fn a_transaction_of_several_changes_is_applied_in_order() {
        let mut text = Text::from(MIXED);

        let result = text.apply(&several(), Origin::new(1));

        assert_eq!(result.map(Revision::get), Ok(1));
        assert_eq!(read(&text), "hello\r\nWörld\nx");
    }

    #[test]
    fn apply_returns_the_revision_it_produced_one_more_for_each_transaction() {
        let mut text = Text::from(MIXED);

        // Several changes are one revision.
        let first = text.apply(&several(), Origin::new(1));
        assert_eq!(first.map(Revision::get), Ok(1));
        assert_eq!(text.current().revision().get(), 1);

        // A transaction that changes nothing is one too.
        let identity = transaction(&[Change::Retain(15)]);
        assert!(identity.changes().is_identity());
        let second = text.apply(&identity, Origin::new(1));
        assert_eq!(second.map(Revision::get), Ok(2));
        assert_eq!(text.current().revision().get(), 2);
        assert_eq!(read(&text), "hello\r\nWörld\nx");

        let third = text.apply(&transaction(&[Change::Delete(15)]), Origin::new(1));
        assert_eq!(third.map(Revision::get), Ok(3));
        assert_eq!(read(&text), "");

        // The change set with no change is the identity for an empty text.
        let fourth = text.apply(&transaction(&[]), Origin::new(1));
        assert_eq!(fourth.map(Revision::get), Ok(4));
        assert_eq!(text.current().revision().get(), 4);
    }

    #[test]
    fn a_change_set_that_stops_short_of_the_text_is_refused_and_changes_nothing() {
        assert_refused(&transaction(&[Change::Retain(19)]), ApplyError::BadChange);
        assert_refused(&transaction(&[]), ApplyError::BadChange);
        assert_refused(
            &transaction(&[insert("x"), Change::Delete(1), Change::Retain(18)]),
            ApplyError::BadChange,
        );
        assert_refused(&transaction(&[insert("x")]), ApplyError::BadChange);
    }

    #[test]
    fn a_change_set_that_runs_past_the_text_is_refused_and_changes_nothing() {
        assert_refused(&transaction(&[Change::Retain(21)]), ApplyError::BadChange);
        assert_refused(
            &transaction(&[insert("x"), Change::Retain(19), Change::Delete(2)]),
            ApplyError::BadChange,
        );
        assert_refused(
            &transaction(&[Change::Retain(usize::MAX)]),
            ApplyError::BadChange,
        );
        assert_refused(
            &transaction(&[Change::Delete(usize::MAX), Change::Retain(usize::MAX)]),
            ApplyError::BadChange,
        );
    }

    #[test]
    fn a_change_set_with_a_boundary_inside_a_character_is_refused_and_changes_nothing() {
        // A retain that ends inside "é", before an insert and before a
        // delete.
        assert_refused(
            &transaction(&[Change::Retain(2), insert("x"), Change::Retain(18)]),
            ApplyError::BadChange,
        );
        assert_refused(
            &transaction(&[Change::Retain(2), Change::Delete(1), Change::Retain(17)]),
            ApplyError::BadChange,
        );
        // A delete that ends inside "é", and one that ends inside "😀".
        assert_refused(
            &transaction(&[Change::Retain(1), Change::Delete(1), Change::Retain(18)]),
            ApplyError::BadChange,
        );
        assert_refused(
            &transaction(&[Change::Retain(15), Change::Delete(2), Change::Retain(3)]),
            ApplyError::BadChange,
        );
        // The changes before the bad boundary fit, and are not made.
        assert_refused(
            &transaction(&[
                insert("H"),
                Change::Delete(1),
                Change::Retain(15),
                Change::Delete(1),
                Change::Retain(3),
            ]),
            ApplyError::BadChange,
        );
    }

    #[test]
    fn a_selection_before_that_is_no_position_of_the_text_before_is_refused() {
        let identity = || transaction(&[Change::Retain(20)]);
        // Inside "é", and past the end.
        assert_refused(
            &identity().with_before(selection(2, 0)),
            ApplyError::BadSelection,
        );
        assert_refused(
            &identity().with_before(selection(0, 21)),
            ApplyError::BadSelection,
        );
        // A position of the text after, and not of the text before: with
        // "é" deleted, 2 is between "h" and "l".
        let without_e = || transaction(&[Change::Retain(1), Change::Delete(2), Change::Retain(17)]);
        assert_refused(
            &without_e().with_before(selection(2, 2)),
            ApplyError::BadSelection,
        );
        // The second range of two.
        let two = Selection::new(
            vec![SelectionRange::new(0, 1), SelectionRange::new(3, 2)],
            0,
        )
        .expect("two ranges");
        assert_refused(&identity().with_before(two), ApplyError::BadSelection);
    }

    #[test]
    fn a_selection_after_that_is_no_position_of_the_text_after_is_refused() {
        // With "h" deleted the text is 19 bytes and "é" is the bytes 0 and
        // 1: 1 and 20 are positions of the text before and not of the text
        // after.
        let without_h = || transaction(&[Change::Delete(1), Change::Retain(19)]);
        assert_refused(
            &without_h().with_after(selection(1, 1)),
            ApplyError::BadSelection,
        );
        assert_refused(
            &without_h().with_after(selection(0, 20)),
            ApplyError::BadSelection,
        );
        assert_refused(
            &without_h()
                .with_before(selection(0, 20))
                .with_after(selection(0, 20)),
            ApplyError::BadSelection,
        );
    }

    #[test]
    fn each_selection_is_checked_against_its_own_text() {
        let mut text = Text::from(MIXED);
        // With "h" deleted: 1 and 20 are positions before, 2 and 19 after.
        let without_h = transaction(&[Change::Delete(1), Change::Retain(19)])
            .with_before(selection(1, 20))
            .with_after(selection(2, 19));

        let result = text.apply(&without_h, Origin::new(1));

        assert_eq!(result.map(Revision::get), Ok(1));
        assert_eq!(read(&text), "éllo\r\nwörld\n😀x");
    }

    #[test]
    fn a_change_set_that_does_not_fit_is_refused_as_that_whatever_its_selections() {
        let short = || transaction(&[Change::Retain(19)]);

        assert_refused(&short().with_before(selection(2, 2)), ApplyError::BadChange);
        assert_refused(
            &short().with_after(selection(99, 99)),
            ApplyError::BadChange,
        );
        assert_refused(
            &short()
                .with_before(selection(2, 2))
                .with_after(selection(99, 99)),
            ApplyError::BadChange,
        );
    }

    #[test]
    fn a_snapshot_taken_before_a_transaction_is_unaffected_by_it() {
        let mut text = Text::from(MIXED);
        let before = text.snapshot();

        text.apply(&several(), Origin::new(1)).expect("it fits");

        assert_eq!(before.to_string(), MIXED);
        assert_eq!(before.revision().get(), 0);
        assert_eq!(text.snapshot().to_string(), "hello\r\nWörld\nx");
        assert_eq!(text.snapshot().revision().get(), 1);
    }

    #[test]
    fn a_transaction_edits_a_text_held_in_many_pieces() {
        let string = long_text();
        let mut text = Text::from(string.as_str());
        let middle = LINES.len() * 2_000;
        let rest = string.len() - middle - LINES.len();

        let result = text.apply(
            &transaction(&[
                insert("<"),
                Change::Retain(middle),
                Change::Delete(LINES.len()),
                insert("😀\r\n"),
                Change::Retain(rest),
                insert(">"),
            ]),
            Origin::new(1),
        );

        assert_eq!(result.map(Revision::get), Ok(1));
        let expected = format!(
            "<{}😀\r\n{}>",
            &string[..middle],
            &string[middle + LINES.len()..]
        );
        assert_eq!(read(&text), expected);
    }
}
