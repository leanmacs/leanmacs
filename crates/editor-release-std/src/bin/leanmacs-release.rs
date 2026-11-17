//! `leanmacs-release`: release tooling's command line, the edge where
//! `editor-release`'s core meets the real environment and real programs.
//!
//! ```text
//! leanmacs-release [--root <dir>] build-id
//! leanmacs-release [--root <dir>] commit
//! leanmacs-release [--root <dir>] dmg <app> <out-dir>
//! leanmacs-release [--root <dir>] nightly <dist-dir> <out-dir>
//! leanmacs-release [--root <dir>] publish <dir>
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
//! - `nightly <dist-dir> <out-dir>`, on macOS only, prepares the nightly
//!   (`editor_release::nightly::prepare`) and holds no token: it takes
//!   `<dist-dir>/Leanmacs-<build-id>.dmg`, mounts it at
//!   `target/nightly-mount` to check that the app's stamp is this build's
//!   ID and commit, and writes `Leanmacs-<build-id>.dmg`, `Leanmacs.dmg`,
//!   `Leanmacs.dmg.sha256`, `build.json` and `notes.md` to `<out-dir>`,
//!   which it makes. The repository the notes link to is
//!   `editor_release::nightly::target`'s: `GITHUB_SERVER_URL` and
//!   `GITHUB_REPOSITORY` when set, else github.com's leanmacs/leanmacs.
//! - `publish <dir>` publishes a directory `nightly` prepared
//!   (`editor_release::nightly::publish`) with `gh`, which reads its token
//!   from `GH_TOKEN`. It refuses to run except on a push to main
//!   (`editor_release::nightly::publish_gate`), and refuses a directory
//!   whose `build.json` and `Leanmacs.dmg.sha256` do not describe this
//!   build and its `Leanmacs.dmg`'s size
//!   (`editor_release::nightly::read_build`).
//!
//! The workspace is the one this binary was built in, two directories above
//! this crate's manifest, unless `--root` names another. Each failure is
//! one line on standard error and exit status 1; a command line it does not
//! take is the usage and status 2.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use editor_release::dmg::{self, Inputs};
use editor_release::{build_id, commit, nightly};
use editor_release_std::{StdEnv, StdProcess, write_prepared};

const USAGE: &str = "usage: leanmacs-release [--root <dir>] (build-id | commit | dmg <app> <out-dir> | nightly <dist-dir> <out-dir> | publish <dir>)";

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
        [command, dist, out] if command == "nightly" => {
            if !cfg!(target_os = "macos") {
                return Err("nightly: the disk image is mounted on macOS only".to_owned());
            }
            let (dist, out) = (absolute(dist)?, absolute(out)?);
            let id =
                build_id::resolve(&StdEnv, &mut StdProcess, here).map_err(|e| e.to_string())?;
            let sha = commit::resolve(&StdEnv, &mut StdProcess, here).map_err(|e| e.to_string())?;
            let target = nightly::target(&StdEnv).map_err(|e| e.to_string())?;
            let image = dist.join(dmg::file_name(&id));
            let size = std::fs::metadata(&image)
                .map_err(|e| format!("{}: {e}: run `mise run dmg`", image.display()))?
                .len();
            let mount_point = root.join("target").join("nightly-mount");
            for dir in [&out, &mount_point] {
                std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
            }
            let inputs = nightly::Inputs {
                image: &image,
                size,
                mount_point: &mount_point,
                out: &out,
            };
            let prepared = nightly::prepare(&mut StdProcess, &inputs, &id, &sha, &target)
                .map_err(|e| e.to_string())?;
            write_prepared(&out, &prepared).map_err(|e| e.to_string())?;
            Ok(Some(format!(
                "{}: build {id}, commit {sha}, SHA-256 {}",
                out.display(),
                prepared.build.sha256
            )))
        }
        [command, dir] if command == "publish" => {
            let target = nightly::publish_gate(&StdEnv).map_err(|e| e.to_string())?;
            let dir = absolute(dir)?;
            let id =
                build_id::resolve(&StdEnv, &mut StdProcess, here).map_err(|e| e.to_string())?;
            let sha = commit::resolve(&StdEnv, &mut StdProcess, here).map_err(|e| e.to_string())?;
            let read = |name: &str| {
                let path = dir.join(name);
                std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))
            };
            let fixed = dir.join(nightly::FIXED);
            let size = std::fs::metadata(&fixed)
                .map_err(|e| format!("{}: {e}", fixed.display()))?
                .len();
            let build = nightly::read_build(
                &read(nightly::BUILD_JSON)?,
                &read(nightly::SHA256)?,
                size,
                &id,
                &sha,
            )
            .map_err(|e| e.to_string())?;
            nightly::publish(&mut StdProcess, &target.repo, &dir, &build)
                .map_err(|e| e.to_string())?;
            Ok(Some(format!(
                "published build {id} as {}'s {}",
                target.repo,
                nightly::TAG
            )))
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
