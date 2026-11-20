//! The real adapters held to the ports' contract (`editor_launch::contract`):
//! the file and clock properties the fakes pass, and the process properties
//! on real processes, with `launch-probe` as the helper and `leanmacs` as
//! the detached start's intermediate. Everything is written in a temporary
//! directory the test owns.

use std::path::PathBuf;

use editor_launch::contract::{check_clock, check_files, check_processes};
use editor_launch::ports::World;
use editor_launch_std::{StdClock, StdExec, StdFiles, StdPids, StdPlatform, StdSpawn};

#[test]
fn the_std_adapters_keep_the_files_and_clock_contract() {
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(check_files(&mut StdFiles, dir.path()), Vec::<&str>::new());
    assert_eq!(check_clock(&mut StdClock::default()), Vec::<&str>::new());
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
