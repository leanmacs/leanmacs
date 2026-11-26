//! Release tooling's real adapters: the environment over `std::env`
//! ([`StdEnv`]), programs over `std::process` ([`StdProcess`]) and files
//! over `std::fs` ([`StdFiles`]), the writer of a prepared nightly's texts
//! ([`write_prepared`]), and the binaries that wire them to
//! `editor-release`'s core: `leanmacs-release` (`src/bin/leanmacs-release.rs`),
//! `stage-bundle` (`src/bin/stage-bundle.rs`) and `link-stubs`
//! (`src/bin/link-stubs.rs`).
//!
//! The adapters are thin: every decision is the core's. `tests/contract.rs`
//! holds [`StdProcess`] and [`StdFiles`] to their ports' contracts, the
//! ones the core's fakes pass, and `tests/resolve.rs` runs the core's resolvers through it
//! on a git repository it makes; `tests/nightly_mount.rs` (`mise run
//! nightly-check`) prepares a nightly from a real image; `tests/site.rs`
//! runs `leanmacs-release site` on the fixtures in `tests/site/`;
//! `tests/stage_bundle.rs` runs `stage-bundle` on both its forms, and
//! `tests/link_stubs.rs` runs `link-stubs` on a copy of itself. Only release
//! tooling depends on this crate, and the editor never links it
//! (`deny.toml`).

use std::ffi::OsString;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use editor_release::nightly::Prepared;
use editor_release::ports::{
    Entry, EntryKind, Env, Files, FilesError, Invocation, Kind, Process, RunError,
};

/// Writes each of `prepared`'s texts to its file in `out`, replacing any
/// file of that name.
///
/// # Errors
///
/// The first write that fails, with the file's path.
#[expect(
    clippy::disallowed_methods,
    reason = "the real edge of the release core: it writes the prepared files the core decided on"
)]
pub fn write_prepared(out: &Path, prepared: &Prepared) -> io::Result<()> {
    for (name, text) in prepared.texts() {
        let path = out.join(name);
        std::fs::write(&path, text)
            .map_err(|e| io::Error::new(e.kind(), format!("{}: {e}", path.display())))?;
    }
    Ok(())
}

/// The process's own environment.
#[derive(Debug, Clone, Copy, Default)]
pub struct StdEnv;

impl Env for StdEnv {
    #[expect(
        clippy::disallowed_methods,
        reason = "`StdEnv` is the real `Env`: the process's environment is what it reads"
    )]
    fn var(&self, name: &str) -> Option<OsString> {
        std::env::var_os(name)
    }
}

/// Programs run with `std::process`, waited for to their end. Standard
/// input is closed and standard error is the tool's own; standard output is
/// captured when the invocation asks, and the tool's own otherwise.
#[derive(Debug, Clone, Copy, Default)]
pub struct StdProcess;

impl Process for StdProcess {
    #[expect(
        clippy::disallowed_methods,
        reason = "`StdProcess` is the real `Process`: it runs the invocation it is given"
    )]
    fn run(&mut self, invocation: &Invocation) -> Result<Vec<u8>, RunError> {
        let mut command = Command::new(&invocation.program);
        command
            .args(&invocation.args)
            .stdin(Stdio::null())
            .stderr(Stdio::inherit());
        let (status, stdout) = if invocation.captured {
            let output = command
                .stdout(Stdio::piped())
                .output()
                .map_err(|e| RunError::Start(e.to_string()))?;
            (output.status, output.stdout)
        } else {
            let status = command
                .stdout(Stdio::inherit())
                .status()
                .map_err(|e| RunError::Start(e.to_string()))?;
            (status, Vec::new())
        };
        if status.success() {
            Ok(stdout)
        } else {
            Err(RunError::Failed(status.code()))
        }
    }
}

/// The real file system, over `std::fs`, every call the system's.
///
/// A copy is `std::fs::copy`, which clones where the file system can: with
/// `fclonefileat` on macOS, the clone `cp -c` makes, so the toolchain a
/// bundle ships costs no disk on APFS, and with `copy_file_range` on Linux,
/// which the kernel makes a reflink where the file system has them. It
/// keeps the file's permissions. A link is made with
/// `std::os::unix::fs::symlink`, which reaches the real file system outside
/// the root `clippy.toml`'s list of `std::fs`, so it carries no mark.
///
/// Two libraries were set aside: `reflink-copy`, since std already clones
/// on both systems, and `walkdir`, since the core walks a tree through the
/// port's [`Files::entries`] and this adapter walks nothing.
#[derive(Debug, Clone, Copy, Default)]
pub struct StdFiles;

/// `error` at `path`.
fn files_error(path: &Path, error: &io::Error) -> FilesError {
    FilesError::new(path, error.to_string())
}

/// Whether a file's permissions give it any executable bit.
fn executable(permissions: &std::fs::Permissions) -> bool {
    permissions.mode() & 0o111 != 0
}

impl Files for StdFiles {
    #[expect(
        clippy::disallowed_methods,
        reason = "`StdFiles` is the real `Files`: it asks the disk what is at the path"
    )]
    fn kind(&self, path: &Path) -> Result<Kind, FilesError> {
        match std::fs::metadata(path) {
            Ok(meta) if meta.is_dir() => Ok(Kind::Directory),
            Ok(meta) if meta.is_file() => Ok(Kind::File {
                executable: executable(&meta.permissions()),
            }),
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
    fn entries(&self, dir: &Path) -> Result<Vec<Entry>, FilesError> {
        let mut entries = Vec::new();
        for entry in std::fs::read_dir(dir).map_err(|e| files_error(dir, &e))? {
            let entry = entry.map_err(|e| files_error(dir, &e))?;
            let path = entry.path();
            // Not following a link: `DirEntry::metadata` is the entry's own.
            let meta = entry.metadata().map_err(|e| files_error(&path, &e))?;
            let file_type = meta.file_type();
            let kind = if file_type.is_symlink() {
                EntryKind::Link
            } else if file_type.is_dir() {
                EntryKind::Directory
            } else if file_type.is_file() {
                EntryKind::File {
                    executable: executable(&meta.permissions()),
                }
            } else {
                EntryKind::Other
            };
            entries.push(Entry {
                name: entry.file_name(),
                kind,
            });
        }
        entries.sort_by(|a, b| a.name.as_encoded_bytes().cmp(b.name.as_encoded_bytes()));
        Ok(entries)
    }

    #[expect(
        clippy::disallowed_methods,
        reason = "`StdFiles` is the real `Files`: it reads the link on disk"
    )]
    fn read_link(&self, path: &Path) -> Result<PathBuf, FilesError> {
        std::fs::read_link(path).map_err(|e| files_error(path, &e))
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
        reason = "`StdFiles` is the real `Files`: it writes the file on disk and sets its executable bits"
    )]
    fn write(&mut self, path: &Path, bytes: &[u8], executable: bool) -> Result<(), FilesError> {
        std::fs::write(path, bytes).map_err(|e| files_error(path, &e))?;
        let mut permissions = std::fs::metadata(path)
            .map_err(|e| files_error(path, &e))?
            .permissions();
        let mode = permissions.mode();
        // The executable bits follow the readable ones, as `chmod +x` under
        // the umask gives them; off, all three are cleared.
        let wanted = if executable {
            mode | ((mode & 0o444) >> 2)
        } else {
            mode & !0o111
        };
        if wanted != mode {
            permissions.set_mode(wanted);
            std::fs::set_permissions(path, permissions).map_err(|e| files_error(path, &e))?;
        }
        Ok(())
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
        reason = "`StdFiles` is the real `Files`: it clones the file on disk"
    )]
    fn copy(&mut self, from: &Path, to: &Path) -> Result<(), FilesError> {
        std::fs::copy(from, to)
            .map(|_| ())
            .map_err(|e| FilesError::new(from, format!("copying to {}: {e}", to.display())))
    }

    fn symlink(&mut self, target: &Path, link: &Path) -> Result<(), FilesError> {
        std::os::unix::fs::symlink(target, link).map_err(|e| files_error(link, &e))
    }
}
