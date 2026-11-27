//! Package libraries compiled from C run on the process's real runtime,
//! loaded through the C function a package's glue calls
//! (`editor_ffi_package_load`), over the real loader:
//!
//! - a library built when the runtime ended at `complete`, against its own
//!   copy of that smaller struct (`editor-package-library-fixture`'s
//!   `older_runtime.c`), loads and completes through it on today's larger
//!   runtime;
//! - a library built against the generated header
//!   (`crates/editor-package-runtime/include/editor_package_runtime.h`,
//!   `current_runtime.c`), the one place the header is compiled by a C
//!   compiler and run against the Rust runtime, checks it has every member
//!   it calls, then completes, posts an event to the editor queue, and lends
//!   a buffer that is reclaimed once and refused the second time.
//!
//! What each member does is pinned by the runtime's contract, on the model
//! and on the real runtime (`editor-package-library`); this pins that the
//! C layout of both headers matches the Rust definition, over the real
//! load.
//!
//! An integration test of its own, and its one test: the queues, the ledger
//! and the loader are the process's.

use std::ffi::c_void;
use std::ptr;

use editor_ffi::package_library::editor_ffi_package_load;
use editor_package_library_fixture as package;
use editor_service::queue::{COMPLETION, EDITOR, Event, Source, SourceKind};

/// The older library's table (`older_runtime.c`).
#[repr(C)]
struct OlderTable {
    /// Its size.
    size: usize,
    /// The service it registered.
    service: u64,
    /// Completes a request through the older runtime's `complete`.
    fire: extern "C" fn(request: u64) -> bool,
}

/// The current library's table (`current_runtime.c`).
#[repr(C)]
struct CurrentTable {
    /// Its size.
    size: usize,
    /// The service it registered.
    service: u64,
    /// Completes a request through the runtime's `complete`.
    fire: extern "C" fn(request: u64) -> bool,
    /// Posts an event of a code and a text through the runtime's
    /// `post_event`.
    post: unsafe extern "C" fn(code: u64, text: *const u8, len: usize) -> bool,
    /// Lends a buffer through `buffer_lend` and hands it back twice
    /// through `buffer_free`, answering both hand-backs.
    lend_twice: unsafe extern "C" fn(first: *mut bool, second: *mut bool),
}

/// Loads the library at `path` through the C function, and reads the
/// table its init wrote as a `T`.
///
/// # Safety
///
/// The library's table is a `T`.
unsafe fn load<T>(path: &str) -> &'static T {
    let mut table: *const c_void = ptr::null();
    // SAFETY: the path is the string's, for the call, and the table's place
    // is writable.
    let status = unsafe { editor_ffi_package_load(path.as_ptr(), path.len(), &raw mut table) };
    assert_eq!(status, 0, "{path} loads");
    // SAFETY: the caller says what the table is; a library's table lives
    // for the process.
    unsafe { table.cast::<T>().as_ref() }.expect("a table")
}

/// A source of the library service `id`.
const fn library(id: u64) -> Source {
    Source {
        kind: SourceKind::Library,
        id,
    }
}

/// The next event on the completion queue, which must hold one already.
fn next_completion() -> Event {
    assert_eq!(COMPLETION.queued(), 1, "one completion queued");
    COMPLETION.next()
}

/// The next event on the editor queue, which must hold one already.
fn next_event() -> Event {
    assert_eq!(EDITOR.queued(), 1, "one event queued");
    EDITOR.next()
}

#[test]
fn libraries_built_against_an_older_and_the_current_header_run_on_the_process_s_runtime() {
    // SAFETY: each fixture's table is laid out as the struct read.
    let older = unsafe { load::<OlderTable>(package::OLDER_RUNTIME) };
    // SAFETY: as above.
    let current = unsafe { load::<CurrentTable>(package::CURRENT_RUNTIME) };
    assert_eq!(older.size, size_of::<OlderTable>());
    assert_eq!(current.size, size_of::<CurrentTable>());
    assert_ne!(older.service, current.service);

    assert!((older.fire)(5));
    assert_eq!(
        next_completion(),
        Event::completion(library(older.service), 5)
    );

    assert!((current.fire)(6));
    assert_eq!(
        next_completion(),
        Event::completion(library(current.service), 6)
    );

    let text = "héllo";
    // SAFETY: the text is lent for the call.
    assert!(unsafe { (current.post)(7, text.as_ptr(), text.len()) });
    assert_eq!(
        next_event(),
        Event::message(library(current.service), 7, "héllo")
    );

    let (mut first, mut second) = (false, true);
    // SAFETY: both places are writable.
    unsafe { (current.lend_twice)(&raw mut first, &raw mut second) };
    assert_eq!(
        (first, second),
        (true, false),
        "reclaimed once, refused once"
    );
}
