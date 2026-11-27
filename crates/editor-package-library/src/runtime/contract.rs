//! The runtime's contract: the properties every package runtime keeps, run
//! through its C members, as a library calls them, on the pure model
//! ([`super::model::ModelRig`], in the model's tests), on the process's
//! real runtime ([`super::RUNTIME`], in `tests/contract.rs`), and on the
//! package wrapper's fake (`editor_package::fake::FakeRuntime`, in
//! `editor-package-check`'s `tests/contract.rs`, as the wrapper may not
//! depend on this crate). So the check holds the ABI itself, not a Rust
//! trait standing in for it, and neither pure runtime can drift from the
//! one the editor hands a library.
//!
//! [`check`] takes a [`Rig`]: the runtime, and what the contract reads that
//! the runtime has no member for (the next completion and the next event
//! queued, how many lent buffers are outstanding, and the ground the stream
//! contract opens children on). It answers the names of the properties that
//! fail: one of [`PROPERTIES`], and for [`CHILD_FRAMED`] each stream
//! property that fails as well (`editor_service::stream::contract`'s).
//!
//! Every call is the runtime's own member, handed the runtime first. A
//! child is taken over, pulled, written and released through the members
//! and every pull decoded ([`super::wire::decode`]), so each rule of the
//! stream contract (the framing of lines, bytes and `Content-Length`
//! messages, the bound, the refusals) must survive the crossing; the
//! ground's source is held to that same stream contract on its own, the
//! real process service among them (`editor-process`).
//!
//! The threads the check starts (the stream contract's pulls and writes,
//! and [`SERVICE_IDS_UNIQUE`]'s registrations) are joined before a property
//! is decided, and a wait is bounded only by the ground's hang guard. A
//! member that panics aborts the process, since a panic cannot unwind out
//! of a C function: a broken runtime fails the check by aborting it.
//!
//! # Where an addition goes
//!
//! A new member's rule is a named `pub const`, an entry of [`PROPERTIES`]
//! and a step of [`check`], driving the member through `Calls`; what it
//! reads that no member gives is a readout of [`Rig`], which the model's rig
//! and `tests/contract.rs`'s rig over the process's statics each answer.

use std::cell::Cell;
use std::ffi::c_void;
use std::mem::{offset_of, size_of};
use std::ptr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;

use editor_package_runtime::{
    PackageChild, PackageRuntime, PackageRuntimePrivate, RawBuffer, RawPull,
};
use editor_service::FIRST_PACKAGE_ID;
use editor_service::buffer;
use editor_service::frame::Frames;
use editor_service::stream::contract::{self as stream_contract, Ground, Scenario};
use editor_service::stream::{
    ChildStreams, Delivery, Ended, InputClosed, Pulled, Refused, StreamSource,
};
use editor_service::wait::HangGuard;

use super::refused_of_tag;
use super::wire::{Encoded, decode};

/// What the contract needs of a runtime beyond its members: the runtime,
/// what it queued, what it lent, and a ground its children come from.
pub trait Rig {
    /// The runtime checked. It lives for the process: the stream
    /// contract's threads call it.
    fn runtime(&self) -> &'static PackageRuntime;

    /// The next completion queued, as its service and its request; none
    /// when the completion queue is idle.
    fn next_completion(&self) -> Option<(u64, u64)>;

    /// The next event queued on the editor queue, as its service, its code
    /// and its text; none when the queue is idle.
    fn next_event(&self) -> Option<(u64, u64, String)>;

    /// How many buffers the runtime lent that are not yet handed back.
    fn outstanding(&self) -> usize;

    /// The ground whose source the runtime's `take_over` takes children
    /// from: [`check`] opens each child of the stream contract on it.
    fn ground(&self) -> &impl Ground;
}

/// A completion posted through the runtime, from a service registered
/// through it, is read once on the completion queue, never duplicated.
pub const COMPLETION_READ_ONCE: &str =
    "a completion posted through the runtime is read once on the completion queue";
/// A completion or an event posted as a core service's id is refused, and
/// neither queue holds anything.
pub const CORE_ID_REFUSED: &str =
    "a completion or an event posted as a core service's id is refused, and nothing is queued";
/// Services registered from several threads at once, some under one name,
/// have distinct ids, each at or above the first package id.
pub const SERVICE_IDS_UNIQUE: &str =
    "service ids registered from several threads are distinct and at or above the first package id";
/// An event posted through the runtime is read once on the editor queue,
/// its service, code and text whole.
pub const EVENT_POSTED: &str =
    "an event posted through the runtime is read once on the editor queue, whole";
/// A child taken over through the runtime keeps the whole stream contract
/// through the members, framed as the process service frames it, and every
/// buffer its pulls and writes lent is handed back once.
pub const CHILD_FRAMED: &str = "a child taken over through the runtime keeps the stream contract, every lent buffer handed back once";
/// A buffer the runtime lends, through `buffer_lend` or a pull, is
/// reclaimed exactly once: its first hand-back answers true, a second
/// false; a pointer never lent is refused; and nothing is left outstanding.
pub const BUFFER_RECLAIMED_ONCE: &str =
    "a lent buffer is reclaimed exactly once, and a pointer never lent is refused";
/// A library built when the runtime ended at `complete` runs on this
/// runtime: the older prefix is laid out as this one's, the runtime is
/// larger, and through the older view the library registers and completes.
pub const OLDER_LIBRARY_RUNS: &str =
    "a library built for an older, smaller runtime runs on this one";

/// Every property of the runtime's own, in the order [`check`] runs them.
pub const PROPERTIES: [&str; 7] = [
    COMPLETION_READ_ONCE,
    CORE_ID_REFUSED,
    SERVICE_IDS_UNIQUE,
    EVENT_POSTED,
    CHILD_FRAMED,
    BUFFER_RECLAIMED_ONCE,
    OLDER_LIBRARY_RUNS,
];

/// Holds the runtime of `rig` to the contract, and answers the names of
/// the properties that fail: none when it keeps them all.
pub fn check(rig: &impl Rig) -> Vec<&'static str> {
    let calls = Calls(rig.runtime());
    let mut failed = Vec::new();
    let mut fails = |property, holds: bool| {
        if !holds {
            failed.push(property);
        }
    };
    fails(COMPLETION_READ_ONCE, completion_read_once(rig, calls));
    fails(CORE_ID_REFUSED, core_id_refused(rig, calls));
    fails(SERVICE_IDS_UNIQUE, service_ids_unique(calls));
    fails(EVENT_POSTED, event_posted(rig, calls));
    let stream_failures = child_framed(rig);
    fails(CHILD_FRAMED, stream_failures.is_empty());
    failed.extend(
        stream_failures
            .into_iter()
            .filter(|name| *name != CHILD_FRAMED),
    );
    let mut fails = |property, holds: bool| {
        if !holds {
            failed.push(property);
        }
    };
    fails(BUFFER_RECLAIMED_ONCE, buffer_reclaimed_once(rig, calls));
    fails(OLDER_LIBRARY_RUNS, older_library_runs(rig, calls));
    failed
}

/// [`COMPLETION_READ_ONCE`].
fn completion_read_once(rig: &impl Rig, calls: Calls<'_>) -> bool {
    let id = calls.register("a completing library's");
    calls.complete(id, 41)
        && rig.next_completion() == Some((id, 41))
        && rig.next_completion().is_none()
}

/// [`CORE_ID_REFUSED`].
fn core_id_refused(rig: &impl Rig, calls: Calls<'_>) -> bool {
    !calls.complete(3, 1)
        && !calls.post(FIRST_PACKAGE_ID - 1, 1, "spoofed")
        && rig.next_completion().is_none()
        && rig.next_event().is_none()
}

/// How many threads [`SERVICE_IDS_UNIQUE`] registers from, and how many
/// services each registers.
const REGISTERING: (usize, usize) = (4, 16);

/// [`SERVICE_IDS_UNIQUE`]: every thread is joined before it is decided, so
/// the result does not depend on how the registrations interleave.
fn service_ids_unique(calls: Calls<'static>) -> bool {
    let (threads, each) = REGISTERING;
    let mut ids: Vec<u64> = thread::scope(|scope| {
        let registering: Vec<_> = (0..threads)
            .map(|thread| {
                scope.spawn(move || {
                    (0..each)
                        .map(|n| {
                            // Half under one name shared by every thread.
                            let name = if n % 2 == 0 {
                                "shared".to_owned()
                            } else {
                                format!("thread {thread}'s")
                            };
                            calls.register(&name)
                        })
                        .collect::<Vec<_>>()
                })
            })
            .collect();
        registering
            .into_iter()
            .flat_map(|registered| registered.join().unwrap_or_default())
            .collect()
    });
    let all_package_ids = ids.iter().all(|&id| id >= FIRST_PACKAGE_ID);
    ids.sort_unstable();
    ids.dedup();
    all_package_ids && ids.len() == threads * each
}

/// [`EVENT_POSTED`].
fn event_posted(rig: &impl Rig, calls: Calls<'_>) -> bool {
    let id = calls.register("a posting library's");
    calls.post(id, 7, "héllo")
        && rig.next_event() == Some((id, 7, "héllo".to_owned()))
        && rig.next_event().is_none()
}

/// [`CHILD_FRAMED`]: the stream properties that fail through the runtime,
/// led by [`CHILD_FRAMED`] itself when a lent buffer's hand-back was
/// refused or one was left outstanding.
fn child_framed(rig: &impl Rig) -> Vec<&'static str> {
    let before = rig.outstanding();
    let through = Through {
        rig,
        source: RuntimeSource {
            calls: Calls(rig.runtime()),
            refused_free: Arc::new(AtomicBool::new(false)),
        },
    };
    let mut failed = stream_contract::check(&through);
    let refused_free = through.source.refused_free.load(Ordering::SeqCst);
    if refused_free || rig.outstanding() != before {
        failed.insert(0, CHILD_FRAMED);
    }
    failed
}

/// [`BUFFER_RECLAIMED_ONCE`].
fn buffer_reclaimed_once(rig: &impl Rig, calls: Calls<'_>) -> bool {
    let before = rig.outstanding();
    let lent = calls.lend(b"abc");
    let lent_whole = calls.read(lent.bytes, lent.len) == b"abc" && rig.outstanding() == before + 1;
    let once = calls.free(lent.bytes, lent.len) && !calls.free(lent.bytes, lent.len);
    let mut own = *b"own";
    let never_lent = !calls.free(own.as_mut_ptr(), own.len()) && own == *b"own";

    let Some(child) = rig.ground().open(Scenario::OneLine) else {
        return false;
    };
    let Ok(handle) = calls.take_over(child) else {
        return false;
    };
    let pulled = calls.pull(handle);
    let pull_lent = rig.outstanding() == before + 2;
    let pull_once = [
        (pulled.words, pulled.words_len),
        (pulled.bytes, pulled.bytes_len),
    ]
    .into_iter()
    .all(|(bytes, len)| calls.free(bytes, len) && !calls.free(bytes, len));
    calls.release(handle);

    lent_whole
        && once
        && never_lent
        && pulled.delivered
        && pull_lent
        && pull_once
        && rig.outstanding() == before
}

/// The request the older library completes at its init.
const OLDER_REQUEST: u64 = 5;

/// The runtime as a library built when it ended at `complete` sees it: the
/// definitions of that time, frozen.
#[repr(C)]
struct OlderRuntime {
    /// Its size.
    size: usize,
    /// The core's state.
    private_members: *mut PackageRuntimePrivate,
    /// `register_service`, as that time declared it.
    register_service: unsafe extern "C" fn(*const OlderRuntime, *const u8, usize) -> u64,
    /// `complete`, as that time declared it.
    complete: unsafe extern "C" fn(*const OlderRuntime, u64, u64) -> bool,
}

thread_local! {
    /// The id the older library registered at its init, on this thread.
    static OLDER_SERVICE: Cell<Option<u64>> = const { Cell::new(None) };
}

/// The older library's init: it checks the runtime is as large as its
/// view, registers its service and completes [`OLDER_REQUEST`] through that
/// view, and writes a table.
///
/// # Safety
///
/// `runtime` is null or points to a runtime at least its `size` long, and
/// `table` to a writable pointer.
#[expect(
    unsafe_code,
    reason = "an init written as a library's is: it reads the runtime it is handed through its own, older view"
)]
unsafe extern "C" fn older_init(runtime: *const OlderRuntime, table: *mut *const c_void) -> u32 {
    if runtime.is_null() {
        return 1;
    }
    // SAFETY: the size is the runtime's first member, read alone.
    let size = unsafe { ptr::addr_of!((*runtime).size).read() };
    if size < size_of::<OlderRuntime>() {
        return 1;
    }
    // SAFETY: the runtime holds every member of the older view.
    let older = unsafe { &*runtime };
    let name = "older";
    // SAFETY: the name is lent for the call.
    let service = unsafe { (older.register_service)(runtime, name.as_ptr(), name.len()) };
    OLDER_SERVICE.set(Some(service));
    // SAFETY: the runtime is the one the init was handed.
    if !unsafe { (older.complete)(runtime, service, OLDER_REQUEST) } {
        return 7;
    }
    // SAFETY: the caller hands a writable place.
    unsafe { table.write(runtime.cast()) };
    0
}

/// [`OLDER_LIBRARY_RUNS`].
#[expect(
    unsafe_code,
    reason = "calls an init as the core's load does, handing it the runtime under the library's older view"
)]
fn older_library_runs(rig: &impl Rig, calls: Calls<'_>) -> bool {
    let laid_out = offset_of!(OlderRuntime, size) == offset_of!(PackageRuntime, size)
        && offset_of!(OlderRuntime, private_members) == offset_of!(PackageRuntime, private_members)
        && offset_of!(OlderRuntime, register_service)
            == offset_of!(PackageRuntime, register_service)
        && offset_of!(OlderRuntime, complete) == offset_of!(PackageRuntime, complete);
    let larger = calls.0.size > size_of::<OlderRuntime>();
    OLDER_SERVICE.set(None);
    let mut table: *const c_void = ptr::null();
    // SAFETY: the runtime is the rig's, and the init reads no more of it
    // than its size says; the table's place is writable.
    let status = unsafe { older_init(ptr::from_ref(calls.0).cast(), &raw mut table) };
    let Some(service) = OLDER_SERVICE.take() else {
        return false;
    };
    laid_out
        && larger
        && status == 0
        && !table.is_null()
        && service >= FIRST_PACKAGE_ID
        && rig.next_completion() == Some((service, OLDER_REQUEST))
        && rig.next_completion().is_none()
}

/// A runtime's members, called as a library calls them: each handed the
/// runtime first, each buffer it lends read and handed back by the caller.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Calls<'r>(pub(crate) &'r PackageRuntime);

#[expect(
    unsafe_code,
    reason = "calls a runtime's C members as a library does: bytes lent for the call, records filled, buffers read and handed back"
)]
impl Calls<'_> {
    /// The runtime, as its members take it.
    fn runtime(self) -> *const PackageRuntime {
        ptr::from_ref(self.0)
    }

    /// `register_service`.
    pub(crate) fn register(self, name: &str) -> u64 {
        // SAFETY: the name is lent for the call.
        unsafe { (self.0.register_service)(self.runtime(), name.as_ptr(), name.len()) }
    }

    /// `complete`.
    pub(crate) fn complete(self, service: u64, request: u64) -> bool {
        // SAFETY: the runtime is the one the member was read from.
        unsafe { (self.0.complete)(self.runtime(), service, request) }
    }

    /// `post_event`.
    pub(crate) fn post(self, service: u64, code: u64, text: &str) -> bool {
        // SAFETY: the text is lent for the call.
        unsafe { (self.0.post_event)(self.runtime(), service, code, text.as_ptr(), text.len()) }
    }

    /// `take_over`: the handle, or the refusal's tag.
    pub(crate) fn take_over(self, child: u64) -> Result<*mut PackageChild, u32> {
        let mut handle = ptr::null_mut();
        // SAFETY: the handle's place is writable.
        match unsafe { (self.0.take_over)(self.runtime(), child, &raw mut handle) } {
            0 => Ok(handle),
            tag => Err(tag),
        }
    }

    /// `child_pull`: the record, its buffers still lent.
    pub(crate) fn pull(self, handle: *mut PackageChild) -> RawPull {
        let mut out = RawPull {
            delivered: false,
            words: ptr::null_mut(),
            words_len: 0,
            bytes: ptr::null_mut(),
            bytes_len: 0,
        };
        // SAFETY: the caller hands a live handle; the record is writable.
        unsafe { (self.0.child_pull)(self.runtime(), handle, &raw mut out) };
        out
    }

    /// `child_write`: true, or the refusal's words, still lent.
    pub(crate) fn write(self, handle: *mut PackageChild, bytes: &[u8]) -> Result<(), RawBuffer> {
        let mut refused = RawBuffer {
            bytes: ptr::null_mut(),
            len: 0,
        };
        // SAFETY: the caller hands a live handle; the bytes are lent for
        // the call and the record is writable.
        let written = unsafe {
            (self.0.child_write)(
                self.runtime(),
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
        // SAFETY: the caller hands a live handle, released this once.
        unsafe { (self.0.child_release)(self.runtime(), handle) };
    }

    /// `buffer_lend`: the buffer, lent.
    pub(crate) fn lend(self, bytes: &[u8]) -> RawBuffer {
        let mut out = RawBuffer {
            bytes: ptr::null_mut(),
            len: 0,
        };
        // SAFETY: the bytes are lent for the call; the record is writable.
        unsafe { (self.0.buffer_lend)(self.runtime(), bytes.as_ptr(), bytes.len(), &raw mut out) };
        out
    }

    /// `buffer_free`.
    pub(crate) fn free(self, bytes: *mut u8, len: usize) -> bool {
        // SAFETY: the member takes any pointer: one it did not lend, or
        // lent and handed back already, is refused unread.
        unsafe { (self.0.buffer_free)(self.runtime(), bytes, len) }
    }

    /// The bytes of a buffer the runtime lent, copied.
    pub(crate) fn read(self, bytes: *mut u8, len: usize) -> Vec<u8> {
        // SAFETY: the caller reads a buffer still lent.
        unsafe { buffer::borrow(bytes, len) }.to_vec()
    }
}

/// The ground of a [`Rig`], with its source replaced by the runtime's
/// members: the stream contract's children are opened on the rig's ground
/// and taken over through the runtime.
struct Through<'a, R> {
    /// The rig.
    rig: &'a R,
    /// The source over the runtime's members.
    source: RuntimeSource,
}

impl<R: Rig> Ground for Through<'_, R> {
    fn source(&self) -> &dyn StreamSource {
        &self.source
    }

    fn open(&self, scenario: Scenario) -> Option<u64> {
        self.rig.ground().open(scenario)
    }

    fn wait_held(&self, child: u64) -> bool {
        self.rig.ground().wait_held(child)
    }

    fn pend_read(&self, child: u64) -> bool {
        self.rig.ground().pend_read(child)
    }

    fn withdraw_read(&self, child: u64) {
        self.rig.ground().withdraw_read(child);
    }

    fn deadline(&self) -> HangGuard {
        self.rig.ground().deadline()
    }
}

/// A stream source whose take-over is the runtime's `take_over`.
struct RuntimeSource {
    /// The runtime's members.
    calls: Calls<'static>,
    /// Set once any lent buffer's hand-back was refused.
    refused_free: Arc<AtomicBool>,
}

impl StreamSource for RuntimeSource {
    fn take_over(&self, child: u64) -> Result<Box<dyn ChildStreams>, Refused> {
        match self.calls.take_over(child) {
            Ok(handle) => Ok(Box::new(RuntimeChild {
                calls: self.calls,
                handle,
                refused_free: Arc::clone(&self.refused_free),
            })),
            // A tag no refusal crosses as reads as no service, which no
            // stream property expects of a child a ground opened.
            Err(tag) => Err(refused_of_tag(tag).unwrap_or(Refused::NoService)),
        }
    }
}

/// What a pull answers when its words cannot be read.
const UNREADABLE: &str = "the runtime's pull could not be read";

/// A child taken over through the runtime: each pull and write through its
/// members, every lent buffer copied and handed back, and the handle
/// released on drop.
struct RuntimeChild {
    /// The runtime's members.
    calls: Calls<'static>,
    /// The runtime's handle of the child.
    handle: *mut PackageChild,
    /// Set once any lent buffer's hand-back was refused.
    refused_free: Arc<AtomicBool>,
}

// SAFETY: the handle is the runtime's, which may be pulled from one thread
// and written from another (the runtime's members' rules); this type only
// hands it back to the runtime.
#[expect(
    unsafe_code,
    reason = "a child handle crosses threads as the runtime's rules allow: pulled on one, written on another"
)]
unsafe impl Send for RuntimeChild {}

// SAFETY: as for `Send`.
#[expect(
    unsafe_code,
    reason = "a child handle crosses threads as the runtime's rules allow: pulled on one, written on another"
)]
unsafe impl Sync for RuntimeChild {}

impl RuntimeChild {
    /// A lent buffer, copied and handed back, a refused hand-back noted.
    fn taken(&self, bytes: *mut u8, len: usize) -> Vec<u8> {
        let copy = self.calls.read(bytes, len);
        if !self.calls.free(bytes, len) {
            self.refused_free.store(true, Ordering::SeqCst);
        }
        copy
    }
}

impl ChildStreams for RuntimeChild {
    fn pull(&self) -> Pulled {
        let raw = self.calls.pull(self.handle);
        let encoded = Encoded {
            delivered: raw.delivered,
            words: self.taken(raw.words, raw.words_len),
            bytes: self.taken(raw.bytes, raw.bytes_len),
        };
        decode(&encoded).unwrap_or_else(|| {
            Pulled::Delivered(Delivery {
                out: Frames::Lines(Vec::new()),
                err: Frames::Lines(Vec::new()),
                ended: Some(Ended::Failed(UNREADABLE.to_owned())),
            })
        })
    }

    fn write(&self, bytes: Vec<u8>) -> Result<(), InputClosed> {
        self.calls.write(self.handle, &bytes).map_err(|refused| {
            let words = self.taken(refused.bytes, refused.len);
            InputClosed(String::from_utf8_lossy(&words).into_owned())
        })
    }
}

impl Drop for RuntimeChild {
    fn drop(&mut self) {
        self.calls.release(self.handle);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_properties_are_seven_and_each_is_named_once() {
        let mut names = PROPERTIES.to_vec();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), 7);
    }
}
