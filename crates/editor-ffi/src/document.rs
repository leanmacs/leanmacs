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
//! **What hands a document handle out.** Every `# Safety` section that
//! takes a document, here and in the modules above, asks for "a document
//! handle this library handed out and has not taken back". The functions
//! that hand one out are:
//!
//! - [`editor_ffi_document_new`], a document holding a string;
//! - [`editor_ffi_document_from_snapshot`], a document holding what a
//!   snapshot holds;
//! - [`editor_ffi_excerpts_new`](crate::excerpts::editor_ffi_excerpts_new),
//!   an excerpt document, whose text is made of ranges of other documents
//!   ([`crate::excerpts`]).
//!
//! Each counts its handle live, through the crate-private `hand_out`, and
//! [`editor_ffi_document_free`] is the one function that takes a handle
//! back.
//!
//! The editor reaches a document only through the text port's real binding
//! (`lean/Editor/Text/Real.lean`).
//!
//! Each document has a key no other document has ([`Document::key`]), and
//! its text is shared, weakly, with the snapshots taken of it
//! ([`crate::snapshot`]), so a snapshot handle is enough to reach the
//! document's log and markers while the document lives.
//!
//! **Every edit tells the syntax service.** Each path that changes the
//! text, the replace here, applying a transaction, applying an edit script
//! and applying an inverse, calls `crate::syntax::touched` with the
//! document's key and the revision the edit produced, once the edit is
//! made and the lock let go; it does nothing for a document nobody parses.
//! Freeing a document detaches it (`crate::syntax::detach`).
//!
//! **An excerpt document is caught up whenever it is locked.** Its text is
//! the assembled text of an excerpt list ([`editor_text::excerpt`]), and
//! `Document::lock` brings it up to date with its sources before it hands
//! the text out, so every path that reads it, its log or its markers sees
//! what its sources hold now. A catch-up tells the syntax service nothing:
//! an excerpt text is not parsed. Its edits are its sources' edits: a
//! replace or a transaction of it is one transaction on each source it
//! changes, and each source it changed tells the syntax service, while the
//! excerpt document itself does not. Its inverse, edit script and trace
//! are refused before the lock is taken; [`crate::excerpts`] has the
//! rules.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};

use editor_text::Text;

use crate::excerpts::Excerpted;
use crate::snapshot::Snapshot;
use crate::text;

/// Text that can be edited in place. Lean shares a handle between threads,
/// so every method takes `&self` and the type is `Send + Sync`.
pub struct Document {
    /// The text. An edit holds the lock from its check to its change, so
    /// edits from several threads apply one after another. It is shared
    /// with the snapshots taken of it only as a [`Weak`], so it is freed with
    /// the document.
    text: Arc<Mutex<Text>>,
    /// The document's key: a number no other document or snapshot of the
    /// process has ([`next_key`]). Layout keeps what it laid out of a text
    /// by it.
    key: u64,
    /// For an excerpt document, its list and its sources; `None` for any
    /// other. Its lock is taken before the text's.
    excerpts: Option<Mutex<Excerpted>>,
    /// Lives as long as the document: an excerpt document that holds this
    /// document's text as a source edits it only while this upgrades
    /// ([`alive`](Self::alive)).
    alive: Arc<()>,
}

/// How a replace ended ([`Document::replace_status`]), as it crosses the
/// boundary. Anything but [`ReplaceStatus::Done`] changed nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplaceStatus {
    /// Replaced.
    Done = 0,
    /// Refused: an offset is not a position of the text, or the start is
    /// after the end.
    BadRange = 1,
    /// Refused: the document is an excerpt document, and the range is not
    /// inside one excerpt, or meets two excerpts of one source
    /// ([`editor_text::excerpt::ExcerptError::OutsideExcerpt`]).
    OutsideExcerpt = 2,
    /// Refused: the document is an excerpt document, and the range is in an
    /// excerpt of a source that was freed.
    NoSuchSource = 3,
}

/// The next key of a text: a number given out once in the process, to a
/// document or to a snapshot no document holds.
pub(crate) fn next_key() -> u64 {
    /// The next key to give out.
    static NEXT: AtomicU64 = AtomicU64::new(0);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

impl Document {
    /// A document holding `text`.
    pub fn new(text: &str) -> Self {
        Self::over(Text::from(text))
    }

    /// A document over `text`, as it is: with its revision, its log, its
    /// markers and its kept inverses.
    pub(crate) fn over(text: Text) -> Self {
        Self {
            text: Arc::new(Mutex::new(text)),
            key: next_key(),
            excerpts: None,
            alive: Arc::new(()),
        }
    }

    /// An excerpt document with no excerpts: an empty text, at revision 0,
    /// that only its list writes.
    pub fn excerpts() -> Self {
        Self {
            text: Arc::new(Mutex::new(Text::new())),
            key: next_key(),
            excerpts: Some(Mutex::new(Excerpted::default())),
            alive: Arc::new(()),
        }
    }

    /// Whether this is an excerpt document.
    pub fn is_excerpts(&self) -> bool {
        self.excerpts.is_some()
    }

    /// The list and the sources of an excerpt document, locked; `None` for
    /// any other.
    pub(crate) fn excerpted(&self) -> Option<MutexGuard<'_, Excerpted>> {
        self.excerpts
            .as_ref()
            .map(|excerpts| excerpts.lock().unwrap_or_else(PoisonError::into_inner))
    }

    /// The text itself, to be held by an excerpt document that reads it:
    /// a strong reference, so the text outlives this document.
    pub(crate) fn text(&self) -> Arc<Mutex<Text>> {
        Arc::clone(&self.text)
    }

    /// Whether the document still lives, to be asked later without keeping
    /// it alive: an excerpt document that reads this one's text edits it
    /// only while this upgrades.
    pub(crate) fn alive(&self) -> Weak<()> {
        Arc::downgrade(&self.alive)
    }

    /// The document's key: no other document's, and no snapshot's but those
    /// taken of it.
    pub fn key(&self) -> u64 {
        self.key
    }

    /// The text, to be read later without keeping it alive: a snapshot's
    /// source.
    pub(crate) fn shared(&self) -> Weak<Mutex<Text>> {
        Arc::downgrade(&self.text)
    }

    /// Replaces the bytes from `start` up to, not including, `end` with
    /// `text`, and returns whether it did:
    /// [`replace_status`](Self::replace_status) for a Rust caller that
    /// wants only that.
    pub fn replace(&self, start: usize, end: usize, text: &str) -> bool {
        self.replace_status(start, end, text) == ReplaceStatus::Done
    }

    /// Replaces the bytes from `start` up to, not including, `end` with
    /// `text`, and says how it ended. An empty range inserts, and an empty
    /// `text` deletes. Anything but [`ReplaceStatus::Done`] changed
    /// nothing.
    ///
    /// It is the text's replace ([`Text::replace`]), refused with
    /// [`ReplaceStatus::BadRange`] unless both offsets are character
    /// boundaries of the document's text, within it, and `start <= end`.
    /// An excerpt document's is its sources' edit, recorded with the
    /// default origin as a plain replace is ([`crate::excerpts`]): after
    /// those checks, made of the text caught up, it is refused with
    /// [`ReplaceStatus::OutsideExcerpt`] or [`ReplaceStatus::NoSuchSource`].
    pub fn replace_status(&self, start: usize, end: usize, text: &str) -> ReplaceStatus {
        if self.is_excerpts() {
            return self.replace_excerpts(start, end, text);
        }
        let mut locked = self.lock();
        let replaced = locked.replace(start..end, text).is_ok();
        let revision = locked.current().revision();
        drop(locked);
        if replaced {
            crate::syntax::touched(self.key, revision);
            ReplaceStatus::Done
        } else {
            ReplaceStatus::BadRange
        }
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
    ///
    /// An excerpt document's text is caught up with its sources first, under
    /// its list's lock, the text's and its sources' in that order
    /// (`Excerpted::refresh`).
    pub(crate) fn lock(&self) -> MutexGuard<'_, Text> {
        let excerpted = self.excerpted();
        let mut text = self.text_locked();
        if let Some(mut excerpted) = excerpted {
            excerpted.refresh(&mut text);
        }
        text
    }
}

impl Document {
    /// The text, locked as it is, with no catch-up: for a caller that holds
    /// an excerpt document's list's lock and has the list catch up itself.
    pub(crate) fn text_locked(&self) -> MutexGuard<'_, Text> {
        self.text.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// An excerpt document gives up the anchors it holds in its sources when it
/// goes, under its list's lock and then its sources', the order every
/// catch-up takes them in.
impl Drop for Document {
    fn drop(&mut self) {
        if let Some(mut excerpted) = self.excerpted() {
            excerpted.release();
        }
    }
}

/// How many document handles this library has handed out (the module docs
/// list the functions that do) that [`editor_ffi_document_free`] has not
/// taken back.
static LIVE: AtomicU64 = AtomicU64::new(0);

/// Hands `document` out as a handle the caller owns, who must hand it to
/// [`editor_ffi_document_free`] exactly once, and counts it live: the one
/// place a document handle is made.
pub(crate) fn hand_out(document: Document) -> *mut Document {
    LIVE.fetch_add(1, Ordering::Relaxed);
    Box::into_raw(Box::new(document))
}

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
    hand_out(Document::new(&text))
}

/// A new document holding what `snapshot` holds, owned by the caller, who
/// must hand it to [`editor_ffi_document_free`] exactly once.
///
/// It is a text of its own ([`Text::from_snapshot`]): at revision 0, with an
/// empty log, no markers and no kept inverses, whatever the snapshot's
/// revision. It copies none of the text. An edit to it changes neither the
/// snapshot nor the document the snapshot was taken from, and it outlives
/// both. The snapshot is only read: it is still the caller's to free.
///
/// # Safety
///
/// `snapshot` is a snapshot handle this library handed out and has not
/// taken back ([`crate::snapshot`]).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_document_from_snapshot(
    snapshot: *const Snapshot,
) -> *mut Document {
    // SAFETY: the caller guarantees `snapshot` points to a live snapshot.
    let text = Text::from_snapshot(unsafe { &*snapshot }.text());
    hand_out(Document::over(text))
}

/// [`Document::replace_status`] for C: replaces the bytes of `document` from
/// `start` up to, not including, `end` with the `len` bytes at `text`, and
/// returns a [`ReplaceStatus`] as its number. Anything but
/// [`ReplaceStatus::Done`] changed nothing.
///
/// `text` that is not UTF-8 is read as [`editor_ffi_document_new`] reads it.
///
/// # Safety
///
/// `document` is a document handle this library handed out and has not
/// taken back, and `text` points to `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_document_replace(
    document: *const Document,
    start: usize,
    end: usize,
    text: *const u8,
    len: usize,
) -> u64 {
    // SAFETY: the caller guarantees the pointer and the length.
    let text = unsafe { text::borrow(text, len) };
    // SAFETY: the caller guarantees `document` points to a live document.
    unsafe { &*document }.replace_status(start, end, &text) as u64
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
/// `document` is a document handle this library handed out and has not
/// taken back, and `out` points to a writable [`RawText`].
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
/// `document` is a document handle this library handed out and has not
/// taken back, and it is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_document_free(document: *mut Document) {
    // SAFETY: the caller guarantees `document` is a box one of the
    // functions that hand a document out gave up, taken back this once.
    let document = unsafe { Box::from_raw(document) };
    crate::syntax::detach(document.key());
    drop(document);
    LIVE.fetch_sub(1, Ordering::Relaxed);
}

/// How many document handles this library has handed out that have not been
/// freed, whichever function handed each out. This is what makes a handle's
/// finaliser, and the lifetime of the editor's table of texts, observable
/// to a test.
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
