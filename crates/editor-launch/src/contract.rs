//! The contract of the ports: what the core assumes of every adapter, as
//! checks that run one.
//!
//! - [`check_files`] and [`check_clock`] hold a [`Files`] and a [`Clock`]
//!   to what the core assumes. They run on the fakes (this module's tests)
//!   and on the real adapters (`editor-launch-std`'s `tests/contract.rs`),
//!   so the fakes cannot drift from the system.
//! - [`check_processes`] holds [`Pids`](crate::ports::Pids), [`Spawn`](crate::ports::Spawn) and the real `Exec` to
//!   theirs on real processes, with a helper program: a process that is
//!   not the caller's child is waited on and killed, a detached start has
//!   another parent and outlives its start, and an exec keeps the pid,
//!   hands on exactly the arguments, applies `set` and `unset`, and answers
//!   a missing program as [`Refusal::NotFound`] with the process still
//!   running. An exec cannot be checked in the process that runs the check,
//!   which it would replace, so the helper execs and reports. It runs on
//!   the real adapters alone.
//!
//! # The helper
//!
//! The helper (`editor-launch-std`'s `launch-probe --contract`) takes
//! `--report <file>`, `--sleep <ms>`, `--set <name>=<value>`, `--unset
//! <name>` and `--exec <program> <arguments>…`, the last one last. It
//! writes [`report`] of itself to the report file, then execs when asked,
//! with the variables set and unset; when that exec is refused it writes
//! its report again, with [`refused`] of the refusal, to `<file>.refused`.
//! Then it sleeps, when asked, and exits 0.

use std::path::{Path, PathBuf};

use crate::handover::{escape, unescape};
use crate::ports::{Clock, FileError, Files, Invocation, Pid, Refusal, Waited, World};

/// `write_atomic` then `read` gives the bytes back.
pub const FILES_ROUND_TRIP: &str = "a file written is read back whole";
/// `write_atomic` over a file replaces all of it.
pub const FILES_REPLACE: &str = "a file written over is replaced whole";
/// A missing file is `NotFound`, and does not exist.
pub const FILES_MISSING: &str = "a missing file is NotFound and does not exist";
/// `rename` moves a file, replacing what is there.
pub const FILES_RENAME: &str = "a rename moves the file over what is there";
/// `remove` of nothing is no error.
pub const FILES_REMOVE_NOTHING: &str = "removing nothing is no error";
/// The clock moves forward by at least a sleep.
pub const CLOCK_SLEEPS: &str = "the clock moves forward by at least what was slept";
/// A detached process reports a parent other than the caller.
pub const DETACHED: &str =
    "a detached process is not the caller's child, and is given the pid it reports";
/// A wait on a running process that is not the caller's child times out.
pub const RUNNING: &str =
    "a wait on a running process that is not the caller's child is Running at its timeout";
/// A killed process is then seen to have ended.
pub const KILLED: &str = "a killed process is then Exited";
/// A process that ends by itself is seen to have ended.
pub const ENDED: &str = "a process that is not the caller's child is Exited once it has ended";
/// An exec keeps the pid.
pub const EXEC_SAME_PID: &str = "the program an exec starts has the pid of the one it replaced";
/// An exec hands on exactly its arguments.
pub const EXEC_ARGUMENTS: &str = "an exec hands on exactly its arguments";
/// An exec sets and removes the variables it is given.
pub const EXEC_ENVIRONMENT: &str = "an exec applies its set and its unset";
/// An exec of a missing program is `NotFound`, and the process carries on.
pub const EXEC_NOT_FOUND: &str =
    "an exec of a missing program is NotFound and the process carries on";

/// The variable the exec property sets.
pub const SET: &str = "LEANMACS_LAUNCH_CONTRACT_SET";
/// The variable the exec property removes.
pub const UNSET: &str = "LEANMACS_LAUNCH_CONTRACT_UNSET";
/// The variables a report holds, besides those two: the one the launcher
/// sets on macOS.
pub const REPORTED: [&str; 3] = [SET, UNSET, crate::launch::CF_PROCESS_PATH];

/// The program of [`EXEC_NOT_FOUND`]: an absolute path nothing is at.
pub const NO_SUCH_PROGRAM: &str = "/nonexistent/leanmacs-launch-contract";

/// How long the check waits for a helper's report.
const REPORT_PATIENCE_MS: u64 = 10_000;

/// What a helper reported of itself.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Report {
    /// Its pid.
    pub pid: u32,
    /// Its parent's pid.
    pub ppid: u32,
    /// Its arguments, without the program.
    pub arguments: Vec<String>,
    /// Each of [`REPORTED`]'s variables and its value, when set.
    pub environment: Vec<(String, Option<String>)>,
    /// The refusal of its exec, as `not-found` or `refused` and the reason.
    pub refused: Option<(String, String)>,
}

/// A report's text, one field per line, values escaped as the hand-over
/// record's are.
#[must_use]
pub fn report(r: &Report) -> String {
    let mut out = format!("pid {}\nppid {}\n", r.pid, r.ppid);
    for a in &r.arguments {
        out.push_str(&format!("argument {}\n", escape(a)));
    }
    for (name, value) in &r.environment {
        match value {
            Some(v) => out.push_str(&format!("env {name} {}\n", escape(v))),
            None => out.push_str(&format!("unset {name}\n")),
        }
    }
    if let Some((kind, reason)) = &r.refused {
        out.push_str(&format!("refused {kind} {}\n", escape(reason)));
    }
    out
}

/// The kind word of a refusal in a report.
#[must_use]
pub fn refused(refusal: &Refusal) -> (String, String) {
    let kind = match refusal {
        Refusal::NotFound(_) => "not-found",
        Refusal::Refused(_) | Refusal::Faked => "refused",
    };
    (kind.to_owned(), refusal.to_string())
}

/// A report read back; `None` for text [`report`] did not write.
#[must_use]
pub fn read_report(text: &str) -> Option<Report> {
    let mut r = Report::default();
    for line in text.lines() {
        let (key, rest) = line.split_once(' ')?;
        match key {
            "pid" => r.pid = rest.parse().ok()?,
            "ppid" => r.ppid = rest.parse().ok()?,
            "argument" => r.arguments.push(unescape(rest).ok()?),
            "env" => {
                let (name, value) = rest.split_once(' ')?;
                r.environment
                    .push((name.to_owned(), Some(unescape(value).ok()?)));
            }
            "unset" => r.environment.push((rest.to_owned(), None)),
            "refused" => {
                let (kind, reason) = rest.split_once(' ')?;
                r.refused = Some((kind.to_owned(), unescape(reason).ok()?));
            }
            _ => return None,
        }
    }
    Some(r)
}

/// Runs the file properties in `dir`, which must exist and be empty, and
/// returns the names of those that fail.
pub fn check_files(files: &mut dyn Files, dir: &Path) -> Vec<&'static str> {
    let mut failed = Vec::new();
    let a = dir.join("a");
    let b = dir.join("b");
    let long: Vec<u8> = (0..100_000u32).map(|i| (i % 251) as u8).collect();
    if files.write_atomic(&a, &long).is_err() || files.read(&a).as_deref() != Ok(&long[..]) {
        failed.push(FILES_ROUND_TRIP);
    }
    if files.write_atomic(&a, b"short").is_err() || files.read(&a).as_deref() != Ok(&b"short"[..]) {
        failed.push(FILES_REPLACE);
    }
    let missing = dir.join("missing");
    if files.read(&missing) != Err(FileError::NotFound) || files.exists(&missing) {
        failed.push(FILES_MISSING);
    }
    let renamed = files.write_atomic(&b, b"old").is_ok()
        && files.rename(&a, &b).is_ok()
        && files.read(&b).as_deref() == Ok(&b"short"[..])
        && !files.exists(&a)
        && files.rename(&a, &b) == Err(FileError::NotFound);
    if !renamed {
        failed.push(FILES_RENAME);
    }
    if files.remove(&b).is_err() || files.remove(&b).is_err() || files.exists(&b) {
        failed.push(FILES_REMOVE_NOTHING);
    }
    failed
}

/// Runs the clock's property and returns its name when it fails.
pub fn check_clock(clock: &mut dyn Clock) -> Vec<&'static str> {
    let before = clock.now_ms();
    clock.sleep_ms(20);
    if clock.now_ms() < before + 20 {
        vec![CLOCK_SLEEPS]
    } else {
        Vec::new()
    }
}

fn await_report(world: &mut World<'_>, path: &Path) -> Option<Report> {
    let start = world.clock.now_ms();
    while world.clock.now_ms().saturating_sub(start) < REPORT_PATIENCE_MS {
        if let Ok(bytes) = world.files.read(path) {
            return read_report(&String::from_utf8_lossy(&bytes));
        }
        world.clock.sleep_ms(10);
    }
    None
}

fn helper_run(helper: &Path, report: &Path) -> Invocation {
    Invocation::new(helper)
        .arg("--contract")
        .arg("--report")
        .arg(report)
}

fn refused_path(report: &Path) -> PathBuf {
    let mut name = report.file_name().unwrap_or_default().to_owned();
    name.push(".refused");
    report.with_file_name(name)
}

/// Runs the process properties with `helper` (the program described in the
/// module docs), writing its reports in `dir`, which must exist, and
/// returns the names of those that fail.
pub fn check_processes(world: &mut World<'_>, helper: &Path, dir: &Path) -> Vec<&'static str> {
    let mut failed = Vec::new();
    let own = world.pids.own();

    let sleeper = dir.join("sleeper");
    let spawned = world
        .spawn
        .spawn_detached(&helper_run(helper, &sleeper).arg("--sleep").arg("30000"));
    match spawned {
        Ok(pid) => {
            let reported = await_report(world, &sleeper);
            let detached = reported
                .as_ref()
                .is_some_and(|r| Pid(r.pid) == pid && Pid(r.ppid) != own);
            if !detached {
                failed.push(DETACHED);
            }
            if world.pids.wait_exit(pid, 50) != Waited::Running {
                failed.push(RUNNING);
            }
            world.pids.kill(pid);
            if world.pids.wait_exit(pid, 5_000) != Waited::Exited {
                failed.push(KILLED);
            }
        }
        Err(_) => failed.extend([DETACHED, RUNNING, KILLED]),
    }

    let short = dir.join("short");
    match world
        .spawn
        .spawn_detached(&helper_run(helper, &short).arg("--sleep").arg("100"))
    {
        Ok(pid) if world.pids.wait_exit(pid, 10_000) == Waited::Exited => {}
        _ => failed.push(ENDED),
    }

    let before = dir.join("before");
    let after = dir.join("after");
    let after_text = after.to_string_lossy().into_owned();
    let handed = ["two words", "", "ü\nnext", "--report"];
    let exec = helper_run(helper, &before)
        .arg("--set")
        .arg(format!("{SET}=set"))
        .arg("--unset")
        .arg(UNSET)
        .arg("--exec")
        .arg(helper)
        .args(["--contract", "--report"])
        .arg(&after)
        .args(handed)
        .set(UNSET, "present");
    if world.spawn.spawn_detached(&exec).is_err() {
        failed.extend([EXEC_SAME_PID, EXEC_ARGUMENTS, EXEC_ENVIRONMENT]);
    } else {
        let first = await_report(world, &before);
        let second = await_report(world, &after);
        match (first, second) {
            (Some(first), Some(second)) => {
                if first.pid != second.pid {
                    failed.push(EXEC_SAME_PID);
                }
                let mut expected = vec!["--contract".to_owned(), "--report".to_owned(), after_text];
                expected.extend(handed.iter().map(|s| (*s).to_owned()));
                if second.arguments != expected {
                    failed.push(EXEC_ARGUMENTS);
                }
                let value = |r: &Report, name: &str| {
                    r.environment
                        .iter()
                        .find(|(n, _)| n == name)
                        .and_then(|(_, v)| v.clone())
                };
                let applied = value(&first, UNSET).as_deref() == Some("present")
                    && value(&second, UNSET).is_none()
                    && value(&second, SET).as_deref() == Some("set");
                if !applied {
                    failed.push(EXEC_ENVIRONMENT);
                }
            }
            _ => failed.extend([EXEC_SAME_PID, EXEC_ARGUMENTS, EXEC_ENVIRONMENT]),
        }
    }

    let missing = dir.join("missing");
    let refused_report = refused_path(&missing);
    let missing_exec = helper_run(helper, &missing)
        .arg("--exec")
        .arg(NO_SUCH_PROGRAM);
    let not_found = world.spawn.spawn_detached(&missing_exec).is_ok()
        && await_report(world, &refused_report).is_some_and(|r| {
            r.refused
                .as_ref()
                .is_some_and(|(kind, _)| kind == "not-found")
                && await_report(world, &missing).is_some_and(|m| m.pid == r.pid)
        });
    if !not_found {
        failed.push(EXEC_NOT_FOUND);
    }
    failed
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake::{FakeClock, FakeFiles};

    #[test]
    fn the_fake_files_and_clock_keep_the_contract() {
        let clock = FakeClock::new();
        let mut files = FakeFiles::new(&clock);
        assert_eq!(check_files(&mut files, Path::new("/d")), Vec::<&str>::new());
        let mut clock = clock;
        assert_eq!(check_clock(&mut clock), Vec::<&str>::new());
    }

    #[test]
    fn files_that_lose_writes_fail_their_properties() {
        struct Forgetful;
        impl Files for Forgetful {
            fn read(&self, _: &Path) -> Result<Vec<u8>, FileError> {
                Err(FileError::NotFound)
            }
            fn write_atomic(&mut self, _: &Path, _: &[u8]) -> Result<(), FileError> {
                Ok(())
            }
            fn rename(&mut self, _: &Path, _: &Path) -> Result<(), FileError> {
                Ok(())
            }
            fn remove(&mut self, _: &Path) -> Result<(), FileError> {
                Err(FileError::Other("no".into()))
            }
            fn exists(&self, _: &Path) -> bool {
                true
            }
        }
        assert_eq!(
            check_files(&mut Forgetful, Path::new("/d")),
            vec![
                FILES_ROUND_TRIP,
                FILES_REPLACE,
                FILES_MISSING,
                FILES_RENAME,
                FILES_REMOVE_NOTHING
            ]
        );
    }

    #[test]
    fn a_report_round_trips() {
        let r = Report {
            pid: 9,
            ppid: 1,
            arguments: vec!["a b".into(), String::new(), "x\ny".into()],
            environment: vec![(SET.into(), Some("v".into())), (UNSET.into(), None)],
            refused: Some(refused(&Refusal::NotFound("no such file".into()))),
        };
        assert_eq!(read_report(&report(&r)), Some(r));
        assert_eq!(read_report("what\n"), None);
    }
}
