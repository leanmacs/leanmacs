//! echo's library, built for today's package runtime, on a runtime from a
//! newer core: one embedded in a larger struct, with a member past
//! today's, whose `size` says so. The init answers 0 and writes its table,
//! registers its service once, and a request started through the table
//! completes through that runtime's `complete`: a library runs on any
//! runtime at least as large as the one it was built for (the runtime's
//! append-only rule).
//!
//! An integration test of its own, and one test, because the library's
//! service is process-wide: once loaded, it stays loaded.

use std::mem::size_of;
use std::ptr;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc::{Sender, channel};
use std::time::Duration;

use echo_service::ffi::{EchoTable, editor_package_init};
use editor_package_runtime::{
    PackageChild, PackageRuntime, RawBuffer, RawPull, TAKE_OVER_NO_SUCH_CHILD,
};
use editor_wait::{HangGuard, recv};

/// hang guard: the completion the wait ends on, posted from echo's worker.
const COMPLETION: HangGuard = HangGuard::on("the request's completion", Duration::from_secs(10));

/// The id the later runtime gives echo's service.
const SERVICE: u64 = 5000;

/// How many services were registered.
static REGISTERED: AtomicU32 = AtomicU32::new(0);

/// Where each completion posted through the runtime goes.
static COMPLETED: Mutex<Option<Sender<(u64, u64)>>> = Mutex::new(None);

extern "C" fn register_service(_: *const PackageRuntime, _: *const u8, _: usize) -> u64 {
    REGISTERED.fetch_add(1, Ordering::SeqCst);
    SERVICE
}

extern "C" fn complete(_: *const PackageRuntime, service: u64, request: u64) -> bool {
    COMPLETED
        .lock()
        .expect("unpoisoned")
        .as_ref()
        .is_some_and(|completed| completed.send((service, request)).is_ok())
}

extern "C" fn post_event(_: *const PackageRuntime, _: u64, _: u64, _: *const u8, _: usize) -> bool {
    false
}

extern "C" fn take_over(_: *const PackageRuntime, _: u64, _: *mut *mut PackageChild) -> u32 {
    TAKE_OVER_NO_SUCH_CHILD
}

extern "C" fn child_pull(_: *const PackageRuntime, _: *mut PackageChild, _: *mut RawPull) {}

extern "C" fn child_write(
    _: *const PackageRuntime,
    _: *mut PackageChild,
    _: *const u8,
    _: usize,
    _: *mut RawBuffer,
) -> bool {
    false
}

extern "C" fn child_release(_: *const PackageRuntime, _: *mut PackageChild) {}

extern "C" fn buffer_lend(_: *const PackageRuntime, _: *const u8, _: usize, _: *mut RawBuffer) {}

extern "C" fn buffer_free(_: *const PackageRuntime, _: *mut u8, _: usize) -> bool {
    false
}

/// A runtime from a newer core: today's members, then one more.
#[repr(C)]
struct Later {
    /// Today's runtime.
    runtime: PackageRuntime,
    /// A member appended after today's.
    later: extern "C" fn(),
}

/// The member past today's: echo, built for today's runtime, never calls
/// it.
extern "C" fn later() {}

/// The later runtime, its `size` the larger struct's.
static LATER: Later = Later {
    runtime: PackageRuntime {
        size: size_of::<Later>(),
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
    },
    later,
};

#[test]
fn echo_built_for_today_s_runtime_runs_on_a_larger_one() {
    assert!(LATER.runtime.size > size_of::<PackageRuntime>());
    let (completed, completions) = channel();
    *COMPLETED.lock().expect("unpoisoned") = Some(completed);

    let mut table: *const EchoTable = ptr::null();
    // SAFETY: the runtime is a static as large as it says, and the table's
    // place is writable.
    let status = unsafe { editor_package_init(&raw const LATER.runtime, &raw mut table) };
    // SAFETY: the table, a static of the library, lives for the process.
    let table = unsafe { table.as_ref() }.expect("a table");
    assert_eq!(status, 0);
    assert_eq!(REGISTERED.load(Ordering::SeqCst), 1, "registered once");

    let text = "héllo";
    // SAFETY: the pointer and length are the string's, for the call.
    assert!(unsafe { (table.start)(41, text.as_ptr(), text.len()) });
    assert_eq!(recv(&completions, COMPLETION), Ok((SERVICE, 41)));
}
