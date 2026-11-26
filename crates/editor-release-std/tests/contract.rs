//! The real adapters held to their ports' contracts. The `std::process`
//! adapter runs real programs: the same check the core's fake passes
//! (`editor_release::contract::check_process`). Its programs are `true`,
//! `false` and `printf`, and a path nothing is at; none writes a file. The
//! `std::fs` adapter runs the files contract
//! (`editor_release::contract::check_files`) in a temporary directory the
//! test owns.

use editor_release::contract::{check_files, check_process};
use editor_release_std::{StdFiles, StdProcess};
use tempfile::TempDir;

#[test]
fn the_std_adapter_keeps_the_process_contract() {
    assert_eq!(check_process(&mut StdProcess), Vec::<&str>::new());
}

#[test]
fn the_std_files_keep_the_files_contract() {
    let dir = TempDir::new().expect("a temporary directory");
    assert_eq!(check_files(&mut StdFiles, dir.path()), Vec::<&str>::new());
}
