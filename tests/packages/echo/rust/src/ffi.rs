//! The library's C interface: its one exported symbol, its init
//! ([`editor_package_init`]), and the table of C functions it answers
//! ([`EchoTable`]), through which the package's glue (`ffi/glue.c`)
//! forwards echo's `@[extern]` calls.
//!
//! The init is handed the core's package runtime ([`PackageRuntime`]). It
//! refuses one smaller than echo requires ([`REQUIRED`]), answering 1 with the
//! table unwritten; otherwise it registers the service `echo` through the
//! runtime, once, makes the process's one [`Echo`] over a completer that
//! posts through the runtime, writes [`TABLE`] and answers 0. A second init
//! answers the same table. Each table function answers false, or none,
//! before the library is loaded.
//!
//! Plain data only: a text crosses as a pointer and a length, borrowed for
//! the call; a reply crosses as one [`RawReply`] filled in a single call,
//! whose text buffer the glue hands back through the table's `free`, so it
//! is freed by this library's allocator, which made it. The table is a
//! static of the library, valid for the life of the process, since the
//! core never unloads the library.

use std::ptr;
use std::sync::OnceLock;

use crate::attach::{attach, attach_take};
use editor_package_runtime::{INIT_LOADED, INIT_RUNTIME_TOO_SMALL, PackageRuntime};

use crate::runtime::{REQUIRED, RuntimeCompleter};
use crate::{Echo, SERVICE_NAME, buffer};

/// The library, once its init has run: the runtime it was handed, and the
/// process's echo service over it.
pub(crate) struct Loaded {
    /// The core's runtime.
    pub(crate) runtime: &'static PackageRuntime,
    /// The process's echo service, reporting through the runtime.
    pub(crate) echo: Echo<RuntimeCompleter>,
}

/// The library, once loaded.
static LOADED: OnceLock<Loaded> = OnceLock::new();

/// The library, once its init has run; none before.
pub(crate) fn loaded() -> Option<&'static Loaded> {
    LOADED.get()
}

/// A reply as it crosses the boundary.
#[repr(C)]
pub struct RawReply {
    /// The reply's text: a buffer of `text_len` bytes of UTF-8, owned by the
    /// caller until it is handed back through the table's `free`.
    pub text: *mut u8,
    /// The length of `text` in bytes.
    pub text_len: usize,
    /// The CRC-32 of the text's bytes.
    pub checksum: u32,
}

/// The table the init answers, mirrored by the glue's `echo_table`: its
/// size, then each C function in this order.
#[repr(C)]
#[derive(Debug)]
pub struct EchoTable {
    /// `size_of::<EchoTable>()`.
    pub size: usize,
    /// Starts a request of a text lent for the call ([`Echo::start`]).
    pub start: unsafe extern "C" fn(id: u64, text: *const u8, len: usize) -> bool,
    /// Cancels a request ([`Echo::cancel`]).
    pub cancel: extern "C" fn(id: u64) -> bool,
    /// Takes a request's reply into a [`RawReply`] ([`Echo::take`]).
    pub take: unsafe extern "C" fn(id: u64, out: *mut RawReply) -> bool,
    /// Asks for a flush ([`Echo::flush`]).
    pub flush: extern "C" fn(id: u64),
    /// [`crate::attach::attach`].
    pub attach: extern "C" fn(request: u64, child: u64) -> bool,
    /// [`crate::attach::attach_take`].
    pub attach_take: unsafe extern "C" fn(request: u64, out: *mut RawReply) -> bool,
    /// Hands back a reply's text, freed by this library's allocator.
    pub free: unsafe extern "C" fn(text: *mut u8, len: usize),
}

/// The library's one table.
pub static TABLE: EchoTable = EchoTable {
    size: size_of::<EchoTable>(),
    start,
    cancel,
    take,
    flush,
    attach,
    attach_take,
    free,
};

/// The library's init, the one symbol it exports: handed the core's
/// runtime, it answers 1 for a runtime smaller than [`REQUIRED`] (or none),
/// the table unwritten; otherwise it registers the service `echo` once,
/// writes [`TABLE`] to `table` and answers 0.
///
/// # Safety
///
/// `runtime` is null or points to a runtime at least as large as its
/// `size` says, which lives for the process; `table` points to a writable
/// pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_package_init(
    runtime: *const PackageRuntime,
    table: *mut *const EchoTable,
) -> u32 {
    if runtime.is_null() {
        return INIT_RUNTIME_TOO_SMALL;
    }
    // SAFETY: the size is the runtime's first member, read alone, before
    // anything of a runtime that may be smaller than echo's is.
    let size = unsafe { ptr::addr_of!((*runtime).size).read() };
    if size < REQUIRED {
        return INIT_RUNTIME_TOO_SMALL;
    }
    // SAFETY: the runtime holds every member echo reads, and is the core's,
    // for the life of the process.
    let runtime: &'static PackageRuntime = unsafe { &*runtime };
    LOADED.get_or_init(|| {
        let name = SERVICE_NAME;
        // SAFETY: the name is lent for the call.
        let service = unsafe { (runtime.register_service)(runtime, name.as_ptr(), name.len()) };
        Loaded {
            runtime,
            echo: Echo::new(RuntimeCompleter { runtime, service }),
        }
    });
    // SAFETY: the caller hands a writable pointer.
    unsafe { table.write(&raw const TABLE) };
    INIT_LOADED
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
unsafe extern "C" fn start(id: u64, text: *const u8, len: usize) -> bool {
    let Some(loaded) = loaded() else {
        return false;
    };
    // SAFETY: the caller guarantees the pointer and the length.
    let text = String::from_utf8_lossy(unsafe { buffer::borrow(text, len) });
    loaded.echo.start(id, &text)
}

/// Cancels the request `id` ([`Echo::cancel`]), and returns whether it was
/// in use.
extern "C" fn cancel(id: u64) -> bool {
    loaded().is_some_and(|loaded| loaded.echo.cancel(id))
}

/// Asks for `id` to be completed once every echo request started before
/// has been ([`Echo::flush`]).
extern "C" fn flush(id: u64) {
    if let Some(loaded) = loaded() {
        loaded.echo.flush(id);
    }
}

/// Takes the reply to the request `id` ([`Echo::take`]): returns whether
/// there was one, and if so fills `out` with it.
///
/// # Safety
///
/// `out` points to a writable [`RawReply`].
unsafe extern "C" fn take(id: u64, out: *mut RawReply) -> bool {
    let Some(reply) = loaded().and_then(|loaded| loaded.echo.take(id)) else {
        return false;
    };
    let checksum = reply.checksum;
    let (text, text_len) = buffer::lend(reply.text.into_bytes());
    // SAFETY: the caller guarantees `out` is writable.
    unsafe {
        out.write(RawReply {
            text,
            text_len,
            checksum,
        });
    }
    true
}

/// Takes back a buffer a [`RawReply`] lent, and frees it.
///
/// # Safety
///
/// `text` and `len` are the pointer and length of a reply's text, which has
/// not been handed back and is not used again.
unsafe extern "C" fn free(text: *mut u8, len: usize) {
    // SAFETY: the caller guarantees the buffer was lent and is handed back
    // once.
    unsafe { buffer::reclaim(text, len) };
}
