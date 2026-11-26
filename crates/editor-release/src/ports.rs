//! The ports release tooling reaches the world through: the environment
//! ([`Env`]), running a program ([`Process`]) and the files of a build and
//! a bundle ([`Files`]).

use std::error::Error;
use std::ffi::{OsStr, OsString};
use std::fmt;
use std::path::{Path, PathBuf};

/// A program to run, with every argument the core chose for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Invocation {
    /// The program, found on `PATH` unless it is a path.
    pub program: OsString,
    /// Its arguments, in order.
    pub args: Vec<OsString>,
    /// Whether the core reads the program's standard output. Otherwise the
    /// output goes to the tool's own.
    pub captured: bool,
}

impl Invocation {
    /// A program with no arguments, whose output goes to the tool's own.
    pub fn new(program: impl Into<OsString>) -> Self {
        Self {
            program: program.into(),
            args: Vec::new(),
            captured: false,
        }
    }

    /// Adds one argument.
    #[must_use]
    pub fn arg(mut self, arg: impl AsRef<OsStr>) -> Self {
        self.args.push(arg.as_ref().to_owned());
        self
    }

    /// Adds several arguments.
    #[must_use]
    pub fn args<I, A>(mut self, args: I) -> Self
    where
        I: IntoIterator<Item = A>,
        A: AsRef<OsStr>,
    {
        self.args
            .extend(args.into_iter().map(|a| a.as_ref().to_owned()));
        self
    }

    /// Captures the program's standard output for the core to read.
    #[must_use]
    pub fn captured(mut self) -> Self {
        self.captured = true;
        self
    }
}

/// The command line, as an error message shows it: the program and each
/// argument, separated by spaces, with no quoting.
impl fmt::Display for Invocation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.program.to_string_lossy())?;
        for arg in &self.args {
            write!(f, " {}", arg.to_string_lossy())?;
        }
        Ok(())
    }
}

/// Why a program could not be run to success.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RunError {
    /// It could not be started (not found, not executable), with the
    /// system's reason.
    Start(String),
    /// It ran and exited unsuccessfully: with this exit code, or with none
    /// when a signal ended it.
    Failed(Option<i32>),
    /// Its captured output is not UTF-8 ([`text`]).
    NotUtf8,
}

impl fmt::Display for RunError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Start(reason) => write!(f, "could not start it: {reason}"),
            Self::Failed(Some(code)) => write!(f, "it exited with code {code}"),
            Self::Failed(None) => f.write_str("a signal ended it"),
            Self::NotUtf8 => f.write_str("its output is not UTF-8"),
        }
    }
}

impl Error for RunError {}

/// Port: runs a program to completion.
pub trait Process {
    /// Runs `invocation`, waiting for it to exit. Returns its standard
    /// output when `invocation.captured` is set, and nothing otherwise. A
    /// program that exits unsuccessfully is [`RunError::Failed`], and one
    /// that cannot be started [`RunError::Start`].
    ///
    /// # Errors
    ///
    /// As above.
    fn run(&mut self, invocation: &Invocation) -> Result<Vec<u8>, RunError>;
}

/// Port: the environment variables a build is named from.
pub trait Env {
    /// The variable's value, or `None` when it is unset.
    fn var(&self, name: &str) -> Option<OsString>;
}

/// Why the file system refused an operation, naming the path it refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FilesError {
    /// The path the operation was on.
    pub path: PathBuf,
    /// The system's reason, or the fake's.
    pub reason: String,
}

impl FilesError {
    /// The error at `path`, for `reason`.
    pub fn new(path: &Path, reason: impl Into<String>) -> Self {
        Self {
            path: path.to_owned(),
            reason: reason.into(),
        }
    }
}

impl fmt::Display for FilesError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.path.display(), self.reason)
    }
}

impl Error for FilesError {}

/// What is at a path, a link followed to what it names, as `test -e` and
/// `test -f` see it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// Nothing: no entry, or a link to nothing.
    Nothing,
    /// A regular file, and whether any of its executable bits is set.
    File {
        /// Whether any of its executable bits is set.
        executable: bool,
    },
    /// A directory.
    Directory,
    /// Something else: a device, a socket, a pipe.
    Other,
}

/// What an entry of a directory is, a link not followed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntryKind {
    /// A regular file, and whether any of its executable bits is set.
    File {
        /// Whether any of its executable bits is set.
        executable: bool,
    },
    /// A directory.
    Directory,
    /// A symbolic link, whose target [`Files::read_link`] reads.
    Link,
    /// Something else: a device, a socket, a pipe.
    Other,
}

/// One entry of a directory: its name and what it is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// The entry's name in its directory.
    pub name: OsString,
    /// What it is, a link not followed.
    pub kind: EntryKind,
}

/// Port: the files a release tool reads and lays out. Every path is
/// absolute.
pub trait Files {
    /// What is at `path`, a link followed.
    ///
    /// # Errors
    ///
    /// The system's reason when it cannot tell, such as a path it may not
    /// search; nothing there is [`Kind::Nothing`], not an error.
    fn kind(&self, path: &Path) -> Result<Kind, FilesError>;
    /// The entries of the directory `dir`, `.` and `..` left out, sorted by
    /// the bytes of their names, each with its kind, a link not followed.
    ///
    /// # Errors
    ///
    /// The system's reason, as when `dir` is not a directory.
    fn entries(&self, dir: &Path) -> Result<Vec<Entry>, FilesError>;
    /// The target text of the link at `path`.
    ///
    /// # Errors
    ///
    /// The system's reason, as when `path` is not a link.
    fn read_link(&self, path: &Path) -> Result<PathBuf, FilesError>;
    /// The bytes of the file at `path`, a link followed.
    ///
    /// # Errors
    ///
    /// The system's reason, as when nothing is there.
    fn read(&self, path: &Path) -> Result<Vec<u8>, FilesError>;
    /// Writes `bytes` as the file at `path`, replacing a file there, with
    /// its executable bits set or not. Its directory must be there.
    ///
    /// # Errors
    ///
    /// The system's reason, as when the directory is not there.
    fn write(&mut self, path: &Path, bytes: &[u8], executable: bool) -> Result<(), FilesError>;
    /// Makes the directory `path` and every directory above it; one that is
    /// there already is no error.
    ///
    /// # Errors
    ///
    /// The system's reason, as when a file is in the way.
    fn make_dir(&mut self, path: &Path) -> Result<(), FilesError>;
    /// Copies the file at `from`, a link followed, to `to`, replacing a file
    /// there: its bytes and its executable bits, cloned where the file
    /// system can. The directory of `to` must be there.
    ///
    /// # Errors
    ///
    /// The system's reason, as when `from` is not a file.
    fn copy(&mut self, from: &Path, to: &Path) -> Result<(), FilesError>;
    /// Makes a symbolic link at `link` whose target text is `target`.
    /// Nothing may be at `link` already.
    ///
    /// # Errors
    ///
    /// The system's reason, as when something is at `link`.
    fn symlink(&mut self, target: &Path, link: &Path) -> Result<(), FilesError>;
}

/// Runs `invocation` and reads its captured output as UTF-8.
///
/// # Errors
///
/// The run's error, or [`RunError::NotUtf8`].
pub fn text(process: &mut impl Process, invocation: &Invocation) -> Result<String, RunError> {
    String::from_utf8(process.run(invocation)?).map_err(|_| RunError::NotUtf8)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake::RecordingProcess;

    #[test]
    fn an_invocation_shows_as_its_command_line() {
        let invocation = Invocation::new("git")
            .arg("-C")
            .arg("/work/leanmacs")
            .args(["show", "-s"])
            .captured();
        assert_eq!(invocation.to_string(), "git -C /work/leanmacs show -s");
        assert!(invocation.captured);
        assert!(!Invocation::new("true").captured);
    }

    #[test]
    fn each_run_error_says_what_happened() {
        assert_eq!(
            RunError::Start("No such file or directory".into()).to_string(),
            "could not start it: No such file or directory"
        );
        assert_eq!(
            RunError::Failed(Some(128)).to_string(),
            "it exited with code 128"
        );
        assert_eq!(RunError::Failed(None).to_string(), "a signal ended it");
        assert_eq!(RunError::NotUtf8.to_string(), "its output is not UTF-8");
    }

    #[test]
    fn text_reads_utf8_and_refuses_anything_else() {
        let mut process = RecordingProcess::new(|i: &Invocation| {
            Ok(if i.program == "good" {
                "héllo\n".into()
            } else {
                vec![0xff]
            })
        });
        assert_eq!(
            text(&mut process, &Invocation::new("good").captured()),
            Ok("héllo\n".to_owned())
        );
        assert_eq!(
            text(&mut process, &Invocation::new("bad").captured()),
            Err(RunError::NotUtf8)
        );
    }
}
