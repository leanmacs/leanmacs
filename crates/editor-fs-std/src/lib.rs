//! The file port's real adapter: [`StdFs`], an [`Fs`] over `std::fs`.
//!
//! The port, its fake and its contract are `editor-text`'s
//! ([`editor_text::fs`]). This crate is thin: each method is a call or two
//! of the standard library, and one function turns the system's errors
//! into the port's. What a load and a save do with the port is
//! `editor-text`'s, and is not here.
//!
//! What each method is over:
//!
//! - **`stat`** is `fs::metadata`, which follows links; nothing there is
//!   `None`. The modification time and the nine permission bits are read
//!   from the Unix metadata.
//! - **`read`** opens the file, refuses what its metadata says is not a
//!   file (opening a directory succeeds on Unix), and reads to the end into
//!   a buffer sized from the metadata.
//! - **`write`** opens with `create_new`, which is `O_EXCL`: nothing is
//!   followed and nothing is overwritten. With permissions named, the file
//!   is made readable and writable by its owner alone and is then given
//!   exactly the bits asked, on the open file, before a byte is written:
//!   so the bits are exact whatever the process's mask, and the file is
//!   never more open than it will be. With none named, it has the default
//!   mode less the mask. Then every piece is written, and the file is
//!   synced (`sync_all`, which on macOS is `F_FULLFSYNC`).
//! - **`append`** opens with `append` and `create` (`O_APPEND | O_CREAT`),
//!   so a file is made, with the default mode less the mask, where nothing
//!   is, and every piece is written at the end. It is **not synced**, as
//!   the port says. The system refuses a directory as one (`EISDIR`) and a
//!   file on the way as not a directory (`ENOTDIR`), both the port's
//!   `NotAFile`.
//! - **`rename`** is `fs::rename`. The directory the file is now in is then
//!   opened and synced, so the new name is on disk too, and **a failure of
//!   that sync is ignored**: some file systems cannot sync a directory, and
//!   the file is whole either way. The system's rename changes neither the
//!   file's modification time nor its size, which the port asks and the
//!   contract checks here on real files.
//! - **`remove`** is `fs::remove_file`.
//! - **`resolve`** is `fs::canonicalize`.
//! - **`read_link`** is `fs::read_link`, which follows nothing and gives
//!   the path as the link holds it. The system refuses a path that is no
//!   link as an invalid argument, and one where nothing is as not found:
//!   both are `None`.
//! - **`make_directory`** is `fs::create_dir_all`, which makes every
//!   directory on the way and takes one already there as done. Where a
//!   file is at the path the system says it exists; the port's word for
//!   that, when making a directory, is `NotAFile`, so `AlreadyExists` is
//!   answered as `NotAFile` here. Under a file the system says not a
//!   directory, which is `NotAFile` as for every operation.
//! - **`list`** is `fs::read_dir`, with `fs::metadata` of each entry for
//!   its kind, which follows links: a link whose metadata cannot be read,
//!   one that names nothing included, is `Other`. The system refuses a
//!   path that is not a directory as not a directory, which is the port's
//!   `NotAFile`, as for every other operation.
//!
//! [`StdFs::system`] is the one way to make one, so that the real file
//! system has a name a lint can refuse where it does not belong
//! (`crates/editor-ffi/clippy.toml`).
//!
//! Unix only: permission bits, and syncing a directory, are
//! `std::os::unix`. Anywhere else the crate does not compile, as the
//! editor's entry point does not.
//!
//! # Tests
//!
//! The tests here are of the adapter and of nothing above it:
//!
//! - `tests/contract.rs` holds [`StdFs`] to the port's contract
//!   ([`editor_text::fs::contract::check`]), in a temporary directory the
//!   test makes and that is removed when it ends, against a ground that
//!   reads and sets the truth with `std` directly;
//! - the unit test below pins how the system's errors are named, the one
//!   decision the adapter makes that the contract reaches only in part.
//!
//! Nothing here calls `editor_text::file`: what a load and a save do is
//! that crate's rule, pinned there on the fake. The one test that runs the
//! real logic over this adapter is `editor-ffi`'s wiring test.

#[cfg(not(unix))]
compile_error!(
    "editor-fs-std is the file port over Unix's files: it reads and sets permission bits and \
     syncs a directory through `std::os::unix`. The editor is built for macOS and Linux only."
);

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use editor_text::fs::{Entry, Fs, FsError, FsErrorKind, Kind, Modified, Permissions, Pieces, Stat};

/// The machine's file system, as the file port.
pub struct StdFs(());

impl StdFs {
    /// The machine's file system. This is the one way to make one.
    ///
    /// It is not called `new`, and there is no `Default`: a second way to
    /// make the real file system would be a second name for a lint to
    /// refuse.
    pub const fn system() -> Self {
        Self(())
    }
}

/// The port's kind of the thing `metadata` describes.
fn kind_of(metadata: &fs::Metadata) -> Kind {
    if metadata.is_file() {
        Kind::File
    } else if metadata.is_dir() {
        Kind::Directory
    } else {
        Kind::Other
    }
}

/// The port's error for the system's `error`: its kind by the system's
/// kind, and the system's own words as the detail.
fn refusal(error: &io::Error) -> FsError {
    let kind = match error.kind() {
        io::ErrorKind::NotFound => FsErrorKind::NotFound,
        io::ErrorKind::PermissionDenied => FsErrorKind::Denied,
        io::ErrorKind::AlreadyExists => FsErrorKind::Exists,
        io::ErrorKind::IsADirectory | io::ErrorKind::NotADirectory => FsErrorKind::NotAFile,
        _ => FsErrorKind::Other,
    };
    FsError::new(kind, error.to_string())
}

impl Fs for StdFs {
    fn stat(&self, path: &Path) -> Result<Option<Stat>, FsError> {
        match fs::metadata(path) {
            Ok(metadata) => Ok(Some(Stat {
                kind: kind_of(&metadata),
                size: metadata.len(),
                modified: Modified {
                    seconds: metadata.mtime(),
                    // The system keeps it below a thousand million; a value
                    // that is not would be the system's fault, and is kept
                    // in range rather than wrapped.
                    nanoseconds: u32::try_from(metadata.mtime_nsec()).unwrap_or(0),
                },
                permissions: Permissions::new(metadata.mode()),
            })),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(refusal(&error)),
        }
    }

    fn read(&self, path: &Path) -> Result<Vec<u8>, FsError> {
        let mut file = File::open(path).map_err(|error| refusal(&error))?;
        let metadata = file.metadata().map_err(|error| refusal(&error))?;
        if !metadata.is_file() {
            return Err(FsError::new(
                FsErrorKind::NotAFile,
                format!("{} is not a regular file", path.display()),
            ));
        }
        let mut bytes = Vec::with_capacity(usize::try_from(metadata.len()).unwrap_or(0));
        file.read_to_end(&mut bytes)
            .map_err(|error| refusal(&error))?;
        Ok(bytes)
    }

    fn write(
        &self,
        path: &Path,
        pieces: &mut Pieces<'_>,
        permissions: Option<Permissions>,
    ) -> Result<(), FsError> {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        if permissions.is_some() {
            // Never more open than it will be, before it is given its own.
            options.mode(0o600);
        }
        let mut file = options.open(path).map_err(|error| refusal(&error))?;
        if let Some(permissions) = permissions {
            // On the open file, so the process's mask has no say.
            file.set_permissions(fs::Permissions::from_mode(permissions.bits()))
                .map_err(|error| refusal(&error))?;
        }
        for piece in pieces {
            file.write_all(&piece).map_err(|error| refusal(&error))?;
        }
        file.sync_all().map_err(|error| refusal(&error))
    }

    fn append(&self, path: &Path, pieces: &mut Pieces<'_>) -> Result<(), FsError> {
        let mut file = OpenOptions::new()
            .append(true)
            .create(true)
            .open(path)
            .map_err(|error| refusal(&error))?;
        for piece in pieces {
            file.write_all(&piece).map_err(|error| refusal(&error))?;
        }
        // Not synced: the port asks only that the bytes reach the system.
        Ok(())
    }

    fn rename(&self, from: &Path, to: &Path) -> Result<(), FsError> {
        fs::rename(from, to).map_err(|error| refusal(&error))?;
        if let Some(directory) = to.parent()
            && let Ok(directory) = File::open(directory)
        {
            // Ignored: some file systems cannot sync a directory, and the
            // file is whole either way.
            let _ = directory.sync_all();
        }
        Ok(())
    }

    fn remove(&self, path: &Path) -> Result<(), FsError> {
        fs::remove_file(path).map_err(|error| refusal(&error))
    }

    fn resolve(&self, path: &Path) -> Result<PathBuf, FsError> {
        fs::canonicalize(path).map_err(|error| refusal(&error))
    }

    fn read_link(&self, path: &Path) -> Result<Option<PathBuf>, FsError> {
        match fs::read_link(path) {
            Ok(held) => Ok(Some(held)),
            // The system refuses what is no link as an invalid argument
            // (`EINVAL`), and nothing as not found: neither is a link.
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::InvalidInput | io::ErrorKind::NotFound
                ) =>
            {
                Ok(None)
            }
            Err(error) => Err(refusal(&error)),
        }
    }

    fn make_directory(&self, path: &Path) -> Result<(), FsError> {
        fs::create_dir_all(path).map_err(|error| {
            // Something that is not a directory is at the path: the system
            // says it exists, and `create_dir_all` has found it is no
            // directory.
            if error.kind() == io::ErrorKind::AlreadyExists {
                FsError::new(FsErrorKind::NotAFile, error.to_string())
            } else {
                refusal(&error)
            }
        })
    }

    fn list(&self, path: &Path) -> Result<Vec<Entry>, FsError> {
        let mut entries = Vec::new();
        for entry in fs::read_dir(path).map_err(|error| refusal(&error))? {
            let entry = entry.map_err(|error| refusal(&error))?;
            // Followed: a link is listed as what it names, and a link to
            // nothing, whose metadata cannot be read, as other.
            let kind =
                fs::metadata(entry.path()).map_or(Kind::Other, |metadata| kind_of(&metadata));
            entries.push(Entry {
                name: entry.file_name(),
                kind,
            });
        }
        Ok(entries)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_kind_of_io_error_is_its_kind_of_file_system_error() {
        let kind = |kind: io::ErrorKind| refusal(&io::Error::from(kind)).kind;

        assert_eq!(kind(io::ErrorKind::NotFound), FsErrorKind::NotFound);
        assert_eq!(kind(io::ErrorKind::PermissionDenied), FsErrorKind::Denied);
        assert_eq!(kind(io::ErrorKind::AlreadyExists), FsErrorKind::Exists);
        assert_eq!(kind(io::ErrorKind::IsADirectory), FsErrorKind::NotAFile);
        assert_eq!(kind(io::ErrorKind::NotADirectory), FsErrorKind::NotAFile);
        // Everything else is the port's catch-all, a few of them here.
        assert_eq!(kind(io::ErrorKind::StorageFull), FsErrorKind::Other);
        assert_eq!(kind(io::ErrorKind::Interrupted), FsErrorKind::Other);
        assert_eq!(kind(io::ErrorKind::InvalidFilename), FsErrorKind::Other);
        assert_eq!(kind(io::ErrorKind::ReadOnlyFilesystem), FsErrorKind::Other);
    }

    #[test]
    fn a_file_system_error_carries_the_systems_own_words() {
        let error = io::Error::other("the disk is on fire");

        assert_eq!(refusal(&error).detail, "the disk is on fire");
    }
}
