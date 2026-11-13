//! The `std::fs` adapter held to the file port's contract, on real files.
//!
//! The check is `editor-text`'s, the same one its fake passes
//! (`editor_text::fs::contract::check`). It runs in a temporary directory
//! this test makes, which is removed when the test ends; every path is
//! under it and is passed in explicitly, so the working directory and the
//! developer's files are not touched.
//!
//! The ground reads and sets the truth with `std` directly, never through
//! the adapter: so the adapter's `write` and its `stat` are each compared
//! with what the system says, and not only with each other.

use std::fs::{self, File};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use editor_fs_std::StdFs;
use editor_text::fs::contract::{self, Ground};
use editor_text::fs::{Modified, Permissions};
use tempfile::TempDir;

/// The ground for the adapter: a temporary directory, and the system asked
/// directly.
struct Disk {
    /// The directory, with the links in its path followed (on macOS the
    /// temporary directory is reached through one).
    root: PathBuf,
    /// The directory's owner: dropping it removes the directory and
    /// everything in it.
    _directory: TempDir,
}

impl Disk {
    /// A new, empty directory of this test's own.
    fn new() -> Self {
        let directory = tempfile::tempdir().expect("a temporary directory can be made");
        let root = fs::canonicalize(directory.path())
            .expect("the temporary directory's own path resolves");
        Self {
            root,
            _directory: directory,
        }
    }
}

/// The system's refusal, in words.
fn said(error: std::io::Error) -> String {
    error.to_string()
}

impl Ground for Disk {
    fn root(&self) -> &Path {
        &self.root
    }

    fn link(&self, link: &Path, to: &Path) -> Result<(), String> {
        std::os::unix::fs::symlink(to, link).map_err(said)
    }

    fn set_modified(&self, path: &Path, to: Modified) -> Result<(), String> {
        let seconds = u64::try_from(to.seconds).map_err(|_| String::from("before the epoch"))?;
        let instant = SystemTime::UNIX_EPOCH + Duration::new(seconds, to.nanoseconds);
        File::options()
            .write(true)
            .open(path)
            .and_then(|file| file.set_modified(instant))
            .map_err(said)
    }

    fn set_permissions(&self, path: &Path, to: Permissions) -> Result<(), String> {
        fs::set_permissions(path, fs::Permissions::from_mode(to.bits())).map_err(said)
    }

    fn permissions(&self, path: &Path) -> Result<Permissions, String> {
        fs::metadata(path)
            .map(|metadata| Permissions::new(metadata.permissions().mode()))
            .map_err(said)
    }
}

#[test]
fn the_adapter_keeps_the_file_ports_contract_in_a_temporary_directory() {
    let disk = Disk::new();

    assert_eq!(contract::check(&StdFs::system(), &disk), Ok(()));
}
