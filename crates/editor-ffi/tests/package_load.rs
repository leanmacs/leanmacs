//! The C function a package's glue calls to load its library
//! (`editor_ffi_package_load`), on real files, through the real adapter:
//! each refusal crosses as its tag and leaves the table unwritten. A path
//! nothing is at answers 1 (missing), a file that is no library 2 (not a
//! library), and a library without a package's init, the fixture grammar
//! library (`editor-syntax-fixture-ini`), 3 (no init). What a load decides
//! is `editor-package-library`'s, pinned there on the port's fake, and the
//! adapter's answers by its contract on the same fixture; a library that
//! loads is the fixture package echo's, whose linked test loads it through
//! its glue.
//!
//! An integration test of its own: the loader is the process's.

use std::ffi::c_void;
use std::path::Path;
use std::ptr;

use editor_ffi::package_library::editor_ffi_package_load;
use editor_syntax_fixture_ini as fixture;

/// The status of a load of `path` through the C function, and whether it
/// wrote the table.
fn load(path: &str) -> (u32, bool) {
    let mut table: *const c_void = ptr::null();
    // SAFETY: the pointer and length are the string's, for the call, and
    // the table's place is writable.
    let status = unsafe { editor_ffi_package_load(path.as_ptr(), path.len(), &raw mut table) };
    (status, !table.is_null())
}

#[test]
fn each_refusal_of_a_load_through_c_crosses_as_its_tag_with_no_table() {
    let absent = Path::new(fixture::LIBRARY).with_file_name("libpackage-absent.so");
    let absent = absent.to_str().expect("a UTF-8 path");

    assert_eq!(load(absent), (1, false), "missing");
    assert_eq!(load("relative/libecho.so"), (1, false), "not absolute");
    assert_eq!(load(fixture::NOT_A_LIBRARY), (2, false), "not a library");
    assert_eq!(load(fixture::LIBRARY), (3, false), "no init");
}
