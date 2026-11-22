//! The `std::process` adapter held to the process port's contract, on real
//! processes.
//!
//! The check is `editor-process`'s, the same one its fake passes
//! (`editor_process::contract::check`), the service's properties among
//! them. It runs in a temporary directory this test makes, which is removed
//! when the test ends: every child runs there, every file a child writes
//! is there, and the working directory and the environment of the test
//! are not touched.
//!
//! The ground reads the truth with the system directly, never through the
//! adapter: a file a child wrote with `std::fs`, whether a process is
//! alive with `kill(pid, 0)`, and its end on the system's exit event
//! (kqueue's `NOTE_EXIT` on macOS, a pidfd on Linux), never by asking
//! again.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use editor_process::contract::{self, Ground};
use editor_process::{Command, Input, Processes, RefusalKind};
use editor_process_std::StdProcesses;
use rustix::io::Errno;
use rustix::process::{Pid, Signal, kill_process, test_kill_process};
use tempfile::TempDir;

/// hang guard: each event the ground and the check wait for with it, a
/// file a child writes, a process's exit, a completion, which must come;
/// only a hang reaches the bound, and the check then fails as a hang.
const DEADLINE: Duration = Duration::from_secs(10);

/// Whether the process `pid` exits within `bound`, told by kqueue's
/// `NOTE_EXIT`: a registration refused with `ESRCH` means it has already
/// ended. Any other failure is the error, with no polling in its place.
/// The twin of `editor-launch-std`'s `StdPids::wait_exit`.
#[cfg(target_os = "macos")]
fn exits_within(pid: Pid, bound: Duration) -> rustix::io::Result<bool> {
    use rustix::buffer::spare_capacity;
    use rustix::event::kqueue::{Event, EventFilter, EventFlags, ProcessEvents, kevent, kqueue};
    let queue = kqueue()?;
    let change = Event::new(
        EventFilter::Proc {
            pid,
            flags: ProcessEvents::EXIT,
        },
        EventFlags::ADD | EventFlags::ONESHOT,
        std::ptr::null_mut(),
    );
    let mut out = Vec::with_capacity(1);
    // SAFETY: the event names a process, not a file descriptor, so no
    // descriptor it refers to can be closed while the queue lives.
    let waited = unsafe { kevent(&queue, &[change], spare_capacity(&mut out), Some(bound)) };
    match waited {
        Ok(0) => Ok(false),
        // A registration that fails with room for events comes back as an
        // event flagged as an error, its errno in `data`.
        Ok(_) => match out.first() {
            Some(event) if event.flags().contains(EventFlags::ERROR) => {
                let errno =
                    i32::try_from(event.data()).map_or(Errno::INVAL, Errno::from_raw_os_error);
                if errno == Errno::SRCH {
                    Ok(true)
                } else {
                    Err(errno)
                }
            }
            _ => Ok(true),
        },
        Err(Errno::SRCH) => Ok(true),
        Err(error) => Err(error),
    }
}

/// Whether the process `pid` exits within `bound`, told by its pidfd's
/// becoming readable: `ESRCH` from `pidfd_open` means it has already
/// ended. Any other failure is the error, with no polling in its place.
/// The twin of `editor-launch-std`'s `StdPids::wait_exit`.
#[cfg(target_os = "linux")]
fn exits_within(pid: Pid, bound: Duration) -> rustix::io::Result<bool> {
    use rustix::event::{PollFd, PollFlags, Timespec, poll};
    use rustix::process::{PidfdFlags, pidfd_open};
    let fd = match pidfd_open(pid, PidfdFlags::empty()) {
        Ok(fd) => fd,
        Err(Errno::SRCH) => return Ok(true),
        Err(error) => return Err(error),
    };
    let timeout = Timespec {
        tv_sec: i64::try_from(bound.as_secs()).unwrap_or(i64::MAX),
        tv_nsec: bound.subsec_nanos().into(),
    };
    let mut fds = [PollFd::new(&fd, PollFlags::IN)];
    Ok(poll(&mut fds, Some(&timeout))? > 0)
}

/// No exit event this ground knows of: the check fails with the error
/// rather than polling.
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn exits_within(_pid: Pid, _bound: Duration) -> rustix::io::Result<bool> {
    Err(Errno::NOSYS)
}

/// The ground for the adapter: a temporary directory, and the system asked
/// directly.
struct System {
    /// The directory, with the links in its path followed (on macOS the
    /// temporary directory is reached through one).
    root: PathBuf,
    /// The directory's owner: dropping it removes the directory.
    _directory: TempDir,
}

impl System {
    /// A new, empty directory of this test's own.
    fn new() -> Self {
        let directory = tempfile::tempdir().expect("a temporary directory can be made");
        let root = fs::canonicalize(directory.path()).expect("the directory's own path resolves");
        Self {
            root,
            _directory: directory,
        }
    }
}

impl Ground for System {
    fn make_file(&self, path: &Path) -> Result<(), String> {
        fs::write(path, b"").map_err(|error| error.to_string())
    }

    /// hang guard: the child's `echo` completing its line; only a hang
    /// reaches [`DEADLINE`], and the check then fails as a hang. A read and
    /// retry, kept so because the contract starts the child before it asks
    /// for the file, so the ground cannot make it a FIFO first: a read finds
    /// no file, an empty one or a partial number, and tries again. The
    /// result is decided by the line appearing, never by the time.
    fn written(&self, path: &Path) -> Option<u32> {
        let end = Instant::now() + DEADLINE;
        loop {
            // `echo` ends what it writes with a line feed, so a number
            // without one may be half written.
            if let Ok(text) = fs::read_to_string(path)
                && let Some(number) = text.strip_suffix('\n')
                && let Ok(id) = number.parse()
            {
                return Some(id);
            }
            if Instant::now() >= end {
                return None;
            }
            // hang guard: the same line, read again once it may be there;
            // the sleep only spaces the reads.
            thread::sleep(Duration::from_millis(2));
        }
    }

    fn exists(&self, path: &Path) -> bool {
        fs::symlink_metadata(path).is_ok()
    }

    fn alive(&self, id: u32) -> bool {
        let Some(pid) = i32::try_from(id).ok().and_then(Pid::from_raw) else {
            return false;
        };
        match test_kill_process(pid) {
            Ok(()) => true,
            // A process of another user's is there all the same.
            Err(error) => error == Errno::PERM,
        }
    }

    fn ends(&self, id: u32) -> bool {
        let Some(pid) = i32::try_from(id).ok().and_then(Pid::from_raw) else {
            return true;
        };
        exits_within(pid, DEADLINE)
            .unwrap_or_else(|error| panic!("no wait for the exit of process {id}: {error}"))
    }

    fn end(&self, id: u32) {
        if let Some(pid) = i32::try_from(id).ok().and_then(Pid::from_raw) {
            // One that has ended already is nothing to end.
            kill_process(pid, Signal::KILL).ok();
        }
    }

    fn escapes(&self) -> bool {
        let there = Path::new(contract::ESCAPE).is_file();
        if !there {
            // No test framework here skips a part of a test, so the skip is
            // said where `cargo test` shows what a test printed.
            eprintln!(
                "skipping `{}`: {} is not on this machine, and the check starts a process outside its group with it",
                contract::ESCAPED,
                contract::ESCAPE
            );
        }
        there
    }

    fn deadline(&self) -> Duration {
        DEADLINE
    }
}

/// The ground's exit wait on a process of the test's own, in each state it
/// can find one in: running for the whole of a bound of zero, a zombie
/// once killed and not yet reaped, and gone once reaped.
#[test]
fn the_grounds_exit_wait_says_running_for_a_live_process_and_ended_for_a_zombie_and_a_reaped_one() {
    let mut child = std::process::Command::new("/bin/sleep")
        .arg("600")
        .stdin(std::process::Stdio::null())
        .spawn()
        .expect("sleep starts");
    let pid = i32::try_from(child.id())
        .ok()
        .and_then(Pid::from_raw)
        .expect("a pid");

    // Alive until it is killed, so a wait of no time finds it running.
    let running = exits_within(pid, Duration::ZERO);
    kill_process(pid, Signal::KILL).expect("the child can be killed");
    // A zombie until it is reaped: it has exited.
    let zombie = exits_within(pid, DEADLINE);
    let alive_as_zombie = System::new().alive(child.id());
    child.wait().expect("the child is reaped");
    let reaped = exits_within(pid, DEADLINE);

    assert_eq!(running, Ok(false));
    assert_eq!(zombie, Ok(true), "a zombie has ended");
    assert!(alive_as_zombie, "though `alive` counts it");
    assert_eq!(reaped, Ok(true), "no such process has ended");
}

#[test]
fn the_adapter_keeps_the_process_ports_contract_on_real_processes_in_a_temporary_directory() {
    let system = System::new();

    assert_eq!(
        contract::check(&StdProcesses::system(), &system, &system.root),
        [""; 0]
    );
}

#[test]
fn a_regular_file_that_is_not_executable_is_denied_and_the_detail_names_the_program_and_the_directory()
 {
    let system = System::new();
    let program = system.root.join("not-executable");
    fs::write(&program, b"#!/bin/sh\n").expect("the file is made");
    fs::set_permissions(&program, fs::Permissions::from_mode(0o644)).expect("its mode is set");
    let program = program.display().to_string();

    let refusal = StdProcesses::system()
        .spawn(
            &Command::new(program.clone(), [""; 0], &system.root),
            Input::Closed,
        )
        .expect_err("refused");

    assert_eq!(refusal.kind, RefusalKind::Denied);
    assert!(refusal.detail.contains(&program));
    assert!(refusal.detail.contains(&system.root.display().to_string()));
}

#[test]
fn a_failure_that_is_neither_missing_nor_denied_is_failed() {
    let system = System::new();
    // A program name with a NUL byte cannot be handed to the system at all.
    let refusal = StdProcesses::system()
        .spawn(
            &Command::new("/bin/s\0h", [""; 0], &system.root),
            Input::Closed,
        )
        .expect_err("refused");

    assert_eq!(refusal.kind, RefusalKind::Failed);
}
