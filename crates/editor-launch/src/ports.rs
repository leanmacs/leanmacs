//! The ports the launcher's core reaches the world through: files
//! ([`Files`]), the time ([`Clock`]), other processes by their id
//! ([`Pids`]), starting a process that is nobody's child ([`Spawn`]),
//! replacing this process ([`Exec`]) and the launcher's own facts and
//! environment ([`Platform`]). [`World`] lends one of each to the core for
//! a call.

use std::ffi::OsString;
use std::fmt;
use std::path::{Path, PathBuf};

/// A process id, in the core's own terms.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Pid(pub u32);

impl fmt::Display for Pid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// A program to start, with every argument and every change to the
/// environment the core chose for it. Everything else of the environment
/// is the launcher's own.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Invocation {
    /// The program: a path, or a name found on `PATH`.
    pub program: PathBuf,
    /// Its arguments, in order, without the program.
    pub args: Vec<OsString>,
    /// Variables set, in order.
    pub set: Vec<(OsString, OsString)>,
    /// Variables removed.
    pub unset: Vec<OsString>,
}

impl Invocation {
    /// `program` with no argument and the launcher's environment.
    pub fn new(program: impl Into<PathBuf>) -> Self {
        Self {
            program: program.into(),
            ..Self::default()
        }
    }

    /// Adds one argument.
    #[must_use]
    pub fn arg(mut self, arg: impl Into<OsString>) -> Self {
        self.args.push(arg.into());
        self
    }

    /// Adds several arguments.
    #[must_use]
    pub fn args<I, A>(mut self, args: I) -> Self
    where
        I: IntoIterator<Item = A>,
        A: Into<OsString>,
    {
        self.args.extend(args.into_iter().map(Into::into));
        self
    }

    /// Sets one variable.
    #[must_use]
    pub fn set(mut self, name: impl Into<OsString>, value: impl Into<OsString>) -> Self {
        self.set.push((name.into(), value.into()));
        self
    }

    /// Removes one variable.
    #[must_use]
    pub fn unset(mut self, name: impl Into<OsString>) -> Self {
        self.unset.push(name.into());
        self
    }
}

/// Why an exec did not replace the process. An exec that succeeds never
/// answers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// Nothing is at the program's path, with the system's reason.
    NotFound(String),
    /// The system refused the program (not executable, a bad format, a
    /// signature), with its reason.
    Refused(String),
    /// The fake's answer ([`crate::fake::FakeExec`]): the exec is recorded
    /// and the core stops there, as if it had replaced the process. A real
    /// adapter never answers it.
    Faked,
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotFound(reason) | Self::Refused(reason) => f.write_str(reason),
            Self::Faked => f.write_str("faked"),
        }
    }
}

/// Why a file could not be read or changed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileError {
    /// Nothing is at the path.
    NotFound,
    /// Any other failure, with the system's reason.
    Other(String),
}

impl fmt::Display for FileError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotFound => f.write_str("no such file"),
            Self::Other(reason) => f.write_str(reason),
        }
    }
}

/// Port: files by path.
pub trait Files {
    /// The file's bytes.
    ///
    /// # Errors
    ///
    /// [`FileError::NotFound`] when nothing is there.
    fn read(&self, path: &Path) -> Result<Vec<u8>, FileError>;
    /// Replaces the file's bytes so that a reader sees the old bytes or the
    /// new ones, never a part. Its directory must be there already
    /// ([`Files::make_dir_all`]).
    ///
    /// # Errors
    ///
    /// The system's reason, and [`FileError::NotFound`] when the file's
    /// directory is not there.
    fn write_atomic(&mut self, path: &Path, bytes: &[u8]) -> Result<(), FileError>;
    /// Moves `from` to `to`, replacing what is there.
    ///
    /// # Errors
    ///
    /// [`FileError::NotFound`] when nothing is at `from`.
    fn rename(&mut self, from: &Path, to: &Path) -> Result<(), FileError>;
    /// Removes the file; nothing there is no error.
    ///
    /// # Errors
    ///
    /// The system's reason.
    fn remove(&mut self, path: &Path) -> Result<(), FileError>;
    /// Whether anything is at the path, a file or a directory.
    fn exists(&self, path: &Path) -> bool;
    /// The names of the entries of the directory `dir`, files and
    /// directories alike, each once, in no particular order; not `.` or
    /// `..`.
    ///
    /// # Errors
    ///
    /// [`FileError::NotFound`] when no directory is at `dir`, and the
    /// system's reason for anything else, a file at `dir` among them.
    fn list(&self, dir: &Path) -> Result<Vec<OsString>, FileError>;
    /// Makes the directory `dir` and each of its parents that is missing;
    /// a directory already there is no error.
    ///
    /// # Errors
    ///
    /// The system's reason, a file in the way among them.
    fn make_dir_all(&mut self, dir: &Path) -> Result<(), FileError>;
}

/// Port: the time, in milliseconds from an arbitrary start.
pub trait Clock {
    /// The time now; it never goes back.
    fn now_ms(&self) -> u64;
    /// Waits `ms`.
    fn sleep_ms(&mut self, ms: u64);
}

/// What [`Pids::wait_exit`] saw.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Waited {
    /// The process has ended, or there is no such process.
    Exited,
    /// It was still running when the time ran out.
    Running,
}

/// Port: processes by their id, whether or not they are the caller's
/// children.
pub trait Pids {
    /// This process's id.
    fn own(&self) -> Pid;
    /// Waits up to `timeout_ms` for `pid` to end.
    fn wait_exit(&mut self, pid: Pid, timeout_ms: u64) -> Waited;
    /// Ends `pid` at once (`SIGKILL`). A process that has already ended is
    /// no error.
    fn kill(&mut self, pid: Pid);
}

/// Port: starting a process that is nobody's child.
pub trait Spawn {
    /// Starts `invocation` so that its parent is not this process and it
    /// outlives this process; its standard error and output are this
    /// process's. Answers its pid.
    ///
    /// # Errors
    ///
    /// The system's reason when it could not be started.
    fn spawn_detached(&mut self, invocation: &Invocation) -> Result<Pid, String>;
}

/// Port: replacing this process with another program, keeping its id.
pub trait Exec {
    /// Execs `invocation`. It answers only when the exec failed, and this
    /// process then carries on.
    fn exec(&mut self, invocation: &Invocation) -> Refusal;
}

/// Port: the launcher's own facts, its environment and its voice.
pub trait Platform {
    /// The launcher's own executable.
    fn own_path(&self) -> PathBuf;
    /// Whether this is macOS, where every exec points CoreFoundation at
    /// the bundle (`CFProcessPath`).
    fn is_macos(&self) -> bool;
    /// The launcher's environment variable `name`: `None` when it is not
    /// set, and its value, empty or not, when it is.
    fn var(&self, name: &str) -> Option<OsString>;
    /// Says one line on standard error.
    fn say(&mut self, line: &str);
}

/// One of each port, lent to the core for a call.
pub struct World<'a> {
    /// Files.
    pub files: &'a mut dyn Files,
    /// The time.
    pub clock: &'a mut dyn Clock,
    /// Processes by id.
    pub pids: &'a mut dyn Pids,
    /// Detached starts.
    pub spawn: &'a mut dyn Spawn,
    /// The exec.
    pub exec: &'a mut dyn Exec,
    /// The launcher's own facts.
    pub platform: &'a mut dyn Platform,
}

/// How a run of the core ended, when it did not exec.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// Exit with this status.
    Exit(u8),
    /// The fake's exec was reached ([`Refusal::Faked`]); a real run never
    /// answers it, since the exec replaced the process.
    Execed,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_invocation_is_built_up_in_order() {
        let invocation = Invocation::new("/bin/editor")
            .arg("--a")
            .args(["b", "c"])
            .set("X", "1")
            .unset("Y");
        assert_eq!(invocation.program, PathBuf::from("/bin/editor"));
        assert_eq!(invocation.args, ["--a", "b", "c"]);
        assert_eq!(invocation.set, [("X".into(), "1".into())]);
        assert_eq!(invocation.unset, ["Y"]);
    }

    #[test]
    fn a_refusal_and_a_file_error_say_their_reason() {
        assert_eq!(Refusal::NotFound("gone".into()).to_string(), "gone");
        assert_eq!(Refusal::Refused("bad".into()).to_string(), "bad");
        assert_eq!(FileError::NotFound.to_string(), "no such file");
        assert_eq!(Pid(7).to_string(), "7");
    }
}
