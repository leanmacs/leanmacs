//! The library port's contract: what every [`Libraries`] keeps, so the
//! load's tests on the fake hold of the real adapter too.
//!
//! [`check`] opens the paths of a [`Corpus`] (one nothing is at, a file
//! that is no library, and a library) and asks the library for a symbol it
//! exports and one it does not, and returns the names of the properties
//! that fail. It never calls what it finds.
//!
//! It is held against the fake ([`crate::fake::FakeLibraries`]) in this
//! module's tests, where each property is seen to bite on a fake canned to
//! break it, and against the real adapter on the fixture grammar library
//! (`crates/editor-package-library-libloading/tests/contract.rs`, over
//! `editor-syntax-fixture-ini`).

use std::path::PathBuf;

use crate::library::{Libraries, Unopened};

/// What the contract opens: owned paths, since a real adapter's fixture
/// paths are known only at run time.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Corpus {
    /// An absolute path nothing is at.
    pub absent: PathBuf,
    /// An absolute path of a file that is no library.
    pub not_a_library: PathBuf,
    /// An absolute path of a library.
    pub library: PathBuf,
    /// A symbol the library exports.
    pub exported: String,
    /// A symbol the library does not export.
    pub not_exported: String,
}

/// A path nothing is at is missing.
pub const ABSENT: &str = "a path nothing is at is missing";
/// A file that is no library is refused as not a library.
pub const NOT_A_LIBRARY: &str = "a file that is no library is refused as not a library";
/// A library opens.
pub const OPENS: &str = "a library opens";
/// A symbol the library exports is found.
pub const FINDS: &str = "a symbol the library exports is found";
/// A symbol the library does not export is none.
pub const LACKS: &str = "a symbol the library does not export is none";

/// The contract's properties.
pub const PROPERTIES: [&str; 5] = [ABSENT, NOT_A_LIBRARY, OPENS, FINDS, LACKS];

/// The names of the properties `libraries` fails over `corpus`: none when
/// it keeps them all.
pub fn check(libraries: &dyn Libraries, corpus: &Corpus) -> Vec<&'static str> {
    let mut failed = Vec::new();
    if libraries.open(&corpus.absent).err() != Some(Unopened::Missing) {
        failed.push(ABSENT);
    }
    if libraries.open(&corpus.not_a_library).err() != Some(Unopened::NotALibrary) {
        failed.push(NOT_A_LIBRARY);
    }
    match libraries.open(&corpus.library) {
        Ok(library) => {
            if library.init(&corpus.exported).is_none() {
                failed.push(FINDS);
            }
            if library.init(&corpus.not_exported).is_some() {
                failed.push(LACKS);
            }
        }
        Err(_) => failed.extend([OPENS, FINDS, LACKS]),
    }
    failed
}

#[cfg(test)]
mod tests {
    use std::ffi::c_void;

    use super::*;
    use crate::fake::FakeLibraries;
    use crate::runtime::PackageRuntime;

    /// An init the contract never calls: called, it would answer neither
    /// status a library answers.
    extern "C" fn never(_: *const PackageRuntime, _: *mut *const c_void) -> u32 {
        9
    }

    /// The corpus over the fake's paths.
    fn corpus() -> Corpus {
        Corpus {
            absent: "/l/absent.so".into(),
            not_a_library: "/l/grammar.js".into(),
            library: "/l/libx.so".into(),
            exported: "x_init".to_owned(),
            not_exported: "editor_package_init".to_owned(),
        }
    }

    #[test]
    fn the_fake_keeps_the_contract() {
        let fake = FakeLibraries::new()
            .not_a_library("/l/grammar.js")
            .library("/l/libx.so", &[("x_init", never)]);
        assert_eq!(check(&fake, &corpus()), [""; 0]);
    }

    #[test]
    fn each_property_bites_on_a_fake_canned_to_break_it() {
        let nothing = FakeLibraries::new();
        assert_eq!(
            check(&nothing, &corpus()),
            [NOT_A_LIBRARY, OPENS, FINDS, LACKS]
        );
        let everything = FakeLibraries::new()
            .not_a_library("/l/absent.so")
            .not_a_library("/l/grammar.js")
            .library(
                "/l/libx.so",
                &[("editor_package_init", never), ("y_init", never)],
            );
        assert_eq!(check(&everything, &corpus()), [ABSENT, FINDS, LACKS]);
    }
}
