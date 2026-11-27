//! The tree-sitter adapter held to the syntax port's contract, once for
//! each of the six grammars it compiles in, loaded instead from the native
//! library `editor-syntax-fixture-grammars` builds from the same pinned
//! source: Rust, JSON, Markdown, Markdown's inline grammar, TOML and Lean;
//! and once for the fixture INI grammar (`editor-syntax-fixture-ini`). A
//! grammar registered from a library ships no query, so each is drawn with
//! the highlights query beside its library (`Corpus::highlights`). The
//! compiled-in table itself is held to the contract by `tests/table.rs`.
//!
//! The check is `editor-syntax`'s, the same one its fake passes
//! (`editor_syntax::contract::check`). Its incremental property drives a
//! real `editor_text::Text` and tells the library the edit log's own
//! patches, so this is where `Edit::input_edit` is held to tree-sitter;
//! and over the same edits it holds the highlights query to draw on a
//! reparsed tree what it draws on a fresh one
//! (`contract::HIGHLIGHTS_AFTER_EDITS`). The corpora are shared with
//! `tests/table.rs` (`tests/corpora/mod.rs`).

use std::path::PathBuf;

use editor_syntax::contract::{self, Corpus};
use editor_syntax::{GrammarName, GrammarSource, QueryErrorKind, ReparsePolicy, Syntax};
use editor_syntax_fixture_grammars as grammars;
use editor_syntax_fixture_ini as fixture;
use editor_syntax_treesitter::TreeSitter;

#[path = "corpora/mod.rs"]
mod corpora;

/// The fixture INI grammar's corpus: a grammar registered from a native
/// library, so it ships no query, and its highlights are the query beside
/// its library. It declares itself incremental when registered, so the
/// properties over edits compare reparses.
const INI: Corpus = Corpus {
    grammar: fixture::NAME,
    texts: &[
        include_str!("../../../tests/syntax/ini/settings.ini"),
        include_str!("../../../tests/syntax/ini/broken.ini"),
        "",
        "[s]\n",
        "k = é 漢\r\n; 😀\r\n",
    ],
    pieces: &[
        "x", " ", "\n", "[", "]", "=", ";", "# c\n", "[t]\n", "k = v\n", "é",
    ],
    query: "(section name: (section_name) @name) @section\n(pair key: (key) @key)\n(comment) @comment\n",
    query_names: &["name", "section", "key", "comment"],
    bad_queries: &[
        ("((", QueryErrorKind::Syntax),
        ("(no_such_kind) @x", QueryErrorKind::NodeType),
        ("(pair nope: (key)) @x", QueryErrorKind::Field),
        ("((key) @x (#eq? @y \"a\"))", QueryErrorKind::Capture),
        ("((key) @x (#eq? @x))", QueryErrorKind::Predicate),
        ("(key (pair)) @x", QueryErrorKind::Structure),
    ],
    unknown_kind_query: "(pair) @p\n(no_such_kind) @x\n",
    shipped: &[],
    highlights: Some(fixture::HIGHLIGHTS),
    settings_query: "((value) @v (#set! injection.language \"json\"))\n(pair) @p\n",
    settings: &[&[("injection.language", Some("json"))], &[]],
    policy: ReparsePolicy::Incremental,
};

/// Holds `grammar`, registered from its native library on a fresh adapter
/// with its policy, to the contract over `corpus`, which ships no query
/// and draws with the library's highlights.
fn check_loaded(grammar: &grammars::Grammar, corpus: Corpus) -> Vec<&'static str> {
    let syntax = TreeSitter::default();
    let policy = if grammar.incremental {
        ReparsePolicy::Incremental
    } else {
        ReparsePolicy::Whole
    };
    let source = GrammarSource {
        library: PathBuf::from(grammar.library),
        symbol: grammar.symbol.to_owned(),
        policy: Some(policy),
    };
    assert_eq!(syntax.register(&source), Ok(GrammarName::new(grammar.name)));
    assert_eq!(corpus.policy, policy, "{}", grammar.name);
    contract::check(
        &syntax,
        &Corpus {
            shipped: &[],
            highlights: Some(grammar.highlights),
            ..corpus
        },
    )
}

#[test]
fn the_tree_sitter_adapter_keeps_the_syntax_ports_contract_for_rust_loaded_from_a_native_library() {
    assert_eq!(check_loaded(&grammars::RUST, corpora::RUST), [""; 0]);
}

#[test]
fn the_tree_sitter_adapter_keeps_the_syntax_ports_contract_for_json_loaded_from_a_native_library() {
    assert_eq!(check_loaded(&grammars::JSON, corpora::JSON), [""; 0]);
}

#[test]
fn the_tree_sitter_adapter_keeps_the_syntax_ports_contract_for_markdown_loaded_from_a_native_library()
 {
    assert_eq!(
        check_loaded(&grammars::MARKDOWN, corpora::MARKDOWN),
        [""; 0]
    );
}

#[test]
fn the_tree_sitter_adapter_keeps_the_syntax_ports_contract_for_markdown_inline_loaded_from_a_native_library()
 {
    assert_eq!(
        check_loaded(&grammars::MARKDOWN_INLINE, corpora::MARKDOWN_INLINE),
        [""; 0]
    );
}

#[test]
fn the_tree_sitter_adapter_keeps_the_syntax_ports_contract_for_toml_loaded_from_a_native_library() {
    assert_eq!(check_loaded(&grammars::TOML, corpora::TOML), [""; 0]);
}

#[test]
fn the_tree_sitter_adapter_keeps_the_syntax_ports_contract_for_lean_loaded_from_a_native_library() {
    assert_eq!(check_loaded(&grammars::LEAN, corpora::LEAN), [""; 0]);
}

#[test]
fn the_tree_sitter_adapter_keeps_the_syntax_ports_contract_for_ini_loaded_from_a_native_library() {
    let syntax = TreeSitter::default();
    let source = GrammarSource {
        library: PathBuf::from(fixture::LIBRARY),
        symbol: fixture::SYMBOL.to_owned(),
        policy: Some(ReparsePolicy::Incremental),
    };

    assert_eq!(
        syntax.register(&source),
        Ok(GrammarName::new(fixture::NAME))
    );
    assert_eq!(contract::check(&syntax, &INI), [""; 0]);
}
