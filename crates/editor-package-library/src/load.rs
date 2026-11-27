//! Loading a package's library: open it, find its init, call it with the
//! core's runtime, and give back the table it wrote, or why not
//! ([`load`]).
//!
//! **The order of the refusals**, the order of `editor-syntax-treesitter`'s
//! native grammars:
//!
//! 1. A path that is not absolute is [`LoadRefusal::Missing`], with nothing
//!    opened: the platform's loader searches its own paths for a bare name,
//!    so a relative path never reaches it.
//! 2. A path the disk says nothing is at is `Missing`.
//! 3. A file that will not open as a library is
//!    [`LoadRefusal::NotALibrary`].
//! 4. A library that does not export [`INIT_SYMBOL`] is
//!    [`LoadRefusal::NoInit`].
//! 5. An init that answers 1, the library finding the runtime's `size`
//!    smaller than it requires, is [`LoadRefusal::RuntimeTooSmall`].
//! 6. An init that answers anything else, or 0 with no table, is
//!    [`LoadRefusal::InitFailed`], so no status is left unmapped.
//!
//! Each refusal crosses as its [`LoadRefusal::tag`], 1 to 5, and 0 means
//! loaded. A library is never unloaded: its table and its functions stay
//! valid for the life of the process.

use std::ffi::c_void;
use std::path::Path;
use std::ptr::{self, NonNull};

use editor_package_runtime::{INIT_LOADED, INIT_RUNTIME_TOO_SMALL};

use crate::library::{Libraries, Unopened};
use crate::runtime::PackageRuntime;

/// The one symbol the core asks a package's library for: its init
/// ([`crate::library::PackageInit`]).
pub const INIT_SYMBOL: &str = "editor_package_init";

/// Why a package's library was not loaded, in the order [`load`] asks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LoadRefusal {
    /// The path is not absolute, or nothing is at it.
    Missing = 1,
    /// The file will not open as a library.
    NotALibrary = 2,
    /// The library does not export [`INIT_SYMBOL`].
    NoInit = 3,
    /// The library's init found the runtime smaller than it requires.
    RuntimeTooSmall = 4,
    /// The library's init answered a status that is neither 0 nor 1, or 0
    /// with no table.
    InitFailed = 5,
}

impl LoadRefusal {
    /// The number the refusal crosses as, 1 to 5; 0 is a load.
    pub const fn tag(self) -> u32 {
        self as u32
    }
}

/// The table a package's library wrote at its init: a pointer to a
/// structure of the package's own, opaque to the core, valid for the life
/// of the process since the library is never unloaded.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Table(NonNull<c_void>);

impl Table {
    /// The table's pointer.
    pub const fn as_ptr(self) -> *const c_void {
        self.0.as_ptr()
    }
}

// SAFETY: the table is a library's static, never written by the core and
// valid for the life of the process; the core only hands its pointer on.
#[expect(
    unsafe_code,
    reason = "a library's table is a static of the library, which the core only hands on"
)]
unsafe impl Send for Table {}

// SAFETY: as for `Send`.
#[expect(
    unsafe_code,
    reason = "a library's table is a static of the library, which the core only hands on"
)]
unsafe impl Sync for Table {}

/// Loads the package library at `path` through `libraries`, calling its
/// init with `runtime`, and gives the table it wrote.
///
/// # Errors
///
/// Why it was not loaded, in the order of the module docs.
pub fn load(
    libraries: &dyn Libraries,
    path: &Path,
    runtime: &'static PackageRuntime,
) -> Result<Table, LoadRefusal> {
    if !path.is_absolute() {
        return Err(LoadRefusal::Missing);
    }
    let library = libraries.open(path).map_err(|unopened| match unopened {
        Unopened::Missing => LoadRefusal::Missing,
        Unopened::NotALibrary => LoadRefusal::NotALibrary,
    })?;
    let init = library.init(INIT_SYMBOL).ok_or(LoadRefusal::NoInit)?;
    let mut table: *const c_void = ptr::null();
    #[expect(
        unsafe_code,
        reason = "loading a package's library is calling its init, the one call into the library the core makes"
    )]
    // SAFETY: the symbol is read as a package's init, which is what a
    // library that exports `editor_package_init` declares it is: loading a
    // package's library means trusting its init, as an editor that loads
    // modules trusts theirs. It is handed the core's runtime, a static, and
    // a place for its table that lives across the call. The library is
    // never unloaded, so what it writes stays valid.
    let status = unsafe { init(runtime, &raw mut table) };
    match status {
        INIT_LOADED => NonNull::new(table.cast_mut())
            .map(Table)
            .ok_or(LoadRefusal::InitFailed),
        INIT_RUNTIME_TOO_SMALL => Err(LoadRefusal::RuntimeTooSmall),
        _ => Err(LoadRefusal::InitFailed),
    }
}

#[cfg(test)]
mod tests;
