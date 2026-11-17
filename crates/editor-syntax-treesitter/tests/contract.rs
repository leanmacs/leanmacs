//! The tree-sitter adapter held to the syntax port's contract, once for
//! each grammar compiled in: Rust, JSON and Markdown.
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

use editor_syntax::contract::{self, Corpus};
use editor_syntax::{QueryErrorKind, QueryKind, ReparsePolicy};
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
    shipped: &[
        QueryKind::Highlights,
        QueryKind::Injections,
        QueryKind::TextObjects,
        QueryKind::Indents,
    ],
    settings_query: "((macro_invocation (token_tree) @injection.content)\n (#set! injection.language \"rust\")\n (#set! injection.include-children))\n(identifier) @name\n((line_comment) @c (#set! priority 2))\n",
    settings: &[
        &[
            ("injection.language", Some("rust")),
            ("injection.include-children", None),
        ],
        &[],
        &[("priority", Some("2"))],
    ],
    policy: ReparsePolicy::Incremental,
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
    shipped: &[QueryKind::Highlights],
    settings_query: "((pair) @p (#set! key value))\n(number) @n\n",
    settings: &[&[("key", Some("value"))], &[]],
    policy: ReparsePolicy::Incremental,
};

/// The Markdown grammar's corpus: the block grammar, the one listed.
const MARKDOWN: Corpus = Corpus {
    grammar: "markdown",
    texts: &[
        include_str!("../../../tests/syntax/markdown/fenced.md"),
        include_str!("../../../tests/syntax/markdown/blocks.md"),
        include_str!("../../../tests/syntax/markdown/broken.md"),
        "",
        "# Title\n",
        "> é 漢\r\n> 😀\n",
    ],
    pieces: &[
        "x", " ", "\n", "#", "> ", "- ", "```", "`", "*", "1. ", "---\n", "é",
    ],
    query: "(atx_heading heading_content: (inline) @heading)\n(fenced_code_block (info_string) @info) @fence\n(block_quote) @quote\n",
    query_names: &["heading", "info", "fence", "quote"],
    bad_queries: &[
        ("((", QueryErrorKind::Syntax),
        ("(no_such_kind) @x", QueryErrorKind::NodeType),
        ("(atx_heading nope: (inline)) @x", QueryErrorKind::Field),
    ],
    unknown_kind_query: "(paragraph) @p\n(no_such_kind) @x\n",
    shipped: &[QueryKind::Highlights, QueryKind::Injections],
    settings_query: "((fenced_code_block) @f (#set! injection.language \"rust\"))\n(paragraph) @p\n",
    settings: &[&[("injection.language", Some("rust"))], &[]],
    policy: ReparsePolicy::Incremental,
};

#[test]
fn the_tree_sitter_adapter_keeps_the_syntax_ports_contract_for_rust() {
    assert_eq!(contract::check(&TreeSitter, &RUST), [""; 0]);
}

#[test]
fn the_tree_sitter_adapter_keeps_the_syntax_ports_contract_for_json() {
    assert_eq!(contract::check(&TreeSitter, &JSON), [""; 0]);
}

#[test]
fn the_tree_sitter_adapter_keeps_the_syntax_ports_contract_for_markdown() {
    assert_eq!(contract::check(&TreeSitter, &MARKDOWN), [""; 0]);
}
