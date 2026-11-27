//! The port a package's library is opened through, in the core's terms:
//! [`Libraries`] opens the file at a path as a library, and a [`Library`]
//! finds a symbol in it as a package's init function ([`InitFunction`]).
//!
//! Finding the symbol is the adapter's; calling it is the core's
//! ([`crate::load`]), so the fake ([`crate::fake::FakeLibraries`]) hands
//! back init functions a test wrote, and the real adapter
//! (`editor-package-library-libloading`) hands back the library's own.
//! Both keep [`crate::contract::check`].

use std::ffi::c_void;
use std::path::Path;

use crate::runtime::PackageRuntime;

/// The C signature of a package library's init, the one symbol the core
/// asks a library for ([`crate::load::INIT_SYMBOL`]), in the shape of
/// Emacs's `emacs_module_init`: it is handed the core's runtime and a place
/// for its table, and answers 0 once it has written its table there, or 1
/// when the runtime's `size` is smaller than the library requires, the
/// table left unwritten. The table's type is the package's own, opaque to
/// the core.
pub type InitFunction =
    unsafe extern "C" fn(runtime: *const PackageRuntime, table: *mut *const c_void) -> u32;

/// Why a path did not open as a library.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Unopened {
    /// The disk says there is nothing at the path.
    Missing,
    /// There is a file, and it will not open as a library on this
    /// platform, or the disk refused to say what is there.
    NotALibrary,
}

/// What opens a package's library: the platform's loader, as the core
/// sees it.
pub trait Libraries: Send + Sync {
    /// Opens the library at the absolute path `path`, which stays open for
    /// the life of the process: a library is never unloaded, so what it
    /// hands out (its init, its table, its functions) stays valid.
    ///
    /// # Errors
    ///
    /// [`Unopened::Missing`] when nothing is at the path, and
    /// [`Unopened::NotALibrary`] when what is there will not open.
    fn open(&self, path: &Path) -> Result<Box<dyn Library>, Unopened>;
}

/// A library, opened.
pub trait Library: Send + Sync {
    /// The function the library exports as `symbol`, read as an init
    /// function, or none when it exports no such symbol. It is found, never
    /// called: the core calls it.
    fn init(&self, symbol: &str) -> Option<InitFunction>;
}
