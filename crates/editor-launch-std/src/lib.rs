//! The app launcher's real adapters, and the edge where `editor-launch`'s
//! core meets the system: files over `std::fs` ([`StdFiles`]), the time
//! over `std::time` ([`StdClock`]), processes by id over rustix
//! ([`StdPids`]), detached starts over a double `std::process` spawn
//! ([`StdSpawn`]), the exec over `CommandExt::exec` ([`StdExec`]), the
//! launcher's own facts ([`StdPlatform`]) and CoreFoundation's main bundle
//! ([`identity`]).
//!
//! Two binaries wire them: `leanmacs`, the bundle's launcher
//! (`src/bin/leanmacs.rs`), and `launch-probe`, the tests' helper
//! (`src/bin/launch-probe.rs`). `editor-ffi` forwards Lean's exec and main
//! bundle to [`StdExec`] and [`identity::main_bundle`].
//!
//! Every adapter is thin: every decision is the core's. `tests/contract.rs`
//! holds them to the ports' contract, `tests/fallback.rs` runs the launcher
//! and its watcher on real processes, and `tests/identity.rs` (macOS)
//! checks CoreFoundation's main bundle in a process the launcher started
//! from outside a bundle.

pub mod identity;

use std::ffi::OsString;
use std::io::{self, Write as _};
use std::os::fd::AsFd;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::time::{Duration, Instant};

use editor_launch::ports::{
    Clock, Exec, FileError, Files, Invocation, Pid, Pids, Platform, Refusal, Spawn, Waited,
};

fn file_error(e: &io::Error) -> FileError {
    if e.kind() == io::ErrorKind::NotFound {
        FileError::NotFound
    } else {
        FileError::Other(e.to_string())
    }
}

/// Files over `std::fs`. A write goes to a temporary file beside the
/// target, named for this process, which is then renamed over it; a
/// listing is `read_dir`'s, and a missing directory `NotFound`.
#[derive(Debug, Clone, Copy, Default)]
pub struct StdFiles;

#[expect(
    clippy::disallowed_methods,
    reason = "`StdFiles` is the launcher's real files: `std::fs` is what it adapts"
)]
impl Files for StdFiles {
    fn read(&self, path: &Path) -> Result<Vec<u8>, FileError> {
        std::fs::read(path).map_err(|e| file_error(&e))
    }

    fn write_atomic(&mut self, path: &Path, bytes: &[u8]) -> Result<(), FileError> {
        let mut name = path.file_name().unwrap_or_default().to_owned();
        name.push(format!(".tmp-{}", std::process::id()));
        let temporary = path.with_file_name(name);
        let written =
            std::fs::write(&temporary, bytes).and_then(|()| std::fs::rename(&temporary, path));
        if let Err(e) = written {
            let _ = std::fs::remove_file(&temporary);
            return Err(file_error(&e));
        }
        Ok(())
    }

    fn rename(&mut self, from: &Path, to: &Path) -> Result<(), FileError> {
        std::fs::rename(from, to).map_err(|e| file_error(&e))
    }

    fn remove(&mut self, path: &Path) -> Result<(), FileError> {
        match std::fs::remove_file(path) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => Err(file_error(&e)),
            _ => Ok(()),
        }
    }

    fn exists(&self, path: &Path) -> bool {
        path.exists()
    }

    fn list(&self, dir: &Path) -> Result<Vec<OsString>, FileError> {
        std::fs::read_dir(dir)
            .and_then(|entries| entries.map(|entry| entry.map(|e| e.file_name())).collect())
            .map_err(|e| file_error(&e))
    }

    fn make_dir_all(&mut self, dir: &Path) -> Result<(), FileError> {
        std::fs::create_dir_all(dir).map_err(|e| file_error(&e))
    }
}

/// The time since this clock was made, over `std::time::Instant`.
#[derive(Debug, Clone, Copy)]
pub struct StdClock(Instant);

impl Default for StdClock {
    fn default() -> Self {
        #[expect(
            clippy::disallowed_methods,
            reason = "the launcher's real clock: the `Clock` port's adapter"
        )]
        Self(Instant::now())
    }
}

impl Clock for StdClock {
    fn now_ms(&self) -> u64 {
        u64::try_from(self.0.elapsed().as_millis()).unwrap_or(u64::MAX)
    }

    fn sleep_ms(&mut self, ms: u64) {
        #[expect(
            clippy::disallowed_methods,
            reason = "the launcher's real clock: the `Clock` port's adapter sleeps as the core asks"
        )]
        std::thread::sleep(Duration::from_millis(ms));
    }
}

/// Processes by id, over rustix: kqueue's `NOTE_EXIT` on macOS,
/// `pidfd_open` and `poll` on Linux, and `kill(pid, 0)` every 50 ms where
/// neither can be had.
#[derive(Debug, Clone, Copy, Default)]
pub struct StdPids;

fn raw(pid: Pid) -> Option<rustix::process::Pid> {
    i32::try_from(pid.0)
        .ok()
        .and_then(rustix::process::Pid::from_raw)
}

/// `kill(pid, 0)` until it says no such process, or the time is up.
#[expect(
    clippy::disallowed_methods,
    reason = "the launcher's exit wait where no exit event can be had (no kqueue or pidfd): `kill(pid, 0)` every 50 ms on the real clock, production and never a test's wait"
)]
fn poll_exit(pid: rustix::process::Pid, timeout_ms: u64) -> Waited {
    let start = Instant::now();
    loop {
        if rustix::process::test_kill_process(pid) == Err(rustix::io::Errno::SRCH) {
            return Waited::Exited;
        }
        let elapsed = u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX);
        if elapsed >= timeout_ms {
            return Waited::Running;
        }
        std::thread::sleep(Duration::from_millis(50.min(timeout_ms - elapsed)));
    }
}

#[cfg(target_os = "macos")]
fn wait_exit_os(pid: rustix::process::Pid, timeout_ms: u64) -> Waited {
    use rustix::buffer::spare_capacity;
    use rustix::event::kqueue::{Event, EventFilter, EventFlags, ProcessEvents, kevent, kqueue};
    let Ok(queue) = kqueue() else {
        return poll_exit(pid, timeout_ms);
    };
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
    let waited = unsafe {
        kevent(
            &queue,
            &[change],
            spare_capacity(&mut out),
            Some(Duration::from_millis(timeout_ms)),
        )
    };
    match waited {
        Ok(0) => Waited::Running,
        Ok(_) | Err(rustix::io::Errno::SRCH) => Waited::Exited,
        Err(_) => poll_exit(pid, timeout_ms),
    }
}

#[cfg(target_os = "linux")]
fn wait_exit_os(pid: rustix::process::Pid, timeout_ms: u64) -> Waited {
    use rustix::event::{PollFd, PollFlags, Timespec, poll};
    use rustix::process::{PidfdFlags, pidfd_open};
    let fd = match pidfd_open(pid, PidfdFlags::empty()) {
        Ok(fd) => fd,
        Err(rustix::io::Errno::SRCH) => return Waited::Exited,
        Err(_) => return poll_exit(pid, timeout_ms),
    };
    let timeout = Timespec {
        tv_sec: i64::try_from(timeout_ms / 1000).unwrap_or(i64::MAX),
        tv_nsec: i64::try_from((timeout_ms % 1000) * 1_000_000).unwrap_or(0),
    };
    let mut fds = [PollFd::new(&fd, PollFlags::IN)];
    match poll(&mut fds, Some(&timeout)) {
        Ok(0) => Waited::Running,
        Ok(_) => Waited::Exited,
        Err(_) => poll_exit(pid, timeout_ms),
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn wait_exit_os(pid: rustix::process::Pid, timeout_ms: u64) -> Waited {
    poll_exit(pid, timeout_ms)
}

impl Pids for StdPids {
    #[expect(
        clippy::disallowed_methods,
        reason = "the real `Pids`: this process's own id is what it answers"
    )]
    fn own(&self) -> Pid {
        Pid(std::process::id())
    }

    fn wait_exit(&mut self, pid: Pid, timeout_ms: u64) -> Waited {
        raw(pid).map_or(Waited::Exited, |pid| wait_exit_os(pid, timeout_ms))
    }

    fn kill(&mut self, pid: Pid) {
        if let Some(pid) = raw(pid) {
            let _ = rustix::process::kill_process(pid, rustix::process::Signal::KILL);
        }
    }
}

#[expect(
    clippy::disallowed_methods,
    reason = "the real `Spawn` and `Exec` build the command they start here"
)]
fn command(invocation: &Invocation) -> Command {
    let mut command = Command::new(&invocation.program);
    command.args(&invocation.args);
    for (name, value) in &invocation.set {
        command.env(name, value);
    }
    for name in &invocation.unset {
        command.env_remove(name);
    }
    command
}

/// Detached starts: `via --detach <program> <arguments>…` runs as an
/// intermediate that starts the program and exits at once, so the program
/// is nobody's child. `via` is the `leanmacs` binary ([`detach`]). The
/// program's standard output and error are this process's, and its
/// standard input is closed.
#[derive(Debug, Clone)]
pub struct StdSpawn {
    /// The program whose `--detach` mode is the intermediate.
    pub via: PathBuf,
}

impl Spawn for StdSpawn {
    fn spawn_detached(&mut self, invocation: &Invocation) -> Result<Pid, String> {
        let mut intermediate = command(&Invocation {
            program: self.via.clone(),
            args: [
                OsString::from("--detach"),
                invocation.program.clone().into_os_string(),
            ]
            .into_iter()
            .chain(invocation.args.iter().cloned())
            .collect(),
            set: invocation.set.clone(),
            unset: invocation.unset.clone(),
        });
        // The intermediate's standard output carries the pid back, so this
        // process's standard output reaches it as its standard input, which
        // it hands the program as its standard output.
        let output_for_program = io::stdout()
            .as_fd()
            .try_clone_to_owned()
            .map_or_else(|_| Stdio::null(), Stdio::from);
        let output = intermediate
            .stdin(output_for_program)
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .output()
            .map_err(|e| format!("{}: {e}", self.via.display()))?;
        let text = String::from_utf8_lossy(&output.stdout);
        if !output.status.success() {
            return Err(format!(
                "{} --detach failed ({})",
                self.via.display(),
                output.status
            ));
        }
        text.trim()
            .parse::<u32>()
            .map(Pid)
            .map_err(|_| format!("{} --detach answered no pid", self.via.display()))
    }
}

/// The intermediate of [`StdSpawn`]: starts `args[0]` with the rest as its
/// arguments, its standard output this process's standard input and its
/// standard input closed, prints its pid and exits without waiting.
#[must_use]
#[expect(
    clippy::disallowed_methods,
    reason = "the detached start's intermediate is a real process that starts the program"
)]
pub fn detach(args: &[OsString]) -> ExitCode {
    let Some((program, rest)) = args.split_first() else {
        eprintln!("leanmacs: --detach needs a program");
        return ExitCode::from(2);
    };
    let output = io::stdin()
        .as_fd()
        .try_clone_to_owned()
        .map_or_else(|_| Stdio::null(), Stdio::from);
    match Command::new(program)
        .args(rest)
        .stdin(Stdio::null())
        .stdout(output)
        .stderr(Stdio::inherit())
        .spawn()
    {
        Ok(child) => {
            let mut out = io::stdout();
            if writeln!(out, "{}", child.id())
                .and_then(|()| out.flush())
                .is_err()
            {
                return ExitCode::from(1);
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!(
                "leanmacs: could not start {}: {e}",
                program.to_string_lossy()
            );
            ExitCode::from(1)
        }
    }
}

/// The exec, over `std::os::unix::process::CommandExt::exec`, with this
/// process's standard input, output and error.
#[derive(Debug, Clone, Copy, Default)]
pub struct StdExec;

impl Exec for StdExec {
    fn exec(&mut self, invocation: &Invocation) -> Refusal {
        let error = command(invocation).exec();
        let reason = format!("{}: {error}", invocation.program.display());
        if error.kind() == io::ErrorKind::NotFound {
            Refusal::NotFound(reason)
        } else {
            Refusal::Refused(reason)
        }
    }
}

/// The launcher's own path, from `std::env::current_exe`, read once, and
/// its environment, read at each ask from `std::env::var_os`.
#[derive(Debug, Clone)]
pub struct StdPlatform {
    own: PathBuf,
}

impl StdPlatform {
    /// This process's facts.
    ///
    /// # Errors
    ///
    /// When the system cannot say where this executable is.
    #[expect(
        clippy::disallowed_methods,
        reason = "the real `Platform` reads this executable's own path once, here"
    )]
    pub fn new() -> io::Result<Self> {
        Ok(Self {
            own: std::env::current_exe()?,
        })
    }
}

impl Platform for StdPlatform {
    fn own_path(&self) -> PathBuf {
        self.own.clone()
    }

    fn is_macos(&self) -> bool {
        cfg!(target_os = "macos")
    }

    #[expect(
        clippy::disallowed_methods,
        reason = "the real `Platform` reads the process's environment"
    )]
    fn var(&self, name: &str) -> Option<OsString> {
        std::env::var_os(name)
    }

    fn say(&mut self, line: &str) {
        eprintln!("{line}");
    }
}
