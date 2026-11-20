//! The C functions the package's glue (`ffi/glue.c`) calls: the process's
//! one [`Echo`] over the real completer, the service [`SERVICE`], whose
//! completions go to the process's completion queue, which the editor's
//! completion pump reads.
//!
//! Plain data only, as `editor-ffi`'s bindings are: a text crosses as a
//! pointer and a length, borrowed for the call
//! ([`editor_service::buffer::borrow`]); a reply crosses as one [`RawReply`]
//! filled in a single call, whose text buffer the caller hands back with
//! [`echo_ffi_free`].

use std::sync::LazyLock;

use editor_service::Service;
use editor_service::buffer;

use crate::{Echo, SERVICE};

/// The process's echo service.
static ECHO: LazyLock<Echo<&'static Service>> = LazyLock::new(|| Echo::new(&SERVICE));

/// A reply as it crosses the boundary.
#[repr(C)]
pub struct RawReply {
    /// The reply's text: a buffer of `text_len` bytes of UTF-8, owned by the
    /// caller until it is handed back with [`echo_ffi_free`].
    pub text: *mut u8,
    /// The length of `text` in bytes.
    pub text_len: usize,
}

/// Starts the request `id` of the `len` bytes of text at `text`
/// ([`Echo::start`]), and returns whether it started.
///
/// Text that is not UTF-8 is read with U+FFFD in place of each invalid
/// sequence; a Lean string is UTF-8.
///
/// # Safety
///
/// `text` points to `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_ffi_start(id: u64, text: *const u8, len: usize) -> bool {
    // SAFETY: the caller guarantees the pointer and the length.
    let text = String::from_utf8_lossy(unsafe { buffer::borrow(text, len) });
    ECHO.start(id, &text)
}

/// Cancels the request `id` ([`Echo::cancel`]), and returns whether it was
/// in use.
#[unsafe(no_mangle)]
pub extern "C" fn echo_ffi_cancel(id: u64) -> bool {
    ECHO.cancel(id)
}

/// Takes the reply to the request `id` ([`Echo::take`]): returns whether
/// there was one, and if so fills `out` with it.
///
/// # Safety
///
/// `out` points to a writable [`RawReply`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_ffi_take(id: u64, out: *mut RawReply) -> bool {
    let Some(reply) = ECHO.take(id) else {
        return false;
    };
    let (text, text_len) = buffer::lend(reply.text.into_bytes());
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(RawReply { text, text_len }) };
    true
}

/// Takes back a buffer a [`RawReply`] lent, and frees it.
///
/// # Safety
///
/// `text` and `len` are the pointer and length of a reply's text, which has
/// not been handed back and is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_ffi_free(text: *mut u8, len: usize) {
    // SAFETY: the caller guarantees the buffer was lent and is handed back
    // once.
    unsafe { buffer::reclaim(text, len) };
}
