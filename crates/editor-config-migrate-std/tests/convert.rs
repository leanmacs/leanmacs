//! `config-migrate` run as the binary it is, in a temporary directory the
//! test owns: the wiring from a command line to the files of a config
//! directory and the exit status. What each conversion and refusal does is
//! `editor_config_migrate::migrate`'s, pinned by its own tests on the
//! fake; here only the files left and the status are read.

use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus};

use tempfile::TempDir;

/// Every file under `dir`, at any depth, relative to it, sorted.
#[expect(
    clippy::disallowed_methods,
    reason = "the binary's test: it lists the files the real `config-migrate` left in the test's directory"
)]
fn files_under(dir: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut pending = vec![PathBuf::new()];
    while let Some(rel) = pending.pop() {
        for entry in std::fs::read_dir(dir.join(&rel)).expect("a directory") {
            let entry = entry.expect("an entry");
            let path = rel.join(entry.file_name());
            if entry.file_type().expect("its type").is_dir() {
                pending.push(path);
            } else {
                found.push(path);
            }
        }
    }
    found.sort();
    found
}

/// `config-migrate` run with `args`, with neither variable of the default
/// directory set.
#[expect(
    clippy::disallowed_methods,
    reason = "the binary's test: it runs the real `config-migrate`"
)]
fn config_migrate(args: &[&Path]) -> ExitStatus {
    Command::new(env!("CARGO_BIN_EXE_config-migrate"))
        .args(args)
        .env_remove("XDG_CONFIG_HOME")
        .env_remove("HOME")
        .status()
        .expect("config-migrate runs")
}

#[test]
#[expect(
    clippy::disallowed_methods,
    reason = "the binary's test: it copies the checked-in fixture into the test's directory and reads what the real `config-migrate` left"
)]
fn the_binary_converts_a_copy_of_the_chunks_fixture() {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/config-migrate/chunks");
    let dir = TempDir::new().expect("a temporary directory");
    let config = dir.path().join("config");
    std::fs::create_dir(&config).expect("the config directory");
    for name in ["05-leader.lean", "90-setup.lean"] {
        std::fs::copy(fixture.join(name), config.join(name)).expect("a fixture file");
    }
    assert!(config_migrate(&[&config]).success());
    assert_eq!(
        files_under(&config),
        [
            PathBuf::from("Config/Leader.lean"),
            PathBuf::from("init.lean")
        ]
    );
    let leader = std::fs::read_to_string(config.join("Config/Leader.lean")).expect("Leader");
    assert!(
        leader.starts_with("import Editor\nopen Editor\n\n-- A config"),
        "{leader}"
    );
    let root = std::fs::read_to_string(config.join("init.lean")).expect("init.lean");
    assert!(
        root.starts_with("import Editor\nimport Config.Leader\nopen Editor\n\n"),
        "{root}"
    );
}

#[test]
#[expect(
    clippy::disallowed_methods,
    reason = "the binary's test: it writes a config in the test's directory and reads it back after the real `config-migrate` refused it"
)]
fn a_refused_directory_is_left_as_it_was_with_status_1() {
    let dir = TempDir::new().expect("a temporary directory");
    let config = dir.path();
    std::fs::write(config.join("10-a.lean"), "def a : Nat := 1\n").expect("a file");
    std::fs::write(config.join("init.lean"), "def setup := pure ()\n").expect("a root");
    assert_eq!(config_migrate(&[config]).code(), Some(1));
    assert_eq!(
        files_under(config),
        [PathBuf::from("10-a.lean"), PathBuf::from("init.lean")]
    );
    assert_eq!(
        std::fs::read_to_string(config.join("10-a.lean")).expect("10-a.lean"),
        "def a : Nat := 1\n"
    );
}

#[test]
fn a_command_line_it_does_not_take_exits_2() {
    assert_eq!(
        config_migrate(&[Path::new("a"), Path::new("b")]).code(),
        Some(2)
    );
    assert_eq!(config_migrate(&[Path::new("--help")]).code(), Some(2));
}
