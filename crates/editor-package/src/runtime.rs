//! The runtime the core hands a package's library at its init, as a safe
//! handle: [`Runtime`].
//!
//! A [`Runtime`] is made only by the package's export
//! ([`crate::Package::export`]), once the runtime it is handed is at least
//! [`REQUIRED`] long, and by the fake ([`crate::fake::FakeRuntime`]). It
//! registers the package's services ([`Runtime::register`]), takes a
//! streaming child over ([`Runtime::take_over`], and as a
//! [`StreamSource`]) and lends bytes into a buffer of the core's
//! ([`Runtime::lend`]). It is `Copy`, and threads keep it: the runtime
//! lives for the process.
//!
//! `Calls` reads every member of a runtime, each handed the runtime first:
//! the one place the wrapper calls the runtime's C members, and a marked
//! `unsafe` site, as is [`Runtime`]'s `from_raw`. It holds the runtime as a
//! pointer and reads each member alone through that member's own place
//! (`member!`), never through a reference to the whole `PackageRuntime`:
//! an older core's runtime may end before the struct this crate is built
//! against does, and a reference to a struct longer than the memory under
//! it is undefined behaviour even if the missing members are never read.

use std::mem::{offset_of, size_of};
use std::ptr::{self, NonNull};

use editor_package_runtime::{
    PackageChild, PackageRuntime, RawBuffer, RawPull, TAKE_OVER_NO_SUCH_CHILD,
    TAKE_OVER_READ_PENDING, TAKE_OVER_TAKEN, runtime_has,
};

use crate::buffer::CoreBuffer;
use crate::service::Service;
use crate::stream::{Child, ChildStreams, Refused, StreamSource};

/// The smallest runtime the wrapper takes: one that ends at `buffer_free`,
/// the whole of the runtime phase 2 made, and so the first a library can
/// meet, as `runtime_has!` computes it. A member appended later is read
/// (`member!`) and called only after `runtime_has!` asks for it, in the
/// method that calls it.
pub const REQUIRED: usize = offset_of!(PackageRuntime, buffer_free) + size_of::<usize>();

/// The runtime the core handed a package's library: a safe handle over
/// its members. `Copy`; the runtime lives for the process.
#[derive(Debug, Clone, Copy)]
pub struct Runtime {
    /// Its members.
    calls: Calls,
}

impl Runtime {
    /// The runtime `runtime`, whole.
    pub(crate) const fn over(runtime: &'static PackageRuntime) -> Self {
        Self {
            calls: Calls::over(runtime),
        }
    }

    /// The runtime at `runtime`, once its `size`, read alone first, says
    /// it is at least [`REQUIRED`] long: none for a null pointer or a
    /// smaller runtime, of which nothing past its size is read.
    ///
    /// # Safety
    ///
    /// `runtime` is null, or points to a runtime at least as long as its
    /// `size` says, which lives for the process.
    #[expect(
        unsafe_code,
        reason = "takes the runtime the core hands a library's init, once its size says every member the wrapper calls is there"
    )]
    pub(crate) unsafe fn from_raw(runtime: *const PackageRuntime) -> Option<Self> {
        let runtime = NonNull::new(runtime.cast_mut())?;
        // SAFETY: the runtime holds at least its size, read alone.
        if !unsafe { runtime_has!(runtime.as_ptr(), buffer_free) } {
            return None;
        }
        // SAFETY: the runtime holds every member through `buffer_free`,
        // which may be less than the whole of `PackageRuntime` (an older
        // core's), and lives for the process.
        Some(Self {
            calls: unsafe { Calls::at(runtime) },
        })
    }

    /// Registers a service named `name` through the runtime's
    /// `register_service`.
    pub fn register(self, name: &str) -> Service {
        Service::registered(self.calls, self.calls.register(name.as_bytes()))
    }

    /// Takes the streaming child `child` over through the runtime's
    /// `take_over`.
    ///
    /// # Errors
    ///
    /// The refusal the runtime's tag stands for; a tag no refusal crosses
    /// as reads as [`Refused::NoService`].
    pub fn take_over(self, child: u64) -> Result<Child, Refused> {
        self.calls
            .take_over(child)
            .map(|handle| Child::taken(self.calls, handle))
            .map_err(refused_of_tag)
    }

    /// Copies `bytes` into a buffer of the core's, lent through the
    /// runtime's `buffer_lend` and handed back when it drops.
    pub fn lend(self, bytes: &[u8]) -> CoreBuffer {
        let lent = self.calls.lend(bytes);
        CoreBuffer::lent(self.calls, lent.bytes, lent.len)
    }

    /// The runtime's size in bytes, its version: at least [`REQUIRED`].
    pub fn size(self) -> usize {
        self.calls.size()
    }
}

impl StreamSource for Runtime {
    fn take_over(&self, child: u64) -> Result<Box<dyn ChildStreams>, Refused> {
        Self::take_over(*self, child).map(|child| Box::new(child) as Box<dyn ChildStreams>)
    }
}

/// The refusal a take-over's tag stands for: one of the four the runtime
/// crosses as, or [`Refused::NoService`] for a tag none crosses as.
const fn refused_of_tag(tag: u32) -> Refused {
    match tag {
        TAKE_OVER_NO_SUCH_CHILD => Refused::NoSuchChild,
        TAKE_OVER_READ_PENDING => Refused::ReadPending,
        TAKE_OVER_TAKEN => Refused::Taken,
        _ => Refused::NoService,
    }
}

/// The member `$member` of the runtime `$calls` holds, read alone through
/// its own place: no reference to the whole runtime is formed, so a
/// runtime shorter than `PackageRuntime` is read only where it has memory.
/// Used inside an `unsafe` block of [`Calls`], for a member through
/// `buffer_free` (every runtime `Calls` holds has it) or one a
/// `runtime_has!` has just asked for.
macro_rules! member {
    ($calls:expr, $member:ident) => {
        ptr::addr_of!((*$calls.raw()).$member).read()
    };
}

/// A runtime's members, called as a library calls them: each handed the
/// runtime first. Made only over a runtime at least [`REQUIRED`] long, so
/// every member through `buffer_free` is there; it holds the runtime as a
/// pointer, since the runtime may be shorter than `PackageRuntime`, and
/// reads each member alone (`member!`), a member past `buffer_free` only
/// after `runtime_has!` asks for it. A child handle it is handed is a live
/// one from its `take_over`, not yet released; each buffer it lends is
/// handed back once (`crate::buffer::CoreBuffer`).
#[derive(Debug, Clone, Copy)]
pub(crate) struct Calls(NonNull<PackageRuntime>);

// SAFETY: the runtime lives for the process and is shared by every thread
// of a library (`PackageRuntime` is `Send` and `Sync`, the definitions'
// rule); `Calls` only reads its members and calls them from the threads
// each allows, as a `&'static PackageRuntime` would.
#[expect(
    unsafe_code,
    reason = "a runtime's members are called from any thread of a library: `Calls` holds the runtime as a pointer only so as not to claim more of it than is there"
)]
unsafe impl Send for Calls {}

// SAFETY: as for `Send`.
#[expect(
    unsafe_code,
    reason = "a runtime's members are called from any thread of a library: `Calls` holds the runtime as a pointer only so as not to claim more of it than is there"
)]
unsafe impl Sync for Calls {}

#[expect(
    unsafe_code,
    reason = "reads a runtime's members, each alone, and calls them as a library does: bytes lent for the call, records filled, a child's handle handed back to the runtime that made it"
)]
impl Calls {
    /// The members of `runtime`, the whole of `PackageRuntime`, which is
    /// at least [`REQUIRED`] long.
    pub(crate) const fn over(runtime: &'static PackageRuntime) -> Self {
        Self(NonNull::from_ref(runtime))
    }

    /// The members of the runtime at `runtime`.
    ///
    /// # Safety
    ///
    /// `runtime` points to a runtime of at least [`REQUIRED`] bytes, which
    /// may be fewer than `PackageRuntime`'s, and which lives for the
    /// process.
    pub(crate) const unsafe fn at(runtime: NonNull<PackageRuntime>) -> Self {
        Self(runtime)
    }

    /// The runtime, as its members take it.
    const fn raw(self) -> *const PackageRuntime {
        self.0.as_ptr().cast_const()
    }

    /// `size`: the runtime's length in bytes.
    pub(crate) fn size(self) -> usize {
        // SAFETY: `size` is the first member, in every runtime.
        unsafe { member!(self, size) }
    }

    /// `register_service`.
    pub(crate) fn register(self, name: &[u8]) -> u64 {
        // SAFETY: the member is there (through `buffer_free`); the name is
        // lent for the call.
        unsafe { member!(self, register_service)(self.raw(), name.as_ptr(), name.len()) }
    }

    /// `complete`.
    pub(crate) fn complete(self, service: u64, request: u64) -> bool {
        // SAFETY: the member is there (through `buffer_free`), handed the
        // runtime it was read from.
        unsafe { member!(self, complete)(self.raw(), service, request) }
    }

    /// `post_event`.
    pub(crate) fn post(self, service: u64, code: u64, text: &[u8]) -> bool {
        // SAFETY: the member is there (through `buffer_free`); the text is
        // lent for the call.
        unsafe { member!(self, post_event)(self.raw(), service, code, text.as_ptr(), text.len()) }
    }

    /// `take_over`: the handle, or the refusal's tag.
    pub(crate) fn take_over(self, child: u64) -> Result<*mut PackageChild, u32> {
        let mut handle = ptr::null_mut();
        // SAFETY: the member is there (through `buffer_free`); the handle's
        // place is writable.
        match unsafe { member!(self, take_over)(self.raw(), child, &raw mut handle) } {
            0 => Ok(handle),
            tag => Err(tag),
        }
    }

    /// `child_pull`: the record, its buffers lent.
    pub(crate) fn pull(self, handle: *mut PackageChild) -> RawPull {
        let mut out = RawPull {
            delivered: false,
            words: ptr::null_mut(),
            words_len: 0,
            bytes: ptr::null_mut(),
            bytes_len: 0,
        };
        // SAFETY: the member is there (through `buffer_free`); the handle
        // is a live one of this runtime's (the type's rule); the record is
        // writable.
        unsafe { member!(self, child_pull)(self.raw(), handle, &raw mut out) };
        out
    }

    /// `child_write`: written, or the refusal's words, lent.
    pub(crate) fn write(self, handle: *mut PackageChild, bytes: &[u8]) -> Result<(), RawBuffer> {
        let mut refused = RawBuffer {
            bytes: ptr::null_mut(),
            len: 0,
        };
        // SAFETY: the member is there (through `buffer_free`); the handle
        // is a live one of this runtime's; the bytes are lent for the call
        // and the record is writable.
        let written = unsafe {
            member!(self, child_write)(
                self.raw(),
                handle,
                bytes.as_ptr(),
                bytes.len(),
                &raw mut refused,
            )
        };
        if written { Ok(()) } else { Err(refused) }
    }

    /// `child_release`.
    pub(crate) fn release(self, handle: *mut PackageChild) {
        // SAFETY: the member is there (through `buffer_free`); the handle
        // is a live one of this runtime's, released this once, after its
        // last call.
        unsafe { member!(self, child_release)(self.raw(), handle) };
    }

    /// `buffer_lend`: the buffer, lent.
    pub(crate) fn lend(self, bytes: &[u8]) -> RawBuffer {
        let mut out = RawBuffer {
            bytes: ptr::null_mut(),
            len: 0,
        };
        // SAFETY: the member is there (through `buffer_free`); the bytes
        // are lent for the call; the record is writable.
        unsafe {
            member!(self, buffer_lend)(self.raw(), bytes.as_ptr(), bytes.len(), &raw mut out)
        };
        out
    }

    /// `buffer_free`.
    pub(crate) fn free(self, bytes: *mut u8, len: usize) -> bool {
        // SAFETY: the member is there (it ends every runtime `Calls`
        // holds); it takes any pointer: one it did not lend, or lent and
        // handed back already, is refused unread.
        unsafe { member!(self, buffer_free)(self.raw(), bytes, len) }
    }
}

#[cfg(test)]
mod tests;
