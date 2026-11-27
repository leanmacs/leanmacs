//! The library's C interface, declared with the package wrapper's macro
//! (`editor_package::package!`): its one exported symbol, its init
//! ([`editor_package_init`]), and the table of C functions it answers
//! ([`EchoFunctions`], behind the table's size), through which the
//! package's glue (`ffi/glue.c`) forwards echo's `@[extern]` calls.
//!
//! The init is the wrapper's ([`editor_package::Package::export`]): it
//! refuses no runtime and one smaller than the wrapper requires, the table
//! unwritten; otherwise it makes the library's state once ([`Loaded::new`]:
//! the service `echo` registered through the runtime, and the process's one
//! [`Echo`] over it), writes the table and answers 0. A second init answers
//! the same table. Each table function reaches the state through
//! [`PACKAGE`], and answers false, or none, before the library is loaded.
//!
//! Plain data only, in the wrapper's FFI-safe types, so no function here
//! has `unsafe` of its own: each is declared with the wrapper's
//! `functions!`, whose body sees what the caller lent borrowed for the call
//! alone. A text crosses as [`Bytes`], read as its `&[u8]`; a reply as one
//! [`RawReply`] written through an [`Out`], entered as a `Place`, in a
//! single call, whose text is a [`Lent`] the glue hands back through the table's
//! `free` ([`editor_package::buffer::free`]), so this library's allocator
//! frees what it made. The table is a static of the library, valid for the
//! life of the process, since the core never unloads the library.

use editor_package::buffer::{Bytes, Lent, Out};
use editor_package::{Package, Runtime, Service, functions, package};

use crate::attach::{attach, attach_take};
use crate::{Echo, SERVICE_NAME};

/// The library, once its init has run: the runtime it was handed, and the
/// process's echo service over it.
pub struct Loaded {
    /// The core's runtime.
    pub(crate) runtime: Runtime,
    /// The process's echo service, reporting through the runtime.
    pub(crate) echo: Echo<Service>,
}

impl Loaded {
    /// The library's init: registers the service `echo` through `runtime`
    /// and makes the process's one [`Echo`] over it.
    pub fn new(runtime: Runtime) -> Self {
        Self {
            runtime,
            echo: Echo::new(runtime.register(SERVICE_NAME)),
        }
    }
}

/// The library, once its init has run; none before.
pub(crate) fn loaded() -> Option<&'static Loaded> {
    PACKAGE.state()
}

/// A reply as it crosses the boundary, mirrored by the glue's
/// `echo_raw_reply`: `{ echo_lent text; uint32_t checksum; }`.
#[repr(C)]
#[derive(Debug)]
pub struct RawReply {
    /// The reply's text, UTF-8, lent by this library until it is handed
    /// back through the table's `free`.
    pub text: Lent,
    /// The CRC-32 of the text's bytes.
    pub checksum: u32,
}

/// echo's functions, behind the table's size, mirrored by the glue's
/// `echo_table` in this order.
#[repr(C)]
#[derive(Debug)]
pub struct EchoFunctions {
    /// Starts a request of a text lent for the call ([`Echo::start`]).
    pub start: extern "C" fn(id: u64, text: Bytes<'_>) -> bool,
    /// Cancels a request ([`Echo::cancel`]).
    pub cancel: extern "C" fn(id: u64) -> bool,
    /// Takes a request's reply into a [`RawReply`] ([`Echo::take`]).
    pub take: extern "C" fn(id: u64, out: Out<'_, RawReply>) -> bool,
    /// Asks for a flush ([`Echo::flush`]).
    pub flush: extern "C" fn(id: u64),
    /// [`crate::attach::attach`].
    pub attach: extern "C" fn(request: u64, child: u64) -> bool,
    /// [`crate::attach::attach_take`].
    pub attach_take: extern "C" fn(request: u64, out: Out<'_, RawReply>) -> bool,
    /// Hands back a reply's text, freed by this library's allocator
    /// ([`editor_package::buffer::free`]).
    pub free: extern "C" fn(text: Lent),
}

package! {
    /// echo's library: its init ([`Loaded::new`]) and its table.
    pub static PACKAGE: Package<Loaded, EchoFunctions> = Package::new(
        Loaded::new,
        EchoFunctions {
            start,
            cancel,
            take,
            flush,
            attach,
            attach_take,
            free: editor_package::buffer::free,
        },
    );
}

functions! {
    /// Starts the request `id` of the text `text` ([`Echo::start`]), and
    /// returns whether it started.
    ///
    /// Text that is not UTF-8 is read with U+FFFD in place of each invalid
    /// sequence; a Lean string is UTF-8.
    extern "C" fn start(id: u64, text: Bytes<'_>) -> bool {
        loaded().is_some_and(|loaded| loaded.echo.start(id, &String::from_utf8_lossy(text)))
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
    /// there was one, and if so writes it to `out`.
    extern "C" fn take(id: u64, out: Out<'_, RawReply>) -> bool {
        let Some(reply) = loaded().and_then(|loaded| loaded.echo.take(id)) else {
            return false;
        };
        out.put(RawReply {
            text: Lent::of(reply.text.into_bytes()),
            checksum: reply.checksum,
        });
        true
    }
}
