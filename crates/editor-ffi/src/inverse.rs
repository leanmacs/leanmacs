//! A document's kept inverses as they cross the boundary: applying the
//! inverse of a run of revisions, and dropping kept inverses.
//!
//! A run is two revisions, its first and its last, and an origin is a
//! number: all three cross as `u64`. What applying an inverse did crosses
//! as words (the private module `words`) in a [`RawWords`]:
//!
//! - **an inverted result** ([`editor_ffi_document_apply_inverse`]): the
//!   revision the inverse produced, a presence word (0 or 1), and if it is
//!   1 the words of the selection handed back, as a marker carries a
//!   selection's: its shape (0 exclusive, 1 inclusive, 2 line-wise, 3
//!   block-wise), the index of its primary range, the count of ranges, and
//!   an anchor and a head for each.
//!
//! A refusal has more than one reason, so it is a status
//! ([`InverseStatus`]) and no words. Dropping has one refusal, and answers
//! with a `bool` ([`editor_ffi_document_drop_inverses`]), as forgetting the
//! log does.
//!
//! No change set crosses, and no name of a state: text that was deleted
//! stays in the library. What the inverse of a run does to the text, when
//! it is refused and what it hands back are the text's rules, pinned by
//! `editor-text`'s own tests. This module forwards and writes the words.

use editor_text::{InverseError, Inverted, Origin, Revision};

use crate::document::Document;
use crate::log::RawWords;
use crate::transaction::SelectionWords;
use crate::words::Writer;

/// How applying the inverse of a run ended, as it crosses the boundary:
/// the `status` of the [`RawWords`] that
/// [`editor_ffi_document_apply_inverse`] fills.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InverseStatus {
    /// Applied. The record's words are the inverted result.
    Done = 0,
    /// Refused: the text has not reached a revision of the run.
    UnknownRevision = 1,
    /// Refused: the text keeps no inverse for a revision of the run.
    NotKept = 2,
    /// Refused: the text is not in the state the run ended in.
    NotInState = 3,
}

impl InverseStatus {
    /// The status that reports `error`. The text's refusals are few and
    /// each has a status of its own, so this names every one: a new
    /// refusal must be given a number here before it can cross.
    pub const fn of(error: InverseError) -> Self {
        match error {
            InverseError::UnknownRevision => Self::UnknownRevision,
            InverseError::NotKept => Self::NotKept,
            InverseError::NotInState => Self::NotInState,
        }
    }
}

/// The words of `inverted`, in the layout the module docs give.
pub fn inverted_words(inverted: &Inverted) -> Vec<u8> {
    let selection = inverted.selection.as_ref();
    let mut writer = Writer::with_capacity(2 + selection.map_or(0, SelectionWords::len));
    writer.word(inverted.revision.get());
    match selection {
        None => writer.word(0),
        Some(selection) => {
            writer.word(1);
            SelectionWords::write(&mut writer, selection);
        }
    }
    writer.finish()
}

impl Document {
    /// Applies the inverse of the run of revisions from `first` to `last`,
    /// recording `origin` as who made the edit
    /// ([`editor_text::Text::apply_inverse`]). A refused one changes
    /// nothing.
    pub fn apply_inverse(
        &self,
        first: Revision,
        last: Revision,
        origin: Origin,
    ) -> Result<Inverted, InverseError> {
        self.lock().apply_inverse(first, last, origin)
    }

    /// Drops the kept inverses of the revisions from `first` to `last`
    /// ([`editor_text::Text::drop_inverses`]).
    pub fn drop_inverses(&self, first: Revision, last: Revision) -> Result<(), InverseError> {
        self.lock().drop_inverses(first, last)
    }
}

/// [`Document::apply_inverse`] for C: applies to `document` the inverse of
/// the run of revisions from `first` to `last`, with `origin`, and fills
/// `out` with the inverted result as words and the status
/// [`InverseStatus::Done`]; or with no words and the status of the
/// refusal, having changed nothing.
///
/// # Safety
///
/// `document` came from [`editor_ffi_document_new`] and has not been freed,
/// and `out` points to a writable [`RawWords`].
///
/// [`editor_ffi_document_new`]: crate::document::editor_ffi_document_new
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_document_apply_inverse(
    document: *const Document,
    first: u64,
    last: u64,
    origin: u64,
    out: *mut RawWords,
) {
    // SAFETY: the caller guarantees `document` points to a live document.
    let inverted = unsafe { &*document }.apply_inverse(
        Revision::new(first),
        Revision::new(last),
        Origin::new(origin),
    );
    let raw = match inverted {
        Ok(inverted) => {
            RawWords::with_status(InverseStatus::Done as u64, inverted_words(&inverted))
        }
        Err(error) => RawWords::with_status(InverseStatus::of(error) as u64, Vec::new()),
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
}

/// [`Document::drop_inverses`] for C: drops the kept inverses of
/// `document` for the revisions from `first` to `last`, and returns
/// whether it could. False, with nothing changed, for a revision the text
/// has not reached.
///
/// # Safety
///
/// `document` came from [`editor_ffi_document_new`] and has not been freed.
///
/// [`editor_ffi_document_new`]: crate::document::editor_ffi_document_new
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_document_drop_inverses(
    document: *const Document,
    first: u64,
    last: u64,
) -> bool {
    // SAFETY: the caller guarantees `document` points to a live document.
    unsafe { &*document }
        .drop_inverses(Revision::new(first), Revision::new(last))
        .is_ok()
}

#[cfg(test)]
mod tests {
    use editor_text::{ChangeSet, Selection, SelectionRange, Shape, Text, Transaction};

    use super::*;
    use crate::words::tests::words_of;

    /// The shapes of a selection, as words.
    const EXCLUSIVE: u64 = 0;
    const INCLUSIVE: u64 = 1;
    const LINE: u64 = 2;
    const BLOCK: u64 = 3;

    /// "é" and "ö" are two bytes each. The text is 13 bytes.
    const TEXT: &str = "héllo wörld";

    /// A selection of shape `shape` of the ranges `ranges`, each an anchor
    /// and a head.
    fn shaped(shape: Shape, ranges: &[(usize, usize)], primary: usize) -> Selection {
        let ranges = ranges
            .iter()
            .map(|&(anchor, head)| SelectionRange::new(anchor, head))
            .collect();
        Selection::shaped(shape, ranges, primary).expect("a primary among the ranges")
    }

    #[test]
    fn an_inverted_result_with_no_selection_is_its_revision_and_a_zero() {
        let inverted = Inverted {
            revision: Revision::new(7),
            selection: None,
        };

        assert_eq!(words_of(&inverted_words(&inverted)), [7, 0]);
        // A revision is a word, and is not cut down.
        let last = Inverted {
            revision: Revision::new(u64::MAX),
            selection: None,
        };
        assert_eq!(words_of(&inverted_words(&last)), [u64::MAX, 0]);
    }

    #[test]
    fn an_inverted_result_with_a_selection_is_its_revision_a_one_and_the_selections_words() {
        let shapes = [
            (EXCLUSIVE, Shape::Exclusive),
            (INCLUSIVE, Shape::Inclusive),
            (LINE, Shape::Line),
            (BLOCK, Shape::Block),
        ];
        for (word, shape) in shapes {
            let selection = shaped(shape, &[(21, 25), (30, 31), (9, 4)], 1);
            // The order of the ranges, their merging and the primary's
            // index are the text's rules: what is written is what the
            // selection holds, whatever that is.
            let mut expected = vec![
                7,
                1,
                word,
                selection.primary() as u64,
                selection.ranges().len() as u64,
            ];
            for range in selection.ranges() {
                expected.extend([range.anchor as u64, range.head as u64]);
            }
            let inverted = Inverted {
                revision: Revision::new(7),
                selection: Some(selection),
            };

            assert_eq!(words_of(&inverted_words(&inverted)), expected, "{shape:?}");
        }
    }

    #[test]
    fn each_refusal_of_an_inverse_is_its_status() {
        assert_eq!(
            InverseStatus::of(InverseError::UnknownRevision),
            InverseStatus::UnknownRevision
        );
        assert_eq!(
            InverseStatus::of(InverseError::NotKept),
            InverseStatus::NotKept
        );
        assert_eq!(
            InverseStatus::of(InverseError::NotInState),
            InverseStatus::NotInState
        );
        // The numbers the glue and Lean read.
        assert_eq!(InverseStatus::Done as u64, 0);
        assert_eq!(InverseStatus::UnknownRevision as u64, 1);
        assert_eq!(InverseStatus::NotKept as u64, 2);
        assert_eq!(InverseStatus::NotInState as u64, 3);
    }

    /// Two transactions for a text holding [`TEXT`], to apply in order,
    /// each with a selection before it and one after it: "é" becomes "e",
    /// and "!" is added at the end.
    fn two_transactions() -> [Transaction; 2] {
        let first = ChangeSet::replacing(13, 1..3, "e").expect("a range in order");
        let second = ChangeSet::replacing(12, 12..12, "!").expect("a range in order");
        [
            Transaction::new(first)
                .with_before(shaped(Shape::Line, &[(1, 3)], 0))
                .with_after(shaped(Shape::Block, &[(2, 1)], 0)),
            Transaction::new(second)
                .with_before(shaped(Shape::Exclusive, &[(12, 12)], 0))
                .with_after(shaped(Shape::Inclusive, &[(13, 0)], 0)),
        ]
    }

    /// A document and a text that hold the same string and were given the
    /// same two transactions.
    fn document_and_text() -> (Document, Text) {
        let (document, mut text) = (Document::new(TEXT), Text::from(TEXT));
        for transaction in two_transactions() {
            let of_document = document.apply(&transaction, Origin::new(1));
            assert_eq!(of_document, text.apply(&transaction, Origin::new(1)));
            assert!(of_document.is_ok());
        }
        (document, text)
    }

    /// Checks that `document` holds what `text` holds, at its revision,
    /// with the same origin on its newest entry.
    fn assert_same(document: &Document, text: &Text) {
        assert_eq!(document.read(), text.current().to_string());
        let revision = text.current().revision();
        assert_eq!(document.snapshot().revision(), revision);
        let origin = |text: &Text| text.entry(revision).map(|entry| entry.origin());
        assert_eq!(origin(&document.lock()), origin(text));
    }

    #[test]
    fn a_document_applies_the_inverse_of_a_run_as_its_text_does() {
        let (document, mut text) = document_and_text();
        let run = |first, last| (Revision::new(first), Revision::new(last), Origin::new(9));

        // Accepted, with a selection handed back; then its own inverse.
        for (first, last) in [(1, 2), (3, 3)] {
            let (first, last, origin) = run(first, last);
            let of_text = text.apply_inverse(first, last, origin);
            assert!(of_text.is_ok(), "{of_text:?}");
            assert_eq!(document.apply_inverse(first, last, origin), of_text);
            assert_same(&document, &text);
        }
        // Each refusal is the text's, and changes nothing.
        for (first, last) in [(1, 9), (0, 1), (1, 1)] {
            let (first, last, origin) = run(first, last);
            let of_text = text.apply_inverse(first, last, origin);
            assert!(of_text.is_err(), "{of_text:?}");
            assert_eq!(document.apply_inverse(first, last, origin), of_text);
            assert_same(&document, &text);
        }
    }

    #[test]
    fn a_document_drops_kept_inverses_as_its_text_does() {
        let (document, mut text) = document_and_text();
        let run = |first, last| (Revision::new(first), Revision::new(last));

        // A drop past the text's revision, and one the text makes.
        for (first, last) in [(1, 9), (1, 1)] {
            let (first, last) = run(first, last);
            assert_eq!(
                document.drop_inverses(first, last),
                text.drop_inverses(first, last)
            );
        }
        // What was dropped is refused by both, and what was not is applied
        // by both.
        for (first, last) in [(1, 2), (2, 2)] {
            let (first, last) = run(first, last);
            assert_eq!(
                document.apply_inverse(first, last, Origin::new(9)),
                text.apply_inverse(first, last, Origin::new(9))
            );
            assert_same(&document, &text);
        }
    }
}
