//! The adapter's compiled-in table held to the syntax port's contract,
//! once for each grammar in it: Rust, JSON, Markdown, Markdown's inline
//! grammar, TOML and Lean, each with the queries it ships. These are table
//! tests (the crate docs, "Tests"): the table is hidden unless turned on,
//! and the editor's startup turns it on, so these pin what the editor still
//! uses until phase 4 of the roadmap `shipped-grammars-package` removes the
//! table and this file. The same grammars loaded from native libraries are
//! `tests/contract.rs`'s, over the same corpora (`tests/corpora/mod.rs`).

use editor_syntax::contract;
use editor_syntax_treesitter::TreeSitter;

#[path = "corpora/mod.rs"]
mod corpora;

/// An adapter with the compiled-in table turned on: this file's one way
/// to it.
fn with_the_table() -> TreeSitter {
    let syntax = TreeSitter::default();
    #[expect(
        clippy::disallowed_methods,
        reason = "the adapter's table tests pin the compiled-in table the editor's startup turns on, until phase 4 removes it"
    )]
    syntax.use_compiled_grammars();
    syntax
}

#[test]
fn the_compiled_in_rust_keeps_the_syntax_ports_contract() {
    assert_eq!(contract::check(&with_the_table(), &corpora::RUST), [""; 0]);
}

#[test]
fn the_compiled_in_json_keeps_the_syntax_ports_contract() {
    assert_eq!(contract::check(&with_the_table(), &corpora::JSON), [""; 0]);
}

#[test]
fn the_compiled_in_markdown_keeps_the_syntax_ports_contract() {
    assert_eq!(
        contract::check(&with_the_table(), &corpora::MARKDOWN),
        [""; 0]
    );
}

#[test]
fn the_compiled_in_markdown_inline_keeps_the_syntax_ports_contract() {
    assert_eq!(
        contract::check(&with_the_table(), &corpora::MARKDOWN_INLINE),
        [""; 0]
    );
}

#[test]
fn the_compiled_in_toml_keeps_the_syntax_ports_contract() {
    assert_eq!(contract::check(&with_the_table(), &corpora::TOML), [""; 0]);
}

#[test]
fn the_compiled_in_lean_keeps_the_syntax_ports_contract() {
    assert_eq!(contract::check(&with_the_table(), &corpora::LEAN), [""; 0]);
}
