//! A document: text the library holds for the editor, and the second
//! example of a handle.
//!
//! This is a placeholder. It is a string behind a lock, and it stands where
//! the rope of the text-storage crate will stand, so that the Lean editor's
//! text interface has a real binding to run against before that crate
//! exists. Nothing else should grow on it.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard, PoisonError};

use crate::text;

/// Text that can be edited in place. Lean shares a handle between threads,
/// so every method takes `&self` and the type is `Send + Sync`.
pub struct Document {
    /// The text. An edit holds the lock from its check to its change, so
    /// edits from several threads apply one after another.
    text: Mutex<String>,
}

impl Document {
    /// A document holding `text`.
    pub fn new(text: &str) -> Self {
        Self {
            text: Mutex::new(text.to_owned()),
        }
    }

    /// Replaces the bytes from `start` up to, not including, `end` with
    /// `text`, and returns whether it did. An empty range inserts, and an
    /// empty `text` deletes.
    ///
    /// Returns false, changing nothing, unless both offsets are character
    /// boundaries of the document's text, within it, and `start <= end`.
    pub fn replace(&self, start: usize, end: usize, text: &str) -> bool {
        let mut current = self.lock();
        // `is_char_boundary` is false past the end, so this also keeps both
        // offsets within the text, and `replace_range` cannot panic.
        if start > end || !current.is_char_boundary(start) || !current.is_char_boundary(end) {
            return false;
        }
        current.replace_range(start..end, text);
        true
    }

    /// A copy of the whole text.
    pub fn read(&self) -> String {
        self.lock().clone()
    }

    /// The text, locked. A panic while the lock was held cannot leave the
    /// string half-edited, so a poisoned lock is used as it is.
    fn lock(&self) -> MutexGuard<'_, String> {
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
    fn replace_inserts_at_a_byte_offset_when_the_range_is_empty() {
        let document = Document::new(TEXT);

        assert!(document.replace(3, 3, "XY"));
        assert_eq!(document.read(), "héXYllo wörld");
        assert!(document.replace(0, 0, "<"));
        assert_eq!(document.read(), "<héXYllo wörld");
        assert!(document.replace(16, 16, ">"));
        assert_eq!(document.read(), "<héXYllo wörld>");
    }

    #[test]
    fn replace_deletes_its_byte_range_when_the_text_is_empty() {
        let document = Document::new(TEXT);

        assert!(document.replace(1, 3, ""));
        assert_eq!(document.read(), "hllo wörld");
        assert!(document.replace(5, 11, ""));
        assert_eq!(document.read(), "hllo ");
    }

    #[test]
    fn replace_puts_the_text_in_place_of_its_byte_range() {
        let document = Document::new(TEXT);

        assert!(document.replace(7, 13, "there"));
        assert_eq!(document.read(), "héllo there");
    }

    #[test]
    fn replace_refuses_an_offset_inside_a_character_and_changes_nothing() {
        let document = Document::new(TEXT);

        assert!(!document.replace(2, 2, "x"));
        assert!(!document.replace(0, 2, ""));
        assert!(!document.replace(2, 3, ""));
        assert_eq!(document.read(), TEXT);
    }

    #[test]
    fn replace_refuses_an_offset_past_the_end_and_changes_nothing() {
        let document = Document::new(TEXT);

        assert!(!document.replace(TEXT.len() + 1, TEXT.len() + 1, "x"));
        assert!(!document.replace(0, TEXT.len() + 1, ""));
        assert!(!document.replace(usize::MAX, usize::MAX, "x"));
        assert_eq!(document.read(), TEXT);
    }

    #[test]
    fn replace_refuses_a_backwards_range_and_changes_nothing() {
        let document = Document::new(TEXT);

        assert!(!document.replace(3, 1, "x"));
        assert_eq!(document.read(), TEXT);
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
