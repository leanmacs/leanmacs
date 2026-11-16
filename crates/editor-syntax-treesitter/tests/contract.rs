//! The tree-sitter adapter held to the syntax port's contract, once for
//! each grammar compiled in.
//!
//! The check is `editor-syntax`'s, the same one its fake passes
//! (`editor_syntax::contract::check`). Its incremental property drives a
//! real `editor_text::Text` and tells the library the edit log's own
//! patches, so this is where `Edit::input_edit` is held to tree-sitter;
//! and over the same edits it holds the grammar crate's shipped highlights
//! query to draw on a reparsed tree what it draws on a fresh one
//! (`contract::HIGHLIGHTS_AFTER_EDITS`).
//! The texts are the fixtures checked in under `tests/syntax/`, read with
//! `include_str!`, and a few written here.

use editor_syntax::QueryErrorKind;
use editor_syntax::contract::{self, Corpus};
use editor_syntax_treesitter::TreeSitter;

/// The Rust grammar's corpus.
const RUST: Corpus = Corpus {
    grammar: "rust",
    texts: &[
        include_str!("../../../tests/syntax/rust/items.rs"),
        include_str!("../../../tests/syntax/rust/strings.rs"),
        include_str!("../../../tests/syntax/rust/crlf.rs"),
        include_str!("../../../tests/syntax/rust/broken.rs"),
        "",
        "  fn f() {}\n\n  ",
        "fn é() -> 漢 { \"😀\" }",
    ],
    pieces: &[
        "x",
        " ",
        "\n",
        "(",
        ")",
        "{",
        "}",
        ";",
        "fn g() {}",
        "\"s\"",
        "// c\n",
        "é",
    ],
    query: "(function_item name: (identifier) @name) @function\n(string_literal) @string\n(line_comment) @comment\n",
    query_names: &["name", "function", "string", "comment"],
    bad_queries: &[
        ("((", QueryErrorKind::Syntax),
        ("(no_such_kind) @x", QueryErrorKind::NodeType),
        (
            "(function_item nope: (identifier)) @x",
            QueryErrorKind::Field,
        ),
        ("((identifier) @x (#eq? @y \"a\"))", QueryErrorKind::Capture),
        ("((identifier) @x (#eq? @x))", QueryErrorKind::Predicate),
        ("(identifier (identifier)) @x", QueryErrorKind::Structure),
    ],
    unknown_kind_query: "(function_item) @f\n(no_such_kind) @x\n",
};

/// The JSON grammar's corpus.
const JSON: Corpus = Corpus {
    grammar: "json",
    texts: &[
        include_str!("../../../tests/syntax/json/object.json"),
        include_str!("../../../tests/syntax/json/values.json"),
        include_str!("../../../tests/syntax/json/broken.json"),
        "",
        "{}",
        "  [ ]  ",
        "{\"é\": \"漢\",\r\n \"😀\": [1]}",
    ],
    pieces: &[
        "1", " ", "\n", ",", "\"k\": 2", "[", "]", "{", "}", "null", "\"", "é",
    ],
    query: "(pair key: (string) @key value: (_) @value)\n(number) @number\n\",\" @comma\n",
    query_names: &["key", "value", "number", "comma"],
    bad_queries: &[
        ("((", QueryErrorKind::Syntax),
        ("(no_such_kind) @x", QueryErrorKind::NodeType),
        ("(pair nope: (string)) @x", QueryErrorKind::Field),
    ],
    unknown_kind_query: "(no_such_kind) @x",
};

#[test]
fn the_tree_sitter_adapter_keeps_the_syntax_ports_contract_for_rust() {
    assert_eq!(contract::check(&TreeSitter, &RUST), [""; 0]);
}

#[test]
fn the_tree_sitter_adapter_keeps_the_syntax_ports_contract_for_json() {
    assert_eq!(contract::check(&TreeSitter, &JSON), [""; 0]);
}
