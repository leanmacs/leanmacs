//! `leanmacs-release`: release tooling's command line, the edge where
//! `editor-release`'s core meets the real environment and real programs.
//!
//! ```text
//! leanmacs-release [--root <dir>] build-id
//! leanmacs-release [--root <dir>] commit
//! leanmacs-release [--root <dir>] dmg <app> <out-dir>
//! ```
//!
//! - `build-id` prints the build ID (`editor_release::build_id::resolve`):
//!   `LEANMACS_BUILD_ID` when set, else HEAD's committer time in UTC, for
//!   the checkout the working directory is in.
//! - `commit` prints the commit (`editor_release::commit::resolve`):
//!   `LEANMACS_COMMIT` when set, else HEAD's SHA.
//! - `dmg <app> <out-dir>`, on macOS only, packs `<app>` into
//!   `<out-dir>/Leanmacs-<build-id>.dmg` (`editor_release::dmg::pack`) and
//!   prints the image's path. It refuses an app whose `CFBundleVersion` is
//!   not this build's ID. `<app>` and `<out-dir>` are made absolute against
//!   the working directory first, as the plan takes absolute paths alone.
//!   The licence is the workspace's `LICENSE`, the README
//!   `packaging/macos/README.txt`, and the volume is staged in
//!   `target/dmg/staging`.
//!
//! The workspace is the one this binary was built in, two directories above
//! this crate's manifest, unless `--root` names another. Each failure is
//! one line on standard error and exit status 1; a command line it does not
//! take is the usage and status 2.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use editor_release::dmg::{self, Inputs};
use editor_release::{build_id, commit};
use editor_release_std::{StdEnv, StdProcess};

const USAGE: &str =
    "usage: leanmacs-release [--root <dir>] (build-id | commit | dmg <app> <out-dir>)";

/// The workspace this binary was built in.
fn built_workspace() -> PathBuf {
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
    manifest
        .parent()
        .and_then(Path::parent)
        .unwrap_or(manifest)
        .to_owned()
}

/// `path` made absolute against the working directory, as the error says
/// otherwise.
fn absolute(path: &str) -> Result<PathBuf, String> {
    std::path::absolute(path).map_err(|e| format!("cannot make {path} absolute: {e}"))
}

fn run(args: &[String]) -> Result<Option<String>, String> {
    let (root, rest) = match args {
        [flag, root, rest @ ..] if flag == "--root" => (absolute(root)?, rest),
        rest => (built_workspace(), rest),
    };
    let here = Path::new(".");
    match rest {
        [command] if command == "build-id" => {
            let id =
                build_id::resolve(&StdEnv, &mut StdProcess, here).map_err(|e| e.to_string())?;
            Ok(Some(id.to_string()))
        }
        [command] if command == "commit" => {
            let sha = commit::resolve(&StdEnv, &mut StdProcess, here).map_err(|e| e.to_string())?;
            Ok(Some(sha.to_string()))
        }
        [command, app, out] if command == "dmg" => {
            if !cfg!(target_os = "macos") {
                return Err("dmg: the disk image is packed on macOS only".to_owned());
            }
            let (app, out) = (absolute(app)?, absolute(out)?);
            let id =
                build_id::resolve(&StdEnv, &mut StdProcess, here).map_err(|e| e.to_string())?;
            let license = root.join("LICENSE");
            let readme = root.join("packaging").join("macos").join("README.txt");
            let staging = root.join("target").join("dmg").join("staging");
            let inputs = Inputs {
                app: &app,
                license: &license,
                readme: &readme,
            };
            let made = dmg::pack(&mut StdProcess, &inputs, &staging, &out, &id)
                .map_err(|e| e.to_string())?;
            Ok(Some(made.display().to_string()))
        }
        _ => Ok(None),
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(Some(line)) => {
            println!("{line}");
            ExitCode::SUCCESS
        }
        Ok(None) => {
            eprintln!("{USAGE}");
            ExitCode::from(2)
        }
        Err(message) => {
            eprintln!("leanmacs-release: {message}");
            ExitCode::FAILURE
        }
    }
}
