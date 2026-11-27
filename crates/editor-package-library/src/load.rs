//! Loading a package's library: open it, find its init, read its
//! declaration, call its init with the core's runtime, and give back the
//! table it wrote, or why not ([`load`]).
//!
//! **The order of the refusals**, the order of `editor-syntax-treesitter`'s
//! native grammars, then the declaration's, then the init's:
//!
//! 1. A path that is not absolute is [`LoadRefusal::Missing`], with nothing
//!    opened: the platform's loader searches its own paths for a bare name,
//!    so a relative path never reaches it.
//! 2. A path the disk says nothing is at is `Missing`.
//! 3. A file that will not open as a library is
//!    [`LoadRefusal::NotALibrary`].
//! 4. A library that does not export [`INIT_SYMBOL`] is
//!    [`LoadRefusal::NoInit`].
//! 5. A library that exports no declaration ([`DECLARATION_SYMBOL`]), or
//!    one whose `size` ends before its `interface`
//!    ([`DECLARATION_REQUIRED`]), is [`LoadRefusal::NoDeclaration`].
//! 6. A declaration of another interface than the glue's is
//!    [`LoadRefusal::OtherInterface`], with both versions: a library of
//!    another interface is not the one this glue was built for at all, so
//!    it is asked before the runtime.
//! 7. A declaration that needs more runtime than the core's `size` is
//!    [`LoadRefusal::NewerRuntime`], with what it needs and what the core
//!    has.
//! 8. Only then is the init called: one that answers 1, the library
//!    finding the runtime's `size` smaller than it requires, is
//!    [`LoadRefusal::RuntimeTooSmall`], the library's own guard behind the
//!    core's.
//! 9. An init that answers anything else, or 0 with no table, is
//!    [`LoadRefusal::InitFailed`], so no status is left unmapped.
//!
//! So the core never calls the init, or anything of the table, of a
//! library refused by its declaration: the declaration is a static, read
//! before the core calls anything. That is not a guarantee that none of
//! the library's code runs. The library is opened (step 2) before its
//! declaration is read, and opening it with the platform's loader
//! (`dlopen`) runs its load-time initialisers (ELF `.init_array`, Mach-O
//! `__mod_init_func`: C constructors, Rust static initialisers), so a
//! library refused here has already run those in the editor's process. A
//! check that no code of a library runs would have to read the declaration
//! without opening it, by parsing the object file, or verify a hash or a
//! signature before `open`.
//!
//! Each refusal crosses as its [`LoadRefusal::tag`], 1 to 8, the tags of
//! the declaration's refusals (6 to 8) appended after the five that came
//! before them, and 0 means loaded; a newer runtime and another interface
//! also cross their two numbers ([`LoadRefusal::versions`]). A library is
//! never unloaded: its table and its functions stay valid for the life of
//! the process.

use std::ffi::c_void;
use std::path::Path;
use std::ptr::{self, NonNull};

pub use editor_package_runtime::{DECLARATION_REQUIRED, DECLARATION_SYMBOL};
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
    Missing,
    /// The file will not open as a library.
    NotALibrary,
    /// The library does not export [`INIT_SYMBOL`].
    NoInit,
    /// The library's init found the runtime smaller than it requires.
    RuntimeTooSmall,
    /// The library's init answered a status that is neither 0 nor 1, or 0
    /// with no table.
    InitFailed,
    /// The library exports no declaration, or one that ends before its
    /// interface version.
    NoDeclaration,
    /// The library's declaration needs more runtime than the core's.
    NewerRuntime {
        /// The runtime the library declares it needs, in bytes.
        needs: usize,
        /// The core's runtime's size, in bytes.
        has: usize,
    },
    /// The library's declaration is of another interface than the glue's.
    OtherInterface {
        /// The interface version the library declares.
        declared: u32,
        /// The interface version the package's glue expects.
        expected: u32,
    },
}

impl LoadRefusal {
    /// The number the refusal crosses as, 1 to 8; 0 is a load.
    pub const fn tag(self) -> u32 {
        match self {
            Self::Missing => 1,
            Self::NotALibrary => 2,
            Self::NoInit => 3,
            Self::RuntimeTooSmall => 4,
            Self::InitFailed => 5,
            Self::NoDeclaration => 6,
            Self::NewerRuntime { .. } => 7,
            Self::OtherInterface { .. } => 8,
        }
    }

    /// The two numbers a refusal crosses beside its tag: for a newer
    /// runtime, what the library needs and what the core has; for another
    /// interface, the library's version and the glue's; none for any other
    /// refusal.
    pub const fn versions(self) -> Option<(u64, u64)> {
        match self {
            Self::NewerRuntime { needs, has } => Some((needs as u64, has as u64)),
            Self::OtherInterface { declared, expected } => Some((declared as u64, expected as u64)),
            _ => None,
        }
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

/// Loads the package library at `path` through `libraries`, for a glue of
/// the package's interface version `interface`, calling its init with
/// `runtime`, and gives the table it wrote.
///
/// # Errors
///
/// Why it was not loaded, in the order of the module docs.
pub fn load(
    libraries: &dyn Libraries,
    path: &Path,
    interface: u32,
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
    let declaration = library
        .declaration(DECLARATION_SYMBOL)
        .filter(|declaration| declaration.size >= DECLARATION_REQUIRED)
        .ok_or(LoadRefusal::NoDeclaration)?;
    if declaration.interface != interface {
        return Err(LoadRefusal::OtherInterface {
            declared: declaration.interface,
            expected: interface,
        });
    }
    if declaration.runtime > runtime.size {
        return Err(LoadRefusal::NewerRuntime {
            needs: declaration.runtime,
            has: runtime.size,
        });
    }
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
