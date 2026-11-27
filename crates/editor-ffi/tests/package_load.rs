//! The C function a package's glue calls to load its library
//! (`editor_ffi_package_load`), on real files, through the real adapter:
//! each refusal crosses as its tag and leaves the table unwritten, and the
//! two that compare versions cross both numbers. A path nothing is at
//! answers 1 (missing), a file that is no library 2 (not a library), a
//! library without a package's init, the fixture grammar library
//! (`editor-syntax-fixture-ini`), 3 (no init), and the fixture package
//! libraries (`editor-package-library-fixture`) 4 (runtime too small: an
//! init that requires a larger runtime than the core's), 5 (init failed:
//! an init that answers a status no library answers), each init called
//! with the process's real runtime, 6 (no declaration, or one whose `size`
//! ends before its `interface`), 7 (a declaration
//! needing a newer runtime, with what it needs and the editor's size) and
//! 8 (a library loaded for another interface than its declaration's, with
//! both versions). What a load decides is `editor-package-library`'s,
//! pinned there on the port's fake, and the adapter's answers by its
//! contract on the same fixtures; a library that loads is the fixture
//! package echo's, whose linked test loads it through its glue.
//!
//! An integration test of its own: the loader is the process's.

use std::ffi::c_void;
use std::path::Path;
use std::ptr;

use editor_ffi::package_library::editor_ffi_package_load;
use editor_package_library::runtime::{PackageRuntime, RUNTIME};
use editor_package_library_fixture as package;
use editor_syntax_fixture_ini as fixture;

/// The status of a load of `path` for a glue of interface `interface`
/// through the C function, whether it wrote the table, and the two numbers
/// it wrote into `versions`, which start as `[u64::MAX; 2]`.
fn load_expecting(path: &str, interface: u32) -> (u32, bool, [u64; 2]) {
    let mut table: *const c_void = ptr::null();
    let mut versions = [u64::MAX; 2];
    // SAFETY: the pointer and length are the string's, for the call, the
    // table's place is writable, and `versions` holds two.
    let status = unsafe {
        editor_ffi_package_load(
            path.as_ptr(),
            path.len(),
            interface,
            &raw mut table,
            versions.as_mut_ptr(),
        )
    };
    (status, !table.is_null(), versions)
}

/// The status of a load of `path` for a glue of interface 1, the fixture
/// libraries' own, and whether it wrote the table; the versions are
/// written for no refusal of these.
fn load(path: &str) -> (u32, bool) {
    let (status, table, versions) = load_expecting(path, 1);
    assert_eq!(versions, [u64::MAX; 2], "{path} wrote no versions");
    (status, table)
}

#[test]
fn each_refusal_of_a_load_through_c_crosses_as_its_tag_with_no_table() {
    let absent = Path::new(fixture::LIBRARY).with_file_name("libpackage-absent.so");
    let absent = absent.to_str().expect("a UTF-8 path");

    assert_eq!(load(absent), (1, false), "missing");
    assert_eq!(load("relative/libecho.so"), (1, false), "not absolute");
    assert_eq!(load(fixture::NOT_A_LIBRARY), (2, false), "not a library");
    assert_eq!(load(fixture::LIBRARY), (3, false), "no init");
    assert_eq!(
        load(package::RUNTIME_TOO_SMALL),
        (4, false),
        "runtime too small"
    );
    assert_eq!(load(package::INIT_FAILED), (5, false), "init failed");
}

#[test]
fn a_library_declaring_a_newer_runtime_crosses_as_7_with_what_it_needs_and_the_editor_s_size() {
    let needs = size_of::<PackageRuntime>() + size_of::<usize>();
    assert_eq!(
        load_expecting(package::NEWER_RUNTIME, 1),
        (7, false, [needs as u64, RUNTIME.size as u64])
    );
}

#[test]
fn a_library_loaded_for_another_interface_crosses_as_8_with_both_versions() {
    assert_eq!(
        load_expecting(package::CURRENT_RUNTIME, 2),
        (8, false, [1, 2])
    );
}

#[test]
fn a_library_declaring_nothing_crosses_as_6() {
    assert_eq!(load(package::NO_DECLARATION), (6, false));
}

#[test]
fn a_library_whose_declaration_ends_before_its_interface_crosses_as_6() {
    assert_eq!(load(package::SHORT_DECLARATION), (6, false));
}
