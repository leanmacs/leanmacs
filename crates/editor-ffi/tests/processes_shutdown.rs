//! The process service's shutdown, through the C function, on real
//! processes: once it returns, the child it was running and a streaming
//! child held at its bound have been reaped, the grandchild ends, a later
//! run is refused as shut down, and nothing is pending.
//!
//! It is a test binary of its own because shutting the process-wide
//! service down is for good. The child writes its own id and its
//! grandchild's into FIFOs in a temporary directory the test makes and
//! removes; the test reads each on a thread it joins, with `std::fs`, which
//! the root `clippy.toml` refuses everywhere else, hence the one `expect`
//! below, and asks the system
//! directly, with `kill(pid, 0)`, whether each is alive. The grandchild's
//! end, which its new parent reaps, is waited for on the system's exit
//! event with `editor-launch-std`'s `StdPids::wait_exit`: this crate is the
//! one allowed to link the launcher's adapters.

#[path = "common/processes.rs"]
mod common;
#[path = "common/open.rs"]
mod open;

use std::path::Path;
use std::sync::mpsc;
use std::thread;

use common::{DEADLINE, ROOMY, completion_of, next_completion, run, take};
use editor_ffi::processes::{editor_ffi_processes_pending, editor_ffi_processes_shutdown};
use editor_launch::ports::{Pid as LaunchPid, Pids, Waited};
use editor_launch_std::StdPids;
use open::{comes_to_be_held, open};
use rustix::fs::{self, Mode, OFlags};
use rustix::process::{Pid, test_kill_process};

/// The id `echo` wrote to the FIFO at `path`, read whole on a thread of
/// its own, which is joined before this returns. The child's `>` blocks
/// until the reader opens the FIFO, and the read ends when the child's
/// `echo` closes it, so the line is there whole once the read ends: no
/// read is tried again.
#[expect(
    clippy::disallowed_methods,
    reason = "the test reads the ids its child wrote into a temporary directory it owns; it reads no other file"
)]
fn written(path: &Path) -> Option<u32> {
    let (sender, read) = mpsc::channel();
    let reader = {
        let path = path.to_path_buf();
        thread::spawn(move || {
            sender.send(std::fs::read_to_string(path).ok()).ok();
        })
    };
    // hang guard: the child's `echo` opening the FIFO and closing it; only
    // a hang reaches the bound, and the check then fails as a hang.
    let text = editor_wait::recv(&read, DEADLINE).unwrap_or_else(|_| {
        // The child never opened it: open its write end, without waiting
        // for a reader, so a reader still waiting in its open ends with
        // nothing read.
        drop(fs::open(
            path,
            OFlags::WRONLY | OFlags::NONBLOCK | OFlags::CLOEXEC,
            Mode::empty(),
        ));
        None
    });
    reader.join().expect("the reader ends");
    text?.strip_suffix('\n')?.parse().ok()
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
    // The FIFOs the children write their ids to, made by a run of
    // `mkfifo`: this crate starts no process but through the C functions.
    assert!(run(4, "mkfifo child grandchild streaming", dir, ROOMY));
    assert_eq!(next_completion(), completion_of(4));
    let made = take(4).expect("the run's result");
    assert_eq!((made.status, made.words), (0, vec![0, 0]), "exited with 0");

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
    // Its new parent reaps it, so its end is waited for on the system's
    // exit event, the launcher's own wait for a process's end.
    // hang guard: the grandchild's exit; only a hang reaches the bound, and
    // the check then fails as a hang.
    let guard = u64::try_from(DEADLINE.bound().as_millis()).unwrap_or(u64::MAX);
    assert_eq!(
        StdPids.wait_exit(LaunchPid(grandchild), guard),
        Waited::Exited,
        "the grandchild ends"
    );
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
