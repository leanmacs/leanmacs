//! The packed disk image, mounted and checked: `mise run dmg-check`, never
//! part of the gate (it mounts an image, and the gate builds none).
//!
//! `LEANMACS_DMG` names the image; the test panics when it is unset, so a
//! run that forgot it never passes. It mounts the image read-only, with no
//! Finder window, on a mount point in a temporary directory it owns, and a
//! guard detaches it however the test ends (`hdiutil detach`, then with
//! `-force` if that fails). Then:
//!
//! 1. the volume's root, read with `read_dir`, `symlink_metadata` and
//!    `read_link`, must pass `editor_release::dmg::check_volume`: exactly
//!    `Leanmacs.app`, `Applications` linking to `/Applications`, `LICENSE`
//!    and `README.txt`, names starting with `.` aside;
//! 2. `LICENSE` and `README.txt` must hold the repository's bytes;
//! 3. the app's signature must verify (`codesign --verify --strict --deep`);
//! 4. its `CFBundleVersion` must be the build the file name names and this
//!    build's ID, its `LeanmacsCommit` this build's commit, both resolved
//!    as `leanmacs-release` resolves them, and its
//!    `CFBundleShortVersionString` the line of `lean/app/version`;
//! 5. its `editor --version`, run with an empty environment, must print
//!    those three;
//! 6. a user's package set builds from the read-only volume alone
//!    (`docs/design/lean-runtime.md`, "The app ships the toolchain"): the
//!    image's `leanmacs headless --generate`, on a temporary config of
//!    `tests/headless/generate`'s `init.lean`, writes a lakefile naming the
//!    volume's set; the volume's own `lake -d <config> build :editorInstall`,
//!    with an empty environment but `PATH=/usr/bin:/bin`, `HOME` in the
//!    temporary directory and the app's `editor.build`, exits 0, installing
//!    an editor whose core is the app's and whose `--probe` prints
//!    `probe: ok`. The volume is read-only, so the build compiled nothing
//!    of the app.
//!
//! It writes nothing but the mount point and step 6's config, home and
//! install, which go with the temporary directory.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use editor_release::dmg::{self, Found, Kind};
use editor_release::{build_id, commit};
use editor_release_std::{StdEnv, StdProcess};
use tempfile::TempDir;

/// The workspace: two directories above this crate's manifest.
fn workspace() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..")
}

/// Runs a program to success and returns its standard output.
fn output(program: &str, args: &[&str]) -> String {
    let out = Command::new(program)
        .args(args)
        .output()
        .unwrap_or_else(|e| panic!("{program} {args:?} cannot start: {e}"));
    assert!(out.status.success(), "{program} {args:?} failed: {out:?}");
    String::from_utf8(out.stdout).expect("UTF-8")
}

/// The mounted image, detached when dropped.
struct Mounted {
    point: PathBuf,
}

impl Drop for Mounted {
    /// Detaches the image, by force if a plain detach fails (a file still
    /// open on the volume).
    fn drop(&mut self) {
        let detach = |force: bool| {
            let mut command = Command::new("hdiutil");
            command.arg("detach");
            if force {
                command.arg("-force");
            }
            command.arg(&self.point).status().is_ok_and(|s| s.success())
        };
        if !detach(false) {
            detach(true);
        }
    }
}

fn kind(path: &Path) -> Kind {
    let meta = fs::symlink_metadata(path).expect("metadata");
    let kind = meta.file_type();
    if kind.is_symlink() {
        Kind::Symlink
    } else if kind.is_dir() {
        Kind::Directory
    } else if kind.is_file() {
        Kind::File
    } else {
        Kind::Other
    }
}

#[test]
#[ignore = "mounts a built .dmg: mise run dmg-check"]
fn the_packed_image_holds_the_app_the_link_the_licence_and_the_readme() {
    let image = PathBuf::from(
        std::env::var_os("LEANMACS_DMG").expect("LEANMACS_DMG must name the .dmg to check"),
    );
    assert!(image.is_file(), "no image at {}", image.display());
    let named = image
        .file_name()
        .and_then(|n| n.to_str())
        .and_then(dmg::build_of)
        .unwrap_or_else(|| panic!("{} is not named Leanmacs-<build-id>.dmg", image.display()));

    let dir = TempDir::new().expect("a temporary directory");
    let point = dir.path().join("mnt");
    let image_arg = image.to_str().expect("a UTF-8 path");
    output(
        "hdiutil",
        &[
            "attach",
            "-nobrowse",
            "-readonly",
            "-noautoopen",
            "-mountpoint",
            point.to_str().expect("a UTF-8 path"),
            image_arg,
        ],
    );
    let mounted = Mounted { point };
    let root = &mounted.point;

    // 1. The root.
    let listing: Vec<Found> = fs::read_dir(root)
        .expect("the volume's root")
        .map(|entry| {
            let entry = entry.expect("an entry");
            let path = entry.path();
            let kind = kind(&path);
            Found {
                name: entry.file_name().to_string_lossy().into_owned(),
                kind,
                target: (kind == Kind::Symlink).then(|| fs::read_link(&path).expect("a link")),
            }
        })
        .collect();
    let problems = dmg::check_volume(&listing);
    assert!(
        problems.is_empty(),
        "the volume's root: {}",
        problems
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join("; ")
    );

    // 2. The two files are the repository's.
    let workspace = workspace();
    for (name, source) in [
        (dmg::LICENSE, workspace.join("LICENSE")),
        (
            dmg::README,
            workspace.join("packaging").join("macos").join("README.txt"),
        ),
    ] {
        assert_eq!(
            fs::read(root.join(name)).expect("the volume's file"),
            fs::read(&source).expect("the repository's file"),
            "{name} is not {}",
            source.display()
        );
    }

    // 3. The signature.
    let app = root.join(dmg::APP);
    let app_arg = app.to_str().expect("a UTF-8 path");
    output("codesign", &["--verify", "--strict", "--deep", app_arg]);

    // 4. The stamp.
    let plist = app.join("Contents").join("Info.plist");
    let key = |name: &str| {
        output(
            "plutil",
            &[
                "-extract",
                name,
                "raw",
                "-o",
                "-",
                plist.to_str().expect("UTF-8"),
            ],
        )
        .trim()
        .to_owned()
    };
    let id = build_id::resolve(&StdEnv, &mut StdProcess, &workspace).expect("this build's ID");
    let sha = commit::resolve(&StdEnv, &mut StdProcess, &workspace).expect("this build's commit");
    let version = fs::read_to_string(workspace.join("lean").join("app").join("version"))
        .expect("lean/app/version");
    let version = version.lines().next().expect("a line");
    assert_eq!(
        key("CFBundleVersion"),
        named.as_str(),
        "the file name's build"
    );
    assert_eq!(key("CFBundleVersion"), id.as_str(), "this build's ID");
    assert_eq!(key("LeanmacsCommit"), sha.as_str(), "this build's commit");
    assert_eq!(
        key("CFBundleShortVersionString"),
        version,
        "lean/app/version"
    );

    // 5. What the app says of itself, with nothing from this environment.
    let executable = app.join("Contents").join("MacOS").join("editor");
    let said = output(
        "env",
        &["-i", executable.to_str().expect("UTF-8"), "--version"],
    );
    assert_eq!(
        said,
        format!("Leanmacs {version}\nbuild {id}\ncommit {sha}\n"),
        "editor --version"
    );
    // 6. A user's package set, built from the read-only volume alone.
    let config = dir.path().join("config");
    let home = dir.path().join("home");
    fs::create_dir_all(&config).expect("the config directory");
    fs::create_dir_all(&home).expect("the home directory");
    let generate = workspace.join("tests").join("headless").join("generate");
    fs::copy(
        generate.join("config").join("init.lean"),
        config.join("init.lean"),
    )
    .expect("init.lean");
    let launcher = app.join("Contents").join("MacOS").join("leanmacs");
    output(
        "env",
        &[
            "-i",
            launcher.to_str().expect("UTF-8"),
            "headless",
            "--generate",
            config.to_str().expect("UTF-8"),
            generate.join("script").to_str().expect("UTF-8"),
        ],
    );
    let resources = app.join("Contents").join("Resources");
    // As the editor names it: its own path with its links resolved.
    let set = fs::canonicalize(resources.join("lean").join("set")).expect("the volume's set");
    let lakefile = fs::read_to_string(config.join("lakefile.toml")).expect("a generated lakefile");
    assert_eq!(
        lakefile,
        fs::read_to_string(generate.join("expected-lakefile-bundle"))
            .expect("expected-lakefile-bundle")
            .replace("@SET@", set.to_str().expect("UTF-8")),
        "the generated lakefile names the volume's set"
    );
    let install = dir.path().join("install");
    let record = fs::read_to_string(resources.join("editor.build")).expect("editor.build");
    let lake = resources
        .join("lean")
        .join("toolchain")
        .join("bin")
        .join("lake");
    let built = Command::new(&lake)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", &home)
        .env("EDITOR_INSTALL_DIR", &install)
        .envs(record.lines().filter_map(|line| line.split_once('=')))
        .args([
            "-d",
            config.to_str().expect("UTF-8"),
            "build",
            ":editorInstall",
        ])
        .output()
        .expect("the volume's lake starts");
    assert!(
        built.status.success(),
        "the default set did not build from the volume: {}{}",
        String::from_utf8_lossy(&built.stdout),
        String::from_utf8_lossy(&built.stderr)
    );
    assert_eq!(
        fs::read(install.join("editor.core")).expect("the installed editor's core"),
        fs::read(resources.join("editor.core")).expect("the app's core"),
        "the editor built from the volume has the app's core"
    );
    let probe = output(
        install.join("editor").to_str().expect("UTF-8"),
        &["--probe"],
    );
    assert!(
        probe.lines().any(|line| line == "probe: ok"),
        "the editor built from the volume did not start: {probe}"
    );
    println!(
        "dmg-check: {} holds the app (build {id}, commit {sha}), the link, the licence and the README, and the default set built from the read-only volume alone",
        image.display()
    );
}
