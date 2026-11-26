//! The `std::fs` adapter held to the files port's contract
//! (`editor_config_migrate::contract::check_files`), the one the core's
//! fake passes, in a temporary directory the test owns.

use editor_config_migrate::contract::check_files;
use editor_config_migrate_std::StdFiles;
use tempfile::TempDir;

#[test]
fn the_std_files_keep_the_files_contract() {
    let dir = TempDir::new().expect("a temporary directory");
    assert_eq!(check_files(&mut StdFiles, dir.path()), Vec::<&str>::new());
}
