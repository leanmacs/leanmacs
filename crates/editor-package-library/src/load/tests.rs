use std::path::PathBuf;
use std::sync::atomic::{AtomicPtr, AtomicUsize, Ordering};

use super::*;
use crate::contract::{self, Corpus};
use crate::fake::FakeLibraries;
use crate::library::{PackageDeclaration, PackageInit};
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

/// The declaration of a library built for the core's runtime and
/// interface 1.
const CURRENT: PackageDeclaration = PackageDeclaration {
    size: size_of::<PackageDeclaration>(),
    runtime: size_of::<PackageRuntime>(),
    interface: 1,
};

/// A fake with one library at `/l/lib.so` exporting `init` as the init
/// symbol and [`CURRENT`] as its declaration, a library at `/l/other.so`
/// exporting another symbol, and a file that is no library at
/// `/l/grammar.js`.
fn fake(init: PackageInit) -> FakeLibraries {
    FakeLibraries::new()
        .library("/l/lib.so", &[(INIT_SYMBOL, init)])
        .declaring("/l/lib.so", CURRENT)
        .library("/l/other.so", &[("tree_sitter_ini", init)])
        .not_a_library("/l/grammar.js")
}

/// The load of `path` from `libraries` over the core's runtime, for a glue
/// of interface 1.
fn loaded(libraries: &FakeLibraries, path: &str) -> Result<Table, LoadRefusal> {
    load(libraries, Path::new(path), 1, &RUNTIME)
}

/// An init that counts its calls in `$calls`, writes [`TABLE`] and answers
/// 0: one of its own for each test that says an init never ran, since the
/// tests run side by side.
macro_rules! counted {
    ($init:ident, $calls:ident) => {
        /// How many times the init beside it was called.
        static $calls: AtomicUsize = AtomicUsize::new(0);

        /// An init that counts its calls, writes its table and answers 0.
        #[expect(
            unsafe_code,
            reason = "a test's init writes its table where the core says, as a library's does"
        )]
        extern "C" fn $init(_: *const PackageRuntime, table: *mut *const c_void) -> u32 {
            $calls.fetch_add(1, Ordering::SeqCst);
            // SAFETY: the core hands a writable pointer.
            unsafe { table.write(ptr::from_ref(&TABLE).cast()) };
            0
        }
    };
}

/// A fake with one library at `/l/lib.so` exporting `init` and declaring
/// `declaration`, or nothing.
fn declaring(init: PackageInit, declaration: Option<PackageDeclaration>) -> FakeLibraries {
    let libraries = FakeLibraries::new().library("/l/lib.so", &[(INIT_SYMBOL, init)]);
    match declaration {
        Some(declaration) => libraries.declaring("/l/lib.so", declaration),
        None => libraries,
    }
}

counted!(other_interface_init, OTHER_INTERFACE_CALLS);

#[test]
fn a_library_declaring_another_interface_is_refused_with_both_versions_and_its_init_never_runs() {
    let libraries = declaring(
        other_interface_init,
        Some(PackageDeclaration {
            interface: 2,
            ..CURRENT
        }),
    );
    assert_eq!(
        loaded(&libraries, "/l/lib.so"),
        Err(LoadRefusal::OtherInterface {
            declared: 2,
            expected: 1
        })
    );
    assert_eq!(OTHER_INTERFACE_CALLS.load(Ordering::SeqCst), 0);
}

counted!(newer_runtime_init, NEWER_RUNTIME_CALLS);

#[test]
fn a_library_declaring_a_newer_runtime_is_refused_with_what_it_needs_and_the_runtime_s_size_and_its_init_never_runs()
 {
    let needs = size_of::<PackageRuntime>() + size_of::<usize>();
    let libraries = declaring(
        newer_runtime_init,
        Some(PackageDeclaration {
            runtime: needs,
            ..CURRENT
        }),
    );
    assert_eq!(
        loaded(&libraries, "/l/lib.so"),
        Err(LoadRefusal::NewerRuntime {
            needs,
            has: RUNTIME.size
        })
    );
    assert_eq!(NEWER_RUNTIME_CALLS.load(Ordering::SeqCst), 0);
}

counted!(undeclared_init, UNDECLARED_CALLS);

#[test]
fn a_library_with_no_declaration_is_refused_and_its_init_never_runs() {
    assert_eq!(
        loaded(&declaring(undeclared_init, None), "/l/lib.so"),
        Err(LoadRefusal::NoDeclaration)
    );
    assert_eq!(UNDECLARED_CALLS.load(Ordering::SeqCst), 0);
}

counted!(short_declaration_init, SHORT_DECLARATION_CALLS);

#[test]
fn a_declaration_ending_before_its_interface_is_refused_as_none() {
    let libraries = declaring(
        short_declaration_init,
        Some(PackageDeclaration {
            size: DECLARATION_REQUIRED - 1,
            ..CURRENT
        }),
    );
    assert_eq!(
        loaded(&libraries, "/l/lib.so"),
        Err(LoadRefusal::NoDeclaration)
    );
    assert_eq!(SHORT_DECLARATION_CALLS.load(Ordering::SeqCst), 0);
}

counted!(older_runtime_init, OLDER_RUNTIME_CALLS);

#[test]
fn a_library_declaring_an_older_runtime_and_the_same_interface_loads() {
    let through_complete = 4 * size_of::<usize>();
    let libraries = declaring(
        older_runtime_init,
        Some(PackageDeclaration {
            runtime: through_complete,
            ..CURRENT
        }),
    );
    let table = loaded(&libraries, "/l/lib.so").expect("loaded");
    assert_eq!(table.as_ptr(), ptr::from_ref(&TABLE).cast());
    assert_eq!(OLDER_RUNTIME_CALLS.load(Ordering::SeqCst), 1);
}

counted!(longer_declaration_init, LONGER_DECLARATION_CALLS);

#[test]
fn a_later_longer_declaration_is_read_by_the_members_it_knows() {
    let libraries = declaring(
        longer_declaration_init,
        Some(PackageDeclaration {
            size: size_of::<PackageDeclaration>() + size_of::<usize>(),
            ..CURRENT
        }),
    );
    assert!(loaded(&libraries, "/l/lib.so").is_ok());
    assert_eq!(LONGER_DECLARATION_CALLS.load(Ordering::SeqCst), 1);
}

#[test]
fn each_refusal_crosses_as_its_tag_and_only_the_versioned_ones_carry_versions() {
    let refusals = [
        LoadRefusal::Missing,
        LoadRefusal::NotALibrary,
        LoadRefusal::NoInit,
        LoadRefusal::RuntimeTooSmall,
        LoadRefusal::InitFailed,
        LoadRefusal::NoDeclaration,
        LoadRefusal::NewerRuntime { needs: 96, has: 88 },
        LoadRefusal::OtherInterface {
            declared: 2,
            expected: 1,
        },
    ];
    assert_eq!(refusals.map(LoadRefusal::tag), [1, 2, 3, 4, 5, 6, 7, 8]);
    assert_eq!(
        refusals.map(LoadRefusal::versions),
        [
            None,
            None,
            None,
            None,
            None,
            None,
            Some((96, 88)),
            Some((2, 1))
        ]
    );
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
fn the_fake_the_load_is_tested_on_keeps_the_library_contract() {
    let corpus = Corpus {
        absent: "/l/absent.so".into(),
        not_a_library: "/l/grammar.js".into(),
        library: "/l/other.so".into(),
        exported: "tree_sitter_ini".to_owned(),
        not_exported: INIT_SYMBOL.to_owned(),
        declaring: "/l/lib.so".into(),
        declaration: CURRENT,
    };
    assert_eq!(contract::check(&fake(too_small), &corpus), [""; 0]);
}
