//! The clipboard: the clipboard port behind a handle, which Lean reads and
//! writes through.
//!
//! A [`ClipboardHandle`] holds a clipboard of the port
//! (`editor_platform::clipboard::Clipboard`), one of three:
//!
//! - the port's memory clipboard ([`editor_ffi_clipboard_memory`]), the
//!   fake every test runs on: Lean's contract check of its real binding
//!   (`lean/ContractTest/Editor/Clipboard/Contract.lean`) is run over it, so
//!   the gate reads and writes no desktop's clipboard;
//! - the port's failing clipboard ([`editor_ffi_clipboard_failing`]), the
//!   fake of one that cannot be reached, made only by tests: the failure
//!   path, a read's `Failed` and a write's `false` with the reason, is
//!   pinned over it here (`tests/clipboard.rs`) and through the glue and
//!   Lean's real binding (`ContractTest.clipboardChecks`);
//! - the desktop's ([`editor_ffi_clipboard_system`]), through the arboard
//!   adapter: made only by Lean's window mode, and refused, with the
//!   reason, where there is none.
//!
//! Each is counted live and freed by [`editor_ffi_clipboard_free`]. What a
//! clipboard does is the port's rule, pinned by its contract; this module
//! converts and forwards. Text crosses as a borrowed buffer in and a lent
//! one out ([`crate::text`]).

use std::sync::atomic::{AtomicU64, Ordering};

use editor_platform::clipboard::{Clipboard, ClipboardError, FailingClipboard, MemoryClipboard};
use editor_platform_arboard::SystemClipboard;

use crate::document::RawText;
use crate::text;

/// A clipboard behind a handle.
pub struct ClipboardHandle {
    /// The clipboard.
    clipboard: Box<dyn Clipboard + Send + Sync>,
}

/// How a read ended, as it crosses the boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClipboardRead {
    /// The clipboard holds text: the record holds it.
    Text = 0,
    /// It holds no text: the record is empty.
    Empty = 1,
    /// It could not be read: the record holds the reason.
    Failed = 2,
}

/// How many clipboard handles this library has handed out that
/// [`editor_ffi_clipboard_free`] has not taken back.
static LIVE: AtomicU64 = AtomicU64::new(0);

/// `clipboard` behind a new handle, owned by the caller.
fn handed_out(clipboard: impl Clipboard + Send + Sync + 'static) -> *mut ClipboardHandle {
    LIVE.fetch_add(1, Ordering::Relaxed);
    Box::into_raw(Box::new(ClipboardHandle {
        clipboard: Box::new(clipboard),
    }))
}

/// Writes `text` into `out`, lent to the caller.
///
/// # Safety
///
/// `out` points to a writable [`RawText`].
unsafe fn lend_into(out: *mut RawText, text: String) {
    let (text, text_len) = text::lend(text);
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(RawText { text, text_len }) };
}

/// A new handle over a clipboard in memory that holds nothing, owned by the
/// caller, who must hand it to [`editor_ffi_clipboard_free`] exactly once.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_clipboard_memory() -> *mut ClipboardHandle {
    handed_out(MemoryClipboard::new())
}

/// A new handle over the port's failing clipboard, whose every read and
/// write fails with the `reason_len` bytes at `reason` (read as UTF-8,
/// U+FFFD for each invalid sequence), owned by the caller, who must hand it
/// to [`editor_ffi_clipboard_free`] exactly once.
///
/// Test-only: it is how a test reaches the failure path across the
/// boundary without a desktop (`tests/clipboard.rs`, and Lean's
/// `ContractTest.clipboardChecks` through the glue). The editor never makes
/// one.
///
/// # Safety
///
/// `reason` points to `reason_len` readable bytes.
#[doc(hidden)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_clipboard_failing(
    reason: *const u8,
    reason_len: usize,
) -> *mut ClipboardHandle {
    // SAFETY: the caller guarantees the pointer and the length.
    let reason = unsafe { text::borrow(reason, reason_len) };
    handed_out(FailingClipboard::new(reason))
}

/// A new handle over the desktop's clipboard, owned by the caller, who must
/// hand it to [`editor_ffi_clipboard_free`] exactly once; or null, with
/// `out` filled with the reason, when the desktop has none to reach. Lean's
/// window mode makes it; no test calls it.
///
/// # Safety
///
/// `out` points to a writable [`RawText`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_clipboard_system(out: *mut RawText) -> *mut ClipboardHandle {
    #[expect(
        clippy::disallowed_methods,
        reason = "the process's clipboard, made for Lean's window mode, is the desktop's"
    )]
    let opened = SystemClipboard::open();
    match opened {
        Ok(clipboard) => handed_out(clipboard),
        Err(ClipboardError { reason }) => {
            // SAFETY: the caller guarantees `out` is writable.
            unsafe { lend_into(out, reason) };
            std::ptr::null_mut()
        }
    }
}

/// Reads the text on the clipboard behind `handle` into `out`, and says how
/// the read ended ([`ClipboardRead`], as its number): the text, nothing,
/// or the reason it failed.
///
/// # Safety
///
/// `handle` is a clipboard handle this library handed out and has not
/// taken back, and `out` points to a writable [`RawText`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_clipboard_read(
    handle: *const ClipboardHandle,
    out: *mut RawText,
) -> u8 {
    // SAFETY: the caller guarantees the handle.
    let read = unsafe { &*handle }.clipboard.read();
    let (status, text) = match read {
        Ok(Some(text)) => (ClipboardRead::Text, text),
        Ok(None) => (ClipboardRead::Empty, String::new()),
        Err(ClipboardError { reason }) => (ClipboardRead::Failed, reason),
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { lend_into(out, text) };
    status as u8
}

/// Puts the `text_len` bytes at `text` on the clipboard behind `handle`, in
/// place of what it held, read as UTF-8 (U+FFFD for each invalid sequence).
/// Returns whether it was written; when not, `out` is filled with the
/// reason, and is left alone otherwise.
///
/// # Safety
///
/// `handle` is a clipboard handle this library handed out and has not
/// taken back, `text` points to `text_len` readable bytes, and `out` to a
/// writable [`RawText`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_clipboard_write(
    handle: *const ClipboardHandle,
    text: *const u8,
    text_len: usize,
    out: *mut RawText,
) -> bool {
    // SAFETY: the caller guarantees the handle, the pointer and the length.
    let (handle, text) = unsafe { (&*handle, text::borrow(text, text_len)) };
    match handle.clipboard.write(&text) {
        Ok(()) => true,
        Err(ClipboardError { reason }) => {
            // SAFETY: the caller guarantees `out` is writable.
            unsafe { lend_into(out, reason) };
            false
        }
    }
}

/// Frees `handle`.
///
/// # Safety
///
/// `handle` is a clipboard handle this library handed out and has not taken
/// back, and it is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_clipboard_free(handle: *mut ClipboardHandle) {
    // SAFETY: the caller guarantees `handle` is a box this module gave up,
    // taken back this once.
    drop(unsafe { Box::from_raw(handle) });
    LIVE.fetch_sub(1, Ordering::Relaxed);
}

/// How many clipboard handles this library has handed out that have not
/// been freed.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_clipboard_live() -> u64 {
    LIVE.load(Ordering::Relaxed)
}
