//! The runtime's fake, published so that a package's crate tests its
//! library, its init and its table with `cargo test` alone:
//! [`FakeRuntime`], a real [`PackageRuntime`] whose members act on state of
//! its own, behind its `private_members`.
//!
//! Its state:
//!
//! - an id counter from 1024, the core's first package id
//!   (docs/design/packages.md, "The package runtime, as built": the ids
//!   below it are the core's services'), a completion or an event of an id
//!   below it refused, as the core's runtime refuses it;
//! - its registrations, with their names ([`FakeRuntime::services`]);
//! - its completions and its events, each queued once, oldest first
//!   ([`FakeRuntime::next_completion`], [`FakeRuntime::next_event`]), and a
//!   wait on one completion ([`FakeRuntime::wait_completed`]);
//! - its own ledger of the buffers it lent, a multiset of address and
//!   length, so a second hand-back, or a pointer never lent, is refused
//!   ([`FakeRuntime::outstanding`]);
//! - the source it takes children from: a [`ScriptedSource`] by default,
//!   or any [`StreamSource`] ([`FakeRuntime::over`]); each pull it encodes
//!   as the core does ([`crate::wire::encode`]), its buffers lent.
//!
//! It starts no thread, and every member runs on its caller's thread. Any
//! number live in one process, each independent. The runtime's contract
//! (`editor-package-library`'s) runs on it from `editor-package-check`'s
//! `tests/contract.rs`, as on the core's model and its real runtime, so the
//! fake cannot drift from the runtime the core hands a library.
//!
//! A fake is leaked to be used ([`FakeRuntime::leak`]), memory only, as
//! the core's runtime lives for the process: a library may keep its
//! runtime, and threads keep a [`Runtime`].
//!
//! The fake's C members and its [`FakeRuntime::init`] are its marked
//! `unsafe` sites.

use std::collections::{BTreeMap, VecDeque};
use std::ffi::c_void;
use std::mem::size_of;
use std::ptr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Condvar, Mutex, MutexGuard, PoisonError};

use editor_package_runtime::{
    PackageChild, PackageInit, PackageRuntime, PackageRuntimePrivate, RawBuffer, RawPull,
    TAKE_OVER_NO_SERVICE, TAKE_OVER_NO_SUCH_CHILD, TAKE_OVER_READ_PENDING, TAKE_OVER_TAKEN,
};
use editor_wait::HangGuard;

use crate::runtime::Runtime;
use crate::stream::fake::ScriptedSource;
use crate::stream::{ChildStreams, InputClosed, Refused, StreamSource};
use crate::wire;

/// The first id a service is given: the ids below it are the core's
/// services' (docs/design/packages.md, "The package runtime, as built"),
/// whose completions and events a library may not post.
const FIRST_PACKAGE_ID: u64 = 1024;

/// What a fake's members act on: `private_members` points here.
struct State {
    /// The next service's id.
    next: AtomicU64,
    /// The services registered, in order: their names and ids.
    services: Mutex<Vec<(String, u64)>>,
    /// The completions posted, oldest first: their service and request.
    completions: Mutex<VecDeque<(u64, u64)>>,
    /// Signalled at each completion.
    completed: Condvar,
    /// The events posted, oldest first: their service, code and text.
    events: Mutex<VecDeque<(u64, u64, String)>>,
    /// Signalled at each event.
    posted: Condvar,
    /// The buffers lent and not yet handed back: how many at each address
    /// and length.
    lent: Mutex<BTreeMap<(usize, usize), usize>>,
    /// The source children are taken over from.
    source: &'static dyn StreamSource,
}

/// Locks `mutex`. No lock of the fake is held while a caller's code runs.
fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

impl State {
    /// Lends `bytes` as a buffer, recorded as outstanding.
    fn lend(&self, bytes: Vec<u8>) -> RawBuffer {
        let bytes = bytes.into_boxed_slice();
        let len = bytes.len();
        let bytes: *mut u8 = Box::into_raw(bytes).cast();
        *locked(&self.lent).entry((bytes.addr(), len)).or_default() += 1;
        RawBuffer { bytes, len }
    }

    /// Takes back the buffer at `bytes` of `len` bytes and frees it,
    /// answering true, when it is outstanding; otherwise answers false and
    /// frees nothing.
    fn reclaim(&self, bytes: *mut u8, len: usize) -> bool {
        {
            let mut lent = locked(&self.lent);
            let key = (bytes.addr(), len);
            match lent.get_mut(&key) {
                None => return false,
                Some(1) => {
                    lent.remove(&key);
                }
                Some(count) => *count -= 1,
            }
        }
        #[expect(
            unsafe_code,
            reason = "frees a buffer the fake lent and still held as outstanding, which it has just struck off"
        )]
        // SAFETY: the fake lent a boxed slice of this address and length
        // and it was outstanding: struck off above, under the lock, so it
        // is freed this once.
        unsafe {
            drop(Box::from_raw(ptr::slice_from_raw_parts_mut(bytes, len)));
        }
        true
    }
}

/// A runtime from a newer core: the current members, then one more.
#[repr(C)]
struct Later {
    /// The current runtime.
    runtime: PackageRuntime,
    /// A member appended after the current ones.
    later: extern "C" fn(),
}

/// The runtime's fake: a runtime, and the state its members act on.
pub struct FakeRuntime {
    /// What the members act on, boxed so that its address stays put.
    state: Box<State>,
    /// The runtime, inside room for one later member.
    runtime: Box<Later>,
}

impl std::fmt::Debug for FakeRuntime {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FakeRuntime")
            .field("size", &self.runtime.runtime.size)
            .field("services", &self.services())
            .finish_non_exhaustive()
    }
}

impl Default for FakeRuntime {
    fn default() -> Self {
        Self::new()
    }
}

impl FakeRuntime {
    /// A fake of the current runtime, over a scripted source with no
    /// child: its `size` is `size_of::<PackageRuntime>()`.
    pub fn new() -> Self {
        Self::over(Box::leak(Box::new(ScriptedSource::new())))
    }

    /// A fake of the current runtime whose `take_over` takes children from
    /// `source`.
    pub fn over(source: &'static dyn StreamSource) -> Self {
        let state = Box::new(State {
            next: AtomicU64::new(FIRST_PACKAGE_ID),
            services: Mutex::new(Vec::new()),
            completions: Mutex::new(VecDeque::new()),
            completed: Condvar::new(),
            events: Mutex::new(VecDeque::new()),
            posted: Condvar::new(),
            lent: Mutex::new(BTreeMap::new()),
            source,
        });
        let private_members = ptr::from_ref::<State>(&state)
            .cast_mut()
            .cast::<PackageRuntimePrivate>();
        let runtime = Box::new(Later {
            runtime: PackageRuntime {
                size: size_of::<PackageRuntime>(),
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
            },
            later,
        });
        Self { state, runtime }
    }

    /// This fake as a runtime from a newer core: embedded in a larger
    /// struct with one more member, its `size` the larger one's.
    #[must_use]
    pub fn later(self) -> Self {
        self.sized(size_of::<Later>())
    }

    /// This fake with its `size` saying `bytes`: smaller than the runtime,
    /// for a library's refusal of a runtime too small, or up to the newer
    /// core's ([`FakeRuntime::later`]). Its members stay, but a library
    /// reads none past the size.
    ///
    /// # Panics
    ///
    /// If `bytes` is more than the fake holds (the newer core's runtime,
    /// its one member past the current ones included): a size larger than
    /// the memory under it would have a library that checks a member's
    /// presence by the size (`runtime_has!`) read past it, from safe code.
    #[must_use]
    pub fn sized(mut self, bytes: usize) -> Self {
        assert!(
            bytes <= size_of::<Later>(),
            "a fake's size says no more than it holds: {bytes} bytes asked, {} held",
            size_of::<Later>()
        );
        self.runtime.runtime.size = bytes;
        self
    }

    /// The fake, kept for the life of the process, as the core's runtime
    /// is: memory only, since a fake starts no thread and holds no file.
    pub fn leak(self) -> &'static Self {
        Box::leak(Box::new(self))
    }

    /// The runtime, as a package's init is handed it by the wrapper.
    pub fn runtime(&'static self) -> Runtime {
        Runtime::over(self.raw())
    }

    /// The runtime, as a library is handed it.
    pub fn raw(&'static self) -> &'static PackageRuntime {
        &self.runtime.runtime
    }

    /// The services registered, in order: each name and id.
    pub fn services(&self) -> Vec<(String, u64)> {
        locked(&self.state.services).clone()
    }

    /// The next completion posted, as its service and request; none when
    /// there is none.
    pub fn next_completion(&self) -> Option<(u64, u64)> {
        locked(&self.state.completions).pop_front()
    }

    /// The next event posted, as its service, code and text; none when
    /// there is none.
    pub fn next_event(&self) -> Option<(u64, u64, String)> {
        locked(&self.state.events).pop_front()
    }

    /// How many buffers the fake lent that are not yet handed back.
    pub fn outstanding(&self) -> usize {
        locked(&self.state.lent).values().sum()
    }

    /// Waits until the completion of `request` from `service` is queued,
    /// and says whether it is: false only once `guard` has run out first.
    /// The request's own signal, as `RecordingCompleter::wait_reported`
    /// is: a test that made a request waits on that one completion, never
    /// on how many there are. It takes nothing off the queue.
    pub fn wait_completed(&self, service: u64, request: u64, guard: HangGuard) -> bool {
        let completions = locked(&self.state.completions);
        let (_completions, completed) =
            editor_wait::wait_while(&self.state.completed, completions, guard, |completions| {
                !completions.contains(&(service, request))
            });
        completed
    }

    /// Calls a library's init `init` with this runtime and a writable place
    /// for its table, as the core's load does: its status, and what it
    /// wrote there (null if nothing). So a package's test calls its init
    /// with no `unsafe` of its own.
    pub fn init(&'static self, init: PackageInit) -> (u32, *const c_void) {
        let mut table: *const c_void = ptr::null();
        #[expect(
            unsafe_code,
            reason = "calls a library's init as the core's load does, handing it this runtime and a writable place"
        )]
        // SAFETY: the runtime lives for the process and is at least as
        // large as its size says (`sized` refuses a size larger than the
        // `Later` it lives in), and the table's place is writable.
        let status = unsafe { init(self.raw(), &raw mut table) };
        (status, table)
    }
}

/// The state of the fake whose runtime is `runtime`.
///
/// # Safety
///
/// `runtime` is a fake's runtime, and the fake outlives `'a`.
#[expect(
    unsafe_code,
    reason = "a fake's member finds its state through the runtime it is handed"
)]
unsafe fn state<'a>(runtime: *const PackageRuntime) -> &'a State {
    // SAFETY: a fake's runtime's `private_members` points to its state,
    // which lives as long as the fake.
    unsafe { &*(*runtime).private_members.cast::<State>() }
}

/// The `len` bytes at `bytes`, borrowed for the call.
///
/// # Safety
///
/// `bytes` points to `len` readable bytes, unless `len` is zero.
#[expect(
    unsafe_code,
    reason = "a fake's member reads the bytes a library lends it for the call"
)]
unsafe fn borrowed<'a>(bytes: *const u8, len: usize) -> &'a [u8] {
    if len == 0 {
        return &[];
    }
    // SAFETY: the caller lends `len` readable bytes for the call.
    unsafe { std::slice::from_raw_parts(bytes, len) }
}

/// The tag a take-over refusal crosses as, as the core's runtime gives it.
/// It matches every variant on purpose: each refusal crosses as its own.
const fn refusal_tag(refused: Refused) -> u32 {
    match refused {
        Refused::NoService => TAKE_OVER_NO_SERVICE,
        Refused::NoSuchChild => TAKE_OVER_NO_SUCH_CHILD,
        Refused::ReadPending => TAKE_OVER_READ_PENDING,
        Refused::Taken => TAKE_OVER_TAKEN,
    }
}

/// A child taken over, as the fake holds it behind a [`PackageChild`].
type Handle = Box<dyn ChildStreams>;

/// The fake's `register_service`: the next id of its own counter, recorded
/// with the name.
///
/// # Safety
///
/// `runtime` is a fake's runtime, and `name` points to `len` readable
/// bytes, unless `len` is zero.
#[expect(
    unsafe_code,
    reason = "a member of the fake a library calls: it finds the fake's state through the runtime and reads the name lent for the call"
)]
unsafe extern "C" fn register_service(
    runtime: *const PackageRuntime,
    name: *const u8,
    len: usize,
) -> u64 {
    // SAFETY: the runtime is a fake's, and the name lent for the call.
    let (state, name) = unsafe { (state(runtime), borrowed(name, len)) };
    let id = state.next.fetch_add(1, Ordering::SeqCst);
    locked(&state.services).push((String::from_utf8_lossy(name).into_owned(), id));
    id
}

/// The fake's `complete`: queued, unless the id is a core service's.
///
/// # Safety
///
/// `runtime` is a fake's runtime.
#[expect(
    unsafe_code,
    reason = "a member of the fake a library calls: it finds the fake's state through the runtime"
)]
unsafe extern "C" fn complete(runtime: *const PackageRuntime, service: u64, request: u64) -> bool {
    if service < FIRST_PACKAGE_ID {
        return false;
    }
    // SAFETY: the runtime is a fake's.
    let state = unsafe { state(runtime) };
    locked(&state.completions).push_back((service, request));
    state.completed.notify_all();
    true
}

/// The fake's `post_event`: queued, unless the id is a core service's.
///
/// # Safety
///
/// `runtime` is a fake's runtime, and `text` points to `len` readable
/// bytes, unless `len` is zero.
#[expect(
    unsafe_code,
    reason = "a member of the fake a library calls: it finds the fake's state through the runtime and reads the text lent for the call"
)]
unsafe extern "C" fn post_event(
    runtime: *const PackageRuntime,
    service: u64,
    code: u64,
    text: *const u8,
    len: usize,
) -> bool {
    if service < FIRST_PACKAGE_ID {
        return false;
    }
    // SAFETY: the runtime is a fake's, and the text lent for the call.
    let (state, text) = unsafe { (state(runtime), borrowed(text, len)) };
    let text = String::from_utf8_lossy(text).into_owned();
    locked(&state.events).push_back((service, code, text));
    state.posted.notify_all();
    true
}

/// The fake's `take_over`, from its source: the handle written and 0, or
/// the refusal's tag and nothing written.
///
/// # Safety
///
/// `runtime` is a fake's runtime, and `handle` points to a writable
/// pointer.
#[expect(
    unsafe_code,
    reason = "a member of the fake a library calls: it finds the fake's state through the runtime and writes the handle where the library says"
)]
unsafe extern "C" fn take_over(
    runtime: *const PackageRuntime,
    child: u64,
    handle: *mut *mut PackageChild,
) -> u32 {
    // SAFETY: the runtime is a fake's.
    let state = unsafe { state(runtime) };
    match state.source.take_over(child) {
        Ok(streams) => {
            let taken: *mut Handle = Box::into_raw(Box::new(streams));
            // SAFETY: the library hands a writable place.
            unsafe { handle.write(taken.cast()) };
            0
        }
        Err(refused) => refusal_tag(refused),
    }
}

/// The child behind `handle`.
///
/// # Safety
///
/// `handle` is a live handle of a fake's, not yet released.
#[expect(
    unsafe_code,
    reason = "a member of the fake reads the child behind a handle its take-over gave up"
)]
unsafe fn child<'a>(handle: *mut PackageChild) -> &'a Handle {
    // SAFETY: the handle is the box a take-over gave up, live until its
    // release.
    unsafe { &*handle.cast::<Handle>() }
}

/// The fake's `child_pull`: the child pulled, blocking, encoded as the
/// core encodes it, its words and bytes lent through the fake's ledger.
///
/// # Safety
///
/// `runtime` is a fake's runtime, `handle` a live handle of its, and `out`
/// points to a writable [`RawPull`].
#[expect(
    unsafe_code,
    reason = "a member of the fake a library calls: it finds the fake's state through the runtime, reads the handle and fills the library's record"
)]
unsafe extern "C" fn child_pull(
    runtime: *const PackageRuntime,
    handle: *mut PackageChild,
    out: *mut RawPull,
) {
    // SAFETY: the runtime is a fake's and the handle live.
    let (state, child) = unsafe { (state(runtime), child(handle)) };
    let encoded = wire::encode(child.pull());
    let words = state.lend(encoded.words);
    let bytes = state.lend(encoded.bytes);
    let pull = RawPull {
        delivered: encoded.delivered,
        words: words.bytes,
        words_len: words.len,
        bytes: bytes.bytes,
        bytes_len: bytes.len,
    };
    // SAFETY: the library hands a writable record.
    unsafe { out.write(pull) };
}

/// The fake's `child_write`: written, or false with the refusal's words
/// lent through the fake's ledger.
///
/// # Safety
///
/// `runtime` is a fake's runtime, `handle` a live handle of its, `bytes`
/// points to `len` readable bytes unless `len` is zero, and `refused` to a
/// writable [`RawBuffer`].
#[expect(
    unsafe_code,
    reason = "a member of the fake a library calls: it finds the fake's state through the runtime, reads the handle and the bytes lent, and fills the library's record"
)]
unsafe extern "C" fn child_write(
    runtime: *const PackageRuntime,
    handle: *mut PackageChild,
    bytes: *const u8,
    len: usize,
    refused: *mut RawBuffer,
) -> bool {
    // SAFETY: the runtime is a fake's, the handle live and the bytes lent.
    let (state, child, bytes) = unsafe { (state(runtime), child(handle), borrowed(bytes, len)) };
    match child.write(bytes.to_vec()) {
        Ok(()) => true,
        Err(InputClosed(words)) => {
            let words = state.lend(words.into_bytes());
            // SAFETY: the library hands a writable record.
            unsafe { refused.write(words) };
            false
        }
    }
}

/// The fake's `child_release`: drops the child.
///
/// # Safety
///
/// `handle` is a live handle of a fake's, released this once.
#[expect(
    unsafe_code,
    reason = "a member of the fake a library calls: it takes back the handle its take-over gave up"
)]
unsafe extern "C" fn child_release(_: *const PackageRuntime, handle: *mut PackageChild) {
    // SAFETY: the handle is the box a take-over gave up, released once.
    drop(unsafe { Box::from_raw(handle.cast::<Handle>()) });
}

/// The fake's `buffer_lend`: a copy lent through its ledger.
///
/// # Safety
///
/// `runtime` is a fake's runtime, `bytes` points to `len` readable bytes
/// unless `len` is zero, and `out` to a writable [`RawBuffer`].
#[expect(
    unsafe_code,
    reason = "a member of the fake a library calls: it finds the fake's state through the runtime, reads the bytes lent and fills the library's record"
)]
unsafe extern "C" fn buffer_lend(
    runtime: *const PackageRuntime,
    bytes: *const u8,
    len: usize,
    out: *mut RawBuffer,
) {
    // SAFETY: the runtime is a fake's and the bytes lent for the call.
    let (state, bytes) = unsafe { (state(runtime), borrowed(bytes, len)) };
    let lent = state.lend(bytes.to_vec());
    // SAFETY: the library hands a writable record.
    unsafe { out.write(lent) };
}

/// The fake's `buffer_free`: true once for a buffer it lent, false
/// otherwise, freeing nothing.
///
/// # Safety
///
/// `runtime` is a fake's runtime.
#[expect(
    unsafe_code,
    reason = "a member of the fake a library calls: it finds the fake's state through the runtime"
)]
unsafe extern "C" fn buffer_free(
    runtime: *const PackageRuntime,
    bytes: *mut u8,
    len: usize,
) -> bool {
    // SAFETY: the runtime is a fake's.
    unsafe { state(runtime) }.reclaim(bytes, len)
}

/// The later runtime's member past the current ones: never called by a
/// library built for the current runtime.
extern "C" fn later() {}

#[cfg(test)]
mod tests;
