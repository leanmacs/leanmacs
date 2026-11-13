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
    /// A [`LogStatus`], as its number.
    pub status: u64,
    /// The words: a buffer of `len` bytes, owned by the caller until it is
    /// handed back with
    /// [`editor_ffi_text_free`](crate::text::editor_ffi_text_free). Empty
    /// unless the status is [`LogStatus::Answered`].
    pub words: *mut u8,
    /// The length of `words` in bytes.
    pub len: usize,
}

impl RawWords {
    /// The record for `status` with `words` as its answer.
    fn new(status: LogStatus, words: Vec<u8>) -> Self {
        let (words, len) = words::lend(words);
        Self {
            status: status as u64,
            words,
            len,
        }
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
    use editor_text::Origin;

    use super::*;
    use crate::transaction::ApplyStatus;
    use crate::words::tests::{buffer, words_of};

    /// A document made as "ab\ncd" and changed twice: "X\n" is inserted at
    /// the start with the origin 7, and "d" is deleted with the origin 9.
    /// It holds "X\nab\nc".
    fn changed_twice() -> Document {
        let document = Document::new("ab\ncd");
        let inserted = buffer(&[2, 2, 2, 0, 5, 0, 0]);
        let deleted = buffer(&[2, 0, 6, 1, 1, 0, 0]);
        let applied = ApplyStatus::Applied as u64;
        assert_eq!(document.apply_words(&inserted, b"X\n", 7).status, applied);
        assert_eq!(document.apply_words(&deleted, b"", 9).status, applied);
        assert_eq!(document.read(), "X\nab\nc");
        document
    }

    #[test]
    fn a_patch_is_written_as_its_revisions_and_twelve_words_an_edit() {
        let document = changed_twice();

        let patch = document.changes_since(Revision::new(0));

        let patch = patch.expect("a revision the text reached");
        assert_eq!(
            words_of(&patch_words(&patch)),
            [
                // From revision 0 to revision 2, two edits.
                0, 2, 2, // Nothing at 0 became "X\n": rows 0 to 1.
                0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 1, 0,
                // "d", at 4 on row 1, became nothing, at 6 on row 2.
                4, 5, 1, 1, 1, 2, 6, 6, 2, 1, 2, 1,
            ]
        );
    }

    #[test]
    fn an_empty_patch_is_its_revisions_and_no_edit() {
        let document = changed_twice();

        let patch = document.changes_since(Revision::new(2));

        let patch = patch.expect("the current revision");
        assert_eq!(words_of(&patch_words(&patch)), [2, 2, 0]);
    }

    #[test]
    fn a_trace_is_written_as_five_words_a_piece() {
        let document = changed_twice();

        let trace = document.trace(0..6).expect("the whole text");

        assert_eq!(
            words_of(&trace_words(&trace)),
            [
                2, // "X\n": written by revision 1 with the origin 7.
                0, 2, 1, 1, 7, // The rest was there at revision 0.
                2, 6, 0, 0, 0,
            ]
        );
        assert_eq!(words_of(&trace_words(&[])), [0]);
    }

    #[test]
    fn the_handle_forwards_what_changed_and_its_refusals() {
        let document = changed_twice();

        assert_eq!(
            document.changes_since(Revision::new(3)),
            Err(LogError::Unknown)
        );
        let since_one = document.changes_since(Revision::new(1));
        assert_eq!(since_one.map(|patch| patch.edits.len()), Ok(1));
    }

    #[test]
    fn the_handle_forwards_a_trace_and_its_refusal() {
        let document = changed_twice();

        // Backwards, and past the end.
        #[expect(clippy::reversed_empty_ranges)]
        let backwards = document.trace(3..1);
        assert_eq!(backwards, None);
        assert_eq!(document.trace(0..7), None);
        let trace = document.trace(1..3).expect("two positions in order");
        assert_eq!(
            trace,
            [
                Attribution {
                    range: 1..2,
                    source: Source::Entry {
                        revision: Revision::new(1),
                        origin: Origin::new(7),
                    },
                },
                Attribution {
                    range: 2..3,
                    source: Source::Earlier(Revision::new(0)),
                },
            ]
        );
    }

    #[test]
    fn the_handle_forwards_forgetting_and_its_refusal() {
        let document = changed_twice();

        assert_eq!(document.forget(Revision::new(3)), Err(LogError::Unknown));
        assert_eq!(document.forget(Revision::new(1)), Ok(()));

        assert_eq!(
            document.changes_since(Revision::new(0)),
            Err(LogError::Forgotten)
        );
        assert!(document.changes_since(Revision::new(1)).is_ok());
        assert_eq!(document.read(), "X\nab\nc");
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
