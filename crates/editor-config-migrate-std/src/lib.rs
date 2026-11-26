//! Config conversion's real files adapter, over `std::fs` ([`StdFiles`]),
//! and the `config-migrate` binary (`src/bin/config-migrate.rs`) that wires
//! it to `editor-config-migrate`'s conversion.
//!
//! The adapter is thin: every decision is the core's. `tests/contract.rs`
//! holds [`StdFiles`] to the files port's contract, the one the core's fake
//! passes, in a temporary directory, and `tests/convert.rs` runs the binary
//! on a copy of the fixture `tests/config-migrate/chunks` and on a
//! directory it refuses. Nothing of the editor depends on this crate
//! (`deny.toml`).

use std::ffi::OsString;
use std::io;
use std::path::Path;

use editor_config_migrate::ports::{Files, FilesError, Kind};

/// The real file system, over `std::fs`, every call the system's.
#[derive(Debug, Clone, Copy, Default)]
pub struct StdFiles;

/// `error` at `path`.
fn files_error(path: &Path, error: &io::Error) -> FilesError {
    FilesError::new(path, error.to_string())
}

impl Files for StdFiles {
    #[expect(
        clippy::disallowed_methods,
        reason = "`StdFiles` is the real `Files`: it asks the disk what is at the path"
    )]
    fn kind(&self, path: &Path) -> Result<Kind, FilesError> {
        match std::fs::metadata(path) {
            Ok(meta) if meta.is_dir() => Ok(Kind::Directory),
            Ok(meta) if meta.is_file() => Ok(Kind::File),
            Ok(_) => Ok(Kind::Other),
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::NotFound | io::ErrorKind::NotADirectory
                ) =>
            {
                Ok(Kind::Nothing)
            }
            Err(e) => Err(files_error(path, &e)),
        }
    }

    #[expect(
        clippy::disallowed_methods,
        reason = "`StdFiles` is the real `Files`: it lists the directory on disk"
    )]
    fn names(&self, dir: &Path) -> Result<Vec<OsString>, FilesError> {
        let mut names = Vec::new();
        for entry in std::fs::read_dir(dir).map_err(|e| files_error(dir, &e))? {
            names.push(entry.map_err(|e| files_error(dir, &e))?.file_name());
        }
        names.sort_by(|a, b| a.as_encoded_bytes().cmp(b.as_encoded_bytes()));
        Ok(names)
    }

    #[expect(
        clippy::disallowed_methods,
        reason = "`StdFiles` is the real `Files`: it reads the file on disk"
    )]
    fn read(&self, path: &Path) -> Result<Vec<u8>, FilesError> {
        std::fs::read(path).map_err(|e| files_error(path, &e))
    }

    #[expect(
        clippy::disallowed_methods,
        reason = "`StdFiles` is the real `Files`: it writes the file on disk"
    )]
    fn write(&mut self, path: &Path, bytes: &[u8]) -> Result<(), FilesError> {
        std::fs::write(path, bytes).map_err(|e| files_error(path, &e))
    }

    #[expect(
        clippy::disallowed_methods,
        reason = "`StdFiles` is the real `Files`: it makes the directory on disk"
    )]
    fn make_dir(&mut self, path: &Path) -> Result<(), FilesError> {
        std::fs::create_dir_all(path).map_err(|e| files_error(path, &e))
    }

    #[expect(
        clippy::disallowed_methods,
        reason = "`StdFiles` is the real `Files`: it removes the file on disk"
    )]
    fn remove(&mut self, path: &Path) -> Result<(), FilesError> {
        std::fs::remove_file(path).map_err(|e| files_error(path, &e))
    }

    #[expect(
        clippy::disallowed_methods,
        reason = "`StdFiles` is the real `Files`: it renames the file on disk"
    )]
    fn rename(&mut self, from: &Path, to: &Path) -> Result<(), FilesError> {
        std::fs::rename(from, to)
            .map_err(|e| FilesError::new(from, format!("renaming to {}: {e}", to.display())))
    }
}
