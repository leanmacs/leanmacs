//! Builds the six fixture grammar libraries into `OUT_DIR` with
//! `editor-grammar-build`, from the pinned grammar crates this crate depends
//! on, and stages each grammar's queries beside them, in the layout of a
//! package's staged `grammars/` directory:
//!
//! ```text
//! OUT_DIR/libtree-sitter-<name>.dylib   (.so elsewhere)
//! OUT_DIR/queries/<name>/<kind>.scm
//! ```
//!
//! The queries are exactly the set the syntax adapter's table ships for each
//! grammar: the grammar crate's own, read from the source directory
//! `editor-grammar-build` reports, and, for rust, the adapter's own
//! `textobjects.scm` and `indents.scm`. A grammar that fails to build fails
//! this build: a fixture that cannot build must fail Cargo.

use std::path::{Path, PathBuf};

use editor_grammar_build::{Grammar, Outcome, build};

/// Where each query a grammar ships comes from: a file under its source
/// directory, or one of the syntax adapter's own.
enum From {
    /// A path under the grammar's source directory.
    Source(&'static str),
    /// A path under this crate's directory.
    Here(&'static str),
}

/// Each grammar's queries: its name, then each staged file and where it is
/// copied from.
const QUERIES: [(&str, &[(&str, From)]); 6] = [
    (
        "rust",
        &[
            ("highlights.scm", From::Source("queries/highlights.scm")),
            ("injections.scm", From::Source("queries/injections.scm")),
            (
                "textobjects.scm",
                From::Here("../editor-syntax-treesitter/queries/rust/textobjects.scm"),
            ),
            (
                "indents.scm",
                From::Here("../editor-syntax-treesitter/queries/rust/indents.scm"),
            ),
        ],
    ),
    (
        "json",
        &[("highlights.scm", From::Source("queries/highlights.scm"))],
    ),
    (
        "markdown",
        &[
            ("highlights.scm", From::Source("queries/highlights.scm")),
            ("injections.scm", From::Source("queries/injections.scm")),
        ],
    ),
    (
        "markdown_inline",
        &[
            ("highlights.scm", From::Source("queries/highlights.scm")),
            ("injections.scm", From::Source("queries/injections.scm")),
        ],
    ),
    (
        "toml",
        &[("highlights.scm", From::Source("queries/highlights.scm"))],
    ),
    (
        "lean",
        &[("highlights.scm", From::Source("queries/highlights.scm"))],
    ),
];

fn main() {
    let report = build(&[
        Grammar::package("rust", "tree-sitter-rust"),
        Grammar::package("json", "tree-sitter-json"),
        Grammar::package_in("markdown", "tree-sitter-md", "tree-sitter-markdown"),
        Grammar::package_in(
            "markdown_inline",
            "tree-sitter-md",
            "tree-sitter-markdown-inline",
        ),
        Grammar::package("toml", "tree-sitter-toml-ng"),
        Grammar::package("lean", "tree-sitter-lean"),
    ]);
    #[expect(
        clippy::disallowed_methods,
        reason = "a build script's inputs are Cargo's environment"
    )]
    let out = PathBuf::from(std::env::var_os("OUT_DIR").expect("Cargo sets OUT_DIR"));
    for outcome in &report.outcomes {
        match outcome {
            Outcome::Failed { name, reason, .. } => {
                panic!("the fixture grammar `{name}` did not build: {reason}")
            }
            Outcome::Built { name, source, .. } => stage(&out, name, source),
        }
    }
    println!(
        "cargo:rustc-env=EDITOR_SYNTAX_FIXTURE_GRAMMARS_DIRECTORY={}",
        out.display()
    );
}

/// Copies the queries of the grammar `name`, whose source directory is
/// `source`, to `out/queries/<name>/`.
fn stage(out: &Path, name: &str, source: &Path) {
    let (_, files) = QUERIES
        .iter()
        .find(|(grammar, _)| *grammar == name)
        .unwrap_or_else(|| panic!("the fixture grammar `{name}` lists no queries"));
    let directory = out.join("queries").join(name);
    #[expect(
        clippy::disallowed_methods,
        reason = "the build script writes the fixture's query layout into OUT_DIR, beside the libraries"
    )]
    std::fs::create_dir_all(&directory)
        .unwrap_or_else(|error| panic!("creating {}: {error}", directory.display()));
    for (file, from) in *files {
        let from = match from {
            From::Source(path) => source.join(path),
            From::Here(path) => PathBuf::from(path),
        };
        let to = directory.join(file);
        #[expect(
            clippy::disallowed_methods,
            reason = "the build script writes the fixture's query layout into OUT_DIR, beside the libraries"
        )]
        std::fs::copy(&from, &to).unwrap_or_else(|error| {
            panic!("copying {} to {}: {error}", from.display(), to.display())
        });
        println!("cargo:rerun-if-changed={}", from.display());
    }
}
