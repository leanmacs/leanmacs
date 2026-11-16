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
//! adapter: a file a child wrote with `std::fs`, and whether a process is
//! alive with `kill(pid, 0)`.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use editor_process::contract::{self, Ground};
use editor_process::{Command, Input, Processes, RefusalKind};
use editor_process_std::StdProcesses;
use rustix::process::{Pid, Signal, kill_process, test_kill_process};
use tempfile::TempDir;

/// How long the ground waits for something that should happen at once: a
/// file a child writes, a grandchild that its new parent reaps.
const DEADLINE: Duration = Duration::from_secs(10);

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
            Err(error) => error == rustix::io::Errno::PERM,
        }
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
