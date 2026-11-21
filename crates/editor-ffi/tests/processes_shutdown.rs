//! The process service's shutdown, through the C function, on real
//! processes: once it returns, the child it was running and a streaming
//! child held at its bound have been reaped, the grandchild ends, a later
//! run is refused as shut down, and nothing is pending.
//!
//! It is a test binary of its own because shutting the process-wide
//! service down is for good. The child writes its own id and its
//! grandchild's into a temporary directory the test makes and removes; the
//! test reads them with `std::fs`, which the crate's `clippy.toml` refuses
//! everywhere else, hence the one `expect` below, and asks the system
//! directly, with `kill(pid, 0)`, whether each is alive.

#[path = "common/processes.rs"]
mod common;
#[path = "common/open.rs"]
mod open;

use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

use common::{DEADLINE, ROOMY, completion_of, next_completion, run, take};
use editor_ffi::processes::{editor_ffi_processes_pending, editor_ffi_processes_shutdown};
use open::{comes_to_be_held, open};
use rustix::process::{Pid, test_kill_process};

/// The id `echo` wrote to the file at `path`, once it is there whole.
#[expect(
    clippy::disallowed_methods,
    reason = "the test reads the ids its child wrote into a temporary directory it owns; it reads no other file"
)]
fn written(path: &Path) -> Option<u32> {
    let end = Instant::now() + DEADLINE;
    loop {
        if let Ok(text) = std::fs::read_to_string(path)
            && let Some(number) = text.strip_suffix('\n')
            && let Ok(id) = number.parse()
        {
            return Some(id);
        }
        if Instant::now() >= end {
            return None;
        }
        thread::sleep(Duration::from_millis(2));
    }
}

/// Whether a process with the id `id` exists, a zombie counted as alive.
fn alive(id: u32) -> bool {
    let pid = i32::try_from(id)
        .ok()
        .and_then(Pid::from_raw)
        .expect("a pid");
    match test_kill_process(pid) {
        Ok(()) => true,
        Err(error) => error == rustix::io::Errno::PERM,
    }
}

#[test]
fn after_shutdown_the_child_is_reaped_its_grandchild_ends_and_a_later_run_is_refused() {
    let directory = tempfile::tempdir().expect("a temporary directory can be made");
    let dir = directory.path();

    assert!(run(
        1,
        "echo $$ > child; /bin/sleep 600 & echo $! > grandchild; wait",
        dir,
        ROOMY
    ));
    let child = written(&dir.join("child")).expect("the child wrote its id");
    let grandchild = written(&dir.join("grandchild")).expect("the child wrote its grandchild's id");
    assert!(alive(child) && alive(grandchild));
    // A streaming child still writing, held at its bound, as the editor
    // quits.
    assert!(open(
        3,
        "echo $$ > streaming; while :; do echo y; done",
        dir,
        false,
        64
    ));
    assert_eq!(next_completion(), completion_of(3));
    let streaming = written(&dir.join("streaming")).expect("the streaming child wrote its id");
    assert!(comes_to_be_held(3));

    editor_ffi_processes_shutdown();

    assert!(
        !alive(child),
        "the child is reaped by the time shutdown returns"
    );
    assert!(
        !alive(streaming),
        "the held streaming child is reaped by then too"
    );
    let end = Instant::now() + DEADLINE;
    while alive(grandchild) && Instant::now() < end {
        thread::sleep(Duration::from_millis(2));
    }
    assert!(!alive(grandchild), "the grandchild ends");
    assert_eq!(editor_ffi_processes_pending(), 0);

    assert!(run(2, "exit 0", dir, ROOMY));
    assert_eq!(
        next_completion(),
        completion_of(2),
        "the shut-down run is completed, not the cancelled one"
    );
    assert_eq!(
        take(2).map(|taken| taken.status),
        Some(6),
        "refused as shut down"
    );
    assert_eq!(take(1), None);
    editor_ffi_processes_shutdown();
    assert_eq!(editor_ffi_processes_pending(), 0);
}
