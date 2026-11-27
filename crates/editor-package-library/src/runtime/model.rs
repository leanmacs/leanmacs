//! The runtime's pure model: a [`PackageRuntime`] whose members keep the
//! same rules as the real one over state of its own, published as the crate
//! that owns a port publishes its model.
//!
//! A [`ModelRuntime`] holds its own id counter, from the first package id;
//! its own completion queue and editor queue; its own ledger of lent
//! buffers; and a [`FakeSource`], the stream port's model, from which its
//! `take_over` takes children. Its `private_members` points to that state,
//! so any number of models live in one process, each independent. It is
//! deterministic, holds no process-wide state and starts no thread.
//!
//! Its members forward to the same safe functions the real runtime's do
//! (`super`), over its own state instead of the process's statics. Both
//! keep [`super::contract::check`]: the model in this module's tests, as
//! the current runtime ([`ModelRuntime::new`]) and as a later, larger one
//! ([`ModelRuntime::later`]), and the real one in `tests/contract.rs`.

use std::collections::VecDeque;
use std::mem::size_of;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use editor_package_runtime::{
    PackageChild, PackageRuntime, PackageRuntimePrivate, RawBuffer, RawPull,
};
use editor_service::FIRST_PACKAGE_ID;
use editor_service::stream::fake::FakeSource;

use super::contract::Rig;
use super::ledger::Ledger;
use super::{
    complete_with, lend_raw, post_event_with, pull_into, release, take_over_into, text_of,
    write_into,
};

/// What a model's members act on: `private_members` points here.
#[derive(Debug)]
struct State {
    /// The next service's id.
    next: AtomicU64,
    /// The completions posted, oldest first: their service and request.
    completions: Mutex<VecDeque<(u64, u64)>>,
    /// The events posted, oldest first: their service, code and text.
    events: Mutex<VecDeque<(u64, u64, String)>>,
    /// The buffers lent.
    ledger: Ledger,
    /// The source children are taken over from.
    source: FakeSource,
}

/// A runtime from a newer core than this one: the current members, then
/// one more.
#[repr(C)]
struct Later {
    /// The current runtime.
    runtime: PackageRuntime,
    /// A member appended after the current ones.
    later: unsafe extern "C" fn(),
}

/// The runtime's pure model: a runtime and the state its members act on.
pub struct ModelRuntime {
    /// What the members act on, shared so that its address stays put.
    state: Arc<State>,
    /// The runtime, inside room for one later member.
    runtime: Box<Later>,
}

impl std::fmt::Debug for ModelRuntime {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ModelRuntime")
            .field("size", &self.runtime.runtime.size)
            .field("state", &self.state)
            .finish_non_exhaustive()
    }
}

impl Default for ModelRuntime {
    fn default() -> Self {
        Self::new()
    }
}

impl ModelRuntime {
    /// A model of the current runtime: its `size` is
    /// `size_of::<PackageRuntime>()`.
    pub fn new() -> Self {
        Self::sized(size_of::<PackageRuntime>())
    }

    /// A model of a runtime from a newer core: the current members and one
    /// more after them, its `size` larger than the current runtime's.
    pub fn later() -> Self {
        Self::sized(size_of::<Later>())
    }

    /// A model whose runtime says it is `size` bytes.
    fn sized(size: usize) -> Self {
        let state = Arc::new(State {
            next: AtomicU64::new(FIRST_PACKAGE_ID),
            completions: Mutex::new(VecDeque::new()),
            events: Mutex::new(VecDeque::new()),
            ledger: Ledger::new(),
            source: FakeSource::new(),
        });
        let private_members = Arc::as_ptr(&state)
            .cast_mut()
            .cast::<PackageRuntimePrivate>();
        let runtime = Box::new(Later {
            runtime: PackageRuntime {
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
            },
            later,
        });
        Self { state, runtime }
    }

    /// The runtime, as a library is handed it.
    pub fn runtime(&self) -> &PackageRuntime {
        &self.runtime.runtime
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

    /// How many buffers the model lent that are not yet handed back.
    pub fn outstanding(&self) -> usize {
        self.state.ledger.outstanding()
    }

    /// The source the model's `take_over` takes children from, on which a
    /// test opens and steps them.
    pub fn source(&self) -> &FakeSource {
        &self.state.source
    }
}

/// Locks `mutex`. The lock is never held while other code runs.
fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The state of the model whose runtime is `runtime`.
///
/// # Safety
///
/// `runtime` is a model's runtime, and the model outlives `'a`.
#[expect(
    unsafe_code,
    reason = "a model's member finds its state through the runtime it is handed"
)]
unsafe fn state<'a>(runtime: *const PackageRuntime) -> &'a State {
    // SAFETY: a model's runtime's `private_members` points to its state,
    // which lives as long as the model.
    unsafe { &*(*runtime).private_members.cast::<State>() }
}

/// The model's `register_service`: the next id of its own counter. The
/// name is read, as the real runtime reads it, and not kept.
///
/// # Safety
///
/// `runtime` is a model's runtime, and `name` points to `len` readable
/// bytes, unless `len` is zero.
#[expect(
    unsafe_code,
    reason = "a member of the model a library calls: it finds the model's state through the runtime and reads the name lent for the call"
)]
unsafe extern "C" fn register_service(
    runtime: *const PackageRuntime,
    name: *const u8,
    len: usize,
) -> u64 {
    // SAFETY: the library lends `len` readable bytes for the call.
    let _name = unsafe { text_of(name, len) };
    // SAFETY: the runtime is the model's.
    unsafe { state(runtime) }
        .next
        .fetch_add(1, Ordering::SeqCst)
}

/// The model's `complete` ([`complete_with`] over its completion queue).
///
/// # Safety
///
/// `runtime` is a model's runtime.
#[expect(
    unsafe_code,
    reason = "a member of the model a library calls: it finds the model's state through the runtime"
)]
unsafe extern "C" fn complete(runtime: *const PackageRuntime, service: u64, request: u64) -> bool {
    // SAFETY: the runtime is the model's.
    let state = unsafe { state(runtime) };
    complete_with(service, request, |service, request| {
        locked(&state.completions).push_back((service, request));
        true
    })
}

/// The model's `post_event` ([`post_event_with`] over its editor queue).
///
/// # Safety
///
/// `runtime` is a model's runtime, and `text` points to `len` readable
/// bytes, unless `len` is zero.
#[expect(
    unsafe_code,
    reason = "a member of the model a library calls: it finds the model's state through the runtime and reads the text lent for the call"
)]
unsafe extern "C" fn post_event(
    runtime: *const PackageRuntime,
    service: u64,
    code: u64,
    text: *const u8,
    len: usize,
) -> bool {
    // SAFETY: the runtime is the model's.
    let state = unsafe { state(runtime) };
    // SAFETY: the library lends `len` readable bytes for the call.
    let text = unsafe { text_of(text, len) };
    post_event_with(service, code, text, |service, code, text| {
        locked(&state.events).push_back((service, code, text));
        true
    })
}

/// The model's `take_over`, from its own source.
///
/// # Safety
///
/// `runtime` is a model's runtime, and `handle` points to a writable
/// pointer.
#[expect(
    unsafe_code,
    reason = "a member of the model a library calls: it finds the model's state through the runtime and writes the handle where the library says"
)]
unsafe extern "C" fn take_over(
    runtime: *const PackageRuntime,
    child: u64,
    handle: *mut *mut PackageChild,
) -> u32 {
    // SAFETY: the runtime is the model's, and the handle's place writable.
    unsafe { take_over_into(&state(runtime).source, child, handle) }
}

/// The model's `child_pull`, lent through its own ledger.
///
/// # Safety
///
/// `runtime` is a model's runtime, `handle` a live handle of its, and
/// `out` points to a writable [`RawPull`].
#[expect(
    unsafe_code,
    reason = "a member of the model a library calls: it finds the model's state through the runtime, reads the handle and fills the library's record"
)]
unsafe extern "C" fn child_pull(
    runtime: *const PackageRuntime,
    handle: *mut PackageChild,
    out: *mut RawPull,
) {
    // SAFETY: the runtime is the model's, the handle live and the record
    // writable.
    unsafe { pull_into(&state(runtime).ledger, handle, out) };
}

/// The model's `child_write`, a refusal's words lent through its own
/// ledger.
///
/// # Safety
///
/// `runtime` is a model's runtime, `handle` a live handle of its, `bytes`
/// points to `len` readable bytes unless `len` is zero, and `refused` to a
/// writable [`RawBuffer`].
#[expect(
    unsafe_code,
    reason = "a member of the model a library calls: it finds the model's state through the runtime, reads the handle and the bytes lent, and fills the library's record"
)]
unsafe extern "C" fn child_write(
    runtime: *const PackageRuntime,
    handle: *mut PackageChild,
    bytes: *const u8,
    len: usize,
    refused: *mut RawBuffer,
) -> bool {
    // SAFETY: the runtime is the model's, the handle live, the bytes lent
    // and the record writable.
    unsafe { write_into(&state(runtime).ledger, handle, bytes, len, refused) }
}

/// The model's `child_release`.
///
/// # Safety
///
/// `handle` is a live handle of the model's, released this once.
#[expect(
    unsafe_code,
    reason = "a member of the model a library calls: it takes back the handle its take-over gave up"
)]
unsafe extern "C" fn child_release(_: *const PackageRuntime, handle: *mut PackageChild) {
    // SAFETY: the library releases a live handle, once.
    unsafe { release(handle) };
}

/// The model's `buffer_lend`, through its own ledger.
///
/// # Safety
///
/// `runtime` is a model's runtime, `bytes` points to `len` readable bytes
/// unless `len` is zero, and `out` to a writable [`RawBuffer`].
#[expect(
    unsafe_code,
    reason = "a member of the model a library calls: it finds the model's state through the runtime, reads the bytes lent and fills the library's record"
)]
unsafe extern "C" fn buffer_lend(
    runtime: *const PackageRuntime,
    bytes: *const u8,
    len: usize,
    out: *mut RawBuffer,
) {
    // SAFETY: the runtime is the model's, the bytes lent and the record
    // writable.
    unsafe { lend_raw(&state(runtime).ledger, bytes, len, out) };
}

/// The model's `buffer_free`: [`Ledger::reclaim`] on its own ledger.
///
/// # Safety
///
/// `runtime` is a model's runtime.
#[expect(
    unsafe_code,
    reason = "a member of the model a library calls: it finds the model's state through the runtime"
)]
unsafe extern "C" fn buffer_free(
    runtime: *const PackageRuntime,
    bytes: *mut u8,
    len: usize,
) -> bool {
    // SAFETY: the runtime is the model's.
    unsafe { state(runtime) }.ledger.reclaim(bytes, len)
}

/// The later runtime's member past the current ones: never called by a
/// library built for the current runtime.
extern "C" fn later() {}

/// The model as a contract's rig ([`Rig`]): a model made for the run and
/// kept for the life of the process, as the real runtime is, since the
/// stream contract's threads call the runtime. Each rig leaks one model,
/// memory only: a model starts no thread and holds no file.
#[derive(Debug, Clone, Copy)]
pub struct ModelRig(&'static ModelRuntime);

impl Default for ModelRig {
    fn default() -> Self {
        Self::new()
    }
}

impl ModelRig {
    /// A rig over a model of the current runtime ([`ModelRuntime::new`]).
    pub fn new() -> Self {
        Self(Box::leak(Box::new(ModelRuntime::new())))
    }

    /// A rig over a model of a later runtime ([`ModelRuntime::later`]).
    pub fn later() -> Self {
        Self(Box::leak(Box::new(ModelRuntime::later())))
    }

    /// The model.
    pub const fn model(self) -> &'static ModelRuntime {
        self.0
    }
}

impl Rig for ModelRig {
    fn runtime(&self) -> &'static PackageRuntime {
        self.0.runtime()
    }

    fn next_completion(&self) -> Option<(u64, u64)> {
        self.0.next_completion()
    }

    fn next_event(&self) -> Option<(u64, u64, String)> {
        self.0.next_event()
    }

    fn outstanding(&self) -> usize {
        self.0.outstanding()
    }

    fn ground(&self) -> &impl editor_service::stream::contract::Ground {
        self.0.source()
    }
}

#[cfg(test)]
mod tests;
