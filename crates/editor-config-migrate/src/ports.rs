//! The port config conversion reaches the files of a config directory
//! through ([`Files`]).

use std::error::Error;
use std::ffi::OsString;
use std::fmt;
use std::path::{Path, PathBuf};

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

/// What is at a path, a link followed, as `test -e`, `-f` and `-d` see it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// Nothing: no entry, or a link to nothing.
    Nothing,
    /// A regular file.
    File,
    /// A directory.
    Directory,
    /// Something else: a device, a socket, a pipe.
    Other,
}

/// Port: the files of a config directory. Every path is absolute.
pub trait Files {
    /// What is at `path`, a link followed.
    ///
    /// # Errors
    ///
    /// The system's reason when it cannot tell; nothing there is
    /// [`Kind::Nothing`], not an error.
    fn kind(&self, path: &Path) -> Result<Kind, FilesError>;
    /// The name of every entry of the directory `dir`, hidden ones too, as
    /// `ls -a` lists them but `.` and `..`, sorted by their bytes.
    ///
    /// # Errors
    ///
    /// The system's reason, as when `dir` is not a directory.
    fn names(&self, dir: &Path) -> Result<Vec<OsString>, FilesError>;
    /// The bytes of the file at `path`.
    ///
    /// # Errors
    ///
    /// The system's reason, as when nothing is there.
    fn read(&self, path: &Path) -> Result<Vec<u8>, FilesError>;
    /// Writes `bytes` as the file at `path`, replacing a file there. Its
    /// directory must be there.
    ///
    /// # Errors
    ///
    /// The system's reason, as when the directory is not there.
    fn write(&mut self, path: &Path, bytes: &[u8]) -> Result<(), FilesError>;
    /// Makes the directory `path` and every directory above it; one that is
    /// there already is no error.
    ///
    /// # Errors
    ///
    /// The system's reason, as when a file is in the way.
    fn make_dir(&mut self, path: &Path) -> Result<(), FilesError>;
    /// Removes the file at `path`.
    ///
    /// # Errors
    ///
    /// The system's reason, as when nothing is there.
    fn remove(&mut self, path: &Path) -> Result<(), FilesError>;
    /// Moves the file at `from` to `to`, replacing a file there.
    ///
    /// # Errors
    ///
    /// The system's reason, as when nothing is at `from`.
    fn rename(&mut self, from: &Path, to: &Path) -> Result<(), FilesError>;
}
