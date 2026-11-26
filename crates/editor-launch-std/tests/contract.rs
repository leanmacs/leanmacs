//! The real adapters held to the ports' contract (`editor_launch::contract`):
//! the file and clock properties the fakes pass, the variable property in
//! a `launch-probe` started with the variables it needs, and the process
//! properties on real processes, with `launch-probe` as the helper and
//! `leanmacs` as the detached start's intermediate. Everything is written
//! in a temporary directory the test owns, and no test changes its own
//! environment.

use std::path::PathBuf;
use std::process::Command;

use editor_launch::contract::{
    PLATFORM_VAR, VAR_EMPTY, VAR_SET, VAR_UNSET, VAR_VALUE, check_clock, check_files,
    check_processes,
};
use editor_launch::ports::World;
use editor_launch_std::{StdClock, StdExec, StdFiles, StdPids, StdPlatform, StdSpawn};

#[test]
fn the_std_adapters_keep_the_files_and_clock_contract() {
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(check_files(&mut StdFiles, dir.path()), Vec::<&str>::new());
    assert_eq!(check_clock(&mut StdClock::default()), Vec::<&str>::new());
}

/// `StdPlatform::var` reads the process's own environment, which a test
/// cannot set without racing every other test of the process. So the
/// check runs in `launch-probe --contract-var`, started with the
/// contract's variables set and unset for it alone, and prints the names
/// of the properties that fail.
#[test]
#[expect(
    clippy::disallowed_methods,
    reason = "the variable property runs in a real probe process, so the test's own environment is left as it was"
)]
fn the_std_platform_keeps_the_variable_contract() {
    let output = Command::new(env!("CARGO_BIN_EXE_launch-probe"))
        .arg("--contract-var")
        .env(VAR_SET, VAR_VALUE)
        .env(VAR_EMPTY, "")
        .env_remove(VAR_UNSET)
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    assert_eq!(String::from_utf8_lossy(&output.stdout), "");
    let unset = Command::new(env!("CARGO_BIN_EXE_launch-probe"))
        .arg("--contract-var")
        .env_remove(VAR_SET)
        .output()
        .unwrap();
    assert_eq!(
        String::from_utf8_lossy(&unset.stdout),
        format!("{PLATFORM_VAR}\n")
    );
}

#[test]
fn the_std_adapters_keep_the_process_contract() {
    let dir = tempfile::tempdir().unwrap();
    let helper = PathBuf::from(env!("CARGO_BIN_EXE_launch-probe"));
    let mut spawn = StdSpawn {
        via: PathBuf::from(env!("CARGO_BIN_EXE_leanmacs")),
    };
    let mut world = World {
        files: &mut StdFiles,
        clock: &mut StdClock::default(),
        pids: &mut StdPids,
        spawn: &mut spawn,
        exec: &mut StdExec,
        platform: &mut StdPlatform::new().unwrap(),
    };
    assert_eq!(
        check_processes(&mut world, &helper, dir.path()),
        Vec::<&str>::new()
    );
}
