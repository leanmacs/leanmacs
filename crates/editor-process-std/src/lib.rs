//! The process port's real adapter: children started with `std::process`,
//! each leading a process group of its own, waited for and killed with
//! the system's calls for a group.
//!
//! [`StdProcesses`] implements `editor-process`'s [`Processes`] port, and is
//! made only by [`StdProcesses::system`]. It is for Unix: macOS and Linux.
//! Everything the editor decides about a run (which commands are refused
//! before a spawn, what a run comes to, cancelling, shutdown) is the port's
//! crate's; this crate only starts, reads, waits and kills, and maps the
//! system's errors to the port's refusals.
//!
//! # How a group is ended without signalling a reused id
//!
//! - **The spawn** puts the child in a new group whose id is its pid
//!   (`CommandExt::process_group(0)`), with standard input closed and both
//!   output streams piped. The std `Child` is dropped once its pipes are
//!   taken: dropping it neither waits nor kills, and this crate reaps the
//!   pid itself.
//! - **[`Child::wait`]** waits for the child's exit with
//!   `waitid(P_PID, pid, WEXITED | WNOWAIT)`, which leaves it unreaped, so
//!   its pid, which is also the group's id, stays the child's. Then, under
//!   the child's lock, it sends `SIGKILL` to the group, which ends any
//!   process the child left in it, reaps the child with `waitpid` and
//!   decodes its status. The exit is kept, and a later wait answers it.
//! - **[`Child::kill`]** takes the same lock and sends `SIGKILL` to the
//!   group unless the child has been reaped. So no signal is ever sent to a
//!   group id that may have been given to another process.
//!
//! A descendant that leaves the group is not reached: the port's crate docs
//! have that limit.
//!
//! # The system's errors
//!
//! A spawn's `io::Error` of kind `NotFound` is [`RefusalKind::NotFound`] (a
//! program or a directory that is not there: the system does not say
//! which), `PermissionDenied` is [`RefusalKind::Denied`], and anything else
//! is [`RefusalKind::Failed`]. The detail is
//! ``cannot start `<program>` in <directory>: <the error>``.

use std::io::{ErrorKind, Read};
use std::os::unix::process::CommandExt;
use std::process::{ChildStderr, ChildStdout, Stdio};
use std::sync::{Mutex, MutexGuard, PoisonError};

use editor_process::{Child, Command, Exit, Output, Processes, Refusal, RefusalKind, Stream};
use rustix::io::Errno;
use rustix::process::{
    Pid, Signal, WaitId, WaitIdOptions, WaitOptions, kill_process_group, waitid, waitpid,
};

/// The machine's processes. Made only by [`StdProcesses::system`].
#[derive(Debug, Clone, Copy)]
pub struct StdProcesses {
    /// Nothing: a value of this type is the permission to start processes.
    _private: (),
}

impl StdProcesses {
    /// The machine's processes. The one constructor, which the crates that
    /// must not start a process refuse in their `clippy.toml`.
    pub const fn system() -> Self {
        Self { _private: () }
    }
}

/// The refusal for an `io::Error` the spawn of `command` gave.
fn refusal(error: &std::io::Error, command: &Command) -> Refusal {
    let kind = match error.kind() {
        ErrorKind::NotFound => RefusalKind::NotFound,
        ErrorKind::PermissionDenied => RefusalKind::Denied,
        _ => RefusalKind::Failed,
    };
    Refusal::new(
        kind,
        format!(
            "cannot start `{}` in {}: {error}",
            command.program,
            command.directory.display()
        ),
    )
}

impl Processes for StdProcesses {
    type Child = StdChild;

    fn spawn(&self, command: &Command) -> Result<StdChild, Refusal> {
        let mut std_command = std::process::Command::new(&command.program);
        std_command
            .args(&command.arguments)
            .current_dir(&command.directory);
        let environment = &command.environment;
        if environment.clear {
            std_command.env_clear();
        }
        for name in &environment.unset {
            std_command.env_remove(name);
        }
        for (name, value) in &environment.set {
            std_command.env(name, value);
        }
        std_command
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0);
        let mut child = std_command
            .spawn()
            .map_err(|error| refusal(&error, command))?;
        let pid = child.id();
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        // Dropping the std child neither waits nor kills: the pid is reaped
        // here, by `wait`.
        drop(child);
        let Some(raw) = i32::try_from(pid).ok().and_then(Pid::from_raw) else {
            return Err(Refusal::new(
                RefusalKind::Failed,
                format!("the child of `{}` has no pid: {pid}", command.program),
            ));
        };
        Ok(StdChild {
            pid: raw,
            exit: Mutex::new(None),
            stdout,
            stderr,
        })
    }
}

/// A child [`StdProcesses`] started.
#[derive(Debug)]
pub struct StdChild {
    /// Its pid, which is also its group's id.
    pid: Pid,
    /// How it ended, once it has been reaped. Its lock is what keeps a kill
    /// from signalling a group whose id may have been reused.
    exit: Mutex<Option<Exit>>,
    /// Its standard output, until taken.
    stdout: Option<ChildStdout>,
    /// Its standard error, until taken.
    stderr: Option<ChildStderr>,
}

impl StdChild {
    /// Locks what the child's exit is. The lock is never held while other
    /// code runs, so a poisoned lock still guards a consistent value.
    fn exit(&self) -> MutexGuard<'_, Option<Exit>> {
        self.exit.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Sends `SIGKILL` to the group. A group with no process left in it is
    /// nothing to end.
    fn kill_group(&self) {
        // `ESRCH` is a group with no process left, which is ended already.
        kill_process_group(self.pid, Signal::KILL).ok();
    }
}

impl Child for StdChild {
    type Output = StdOutput;

    fn id(&self) -> u32 {
        self.pid.as_raw_nonzero().get().unsigned_abs()
    }

    fn take_output(&mut self, stream: Stream) -> Option<StdOutput> {
        match stream {
            Stream::Out => self.stdout.take().map(StdOutput::Out),
            Stream::Err => self.stderr.take().map(StdOutput::Err),
        }
    }

    fn wait(&self) -> Exit {
        if let Some(exit) = *self.exit() {
            return exit;
        }
        // Wait for the exit without reaping: the pid stays the child's.
        while waitid(
            WaitId::Pid(self.pid),
            WaitIdOptions::EXITED | WaitIdOptions::NOWAIT,
        )
        .is_err_and(|error| error == Errno::INTR)
        {}
        let mut exit = self.exit();
        if let Some(exit) = *exit {
            return exit;
        }
        self.kill_group();
        let status = loop {
            match waitpid(Some(self.pid), WaitOptions::empty()) {
                Err(Errno::INTR) => {}
                Ok(Some((_, status))) => break Some(status),
                Ok(None) | Err(_) => break None,
            }
        };
        let ended = match status {
            Some(status) => match (status.exit_status(), status.terminating_signal()) {
                (Some(code), _) => Exit::Code(code),
                (None, Some(signal)) => Exit::Signal(signal),
                (None, None) => Exit::Signal(Signal::KILL.as_raw()),
            },
            // Reaped by someone else, or not ours to reap: it has ended, and
            // how is not known.
            None => Exit::Signal(Signal::KILL.as_raw()),
        };
        *exit = Some(ended);
        ended
    }

    fn kill(&self) {
        let exit = self.exit();
        if exit.is_none() {
            self.kill_group();
        }
    }
}

/// One of a child's output streams.
#[derive(Debug)]
pub enum StdOutput {
    /// Its standard output.
    Out(ChildStdout),
    /// Its standard error.
    Err(ChildStderr),
}

impl Output for StdOutput {
    fn read(&mut self, buffer: &mut [u8]) -> Result<usize, Refusal> {
        loop {
            let read = match self {
                Self::Out(stream) => stream.read(buffer),
                Self::Err(stream) => stream.read(buffer),
            };
            match read {
                Err(error) if error.kind() == ErrorKind::Interrupted => {}
                Ok(count) => return Ok(count),
                Err(error) => {
                    return Err(Refusal::new(
                        RefusalKind::Failed,
                        format!("cannot read a child's stream: {error}"),
                    ));
                }
            }
        }
    }
}
