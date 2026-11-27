//! Compiles each grammar the `languages` package ships from source into a
//! shared library in `OUT_DIR`, with `editor-grammar-build`, and writes the
//! report this crate's binary prints for the set's build
//! (docs/design/packages.md, "A package's grammars"). A grammar added here
//! is a build-dependency in `Cargo.toml` and a declaration in
//! `Languages/Grammars.lean`.

use editor_grammar_build::{Grammar, build};

fn main() {
    build(&[Grammar::package("yaml", "tree-sitter-yaml")]);
}
