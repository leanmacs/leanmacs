//! A text: the one writer.

use std::error::Error;
use std::fmt;
use std::ops::Range;

use crate::change::ChangeSet;
use crate::inverse::{InverseError, Inverses, Inverted};
use crate::log::{Attribution, Log, LogEntry, LogError, Origin, Subscription};
use crate::marker::{MarkError, Marker, MarkerId, Markers};
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
    /// The anchors and selections the text holds, each where it is in the
    /// text as it is now.
    markers: Markers,
    /// The inverse of each transaction the text accepted, until it is
    /// dropped, and the name of the state the text is in.
    inverses: Inverses,
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

    /// A text holding what `snapshot` holds, **at revision 0**: a new text,
    /// with an empty log, no markers and no kept inverses, whatever revision
    /// the snapshot was at. It shares the snapshot's text and copies none of
    /// it; an edit to either text, or to the one the snapshot was taken
    /// from, leaves the others as they were.
    ///
    /// This is how a text is made from what another thread loaded, since a
    /// snapshot is what crosses threads, and how a text is copied.
    pub fn from_snapshot(snapshot: &Snapshot) -> Self {
        Self {
            current: Snapshot {
                // A clone of a rope shares its tree.
                rope: snapshot.rope.clone(),
                revision: Revision::default(),
            },
            log: Log::default(),
            markers: Markers::default(),
            inverses: Inverses::default(),
        }
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
    /// its log are as they were, and no marker has moved. The checks are
    /// made in this order:
    ///
    /// 1. the change set fits the text, or it is [`ApplyError::BadChange`]:
    ///    it is for the text's length, and every boundary between two of
    ///    its changes is a position;
    /// 2. every end of the selection before, if there is one, is a position
    ///    of the text as it is, or it is [`ApplyError::BadSelection`];
    /// 3. every end of the selection after, if there is one, is a position
    ///    of the text the changes make, or it is
    ///    [`ApplyError::BadSelection`].
    ///
    /// An accepted transaction moves every marker the text holds
    /// ([`mark`](Self::mark)) to where it is in the text the changes make:
    /// an anchor by its bias ([`Anchor::map`](crate::Anchor::map)) and a
    /// selection as [`Selection::map`](crate::Selection::map) says. The
    /// selections of the transaction itself are carried, not held: the
    /// text marks neither.
    ///
    /// An accepted transaction's inverse is kept, by the revision it
    /// produced, until it is dropped: [`apply_inverse`](Self::apply_inverse)
    /// takes the transaction back. The transaction puts the text in a new
    /// state.
    pub fn apply(
        &mut self,
        transaction: &Transaction,
        origin: Origin,
    ) -> Result<Revision, ApplyError> {
        let inverse = Self::commit(
            &mut self.current,
            &mut self.log,
            &mut self.markers,
            transaction,
            origin,
        )?;
        let revision = self.current.revision;
        self.inverses.keep(revision, inverse, None);
        Ok(revision)
    }

    /// The one writer path: makes `transaction` of the text `current`,
    /// records it in `log` with `origin` and moves `markers`, as
    /// [`apply`](Self::apply) says, with its checks in its order. Returns
    /// the transaction's inverse, for the caller to keep with the name of
    /// the state the transaction put the text in. A refusal has changed
    /// nothing.
    ///
    /// It takes the parts of a text and not the text, so that the
    /// transaction may be one the text keeps: a kept inverse is applied
    /// where it is, with no copy.
    fn commit(
        current: &mut Snapshot,
        log: &mut Log,
        markers: &mut Markers,
        transaction: &Transaction,
        origin: Origin,
    ) -> Result<Transaction, ApplyError> {
        let changes = transaction.changes();
        if !changes.fits(&current.rope) {
            return Err(ApplyError::BadChange);
        }
        if transaction
            .before()
            .is_some_and(|selection| !selection.fits(current))
        {
            return Err(ApplyError::BadSelection);
        }
        // The changes are made to a clone, which shares the text's nodes and
        // copies only those it changes. It takes the text's place once
        // everything is accepted, so a refusal has nothing to undo.
        let mut next = Snapshot {
            rope: current.rope.clone(),
            revision: current.revision.next(),
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
            let (Some(old), Some(new)) = (Span::of(current, old), Span::of(&next, new)) else {
                return Err(ApplyError::BadChange);
            };
            edits.push(Edit { old, new });
        }
        // Every end a marker holds is a position of the text as it is, so
        // it is within the length the change set is for and none is
        // expected to map to nothing.
        let Some(marked) = markers.mapped(changes) else {
            return Err(ApplyError::BadChange);
        };
        // What the transaction removes is read from the text as it is,
        // last of all, so a refused transaction reads none of it. The
        // change set fits, so an inverse is expected. Nothing has been
        // changed yet.
        let Some(inverse) = transaction.invert(current) else {
            return Err(ApplyError::BadChange);
        };
        log.record(origin, edits.into_boxed_slice());
        markers.place_all(&marked);
        *current = next;
        Ok(inverse)
    }

    /// Applies the inverse of the run of revisions from `first` to `last`,
    /// both included, as one transaction, recording `origin` as who made
    /// the edit: the text holds again what it held before the transaction
    /// that produced `first`.
    ///
    /// The inverse is a transaction like any other and goes by the path
    /// every transaction takes ([`apply`](Self::apply)): it adds one to
    /// the revision, has one entry in the log, with `origin` and the
    /// edits of the run's inverses composed, and moves every marker
    /// through that one change set. Text it puts back is its own in a
    /// [`trace`](Self::trace). Its inverse is kept like any other's, so
    /// the inverse of the revision this returns takes it back: a redo is
    /// the inverse of an undo.
    ///
    /// Refused, changing nothing, in this order:
    ///
    /// 1. the text has not reached `first` or `last`:
    ///    [`InverseError::UnknownRevision`];
    /// 2. the text does not keep an inverse for every revision of the run,
    ///    because the run starts at revision 0, which no transaction
    ///    produced, its first revision is after its last, or one of its
    ///    inverses was dropped ([`drop_inverses`](Self::drop_inverses)):
    ///    [`InverseError::NotKept`];
    /// 3. the text is not in the state the run ended in:
    ///    [`InverseError::NotInState`].
    ///
    /// **A state** is where the text is in its history, not what it
    /// holds. A transaction puts the text in a new state, and the inverse
    /// of a run puts it back in the state it was in before the run. So
    /// the text is in the state a run ended in just after the run, and
    /// again whenever inverses have brought it back there; a text edited
    /// by hand until it reads what it read then is in another state. The
    /// crate docs say why.
    ///
    /// What is handed back is the selection in force before the run: the
    /// selection before that the run's first transaction carried, or none
    /// when it carried none. The text holds no current selection, so
    /// putting it somewhere ([`mark`](Self::mark), [`place`](Self::place))
    /// is the caller's. The inverse of this inverse hands back the
    /// selection after that the run's last transaction carried.
    ///
    /// The cost is that of composing the run's kept inverses and of one
    /// transaction of their size, and of reading the bytes the inverse
    /// removes back out of the text, once, for its own inverse. A run of
    /// one revision is applied where it is kept, with no copy.
    pub fn apply_inverse(
        &mut self,
        first: Revision,
        last: Revision,
        origin: Origin,
    ) -> Result<Inverted, InverseError> {
        let run = self.inverses.of_run(first, last, self.current.revision)?;
        // The state's name says the text is what the run ended in, which
        // the inverse fits, so the transaction is not expected to be
        // refused. It is reported, and not a panic, as any refusal is.
        let inverse = Self::commit(
            &mut self.current,
            &mut self.log,
            &mut self.markers,
            &run.transaction,
            origin,
        )
        .map_err(|_| InverseError::NotInState)?;
        let selection = run.transaction.after().cloned();
        let state = run.state;
        let revision = self.current.revision;
        self.inverses.keep(revision, inverse, Some(state));
        Ok(Inverted {
            revision,
            selection,
        })
    }

    /// Drops the kept inverse of every revision from `first` to `last`,
    /// both included. Afterwards the inverse of a run that names one of
    /// them is refused ([`InverseError::NotKept`]), whatever state the
    /// text is in, and the inverse of any other run is as it was.
    ///
    /// [`InverseError::UnknownRevision`], dropping nothing, for a `last`
    /// the text has not reached. A revision of the run with nothing kept
    /// (revision 0, or one dropped already) is passed over, and a run
    /// whose first revision is after its last drops nothing.
    ///
    /// Dropping is not an edit: the text, its revision and its log are as
    /// they were. It is independent of [`forget`](Self::forget), which
    /// drops log entries and leaves every kept inverse: the log's readers
    /// are consumers that pull patches, and an inverse's is the history.
    /// An inverse of a run whose entries the log has forgotten still
    /// applies.
    ///
    /// This is the one bound on what is kept. The text never drops an
    /// inverse by itself, not even those of a run it has just inverted:
    /// it keeps one for each accepted transaction, each holding the bytes
    /// its transaction removed, until the caller, which knows what its
    /// history still needs, drops it.
    pub fn drop_inverses(&mut self, first: Revision, last: Revision) -> Result<(), InverseError> {
        if last > self.current.revision {
            return Err(InverseError::UnknownRevision);
        }
        self.inverses.drop_run(first, last);
        Ok(())
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
    /// [`LogError::Unknown`] for a revision the text has not reached, and
    /// [`LogError::Forgotten`] for one before the [horizon](Self::horizon).
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

    /// Where the bytes of `range`, a range of the text as it is now, came
    /// from: the range cut into pieces, in order and covering it, each
    /// with its [`Source`](crate::Source). A piece is the entry's whose
    /// transaction inserted its bytes, which names the revision and the
    /// origin; bytes no entry the log holds inserted were in the text at
    /// the [horizon](Self::horizon), and are named as earlier than it.
    /// Neighbours with one source are one piece, and text that was deleted
    /// is in none. Empty for an empty range.
    ///
    /// `None` unless both ends of the range are positions and the start is
    /// not after the end.
    ///
    /// This walks the log back from its newest entry, so it costs more the
    /// more the log holds: it is a question for a review, not for a
    /// keystroke.
    pub fn trace(&self, range: Range<usize>) -> Option<Vec<Attribution>> {
        let fits = range.start <= range.end
            && self.current.is_char_boundary(range.start)
            && self.current.is_char_boundary(range.end);
        fits.then(|| self.log.trace(range))
    }

    /// Drops the log's entries for the revisions up to and including
    /// `through`, and moves the [horizon](Self::horizon) there. The text
    /// and its revision are untouched.
    ///
    /// Afterwards [`changes_since`](Self::changes_since) a revision before
    /// `through` is [`LogError::Forgotten`], and [`trace`](Self::trace)
    /// names bytes written at or before `through` as earlier than it. A
    /// revision at or before the horizon changes nothing.
    /// [`LogError::Unknown`] for a revision the text has not reached.
    ///
    /// This is the log's one bound. The text never drops an entry by
    /// itself: the log grows by one entry for each transaction until the
    /// caller, which knows who still reads it, forgets.
    pub fn forget(&mut self, through: Revision) -> Result<(), LogError> {
        self.log.forget(through, self.current.revision)
    }

    /// Holds `marker`, and returns the id it is read back by. From now on
    /// every transaction the text accepts moves it
    /// ([`apply`](Self::apply)), until it is given up
    /// ([`unmark`](Self::unmark)).
    ///
    /// Refused, holding nothing, unless the marker is in the text as it is
    /// now: an anchor's offset is a position, or it is
    /// [`MarkError::BadPosition`]; every end of every range of a selection
    /// is a position, or it is [`MarkError::BadSelection`].
    ///
    /// Marking is not an edit: the revision and the log are as they were,
    /// and no snapshot holds a marker.
    pub fn mark(&mut self, marker: Marker) -> Result<MarkerId, MarkError> {
        self.check(&marker)?;
        Ok(self.markers.add(marker))
    }

    /// The marker with the id `id`, where it is in the text as it is now.
    /// `None` when the text holds no such marker.
    pub fn marker(&self, id: MarkerId) -> Option<&Marker> {
        self.markers.get(id)
    }

    /// Puts `marker` in place of the marker with the id `id`, which keeps
    /// its id: the marker is somewhere else, or of the other kind.
    ///
    /// Refused, changing nothing, in this order: the text holds no marker
    /// with that id ([`MarkError::NoSuchMarker`]); `marker` is not in the
    /// text as it is now, as [`mark`](Self::mark) says.
    pub fn place(&mut self, id: MarkerId, marker: Marker) -> Result<(), MarkError> {
        if self.markers.get(id).is_none() {
            return Err(MarkError::NoSuchMarker);
        }
        // Checked before the marker is touched, and nothing below fails.
        self.check(&marker)?;
        if let Some(held) = self.markers.get_mut(id) {
            *held = marker;
        }
        Ok(())
    }

    /// Gives up the marker with the id `id`, and returns whether the text
    /// held one. The id names nothing from then on: the text gives no
    /// marker that id again.
    pub fn unmark(&mut self, id: MarkerId) -> bool {
        self.markers.remove(id)
    }

    /// Whether `marker` is in the text as it is now.
    fn check(&self, marker: &Marker) -> Result<(), MarkError> {
        match marker {
            Marker::Anchor(anchor) if !self.current.is_char_boundary(anchor.offset) => {
                Err(MarkError::BadPosition)
            }
            Marker::Selection(selection) if !selection.fits(&self.current) => {
                Err(MarkError::BadSelection)
            }
            Marker::Anchor(_) | Marker::Selection(_) => Ok(()),
        }
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
            markers: Markers::default(),
            inverses: Inverses::default(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::anchor::Anchor;
    use crate::change::{Bias, Change};
    use crate::selection::{Selection, SelectionRange, Shape};
    use crate::snapshot::Revision;

    /// A text holding [`LINES`] after three edits, so at revision 3, and
    /// what it holds.
    fn text_at_revision_3() -> (Text, String) {
        let mut text = Text::from(LINES);
        let mut reference = String::from(LINES);
        for (range, insert) in [(0..1, "H"), (7..7, "\u{10DCFF}"), (3..6, "")] {
            assert_eq!(text.replace(range.clone(), insert), Ok(()));
            reference.replace_range(range, insert);
        }
        assert_eq!(text.current().revision(), Revision::new(3));
        (text, reference)
    }

    #[test]
    fn a_text_made_from_a_snapshot_holds_what_it_holds_at_revision_0_with_an_empty_log() {
        let (source, reference) = text_at_revision_3();
        let snapshot = source.snapshot();

        let copy = Text::from_snapshot(&snapshot);

        assert_eq!(copy.current().to_string(), reference);
        assert_eq!(copy.current().revision(), Revision::new(0));
        assert_eq!(copy.horizon(), Revision::new(0));
        assert!(copy.entry(Revision::new(1)).is_none());
        assert_eq!(
            copy.changes_since(Revision::new(0))
                .map(|patch| patch.edits),
            Ok(Vec::new())
        );
        // Whatever the snapshot's own state: an empty one too.
        let empty = Text::from_snapshot(&Snapshot::default());
        assert_eq!(empty.current().to_string(), "");
        assert_eq!(empty.current().revision(), Revision::new(0));
    }

    #[test]
    fn an_edit_to_a_text_made_from_a_snapshot_leaves_the_snapshot_and_the_source_as_they_were() {
        let (mut source, reference) = text_at_revision_3();
        let snapshot = source.snapshot();
        let mut copy = Text::from_snapshot(&snapshot);

        assert_eq!(copy.replace(0..0, "copy: "), Ok(()));

        assert_eq!(copy.current().to_string(), format!("copy: {reference}"));
        assert_eq!(copy.current().revision(), Revision::new(1));
        assert_eq!(snapshot.to_string(), reference);
        assert_eq!(snapshot.revision(), Revision::new(3));
        assert_eq!(source.current().to_string(), reference);
        // And the other way: an edit to the source leaves the copy.
        assert_eq!(source.replace(0..0, "source: "), Ok(()));
        assert_eq!(copy.current().to_string(), format!("copy: {reference}"));
    }

    #[test]
    fn a_text_made_from_a_snapshot_holds_no_marker_of_the_source_and_keeps_no_inverse() {
        let (mut source, _) = text_at_revision_3();
        let marker = Marker::Anchor(Anchor::new(4, Bias::Before));
        let Ok(id) = source.mark(marker) else {
            panic!("the source takes the marker");
        };

        let mut copy = Text::from_snapshot(&source.snapshot());

        assert!(source.marker(id).is_some());
        assert!(copy.marker(id).is_none());
        // The source keeps the inverse of its revision 1. The copy never
        // reached a revision 1.
        assert_eq!(
            copy.apply_inverse(Revision::new(1), Revision::new(1), Origin::default())
                .err(),
            Some(InverseError::UnknownRevision)
        );
        assert_eq!(copy.current().revision(), Revision::new(0));
    }

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

    /// An anchor marker at `offset` with the bias `bias`.
    fn anchor(offset: usize, bias: Bias) -> Marker {
        Marker::Anchor(Anchor::new(offset, bias))
    }

    /// A selection marker of shape `shape` with `ranges`, given as anchor
    /// and head, whose primary is the first of them.
    fn selected(shape: Shape, ranges: &[(usize, usize)]) -> Marker {
        let ranges = ranges
            .iter()
            .map(|&(anchor, head)| SelectionRange::new(anchor, head))
            .collect();
        Marker::Selection(Selection::shaped(shape, ranges, 0).expect("at least one range"))
    }

    #[test]
    fn a_marker_reads_back_by_the_id_marking_gave() {
        let mut text = Text::from(TEXT);

        let first = text.mark(anchor(3, Bias::After)).expect("a position");
        let second = text
            .mark(selected(Shape::Line, &[(0, 3), (13, 10)]))
            .expect("positions");

        assert_ne!(first, second);
        assert_eq!(text.marker(first), Some(&anchor(3, Bias::After)));
        assert_eq!(
            text.marker(second),
            Some(&selected(Shape::Line, &[(0, 3), (13, 10)]))
        );
    }

    #[test]
    fn a_text_holds_no_marker_with_an_id_it_never_gave() {
        let mut text = Text::from(TEXT);
        let given = text.mark(anchor(0, Bias::Before)).expect("a position");

        assert_eq!(text.marker(MarkerId::new(given.get() + 1)), None);
        assert_eq!(text.marker(MarkerId::new(u64::MAX)), None);
        assert_eq!(Text::new().marker(given), None);
    }

    #[test]
    fn an_anchor_that_is_at_no_position_is_refused_and_nothing_is_held() {
        // In "héllo wörld", 2 is inside "é" and 13 is the end.
        let mut text = Text::from(TEXT);

        for offset in [2, 14, usize::MAX] {
            assert_eq!(
                text.mark(anchor(offset, Bias::Before)),
                Err(MarkError::BadPosition),
                "{offset}"
            );
        }
        let end = text.mark(anchor(13, Bias::Before)).expect("the end");
        // The refusals held nothing: the one marker is the only one.
        assert!(text.unmark(end));
        assert!((0..8).all(|id| text.marker(MarkerId::new(id)).is_none()));
    }

    #[test]
    fn a_selection_with_an_end_at_no_position_is_refused() {
        let mut text = Text::from(TEXT);

        for ranges in [&[(0, 1), (3, 2)][..], &[(2, 6)], &[(0, 14)], &[(14, 14)]] {
            assert_eq!(
                text.mark(selected(Shape::Exclusive, ranges)),
                Err(MarkError::BadSelection),
                "{ranges:?}"
            );
        }
        assert!(text.mark(selected(Shape::Block, &[(13, 0)])).is_ok());
    }

    #[test]
    fn place_puts_a_marker_somewhere_else_and_can_make_it_the_other_kind() {
        let mut text = Text::from(TEXT);
        let id = text.mark(anchor(3, Bias::After)).expect("a position");
        let other = text.mark(anchor(0, Bias::Before)).expect("a position");

        assert_eq!(text.place(id, anchor(6, Bias::Before)), Ok(()));
        assert_eq!(text.marker(id), Some(&anchor(6, Bias::Before)));

        assert_eq!(
            text.place(id, selected(Shape::Inclusive, &[(4, 1)])),
            Ok(())
        );
        assert_eq!(
            text.marker(id),
            Some(&selected(Shape::Inclusive, &[(4, 1)]))
        );

        assert_eq!(text.place(id, anchor(0, Bias::After)), Ok(()));
        assert_eq!(text.marker(id), Some(&anchor(0, Bias::After)));
        // The other marker is where it was.
        assert_eq!(text.marker(other), Some(&anchor(0, Bias::Before)));
    }

    #[test]
    fn a_refused_place_changes_nothing_and_an_unknown_id_is_refused_first() {
        let mut text = Text::from(TEXT);
        let id = text.mark(anchor(3, Bias::After)).expect("a position");
        let unknown = MarkerId::new(id.get() + 1);

        // An unknown id, whatever the marker.
        assert_eq!(
            text.place(unknown, anchor(0, Bias::Before)),
            Err(MarkError::NoSuchMarker)
        );
        assert_eq!(
            text.place(unknown, anchor(2, Bias::Before)),
            Err(MarkError::NoSuchMarker)
        );
        assert_eq!(
            text.place(unknown, selected(Shape::Exclusive, &[(2, 2)])),
            Err(MarkError::NoSuchMarker)
        );
        assert_eq!(text.marker(unknown), None);
        // A known id, and a marker that is not in the text.
        assert_eq!(
            text.place(id, anchor(2, Bias::Before)),
            Err(MarkError::BadPosition)
        );
        assert_eq!(
            text.place(id, selected(Shape::Exclusive, &[(0, 14)])),
            Err(MarkError::BadSelection)
        );
        assert_eq!(text.marker(id), Some(&anchor(3, Bias::After)));
    }

    #[test]
    fn unmark_gives_a_marker_up_and_its_id_is_never_given_again() {
        let mut text = Text::from(TEXT);
        let first = text.mark(anchor(3, Bias::After)).expect("a position");
        let second = text.mark(anchor(4, Bias::After)).expect("a position");

        assert!(text.unmark(first));

        assert_eq!(text.marker(first), None);
        assert!(!text.unmark(first));
        assert_eq!(
            text.place(first, anchor(0, Bias::After)),
            Err(MarkError::NoSuchMarker)
        );
        assert_eq!(text.marker(second), Some(&anchor(4, Bias::After)));
        // Later markers get other ids, the last one given up included.
        assert!(text.unmark(second));
        let later: Vec<_> = (0..4)
            .map(|_| text.mark(anchor(0, Bias::After)).expect("a position"))
            .collect();
        for (index, id) in later.iter().enumerate() {
            assert!(*id != first && *id != second, "{id:?}");
            assert!(!later[..index].contains(id), "{id:?}");
        }
        assert!(!text.unmark(MarkerId::new(u64::MAX)));
    }

    #[test]
    fn an_accepted_transaction_moves_every_marker() {
        // "XY" is inserted at 3, after "hé".
        let mut text = Text::from(TEXT);
        let stays = text.mark(anchor(3, Bias::Before)).expect("a position");
        let goes = text.mark(anchor(3, Bias::After)).expect("a position");
        let range = text
            .mark(selected(Shape::Exclusive, &[(1, 3), (6, 3)]))
            .expect("positions");
        let last = text.mark(anchor(13, Bias::Before)).expect("a position");

        let result = text.apply(
            &transaction(&[Change::Retain(3), insert("XY"), Change::Retain(10)]),
            Origin::new(1),
        );

        assert!(result.is_ok());
        assert_eq!(text.marker(stays), Some(&anchor(3, Bias::Before)));
        assert_eq!(text.marker(goes), Some(&anchor(5, Bias::After)));
        // The insertion is between the two ranges, and in neither.
        assert_eq!(
            text.marker(range),
            Some(&selected(Shape::Exclusive, &[(1, 3), (8, 5)]))
        );
        assert_eq!(text.marker(last), Some(&anchor(15, Bias::Before)));
    }

    #[test]
    fn a_transaction_that_brings_marked_ranges_together_leaves_one_range() {
        // " w" is deleted from "héllo wörld": the cursors at 6 and at 8 meet.
        let mut text = Text::from(TEXT);
        let cursors = text
            .mark(selected(Shape::Exclusive, &[(6, 6), (8, 8), (0, 0)]))
            .expect("positions");

        let result = text.apply(
            &transaction(&[Change::Retain(6), Change::Delete(2), Change::Retain(5)]),
            Origin::new(1),
        );

        assert!(result.is_ok());
        let Some(Marker::Selection(selection)) = text.marker(cursors) else {
            panic!("the marker is a selection");
        };
        assert_eq!(
            selection.ranges(),
            [SelectionRange::new(0, 0), SelectionRange::new(6, 6)]
        );
        // The primary was the cursor at 6.
        assert_eq!(selection.primary(), 1);
    }

    #[test]
    fn replace_moves_every_marker_as_the_transaction_it_is() {
        let mut text = Text::from(TEXT);
        let before = text.mark(anchor(1, Bias::After)).expect("a position");
        let inside = text.mark(anchor(4, Bias::After)).expect("a position");
        let cursor = text
            .mark(selected(Shape::Inclusive, &[(6, 6)]))
            .expect("a position");

        assert_eq!(text.replace(3..5, "L"), Ok(()));

        assert_eq!(text.marker(before), Some(&anchor(1, Bias::After)));
        assert_eq!(text.marker(inside), Some(&anchor(4, Bias::After)));
        assert_eq!(
            text.marker(cursor),
            Some(&selected(Shape::Inclusive, &[(5, 5)]))
        );
    }

    #[test]
    fn a_refused_transaction_moves_no_marker() {
        let mut text = Text::from(TEXT);
        let point = text.mark(anchor(3, Bias::After)).expect("a position");
        let range = text
            .mark(selected(Shape::Exclusive, &[(1, 6)]))
            .expect("positions");

        // For another length; and one that fits, with a selection after
        // that does not.
        let short = transaction(&[insert("XY"), Change::Retain(3)]);
        let unselectable = transaction(&[insert("XY"), Change::Retain(13)])
            .with_after(Selection::new(vec![SelectionRange::new(0, 99)], 0).expect("one range"));
        assert_eq!(
            text.apply(&short, Origin::new(1)),
            Err(ApplyError::BadChange)
        );
        assert_eq!(
            text.apply(&unselectable, Origin::new(1)),
            Err(ApplyError::BadSelection)
        );
        assert_eq!(text.replace(2..3, "x"), Err(BadRange));

        assert_eq!(text.marker(point), Some(&anchor(3, Bias::After)));
        assert_eq!(
            text.marker(range),
            Some(&selected(Shape::Exclusive, &[(1, 6)]))
        );
    }

    #[test]
    fn marking_placing_and_unmarking_are_not_edits() {
        let mut text = Text::from(TEXT);
        text.replace(0..0, "x").expect("a position");
        let snapshot = text.snapshot();
        let since = text.changes_since(Revision::new(0));

        let id = text.mark(anchor(4, Bias::After)).expect("a position");
        text.place(id, selected(Shape::Line, &[(0, 14)]))
            .expect("positions");
        let other = text.mark(anchor(0, Bias::Before)).expect("a position");
        assert!(text.unmark(other));

        assert_eq!(text.current().revision(), Revision::new(1));
        assert_eq!(text.changes_since(Revision::new(0)), since);
        assert_eq!(
            text.changes_since(Revision::new(1))
                .map(|patch| patch.edits),
            Ok(Vec::new())
        );
        assert!(text.entry(Revision::new(2)).is_none());
        assert_eq!(text.horizon(), Revision::new(0));
        assert_eq!(snapshot.revision(), Revision::new(1));
        assert_eq!(snapshot.to_string(), read(&text));
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
