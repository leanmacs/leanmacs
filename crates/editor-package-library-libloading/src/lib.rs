//! The library port's real adapter ([`LibLoading`]): a package's native
//! library opened with the platform's loader (`dlopen`, through
//! `libloading`, whose types stay in this crate), its init found by symbol
//! (`dlsym`), and the library never unloaded.
//!
//! It keeps `editor-package-library`'s contract
//! (`editor_package_library::contract::check`) on the fixture grammar
//! library (`tests/contract.rs`). It decides nothing: the order of the
//! refusals and the call of the init are the core's
//! (`editor_package_library::load`).
//!
//! **How a refusal is told** ([`LibLoading::open`]): the disk is asked
//! first whether anything is at the path, so a path the disk says nothing
//! is at is [`Unopened::Missing`]; any other answer of the disk, or a file
//! the loader will not open, is [`Unopened::NotALibrary`]. The same as the
//! syntax adapter's native grammars (`editor-syntax-treesitter`'s
//! `src/native.rs`).
//!
//! **A library is never unloaded.** A package's table and its functions
//! point into the library's code for the life of the process, so the
//! handle is leaked once the library opens. Opening the same library again
//! is the loader's reference count, never a second copy. Each library is
//! opened on its own (`RTLD_LOCAL` on Unix, libloading's default), so two
//! packages' `editor_package_init` never stand for each other.
//!
//! **Its one constructor** is [`LibLoading::system`], which the root
//! `clippy.toml` refuses everywhere but `editor-ffi`'s one static and this
//! crate's contract test.
//!
//! The crate denies `unsafe` everywhere but its two marked sites: opening a
//! library runs its initialisers, and reading a symbol as an init trusts
//! that it is one.

#![deny(unsafe_code)]

use std::io::ErrorKind;
use std::path::Path;

use editor_package_library::library::{InitFunction, Libraries, Library, Unopened};

/// The platform's loader: the library port's real adapter.
#[derive(Debug)]
pub struct LibLoading(());

impl LibLoading {
    /// The platform's loader. Made in one place, `editor-ffi`'s static,
    /// and in this crate's contract test (the root `clippy.toml`).
    pub const fn system() -> Self {
        Self(())
    }
}

impl Libraries for LibLoading {
    fn open(&self, path: &Path) -> Result<Box<dyn Library>, Unopened> {
        there(path)?;
        #[expect(
            unsafe_code,
            reason = "loading a package's library is opening it with dlopen"
        )]
        // SAFETY: opening a library runs its initialisers, which are its
        // author's code: loading the code a package ships is what loading a
        // package's library means. The library is never closed, so nothing
        // of it is used after an unload.
        let library =
            unsafe { libloading::Library::new(path) }.map_err(|_| Unopened::NotALibrary)?;
        Ok(Box::new(Opened(Box::leak(Box::new(library)))))
    }
}

/// Whether the disk has anything at `path`: `Missing` when it says there is
/// nothing, `NotALibrary` for any other refusal.
#[expect(
    clippy::disallowed_methods,
    reason = "the adapter opens a package's library on the real disk, and asks first whether anything is there, to tell a missing library from one that will not open"
)]
fn there(path: &Path) -> Result<(), Unopened> {
    match std::fs::metadata(path) {
        Ok(_) => Ok(()),
        Err(error) if error.kind() == ErrorKind::NotFound => Err(Unopened::Missing),
        Err(_) => Err(Unopened::NotALibrary),
    }
}

/// A library, opened and never closed.
struct Opened(&'static libloading::Library);

impl Library for Opened {
    fn init(&self, symbol: &str) -> Option<InitFunction> {
        #[expect(
            unsafe_code,
            reason = "finding a package's init is dlsym of its symbol"
        )]
        // SAFETY: the symbol is read as a package's init, which is what the
        // core asks a library for by name; the core decides whether to call
        // it. The library is never closed, so the function stays valid for
        // the life of the process.
        let init = unsafe { self.0.get::<InitFunction>(symbol.as_bytes()) }.ok()?;
        Some(*init)
    }
}
