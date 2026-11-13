//! A document: the text of the text-storage crate behind a handle, and the
//! second example of a handle.
//!
//! [`editor_text::Text`] has one writer and holds no lock. Lean shares a
//! handle between threads, so a document is that text behind a lock: the
//! one writer is whoever holds it. What an edit means, when it is refused
//! and what a position is are the text's rules, pinned by `editor-text`'s
//! own tests; this module forwards. A reader that must not wait for the
//! lock, or that reads more than once and wants one state of the text,
//! takes a snapshot ([`crate::snapshot`]).
//!
//! A document's other methods are beside what they carry across the
//! boundary: applying a transaction in [`crate::transaction`], the reads
//! of the edit log and forgetting in [`crate::log`], its markers in
//! [`crate::marker`], and applying the inverse of a run of revisions and
//! dropping kept inverses in [`crate::inverse`]. A replace made here is a
//! transaction too, recorded in the log with the text's default origin,
//! and its inverse is kept like any other's.
//!
//! The editor reaches a document only through the text port's real binding
//! (`lean/Editor/Text/Real.lean`).

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard, PoisonError};

use editor_text::Text;

use crate::text;

/// Text that can be edited in place. Lean shares a handle between threads,
/// so every method takes `&self` and the type is `Send + Sync`.
pub struct Document {
    /// The text. An edit holds the lock from its check to its change, so
    /// edits from several threads apply one after another.
    text: Mutex<Text>,
}

impl Document {
    /// A document holding `text`.
    pub fn new(text: &str) -> Self {
        Self {
            text: Mutex::new(Text::from(text)),
        }
    }

    /// Replaces the bytes from `start` up to, not including, `end` with
    /// `text`, and returns whether it did. An empty range inserts, and an
    /// empty `text` deletes.
    ///
    /// Returns false, changing nothing, when the text refuses the edit
    /// ([`Text::replace`]): unless both offsets are character boundaries of
    /// the document's text, within it, and `start <= end`.
    pub fn replace(&self, start: usize, end: usize, text: &str) -> bool {
        self.lock().replace(start..end, text).is_ok()
    }

    /// A copy of the whole text.
    pub fn read(&self) -> String {
        self.lock().current().to_string()
    }

    /// The text as it is now, to keep: later edits to the document do not
    /// change it. It copies none of the text, so the lock is held only for
    /// a moment.
    pub fn snapshot(&self) -> editor_text::Snapshot {
        self.lock().snapshot()
    }

    /// The text, locked. An edit is all or nothing, so a panic while the
    /// lock was held cannot leave the text half-edited, and a poisoned lock
    /// is used as it is.
    pub(crate) fn lock(&self) -> MutexGuard<'_, Text> {
        self.text.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// How many documents [`editor_ffi_document_new`] has handed out that
/// [`editor_ffi_document_free`] has not taken back.
static LIVE: AtomicU64 = AtomicU64::new(0);

/// A new document holding the `len` bytes at `text`, owned by the caller,
/// who must hand it to [`editor_ffi_document_free`] exactly once.
///
/// `text` is expected to be UTF-8, as a Lean string is. Text that is not is
/// still accepted: the document holds U+FFFD in place of each invalid
/// sequence, so its byte offsets are those of that text, not of the bytes
/// passed in.
///
/// # Safety
///
/// `text` points to `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_document_new(text: *const u8, len: usize) -> *mut Document {
    // SAFETY: the caller guarantees the pointer and the length.
    let text = unsafe { text::borrow(text, len) };
    LIVE.fetch_add(1, Ordering::Relaxed);
    Box::into_raw(Box::new(Document::new(&text)))
}

/// [`Document::replace`] for C: replaces the bytes of `document` from
/// `start` up to, not including, `end` with the `len` bytes at `text`, and
/// returns whether it did. False, with nothing changed, is the refusal.
///
/// `text` that is not UTF-8 is read as [`editor_ffi_document_new`] reads it.
///
/// # Safety
///
/// `document` came from [`editor_ffi_document_new`] and has not been freed,
/// and `text` points to `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_document_replace(
    document: *const Document,
    start: usize,
    end: usize,
    text: *const u8,
    len: usize,
) -> bool {
    // SAFETY: the caller guarantees the pointer and the length.
    let text = unsafe { text::borrow(text, len) };
    // SAFETY: the caller guarantees `document` points to a live document.
    unsafe { &*document }.replace(start, end, &text)
}

/// A document's text as it crosses the boundary: one record, filled in one
/// call.
#[repr(C)]
pub struct RawText {
    /// The text: a buffer of `text_len` bytes of UTF-8, owned by the caller
    /// until it is handed back with [`text::editor_ffi_text_free`].
    pub text: *mut u8,
    /// The length of `text` in bytes.
    pub text_len: usize,
}

/// [`Document::read`] for C: fills `out` with a copy of the whole text of
/// `document`.
///
/// # Safety
///
/// `document` came from [`editor_ffi_document_new`] and has not been freed,
/// and `out` points to a writable [`RawText`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_document_read(document: *const Document, out: *mut RawText) {
    // SAFETY: the caller guarantees `document` points to a live document.
    let (text, text_len) = text::lend(unsafe { &*document }.read());
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(RawText { text, text_len }) };
}

/// Frees `document`.
///
/// # Safety
///
/// `document` came from [`editor_ffi_document_new`], has not been freed, and
/// is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_document_free(document: *mut Document) {
    // SAFETY: the caller guarantees `document` is a box
    // `editor_ffi_document_new` gave up, taken back this once.
    drop(unsafe { Box::from_raw(document) });
    LIVE.fetch_sub(1, Ordering::Relaxed);
}

/// How many documents [`editor_ffi_document_new`] has made that have not
/// been freed. This is what makes a handle's finaliser, and the lifetime of
/// the editor's table of texts, observable to a test.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_document_live() -> u64 {
    LIVE.load(Ordering::Relaxed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    /// "é" and "ö" are two bytes each, so byte offsets and character counts
    /// differ from the second character on: in "héllo" the offsets 0, 1, 3,
    /// 4, 5 and 6 are character boundaries, and 2 is inside "é".
    const TEXT: &str = "héllo wörld";

    #[test]
    fn a_document_reads_back_its_initial_text() {
        assert_eq!(Document::new(TEXT).read(), TEXT);
        assert_eq!(Document::new("").read(), "");
    }

    #[test]
    fn a_replace_the_text_accepts_changes_the_document_and_returns_true() {
        let document = Document::new(TEXT);

        assert!(document.replace(7, 13, "there"));
        assert_eq!(document.read(), "héllo there");
    }

    #[test]
    fn a_replace_the_text_refuses_returns_false_and_changes_nothing() {
        let document = Document::new(TEXT);

        // An offset inside "é": which ranges are refused is the text's
        // rule, and its own tests pin it.
        assert!(!document.replace(2, 2, "x"));
        assert_eq!(document.read(), TEXT);
    }

    #[test]
    fn a_snapshot_of_a_document_is_its_text_as_it_is_now() {
        let document = Document::new(TEXT);
        assert!(document.replace(0, 1, "J"));

        let snapshot = document.snapshot();
        assert!(document.replace(0, 1, ""));

        assert_eq!(snapshot.to_string(), "Jéllo wörld");
        assert_eq!(document.read(), "éllo wörld");
    }

    #[test]
    fn edits_made_from_several_threads_all_land() {
        const THREADS: usize = 4;
        const EDITS: usize = 250;
        let document = Document::new(TEXT);

        thread::scope(|scope| {
            for _ in 0..THREADS {
                scope.spawn(|| {
                    for _ in 0..EDITS {
                        assert!(document.replace(0, 0, "é"));
                    }
                });
            }
        });

        let expected = "é".repeat(THREADS * EDITS) + TEXT;
        assert_eq!(document.read(), expected);
    }
}
