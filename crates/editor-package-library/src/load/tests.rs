use std::path::PathBuf;
use std::sync::atomic::{AtomicPtr, Ordering};

use super::*;
use crate::contract::{self, Corpus};
use crate::fake::FakeLibraries;
use crate::library::InitFunction;
use crate::runtime::RUNTIME;

/// The table [`writes_its_table`] writes.
static TABLE: u64 = 0x7AB1E;

/// The runtime [`writes_its_table`] was handed, once it has been.
static HANDED: AtomicPtr<PackageRuntime> = AtomicPtr::new(ptr::null_mut());

/// An init that writes [`TABLE`] and answers 0, keeping the runtime it was
/// handed.
#[expect(
    unsafe_code,
    reason = "a test's init writes its table where the core says, as a library's does"
)]
extern "C" fn writes_its_table(runtime: *const PackageRuntime, table: *mut *const c_void) -> u32 {
    HANDED.store(runtime.cast_mut(), Ordering::SeqCst);
    // SAFETY: the core hands a writable pointer.
    unsafe { table.write(ptr::from_ref(&TABLE).cast()) };
    0
}

/// An init that finds the runtime too small.
extern "C" fn too_small(_: *const PackageRuntime, _: *mut *const c_void) -> u32 {
    1
}

/// An init that answers a status no library answers.
extern "C" fn answers_seven(_: *const PackageRuntime, _: *mut *const c_void) -> u32 {
    7
}

/// An init that answers 0 and writes no table.
extern "C" fn writes_none(_: *const PackageRuntime, _: *mut *const c_void) -> u32 {
    0
}

/// A fake with one library at `/l/lib.so` exporting `init` as the init
/// symbol, a library at `/l/other.so` exporting another symbol, and a file
/// that is no library at `/l/grammar.js`.
fn fake(init: InitFunction) -> FakeLibraries {
    FakeLibraries::new()
        .library("/l/lib.so", &[(INIT_SYMBOL, init)])
        .library("/l/other.so", &[("tree_sitter_ini", init)])
        .not_a_library("/l/grammar.js")
}

/// The load of `path` from `libraries` over the core's runtime.
fn loaded(libraries: &FakeLibraries, path: &str) -> Result<Table, LoadRefusal> {
    load(libraries, Path::new(path), &RUNTIME)
}

#[test]
fn a_relative_path_is_missing_with_nothing_opened() {
    let libraries = fake(writes_its_table);
    for path in ["lib.so", "l/lib.so"] {
        assert_eq!(
            loaded(&libraries, path),
            Err(LoadRefusal::Missing),
            "{path}"
        );
    }
    assert_eq!(libraries.opened(), [] as [PathBuf; 0]);
}

#[test]
fn an_absent_path_is_missing() {
    let libraries = fake(writes_its_table);
    assert_eq!(
        loaded(&libraries, "/l/absent.so"),
        Err(LoadRefusal::Missing)
    );
    assert_eq!(libraries.opened(), [PathBuf::from("/l/absent.so")]);
}

#[test]
fn a_file_that_is_no_library_is_not_a_library() {
    assert_eq!(
        loaded(&fake(writes_its_table), "/l/grammar.js"),
        Err(LoadRefusal::NotALibrary)
    );
}

#[test]
fn a_library_without_the_init_symbol_has_no_init() {
    assert_eq!(
        loaded(&fake(writes_its_table), "/l/other.so"),
        Err(LoadRefusal::NoInit)
    );
}

#[test]
fn an_init_that_answers_one_found_the_runtime_too_small() {
    assert_eq!(
        loaded(&fake(too_small), "/l/lib.so"),
        Err(LoadRefusal::RuntimeTooSmall)
    );
}

#[test]
fn an_init_that_answers_another_status_or_no_table_failed() {
    assert_eq!(
        loaded(&fake(answers_seven), "/l/lib.so"),
        Err(LoadRefusal::InitFailed)
    );
    assert_eq!(
        loaded(&fake(writes_none), "/l/lib.so"),
        Err(LoadRefusal::InitFailed)
    );
}

#[test]
fn an_init_that_answers_zero_is_loaded_with_its_table_and_was_handed_the_core_s_runtime() {
    let table = loaded(&fake(writes_its_table), "/l/lib.so").expect("loaded");
    assert_eq!(table.as_ptr(), ptr::from_ref(&TABLE).cast());
    assert_eq!(
        HANDED.load(Ordering::SeqCst).cast_const(),
        ptr::from_ref(&RUNTIME)
    );
}

#[test]
fn each_refusal_crosses_as_a_tag_of_its_own_and_none_is_a_load_s() {
    let tags = [
        LoadRefusal::Missing,
        LoadRefusal::NotALibrary,
        LoadRefusal::NoInit,
        LoadRefusal::RuntimeTooSmall,
        LoadRefusal::InitFailed,
    ]
    .map(LoadRefusal::tag);
    assert_eq!(tags, [1, 2, 3, 4, 5]);
}

#[test]
fn the_fake_the_load_is_tested_on_keeps_the_library_contract() {
    let corpus = Corpus {
        absent: "/l/absent.so".into(),
        not_a_library: "/l/grammar.js".into(),
        library: "/l/other.so".into(),
        exported: "tree_sitter_ini".to_owned(),
        not_exported: INIT_SYMBOL.to_owned(),
    };
    assert_eq!(contract::check(&fake(too_small), &corpus), [""; 0]);
}
