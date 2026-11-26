//! The nightly, prepared from a real disk image: `mise run nightly-check`,
//! never part of the gate (it mounts an image, on macOS only).
//!
//! In a temporary directory it owns, the test stages a tiny
//! `Leanmacs.app/Contents/Info.plist` holding a stamp, written with
//! `plutil`, packs it with `hdiutil create` as `Leanmacs-<id>.dmg`, and
//! runs `editor_release::nightly::prepare` through [`StdProcess`], then
//! [`write_prepared`]:
//!
//! 1. for the stamp's own build and commit, the output directory holds
//!    exactly the two images, `Leanmacs.dmg.sha256`, `build.json` and
//!    `notes.md`; `shasum -a 256 -c` passes on the checksum file;
//!    `read_build` reads the build back from the files; and the image is
//!    detached;
//! 2. for another commit, `prepare` refuses with the stamp's mismatch,
//!    copies nothing, and the image is detached all the same.
//!
//! It writes nothing outside the temporary directory.

use std::fs;
use std::path::Path;
use std::process::Command;

use editor_release::build_id::BuildId;
use editor_release::commit::Commit;
use editor_release::nightly::{self, Inputs, PrepareError, Repo, Server, StampError, Target};
use editor_release_std::{StdProcess, write_prepared};
use tempfile::TempDir;

const ID: &str = "20010203040506";
const SHA: &str = "0123456789abcdef0123456789abcdef01234567";

/// Runs a program to success and returns its standard output.
#[expect(
    clippy::disallowed_methods,
    reason = "the adapter's test on a real disk image, built and mounted in a temporary directory it owns"
)]
fn output(program: &str, args: &[&str], dir: Option<&Path>) -> String {
    let mut command = Command::new(program);
    command.args(args);
    if let Some(dir) = dir {
        command.current_dir(dir);
    }
    let out = command
        .output()
        .unwrap_or_else(|e| panic!("{program} {args:?} cannot start: {e}"));
    assert!(out.status.success(), "{program} {args:?} failed: {out:?}");
    String::from_utf8(out.stdout).expect("UTF-8")
}

fn utf8(path: &Path) -> &str {
    path.to_str().expect("a UTF-8 path")
}

/// Whether anything is mounted at `point`, by `hdiutil info`.
#[expect(
    clippy::disallowed_methods,
    reason = "the adapter's test on a real disk image, built and mounted in a temporary directory it owns"
)]
fn mounted(point: &Path) -> bool {
    let info = output("hdiutil", &["info"], None);
    let canonical = point.canonicalize().unwrap_or_else(|_| point.to_owned());
    [point, canonical.as_path()]
        .iter()
        .any(|p| info.lines().any(|l| l.trim_end().ends_with(utf8(p))))
}

/// The image `<dir>/dist/Leanmacs-<ID>.dmg`, whose app is stamped with
/// [`ID`], [`SHA`] and the core's tag `nightly-<ID>`.
#[expect(
    clippy::disallowed_methods,
    reason = "the adapter's test on a real disk image, built and mounted in a temporary directory it owns"
)]
fn image(dir: &Path) -> std::path::PathBuf {
    let contents = dir.join("stage").join("Leanmacs.app").join("Contents");
    fs::create_dir_all(&contents).expect("the staged bundle");
    let plist = contents.join("Info.plist");
    let plist = utf8(&plist);
    output("plutil", &["-create", "xml1", plist], None);
    output(
        "plutil",
        &["-insert", "CFBundleVersion", "-string", ID, plist],
        None,
    );
    output(
        "plutil",
        &["-insert", "LeanmacsCommit", "-string", SHA, plist],
        None,
    );
    output(
        "plutil",
        &[
            "-insert",
            "LeanmacsCoreTag",
            "-string",
            &format!("nightly-{ID}"),
            plist,
        ],
        None,
    );
    let dist = dir.join("dist");
    fs::create_dir_all(&dist).expect("dist");
    let image = dist.join(format!("Leanmacs-{ID}.dmg"));
    output(
        "hdiutil",
        &[
            "create",
            "-quiet",
            "-volname",
            "Leanmacs",
            "-srcfolder",
            utf8(&dir.join("stage")),
            "-fs",
            "HFS+",
            "-format",
            "UDZO",
            "-ov",
            utf8(&image),
        ],
        None,
    );
    image
}

fn target() -> Target {
    Target {
        server: Server::parse("https://github.com").expect("a server"),
        repo: Repo::parse("leanmacs/leanmacs").expect("a repo"),
    }
}

#[test]
#[ignore = "mounts a disk image, on macOS: mise run nightly-check"]
#[expect(
    clippy::disallowed_methods,
    reason = "the adapter's test on a real disk image, built and mounted in a temporary directory it owns"
)]
fn prepare_checks_a_real_image_and_writes_the_five_files() {
    let dir = TempDir::new().expect("a temporary directory");
    let image = image(dir.path());
    let (mount_point, out) = (dir.path().join("mnt"), dir.path().join("out"));
    fs::create_dir_all(&mount_point).expect("the mount point");
    fs::create_dir_all(&out).expect("the output directory");
    let size = fs::metadata(&image).expect("the image").len();
    let inputs = Inputs {
        image: &image,
        size,
        mount_point: &mount_point,
        out: &out,
    };
    let (id, sha) = (
        BuildId::parse(ID).expect("an ID"),
        Commit::parse(SHA).expect("a commit"),
    );

    // 1. This build's stamp.
    let prepared =
        nightly::prepare(&mut StdProcess, &inputs, &id, &sha, &target()).expect("prepared");
    write_prepared(&out, &prepared).expect("written");
    assert!(!mounted(&mount_point), "the image is still mounted");
    let mut names: Vec<String> = fs::read_dir(&out)
        .expect("the output directory")
        .map(|e| {
            e.expect("an entry")
                .file_name()
                .to_string_lossy()
                .into_owned()
        })
        .collect();
    names.sort();
    assert_eq!(
        names,
        [
            "Leanmacs-20010203040506.dmg",
            "Leanmacs.dmg",
            "Leanmacs.dmg.sha256",
            "build.json",
            "notes.md"
        ]
    );
    output(
        "shasum",
        &["-a", "256", "-c", "Leanmacs.dmg.sha256"],
        Some(&out),
    );
    let read = |name: &str| fs::read_to_string(out.join(name)).expect("a text");
    let build = nightly::read_build(
        &read("build.json"),
        &read("Leanmacs.dmg.sha256"),
        fs::metadata(out.join("Leanmacs.dmg"))
            .expect("the image")
            .len(),
        &id,
        &sha,
    )
    .expect("the build read back");
    assert_eq!(build, prepared.build);
    assert_eq!(build.size, size);
    assert_eq!(
        fs::read(out.join("Leanmacs-20010203040506.dmg")).expect("the copy"),
        fs::read(&image).expect("the image")
    );

    // 2. Another commit: refused, nothing copied, detached.
    let other_out = dir.path().join("other");
    fs::create_dir_all(&other_out).expect("another output directory");
    let other = Commit::parse("fedcba9876543210fedcba9876543210fedcba98").expect("a commit");
    let error = nightly::prepare(
        &mut StdProcess,
        &Inputs {
            out: &other_out,
            ..inputs
        },
        &id,
        &other,
        &target(),
    )
    .expect_err("another commit");
    assert!(
        matches!(error, PrepareError::Stamp(StampError::Commit { .. })),
        "{error}"
    );
    assert!(!mounted(&mount_point), "the image is still mounted");
    assert_eq!(
        fs::read_dir(&other_out).expect("the directory").count(),
        0,
        "something was copied"
    );
    println!(
        "nightly-check: prepare checked {} and wrote the five files",
        image.display()
    );
}
