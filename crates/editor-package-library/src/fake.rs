//! The fake of the library port: libraries canned per path, recording what
//! was opened, published so that the load's tests, and a later user's, run
//! with no file.
//!
//! A path canned with [`FakeLibraries::not_a_library`] is a file that will
//! not open; one canned with [`FakeLibraries::library`] opens as a library
//! exporting the init functions a test wrote, by symbol, and with
//! [`FakeLibraries::declaring`] the declaration a test wrote, as
//! `editor_package_declaration`; any other path is missing. It keeps
//! [`crate::contract::check`], in that module's tests.

use std::collections::HashMap;
use std::mem::offset_of;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};

use editor_package_runtime::DECLARATION_SYMBOL;

use crate::library::{Libraries, Library, PackageDeclaration, PackageInit, Unopened};

/// What a path is canned as.
#[derive(Debug, Clone)]
enum Canned {
    /// A file that will not open as a library.
    NotALibrary,
    /// A library exporting these symbols.
    Library(FakeLibrary),
}

/// Libraries canned per path: the port's fake.
#[derive(Debug, Default)]
pub struct FakeLibraries {
    /// What each canned path is.
    canned: HashMap<PathBuf, Canned>,
    /// Every path opened, oldest first.
    opened: Mutex<Vec<PathBuf>>,
}

impl FakeLibraries {
    /// A fake in which every path is missing.
    pub fn new() -> Self {
        Self::default()
    }

    /// This fake, with a file at `path` that will not open as a library.
    #[must_use]
    pub fn not_a_library(mut self, path: impl Into<PathBuf>) -> Self {
        self.canned.insert(path.into(), Canned::NotALibrary);
        self
    }

    /// This fake, with a library at `path` exporting each of `symbols`.
    #[must_use]
    pub fn library(mut self, path: impl Into<PathBuf>, symbols: &[(&str, PackageInit)]) -> Self {
        let inits = symbols
            .iter()
            .map(|&(symbol, init)| (symbol.to_owned(), init))
            .collect();
        self.canned.insert(
            path.into(),
            Canned::Library(FakeLibrary {
                inits,
                declaration: None,
            }),
        );
        self
    }

    /// This fake, with the library at `path` also exporting `declaration`
    /// as `editor_package_declaration`: a library exporting no init when
    /// none was canned there. A declaration whose `size` ends before a
    /// member reads that member as 0, whatever was written there, as the
    /// real adapter reads a short declaration by the members its size
    /// covers (the contract's `SHORT`).
    #[must_use]
    pub fn declaring(mut self, path: impl Into<PathBuf>, declaration: PackageDeclaration) -> Self {
        let path = path.into();
        let mut library = match self.canned.remove(&path) {
            Some(Canned::Library(library)) => library,
            _ => FakeLibrary::default(),
        };
        library.declaration = Some(declaration);
        self.canned.insert(path, Canned::Library(library));
        self
    }

    /// Every path asked to open so far, oldest first.
    pub fn opened(&self) -> Vec<PathBuf> {
        self.opened
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }
}

impl Libraries for FakeLibraries {
    fn open(&self, path: &Path) -> Result<Box<dyn Library>, Unopened> {
        self.opened
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(path.to_owned());
        match self.canned.get(path) {
            None => Err(Unopened::Missing),
            Some(Canned::NotALibrary) => Err(Unopened::NotALibrary),
            Some(Canned::Library(library)) => Ok(Box::new(library.clone())),
        }
    }
}

/// A canned library: the init functions it exports by symbol, and its
/// declaration, if it exports one.
#[derive(Debug, Clone, Default)]
struct FakeLibrary {
    /// The init functions, by symbol.
    inits: Vec<(String, PackageInit)>,
    /// The declaration exported as `editor_package_declaration`.
    declaration: Option<PackageDeclaration>,
}

impl Library for FakeLibrary {
    fn init(&self, symbol: &str) -> Option<PackageInit> {
        self.inits
            .iter()
            .find(|(exported, _)| exported == symbol)
            .map(|&(_, init)| init)
    }

    fn declaration(&self, symbol: &str) -> Option<PackageDeclaration> {
        let written = self.declaration.filter(|_| symbol == DECLARATION_SYMBOL)?;
        let covers = |offset: usize, width: usize| written.size >= offset + width;
        Some(PackageDeclaration {
            size: written.size,
            runtime: if covers(offset_of!(PackageDeclaration, runtime), size_of::<usize>()) {
                written.runtime
            } else {
                0
            },
            interface: if covers(offset_of!(PackageDeclaration, interface), size_of::<u32>()) {
                written.interface
            } else {
                0
            },
        })
    }
}
