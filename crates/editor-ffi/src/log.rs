//! A document's edit log as it crosses the boundary: what changed since a
//! revision, who wrote a range, and forgetting.
//!
//! Each answer is a list, so it crosses as words (the private module
//! `words`) in a [`RawWords`]:
//!
//! - **a patch** ([`editor_ffi_document_changes_since`]): the revision it
//!   starts from, the revision it reaches, the count of edits, and twelve
//!   words for each edit: for its old span and then for its new one, the
//!   start offset, the end offset, the row and the column of the start,
//!   and the row and the column of the end. Columns are in bytes;
//! - **a trace** ([`editor_ffi_document_trace`]): the count of pieces, and
//!   five words for each: its start offset, its end offset, 1 if an entry
//!   of the log wrote it or 0 if it is earlier than the log reaches, the
//!   revision (of the entry, or of the horizon), and the origin (0 for an
//!   earlier piece).
//!
//! What a patch holds, what a trace names and what forgetting does are the
//! text's rules, pinned by `editor-text`'s own tests. This module forwards
//! and writes the words.

use std::ops::Range;

use editor_text::{Attribution, LogError, Patch, Revision, Source, Span};

use crate::document::Document;
use crate::words::{self, Writer};

/// How a question about the log ended, as it crosses the boundary: the
/// `status` of a [`RawWords`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogStatus {
    /// Answered. The record's words are the answer.
    Answered = 0,
    /// Refused: the text has not reached the revision.
    Unknown = 1,
    /// Refused: the revision is before the log's horizon.
    Forgotten = 2,
}

impl LogStatus {
    /// The status that reports `error`.
    const fn of(error: LogError) -> Self {
        match error {
            LogError::Unknown => Self::Unknown,
            LogError::Forgotten => Self::Forgotten,
        }
    }
}

/// An answer in words: one record, filled in one call.
#[repr(C)]
pub struct RawWords {
    /// How the question ended, as a number: 0 answered, and anything else
    /// the refusal of the function that filled the record (a
    /// [`LogStatus`] for the log's, a
    /// [`MarkStatus`](crate::marker::MarkStatus) for a marker's and for
    /// extents, an [`InverseStatus`](crate::inverse::InverseStatus) for
    /// an inverse's).
    pub status: u64,
    /// The words: a buffer of `len` bytes, owned by the caller until it is
    /// handed back with
    /// [`editor_ffi_text_free`](crate::text::editor_ffi_text_free). Empty
    /// unless the status is 0.
    pub words: *mut u8,
    /// The length of `words` in bytes.
    pub len: usize,
}

impl RawWords {
    /// The record for `status` with `words` as its answer.
    fn new(status: LogStatus, words: Vec<u8>) -> Self {
        Self::with_status(status as u64, words)
    }

    /// The record for the status `status`, as its number, with `words` as
    /// its answer.
    pub(crate) fn with_status(status: u64, words: Vec<u8>) -> Self {
        let (words, len) = words::lend(words);
        Self { status, words, len }
    }
}

/// The words of `patch`, in the layout the module docs give.
pub fn patch_words(patch: &Patch) -> Vec<u8> {
    let mut writer = Writer::with_capacity(3 + 12 * patch.edits.len());
    writer.word(patch.from.get());
    writer.word(patch.to.get());
    writer.size(patch.edits.len());
    for edit in &patch.edits {
        span_words(&mut writer, &edit.old);
        span_words(&mut writer, &edit.new);
    }
    writer.finish()
}

/// Adds the six words of `span`: its offsets, then its points.
fn span_words(writer: &mut Writer, span: &Span) {
    writer.size(span.start);
    writer.size(span.end);
    writer.size(span.start_point.row);
    writer.size(span.start_point.column);
    writer.size(span.end_point.row);
    writer.size(span.end_point.column);
}

/// The words of `trace`, in the layout the module docs give.
pub fn trace_words(trace: &[Attribution]) -> Vec<u8> {
    let mut writer = Writer::with_capacity(1 + 5 * trace.len());
    writer.size(trace.len());
    for piece in trace {
        writer.size(piece.range.start);
        writer.size(piece.range.end);
        match piece.source {
            Source::Entry { revision, origin } => {
                writer.word(1);
                writer.word(revision.get());
                writer.word(origin.get());
            }
            Source::Earlier(horizon) => {
                writer.word(0);
                writer.word(horizon.get());
                writer.word(0);
            }
        }
    }
    writer.finish()
}

impl Document {
    /// What changed in the text since the revision `since`, as one patch
    /// ([`editor_text::Text::changes_since`]).
    pub fn changes_since(&self, since: Revision) -> Result<Patch, LogError> {
        self.lock().changes_since(since)
    }

    /// Where the bytes of `range` came from ([`editor_text::Text::trace`]).
    /// `None` unless the range is two positions of the text in order.
    pub fn trace(&self, range: Range<usize>) -> Option<Vec<Attribution>> {
        self.lock().trace(range)
    }

    /// Drops the log's entries up to `through`
    /// ([`editor_text::Text::forget`]).
    pub fn forget(&self, through: Revision) -> Result<(), LogError> {
        self.lock().forget(through)
    }
}

/// [`Document::changes_since`] for C: fills `out` with the patch of what
/// changed in `document` since `revision`, as words, or with the status
/// that says why there is none.
///
/// # Safety
///
/// `document` came from [`editor_ffi_document_new`] and has not been freed,
/// and `out` points to a writable [`RawWords`].
///
/// [`editor_ffi_document_new`]: crate::document::editor_ffi_document_new
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_document_changes_since(
    document: *const Document,
    revision: u64,
    out: *mut RawWords,
) {
    // SAFETY: the caller guarantees `document` points to a live document.
    let patch = unsafe { &*document }.changes_since(Revision::new(revision));
    let raw = match patch {
        Ok(patch) => RawWords::new(LogStatus::Answered, patch_words(&patch)),
        Err(error) => RawWords::new(LogStatus::of(error), Vec::new()),
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
}

/// [`Document::trace`] for C: returns whether the bytes of `document` from
/// `start` up to, not including, `end` are a range of two positions in
/// order, and if so fills `out` with their trace, as words.
///
/// # Safety
///
/// `document` came from [`editor_ffi_document_new`] and has not been freed,
/// and `out` points to a writable [`RawWords`].
///
/// [`editor_ffi_document_new`]: crate::document::editor_ffi_document_new
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_document_trace(
    document: *const Document,
    start: usize,
    end: usize,
    out: *mut RawWords,
) -> bool {
    // SAFETY: the caller guarantees `document` points to a live document.
    let Some(trace) = unsafe { &*document }.trace(start..end) else {
        return false;
    };
    let raw = RawWords::new(LogStatus::Answered, trace_words(&trace));
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
    true
}

/// [`Document::forget`] for C: drops the entries of `document`'s log up to
/// `revision`, and returns whether it could. False, with nothing changed,
/// for a revision the text has not reached.
///
/// # Safety
///
/// `document` came from [`editor_ffi_document_new`] and has not been freed.
///
/// [`editor_ffi_document_new`]: crate::document::editor_ffi_document_new
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_document_forget(
    document: *const Document,
    revision: u64,
) -> bool {
    // SAFETY: the caller guarantees `document` points to a live document.
    unsafe { &*document }
        .forget(Revision::new(revision))
        .is_ok()
}

#[cfg(test)]
mod tests {
    use editor_text::{Change, ChangeSet, Edit, Origin, Point, Text, Transaction};

    use super::*;
    use crate::words::tests::words_of;

    /// The span from `start` to `end` whose points are `start_point` and
    /// `end_point`, each a row and a column.
    fn span(
        start: usize,
        end: usize,
        start_point: (usize, usize),
        end_point: (usize, usize),
    ) -> Span {
        Span {
            start,
            end,
            start_point: Point::new(start_point.0, start_point.1),
            end_point: Point::new(end_point.0, end_point.1),
        }
    }

    // The patches and the traces of the three tests of the layout are
    // written out here, and are not read from a text: what a text's log
    // answers is the text's rule. Their numbers are those of no text. Every
    // one is different, so that a word written in another's place shows.

    #[test]
    fn a_patch_is_written_as_its_revisions_and_twelve_words_an_edit() {
        let patch = Patch {
            from: Revision::new(3),
            to: Revision::new(8),
            edits: vec![
                Edit {
                    old: span(11, 12, (13, 14), (15, 16)),
                    new: span(21, 22, (23, 24), (25, 26)),
                },
                Edit {
                    old: span(31, 32, (33, 34), (35, 36)),
                    new: span(41, 42, (43, 44), (45, 46)),
                },
            ],
        };

        // From revision 3 to revision 8, two edits. Then each edit: its old
        // span, then its new one.
        let head: [u64; 3] = [3, 8, 2];
        let first = [11, 12, 13, 14, 15, 16, 21, 22, 23, 24, 25, 26];
        let second = [31, 32, 33, 34, 35, 36, 41, 42, 43, 44, 45, 46];
        assert_eq!(
            words_of(&patch_words(&patch)),
            [&head[..], &first, &second].concat()
        );
    }

    #[test]
    fn an_empty_patch_is_its_revisions_and_no_edit() {
        let patch = Patch {
            from: Revision::new(4),
            to: Revision::new(9),
            edits: Vec::new(),
        };

        assert_eq!(words_of(&patch_words(&patch)), [4, 9, 0]);
    }

    #[test]
    fn a_trace_is_written_as_five_words_a_piece() {
        let trace = [
            Attribution {
                range: 11..12,
                source: Source::Entry {
                    revision: Revision::new(13),
                    origin: Origin::new(14),
                },
            },
            Attribution {
                range: 21..22,
                source: Source::Earlier(Revision::new(23)),
            },
        ];

        // Two pieces. After its range, an entry's piece is 1, its revision
        // and its origin, and an earlier piece is 0, the horizon and 0.
        let count: [u64; 1] = [2];
        let written = [11, 12, 1, 13, 14];
        let earlier = [21, 22, 0, 23, 0];
        assert_eq!(
            words_of(&trace_words(&trace)),
            [&count[..], &written, &earlier].concat()
        );
        assert_eq!(words_of(&trace_words(&[])), [0]);
    }

    /// A document, and a text made as it was and changed as it was: by two
    /// transactions, each with an origin of its own.
    ///
    /// What a log answers after them is the text's rule. The tests of the
    /// handle below state none of it: they ask the document and the text
    /// the same thing and compare the two answers.
    fn changed_twice() -> (Document, Text) {
        let document = Document::new("ab\ncd");
        let mut text = Text::from("ab\ncd");
        let transactions = [
            // "X\n" is inserted at the start.
            (
                vec![Change::Insert("X\n".to_owned()), Change::Retain(5)],
                Origin::new(7),
            ),
            // "d", by then the last of 7 bytes, is deleted.
            (vec![Change::Retain(6), Change::Delete(1)], Origin::new(9)),
        ];
        for (changes, origin) in transactions {
            let changes: ChangeSet = changes.into_iter().collect();
            let transaction = Transaction::new(changes);
            let applied = text.apply(&transaction, origin);
            assert!(applied.is_ok(), "a transaction the text accepts");
            assert_eq!(document.apply(&transaction, origin), applied);
        }
        (document, text)
    }

    #[test]
    fn the_handle_answers_what_changed_as_the_text_does() {
        let (document, text) = changed_twice();

        // Since the revision the text was made at, since each of the two
        // that followed, and since one after them.
        for since in (0..=3).map(Revision::new) {
            assert_eq!(
                document.changes_since(since),
                text.changes_since(since),
                "since {since:?}"
            );
        }
    }

    #[test]
    fn the_handle_traces_a_range_as_the_text_does() {
        let (document, text) = changed_twice();
        let len = text.current().len();
        let past = len + 1;

        // The whole text, a part of it, no byte, a range that is backwards
        // and one that runs past the end.
        #[expect(clippy::reversed_empty_ranges)]
        let ranges = [0..len, 1..3, 2..2, 3..1, 0..past];
        for range in ranges {
            assert_eq!(
                document.trace(range.clone()),
                text.trace(range.clone()),
                "{range:?}"
            );
        }
    }

    #[test]
    fn the_handle_forgets_as_the_text_does() {
        let (document, mut text) = changed_twice();

        // Through a revision after the two transactions, then through the
        // first of them.
        for through in [3, 1].map(Revision::new) {
            assert_eq!(
                document.forget(through),
                text.forget(through),
                "through {through:?}"
            );
        }

        // What each forgot shows in what its log answers afterwards.
        for since in (0..=2).map(Revision::new) {
            assert_eq!(
                document.changes_since(since),
                text.changes_since(since),
                "since {since:?}"
            );
        }
        let whole = 0..text.current().len();
        assert_eq!(document.trace(whole.clone()), text.trace(whole));
        assert_eq!(document.read(), text.current().to_string());
    }

    #[test]
    fn each_refusal_of_the_log_has_its_status() {
        assert_eq!(LogStatus::of(LogError::Unknown), LogStatus::Unknown);
        assert_eq!(LogStatus::of(LogError::Forgotten), LogStatus::Forgotten);
        assert_eq!(LogStatus::Answered as u64, 0);
        assert_eq!(LogStatus::Unknown as u64, 1);
        assert_eq!(LogStatus::Forgotten as u64, 2);
    }
}
