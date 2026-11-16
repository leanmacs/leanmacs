//! The C functions over the process's process service, called the way the
//! C glue calls them, with its completions pulled from the process's
//! completion queue, on real processes.
//!
//! This is the wiring test: the C functions, the process's service, the
//! service of `editor-process` and the real adapter, `editor-process-std`.
//! It asserts wiring only: a command that went in ran, and its status and
//! its bytes came out, once, after its completion; a run fed its standard
//! input hands it to its child; and a cancelled run is never completed and
//! its child is reaped. What a run does is
//! `editor-process`'s rule, pinned there on the fake and by the contract on
//! real processes.
//!
//! It is an integration test of its own, and one test function, because the
//! service and the completion queue are process-wide. It does not shut the
//! service down, which is for good: `tests/processes_shutdown.rs` does,
//! in a process of its own.
//!
//! Every child runs in a temporary directory the test makes, which is
//! removed when it ends, and writes nothing. The test names no method the
//! crate's `clippy.toml` refuses: it reaches real processes through the C
//! functions alone.

#[path = "common/processes.rs"]
mod common;

use std::thread;
use std::time::Instant;

use common::{DEADLINE, ROOMY, Taken, completion_of, next_completion, run, run_input, take};
use editor_ffi::processes::{editor_ffi_processes_cancel, editor_ffi_processes_pending};

/// Whether `pending` comes to `count` within the deadline.
fn pending_comes_to(count: u64) -> bool {
    let end = Instant::now() + DEADLINE;
    while Instant::now() < end {
        if editor_ffi_processes_pending() == count {
            return true;
        }
        thread::yield_now();
    }
    false
}

#[test]
fn a_command_is_run_through_c_completed_on_the_completion_queue_and_taken_once_unless_cancelled() {
    let directory = tempfile::tempdir().expect("a temporary directory can be made");
    let before = editor_ffi_processes_pending();

    assert!(run(
        1,
        "printf out; printf err >&2; exit 3",
        directory.path(),
        ROOMY
    ));
    assert_eq!(next_completion(), completion_of(1));
    assert_eq!(
        take(1),
        Some(Taken {
            status: 0,
            words: vec![0, 3],
            detail: String::new(),
            stdout: b"out".to_vec(),
            stderr: b"err".to_vec(),
        })
    );
    assert_eq!(take(1), None, "taken once");

    // A run cancelled while its child sleeps is never completed: the next
    // completion is the marker's, started after it.
    assert!(run(2, "/bin/sleep 600", directory.path(), ROOMY));
    assert!(pending_comes_to(before + 1));
    assert!(editor_ffi_processes_cancel(2));
    assert!(
        pending_comes_to(before),
        "the cancelled run's child is reaped"
    );
    assert!(run(3, "exit 0", directory.path(), ROOMY));
    assert_eq!(next_completion(), completion_of(3));
    assert_eq!(take(2), None);
    assert_eq!(take(3).map(|taken| taken.words), Some(vec![0, 0]));

    // A run fed its standard input hands it to the child whole: `cat`
    // gives back a NUL and a byte that is not UTF-8.
    assert!(run_input(
        5,
        "/bin/cat",
        directory.path(),
        b"fed\0\xff\n",
        ROOMY
    ));
    assert_eq!(next_completion(), completion_of(5));
    assert_eq!(
        take(5).map(|taken| (taken.status, taken.words, taken.stdout)),
        Some((0, vec![0, 0], b"fed\0\xff\n".to_vec()))
    );

    // Words that spell no command start nothing.
    // SAFETY: no bytes are lent.
    assert!(!unsafe {
        editor_ffi::processes::editor_ffi_processes_run(4, std::ptr::null(), 0, std::ptr::null(), 0)
    });
    assert_eq!(editor_ffi_processes_pending(), before);
}
