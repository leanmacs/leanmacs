//! The URL opener: the URL opener port behind a handle, which Lean's jobs
//! hand a URL to.
//!
//! A [`UrlOpenerHandle`] holds an opener of the port
//! (`editor_platform::url_opener::UrlOpener`), one of three:
//!
//! - the port's recording opener ([`editor_ffi_url_opener_recording`]), the
//!   fake the boundary's tests run on: what it was handed is read back with
//!   [`editor_ffi_url_opener_opened`], here (`tests/url_opener.rs`) and
//!   through the glue and Lean's real binding
//!   (`ContractTest.urlOpenerChecks`, `ContractTest.urlOpenerJobFailures`),
//!   so the gate launches nothing;
//! - the port's failing opener ([`editor_ffi_url_opener_failing`]), whose
//!   every open fails with its reason, made only by tests;
//! - the desktop's ([`editor_ffi_url_opener_system`]), through the `open`
//!   adapter: made only by Lean's window mode.
//!
//! Each is counted live and freed by [`editor_ffi_url_opener_free`]. What
//! an opener does is the port's rule, pinned by its contract; this module
//! converts and forwards. Text crosses as a borrowed buffer in and a lent
//! one out ([`crate::text`]).

use std::sync::atomic::{AtomicU64, Ordering};

use editor_platform::url_opener::{FailingOpener, RecordingOpener, UrlOpenError, UrlOpener};
use editor_platform_open::SystemOpener;

use crate::document::RawText;
use crate::text;

/// The opener behind a handle.
enum Held {
    /// The port's recording fake, whose URLs can be read back.
    Recording(RecordingOpener),
    /// Any other opener.
    Other(Box<dyn UrlOpener>),
}

/// A URL opener behind a handle.
pub struct UrlOpenerHandle {
    /// The opener.
    held: Held,
}

impl UrlOpenerHandle {
    /// The opener, as the port.
    fn opener(&self) -> &dyn UrlOpener {
        match &self.held {
            Held::Recording(recording) => recording,
            Held::Other(other) => other.as_ref(),
        }
    }
}

/// How many URL opener handles this library has handed out that
/// [`editor_ffi_url_opener_free`] has not taken back.
static LIVE: AtomicU64 = AtomicU64::new(0);

/// `held` behind a new handle, owned by the caller.
fn handed_out(held: Held) -> *mut UrlOpenerHandle {
    LIVE.fetch_add(1, Ordering::Relaxed);
    Box::into_raw(Box::new(UrlOpenerHandle { held }))
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

/// A new handle over the port's recording opener, which has been handed
/// nothing, owned by the caller, who must hand it to
/// [`editor_ffi_url_opener_free`] exactly once.
///
/// Test-only: the editor never makes one.
#[doc(hidden)]
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_url_opener_recording() -> *mut UrlOpenerHandle {
    handed_out(Held::Recording(RecordingOpener::new()))
}

/// A new handle over the port's failing opener, whose every open fails with
/// the `reason_len` bytes at `reason` (read as UTF-8, U+FFFD for each
/// invalid sequence), owned by the caller, who must hand it to
/// [`editor_ffi_url_opener_free`] exactly once.
///
/// Test-only: the editor never makes one.
///
/// # Safety
///
/// `reason` points to `reason_len` readable bytes.
#[doc(hidden)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_url_opener_failing(
    reason: *const u8,
    reason_len: usize,
) -> *mut UrlOpenerHandle {
    // SAFETY: the caller guarantees the pointer and the length.
    let reason = unsafe { text::borrow(reason, reason_len) };
    handed_out(Held::Other(Box::new(FailingOpener::new(reason))))
}

/// A new handle over the desktop's URL opener, owned by the caller, who
/// must hand it to [`editor_ffi_url_opener_free`] exactly once. Lean's
/// window mode makes it; no test calls it.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_url_opener_system() -> *mut UrlOpenerHandle {
    #[expect(
        clippy::disallowed_methods,
        reason = "the process's URL opener, made for Lean's window mode, is the desktop's"
    )]
    let opener = SystemOpener::system();
    handed_out(Held::Other(Box::new(opener)))
}

/// Hands the `url_len` bytes at `url`, read as UTF-8 (U+FFFD for each
/// invalid sequence), to the opener behind `handle`. Returns whether the
/// system took it; when not, `out` is filled with the reason, and is left
/// alone otherwise. It may block, as the desktop's opener does, so Lean
/// calls it from a job alone.
///
/// # Safety
///
/// `handle` is a URL opener handle this library handed out and has not
/// taken back, `url` points to `url_len` readable bytes, and `out` to a
/// writable [`RawText`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_url_opener_open(
    handle: *const UrlOpenerHandle,
    url: *const u8,
    url_len: usize,
    out: *mut RawText,
) -> bool {
    // SAFETY: the caller guarantees the handle, the pointer and the length.
    let (handle, url) = unsafe { (&*handle, text::borrow(url, url_len)) };
    match handle.opener().open(&url) {
        Ok(()) => true,
        Err(UrlOpenError { reason }) => {
            // SAFETY: the caller guarantees `out` is writable.
            unsafe { lend_into(out, reason) };
            false
        }
    }
}

/// For a handle over the recording opener, fills `out` with each URL it was
/// handed, in order, each followed by a NUL byte, which no URL it took
/// holds, and returns true; for any other handle, returns false and leaves
/// `out` alone.
///
/// Test-only: the editor never makes a recording opener.
///
/// # Safety
///
/// `handle` is a URL opener handle this library handed out and has not
/// taken back, and `out` points to a writable [`RawText`].
#[doc(hidden)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_url_opener_opened(
    handle: *const UrlOpenerHandle,
    out: *mut RawText,
) -> bool {
    // SAFETY: the caller guarantees the handle.
    match &unsafe { &*handle }.held {
        Held::Recording(recording) => {
            let opened: String = recording
                .opened()
                .into_iter()
                .map(|url| url + "\0")
                .collect();
            // SAFETY: the caller guarantees `out` is writable.
            unsafe { lend_into(out, opened) };
            true
        }
        Held::Other(_) => false,
    }
}

/// Frees `handle`.
///
/// # Safety
///
/// `handle` is a URL opener handle this library handed out and has not
/// taken back, and it is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_url_opener_free(handle: *mut UrlOpenerHandle) {
    // SAFETY: the caller guarantees `handle` is a box this module gave up,
    // taken back this once.
    drop(unsafe { Box::from_raw(handle) });
    LIVE.fetch_sub(1, Ordering::Relaxed);
}

/// How many URL opener handles this library has handed out that have not
/// been freed.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_url_opener_live() -> u64 {
    LIVE.load(Ordering::Relaxed)
}
