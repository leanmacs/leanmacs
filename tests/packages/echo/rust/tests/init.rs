//! The library's init and its table over a runtime of test functions, as
//! the core's loader calls them: a runtime smaller than echo requires is
//! refused with 1 and the table left unwritten; a whole one is answered
//! with 0 and the table, the service `echo` registered through it once;
//! and a request started through the table completes through the
//! runtime's `complete` with that service's id and the request's id, and
//! its reply, taken through the table, is its text and the text's CRC-32
//! from the system's zlib, handed back through the table's `free`.
//!
//! An integration test of its own, and one test, because the library's
//! service is process-wide: once loaded, it stays loaded.

use std::ffi::c_void;
use std::mem::{MaybeUninit, size_of};
use std::ptr;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc::{Sender, channel};
use std::time::Duration;

use echo_service::ffi::{EchoTable, RawReply, editor_package_init};
use echo_service::runtime::{REQUIRED, RawBuffer, RawPull, Runtime};
use editor_wait::{HangGuard, recv};

/// hang guard: the completion the wait ends on, posted from echo's worker.
const COMPLETION: HangGuard = HangGuard::on("the request's completion", Duration::from_secs(10));

/// The id the test runtime gives echo's service.
const SERVICE: u64 = 4096;

/// How many services were registered, and under which name last.
static REGISTERED: AtomicU32 = AtomicU32::new(0);
static NAME: Mutex<String> = Mutex::new(String::new());

/// Where each completion posted through the runtime goes.
static COMPLETED: Mutex<Option<Sender<(u64, u64)>>> = Mutex::new(None);

unsafe extern "C" fn register_service(name: *const u8, len: usize) -> u64 {
    // SAFETY: the library lends `len` bytes for the call.
    let name = unsafe { std::slice::from_raw_parts(name, len) };
    *NAME.lock().expect("unpoisoned") = String::from_utf8_lossy(name).into_owned();
    REGISTERED.fetch_add(1, Ordering::SeqCst);
    SERVICE
}

extern "C" fn complete(service: u64, request: u64) -> bool {
    COMPLETED
        .lock()
        .expect("unpoisoned")
        .as_ref()
        .is_some_and(|completed| completed.send((service, request)).is_ok())
}

unsafe extern "C" fn take_over(_: u64, _: *mut *mut c_void) -> u32 {
    2
}

unsafe extern "C" fn child_pull(_: *mut c_void, _: *mut RawPull) {}

unsafe extern "C" fn child_write(
    _: *mut c_void,
    _: *const u8,
    _: usize,
    _: *mut RawBuffer,
) -> bool {
    false
}

unsafe extern "C" fn child_release(_: *mut c_void) {}

unsafe extern "C" fn buffer_free(_: *mut u8, _: usize) {}

/// A runtime of test functions saying it is `size` bytes.
const fn runtime(size: usize) -> Runtime {
    Runtime {
        size,
        register_service,
        complete,
        take_over,
        child_pull,
        child_write,
        child_release,
        buffer_free,
    }
}

/// A runtime one member smaller than echo requires.
static SMALL: Runtime = runtime(REQUIRED - size_of::<usize>());

/// A whole runtime.
static WHOLE: Runtime = runtime(REQUIRED);

/// The init's status for `runtime`, and the table it wrote, if any.
fn init(runtime: &'static Runtime) -> (u32, Option<&'static EchoTable>) {
    let mut table: *const EchoTable = ptr::null();
    // SAFETY: the runtime is a static as large as it says, and the table's
    // place is writable; the table, a static of the library, lives for the
    // process.
    let status = unsafe { editor_package_init(runtime, &raw mut table) };
    (status, unsafe { table.as_ref() })
}

/// Takes the reply to `id` through the table, its text handed back.
fn take(table: &EchoTable, id: u64) -> Option<(String, u32)> {
    let mut raw = MaybeUninit::<RawReply>::uninit();
    // SAFETY: `raw` is writable, read only when filled, and its text
    // handed back once after it is copied.
    unsafe {
        if !(table.take)(id, raw.as_mut_ptr()) {
            return None;
        }
        let raw = raw.assume_init();
        let text = std::slice::from_raw_parts(raw.text, raw.text_len).to_vec();
        (table.free)(raw.text, raw.text_len);
        String::from_utf8(text)
            .ok()
            .map(|text| (text, raw.checksum))
    }
}

#[test]
fn the_init_refuses_a_small_runtime_and_a_whole_one_s_table_completes_through_the_runtime() {
    let (completed, completions) = channel();
    *COMPLETED.lock().expect("unpoisoned") = Some(completed);

    let (small, unwritten) = init(&SMALL);
    assert_eq!(
        (small, unwritten.is_none()),
        (1, true),
        "too small: no table"
    );
    assert_eq!(REGISTERED.load(Ordering::SeqCst), 0);

    let (status, table) = init(&WHOLE);
    let table = table.expect("a table");
    assert_eq!(status, 0);
    assert_eq!(table.size, size_of::<EchoTable>());
    let (again, same) = init(&WHOLE);
    assert_eq!(
        (again, same.map(ptr::from_ref)),
        (0, Some(ptr::from_ref(table)))
    );
    assert_eq!(REGISTERED.load(Ordering::SeqCst), 1, "registered once");
    assert_eq!(*NAME.lock().expect("unpoisoned"), "echo");

    let text = "héllo";
    // SAFETY: the pointer and length are the string's, for the call.
    assert!(unsafe { (table.start)(41, text.as_ptr(), text.len()) });
    assert_eq!(recv(&completions, COMPLETION), Ok((SERVICE, 41)));
    assert_eq!(take(table, 41), Some(("héllo".to_owned(), 0x9E3B_8236)));
    assert_eq!(take(table, 41), None);
    assert!(!(table.cancel)(41));
    assert!(!(table.attach)(42, 7), "the take-over is refused");
}
