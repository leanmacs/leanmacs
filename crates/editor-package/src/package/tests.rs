use std::mem::size_of;

use editor_package_runtime::INIT_RUNTIME_TOO_SMALL;

use super::*;
use crate::REQUIRED;
use crate::Service;
use crate::fake::FakeRuntime;

/// A package's state: the service its init registers.
#[derive(Debug)]
struct State {
    /// The service.
    service: Service,
}

/// A package's init: it registers one service, so a fake's registrations
/// count how many times it ran there.
fn init(runtime: Runtime) -> State {
    State {
        service: runtime.register("tested"),
    }
}

/// A package's own table, opaque to the core.
#[repr(C)]
#[derive(Debug)]
struct Functions {
    /// A word, to give the table a size of its own.
    word: u64,
    /// A function, as a table holds them.
    function: extern "C" fn() -> u32,
}

/// The function of [`Functions`].
extern "C" fn seven() -> u32 {
    7
}

/// A package of its own for each test, kept for the process as a
/// library's static is.
fn package() -> &'static Package<State, Functions> {
    Box::leak(Box::new(Package::new(
        init,
        Functions {
            word: 3,
            function: seven,
        },
    )))
}

/// The export's answer for `runtime`, and the table it wrote, if any.
#[expect(
    unsafe_code,
    reason = "calls the export as a library's init does, on a null runtime or one that lives for the process, with a writable place"
)]
fn export(
    package: &'static Package<State, Functions>,
    runtime: *const PackageRuntime,
) -> (u32, *const c_void) {
    let mut table: *const c_void = ptr::null();
    // SAFETY: the runtime is null or a fake's, leaked, as long as its size
    // says or longer; the place is writable.
    let status = unsafe { package.export(runtime, &raw mut table) };
    (status, table)
}

#[test]
fn a_package_s_state_is_made_once_and_its_table_carries_its_size() {
    let package = package();
    let fake = FakeRuntime::new().leak();
    assert!(package.state().is_none(), "no state before a load");

    let table = package.load(fake.runtime());
    let again = package.load(fake.runtime());

    assert!(ptr::eq(table, again));
    assert!(ptr::eq(table, package.table()));
    assert_eq!(table.size(), size_of::<Table<Functions>>());
    assert_eq!(table.size(), size_of::<usize>() + size_of::<Functions>());
    assert_eq!(table.functions().word, 3);
    assert_eq!((table.functions().function)(), 7);
    assert_eq!(fake.services(), [("tested".to_owned(), 1024)], "made once");
    let state = package.state().expect("made by the load");
    assert_eq!(state.service.id(), 1024);
}

#[test]
fn the_export_refuses_no_runtime_and_a_smaller_one_with_the_table_unwritten_and_no_state() {
    let package = package();
    let small = FakeRuntime::new().sized(REQUIRED - 8).leak();

    assert_eq!(
        export(package, ptr::null()),
        (INIT_RUNTIME_TOO_SMALL, ptr::null())
    );
    assert_eq!(
        export(package, small.raw()),
        (INIT_RUNTIME_TOO_SMALL, ptr::null())
    );
    assert!(package.state().is_none());
    assert!(small.services().is_empty(), "nothing registered");
}

#[test]
fn the_export_loads_a_whole_and_a_later_runtime_and_answers_the_same_table_twice() {
    let package = package();
    let whole = FakeRuntime::new().leak();
    let later = FakeRuntime::new().later().leak();
    let table: *const c_void = ptr::from_ref(package.table()).cast();

    assert_eq!(export(package, whole.raw()), (INIT_LOADED, table));
    assert_eq!(export(package, later.raw()), (INIT_LOADED, table));
    assert_eq!(whole.services().len(), 1, "made once, on the first");
    assert!(later.services().is_empty(), "and not again");

    let alone = package_on_later();
    assert_eq!(
        alone.services().len(),
        1,
        "a later runtime alone loads a package"
    );
}

/// A fresh package loaded on a later runtime alone: the fake it ran on.
fn package_on_later() -> &'static FakeRuntime {
    let package = package();
    let later = FakeRuntime::new().later().leak();
    let (status, table) = export(package, later.raw());
    assert_eq!(status, INIT_LOADED);
    assert!(ptr::eq(table, ptr::from_ref(package.table()).cast()));
    later
}
