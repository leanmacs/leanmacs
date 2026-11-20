//! The C functions over the process's watch service, called the way the C
//! glue calls them, with its completions pulled from the process's
//! completion queue, on real files.
//!
//! This is the wiring test: the C functions, the process's service, the
//! service of `editor-watch` and the real adapter, `editor-watch-notify`.
//! It asserts wiring only: a watch that went in was registered, a write
//! came out as a change of the file with its kinds, once, after its
//! completion; and a cancelled watch's read is never completed. What a
//! watch does is `editor-watch`'s rule, pinned there on the fake and by the
//! contract on real files.
//!
//! It is an integration test of its own, and one test function, because the
//! service and the completion queue are process-wide. It does not shut the
//! service down, which is for good: `tests/watches_shutdown.rs` does, in a
//! process of its own.
//!
//! Every file is in a temporary directory the test makes, which is removed
//! when it ends.

#[path = "common/watches.rs"]
mod common;

use common::{completion_of, next, next_completion, start, take, write};
use editor_ffi::watches::{
    editor_ffi_watches_cancel, editor_ffi_watches_flush, editor_ffi_watches_pending,
};

/// The bit of a written change.
const WRITTEN: u64 = 2;

#[test]
fn a_watch_is_started_through_c_and_a_write_is_delivered_on_the_completion_queue_unless_cancelled()
{
    let directory = tempfile::tempdir().expect("a temporary directory can be made");
    let file = directory.path().join("f");
    write(&file, b"x");
    let before = editor_ffi_watches_pending();

    assert!(start(1, 0, 0, 64, &file));
    assert_eq!(next_completion(), completion_of(1));
    assert_eq!(take(1).map(|taken| taken.status), Some(0), "started");
    assert_eq!(take(1), None, "taken once");

    // Reads until the write is delivered: a platform can split what one
    // write made across deliveries.
    write(&file, b"y");
    let path = file.to_str().expect("UTF-8").as_bytes().to_vec();
    let mut written = false;
    for wait in 2..6 {
        assert!(next(1, wait));
        assert_eq!(next_completion(), completion_of(wait));
        let taken = take(wait).expect("a delivery");
        assert_eq!(taken.status, 8);
        assert!(
            taken.changes().iter().all(|(of, _)| *of == path),
            "the file only"
        );
        if taken.changes().iter().any(|(_, bits)| bits & WRITTEN != 0) {
            written = true;
            break;
        }
    }
    assert!(written, "the write was delivered");

    // A cancelled watch's pending read is never completed: the next
    // completion is a marker's, started after it.
    assert!(next(1, 10));
    assert!(editor_ffi_watches_cancel(1));
    write(&file, b"z");
    assert!(start(11, 1, 0, 64, directory.path()));
    assert_eq!(next_completion(), completion_of(11));
    assert_eq!(take(10), None);
    assert_eq!(take(11).map(|taken| taken.status), Some(0));
    assert!(editor_ffi_watches_cancel(11));

    // A refusal crosses as its status, with its detail naming the path.
    let missing = directory.path().join("missing");
    assert!(start(12, 1, 0, 64, &missing));
    assert_eq!(next_completion(), completion_of(12));
    let refused = take(12).expect("a reply");
    assert_eq!(refused.status, 2, "not found");
    assert!(refused.detail.contains("missing"));

    // A flush asked behind a start is completed after it.
    assert!(start(13, 1, 0, 64, directory.path()));
    assert!(editor_ffi_watches_flush(14));
    assert_eq!(next_completion(), completion_of(13));
    assert_eq!(next_completion(), completion_of(14));
    assert_eq!(take(14), None, "a flush keeps no reply");
    assert_eq!(take(13).map(|taken| taken.status), Some(0));
    assert!(editor_ffi_watches_cancel(13));

    // Words that spell no start start nothing.
    // SAFETY: no bytes are lent.
    assert!(!unsafe {
        editor_ffi::watches::editor_ffi_watches_start(13, std::ptr::null(), 0, std::ptr::null(), 0)
    });
    assert_eq!(editor_ffi_watches_pending(), before);
}
