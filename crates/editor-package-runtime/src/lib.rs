//! The package runtime's C definitions: the contract between the core and
//! every package library (docs/design/packages.md, "The package runtime, as
//! built").
//!
//! The core hands a package's library its runtime, a [`PackageRuntime`],
//! at the library's init ([`PackageInit`], exported as
//! `editor_package_init`): its size, then a function pointer for each
//! capability of the core's. The core implements it
//! (`editor-package-library`'s `runtime`); a library builds against these
//! definitions, in Rust through this crate and in C, C++ or Zig through the
//! header generated from this file, `include/editor_package_runtime.h`
//! (`editor-package-runtime-header` generates it and fails a test when the
//! checked-in copy differs). This crate has no dependency, no build script
//! and no static, so a library carries nothing of the core's.
//!
//! # The members
//!
//! Every member takes the runtime it was read from as its first argument,
//! so a library may hold any number of runtimes and each answers for its
//! own state ([`PackageRuntime::private_members`]).
//!
//! | Member | What it does | Which threads | Blocks |
//! |---|---|---|---|
//! | `size` | The runtime's size in bytes, its version | Read by any | No |
//! | `private_members` | The core's own state, never read by a library | None | No |
//! | `register_service` | Registers a service by name and answers its id, at or above the first package id | Any | No |
//! | `complete` | Posts a completion of a request from the library's service to the completion queue; refused for a core service's id | Any | No |
//! | `post_event` | Posts a message (a code and a text) from the library's service to the editor queue; refused for a core service's id | Any | No |
//! | `take_over` | Takes over a streaming child the core's process service opened, as a handle ([`PackageChild`]) | Any, once per child | No |
//! | `child_pull` | The child's next delivery, framed as the process service frames it ("How a pull crosses") | One at a time per handle | Yes |
//! | `child_write` | Writes bytes to the child's input; a refusal lends the platform's words | One writer at a time per handle, beside a pull | Yes |
//! | `child_release` | Releases a handle, once, after its last pull and write have returned | Any | No |
//! | `buffer_lend` | Copies bytes into a buffer of the core's and lends it | Any | No |
//! | `buffer_free` | Hands back a buffer the core lent: true once, false for a second hand-back or a pointer never lent | Any | No |
//!
//! # The append-only rule
//!
//! A new capability is a new trailing member. No member is ever removed,
//! reordered or retyped, so a library built against an older, smaller
//! runtime runs on a newer one unchanged. A library checks that the
//! runtime it is handed has every member it calls before calling any of
//! them: [`runtime_has!`] in Rust, `EDITOR_PACKAGE_RUNTIME_HAS` in C, or
//! `size` against the end of the last member it requires; and answers
//! [`INIT_RUNTIME_TOO_SMALL`] when it does not. The layout test of this
//! crate pins each member's slot, the generated header shows every change
//! in review, and `editor-package-library`'s contract runs a library built
//! for an older prefix on the current runtime.
//!
//! # Who owns what
//!
//! - **The runtime** is the core's, for the life of the process. A library
//!   may keep the pointer and call it from the threads each member allows.
//! - **`private_members`** is the core's state behind the runtime, opaque:
//!   a library never reads or writes it.
//! - **A child handle** is made by the core in `take_over` and owned by the
//!   core until the library releases it, once, through `child_release`.
//! - **A buffer the core lends** (a pull's words and bytes, a refused
//!   write's words, `buffer_lend`'s) is the library's to read until it
//!   hands it back, exactly once, through `buffer_free`. The core frees it
//!   with its own allocator: each side frees what its own allocator made.
//! - **A buffer the library lends** (a reply through its own table) stays
//!   the library's, freed through the library's own table.
//! - **Bytes handed in** (a name, a text, a write's bytes) are borrowed for
//!   the call and copied.
//! - **A library's table**, written at its init, is the library's, valid
//!   for the life of the process: a library is never unloaded.
//!
//! # How a pull crosses
//!
//! A [`RawPull`]: whether something was delivered, and two buffers, both
//! lent. A cancelled pull is `delivered = false` with both buffers empty,
//! and both are still handed back.
//!
//! The words are little-endian `u64`s, eight bytes each:
//!
//! | Words | |
//! |---|---|
//! | standard output's framing ([`FRAMING_LINES`], [`FRAMING_BYTES`], [`FRAMING_MESSAGES`]) | |
//! | its count of frames | the length of each (bytes are one frame) |
//! | the same for standard error | |
//! | the end ([`END_NONE`] to [`END_FAILED`]) | |
//! | two values: the status or the signal, two's complement, and 0; or the stream ([`STREAM_OUT`], [`STREAM_ERR`]) and its bound; or 0 and 0 | |
//! | the failed words' length, else 0 | |
//!
//! The bytes are standard output's frames, standard error's, and the
//! failed words, end to end.
//!
//! # Where an addition goes
//!
//! A new capability is a member appended to [`PackageRuntime`], a row
//! appended to this crate's layout table, the header regenerated, and in
//! `editor-package-library` its real forwarder, its model member and a
//! property of the runtime's contract.

#![deny(unsafe_code)]

use std::ffi::c_void;

/// The core's private state behind a runtime: opaque, never read by a
/// library.
pub struct PackageRuntimePrivate {
    /// Nothing a library can name.
    _opaque: [u8; 0],
}

/// A streaming child taken over: opaque, the core's, from `take_over` to
/// `child_release`.
pub struct PackageChild {
    /// Nothing a library can name.
    _opaque: [u8; 0],
}

/// The runtime the core hands a package's library at its init: its size,
/// the core's private state, then a function pointer for each capability,
/// only ever appended to (the crate docs, "The append-only rule").
#[repr(C)]
#[derive(Debug)]
pub struct PackageRuntime {
    /// The runtime's size in bytes: its version. A library checks it
    /// before it calls a member past those it requires.
    pub size: usize,
    /// The core's state behind this runtime: a library never reads it.
    pub private_members: *mut PackageRuntimePrivate,
    /// Registers a service of the `len` bytes of name at `name`, borrowed
    /// for the call and read as UTF-8, and answers its id: the id its
    /// completions and events carry. Any thread; never blocks.
    pub register_service:
        unsafe extern "C" fn(runtime: *const PackageRuntime, name: *const u8, len: usize) -> u64,
    /// Posts the completion of the request `request` from the service
    /// `service` to the completion queue, and answers whether it was
    /// accepted: false, with nothing posted, for an id below the first
    /// package id (a core service's), and when the queue was quit. Any
    /// thread; never blocks.
    pub complete:
        unsafe extern "C" fn(runtime: *const PackageRuntime, service: u64, request: u64) -> bool,
    /// Posts a message from the service `service` to the editor queue: the
    /// number `code` and the `len` bytes of text at `text`, borrowed for
    /// the call and read as UTF-8. Answers whether it was accepted: false,
    /// with nothing posted, for a core service's id, and when the queue
    /// was quit. Any thread; never blocks.
    pub post_event: unsafe extern "C" fn(
        runtime: *const PackageRuntime,
        service: u64,
        code: u64,
        text: *const u8,
        len: usize,
    ) -> bool,
    /// Takes the streaming child `child` over and writes its handle to
    /// `handle`, answering 0; or answers a refusal's tag
    /// ([`TAKE_OVER_NO_SERVICE`] to [`TAKE_OVER_TAKEN`]) and writes
    /// nothing. Any thread, once per child; never blocks.
    pub take_over: unsafe extern "C" fn(
        runtime: *const PackageRuntime,
        child: u64,
        handle: *mut *mut PackageChild,
    ) -> u32,
    /// Pulls the child `handle`, blocking until something is deliverable,
    /// the child has ended or it was cancelled, and fills `out` ("How a
    /// pull crosses"). One thread at a time per handle.
    pub child_pull: unsafe extern "C" fn(
        runtime: *const PackageRuntime,
        handle: *mut PackageChild,
        out: *mut RawPull,
    ),
    /// Writes the `len` bytes at `bytes`, borrowed for the call, to the
    /// child `handle`'s input, blocking until they are in its pipe, and
    /// answers true; or false, with the platform's words lent into
    /// `refused`. One writer at a time per handle, which may run beside a
    /// pull.
    pub child_write: unsafe extern "C" fn(
        runtime: *const PackageRuntime,
        handle: *mut PackageChild,
        bytes: *const u8,
        len: usize,
        refused: *mut RawBuffer,
    ) -> bool,
    /// Releases the child `handle`, once, after its last pull and write
    /// have returned. Any thread; never blocks.
    pub child_release:
        unsafe extern "C" fn(runtime: *const PackageRuntime, handle: *mut PackageChild),
    /// Copies the `len` bytes at `bytes`, borrowed for the call, into a
    /// buffer of the core's and lends it into `out`, to be handed back
    /// through `buffer_free`. Any thread; never blocks.
    pub buffer_lend: unsafe extern "C" fn(
        runtime: *const PackageRuntime,
        bytes: *const u8,
        len: usize,
        out: *mut RawBuffer,
    ),
    /// Hands back a buffer the core lent, which the core frees, and
    /// answers true; or answers false, freeing nothing, for a buffer
    /// handed back already or a pointer the core never lent. A library
    /// hands each buffer back exactly once. Any thread; never blocks.
    pub buffer_free:
        unsafe extern "C" fn(runtime: *const PackageRuntime, bytes: *mut u8, len: usize) -> bool,
}

// SAFETY: every member may be called from the threads its docs allow, and
// `private_members` is read only by the core's own members, which keep the
// state behind it safe to share.
#[expect(
    unsafe_code,
    reason = "a runtime is shared by every thread of a library: its one pointer is the core's state, read only by the core's members"
)]
unsafe impl Send for PackageRuntime {}

// SAFETY: as for `Send`.
#[expect(
    unsafe_code,
    reason = "a runtime is shared by every thread of a library: its one pointer is the core's state, read only by the core's members"
)]
unsafe impl Sync for PackageRuntime {}

/// A pull as it crosses (the crate docs, "How a pull crosses").
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

/// A package library's init, the one symbol the core asks a library for,
/// exported as `editor_package_init`, in the shape of Emacs's
/// `emacs_module_init`: it is handed the core's runtime and a place for its
/// table, and answers [`INIT_LOADED`] once it has written its table there,
/// or [`INIT_RUNTIME_TOO_SMALL`] when the runtime lacks a member it
/// requires, the table left unwritten. The table's type is the package's
/// own, opaque to the core.
pub type PackageInit =
    unsafe extern "C" fn(runtime: *const PackageRuntime, table: *mut *const c_void) -> u32;

/// An init's status: loaded, its table written.
pub const INIT_LOADED: u32 = 0;
/// An init's status: the runtime lacks a member the library requires, its
/// table unwritten.
pub const INIT_RUNTIME_TOO_SMALL: u32 = 1;

/// A take-over refused: no process service has been provided.
pub const TAKE_OVER_NO_SERVICE: u32 = 1;
/// A take-over refused: no live streaming child of that number.
pub const TAKE_OVER_NO_SUCH_CHILD: u32 = 2;
/// A take-over refused: the job has a read of the child pending.
pub const TAKE_OVER_READ_PENDING: u32 = 3;
/// A take-over refused: the child was taken over already.
pub const TAKE_OVER_TAKEN: u32 = 4;

/// A stream's framing, in a pull's words: lines.
pub const FRAMING_LINES: u64 = 0;
/// A stream's framing, in a pull's words: bytes, as one frame.
pub const FRAMING_BYTES: u64 = 1;
/// A stream's framing, in a pull's words: `Content-Length` messages.
pub const FRAMING_MESSAGES: u64 = 2;

/// How a child ended, in a pull's words: not yet.
pub const END_NONE: u64 = 0;
/// How a child ended, in a pull's words: it exited, with its status.
pub const END_EXITED: u64 = 1;
/// How a child ended, in a pull's words: a signal, with its number.
pub const END_SIGNALLED: u64 = 2;
/// How a child ended, in a pull's words: a line longer than the bound,
/// with its stream and the bound.
pub const END_LINE_TOO_LONG: u64 = 3;
/// How a child ended, in a pull's words: a message longer than the bound,
/// with its stream and the bound.
pub const END_MESSAGE_TOO_LONG: u64 = 4;
/// How a child ended, in a pull's words: a failure, with its words'
/// length, its words last among the bytes.
pub const END_FAILED: u64 = 5;

/// A stream, in a pull's words: standard output.
pub const STREAM_OUT: u64 = 0;
/// A stream, in a pull's words: standard error.
pub const STREAM_ERR: u64 = 1;

/// Whether the runtime at the pointer `runtime` has the member `member`:
/// whether its `size`, read alone first, covers the member's end. A
/// library asks it before it calls a member past those it requires (the
/// crate docs, "The append-only rule"). The header's
/// `EDITOR_PACKAGE_RUNTIME_HAS` is its C twin.
///
/// It reads through a raw pointer, so it is used inside `unsafe`.
///
/// # Safety
///
/// `runtime` points to a runtime, which holds at least its `size`.
#[macro_export]
macro_rules! runtime_has {
    ($runtime:expr, $member:ident) => {{
        let runtime: *const $crate::PackageRuntime = $runtime;
        ::core::ptr::addr_of!((*runtime).size).read()
            >= ::core::mem::offset_of!($crate::PackageRuntime, $member)
                + ::core::mem::size_of::<usize>()
    }};
}

#[cfg(test)]
mod tests {
    use std::mem::{offset_of, size_of};

    use super::*;

    /// The rows of [`LAYOUT`]: each member's name and offset, in the order
    /// given.
    macro_rules! layout {
        ($($member:ident),* $(,)?) => {
            [$((stringify!($member), offset_of!(PackageRuntime, $member))),*]
        };
    }

    /// The runtime's members in order, one row each, its slot the row's
    /// index. Rows are only ever appended: a member is never removed,
    /// reordered or retyped, so an edit to any row but a new last one is a
    /// break of every library built before it.
    const LAYOUT: [(&str, usize); 11] = layout![
        size,
        private_members,
        register_service,
        complete,
        post_event,
        take_over,
        child_pull,
        child_write,
        child_release,
        buffer_lend,
        buffer_free,
    ];

    #[test]
    fn each_member_sits_in_its_slot_and_the_runtime_is_its_rows_long() {
        for (slot, (member, offset)) in LAYOUT.iter().enumerate() {
            assert_eq!(*offset, slot * size_of::<usize>(), "{member}");
        }
        assert_eq!(
            size_of::<PackageRuntime>(),
            LAYOUT.len() * size_of::<usize>()
        );
    }

    /// A runtime's first words, the size first, the rest zero: as much of
    /// a runtime as `runtime_has!` reads.
    fn sized(size: usize) -> [usize; 12] {
        let mut words = [0; 12];
        words[0] = size;
        words
    }

    /// Whether a runtime saying it is `size` bytes has `member`.
    macro_rules! has {
        ($size:expr, $member:ident) => {{
            let words = sized($size);
            #[expect(
                unsafe_code,
                reason = "reads the size of a runtime made here, as a library reads the runtime it is handed"
            )]
            // SAFETY: the words are as large as the runtime and live for
            // the call.
            let has = unsafe { runtime_has!(words.as_ptr().cast::<PackageRuntime>(), $member) };
            has
        }};
    }

    #[test]
    fn a_runtime_ending_at_a_member_has_it_and_not_the_next() {
        let through_complete = offset_of!(PackageRuntime, complete) + size_of::<usize>();
        assert!(has!(through_complete, complete));
        assert!(!has!(through_complete, post_event));
        assert!(has!(size_of::<PackageRuntime>(), buffer_free));
        assert!(!has!(size_of::<PackageRuntime>() - 1, buffer_free));
        assert!(has!(size_of::<PackageRuntime>() + 8, buffer_free));
        assert!(!has!(0, size), "not even its size");
    }

    #[test]
    fn each_kind_of_tag_is_numbered_from_its_documented_start() {
        assert_eq!([INIT_LOADED, INIT_RUNTIME_TOO_SMALL], [0, 1]);
        assert_eq!(
            [
                TAKE_OVER_NO_SERVICE,
                TAKE_OVER_NO_SUCH_CHILD,
                TAKE_OVER_READ_PENDING,
                TAKE_OVER_TAKEN
            ],
            [1, 2, 3, 4]
        );
        assert_eq!([FRAMING_LINES, FRAMING_BYTES, FRAMING_MESSAGES], [0, 1, 2]);
        assert_eq!(
            [
                END_NONE,
                END_EXITED,
                END_SIGNALLED,
                END_LINE_TOO_LONG,
                END_MESSAGE_TOO_LONG,
                END_FAILED
            ],
            [0, 1, 2, 3, 4, 5]
        );
        assert_eq!([STREAM_OUT, STREAM_ERR], [0, 1]);
    }
}
