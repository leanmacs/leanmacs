//! The package runtime: the C struct of the core's capabilities that the
//! core hands a package's library at its init ([`PackageRuntime`]), its one
//! instance ([`RUNTIME`]), and the core's implementation of each member over
//! what the core already runs.
//!
//! In phase 1 of the roadmap `package-native-libraries` it is unversioned
//! and holds exactly what the fixture package `echo` uses: registering its
//! service, posting a completion, taking over a streaming child the core's
//! process service opened, pulling and writing that child, and handing a
//! buffer back. Its `size`, first, is how a library tells a runtime too
//! small for it (the library checks it, as an Emacs module checks
//! `emacs_env`); a later member is only ever appended.
//!
//! # How each member is the core's
//!
//! | Member | The core's implementation |
//! |---|---|
//! | `register_service` | `editor_service::service::register`: an id from the counter every service takes its id from |
//! | `complete` | `editor_service::queue::complete`, the call a static `Service` makes, so the completion lands on the one completion queue the editor's pump reads; refused (false, nothing posted) for an id below [`FIRST_PACKAGE_ID`], a core service's |
//! | `take_over` | `editor_service::stream::take_over`, the process's one stream source; the child crosses as a handle the core owns ([`PackageChild`]), 0 or a [`refusal_tag`] |
//! | `child_pull` | [`ChildStreams::pull`], encoded as one [`RawPull`] ("How a pull crosses") |
//! | `child_write` | [`ChildStreams::write`]; a refused write lends the platform's words |
//! | `child_release` | Drops the handle's streams |
//! | `buffer_free` | `editor_service::buffer::reclaim` |
//!
//! Each C member is a thin forwarder over a safe function of this module
//! that takes its collaborator ([`take_over_from`], [`pull_from`],
//! [`write_to`], [`complete_with`]), so the unit tests run on
//! `editor-service`'s fakes with no process-wide source or queue.
//!
//! # Who owns what
//!
//! - The runtime is a `static` of the core, for the life of the process. A
//!   library may keep the pointer.
//! - A child handle is made by the core in `take_over` and owned by the
//!   core. The library may call `child_pull` from one thread while it calls
//!   `child_write` from another, one writer at a time ([`ChildStreams`]'s
//!   rules). It calls `child_release` exactly once, after its last call,
//!   and the core drops the streams.
//! - Every buffer the core lends (a pull's words and bytes, a refused
//!   write's words) is handed back once, through `buffer_free`. Each side
//!   frees what its own allocator made: a library carries its own Rust
//!   standard library.
//! - Bytes handed in (a service's name, a write's bytes) are borrowed for
//!   the call and copied.
//!
//! # How a pull crosses
//!
//! A [`RawPull`]: whether something was delivered, and two buffers, both
//! lent. A cancelled pull ([`Pulled::Cancelled`]) is `delivered = false`
//! with both buffers empty, and still handed back.
//!
//! The words are little-endian `u64`s, eight bytes each:
//!
//! | Words | |
//! |---|---|
//! | standard output's framing: 0 lines, 1 bytes, 2 messages | |
//! | its count of frames | the length of each (bytes are one frame) |
//! | the same for standard error | |
//! | the end: 0 none, 1 exited, 2 signalled, 3 line too long, 4 message too long, 5 failed | |
//! | two values: the status or the signal, two's complement, and 0; or the stream (0 out, 1 err) and its bound; or 0 and 0 | |
//! | the failed words' length, else 0 | |
//!
//! The bytes are standard output's frames, standard error's, and the
//! failed words, end to end.

use std::mem::size_of;

use editor_service::buffer;
use editor_service::frame::{Frames, Stream};
use editor_service::stream::{
    self, ChildStreams, Ended, InputClosed, Pulled, Refused, StreamSource,
};
use editor_service::{FIRST_PACKAGE_ID, queue, service};

/// The runtime the core hands a package's library at its init: its size,
/// then a function pointer for each capability.
#[repr(C)]
#[derive(Debug)]
pub struct PackageRuntime {
    /// `size_of::<PackageRuntime>()`: a library checks it before it uses a
    /// member, and refuses a runtime smaller than it requires.
    pub size: usize,
    /// Registers a service of the `len` bytes of name at `name`, borrowed
    /// for the call, and answers its id: the id its completions carry.
    pub register_service: unsafe extern "C" fn(name: *const u8, len: usize) -> u64,
    /// Posts the completion of the request `request` from the service
    /// `service`, and answers whether it was accepted: false for a service
    /// id below [`FIRST_PACKAGE_ID`], and when the queue was quit.
    pub complete: extern "C" fn(service: u64, request: u64) -> bool,
    /// Takes the streaming child `child` over and writes its handle to
    /// `handle`, answering 0; or answers the refusal's tag
    /// ([`refusal_tag`]) and writes nothing.
    pub take_over: unsafe extern "C" fn(child: u64, handle: *mut *mut PackageChild) -> u32,
    /// Pulls the child `handle` ([`ChildStreams::pull`]), blocking, and
    /// fills `out` ("How a pull crosses").
    pub child_pull: unsafe extern "C" fn(handle: *mut PackageChild, out: *mut RawPull),
    /// Writes the `len` bytes at `bytes` to the child `handle`'s input,
    /// blocking, and answers true; or false, with the platform's words lent
    /// into `refused`.
    pub child_write: unsafe extern "C" fn(
        handle: *mut PackageChild,
        bytes: *const u8,
        len: usize,
        refused: *mut RawBuffer,
    ) -> bool,
    /// Releases the child `handle`, once, after its last call.
    pub child_release: unsafe extern "C" fn(handle: *mut PackageChild),
    /// Takes back a buffer the core lent.
    pub buffer_free: unsafe extern "C" fn(bytes: *mut u8, len: usize),
}

/// The process's one runtime, handed to every package library's init.
pub static RUNTIME: PackageRuntime = PackageRuntime {
    size: size_of::<PackageRuntime>(),
    register_service,
    complete,
    take_over,
    child_pull,
    child_write,
    child_release,
    buffer_free,
};

/// A streaming child taken over, as a handle the core owns: opaque to a
/// library, which holds a pointer to it from `take_over` until
/// `child_release`.
pub struct PackageChild(Box<dyn ChildStreams>);

impl std::fmt::Debug for PackageChild {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PackageChild").finish_non_exhaustive()
    }
}

/// A pull as it crosses ("How a pull crosses", in the module docs).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct RawPull {
    /// Whether frames, or the end, were delivered: false once the child was
    /// cancelled or its last delivery was pulled.
    pub delivered: bool,
    /// The words, lent: `words_len` bytes.
    pub words: *mut u8,
    /// The length of `words` in bytes, a multiple of eight.
    pub words_len: usize,
    /// The bytes, lent: `bytes_len` of them.
    pub bytes: *mut u8,
    /// The length of `bytes`.
    pub bytes_len: usize,
}

/// A buffer the core lends: a pointer and a length.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct RawBuffer {
    /// The bytes.
    pub bytes: *mut u8,
    /// How many.
    pub len: usize,
}

/// The tag a take-over refusal crosses as, 1 to 4. It matches every
/// variant of [`Refused`] on purpose: each refusal must cross as a tag of
/// its own, and a new one must be given one here.
pub const fn refusal_tag(refused: Refused) -> u32 {
    match refused {
        Refused::NoService => 1,
        Refused::NoSuchChild => 2,
        Refused::ReadPending => 3,
        Refused::Taken => 4,
    }
}

/// A pull, encoded: whether it delivered, its words and its bytes.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Encoded {
    /// Whether it delivered.
    pub delivered: bool,
    /// The words, as their little-endian bytes.
    pub words: Vec<u8>,
    /// The frames and the failed words, end to end.
    pub bytes: Vec<u8>,
}

impl Encoded {
    /// Lends both buffers, as a [`RawPull`].
    fn lend(self) -> RawPull {
        let (words, words_len) = buffer::lend(self.words);
        let (bytes, bytes_len) = buffer::lend(self.bytes);
        RawPull {
            delivered: self.delivered,
            words,
            words_len,
            bytes,
            bytes_len,
        }
    }
}

/// Encodes `pulled` as it crosses ("How a pull crosses"). It matches every
/// variant of [`Frames`] and [`Ended`] on purpose: each must cross, and a
/// new one must be given its words here.
pub fn encode(pulled: Pulled) -> Encoded {
    let Pulled::Delivered(delivery) = pulled else {
        return Encoded::default();
    };
    let mut encoded = Encoded {
        delivered: true,
        ..Encoded::default()
    };
    encoded.frames(delivery.out);
    encoded.frames(delivery.err);
    let end = match delivery.ended {
        None => [0, 0, 0, 0],
        Some(Ended::Exited { code }) => [1, i64::from(code).cast_unsigned(), 0, 0],
        Some(Ended::Signalled { signal }) => [2, i64::from(signal).cast_unsigned(), 0, 0],
        Some(Ended::LineTooLong { stream, bound }) => [3, stream_tag(stream), bound, 0],
        Some(Ended::MessageTooLong { stream, bound }) => [4, stream_tag(stream), bound, 0],
        Some(Ended::Failed(words)) => {
            let len = words.len() as u64;
            encoded.bytes.extend_from_slice(words.as_bytes());
            [5, 0, 0, len]
        }
    };
    for word in end {
        encoded.word(word);
    }
    encoded
}

impl Encoded {
    /// Appends `word`.
    fn word(&mut self, word: u64) {
        self.words.extend_from_slice(&word.to_le_bytes());
    }

    /// Appends one stream's framing, its frames' count and lengths, and
    /// their bytes.
    fn frames(&mut self, frames: Frames) {
        let (framing, frames) = match frames {
            Frames::Lines(lines) => (0, lines),
            Frames::Bytes(bytes) => (1, vec![bytes]),
            Frames::Messages(bodies) => (2, bodies),
        };
        self.word(framing);
        self.word(frames.len() as u64);
        for frame in frames {
            self.word(frame.len() as u64);
            self.bytes.extend_from_slice(&frame);
        }
    }
}

/// The number a stream crosses as: 0 standard output, 1 standard error.
const fn stream_tag(stream: Stream) -> u64 {
    match stream {
        Stream::Out => 0,
        Stream::Err => 1,
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

/// Takes `child` over from `source`, as the handle the core owns.
///
/// # Errors
///
/// The [`refusal_tag`] of the source's refusal.
pub fn take_over_from(source: &dyn StreamSource, child: u64) -> Result<Box<PackageChild>, u32> {
    source
        .take_over(child)
        .map(|streams| Box::new(PackageChild(streams)))
        .map_err(refusal_tag)
}

/// Pulls `child`, blocking, encoded.
pub fn pull_from(child: &PackageChild) -> Encoded {
    encode(child.0.pull())
}

/// Writes `bytes` to `child`'s input, blocking.
///
/// # Errors
///
/// The platform's words, as bytes, when the input is closed.
pub fn write_to(child: &PackageChild, bytes: &[u8]) -> Result<(), Vec<u8>> {
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

/// The runtime's `register_service` ([`register_named`]).
///
/// # Safety
///
/// `name` points to `len` readable bytes, unless `len` is zero.
#[expect(
    unsafe_code,
    reason = "a member of the runtime a package's library calls: it reads the name the library lends for the call"
)]
unsafe extern "C" fn register_service(name: *const u8, len: usize) -> u64 {
    // SAFETY: the library lends `len` readable bytes for the call.
    register_named(unsafe { buffer::borrow(name, len) })
}

/// The runtime's `complete` ([`complete_with`] over the process's
/// completion queue).
extern "C" fn complete(service: u64, request: u64) -> bool {
    complete_with(service, request, queue::complete)
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
unsafe extern "C" fn take_over(child: u64, handle: *mut *mut PackageChild) -> u32 {
    match take_over_from(&Provided, child) {
        Ok(child) => {
            // SAFETY: the library hands a writable pointer.
            unsafe { handle.write(Box::into_raw(child)) };
            0
        }
        Err(tag) => tag,
    }
}

/// The runtime's `child_pull` ([`pull_from`]).
///
/// # Safety
///
/// `handle` is a live handle from `take_over`, not yet released, and `out`
/// points to a writable [`RawPull`].
#[expect(
    unsafe_code,
    reason = "a member of the runtime a package's library calls: it reads the child's handle and fills the library's record"
)]
unsafe extern "C" fn child_pull(handle: *mut PackageChild, out: *mut RawPull) {
    // SAFETY: the library hands a live handle, which it releases only after
    // its last call.
    let child = unsafe { &*handle };
    let pull = pull_from(child).lend();
    // SAFETY: the library hands a writable record.
    unsafe { out.write(pull) };
}

/// The runtime's `child_write` ([`write_to`]).
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
    handle: *mut PackageChild,
    bytes: *const u8,
    len: usize,
    refused: *mut RawBuffer,
) -> bool {
    // SAFETY: the library hands a live handle, which it releases only after
    // its last call.
    let child = unsafe { &*handle };
    // SAFETY: the library lends `len` readable bytes for the call.
    let bytes = unsafe { buffer::borrow(bytes, len) };
    match write_to(child, bytes) {
        Ok(()) => true,
        Err(words) => {
            let (bytes, len) = buffer::lend(words);
            // SAFETY: the library hands a writable record.
            unsafe { refused.write(RawBuffer { bytes, len }) };
            false
        }
    }
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
unsafe extern "C" fn child_release(handle: *mut PackageChild) {
    // SAFETY: the handle is the box `take_over` gave up, released once.
    drop(unsafe { Box::from_raw(handle) });
}

/// The runtime's `buffer_free`.
///
/// # Safety
///
/// `bytes` and `len` are a buffer the core lent, handed back this once.
#[expect(
    unsafe_code,
    reason = "a member of the runtime a package's library calls: it takes back a buffer the core lent"
)]
unsafe extern "C" fn buffer_free(bytes: *mut u8, len: usize) {
    // SAFETY: the library hands back a buffer the core lent, once.
    unsafe { buffer::reclaim(bytes, len) };
}

#[cfg(test)]
mod tests;
