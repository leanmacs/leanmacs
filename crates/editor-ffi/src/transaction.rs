//! A transaction as it crosses the boundary, and applying one to a
//! document.
//!
//! Lean builds a transaction as plain data and applies it with one call.
//! The call takes it as words (the private module `words`) and one string:
//!
//! - the count of changes, then two words for each: its kind (0 a retain,
//!   1 a delete, 2 an insert) and its length in bytes;
//! - for the selection before, and then again for the selection after: a
//!   presence word (0 or 1), and if it is 1 the selection's shape (0
//!   exclusive, 1 inclusive, 2 line-wise, 3 block-wise), the index of the
//!   primary range, the count of ranges, and two words for each range, its
//!   anchor and its head;
//! - `inserted`: the text of every insert, joined in order. An insert's
//!   length cuts its text from it.
//!
//! What a change set is, when it fits and what a selection's ends must be
//! are the text's rules, pinned by `editor-text`'s own tests. This module
//! reads the words and forwards.

use editor_text::{
    ApplyError, ChangeSet, Origin, Revision, Selection, SelectionRange, Shape, Transaction,
};

use crate::document::Document;
use crate::words::{Reader, Writer};

/// Why a transaction did not come out of its words.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Undecoded {
    /// The words or the inserted text could not be read: the buffer is not
    /// whole words, a count runs past it, words are left over, a kind, a
    /// presence word or a shape is unknown, the inserts' lengths do not add up to the
    /// inserted text or cut a character of it, or the text is not UTF-8.
    Unreadable,
    /// A selection has no range, or its primary names none: it is not a
    /// selection.
    NotASelection,
}

/// The transaction `words` and `inserted` spell, in the layout the module
/// docs give.
pub fn decode(words: &[u8], inserted: &[u8]) -> Result<Transaction, Undecoded> {
    // Everything is read before anything is judged, so words that cannot
    // be read are reported as that whatever else is wrong with them.
    let (changes, before, after) = read(words, inserted).ok_or(Undecoded::Unreadable)?;
    let mut transaction = Transaction::new(changes);
    if let Some(before) = before {
        transaction = transaction.with_before(before.selection()?);
    }
    if let Some(after) = after {
        transaction = transaction.with_after(after.selection()?);
    }
    Ok(transaction)
}

/// A selection as its words spell it, before it is known to be one.
pub(crate) struct SelectionWords {
    /// What the ranges cover.
    shape: Shape,
    /// The index of the primary range.
    primary: usize,
    /// The ranges.
    ranges: Vec<SelectionRange>,
}

impl SelectionWords {
    /// The selection, if the words spell one.
    pub(crate) fn selection(self) -> Result<Selection, Undecoded> {
        Selection::shaped(self.shape, self.ranges, self.primary).ok_or(Undecoded::NotASelection)
    }

    /// The next selection of `reader`, from its shape on: the shape, the
    /// index of the primary range, the count of ranges, and an anchor and
    /// a head for each. `None` when the words cannot be read.
    pub(crate) fn read(reader: &mut Reader<'_>) -> Option<Self> {
        let shape = shape_of(reader.word()?)?;
        let primary = reader.size()?;
        let mut ranges = Vec::new();
        for _ in 0..reader.count(2)? {
            ranges.push(SelectionRange::new(reader.size()?, reader.size()?));
        }
        Some(Self {
            shape,
            primary,
            ranges,
        })
    }

    /// How many words [`write`](Self::write) adds for `selection`.
    pub(crate) fn len(selection: &Selection) -> usize {
        3 + 2 * selection.ranges().len()
    }

    /// Adds the words of `selection` to `writer`, as [`read`](Self::read)
    /// reads them: its shape, the index of its primary range, the count of
    /// its ranges, and an anchor and a head for each. This is the one
    /// place a selection's words are written.
    pub(crate) fn write(writer: &mut Writer, selection: &Selection) {
        let ranges = selection.ranges();
        writer.word(shape_word(selection.shape()));
        writer.size(selection.primary());
        writer.size(ranges.len());
        for range in ranges {
            writer.size(range.anchor);
            writer.size(range.head);
        }
    }
}

/// The shape `word` stands for: 0 exclusive, 1 inclusive, 2 line-wise, 3
/// block-wise. `None` for any other word.
pub(crate) fn shape_of(word: u64) -> Option<Shape> {
    match word {
        0 => Some(Shape::Exclusive),
        1 => Some(Shape::Inclusive),
        2 => Some(Shape::Line),
        3 => Some(Shape::Block),
        _ => None,
    }
}

/// The word that stands for `shape`, as [`shape_of`] reads it. Every shape
/// must cross, so this names every one: a new shape must be given a word
/// here, and in [`shape_of`], before it can.
fn shape_word(shape: Shape) -> u64 {
    match shape {
        Shape::Exclusive => 0,
        Shape::Inclusive => 1,
        Shape::Line => 2,
        Shape::Block => 3,
    }
}

/// The change set and the two selections `words` and `inserted` spell.
/// `None` when they cannot be read.
fn read(
    words: &[u8],
    inserted: &[u8],
) -> Option<(ChangeSet, Option<SelectionWords>, Option<SelectionWords>)> {
    let mut reader = Reader::new(words)?;
    // What is left of the inserted text for the inserts still to come.
    let mut inserted = str::from_utf8(inserted).ok()?;
    let mut changes = ChangeSet::new();
    for _ in 0..reader.count(2)? {
        let (kind, len) = (reader.word()?, reader.size()?);
        match kind {
            0 => changes.retain(len),
            1 => changes.delete(len),
            2 => {
                let (text, rest) = inserted.split_at_checked(len)?;
                changes.insert(text);
                inserted = rest;
            }
            _ => return None,
        }
    }
    if !inserted.is_empty() {
        return None;
    }
    let before = read_selection(&mut reader)?;
    let after = read_selection(&mut reader)?;
    reader.finish()?;
    Some((changes, before, after))
}

/// The next selection block of `reader`: nothing when its presence word is
/// 0. The outer `None` is a block that cannot be read.
fn read_selection(reader: &mut Reader<'_>) -> Option<Option<SelectionWords>> {
    match reader.word()? {
        0 => Some(None),
        1 => Some(Some(SelectionWords::read(reader)?)),
        _ => None,
    }
}

/// How applying a transaction ended, as it crosses the boundary: the
/// `status` of a [`RawApplied`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApplyStatus {
    /// Applied. The record's `revision` is the revision it produced.
    Applied = 0,
    /// Refused: the change set does not fit the text.
    BadChange = 1,
    /// Refused: a selection is not one, or an end of one is not a position
    /// of its text.
    BadSelection = 2,
    /// Refused: the words could not be read.
    Unreadable = 3,
}

/// The result of applying a transaction: one record, filled in one call.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RawApplied {
    /// An [`ApplyStatus`], as its number.
    pub status: u64,
    /// The revision the transaction produced. 0 unless it was applied.
    pub revision: u64,
}

impl Document {
    /// Applies the transaction `words` and `inserted` spell
    /// ([`decode`]), recording `origin` as who made the edit, and says how
    /// it ended. Anything but [`ApplyStatus::Applied`] changed nothing.
    ///
    /// A selection that is not one is refused before the change set is
    /// looked at; after that the order is the text's
    /// ([`editor_text::Text::apply`]).
    pub fn apply_words(&self, words: &[u8], inserted: &[u8], origin: u64) -> RawApplied {
        let applied = decode(words, inserted)
            .map_err(|undecoded| match undecoded {
                Undecoded::Unreadable => ApplyStatus::Unreadable,
                Undecoded::NotASelection => ApplyStatus::BadSelection,
            })
            .and_then(|transaction| {
                self.apply(&transaction, Origin::new(origin))
                    .map_err(|refused| match refused {
                        ApplyError::BadChange => ApplyStatus::BadChange,
                        ApplyError::BadSelection => ApplyStatus::BadSelection,
                    })
            });
        match applied {
            Ok(revision) => RawApplied {
                status: ApplyStatus::Applied as u64,
                revision: revision.get(),
            },
            Err(status) => RawApplied {
                status: status as u64,
                revision: 0,
            },
        }
    }

    /// Applies `transaction`, recording `origin` as who made the edit, and
    /// returns the revision it produced ([`editor_text::Text::apply`]). A
    /// refused transaction changes nothing.
    pub fn apply(&self, transaction: &Transaction, origin: Origin) -> Result<Revision, ApplyError> {
        self.lock().apply(transaction, origin)
    }
}

/// [`Document::apply_words`] for C: applies to `document` the transaction
/// spelled by the `words_len` bytes at `words` and the `inserted_len` bytes
/// at `inserted`, with `origin`, and fills `out`.
///
/// # Safety
///
/// `document` is a document handle this library handed out and has not
/// taken back ([`crate::document`] lists what hands one out);
/// `words` points to `words_len` readable bytes and `inserted` to
/// `inserted_len`; and `out` points to a writable [`RawApplied`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_document_apply(
    document: *const Document,
    words: *const u8,
    words_len: usize,
    inserted: *const u8,
    inserted_len: usize,
    origin: u64,
    out: *mut RawApplied,
) {
    // SAFETY: the caller guarantees both pointers and lengths.
    let (words, inserted) = unsafe {
        (
            crate::words::borrow(words, words_len),
            crate::words::borrow(inserted, inserted_len),
        )
    };
    // SAFETY: the caller guarantees `document` points to a live document.
    let applied = unsafe { &*document }.apply_words(words, inserted, origin);
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(applied) };
}

#[cfg(test)]
mod tests {
    use std::thread;

    use editor_text::{Change, Source};

    use super::*;
    use crate::words::tests::buffer;

    /// The kinds of a change, as words.
    const RETAIN: u64 = 0;
    const DELETE: u64 = 1;
    const INSERT: u64 = 2;

    /// "é" and "ö" are two bytes each: in "héllo wörld" the offset 2 is
    /// inside "é". The text is 13 bytes.
    const TEXT: &str = "héllo wörld";

    /// The change set of `changes`.
    fn set(changes: &[Change]) -> ChangeSet {
        changes.iter().cloned().collect()
    }

    /// The shapes of a selection, as words.
    const EXCLUSIVE: u64 = 0;
    const INCLUSIVE: u64 = 1;
    const LINE: u64 = 2;
    const BLOCK: u64 = 3;

    /// An exclusive selection of the ranges `ranges`, each an anchor and a
    /// head.
    fn selection(ranges: &[(usize, usize)], primary: usize) -> Selection {
        shaped(Shape::Exclusive, ranges, primary)
    }

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
    fn a_buffer_decodes_to_the_transaction_it_spells() {
        let words = buffer(&[
            // Four changes.
            4, RETAIN, 1, DELETE, 2, INSERT, 5, RETAIN, 10,
            // A selection before: exclusive, and the primary is the second
            // of two ranges.
            1, EXCLUSIVE, 1, 2, 0, 3, 13, 1, // A selection after: line-wise, one range.
            1, LINE, 0, 1, 14, 14,
        ]);

        let transaction = decode(&words, "e😀".as_bytes());

        assert_eq!(
            transaction,
            Ok(Transaction::new(set(&[
                Change::Retain(1),
                Change::Delete(2),
                Change::Insert("e😀".to_owned()),
                Change::Retain(10),
            ]))
            .with_before(selection(&[(0, 3), (13, 1)], 1))
            .with_after(shaped(Shape::Line, &[(14, 14)], 0)))
        );
    }

    #[test]
    fn the_shape_word_of_a_selection_is_its_shape() {
        let shapes = [
            (EXCLUSIVE, Shape::Exclusive),
            (INCLUSIVE, Shape::Inclusive),
            (LINE, Shape::Line),
            (BLOCK, Shape::Block),
        ];
        for (word, shape) in shapes {
            // Before and after, each with the one range from 2 to 5.
            let words = buffer(&[0, 1, word, 0, 1, 2, 5, 1, word, 0, 1, 5, 2]);

            assert_eq!(
                decode(&words, b""),
                Ok(Transaction::new(ChangeSet::new())
                    .with_before(shaped(shape, &[(2, 5)], 0))
                    .with_after(shaped(shape, &[(5, 2)], 0))),
                "{shape:?}"
            );
        }
    }

    #[test]
    fn a_shape_word_that_names_no_shape_is_unreadable() {
        for word in [4, 5, u64::MAX] {
            assert_eq!(
                decode(&buffer(&[0, 1, word, 0, 1, 2, 5, 0]), b""),
                Err(Undecoded::Unreadable),
                "{word}"
            );
            // Unreadable, whatever else is wrong with the selection.
            assert_eq!(
                decode(&buffer(&[0, 0, 1, word, 0, 0]), b""),
                Err(Undecoded::Unreadable),
                "{word}"
            );
        }
    }

    #[test]
    fn each_insert_takes_its_length_of_the_inserted_text_in_order() {
        let words = buffer(&[3, INSERT, 2, RETAIN, 4, INSERT, 5, 0, 0]);

        let transaction = decode(&words, "éhello".as_bytes());

        assert_eq!(
            transaction,
            Ok(Transaction::new(set(&[
                Change::Insert("é".to_owned()),
                Change::Retain(4),
                Change::Insert("hello".to_owned()),
            ])))
        );
    }

    #[test]
    fn no_change_and_no_selection_is_the_empty_transaction() {
        assert_eq!(
            decode(&buffer(&[0, 0, 0]), b""),
            Ok(Transaction::new(ChangeSet::new()))
        );
    }

    #[test]
    fn a_length_no_size_holds_is_the_largest_size_and_not_cut_down() {
        let words = buffer(&[1, RETAIN, u64::MAX, 1, EXCLUSIVE, 0, 1, u64::MAX, 0, 0]);

        let transaction = decode(&words, b"").expect("words that can be read");

        assert_eq!(transaction.changes().len_before(), usize::MAX);
        assert_eq!(
            transaction.before(),
            Some(&selection(&[(usize::MAX, 0)], 0))
        );
    }

    #[test]
    fn words_that_cannot_be_read_are_unreadable() {
        let unreadable = |words: &[u64], inserted: &str| {
            assert_eq!(
                decode(&buffer(words), inserted.as_bytes()),
                Err(Undecoded::Unreadable),
                "{words:?} with {inserted:?}"
            );
        };

        // Nothing at all, and a buffer that stops before the selections.
        unreadable(&[], "");
        unreadable(&[0], "");
        unreadable(&[0, 0], "");
        // A count of changes that runs past the buffer.
        unreadable(&[2, RETAIN, 1, 0, 0], "");
        unreadable(&[u64::MAX, RETAIN, 1, 0, 0], "");
        // A kind that is none.
        unreadable(&[1, 3, 1, 0, 0], "");
        // A presence word that is neither 0 nor 1.
        unreadable(&[0, 2, 0], "");
        unreadable(&[0, 0, 2], "");
        // A count of ranges that runs past the buffer.
        unreadable(&[0, 1, EXCLUSIVE, 0, 2, 0, 0, 0], "");
        // A selection that stops after its presence word, or its shape.
        unreadable(&[0, 0, 1], "");
        unreadable(&[0, 0, 1, EXCLUSIVE], "");
        // Words left over.
        unreadable(&[0, 0, 0, 0], "");
        unreadable(&[1, RETAIN, 1, 0, 0, 7], "");
    }

    #[test]
    fn insert_lengths_that_do_not_add_up_to_the_inserted_text_are_unreadable() {
        let unreadable = |words: &[u64], inserted: &str| {
            assert_eq!(
                decode(&buffer(words), inserted.as_bytes()),
                Err(Undecoded::Unreadable),
                "{words:?} with {inserted:?}"
            );
        };

        // Too short, too long, and text with no insert to take it.
        unreadable(&[1, INSERT, 2, 0, 0], "abc");
        unreadable(&[1, INSERT, 4, 0, 0], "abc");
        unreadable(&[2, INSERT, 2, INSERT, 2, 0, 0], "abc");
        unreadable(&[1, RETAIN, 3, 0, 0], "abc");
        unreadable(&[1, INSERT, u64::MAX, 0, 0], "abc");
    }

    #[test]
    fn an_insert_length_that_cuts_a_character_is_unreadable() {
        // "é" is two bytes: the first insert would end inside it.
        let words = buffer(&[2, INSERT, 1, INSERT, 1, 0, 0]);

        assert_eq!(decode(&words, "é".as_bytes()), Err(Undecoded::Unreadable));
    }

    #[test]
    fn inserted_text_that_is_not_utf8_is_unreadable() {
        let words = buffer(&[1, INSERT, 2, 0, 0]);

        assert_eq!(decode(&words, &[0xC3, 0x28]), Err(Undecoded::Unreadable));
    }

    #[test]
    fn a_selection_with_no_range_or_whose_primary_names_none_is_not_a_selection() {
        // Before: present, primary 0, no range.
        assert_eq!(
            decode(&buffer(&[0, 1, EXCLUSIVE, 0, 0, 0]), b""),
            Err(Undecoded::NotASelection)
        );
        // After: present, primary 1, one range.
        assert_eq!(
            decode(&buffer(&[0, 0, 1, BLOCK, 1, 1, 0, 0]), b""),
            Err(Undecoded::NotASelection)
        );
        assert_eq!(
            decode(&buffer(&[0, 0, 1, INCLUSIVE, u64::MAX, 1, 0, 0]), b""),
            Err(Undecoded::NotASelection)
        );
    }

    /// The record for a transaction that was applied and produced
    /// `revision`.
    fn applied(revision: u64) -> RawApplied {
        RawApplied {
            status: ApplyStatus::Applied as u64,
            revision,
        }
    }

    /// The record for a transaction that ended as `status`, which is not
    /// applied.
    fn refused(status: ApplyStatus) -> RawApplied {
        RawApplied {
            status: status as u64,
            revision: 0,
        }
    }

    #[test]
    fn a_transaction_the_text_accepts_changes_the_document_and_reports_its_revision() {
        let document = Document::new(TEXT);
        // "é" becomes "e", and "!" is added at the end.
        let words = buffer(&[
            5, RETAIN, 1, DELETE, 2, INSERT, 1, RETAIN, 10, INSERT, 1, 0, 1, INCLUSIVE, 0, 1, 13,
            13,
        ]);

        // Which revision a transaction produces is the text's rule: the
        // one reported is the one the document is at once it is applied.
        let first = document.apply_words(&words, b"e!", 7);
        assert_eq!(first, applied(document.snapshot().revision().get()));
        assert_eq!(document.read(), "hello wörld!");
        let second = document.apply_words(&buffer(&[1, RETAIN, 13, 0, 0]), b"", 7);
        assert_eq!(second, applied(document.snapshot().revision().get()));
    }

    #[test]
    fn each_refusal_is_reported_as_its_status_and_changes_nothing() {
        let document = Document::new(TEXT);
        let before = document.snapshot().revision();
        let short = buffer(&[1, RETAIN, 12, 0, 0]);
        let inside = buffer(&[1, RETAIN, 13, 1, EXCLUSIVE, 0, 1, 2, 2, 0]);
        let no_range = buffer(&[1, RETAIN, 13, 1, LINE, 0, 0, 0]);
        let unknown_kind = buffer(&[1, 9, 13, 0, 0]);
        let unknown_shape = buffer(&[1, RETAIN, 13, 1, 4, 0, 1, 0, 0, 0]);

        assert_eq!(
            document.apply_words(&short, b"", 1),
            refused(ApplyStatus::BadChange)
        );
        assert_eq!(
            document.apply_words(&inside, b"", 1),
            refused(ApplyStatus::BadSelection)
        );
        assert_eq!(
            document.apply_words(&no_range, b"", 1),
            refused(ApplyStatus::BadSelection)
        );
        assert_eq!(
            document.apply_words(&unknown_kind, b"", 1),
            refused(ApplyStatus::Unreadable)
        );
        assert_eq!(
            document.apply_words(&unknown_shape, b"", 1),
            refused(ApplyStatus::Unreadable)
        );
        assert_eq!(document.read(), TEXT);
        assert_eq!(document.snapshot().revision(), before);
    }

    #[test]
    fn a_selection_that_is_none_is_refused_before_the_change_set_is_looked_at() {
        let document = Document::new(TEXT);
        // The change set stops short, and the selection after has no range.
        let both = buffer(&[1, RETAIN, 12, 0, 1, EXCLUSIVE, 0, 0]);

        assert_eq!(
            document.apply_words(&both, b"", 1),
            refused(ApplyStatus::BadSelection)
        );
    }

    #[test]
    fn the_origin_a_transaction_is_applied_with_is_recorded() {
        let document = Document::new(TEXT);
        let words = buffer(&[2, INSERT, 1, RETAIN, 13, 0, 0]);

        let result = document.apply_words(&words, b"x", u64::MAX);
        assert_eq!(result.status, ApplyStatus::Applied as u64);

        // How a trace is cut into pieces is the text's rule: the origin is
        // only looked for among the pieces of the whole text's.
        let whole = 0..document.snapshot().len();
        let trace = document.trace(whole).expect("the whole text");
        let named = trace.iter().any(|piece| {
            matches!(
                piece.source,
                Source::Entry { origin, .. } if origin == Origin::new(u64::MAX)
            )
        });
        assert!(named, "{trace:?}");
    }

    #[test]
    fn transactions_applied_from_several_threads_all_land() {
        const THREADS: usize = 4;
        const EDITS: usize = 250;
        let document = Document::new("");

        thread::scope(|scope| {
            for _ in 0..THREADS {
                scope.spawn(|| {
                    let mut landed = 0;
                    // A transaction is for one length of text, so one built
                    // for a length another thread has just changed is
                    // refused, and is built again. The tries are bounded so
                    // that a document that accepts nothing fails the test.
                    for _ in 0..EDITS * 10_000 {
                        let len = document.snapshot().len() as u64;
                        let words = buffer(&[2, INSERT, 2, RETAIN, len, 0, 0]);
                        let result = document.apply_words(&words, "é".as_bytes(), 1);
                        if result.status == ApplyStatus::Applied as u64 {
                            landed += 1;
                        }
                        if landed == EDITS {
                            break;
                        }
                    }
                    assert_eq!(landed, EDITS);
                });
            }
        });

        assert_eq!(document.read(), "é".repeat(THREADS * EDITS));
    }
}
