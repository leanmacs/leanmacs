//! Native grammar libraries, loaded at run time: the load step the
//! adapter hands the core's registry ([`editor_syntax::registry`]).
//!
//! A native grammar is a shared library (`.dylib` on macOS, `.so` on
//! Linux) exporting `tree_sitter_<name>`, a function that answers the
//! grammar's language: the same generated `parser.c` (and `scanner.c`) a
//! grammar crate compiles in, linked as a library. It is opened with
//! `libloading`, whose types stay in this module.
//!
//! **The order of the refusals** ([`load`]):
//!
//! 1. A library path that is not absolute is
//!    [`RegistrationRefusal::NotFound`], with nothing read: `dlopen`
//!    searches the system's paths for a bare name, so a relative path never
//!    reaches it. Whoever names a library hands a path it has resolved.
//! 2. A path the disk says is not there is `NotFound`.
//! 3. Any other answer of the disk, or a file `dlopen` will not open as a
//!    library on this platform, is [`RegistrationRefusal::NotLoadable`].
//! 4. A library that does not export the symbol is
//!    [`RegistrationRefusal::MissingSymbol`].
//! 5. A language whose ABI version is outside what the pinned library
//!    accepts ([`abi_supported`]) is
//!    [`RegistrationRefusal::UnsupportedAbi`], before any parser is made.
//!
//! **A library is never unloaded.** A `Language`, and every parser and
//! tree of it, points into the library's code for as long as it lives, and
//! a parser or a tree outlives the registration that made it. So the
//! handle is leaked once the library opens, and the library stays mapped
//! for the life of the process. Loading the same library again is
//! `dlopen`'s reference count, never a second copy.
//!
//! **Where it runs.** The adapter loads before it takes its registry's
//! lock, so nothing that reads the grammars listed waits for a `dlopen`;
//! in the process the load runs on the syntax worker's thread, where the
//! job of a registration is answered.
//!
//! This is the crate's one module with `unsafe` (the crate root denies it
//! everywhere else): opening a library runs its initialisers, and calling
//! the symbol trusts that it is a grammar's language function. Each site is
//! marked with its reason, and each block says what it relies on.

use std::io::ErrorKind;
use std::path::Path;

use editor_syntax::{GrammarSource, RegistrationRefusal};
use libloading::{Library, Symbol};
use tree_sitter::{LANGUAGE_VERSION, Language, MIN_COMPATIBLE_LANGUAGE_VERSION};
use tree_sitter_language::LanguageFn;

/// The signature of a grammar's language function.
type LanguageFunction = unsafe extern "C" fn() -> *const ();

/// Whether the pinned library speaks a grammar of ABI `version`: whether
/// it is within the library's compatible range.
pub(crate) fn abi_supported(version: usize) -> bool {
    (MIN_COMPATIBLE_LANGUAGE_VERSION..=LANGUAGE_VERSION).contains(&version)
}

/// The language `source` names, loaded from its library, or why not, in
/// the order of the module docs.
pub(crate) fn load(source: &GrammarSource) -> Result<Language, RegistrationRefusal> {
    let path = source.library.as_path();
    if !path.is_absolute() {
        return Err(RegistrationRefusal::NotFound);
    }
    there(path)?;
    let library = open(path)?;
    let language = language(library, &source.symbol)?;
    if !abi_supported(language.abi_version()) {
        return Err(RegistrationRefusal::UnsupportedAbi);
    }
    Ok(language)
}

/// Whether the disk has a file at `path`: `NotFound` when it says there is
/// none, `NotLoadable` for any other refusal.
#[expect(
    clippy::disallowed_methods,
    reason = "the adapter opens a grammar library on the real disk, and asks first whether the file is there, to tell a missing library from one that will not open"
)]
fn there(path: &Path) -> Result<(), RegistrationRefusal> {
    match std::fs::metadata(path) {
        Ok(_) => Ok(()),
        Err(error) if error.kind() == ErrorKind::NotFound => Err(RegistrationRefusal::NotFound),
        Err(_) => Err(RegistrationRefusal::NotLoadable),
    }
}

/// The library at `path`, opened and never closed: `NotLoadable` when the
/// platform will not open it as a library.
fn open(path: &Path) -> Result<&'static Library, RegistrationRefusal> {
    #[expect(
        unsafe_code,
        reason = "loading a native grammar is opening its library with dlopen"
    )]
    // SAFETY: opening a library runs its initialisers, which are its
    // author's code: loading code the user named is what registering a
    // native grammar means, as in every editor that loads them. The library
    // is never closed, so nothing of it is used after an unload.
    let library = unsafe { Library::new(path) }.map_err(|_| RegistrationRefusal::NotLoadable)?;
    Ok(Box::leak(Box::new(library)))
}

/// The language `library`'s `symbol` answers: `MissingSymbol` when the
/// library does not export it.
fn language(library: &'static Library, symbol: &str) -> Result<Language, RegistrationRefusal> {
    #[expect(
        unsafe_code,
        reason = "finding a native grammar's language function is dlsym of its symbol"
    )]
    // SAFETY: the symbol is read as a grammar's language function, which
    // is what a `GrammarSource` names: a function of no arguments that
    // answers a pointer to a static `TSLanguage`. The library is never
    // closed, so the function stays valid for the life of the process.
    let function: Symbol<'static, LanguageFunction> = unsafe { library.get(symbol.as_bytes()) }
        .map_err(|_| RegistrationRefusal::MissingSymbol)?;
    #[expect(
        unsafe_code,
        reason = "wrapping a native grammar's language function as tree-sitter's LanguageFn"
    )]
    // SAFETY: as above, the function is a grammar's language function,
    // generated by the tree-sitter CLI, which `LanguageFn` requires; its
    // ABI version is checked before any parser is made of it.
    let function = unsafe { LanguageFn::from_raw(*function) };
    Ok(Language::new(function))
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;

    #[test]
    fn an_abi_version_inside_the_pinned_librarys_range_is_supported() {
        assert!(abi_supported(MIN_COMPATIBLE_LANGUAGE_VERSION));
        assert!(abi_supported(LANGUAGE_VERSION));
    }

    #[test]
    fn an_abi_version_outside_the_pinned_librarys_range_is_unsupported() {
        assert!(!abi_supported(0));
        assert!(!abi_supported(MIN_COMPATIBLE_LANGUAGE_VERSION - 1));
        assert!(!abi_supported(LANGUAGE_VERSION + 1));
    }

    #[test]
    fn a_relative_library_path_is_refused_as_not_found_with_nothing_opened() {
        // `dlopen` would search the system's paths for a bare name; neither
        // path reaches it.
        for library in ["libtree-sitter-ini.dylib", "grammar/libx.so"] {
            let source = GrammarSource {
                library: PathBuf::from(library),
                symbol: "tree_sitter_ini".to_owned(),
                policy: None,
            };
            assert_eq!(
                load(&source).map(|_| ()),
                Err(RegistrationRefusal::NotFound),
                "{library}"
            );
        }
    }
}
