//! The port's contract held against the adapter on real files, in a
//! temporary directory the test owns.

use std::io::Write as _;
use std::path::Path;

use editor_grep::contract::{self, Ground};
use editor_grep_ripgrep::RipgrepFiles;

/// The ground: `std::fs`, asked directly. An exclusion is a line of the
/// `.ignore` file in the excluded path's directory.
struct System;

impl Ground for System {
    #[expect(
        clippy::disallowed_methods,
        reason = "the contract's ground writes real files, in a temporary directory the test owns"
    )]
    fn write(&self, path: &Path, bytes: &[u8]) {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("the check's directory is made");
        }
        std::fs::write(path, bytes).expect("the check's file is written");
    }

    #[expect(
        clippy::disallowed_methods,
        reason = "the contract's ground writes real files, in a temporary directory the test owns"
    )]
    fn make_dir(&self, path: &Path) {
        std::fs::create_dir_all(path).expect("the check's directory is made");
    }

    #[expect(
        clippy::disallowed_types,
        reason = "the contract's ground writes real files, in a temporary directory the test owns"
    )]
    fn exclude(&self, path: &Path) {
        let (Some(parent), Some(name)) = (path.parent(), path.file_name()) else {
            panic!("an excluded path has a directory and a name");
        };
        let mut ignore = std::fs::OpenOptions::new()
            .append(true)
            .create(true)
            .open(parent.join(".ignore"))
            .expect("the check's .ignore is opened");
        writeln!(ignore, "/{}", name.to_string_lossy()).expect("the check's .ignore is written");
    }
}

#[test]
#[expect(
    clippy::disallowed_methods,
    reason = "the adapter's contract check: the real files are what it holds to the port"
)]
fn the_adapter_keeps_the_files_ports_contract_on_real_files_in_a_temporary_directory() {
    let dir = tempfile::tempdir().expect("a temporary directory");

    let failures = contract::check(&RipgrepFiles::new(), &System, dir.path());

    assert_eq!(failures, [""; 0]);
}
