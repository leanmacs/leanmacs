//! `link-stubs` run as the binary it is, on a real executable: a copy of
//! itself, a thin arm64 Mach-O, in a temporary directory the test owns.
//! It is the one check that what `lipo`, `otool`, `nm` and `vtool` print
//! parses; what the stubs hold is `editor_release::stubs`'s, pinned by its
//! own tests on canned output. macOS only, as the tools are.
#![cfg(target_os = "macos")]

use std::path::{Path, PathBuf};
use std::process::Command;

use tempfile::TempDir;

/// Every file under `dir`, at any depth.
#[expect(
    clippy::disallowed_methods,
    reason = "the binary's test: it lists the stubs the real `link-stubs` wrote in the test's directory"
)]
fn files_under(dir: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    for entry in std::fs::read_dir(dir).expect("the out directory") {
        let path = entry.expect("an entry").path();
        if path.is_dir() {
            found.extend(files_under(&path));
        } else {
            found.push(path);
        }
    }
    found
}

#[test]
#[expect(
    clippy::disallowed_methods,
    reason = "the binary's test: it copies the real `link-stubs` into the test's directory, runs it there and reads what it wrote"
)]
fn the_binary_writes_platform_version_and_stubs_from_a_real_executable() {
    let dir = TempDir::new().expect("a temporary directory");
    let executable = dir.path().join("linked");
    std::fs::copy(env!("CARGO_BIN_EXE_link-stubs"), &executable).expect("a copy of the binary");
    let out = dir.path().join("stubs");
    let status = Command::new(env!("CARGO_BIN_EXE_link-stubs"))
        .arg(&executable)
        .arg(&out)
        .status()
        .expect("link-stubs runs");
    assert!(status.success(), "link-stubs exited {status}");

    let platform = std::fs::read_to_string(out.join("platform-version")).expect("platform-version");
    assert_eq!(platform.split_whitespace().count(), 2, "{platform:?}");
    assert!(!out.join("libSystem.tbd").exists());
    for stub in files_under(&out)
        .into_iter()
        .filter(|path| path.extension().is_some_and(|e| e == "tbd"))
    {
        let text = std::fs::read_to_string(&stub).expect("a stub");
        assert!(text.starts_with("--- !tapi-tbd\n"), "{}", stub.display());
    }
}
