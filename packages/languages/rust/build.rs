//! Compiles each grammar the `languages` package ships from source into a
//! shared library in `OUT_DIR`, with `editor-grammar-build`, and writes the
//! report this crate's binary prints for the set's build
//! (docs/design/packages.md, "A package's grammars"). Each crates.io
//! grammar is a build-dependency in `Cargo.toml`; `lean` is the vendored
//! directory `vendor/tree-sitter-lean`, taken from this crate's directory,
//! and no dependency (`Cargo.toml` says why). A grammar added here is a
//! source there and a declaration in `Languages/Grammars.lean`, in the same
//! order: the former built-ins, `yaml`, then the popular languages.

use editor_grammar_build::{Grammar, build};

fn main() {
    build(&[
        Grammar::package("rust", "tree-sitter-rust"),
        Grammar::package("json", "tree-sitter-json"),
        Grammar::package_in("markdown", "tree-sitter-md", "tree-sitter-markdown"),
        Grammar::package_in(
            "markdown_inline",
            "tree-sitter-md",
            "tree-sitter-markdown-inline",
        ),
        Grammar::package("toml", "tree-sitter-toml-ng"),
        Grammar::directory("lean", "../../../vendor/tree-sitter-lean"),
        Grammar::package("yaml", "tree-sitter-yaml"),
        Grammar::package("java", "tree-sitter-java"),
        Grammar::package("swift", "tree-sitter-swift"),
        Grammar::package("ruby", "tree-sitter-ruby"),
        Grammar::package("python", "tree-sitter-python"),
        Grammar::package("javascript", "tree-sitter-javascript"),
        Grammar::package_in("typescript", "tree-sitter-typescript", "typescript"),
        Grammar::package_in("tsx", "tree-sitter-typescript", "tsx"),
        Grammar::package("c", "tree-sitter-c"),
        Grammar::package("cpp", "tree-sitter-cpp"),
        Grammar::package("clojure_orchard", "tree-sitter-clojure-orchard"),
    ]);
}
