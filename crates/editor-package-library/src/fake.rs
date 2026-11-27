//! The fake of the library port: libraries canned per path, recording what
//! was opened, published so that the load's tests, and a later user's, run
//! with no file.
//!
//! A path canned with [`FakeLibraries::not_a_library`] is a file that will
//! not open; one canned with [`FakeLibraries::library`] opens as a library
//! exporting the init functions a test wrote, by symbol; any other path is
//! missing. It keeps [`crate::contract::check`], in that module's tests.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};

use crate::library::{InitFunction, Libraries, Library, Unopened};

/// What a path is canned as.
#[derive(Debug, Clone)]
enum Canned {
    /// A file that will not open as a library.
    NotALibrary,
    /// A library exporting these symbols.
    Library(Vec<(String, InitFunction)>),
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
    pub fn library(mut self, path: impl Into<PathBuf>, symbols: &[(&str, InitFunction)]) -> Self {
        let symbols = symbols
            .iter()
            .map(|&(symbol, init)| (symbol.to_owned(), init))
            .collect();
        self.canned.insert(path.into(), Canned::Library(symbols));
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
            Some(Canned::Library(symbols)) => Ok(Box::new(FakeLibrary(symbols.clone()))),
        }
    }
}

/// A canned library, opened.
#[derive(Debug)]
struct FakeLibrary(Vec<(String, InitFunction)>);

impl Library for FakeLibrary {
    fn init(&self, symbol: &str) -> Option<InitFunction> {
        self.0
            .iter()
            .find(|(exported, _)| exported == symbol)
            .map(|&(_, init)| init)
    }
}
