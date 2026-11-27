//! The runtime's members over the process's real completion queue, as a
//! package's library calls them, through [`RUNTIME`]'s function pointers:
//! a service registered through the runtime completes on the queue the
//! editor's pump reads, from the library's source with its id, and a
//! completion posted as a core service's id is refused and never queued.
//!
//! An integration test of its own, because the queue is process-wide: it is
//! the one test of its binary.

use editor_package_library::runtime::RUNTIME;
use editor_service::queue::{COMPLETION, Event, Source, SourceKind};

/// Registers a service named `name` through the runtime's member.
#[expect(
    unsafe_code,
    reason = "calls the runtime's member as a package's library does, lending the name for the call"
)]
fn register(name: &str) -> u64 {
    // SAFETY: the pointer and length are the string's, for the call.
    unsafe { (RUNTIME.register_service)(name.as_ptr(), name.len()) }
}

#[test]
fn a_completion_through_the_runtime_lands_on_the_completion_queue_and_a_core_id_s_is_refused() {
    let id = register("a library's service");
    let source = Source {
        kind: SourceKind::Library,
        id,
    };

    assert!((RUNTIME.complete)(id, 41));
    // The pull parks until the completion is queued; it is queued already.
    assert_eq!(COMPLETION.next(), Event::completion(source, 41));

    assert!(!(RUNTIME.complete)(3, 42), "the process service's id");
    assert!((RUNTIME.complete)(id, 43));
    // The queue keeps its order, so had the refused completion been queued
    // it would be read first: the next event read is the later one.
    assert_eq!(COMPLETION.next(), Event::completion(source, 43));
}
