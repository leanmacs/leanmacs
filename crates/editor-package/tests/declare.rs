//! A package declared with `editor_package::package!`, as a package's
//! library declares itself: the macro exports the init,
//! `editor_package_init`, which refuses no runtime and one smaller than
//! the wrapper requires, with no table written and no state made, and
//! loads a whole runtime and a later one, the state made once and the same
//! table answered, whose functions reach the state; and beside it the
//! declaration, `editor_package_declaration`, which says the package's
//! interface, as the macro's `interface 7;` gives it, and the runtime the
//! wrapper needs, [`REQUIRED`].
//!
//! An integration test of its own, and one test of the init, because the
//! export is one symbol per binary and the package's state is process-wide:
//! once loaded, it stays loaded. The declaration is a static that no load
//! changes, so its test stands apart.

#![deny(unsafe_code)]

use std::ffi::c_void;
use std::ptr;

use editor_package::fake::FakeRuntime;
use editor_package::raw::{INIT_LOADED, INIT_RUNTIME_TOO_SMALL, PackageDeclaration};
use editor_package::{Package, REQUIRED, Runtime, Service, package};

/// The declared package's state: the service its init registers.
#[derive(Debug)]
struct Declared {
    /// The service.
    service: Service,
}

impl Declared {
    /// The package's init.
    fn new(runtime: Runtime) -> Self {
        Self {
            service: runtime.register("declared"),
        }
    }
}

/// The declared package's own table.
#[repr(C)]
#[derive(Debug)]
struct Functions {
    /// Completes the request `request` through the package's service, and
    /// answers whether it was loaded and accepted.
    complete: extern "C" fn(request: u64) -> bool,
}

/// [`Functions::complete`].
extern "C" fn complete(request: u64) -> bool {
    PACKAGE
        .state()
        .is_some_and(|declared| declared.service.complete(request))
}

package! {
    interface 7;

    /// The declared package.
    static PACKAGE: Package<Declared, Functions> = Package::new(Declared::new, Functions { complete });
}

/// The init's answer for no runtime at all, as a core that hands none.
fn init_without_a_runtime() -> (u32, *const c_void) {
    let mut table: *const c_void = ptr::null();
    #[expect(
        unsafe_code,
        reason = "calls the exported init as the core's load does, with no runtime and a writable place"
    )]
    // SAFETY: a null runtime is one the init refuses; the place is
    // writable.
    let status = unsafe { editor_package_init(ptr::null(), &raw mut table) };
    (status, table)
}

#[test]
fn a_package_declared_with_the_macro_exports_its_init_and_table() {
    let table: *const c_void = ptr::from_ref(PACKAGE.table()).cast();
    let small = FakeRuntime::new().sized(REQUIRED - 8).leak();
    let whole = FakeRuntime::new().leak();
    let later = FakeRuntime::new().later().leak();

    assert!(!(PACKAGE.table().functions().complete)(1), "not loaded yet");
    assert_eq!(
        init_without_a_runtime(),
        (INIT_RUNTIME_TOO_SMALL, ptr::null())
    );
    assert_eq!(
        small.init(editor_package_init),
        (INIT_RUNTIME_TOO_SMALL, ptr::null())
    );
    assert!(PACKAGE.state().is_none(), "no state made");
    assert!(small.services().is_empty());

    assert_eq!(whole.init(editor_package_init), (INIT_LOADED, table));
    assert_eq!(later.init(editor_package_init), (INIT_LOADED, table));
    assert_eq!(whole.services(), [("declared".to_owned(), 1024)]);
    assert!(later.services().is_empty(), "the state is made once");

    assert!((PACKAGE.table().functions().complete)(41));
    assert_eq!(whole.next_completion(), Some((1024, 41)));
    assert_eq!(later.next_completion(), None);
}

#[test]
fn a_package_declared_with_the_macro_exports_its_declaration_its_interface_and_the_runtime_it_needs()
 {
    assert_eq!(
        editor_package_declaration,
        PackageDeclaration {
            size: size_of::<PackageDeclaration>(),
            runtime: REQUIRED,
            interface: 7,
        }
    );
}
