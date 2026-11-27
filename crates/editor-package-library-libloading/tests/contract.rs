//! The adapter keeps the library port's contract on real files: the
//! fixture grammar library (`editor-syntax-fixture-ini`) opens and finds
//! the symbol it exports, `tree_sitter_ini`, and not a package's init;
//! its grammar's source is a file that is no library; and a path beside the
//! library that is never made is missing.
//!
//! The check is the port's own, the one the fake keeps
//! (`editor_package_library::contract::check`). No file is created.

use std::path::{Path, PathBuf};

use editor_package_library::contract::{Corpus, check};
use editor_package_library::load::INIT_SYMBOL;
use editor_package_library_libloading::LibLoading;
use editor_syntax_fixture_ini as fixture;

/// A path beside the fixture library, of its kind, that is never made.
fn absent_library() -> PathBuf {
    let library = Path::new(fixture::LIBRARY);
    let extension = library
        .extension()
        .and_then(|extension| extension.to_str())
        .unwrap_or("so");
    library.with_file_name(format!("libpackage-absent.{extension}"))
}

#[test]
fn the_adapter_keeps_the_library_contract_on_the_fixture_library() {
    let corpus = Corpus {
        absent: absent_library(),
        not_a_library: fixture::NOT_A_LIBRARY.into(),
        library: fixture::LIBRARY.into(),
        exported: fixture::SYMBOL.to_owned(),
        not_exported: INIT_SYMBOL.to_owned(),
    };
    #[expect(
        clippy::disallowed_methods,
        reason = "the adapter's contract test opens real libraries, which is the adapter's job"
    )]
    let libraries = LibLoading::system();
    assert_eq!(check(&libraries, &corpus), [""; 0]);
}
