//! The shipped highlights queries of the Markdown grammars, the
//! repository's own (`queries/markdown/highlights.scm` and
//! `queries/markdown_inline/highlights.scm`), on the real grammars: a
//! heading is captured by its level, a code block apart from an inline code
//! span, a list marker, a block quote and a table's header row each by a
//! name of its own, and a link's title as a link, not as a code span. Which
//! face each name is drawn in is Lean's (`Highlight.defaultFaces`).

use std::ops::Range;

use editor_syntax::query::captures_in;
use editor_syntax::{GrammarName, QueryKind, Syntax};
use editor_syntax_treesitter::TreeSitter;
use editor_text::Text;

/// A document with a heading of each kind, a list, a quote, a fence, a
/// table and a link reference definition with a title.
const DOCUMENT: &str = "# One\n\n### Three\n\nSetext\n======\n\n- item\n\n> quote\n\n```rust\nfn f() {}\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n[ref]: /url \"Block title\"\n";

/// A paragraph's text, as the inline grammar sees it: a code span and a
/// link with a title.
const INLINE: &str = "Some `code` and [link](/url \"Inline title\").";

/// Each capture of the shipped highlights query of the grammar `grammar`
/// over `text`, as its name and the bytes it covers.
fn captures(grammar: &str, text: &str) -> Vec<(String, Range<usize>)> {
    let syntax = TreeSitter::default();
    let grammar = GrammarName::new(grammar);
    let source = syntax
        .shipped_query(&grammar, QueryKind::Highlights)
        .expect("a shipped highlights query");
    let query = syntax
        .compile(&grammar, &source)
        .expect("the query compiles");
    let names = syntax.capture_names(&query);
    let snapshot = Text::from(text).snapshot();
    let mut parser = syntax.parser(&grammar).expect("the markdown grammar");
    let tree = syntax.parse(&mut parser, &snapshot, None);
    captures_in(&syntax, &query, &tree, &snapshot, 0..text.len())
        .expect("the whole text")
        .into_iter()
        .map(|capture| {
            (
                names[capture.capture as usize].clone(),
                capture.start..capture.end,
            )
        })
        .collect()
}

/// The range of the first place `needle` is in `text`.
fn first(text: &str, needle: &str) -> Range<usize> {
    let start = text.find(needle).expect("in the text");
    start..start + needle.len()
}

/// Whether some capture named `name` covers `bytes`.
fn covers(captures: &[(String, Range<usize>)], name: &str, bytes: &Range<usize>) -> bool {
    captures.iter().any(|(captured, range)| {
        captured == name && range.start <= bytes.start && bytes.end <= range.end
    })
}

#[test]
fn markdowns_block_query_captures_headings_by_level_and_code_blocks_quotes_list_markers_and_table_headers_by_name()
 {
    let captured = captures("markdown", DOCUMENT);
    let expected = [
        ("text.heading.1", first(DOCUMENT, "One")),
        ("text.heading.3", first(DOCUMENT, "Three")),
        ("text.heading.1", first(DOCUMENT, "Setext")),
        ("text.code-block", first(DOCUMENT, "fn f() {}")),
        ("text.list-marker", first(DOCUMENT, "-")),
        ("text.quote", first(DOCUMENT, "quote")),
        ("text.table-header", first(DOCUMENT, "| a | b |")),
    ];
    for (name, bytes) in &expected {
        assert!(
            covers(&captured, name, bytes),
            "{name} over {:?}: {captured:?}",
            &DOCUMENT[bytes.clone()]
        );
    }
    // The crate's own name for a heading is gone, and no capture named as
    // a code span touches the fenced code block.
    assert!(
        captured.iter().all(|(name, _)| name != "text.title"),
        "{captured:?}"
    );
    let fence = first(DOCUMENT, "```rust\nfn f() {}\n```");
    assert!(
        !captured.iter().any(|(name, range)| {
            name == "text.literal" && range.start < fence.end && fence.start < range.end
        }),
        "{captured:?}"
    );
    // A heading of one level is not captured as another's.
    assert!(!covers(
        &captured,
        "text.heading.1",
        &first(DOCUMENT, "Three")
    ));
}

#[test]
fn markdowns_block_query_captures_a_link_reference_definitions_title_as_a_link() {
    let captured = captures("markdown", DOCUMENT);
    let title = first(DOCUMENT, "\"Block title\"");
    assert!(covers(&captured, "text.reference", &title), "{captured:?}");
    assert!(!covers(&captured, "text.literal", &title), "{captured:?}");
}

#[test]
fn markdowns_inline_query_captures_a_code_span_as_a_literal_and_a_links_title_as_a_link() {
    let captured = captures("markdown_inline", INLINE);
    let title = first(INLINE, "\"Inline title\"");
    assert!(
        covers(&captured, "text.literal", &first(INLINE, "`code`")),
        "{captured:?}"
    );
    assert!(covers(&captured, "text.reference", &title), "{captured:?}");
    assert!(!covers(&captured, "text.literal", &title), "{captured:?}");
}
