//! The tree-sitter adapter held to the syntax port's contract, once for
//! each grammar compiled in: Rust, JSON, Markdown, Markdown's inline
//! grammar, TOML and Lean; and once for a grammar loaded from a native
//! library at run time, the fixture INI grammar
//! (`editor-syntax-fixture-ini`), which ships no query and is drawn with
//! the highlights query beside its library (`Corpus::highlights`).
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

use std::path::PathBuf;

use editor_syntax::contract::{self, Corpus};
use editor_syntax::{GrammarName, GrammarSource, QueryErrorKind, QueryKind, ReparsePolicy, Syntax};
use editor_syntax_fixture_ini as fixture;
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
    highlights: None,
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
    highlights: None,
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
    highlights: None,
    settings_query: "((fenced_code_block) @f (#set! injection.language \"rust\"))\n(paragraph) @p\n",
    settings: &[&[("injection.language", Some("rust"))], &[]],
    policy: ReparsePolicy::Incremental,
};

/// The Markdown inline grammar's corpus: the grammar of a paragraph's
/// text, which the block grammar injects into each `(inline)` node. It is
/// reparsed whole: its incremental reparses of texts without errors were
/// seen to differ from a fresh parse.
const MARKDOWN_INLINE: Corpus = Corpus {
    grammar: "markdown_inline",
    texts: &[
        include_str!("../../../tests/syntax/markdown_inline/spans.md"),
        include_str!("../../../tests/syntax/markdown_inline/broken.md"),
        "",
        "*é* `漢`\r\n😀 **b**",
    ],
    pieces: &["x", " ", "*", "**", "`", "[", "]", "(", ")", "\\", "<", "é"],
    query: "(emphasis) @emphasis\n(code_span) @code\n(inline_link (link_destination) @destination)\n",
    query_names: &["emphasis", "code", "destination"],
    bad_queries: &[
        ("((", QueryErrorKind::Syntax),
        ("(no_such_kind) @x", QueryErrorKind::NodeType),
        ("(inline_link nope: (link_text)) @x", QueryErrorKind::Field),
    ],
    unknown_kind_query: "(emphasis) @e\n(no_such_kind) @x\n",
    shipped: &[QueryKind::Highlights, QueryKind::Injections],
    highlights: None,
    settings_query: "((code_span) @c (#set! injection.language \"rust\"))\n(emphasis) @e\n",
    settings: &[&[("injection.language", Some("rust"))], &[]],
    policy: ReparsePolicy::Whole,
};

/// The TOML grammar's corpus. Its grammar has no fields, so `nope:` is
/// refused as a field.
const TOML: Corpus = Corpus {
    grammar: "toml",
    texts: &[
        include_str!("../../../tests/syntax/toml/manifest.toml"),
        include_str!("../../../tests/syntax/toml/values.toml"),
        include_str!("../../../tests/syntax/toml/Cargo.lock"),
        include_str!("../../../tests/syntax/toml/broken.toml"),
        "",
        "[a]\n",
        "\"é\" = '漢'\r\n[\"😀\"]\r\nk = [1]\r\n",
    ],
    pieces: &[
        "x",
        " ",
        "\n",
        "=",
        "\"",
        "'",
        "[",
        "]",
        "{",
        "}",
        ",",
        ".",
        "1",
        "# c\n",
        "[t]\n",
        "k = \"v\"\n",
        "é",
    ],
    query: "(table (bare_key) @header) @table\n(pair (bare_key) @key)\n(string) @string\n(comment) @comment\n",
    query_names: &["header", "table", "key", "string", "comment"],
    bad_queries: &[
        ("((", QueryErrorKind::Syntax),
        ("(no_such_kind) @x", QueryErrorKind::NodeType),
        ("(pair nope: (string)) @x", QueryErrorKind::Field),
        ("((bare_key) @x (#eq? @y \"a\"))", QueryErrorKind::Capture),
        ("((bare_key) @x (#eq? @x))", QueryErrorKind::Predicate),
        ("(bare_key (pair)) @x", QueryErrorKind::Structure),
    ],
    unknown_kind_query: "(pair) @p\n(no_such_kind) @x\n",
    shipped: &[QueryKind::Highlights],
    highlights: None,
    settings_query: "((string) @s (#set! injection.language \"json\"))\n(pair) @p\n",
    settings: &[&[("injection.language", Some("json"))], &[]],
    policy: ReparsePolicy::Incremental,
};

/// The Lean grammar's corpus. Its multibyte CRLF text has no string that
/// a range of `IN_RANGES` starts inside: a range that starts on a
/// multibyte character inside a string leaves an `ERROR` leaf that starts
/// in the gap before it, which is tree-sitter's error recovery across
/// included ranges and which the Rust grammar shows on the same cut.
const LEAN: Corpus = Corpus {
    grammar: "lean",
    texts: &[
        include_str!("../../../tests/syntax/lean/Basic.lean"),
        include_str!("../../../tests/syntax/lean/Strings.lean"),
        include_str!("../../../tests/syntax/lean/Programs.lean"),
        include_str!("../../../tests/syntax/lean/broken.lean"),
        "",
        "def x := 1\n",
        "def é : String := \"😀\"\r\n-- 漢\r\n",
    ],
    pieces: &[
        "x",
        " ",
        "\n",
        "(",
        ")",
        "{",
        "}",
        ":",
        ":=",
        "\"",
        "|",
        ".",
        "1",
        "-- c\n",
        "def f := 1\n",
        "fun x => x",
        "é",
    ],
    query: "(structure name: (identifier) @name) @structure\n(str_lit) @string\n(line_comment) @comment\n",
    query_names: &["name", "structure", "string", "comment"],
    bad_queries: &[
        ("((", QueryErrorKind::Syntax),
        ("(no_such_kind) @x", QueryErrorKind::NodeType),
        ("(def nope: (identifier)) @x", QueryErrorKind::Field),
        ("((identifier) @x (#eq? @y \"a\"))", QueryErrorKind::Capture),
        ("((identifier) @x (#eq? @x))", QueryErrorKind::Predicate),
        ("(identifier (def)) @x", QueryErrorKind::Structure),
    ],
    unknown_kind_query: "(def) @d\n(no_such_kind) @x\n",
    shipped: &[QueryKind::Highlights],
    highlights: None,
    settings_query: "((str_lit) @s (#set! injection.language \"json\"))\n(def) @d\n",
    settings: &[&[("injection.language", Some("json"))], &[]],
    policy: ReparsePolicy::Incremental,
};

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

#[test]
fn the_tree_sitter_adapter_keeps_the_syntax_ports_contract_for_rust() {
    assert_eq!(contract::check(&TreeSitter::default(), &RUST), [""; 0]);
}

#[test]
fn the_tree_sitter_adapter_keeps_the_syntax_ports_contract_for_json() {
    assert_eq!(contract::check(&TreeSitter::default(), &JSON), [""; 0]);
}

#[test]
fn the_tree_sitter_adapter_keeps_the_syntax_ports_contract_for_markdown() {
    assert_eq!(contract::check(&TreeSitter::default(), &MARKDOWN), [""; 0]);
}

#[test]
fn the_tree_sitter_adapter_keeps_the_syntax_ports_contract_for_markdown_inline() {
    assert_eq!(
        contract::check(&TreeSitter::default(), &MARKDOWN_INLINE),
        [""; 0]
    );
}

#[test]
fn the_tree_sitter_adapter_keeps_the_syntax_ports_contract_for_toml() {
    assert_eq!(contract::check(&TreeSitter::default(), &TOML), [""; 0]);
}

#[test]
fn the_tree_sitter_adapter_keeps_the_syntax_ports_contract_for_lean() {
    assert_eq!(contract::check(&TreeSitter::default(), &LEAN), [""; 0]);
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
