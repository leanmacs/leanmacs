//! Builds the six fixture grammar libraries into `OUT_DIR` with
//! `editor-grammar-build`, from the pinned grammar crates this crate takes
//! as build-dependencies and the vendored `vendor/tree-sitter-lean`, and
//! stages each grammar's queries beside them, in the layout of a package's
//! staged `grammars/` directory:
//!
//! ```text
//! OUT_DIR/libtree-sitter-<name>.dylib   (.so elsewhere)
//! OUT_DIR/queries/<name>/<kind>.scm
//! ```
//!
//! The queries are the `languages` package's, copied from its
//! `packages/languages/grammars/queries/<name>/`, so the core's tests draw
//! with exactly what ships. A grammar that fails to build fails this build:
//! a fixture that cannot build must fail Cargo.

use std::path::{Path, PathBuf};

use editor_grammar_build::{Grammar, Outcome, build};

/// The `languages` package's query directory, from this crate's directory.
const PACKAGE_QUERIES: &str = "../../packages/languages/grammars/queries";

/// Each grammar's queries: its name, then each file of the package's
/// `queries/<name>/` staged.
const QUERIES: [(&str, &[&str]); 6] = [
    (
        "rust",
        &[
            "highlights.scm",
            "injections.scm",
            "textobjects.scm",
            "indents.scm",
        ],
    ),
    ("json", &["highlights.scm"]),
    ("markdown", &["highlights.scm", "injections.scm"]),
    ("markdown_inline", &["highlights.scm", "injections.scm"]),
    ("toml", &["highlights.scm"]),
    ("lean", &["highlights.scm"]),
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
        Grammar::directory("lean", "../../vendor/tree-sitter-lean"),
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
            Outcome::Built { name, .. } => stage(&out, name),
        }
    }
    println!(
        "cargo:rustc-env=EDITOR_SYNTAX_FIXTURE_GRAMMARS_DIRECTORY={}",
        out.display()
    );
}

/// Copies the queries of the grammar `name`, from the package's
/// `queries/<name>/`, to `out/queries/<name>/`.
fn stage(out: &Path, name: &str) {
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
    for file in *files {
        let from = Path::new(PACKAGE_QUERIES).join(name).join(file);
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
