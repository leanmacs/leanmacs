//! A package's library, declared: its init and its function table
//! ([`Package`], [`Table`]), exported by one macro ([`crate::package!`]).
//!
//! A package writes a `#[repr(C)]` struct of `extern "C"` function
//! pointers, its own and opaque to the core, and an init, `fn(Runtime) ->
//! S`, that makes its state from the runtime it is handed. [`Package::new`]
//! holds both, and [`crate::package!`] declares it as a `static` and
//! exports the library's one symbol, `editor_package_init`, over
//! [`Package::export`]:
//!
//! - a null runtime, and one whose `size` ends before `buffer_free`
//!   ([`crate::REQUIRED`], `runtime_has!`), are answered
//!   [`INIT_RUNTIME_TOO_SMALL`], the table unwritten and no state made;
//! - otherwise the state is made once, from the first runtime loaded
//!   ([`Package::load`]), the table written and [`INIT_LOADED`] answered;
//!   a second init answers the same table.
//!
//! The table carries its own size first ([`Table`]), so its layout is a
//! flat `{ size_t size; fns… }` the glue mirrors. A table's function
//! reaches the state with [`Package::state`], none before a load.
//!
//! A member of the runtime appended later is called only after
//! `runtime_has!` asks for it, in the wrapper's method that calls it, which
//! answers that method's absent outcome on an older runtime: the init
//! itself asks only for [`crate::REQUIRED`].
//!
//! Why a declarative macro and not a procedural attribute: a table's
//! functions are ordinary `extern "C" fn`s over the wrapper's FFI-safe
//! types ([`crate::buffer`]), declared with the declarative
//! [`crate::functions!`], whose per-parameter code is one line each, and
//! a procedural macro would compile `syn` and `quote` into every package's
//! build for no gain. The export's `unsafe` is written once, here, with
//! its reason; rustc's `unsafe_code` lint does not fire on an external
//! macro's expansion, so a package keeps `#![deny(unsafe_code)]`.

use std::ffi::c_void;
use std::mem::size_of;
use std::ptr;
use std::sync::OnceLock;

use editor_package_runtime::{INIT_LOADED, INIT_RUNTIME_TOO_SMALL, PackageRuntime};

use crate::runtime::Runtime;

/// A package's function table as it crosses: its size, then the package's
/// own functions `F`, a `#[repr(C)]` struct of `extern "C"` function
/// pointers. Its C shape is `{ size_t size; fns… }`.
#[repr(C)]
#[derive(Debug)]
pub struct Table<F> {
    /// `size_of::<Table<F>>()`.
    size: usize,
    /// The package's functions.
    functions: F,
}

impl<F> Table<F> {
    /// The table of `functions`, its size computed.
    pub const fn new(functions: F) -> Self {
        Self {
            size: size_of::<Self>(),
            functions,
        }
    }

    /// The table's size in bytes, which it carries first.
    pub const fn size(&self) -> usize {
        self.size
    }

    /// The package's functions.
    pub const fn functions(&self) -> &F {
        &self.functions
    }
}

/// A package's library: its init, its state once made, and its table.
/// Declared as a `static` by [`crate::package!`].
pub struct Package<S, F> {
    /// Makes the state from the runtime the library is handed.
    init: fn(Runtime) -> S,
    /// The state, once a load has made it.
    state: OnceLock<S>,
    /// The table the init answers.
    table: Table<F>,
}

impl<S, F> std::fmt::Debug for Package<S, F> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Package")
            .field("size", &self.table.size)
            .field("loaded", &self.state.get().is_some())
            .finish_non_exhaustive()
    }
}

impl<S, F> Package<S, F> {
    /// A package whose state `init` makes and whose table holds
    /// `functions`.
    pub const fn new(init: fn(Runtime) -> S, functions: F) -> Self {
        Self {
            init,
            state: OnceLock::new(),
            table: Table::new(functions),
        }
    }

    /// Loads the package on `runtime`: makes its state, once, from the
    /// first runtime it is loaded on, and answers its table.
    pub fn load(&'static self, runtime: Runtime) -> &'static Table<F> {
        self.state.get_or_init(|| (self.init)(runtime));
        &self.table
    }

    /// The state, once a load has made it; none before.
    pub fn state(&'static self) -> Option<&'static S> {
        self.state.get()
    }

    /// The table, as the init answers it.
    pub const fn table(&self) -> &Table<F> {
        &self.table
    }

    /// The library's init, as [`crate::package!`] exports it: answers
    /// [`INIT_RUNTIME_TOO_SMALL`] for a null runtime or one smaller than
    /// [`crate::REQUIRED`], the table unwritten and no state made;
    /// otherwise loads the package ([`Package::load`]), writes its table to
    /// `table` and answers [`INIT_LOADED`].
    ///
    /// # Safety
    ///
    /// `runtime` is null, or points to a runtime at least as long as its
    /// `size` says, which lives for the process; `table` points to a
    /// writable pointer.
    #[expect(
        unsafe_code,
        reason = "the library's init: it takes the runtime the core hands it, once its size is checked, and writes the table where the core says"
    )]
    pub unsafe fn export(
        &'static self,
        runtime: *const PackageRuntime,
        table: *mut *const c_void,
    ) -> u32 {
        // SAFETY: the caller hands null or a runtime at least as long as
        // its size says, living for the process.
        let Some(runtime) = (unsafe { Runtime::from_raw(runtime) }) else {
            return INIT_RUNTIME_TOO_SMALL;
        };
        let loaded = self.load(runtime);
        // SAFETY: the caller hands a writable place.
        unsafe { table.write(ptr::from_ref(loaded).cast()) };
        INIT_LOADED
    }
}

/// Declares a package's library: `package! { pub static NAME: Package<S,
/// F> = Package::new(init, functions); }` declares the `static` and
/// exports the library's init, `editor_package_init`, over
/// [`Package::export`], so one invocation declares both the init and the
/// function table. The export's signature is checked against the
/// definitions' `PackageInit` at compile time. A second invocation in one
/// library fails to link: the symbol is one per library.
///
/// The `unsafe` of the export is the wrapper's, written here once; rustc's
/// `unsafe_code` lint does not fire on an external macro's expansion, so a
/// package keeps `#![deny(unsafe_code)]`.
#[macro_export]
macro_rules! package {
    ($(#[$meta:meta])* $vis:vis static $name:ident : $ty:ty = $value:expr ;) => {
        $(#[$meta])*
        $vis static $name: $ty = $value;

        /// The library's init, the one symbol the core asks a package's
        /// library for: it loads the package declared beside it on the
        /// runtime it is handed and writes its table, or refuses a runtime
        /// too small (`editor_package::Package::export`).
        ///
        /// # Safety
        ///
        /// `runtime` is null, or points to a runtime at least as long as
        /// its `size` says, which lives for the process; `table` points to
        /// a writable pointer.
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn editor_package_init(
            runtime: *const $crate::raw::PackageRuntime,
            table: *mut *const ::core::ffi::c_void,
        ) -> u32 {
            // SAFETY: the core's load, or a fake's init, hands null or a
            // runtime as long as its size says, living for the process,
            // and a writable place, as the export's caller must.
            unsafe { $crate::Package::export(&$name, runtime, table) }
        }

        const _: $crate::raw::PackageInit = editor_package_init;
    };
}

#[cfg(test)]
mod tests;
