//! The watch service's shutdown, through the C function, on real files:
//! once it returns nothing is pending, a pending read is never completed,
//! and a later start is refused as shut down.
//!
//! It is a test binary of its own because shutting the process-wide
//! service down is for good. Its files are in a temporary directory the
//! test makes and removes.

#[path = "common/watches.rs"]
mod common;

use common::{completion_of, next, next_completion, start, take, write};
use editor_ffi::watches::{editor_ffi_watches_pending, editor_ffi_watches_shutdown};

#[test]
fn after_shutdown_nothing_is_pending_a_pending_read_is_dropped_and_a_later_start_is_refused() {
    let directory = tempfile::tempdir().expect("a temporary directory can be made");
    let file = directory.path().join("f");

    assert!(start(1, 0, 0, 64, &file));
    assert_eq!(next_completion(), completion_of(1));
    assert_eq!(take(1).map(|taken| taken.status), Some(0));
    assert!(start(2, 2, 0, 64, directory.path()));
    assert_eq!(next_completion(), completion_of(2));
    assert_eq!(take(2).map(|taken| taken.status), Some(0));
    assert!(next(1, 3));

    editor_ffi_watches_shutdown();
    write(&file, b"x");

    assert_eq!(editor_ffi_watches_pending(), 0);
    assert!(start(4, 0, 0, 64, &file));
    assert_eq!(
        next_completion(),
        completion_of(4),
        "the shut-down start is completed, not the dropped read"
    );
    assert_eq!(
        take(4).map(|taken| taken.status),
        Some(6),
        "refused as shut down"
    );
    assert_eq!(take(3), None);
    editor_ffi_watches_shutdown();
    assert_eq!(editor_ffi_watches_pending(), 0);
}
