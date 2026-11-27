//! The package runtime as the core implements it: the process's one
//! runtime ([`RUNTIME`]), the core's implementation of each member over
//! what the core already runs, the runtime's pure model
//! ([`model::ModelRuntime`]) and the contract both keep
//! ([`contract::check`]).
//!
//! The runtime's C definitions are `editor-package-runtime`'s, re-exported
//! here ([`PackageRuntime`], [`PackageChild`], [`RawPull`], [`RawBuffer`]),
//! and so are the rules a library keeps: what each member does, which
//! threads may call it, who owns each piece of data, the append-only rule
//! and how a pull crosses (its crate docs).
//!
//! # How each member is the core's
//!
//! | Member | The core's implementation |
//! |---|---|
//! | `private_members` | Null: the real runtime's state is the process's statics, and its members ignore the runtime they are handed |
//! | `register_service` | `editor_service::service::register`: an id from the counter every service takes its id from |
//! | `complete` | `editor_service::queue::complete`, the call a static `Service` makes, so the completion lands on the one completion queue the editor's pump reads; refused (false, nothing posted) for an id below [`FIRST_PACKAGE_ID`], a core service's |
//! | `post_event` | A message ([`Event::message`]) from the library's service on the editor queue; refused for a core service's id, as `complete` is |
//! | `take_over` | `editor_service::stream::take_over`, the process's one stream source; the child crosses as a handle the core owns (a [`TakenChild`] behind a [`PackageChild`] pointer), 0 or a [`refusal_tag`] |
//! | `child_pull` | [`ChildStreams::pull`], encoded ([`wire::encode`]) as one [`RawPull`], its buffers lent through the process's ledger ([`ledger::LEDGER`]) |
//! | `child_write` | [`ChildStreams::write`]; a refused write lends the platform's words through the ledger |
//! | `child_release` | Drops the handle's streams |
//! | `buffer_lend` | The bytes copied into a buffer lent through the ledger |
//! | `buffer_free` | [`ledger::Ledger::reclaim`] on the process's ledger: true once, false for a buffer handed back already or never lent |
//!
//! Each C member is a thin forwarder over a safe function of this module
//! that takes its collaborator ([`take_over_from`], [`pull_from`],
//! [`write_to`], [`complete_with`], [`post_event_with`], [`lend_into`]),
//! so the unit tests run on `editor-service`'s fakes with no process-wide
//! source or queue. The model's members forward to the same functions over
//! its own state.
//!
//! # Tests
//!
//! - This module's unit tests: the safe functions on `editor-service`'s
//!   fakes, and the C members through [`RUNTIME`], each lent buffer handed
//!   back once. Their binary's tests run in parallel and share the
//!   process's ledger, so a second hand-back is pinned on a ledger of its
//!   own ([`ledger`]'s tests) and by the contract.
//! - [`model`]'s tests: the model's members, and [`contract::check`] on the
//!   model, as the current runtime and as a later, larger one.
//! - `tests/contract.rs`: [`contract::check`] on [`RUNTIME`], over the
//!   process's queues and ledger, in a binary of its own.

pub mod contract;
pub mod ledger;
pub mod model;
pub mod wire;

use std::mem::size_of;
use std::ptr;

pub use editor_package_runtime::{PackageChild, PackageRuntime, RawBuffer, RawPull};
use editor_package_runtime::{
    TAKE_OVER_NO_SERVICE, TAKE_OVER_NO_SUCH_CHILD, TAKE_OVER_READ_PENDING, TAKE_OVER_TAKEN,
};
use editor_service::buffer;
use editor_service::queue::{EDITOR, Event, Source, SourceKind};
use editor_service::stream::{self, ChildStreams, InputClosed, Refused, StreamSource};
use editor_service::{FIRST_PACKAGE_ID, queue, service};

use ledger::{LEDGER, Ledger};
use wire::Encoded;

/// The process's one runtime, handed to every package library's init. Its
/// `private_members` is null: its state is the process's statics.
pub static RUNTIME: PackageRuntime = PackageRuntime {
    size: size_of::<PackageRuntime>(),
    private_members: ptr::null_mut(),
    register_service,
    complete,
    post_event,
    take_over,
    child_pull,
    child_write,
    child_release,
    buffer_lend,
    buffer_free,
};

/// A streaming child taken over, as the core holds it: what a
/// [`PackageChild`] pointer points to, from `take_over` until
/// `child_release`, opaque to a library.
pub struct TakenChild(Box<dyn ChildStreams>);

impl std::fmt::Debug for TakenChild {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TakenChild").finish_non_exhaustive()
    }
}

/// The tag a take-over refusal crosses as, 1 to 4. It matches every
/// variant of [`Refused`] on purpose: each refusal must cross as a tag of
/// its own, and a new one must be given one here.
pub const fn refusal_tag(refused: Refused) -> u32 {
    match refused {
        Refused::NoService => TAKE_OVER_NO_SERVICE,
        Refused::NoSuchChild => TAKE_OVER_NO_SUCH_CHILD,
        Refused::ReadPending => TAKE_OVER_READ_PENDING,
        Refused::Taken => TAKE_OVER_TAKEN,
    }
}

/// The refusal a take-over's tag stands for, [`refusal_tag`]'s inverse:
/// none for a tag no refusal crosses as.
pub const fn refused_of_tag(tag: u32) -> Option<Refused> {
    match tag {
        TAKE_OVER_NO_SERVICE => Some(Refused::NoService),
        TAKE_OVER_NO_SUCH_CHILD => Some(Refused::NoSuchChild),
        TAKE_OVER_READ_PENDING => Some(Refused::ReadPending),
        TAKE_OVER_TAKEN => Some(Refused::Taken),
        _ => None,
    }
}

/// Lends both of `encoded`'s buffers through `ledger`, as a [`RawPull`].
fn lend_pull(encoded: Encoded, ledger: &Ledger) -> RawPull {
    let words = ledger.lend(encoded.words);
    let bytes = ledger.lend(encoded.bytes);
    RawPull {
        delivered: encoded.delivered,
        words: words.bytes,
        words_len: words.len,
        bytes: bytes.bytes,
        bytes_len: bytes.len,
    }
}

/// The id of a service registered by the name `name`, its bytes read as
/// UTF-8 with U+FFFD in place of each invalid sequence.
pub fn register_named(name: &[u8]) -> u64 {
    service::register(&String::from_utf8_lossy(name))
}

/// Posts the completion of `request` from `service` through `post`, unless
/// `service` is a core service's id (below [`FIRST_PACKAGE_ID`]), which is
/// refused with nothing posted: a library cannot post as a core service.
pub fn complete_with(service: u64, request: u64, post: impl FnOnce(u64, u64) -> bool) -> bool {
    service >= FIRST_PACKAGE_ID && post(service, request)
}

/// Posts a message of `code` and `text` from `service` through `post`,
/// unless `service` is a core service's id, which is refused with nothing
/// posted, as [`complete_with`] refuses it: a library cannot post as a core
/// service.
pub fn post_event_with(
    service: u64,
    code: u64,
    text: String,
    post: impl FnOnce(u64, u64, String) -> bool,
) -> bool {
    service >= FIRST_PACKAGE_ID && post(service, code, text)
}

/// Posts a message of `code` and `text` from the library's service
/// `service` on the process's editor queue.
fn post_message(service: u64, code: u64, text: String) -> bool {
    let source = Source {
        kind: SourceKind::Library,
        id: service,
    };
    EDITOR.push(Event::message(source, code, text))
}

/// Lends a copy of `bytes` through `ledger`.
pub fn lend_into(ledger: &Ledger, bytes: &[u8]) -> RawBuffer {
    ledger.lend(bytes.to_vec())
}

/// Takes `child` over from `source`, as the handle the core owns.
///
/// # Errors
///
/// The [`refusal_tag`] of the source's refusal.
pub fn take_over_from(source: &dyn StreamSource, child: u64) -> Result<Box<TakenChild>, u32> {
    source
        .take_over(child)
        .map(|streams| Box::new(TakenChild(streams)))
        .map_err(refusal_tag)
}

/// Pulls `child`, blocking, encoded.
pub fn pull_from(child: &TakenChild) -> Encoded {
    wire::encode(child.0.pull())
}

/// Writes `bytes` to `child`'s input, blocking.
///
/// # Errors
///
/// The platform's words, as bytes, when the input is closed.
pub fn write_to(child: &TakenChild, bytes: &[u8]) -> Result<(), Vec<u8>> {
    child
        .0
        .write(bytes.to_vec())
        .map_err(|InputClosed(words)| words.into_bytes())
}

/// The process's stream source, as a [`StreamSource`]: the one
/// `editor-ffi` provided when the library started.
struct Provided;

impl StreamSource for Provided {
    fn take_over(&self, child: u64) -> Result<Box<dyn ChildStreams>, Refused> {
        stream::take_over(child)
    }
}

/// The `len` bytes of text at `text`, borrowed for the call, read as UTF-8
/// with U+FFFD in place of each invalid sequence.
///
/// # Safety
///
/// `text` points to `len` readable bytes, unless `len` is zero.
#[expect(
    unsafe_code,
    reason = "reads the text a library lends a member for the call"
)]
pub(crate) unsafe fn text_of(text: *const u8, len: usize) -> String {
    // SAFETY: the caller guarantees the pointer and the length.
    String::from_utf8_lossy(unsafe { buffer::borrow(text, len) }).into_owned()
}

/// A `take_over` over `source`: writes the handle and answers 0, or answers
/// the refusal's tag and writes nothing.
///
/// # Safety
///
/// `handle` points to a writable pointer.
#[expect(
    unsafe_code,
    reason = "a runtime's take-over writes the child's handle where the library says"
)]
pub(crate) unsafe fn take_over_into(
    source: &dyn StreamSource,
    child: u64,
    handle: *mut *mut PackageChild,
) -> u32 {
    match take_over_from(source, child) {
        Ok(child) => {
            // SAFETY: the caller hands a writable pointer.
            unsafe { handle.write(Box::into_raw(child).cast()) };
            0
        }
        Err(tag) => tag,
    }
}

/// A `child_pull`: pulls the child, blocking, and fills `out`, its buffers
/// lent through `ledger`.
///
/// # Safety
///
/// `handle` is a live handle from a take-over, not yet released, and `out`
/// points to a writable [`RawPull`].
#[expect(
    unsafe_code,
    reason = "a runtime's pull reads the child's handle and fills the library's record"
)]
pub(crate) unsafe fn pull_into(ledger: &Ledger, handle: *mut PackageChild, out: *mut RawPull) {
    // SAFETY: the caller hands a live handle, which it releases only after
    // its last call.
    let child = unsafe { &*handle.cast::<TakenChild>() };
    let pull = lend_pull(pull_from(child), ledger);
    // SAFETY: the caller hands a writable record.
    unsafe { out.write(pull) };
}

/// A `child_write`: writes the bytes lent to the child's input, blocking,
/// and answers true; or false, the platform's words lent into `refused`
/// through `ledger`.
///
/// # Safety
///
/// `handle` is a live handle from a take-over, not yet released; `bytes`
/// points to `len` readable bytes, unless `len` is zero; and `refused`
/// points to a writable [`RawBuffer`].
#[expect(
    unsafe_code,
    reason = "a runtime's write reads the child's handle and the bytes lent, and fills the library's record"
)]
pub(crate) unsafe fn write_into(
    ledger: &Ledger,
    handle: *mut PackageChild,
    bytes: *const u8,
    len: usize,
    refused: *mut RawBuffer,
) -> bool {
    // SAFETY: the caller hands a live handle, which it releases only after
    // its last call.
    let child = unsafe { &*handle.cast::<TakenChild>() };
    // SAFETY: the caller lends `len` readable bytes for the call.
    let bytes = unsafe { buffer::borrow(bytes, len) };
    match write_to(child, bytes) {
        Ok(()) => true,
        Err(words) => {
            let words = ledger.lend(words);
            // SAFETY: the caller hands a writable record.
            unsafe { refused.write(words) };
            false
        }
    }
}

/// A `child_release`: drops the child's streams.
///
/// # Safety
///
/// `handle` is a live handle from a take-over, released this once.
#[expect(
    unsafe_code,
    reason = "a runtime's release takes back the handle a take-over gave up"
)]
pub(crate) unsafe fn release(handle: *mut PackageChild) {
    // SAFETY: the handle is the box a take-over gave up, released once.
    drop(unsafe { Box::from_raw(handle.cast::<TakenChild>()) });
}

/// A `buffer_lend`: lends a copy of the bytes lent through `ledger` into
/// `out`.
///
/// # Safety
///
/// `bytes` points to `len` readable bytes, unless `len` is zero, and `out`
/// points to a writable [`RawBuffer`].
#[expect(
    unsafe_code,
    reason = "a runtime's lend reads the bytes lent for the call and fills the library's record"
)]
pub(crate) unsafe fn lend_raw(ledger: &Ledger, bytes: *const u8, len: usize, out: *mut RawBuffer) {
    // SAFETY: the caller lends `len` readable bytes for the call.
    let lent = lend_into(ledger, unsafe { buffer::borrow(bytes, len) });
    // SAFETY: the caller hands a writable record.
    unsafe { out.write(lent) };
}

/// The runtime's `register_service` ([`register_named`]).
///
/// # Safety
///
/// `name` points to `len` readable bytes, unless `len` is zero.
#[expect(
    unsafe_code,
    reason = "a member of the runtime a package's library calls: it reads the name the library lends for the call"
)]
unsafe extern "C" fn register_service(
    _: *const PackageRuntime,
    name: *const u8,
    len: usize,
) -> u64 {
    // SAFETY: the library lends `len` readable bytes for the call.
    register_named(unsafe { buffer::borrow(name, len) })
}

/// The runtime's `complete` ([`complete_with`] over the process's
/// completion queue).
extern "C" fn complete(_: *const PackageRuntime, service: u64, request: u64) -> bool {
    complete_with(service, request, queue::complete)
}

/// The runtime's `post_event` ([`post_event_with`] over the process's
/// editor queue).
///
/// # Safety
///
/// `text` points to `len` readable bytes, unless `len` is zero.
#[expect(
    unsafe_code,
    reason = "a member of the runtime a package's library calls: it reads the text the library lends for the call"
)]
unsafe extern "C" fn post_event(
    _: *const PackageRuntime,
    service: u64,
    code: u64,
    text: *const u8,
    len: usize,
) -> bool {
    // SAFETY: the library lends `len` readable bytes for the call.
    post_event_with(service, code, unsafe { text_of(text, len) }, post_message)
}

/// The runtime's `take_over` ([`take_over_from`] the process's source).
///
/// # Safety
///
/// `handle` points to a writable pointer.
#[expect(
    unsafe_code,
    reason = "a member of the runtime a package's library calls: it writes the child's handle where the library says"
)]
unsafe extern "C" fn take_over(
    _: *const PackageRuntime,
    child: u64,
    handle: *mut *mut PackageChild,
) -> u32 {
    // SAFETY: the library hands a writable pointer.
    unsafe { take_over_into(&Provided, child, handle) }
}

/// The runtime's `child_pull` ([`pull_from`]), lent through the process's
/// ledger.
///
/// # Safety
///
/// `handle` is a live handle from `take_over`, not yet released, and `out`
/// points to a writable [`RawPull`].
#[expect(
    unsafe_code,
    reason = "a member of the runtime a package's library calls: it reads the child's handle and fills the library's record"
)]
unsafe extern "C" fn child_pull(
    _: *const PackageRuntime,
    handle: *mut PackageChild,
    out: *mut RawPull,
) {
    // SAFETY: the library hands a live handle and a writable record.
    unsafe { pull_into(&LEDGER, handle, out) };
}

/// The runtime's `child_write` ([`write_to`]), a refusal's words lent
/// through the process's ledger.
///
/// # Safety
///
/// `handle` is a live handle from `take_over`, not yet released; `bytes`
/// points to `len` readable bytes, unless `len` is zero; and `refused`
/// points to a writable [`RawBuffer`].
#[expect(
    unsafe_code,
    reason = "a member of the runtime a package's library calls: it reads the child's handle and the bytes lent, and fills the library's record"
)]
unsafe extern "C" fn child_write(
    _: *const PackageRuntime,
    handle: *mut PackageChild,
    bytes: *const u8,
    len: usize,
    refused: *mut RawBuffer,
) -> bool {
    // SAFETY: the library hands a live handle, the bytes and a writable
    // record.
    unsafe { write_into(&LEDGER, handle, bytes, len, refused) }
}

/// The runtime's `child_release`: drops the child's streams.
///
/// # Safety
///
/// `handle` is a live handle from `take_over`, released this once.
#[expect(
    unsafe_code,
    reason = "a member of the runtime a package's library calls: it takes back the handle `take_over` gave up"
)]
unsafe extern "C" fn child_release(_: *const PackageRuntime, handle: *mut PackageChild) {
    // SAFETY: the library releases a live handle, once.
    unsafe { release(handle) };
}

/// The runtime's `buffer_lend` ([`lend_into`] the process's ledger).
///
/// # Safety
///
/// `bytes` points to `len` readable bytes, unless `len` is zero, and `out`
/// points to a writable [`RawBuffer`].
#[expect(
    unsafe_code,
    reason = "a member of the runtime a package's library calls: it reads the bytes lent for the call and fills the library's record"
)]
unsafe extern "C" fn buffer_lend(
    _: *const PackageRuntime,
    bytes: *const u8,
    len: usize,
    out: *mut RawBuffer,
) {
    // SAFETY: the library lends the bytes and hands a writable record.
    unsafe { lend_raw(&LEDGER, bytes, len, out) };
}

/// The runtime's `buffer_free`: [`Ledger::reclaim`] on the process's
/// ledger, true once for a buffer it lent, false otherwise.
extern "C" fn buffer_free(_: *const PackageRuntime, bytes: *mut u8, len: usize) -> bool {
    LEDGER.reclaim(bytes, len)
}

#[cfg(test)]
mod tests;
