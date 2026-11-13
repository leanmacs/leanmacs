//! Kept inverses: what a text keeps of each transaction it accepted, so
//! that the transaction, or a run of them, can be taken back.
//!
//! The crate docs give the rules. [`Inverses`] is the table a
//! [`Text`](crate::Text) keeps them in; the text's methods apply what it
//! hands out by the path every transaction takes.

use std::borrow::Cow;
use std::collections::BTreeMap;
use std::error::Error;
use std::fmt;

use crate::change::ChangeSet;
use crate::selection::Selection;
use crate::snapshot::Revision;
use crate::transaction::Transaction;

/// What a text keeps of one transaction it accepted.
#[derive(Debug)]
struct Kept {
    /// The transaction that undoes it on the text it made: the bytes it
    /// removed, only the lengths of what it inserted, and its two
    /// selections swapped.
    inverse: Transaction,
    /// The name of the state the text was in before the transaction.
    before: Revision,
    /// The name of the state the transaction put the text in.
    after: Revision,
}

/// The kept inverses of one text, and the name of the state the text is
/// in.
///
/// A state's name is the revision of the transaction that first put the
/// text there, and 0 for the text as it was made. An ordinary transaction
/// names a new state; the inverse of a run copies the name the text had
/// before the run. So a name is given once, to the text one transaction
/// made, and whenever the text has that name it holds exactly that text.
#[derive(Debug, Default)]
pub(crate) struct Inverses {
    /// The name of the state the text is in.
    state: Revision,
    /// The kept inverse of each revision that has one, by the revision its
    /// transaction produced.
    kept: BTreeMap<Revision, Kept>,
}

/// The inverse of a run of revisions, ready to be applied
/// ([`Inverses::of_run`]).
pub(crate) struct RunInverse<'a> {
    /// The one transaction that takes the run back. For a run of one
    /// revision it is the kept inverse itself, borrowed.
    pub(crate) transaction: Cow<'a, Transaction>,
    /// The name of the state the text is in once it is applied: the one
    /// it was in before the run.
    pub(crate) state: Revision,
}

impl Inverses {
    /// Keeps `inverse` as the inverse of the transaction that produced
    /// `revision`, and names the state that transaction put the text in:
    /// `state`, or for `None` a new state, named by the revision.
    pub(crate) fn keep(
        &mut self,
        revision: Revision,
        inverse: Transaction,
        state: Option<Revision>,
    ) {
        let after = state.unwrap_or(revision);
        self.kept.insert(
            revision,
            Kept {
                inverse,
                before: self.state,
                after,
            },
        );
        self.state = after;
    }

    /// The transaction that takes back the run of revisions from `first`
    /// to `last`, for a text at the revision `current`. The refusals, and
    /// their order, are those of
    /// [`Text::apply_inverse`](crate::Text::apply_inverse).
    ///
    /// The inverse change sets of a longer run are composed, newest first,
    /// pairwise as a balanced tree, so a change is walked once for each
    /// level of the tree and not once for each revision after its own.
    pub(crate) fn of_run(
        &self,
        first: Revision,
        last: Revision,
        current: Revision,
    ) -> Result<RunInverse<'_>, InverseError> {
        if first > current || last > current {
            return Err(InverseError::UnknownRevision);
        }
        if first > last {
            return Err(InverseError::NotKept);
        }
        // Newest first: the order the inverses are applied in.
        let run: Vec<&Kept> = self
            .kept
            .range(first..=last)
            .rev()
            .map(|(_, kept)| kept)
            .collect();
        let (Some(newest), Some(oldest)) = (run.first(), run.last()) else {
            return Err(InverseError::NotKept);
        };
        // One for every revision of the run. Revision 0 is never among
        // them: no transaction produced it.
        let between = u64::try_from(run.len() - 1).ok();
        if between != Some(last.get() - first.get()) {
            return Err(InverseError::NotKept);
        }
        if self.state != newest.after {
            return Err(InverseError::NotInState);
        }
        let transaction = match run.as_slice() {
            [one] => Cow::Borrowed(&one.inverse),
            _ => {
                let changes: Vec<&ChangeSet> =
                    run.iter().map(|kept| kept.inverse.changes()).collect();
                // The state's name says the text is what the run ended
                // in, so each inverse fits what the one after it leaves
                // and none is expected not to compose.
                let composed = composed(&changes).ok_or(InverseError::NotInState)?;
                let mut transaction = Transaction::new(composed.into_owned());
                if let Some(selection) = newest.inverse.before() {
                    transaction = transaction.with_before(selection.clone());
                }
                if let Some(selection) = oldest.inverse.after() {
                    transaction = transaction.with_after(selection.clone());
                }
                Cow::Owned(transaction)
            }
        };
        Ok(RunInverse {
            transaction,
            state: oldest.before,
        })
    }
}

/// The change set that does each of `changes` in turn. `None` for none,
/// and where two neighbours do not compose.
fn composed<'a>(changes: &[&'a ChangeSet]) -> Option<Cow<'a, ChangeSet>> {
    match changes {
        [] => None,
        [one] => Some(Cow::Borrowed(one)),
        _ => {
            let (first, then) = changes.split_at(changes.len() / 2);
            let (first, then) = (composed(first)?, composed(then)?);
            Some(Cow::Owned(first.compose(&then)?))
        }
    }
}

/// What applying the inverse of a run did
/// ([`Text::apply_inverse`](crate::Text::apply_inverse)).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Inverted {
    /// The revision the inverse produced.
    pub revision: Revision,
    /// The selection in force before the run: the selection before that
    /// the run's first transaction carried, which is a selection of the
    /// text as the inverse leaves it. `None` when that transaction carried
    /// none.
    pub selection: Option<Selection>,
}

/// Why the inverse of a run was refused
/// ([`Text::apply_inverse`](crate::Text::apply_inverse)), or kept inverses
/// could not be dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InverseError {
    /// The text has not reached a revision the run names.
    UnknownRevision,
    /// The text keeps no inverse for a revision of the run: the run starts
    /// at revision 0, which no transaction produced, or its first revision
    /// is after its last.
    NotKept,
    /// The text is not in the state the run ended in.
    NotInState,
}

impl fmt::Display for InverseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::UnknownRevision => "the text has not reached the revision",
            Self::NotKept => "no inverse is kept for a revision of the run",
            Self::NotInState => "the text is not in the state the run ended in",
        })
    }
}

impl Error for InverseError {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::anchor::Anchor;
    use crate::change::{Bias, Change};
    use crate::log::{Attribution, Origin, Source};
    use crate::marker::Marker;
    use crate::patch::tests::span;
    use crate::patch::{Edit, Patch};
    use crate::selection::{SelectionRange, Shape};
    use crate::text::Text;

    /// "é" and "ö" are two bytes each: "é" is the bytes 1 and 2, the space
    /// is at 6, "wörld" is the bytes 7 to 12 and "ö" the bytes 8 and 9.
    const TEXT: &str = "héllo wörld";

    /// A character of four bytes, the bytes 0 to 3, and one of two, the
    /// bytes 6 and 7, in 11 bytes.
    const WIDE: &str = "😀 héllo";

    /// What `text` holds now.
    fn read(text: &Text) -> String {
        text.current().to_string()
    }

    /// The revision `text` is at, as a number.
    fn revision(text: &Text) -> u64 {
        text.current().revision().get()
    }

    /// An insert of `text`.
    fn insert(text: &str) -> Change {
        Change::Insert(text.to_owned())
    }

    /// The transaction of `changes`, with no selection.
    fn transaction(changes: &[Change]) -> Transaction {
        Transaction::new(changes.iter().cloned().collect())
    }

    /// A selection of shape `shape` with `ranges`, given as anchor and
    /// head, whose primary is the range at `primary` as they are given.
    fn selected(shape: Shape, ranges: &[(usize, usize)], primary: usize) -> Selection {
        let ranges = ranges
            .iter()
            .map(|&(anchor, head)| SelectionRange::new(anchor, head))
            .collect();
        Selection::shaped(shape, ranges, primary).expect("at least one range")
    }

    /// The inverse of the run from `first` to `last`, applied to `text`
    /// with the origin 9.
    fn invert(text: &mut Text, first: u64, last: u64) -> Result<Inverted, InverseError> {
        text.apply_inverse(Revision::new(first), Revision::new(last), Origin::new(9))
    }

    /// The inverse of the run from `first` to `last`, applied to `text`:
    /// the revision it produced, or its refusal.
    fn inverted(text: &mut Text, first: u64, last: u64) -> Result<u64, InverseError> {
        invert(text, first, last).map(|inverted| inverted.revision.get())
    }

    /// A text holding [`TEXT`] changed three times, the second time by a
    /// replace, to "hello, wörld😀".
    fn changed_three_times() -> Text {
        let mut text = Text::from(TEXT);
        // "é" becomes "e".
        let first = transaction(&[
            Change::Retain(1),
            Change::Delete(2),
            insert("e"),
            Change::Retain(10),
        ]);
        text.apply(&first, Origin::new(1)).expect("it fits");
        text.replace(5..5, ",").expect("a position");
        let third = transaction(&[Change::Retain(13), insert("😀")]);
        text.apply(&third, Origin::new(1)).expect("it fits");
        assert_eq!(read(&text), "hello, wörld😀");
        text
    }

    #[test]
    fn the_inverse_of_a_run_restores_the_text_the_run_started_from_as_one_revision_and_one_log_entry()
     {
        let mut text = changed_three_times();

        let result = invert(&mut text, 1, 3);

        assert_eq!(
            result,
            Ok(Inverted {
                revision: Revision::new(4),
                selection: None,
            })
        );
        assert_eq!(read(&text), TEXT);
        assert_eq!(revision(&text), 4);
        // One entry, with the origin given. Its old spans are ranges of
        // "hello, wörld😀" and its new ones ranges of "héllo wörld".
        let entry = text.entry(Revision::new(4)).expect("the inverse's entry");
        assert_eq!(entry.origin(), Origin::new(9));
        assert_eq!(
            entry.edits(),
            [
                Edit {
                    old: span(1, 2, (0, 1), (0, 2)),
                    new: span(1, 3, (0, 1), (0, 3)),
                },
                Edit {
                    old: span(5, 6, (0, 5), (0, 6)),
                    new: span(6, 6, (0, 6), (0, 6)),
                },
                Edit {
                    old: span(13, 17, (0, 13), (0, 17)),
                    new: span(13, 13, (0, 13), (0, 13)),
                },
            ]
        );
        assert!(text.entry(Revision::new(5)).is_none());
    }

    #[test]
    fn the_inverse_of_a_run_of_one_revision_restores_the_text_as_one_revision_and_one_log_entry() {
        let mut text = Text::from(WIDE);
        text.replace(0..4, "").expect("the first character");
        assert_eq!(read(&text), " héllo");

        let result = invert(&mut text, 1, 1);

        assert_eq!(
            result,
            Ok(Inverted {
                revision: Revision::new(2),
                selection: None,
            })
        );
        assert_eq!(read(&text), WIDE);
        assert_eq!(revision(&text), 2);
        let entry = text.entry(Revision::new(2)).expect("the inverse's entry");
        assert_eq!(entry.origin(), Origin::new(9));
        assert_eq!(
            entry.edits(),
            [Edit {
                old: span(0, 0, (0, 0), (0, 0)),
                new: span(0, 4, (0, 0), (0, 4)),
            }]
        );
        assert!(text.entry(Revision::new(3)).is_none());
    }

    #[test]
    fn the_inverse_of_an_inverse_restores_the_text_again() {
        let mut text = changed_three_times();
        assert_eq!(inverted(&mut text, 1, 3), Ok(4));
        assert_eq!(read(&text), TEXT);

        // The inverse of the undo is the redo.
        assert_eq!(inverted(&mut text, 4, 4), Ok(5));
        assert_eq!(read(&text), "hello, wörld😀");
        // And back and forth.
        assert_eq!(inverted(&mut text, 5, 5), Ok(6));
        assert_eq!(read(&text), TEXT);
        assert_eq!(inverted(&mut text, 6, 6), Ok(7));
        assert_eq!(read(&text), "hello, wörld😀");
        assert_eq!(revision(&text), 7);
    }

    #[test]
    fn an_inverse_is_refused_and_the_text_unchanged_when_the_text_is_not_in_the_state_its_run_ended_in()
     {
        let mut text = Text::from(TEXT);
        text.replace(0..1, "H").expect("the first character");
        text.replace(8..10, "o").expect("the ö");
        assert_eq!(read(&text), "Héllo world");
        let marker = Marker::Anchor(Anchor::new(8, Bias::After));
        let id = text.mark(marker.clone()).expect("a position");
        let newest = text.entry(Revision::new(2)).expect("an entry").edits();
        let newest = newest.to_vec();

        // The first edit's run did not end where the text is: the second
        // edit was made since.
        assert_eq!(invert(&mut text, 1, 1), Err(InverseError::NotInState));

        assert_eq!(read(&text), "Héllo world");
        assert_eq!(revision(&text), 2);
        let entry = text.entry(Revision::new(2)).expect("an entry");
        assert_eq!(entry.edits(), newest);
        assert!(text.entry(Revision::new(3)).is_none());
        assert_eq!(text.marker(id), Some(&marker));

        // Once the second edit is taken back its inverse is refused, the
        // text being no longer where it left it, and the first's accepted.
        assert_eq!(inverted(&mut text, 2, 2), Ok(3));
        assert_eq!(invert(&mut text, 2, 2), Err(InverseError::NotInState));
        assert_eq!(read(&text), "Héllo wörld");
        assert_eq!(revision(&text), 3);
        assert_eq!(inverted(&mut text, 1, 1), Ok(4));
        assert_eq!(read(&text), TEXT);
    }

    /// The first transaction of the run the selection tests take back, on
    /// [`WIDE`]: "X" is inserted after the first character, making
    /// "😀X héllo".
    fn inserting_x() -> Transaction {
        transaction(&[Change::Retain(4), insert("X"), Change::Retain(7)])
    }

    /// The second transaction of that run: "é" is deleted, making
    /// "😀X hllo".
    fn deleting_e() -> Transaction {
        transaction(&[Change::Retain(7), Change::Delete(2), Change::Retain(3)])
    }

    #[test]
    fn an_inverse_hands_back_the_selection_in_force_before_its_run() {
        for shape in [
            Shape::Exclusive,
            Shape::Inclusive,
            Shape::Line,
            Shape::Block,
        ] {
            // Two ranges of the text before the run, given out of order,
            // and two of the text after it.
            let before = selected(shape, &[(8, 5), (0, 4)], 0);
            let after = selected(shape, &[(7, 7), (0, 4)], 0);
            let mut text = Text::from(WIDE);
            let first = inserting_x()
                .with_before(before.clone())
                .with_after(selected(shape, &[(5, 5)], 0));
            let second = deleting_e()
                .with_before(selected(shape, &[(7, 9)], 0))
                .with_after(after.clone());
            text.apply(&first, Origin::new(1)).expect("it fits");
            text.apply(&second, Origin::new(1)).expect("it fits");
            assert_eq!(read(&text), "😀X hllo");

            // The selection before the run's first transaction.
            let undone = invert(&mut text, 1, 2).expect("the run ended here");
            assert_eq!(undone.revision, Revision::new(3), "{shape:?}");
            assert_eq!(undone.selection, Some(before.clone()), "{shape:?}");
            assert_eq!(read(&text), WIDE);
            // It is a selection of the text the inverse left.
            let held = undone
                .selection
                .map(Marker::Selection)
                .expect("handed back");
            let id = text.mark(held).expect("positions of the text");
            assert_eq!(text.marker(id), Some(&Marker::Selection(before)));

            // The inverse of the inverse hands back the selection after
            // the run's last transaction.
            let redone = invert(&mut text, 3, 3).expect("the run ended here");
            assert_eq!(redone.selection, Some(after.clone()), "{shape:?}");
            assert_eq!(read(&text), "😀X hllo");
            let held = redone
                .selection
                .map(Marker::Selection)
                .expect("handed back");
            let id = text.mark(held).expect("positions of the text");
            assert_eq!(text.marker(id), Some(&Marker::Selection(after)));
        }
    }

    #[test]
    fn an_inverse_hands_back_no_selection_when_its_runs_first_transaction_carried_none() {
        // The second transaction of the run carried both; the first none.
        let after = selected(Shape::Exclusive, &[(7, 7)], 0);
        let mut text = Text::from(WIDE);
        text.apply(&inserting_x(), Origin::new(1)).expect("it fits");
        let second = deleting_e()
            .with_before(selected(Shape::Exclusive, &[(7, 9)], 0))
            .with_after(after.clone());
        text.apply(&second, Origin::new(1)).expect("it fits");

        let undone = invert(&mut text, 1, 2).expect("the run ended here");
        assert_eq!(undone.selection, None);
        assert_eq!(read(&text), WIDE);
        // The redo has the last transaction's selection after.
        let redone = invert(&mut text, 3, 3).expect("the run ended here");
        assert_eq!(redone.selection, Some(after));

        // The first carried one before it, and the last none after it.
        let before = selected(Shape::Inclusive, &[(5, 8)], 0);
        let mut text = Text::from(WIDE);
        text.apply(&inserting_x().with_before(before.clone()), Origin::new(1))
            .expect("it fits");
        text.apply(&deleting_e(), Origin::new(1)).expect("it fits");

        let undone = invert(&mut text, 1, 2).expect("the run ended here");
        assert_eq!(undone.selection, Some(before));
        let redone = invert(&mut text, 3, 3).expect("the run ended here");
        assert_eq!(redone.selection, None);
        assert_eq!(read(&text), "😀X hllo");
    }

    #[test]
    fn a_state_is_where_the_text_is_in_its_history_not_what_it_holds() {
        // Typed back by hand to what it held, the text is somewhere new.
        let mut text = Text::from(TEXT);
        text.replace(0..0, "é").expect("an insert at the start");
        text.replace(0..2, "").expect("the é");
        assert_eq!(read(&text), TEXT);
        assert_eq!(invert(&mut text, 1, 1), Err(InverseError::NotInState));
        assert_eq!(read(&text), TEXT);
        assert_eq!(revision(&text), 2);

        // Brought back by inverses, it is where it was: an edit, its
        // inverse and the inverse of that leave the text where the edit
        // left it, at another revision.
        let mut text = Text::from(TEXT);
        text.replace(0..0, "é").expect("an insert at the start");
        assert_eq!(inverted(&mut text, 1, 1), Ok(2));
        assert_eq!(inverted(&mut text, 2, 2), Ok(3));
        assert_eq!(read(&text), "éhéllo wörld");
        // So the edit's own inverse is accepted again.
        assert_eq!(inverted(&mut text, 1, 1), Ok(4));
        assert_eq!(read(&text), TEXT);
    }

    /// Adds `added` at the end of `text`.
    fn append(text: &mut Text, added: &str) {
        let end = text.current().len();
        text.replace(end..end, added).expect("the end");
    }

    #[test]
    fn a_branch_is_switched_by_inverses_each_allowed_where_it_is_applied() {
        let mut text = Text::from("héllo");
        // Edits A and B.
        append(&mut text, " A");
        append(&mut text, "B");
        assert_eq!(read(&text), "héllo AB");

        // Undo B.
        assert_eq!(inverted(&mut text, 2, 2), Ok(3));
        assert_eq!(read(&text), "héllo A");
        // B's inverse again: the text is no longer where B left it.
        assert_eq!(invert(&mut text, 2, 2), Err(InverseError::NotInState));
        assert_eq!(revision(&text), 3);

        // Edit C, a new branch.
        append(&mut text, "C");
        assert_eq!(read(&text), "héllo AC");
        assert_eq!(revision(&text), 4);

        // Back to B: undo C, then redo B by the inverse of its undo.
        assert_eq!(inverted(&mut text, 4, 4), Ok(5));
        assert_eq!(read(&text), "héllo A");
        assert_eq!(inverted(&mut text, 3, 3), Ok(6));
        assert_eq!(read(&text), "héllo AB");

        // And to C again, by the inverses the last two moves left.
        assert_eq!(inverted(&mut text, 6, 6), Ok(7));
        assert_eq!(inverted(&mut text, 5, 5), Ok(8));
        assert_eq!(read(&text), "héllo AC");
    }

    #[test]
    fn a_run_may_hold_inverses() {
        // An edit, its inverse and the inverse of that are the run 1 to 3.
        let mut text = Text::from(TEXT);
        text.replace(1..3, "E").expect("the é");
        assert_eq!(inverted(&mut text, 1, 1), Ok(2));
        assert_eq!(inverted(&mut text, 2, 2), Ok(3));
        assert_eq!(read(&text), "hEllo wörld");
        assert_eq!(inverted(&mut text, 1, 3), Ok(4));
        assert_eq!(read(&text), TEXT);

        // After three edits and the inverse of the third, the text is
        // where the second left it: the run 1 to 2 ended there.
        let thrice = || {
            let mut text = Text::from(TEXT);
            text.replace(1..3, "E").expect("the é");
            append(&mut text, "😀");
            text.replace(0..1, "").expect("the first character");
            assert_eq!(inverted(&mut text, 3, 3), Ok(4));
            assert_eq!(read(&text), "hEllo wörld😀");
            text
        };
        let mut text = thrice();
        assert_eq!(inverted(&mut text, 1, 2), Ok(5));
        assert_eq!(read(&text), TEXT);
        // And so did the run 1 to 4, which holds the third and its inverse.
        let mut text = thrice();
        assert_eq!(inverted(&mut text, 1, 4), Ok(5));
        assert_eq!(read(&text), TEXT);
    }

    #[test]
    fn an_edit_that_changes_nothing_has_an_inverse() {
        let mut text = Text::from(TEXT);
        text.replace(3..3, "").expect("a position");
        assert_eq!(revision(&text), 1);

        assert_eq!(inverted(&mut text, 1, 1), Ok(2));
        assert_eq!(read(&text), TEXT);
        let entry = text.entry(Revision::new(2)).expect("the inverse's entry");
        assert_eq!(entry.edits(), []);

        // A run may cross one.
        let mut text = Text::from(TEXT);
        text.replace(0..1, "H").expect("the first character");
        text.replace(3..3, "").expect("a position");
        append(&mut text, "!");
        assert_eq!(inverted(&mut text, 1, 3), Ok(4));
        assert_eq!(read(&text), TEXT);
    }

    /// Checks that the inverse of the run from `first` to `last` of a text
    /// edited twice is refused with `error`, and that the text and its
    /// revision are as they were.
    fn assert_refused(first: u64, last: u64, error: InverseError) {
        let mut text = Text::from(TEXT);
        text.replace(0..1, "H").expect("the first character");
        text.replace(8..10, "o").expect("the ö");

        assert_eq!(
            invert(&mut text, first, last),
            Err(error),
            "{first}..={last}"
        );
        assert_eq!(read(&text), "Héllo world", "{first}..={last}");
        assert_eq!(revision(&text), 2, "{first}..={last}");
        assert!(text.entry(Revision::new(3)).is_none(), "{first}..={last}");
    }

    #[test]
    fn a_run_that_names_a_revision_the_text_has_not_reached_is_refused_as_unknown() {
        // At either end, and at both.
        assert_refused(1, 3, InverseError::UnknownRevision);
        assert_refused(2, u64::MAX, InverseError::UnknownRevision);
        assert_refused(3, 3, InverseError::UnknownRevision);
        assert_refused(3, 2, InverseError::UnknownRevision);
        assert_refused(u64::MAX, 1, InverseError::UnknownRevision);
        // Before anything else is looked at: this run also starts at 0.
        assert_refused(0, 3, InverseError::UnknownRevision);
    }

    #[test]
    fn a_run_from_revision_zero_or_whose_first_is_after_its_last_is_refused_as_not_kept() {
        // No transaction produced revision 0.
        assert_refused(0, 0, InverseError::NotKept);
        assert_refused(0, 2, InverseError::NotKept);
        assert_refused(2, 1, InverseError::NotKept);
        // Before the state is looked at: the text is not where the run
        // from 0 to 1 would have ended.
        assert_refused(0, 1, InverseError::NotKept);
        // A text nothing was done to has nothing kept.
        let mut text = Text::from(TEXT);
        assert_eq!(invert(&mut text, 0, 0), Err(InverseError::NotKept));
        assert_eq!(invert(&mut text, 1, 1), Err(InverseError::UnknownRevision));
        assert_eq!(read(&text), TEXT);
    }

    #[test]
    fn the_entry_of_an_inverse_has_the_origin_it_was_given_and_a_trace_names_what_it_restored_as_its_own()
     {
        // The character of four bytes is deleted by one author and
        // restored by another's inverse.
        let mut text = Text::from("a😀b");
        let delete = transaction(&[Change::Retain(1), Change::Delete(4), Change::Retain(1)]);
        text.apply(&delete, Origin::new(3)).expect("it fits");

        let result = text.apply_inverse(Revision::new(1), Revision::new(1), Origin::new(7));

        assert_eq!(result.map(|inverted| inverted.revision.get()), Ok(2));
        assert_eq!(read(&text), "a😀b");
        let entry = text.entry(Revision::new(2)).expect("the inverse's entry");
        assert_eq!(entry.origin(), Origin::new(7));
        assert_eq!(entry.revision(), Revision::new(2));
        // The restored bytes are the inverse's: it inserted them.
        let restored = Source::Entry {
            revision: Revision::new(2),
            origin: Origin::new(7),
        };
        let made = Source::Earlier(Revision::new(0));
        assert_eq!(
            text.trace(0..6),
            Some(vec![
                Attribution {
                    range: 0..1,
                    source: made,
                },
                Attribution {
                    range: 1..5,
                    source: restored,
                },
                Attribution {
                    range: 5..6,
                    source: made,
                },
            ])
        );
    }

    #[test]
    fn what_changed_across_an_edit_and_its_inverse_is_nothing_for_an_insert_and_the_range_for_a_delete()
     {
        let mut text = Text::from("héllo");
        text.replace(3..3, "😀").expect("a position");
        assert_eq!(inverted(&mut text, 1, 1), Ok(2));

        assert_eq!(
            text.changes_since(Revision::new(0)),
            Ok(Patch {
                from: Revision::new(0),
                to: Revision::new(2),
                edits: Vec::new(),
            })
        );

        // What a delete removed and its inverse put back is one edit whose
        // range is replaced by itself.
        let mut text = Text::from("héllo");
        text.replace(1..3, "").expect("the é");
        assert_eq!(inverted(&mut text, 1, 1), Ok(2));

        assert_eq!(
            text.changes_since(Revision::new(0)),
            Ok(Patch {
                from: Revision::new(0),
                to: Revision::new(2),
                edits: vec![Edit {
                    old: span(1, 3, (0, 1), (0, 3)),
                    new: span(1, 3, (0, 1), (0, 3)),
                }],
            })
        );
    }

    /// An anchor marker at `offset` with the bias `bias`.
    fn anchor(offset: usize, bias: Bias) -> Marker {
        Marker::Anchor(Anchor::new(offset, bias))
    }

    #[test]
    fn a_marker_follows_an_inverse_as_it_follows_any_transaction() {
        let mut text = Text::from(TEXT);
        // Inside "wörld", of each bias; before it; at its end; and a
        // selection inside it.
        let stays = text.mark(anchor(8, Bias::Before)).expect("a position");
        let goes = text.mark(anchor(8, Bias::After)).expect("a position");
        let outside = text.mark(anchor(3, Bias::After)).expect("a position");
        let end = text.mark(anchor(13, Bias::Before)).expect("a position");
        let inside = Marker::Selection(selected(Shape::Exclusive, &[(8, 10)], 0));
        let range = text.mark(inside).expect("positions");
        // "wörld" is deleted: everything in it collapses to where it was.
        text.replace(7..13, "").expect("the last word");
        assert_eq!(text.marker(stays), Some(&anchor(7, Bias::Before)));
        assert_eq!(text.marker(goes), Some(&anchor(7, Bias::After)));

        assert_eq!(inverted(&mut text, 1, 1), Ok(2));

        // The inverse inserts "wörld" at 7. The anchors are before it and
        // after it by their bias, and none is back inside it.
        assert_eq!(read(&text), TEXT);
        assert_eq!(text.marker(stays), Some(&anchor(7, Bias::Before)));
        assert_eq!(text.marker(goes), Some(&anchor(13, Bias::After)));
        assert_eq!(text.marker(outside), Some(&anchor(3, Bias::After)));
        assert_eq!(text.marker(end), Some(&anchor(7, Bias::Before)));
        // The selection collapsed to a cursor, which text inserted at it
        // is before.
        assert_eq!(
            text.marker(range),
            Some(&Marker::Selection(selected(
                Shape::Exclusive,
                &[(13, 13)],
                0
            )))
        );
    }

    #[test]
    fn markers_move_through_the_one_change_set_the_inverse_of_a_run_applies() {
        // "é" is deleted and then "E" inserted where it was: "hEllo wörld".
        let mut text = Text::from(TEXT);
        text.replace(1..3, "").expect("the é");
        text.replace(1..1, "E").expect("a position");
        let before = text.mark(anchor(1, Bias::Before)).expect("a position");
        let after = text.mark(anchor(1, Bias::After)).expect("a position");
        let past = text.mark(anchor(2, Bias::Before)).expect("a position");

        assert_eq!(inverted(&mut text, 1, 2), Ok(3));

        // The run's inverse replaces "E" by "é" as one change. An anchor
        // at the start of the replaced range is at the start or the end of
        // the replacement by its bias.
        assert_eq!(read(&text), TEXT);
        assert_eq!(text.marker(before), Some(&anchor(1, Bias::Before)));
        assert_eq!(text.marker(after), Some(&anchor(3, Bias::After)));
        // One at its end is after the replacement. Mapped through the two
        // inverses in turn it would be at 1: at the point "E" collapsed
        // to, and then before the "é" inserted there.
        assert_eq!(text.marker(past), Some(&anchor(3, Bias::Before)));
    }

    #[test]
    fn each_refusal_of_an_inverse_says_what_was_refused() {
        let unknown = InverseError::UnknownRevision.to_string();
        let not_kept = InverseError::NotKept.to_string();
        let not_in_state = InverseError::NotInState.to_string();

        // Each names its own thing, and not another's.
        assert!(unknown.contains("not reached"), "{unknown:?}");
        assert!(!unknown.contains("kept"), "{unknown:?}");
        assert!(!unknown.contains("state"), "{unknown:?}");
        assert!(not_kept.contains("no inverse is kept"), "{not_kept:?}");
        assert!(!not_kept.contains("reached"), "{not_kept:?}");
        assert!(!not_kept.contains("state"), "{not_kept:?}");
        assert!(
            not_in_state.contains("not in the state"),
            "{not_in_state:?}"
        );
        assert!(!not_in_state.contains("reached"), "{not_in_state:?}");
        assert!(!not_in_state.contains("kept"), "{not_in_state:?}");
    }
}
