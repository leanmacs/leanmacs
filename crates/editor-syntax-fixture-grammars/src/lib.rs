//! A test fixture: the six grammars the syntax adapter compiles in (`rust`,
//! `json`, `markdown`, `markdown_inline`, `toml` and `lean`), built as
//! native grammar libraries from the same pinned sources, each with the
//! queries the adapter ships for it beside it.
//!
//! **Who uses it.** The core's tests, which load their grammars from here
//! rather than from the adapter's compiled-in table, which they cannot see
//! (`editor-syntax-treesitter`'s crate docs, "How grammars are loaded"):
//! the adapter's own tests (`tests/contract.rs`, `tests/injections.rs`,
//! `tests/refresh.rs`, its unit tests and the `round` example) and
//! `editor-ffi`'s, each by a dev-dependency; and Lean's test programs,
//! which `mise run ffi-test` hands [`DIRECTORY`], printed by this crate's
//! binary. The editor never links it (`deny.toml`).
//!
//! **The layout.** [`DIRECTORY`] holds each grammar's library,
//! `libtree-sitter-<name>.dylib` on macOS and `.so` elsewhere, and its
//! queries under `queries/<name>/<kind>.scm`: the layout of a package's
//! staged `grammars/` directory, so a Lean test declares a grammar with its
//! library and `queries/<name>` as it would a package's.
//!
//! **Why a build-script product, not a `cdylib`.** As for
//! `editor-syntax-fixture-ini`: a `cdylib`'s path cannot reach another
//! crate's tests on stable Cargo, and a Rust `cdylib` does not export the
//! C symbols of a static archive linked into it. The build script compiles
//! each grammar's C with `editor-grammar-build`, as a package's
//! grammar-source crate does.
//!
//! The crate depends on no port: it hands out paths, names and query texts,
//! and each test registers the grammar on what it tests.

/// The directory the libraries and their queries are in, absolute.
pub const DIRECTORY: &str = env!("EDITOR_SYNTAX_FIXTURE_GRAMMARS_DIRECTORY");

/// The path of the library of the grammar `$name` in [`DIRECTORY`].
#[cfg(target_os = "macos")]
macro_rules! library {
    ($name:literal) => {
        concat!(
            env!("EDITOR_SYNTAX_FIXTURE_GRAMMARS_DIRECTORY"),
            "/libtree-sitter-",
            $name,
            ".dylib"
        )
    };
}

/// The path of the library of the grammar `$name` in [`DIRECTORY`].
#[cfg(not(target_os = "macos"))]
macro_rules! library {
    ($name:literal) => {
        concat!(
            env!("EDITOR_SYNTAX_FIXTURE_GRAMMARS_DIRECTORY"),
            "/libtree-sitter-",
            $name,
            ".so"
        )
    };
}

/// The text of the query `$kind` of the grammar `$name`, staged in
/// [`DIRECTORY`].
macro_rules! query {
    ($name:literal, $kind:literal) => {
        include_str!(concat!(
            env!("EDITOR_SYNTAX_FIXTURE_GRAMMARS_DIRECTORY"),
            "/queries/",
            $name,
            "/",
            $kind,
            ".scm"
        ))
    };
}

/// One fixture grammar: what a test registers and draws with.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Grammar {
    /// Its name.
    pub name: &'static str,
    /// The symbol its library exports, `tree_sitter_<name>`.
    pub symbol: &'static str,
    /// Its library, absolute.
    pub library: &'static str,
    /// Whether its incremental reparses of texts without errors equal a
    /// fresh parse: the adapter's finding, which its corpora pin
    /// (`editor-syntax-treesitter`'s `tests/contract.rs`). False for
    /// `markdown_inline` alone.
    pub incremental: bool,
    /// Its highlights query, `queries/<name>/highlights.scm`.
    pub highlights: &'static str,
    /// Its injections query, `queries/<name>/injections.scm`, if it has one.
    pub injections: Option<&'static str>,
    /// Its text objects query, `queries/<name>/textobjects.scm`, if it has
    /// one.
    pub text_objects: Option<&'static str>,
    /// Its indents query, `queries/<name>/indents.scm`, if it has one.
    pub indents: Option<&'static str>,
}

/// Rust, with its crate's highlights and injections and the adapter's text
/// objects and indents.
pub const RUST: Grammar = Grammar {
    name: "rust",
    symbol: "tree_sitter_rust",
    library: library!("rust"),
    incremental: true,
    highlights: query!("rust", "highlights"),
    injections: Some(query!("rust", "injections")),
    text_objects: Some(query!("rust", "textobjects")),
    indents: Some(query!("rust", "indents")),
};

/// JSON, with its crate's highlights.
pub const JSON: Grammar = Grammar {
    name: "json",
    symbol: "tree_sitter_json",
    library: library!("json"),
    incremental: true,
    highlights: query!("json", "highlights"),
    injections: None,
    text_objects: None,
    indents: None,
};

/// Markdown's block grammar, with its highlights and injections.
pub const MARKDOWN: Grammar = Grammar {
    name: "markdown",
    symbol: "tree_sitter_markdown",
    library: library!("markdown"),
    incremental: true,
    highlights: query!("markdown", "highlights"),
    injections: Some(query!("markdown", "injections")),
    text_objects: None,
    indents: None,
};

/// Markdown's inline grammar, with its highlights and injections; reparsed
/// whole.
pub const MARKDOWN_INLINE: Grammar = Grammar {
    name: "markdown_inline",
    symbol: "tree_sitter_markdown_inline",
    library: library!("markdown_inline"),
    incremental: false,
    highlights: query!("markdown_inline", "highlights"),
    injections: Some(query!("markdown_inline", "injections")),
    text_objects: None,
    indents: None,
};

/// TOML, with its crate's highlights.
pub const TOML: Grammar = Grammar {
    name: "toml",
    symbol: "tree_sitter_toml",
    library: library!("toml"),
    incremental: true,
    highlights: query!("toml", "highlights"),
    injections: None,
    text_objects: None,
    indents: None,
};

/// Lean 4, with upstream's highlights.
pub const LEAN: Grammar = Grammar {
    name: "lean",
    symbol: "tree_sitter_lean",
    library: library!("lean"),
    incremental: true,
    highlights: query!("lean", "highlights"),
    injections: None,
    text_objects: None,
    indents: None,
};

/// The six, in the adapter's table's order.
pub const ALL: [Grammar; 6] = [JSON, RUST, MARKDOWN, MARKDOWN_INLINE, TOML, LEAN];

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    /// The text of the file at `path`, read from disk.
    fn read(path: &Path) -> Option<String> {
        #[expect(
            clippy::disallowed_methods,
            reason = "the test reads the files the build script staged, the layout the Lean tests read"
        )]
        let read = std::fs::read_to_string(path);
        read.ok()
    }

    /// Whether a file is at `path`, asked of the disk.
    fn is_file(path: &Path) -> bool {
        #[expect(
            clippy::disallowed_methods,
            reason = "the test asks whether the build script staged a file, the layout the Lean tests read"
        )]
        let found = path.is_file();
        found
    }

    #[test]
    fn each_grammars_library_and_its_query_files_are_where_the_layout_puts_them() {
        let extension = if cfg!(target_os = "macos") {
            "dylib"
        } else {
            "so"
        };
        for grammar in ALL {
            let library =
                Path::new(DIRECTORY).join(format!("libtree-sitter-{}.{extension}", grammar.name));
            assert_eq!(Path::new(grammar.library), library, "{}", grammar.name);
            assert!(is_file(&library), "{} is no file", library.display());
            assert_eq!(grammar.symbol, format!("tree_sitter_{}", grammar.name));
            let queries = Path::new(DIRECTORY).join("queries").join(grammar.name);
            for (kind, shipped) in [
                ("highlights", Some(grammar.highlights)),
                ("injections", grammar.injections),
                ("textobjects", grammar.text_objects),
                ("indents", grammar.indents),
            ] {
                let file = queries.join(format!("{kind}.scm"));
                assert_eq!(
                    is_file(&file),
                    shipped.is_some(),
                    "{}: {kind}",
                    grammar.name
                );
            }
        }
    }

    #[test]
    fn each_query_constant_is_the_file_staged_beside_the_libraries() {
        for grammar in ALL {
            let queries = Path::new(DIRECTORY).join("queries").join(grammar.name);
            for (kind, shipped) in [
                ("highlights", Some(grammar.highlights)),
                ("injections", grammar.injections),
                ("textobjects", grammar.text_objects),
                ("indents", grammar.indents),
            ] {
                assert_eq!(
                    read(&queries.join(format!("{kind}.scm"))).as_deref(),
                    shipped,
                    "{}: {kind}",
                    grammar.name
                );
            }
        }
    }

    #[test]
    fn only_markdown_inline_is_reparsed_whole_and_the_six_are_the_tables_names_in_order() {
        assert_eq!(
            ALL.map(|grammar| grammar.name),
            [
                "json",
                "rust",
                "markdown",
                "markdown_inline",
                "toml",
                "lean"
            ]
        );
        assert_eq!(
            ALL.iter()
                .filter(|grammar| !grammar.incremental)
                .map(|grammar| grammar.name)
                .collect::<Vec<_>>(),
            ["markdown_inline"]
        );
    }
}
