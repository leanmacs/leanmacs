//! The file port: what the crate needs of a file system, in its own terms.
//!
//! [`Fs`] is the one way the crate reaches a file. The crate defines it,
//! publishes a fake of it ([`FakeFs`]) and the contract every
//! implementation keeps ([`contract::check`]); the real adapter, over
//! `std::fs`, is another crate (`editor-fs-std`). Paths are
//! [`std::path::Path`]s and bytes are bytes; nothing here names `std::fs`
//! or `std::io`, and the crate's `clippy.toml` keeps it so.
//!
//! # The rules of the port
//!
//! - **[`Fs::stat`]** says what is at a path, following links: `None` when
//!   nothing is, which is not an error. **All time and metadata reach the
//!   crate through this method**: the crate reads no clock.
//! - **[`Fs::read`]** gives the bytes of the file at a path, whole,
//!   following links. A directory is refused as
//!   [`FsErrorKind::NotAFile`], and nothing as [`FsErrorKind::NotFound`].
//! - **[`Fs::write`]** makes a *new* file holding the pieces it is given,
//!   joined, with the permissions given (exactly, whatever the process's
//!   mask) or the platform's default for a new file, and has it on disk
//!   before it returns. It is refused as [`FsErrorKind::Exists`], changing
//!   nothing, when anything is at the path, a link included, whatever the
//!   link names. It takes pieces so that a caller hands over a rope's
//!   pieces and never a copy of the text.
//! - **[`Fs::append`]** adds the pieces it is given, joined, to the end of
//!   the file at a path, and makes the file, with the platform's default
//!   permissions, when nothing is there. A directory at the path, and a
//!   file on the way to it, are refused as [`FsErrorKind::NotAFile`]; a
//!   directory on the way that is not there as [`FsErrorKind::NotFound`].
//!   The bytes are handed to the system before it returns, and **are not
//!   synced**: an append is for a record that is added to often, such as a
//!   log, where a crash may lose the last of it.
//! - **[`Fs::rename`]** puts the file at one path in place of whatever
//!   file is at another, in one step, with its permissions and **with its
//!   stamp**: the modification time and the size its stat said before the
//!   rename are what its stat says after it. Afterwards the first path
//!   holds nothing.
//! - **[`Fs::remove`]** removes the file at a path.
//! - **[`Fs::resolve`]** gives the path of what a path names once every
//!   link in it is followed, and is refused as [`FsErrorKind::NotFound`]
//!   when nothing is there, which a link that names nothing is.
//! - **[`Fs::read_link`]** gives the path the link at a path holds, as the
//!   link holds it and following nothing, whether the link names something
//!   or nothing; and none for what is no link, nothing included. It is how
//!   a caller finds the file a link to nothing names, which `resolve`
//!   cannot say.
//! - **[`Fs::list`]** gives what the directory at a path holds, one
//!   [`Entry`] per name, with `.` and `..` left out. Each entry's kind is
//!   taken with links followed, and a link that names nothing is
//!   [`Kind::Other`]. The order is not specified. A link to a directory is
//!   listed as the directory. It is refused as [`FsErrorKind::NotFound`]
//!   when nothing is at the path, as [`FsErrorKind::NotAFile`] when what is
//!   there is not a directory, and as [`FsErrorKind::Denied`] when the
//!   system does not allow it.
//! - **[`Fs::make_directory`]** makes the directory at a path and every
//!   directory on the way to it that is not there. A directory already
//!   there is no error. It is refused as [`FsErrorKind::NotAFile`] when a
//!   file, or anything else that is not a directory, is at the path or on
//!   the way to it, and as [`FsErrorKind::Denied`] when the system does
//!   not allow it.
//! - **An error is a kind and a detail** ([`FsError`]). The kind is what
//!   the crate decides on; the detail is the platform's words, for a
//!   person.
//!
//! The port has no way to make a directory, a link or anything that is not
//! a file, to set a modification time, or to change a file's permissions:
//! the crate needs none of them. The contract needs some of them done, so
//! it takes them from its caller ([`contract::Ground`]).
//!
//! # Where an addition goes
//!
//! | Addition | Where | Pinned by |
//! |---|---|---|
//! | Another thing the crate needs of a file system | A method of [`Fs`], in the crate's terms, with its rule in the list above | Its rule in [`contract::check`], with a fake written to break it in the contract's tests, and the fake's own tests |
//! | Another fact about a file | A field of [`Stat`] | The same |
//! | Another fact a listing gives of each thing a directory holds | A field of [`Entry`] | The contract's listing rule, with a fake written to break it |
//! | Another failure the crate decides on | A variant of [`FsErrorKind`] | The rule of the contract that asks for it |
//! | Another way for a test to set the file system up, or to make it fail | A method of [`FakeFs`] | The fake's tests in `fs/fake.rs` |
//!
//! # What an adapter's tests are
//!
//! An adapter's crate runs [`contract::check`] in a place it owns (the
//! `std::fs` adapter, in a temporary directory its test makes), with a
//! [`contract::Ground`] that sets and reads the truth by its own means, and
//! tests what is its own, such as how it names the system's errors. **It
//! does not run this crate's loading and saving.** What a load and a save
//! do is this crate's rule, pinned here on the fake. A rule the contract
//! does not state yet is added to the contract, with its broken fake; it is
//! not tested through the logic from an adapter's crate.
//!
//! One test runs the real logic over a real adapter: a wiring test in the
//! crate that links the two, `editor-ffi` (its `tests/files.rs`). It
//! asserts only that the bytes that went in are the bytes that came out.

use std::borrow::Cow;
use std::error::Error;
use std::ffi::OsString;
use std::fmt;
use std::path::{Path, PathBuf};

pub mod contract;
mod fake;

pub use fake::{Call, FakeFs, FakeGround, Op};

/// The pieces a file is written from, in order ([`Fs::write`]), or added
/// to its end ([`Fs::append`]). Joined, they are the bytes written. A piece
/// may be empty.
pub type Pieces<'a> = dyn Iterator<Item = Cow<'a, [u8]>> + 'a;

/// A file system, as far as the crate needs one. The module docs have the
/// rules; [`contract::check`] holds an implementation to them.
///
/// It is `Send + Sync`: the thread that loads and saves is not the one that
/// made it.
pub trait Fs: Send + Sync {
    /// What is at `path`, following links. `None` when nothing is, a link
    /// that names nothing included.
    fn stat(&self, path: &Path) -> Result<Option<Stat>, FsError>;

    /// The bytes of the file at `path`, whole, following links. Refused as
    /// [`FsErrorKind::NotFound`] when nothing is there and as
    /// [`FsErrorKind::NotAFile`] for a directory.
    fn read(&self, path: &Path) -> Result<Vec<u8>, FsError>;

    /// Makes a new file at `path` holding `pieces` joined, and has it on
    /// disk before it returns. With `permissions`, the file has exactly
    /// those, whatever the process's mask; with none, the platform's
    /// default for a new file.
    ///
    /// Refused as [`FsErrorKind::Exists`], changing nothing, when anything
    /// is at `path`: a file, a directory, or a link, whether the link names
    /// something or nothing. Refused as [`FsErrorKind::NotFound`] when the
    /// directory `path` is in is not there.
    ///
    /// A write that fails partway may leave a file holding part of the
    /// pieces; taking it away is the caller's ([`Fs::remove`]).
    fn write(
        &self,
        path: &Path,
        pieces: &mut Pieces<'_>,
        permissions: Option<Permissions>,
    ) -> Result<(), FsError>;

    /// Adds `pieces`, joined, to the end of the file at `path`, and makes
    /// the file, with the platform's default permissions, when nothing is
    /// there. The bytes are handed to the system before it returns, and are
    /// not synced.
    ///
    /// Refused as [`FsErrorKind::NotAFile`] when what is at `path` is a
    /// directory, or a file is on the way to it, and as
    /// [`FsErrorKind::NotFound`] when the directory `path` is in is not
    /// there.
    ///
    /// An append that fails partway may leave part of the pieces added.
    fn append(&self, path: &Path, pieces: &mut Pieces<'_>) -> Result<(), FsError>;

    /// Puts the file at `from` in place of whatever file is at `to`, in one
    /// step: at every moment `to` holds the old file whole or the new one
    /// whole. The file keeps its permissions, its modification time and its
    /// size, so the stat of `to` afterwards says of them what the stat of
    /// `from` said before; and afterwards `from` holds nothing. Refused as
    /// [`FsErrorKind::NotFound`], changing nothing, when nothing is at
    /// `from`.
    fn rename(&self, from: &Path, to: &Path) -> Result<(), FsError>;

    /// Removes the file at `path`. Refused as [`FsErrorKind::NotFound`]
    /// when nothing is there.
    fn remove(&self, path: &Path) -> Result<(), FsError>;

    /// The path of what `path` names once every link in it is followed. A
    /// file that is no link resolves to itself, when the directory it is in
    /// is reached through no link. Refused as [`FsErrorKind::NotFound`]
    /// when nothing is there, a link that names nothing included.
    fn resolve(&self, path: &Path) -> Result<PathBuf, FsError>;

    /// The path the link at `path` holds: what the link names, as it is
    /// written in the link, so a path that is not absolute is to be read
    /// from the directory the link is in. Nothing is followed: the link may
    /// name a file, another link, or nothing. `None` when what is at `path`
    /// is not a link, and when nothing is there.
    fn read_link(&self, path: &Path) -> Result<Option<PathBuf>, FsError>;

    /// What the directory at `path` holds, one entry per name, `.` and
    /// `..` left out, in no particular order. Each kind is taken with links
    /// followed, and a link that names nothing is [`Kind::Other`]. Refused
    /// as [`FsErrorKind::NotFound`] when nothing is there, as
    /// [`FsErrorKind::NotAFile`] when what is there is not a directory, and
    /// as [`FsErrorKind::Denied`] when the system does not allow it.
    fn list(&self, path: &Path) -> Result<Vec<Entry>, FsError>;

    /// Makes the directory at `path` and every directory on the way to it
    /// that is not there. A directory already at `path` is no error.
    /// Refused as [`FsErrorKind::NotAFile`] when what is at `path`, or at
    /// a path on the way to it, is not a directory, and as
    /// [`FsErrorKind::Denied`] when the system does not allow it.
    fn make_directory(&self, path: &Path) -> Result<(), FsError>;
}

/// One thing a directory holds ([`Fs::list`]): its name in the directory
/// and its kind, links followed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// Its name in the directory, which may not be UTF-8.
    pub name: OsString,
    /// What kind of thing it is, links followed; a link to nothing is
    /// [`Kind::Other`].
    pub kind: Kind,
}

/// What is at a path ([`Fs::stat`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Stat {
    /// What kind of thing it is.
    pub kind: Kind,
    /// Its length in bytes. Meaningful for a file.
    pub size: u64,
    /// When it was last modified.
    pub modified: Modified,
    /// Its permissions.
    pub permissions: Permissions,
}

/// What kind of thing is at a path.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// A file, which can be read.
    File,
    /// A directory.
    Directory,
    /// Anything else: a pipe, a socket, a device.
    Other,
}

/// An instant a file was modified at, as the file system keeps it: seconds
/// and nanoseconds since the Unix epoch. The seconds are negative for an
/// instant before it. Two are compared for equality and never ordered by
/// the crate: a file put back from a backup is older and has still changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Modified {
    /// Whole seconds since the Unix epoch.
    pub seconds: i64,
    /// The nanoseconds past that second, below a thousand million.
    pub nanoseconds: u32,
}

/// The permissions of a file: the nine bits that say who may read, write
/// and execute it, as Unix writes them (`0o644`). The set-user-id,
/// set-group-id and sticky bits are not part of it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Permissions(u32);

impl Permissions {
    /// The permissions `mode` holds: its lowest nine bits. Anything above
    /// them is dropped.
    pub const fn new(mode: u32) -> Self {
        Self(mode & 0o777)
    }

    /// The nine bits.
    pub const fn bits(self) -> u32 {
        self.0
    }
}

/// Octal, as Unix writes a mode: `0o644`.
impl fmt::Display for Permissions {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:#o}", self.0)
    }
}

/// Why a file system refused, as far as the crate decides on it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FsErrorKind {
    /// Nothing is at the path, or at a directory on the way to it.
    NotFound,
    /// The file system does not allow it.
    Denied,
    /// Something is at the path already.
    Exists,
    /// What is there is not a file, or a directory on the way to it is not
    /// a directory. For a listing ([`Fs::list`]), what is there is not a
    /// directory; for a directory made ([`Fs::make_directory`]), what is
    /// there or on the way to it is not a directory.
    NotAFile,
    /// Anything else. The detail says what.
    Other,
}

/// A refusal by a file system: a kind the crate decides on, and the
/// platform's words for a person.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FsError {
    /// What the crate decides on.
    pub kind: FsErrorKind,
    /// The platform's own description, which may be empty.
    pub detail: String,
}

impl FsError {
    /// A refusal of `kind`, with the platform's words `detail`.
    pub fn new(kind: FsErrorKind, detail: impl Into<String>) -> Self {
        Self {
            kind,
            detail: detail.into(),
        }
    }
}

/// The kind in the port's words, then the detail when there is one.
impl fmt::Display for FsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self.kind {
            FsErrorKind::NotFound => "nothing is there",
            FsErrorKind::Denied => "it is not allowed",
            FsErrorKind::Exists => "something is there already",
            FsErrorKind::NotAFile => "what is there is not a file",
            FsErrorKind::Other => "the file system failed",
        })?;
        if self.detail.is_empty() {
            Ok(())
        } else {
            write!(f, ": {}", self.detail)
        }
    }
}

impl Error for FsError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_file_system_error_says_its_kind_and_its_detail() {
        let said = |kind| FsError::new(kind, "os error 7").to_string();

        assert_eq!(said(FsErrorKind::NotFound), "nothing is there: os error 7");
        assert_eq!(said(FsErrorKind::Denied), "it is not allowed: os error 7");
        assert_eq!(
            said(FsErrorKind::Exists),
            "something is there already: os error 7"
        );
        assert_eq!(
            said(FsErrorKind::NotAFile),
            "what is there is not a file: os error 7"
        );
        assert_eq!(
            said(FsErrorKind::Other),
            "the file system failed: os error 7"
        );
    }

    #[test]
    fn a_file_system_error_with_no_detail_says_its_kind_alone() {
        assert_eq!(
            FsError::new(FsErrorKind::NotFound, "").to_string(),
            "nothing is there"
        );
    }

    #[test]
    fn permissions_are_the_nine_bits_and_are_written_in_octal() {
        assert_eq!(Permissions::new(0o104_755).bits(), 0o755);
        assert_eq!(Permissions::new(0o640).to_string(), "0o640");
    }
}
