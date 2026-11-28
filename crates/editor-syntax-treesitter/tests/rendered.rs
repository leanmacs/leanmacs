//! The rendered queries of the Markdown grammars, the repository's own
//! (`queries/markdown/rendered.scm` and `queries/markdown_inline/rendered.scm`),
//! and the injections a text parsed once for a rendered view finds its
//! layers with (`TreeSitter::rendered_injections`), on the real grammars:
//! which nodes each capture names, and the layers a Markdown text parsed
//! once (`editor_syntax::once::parse`) answers. What the renderer does with them is
//! Lean's (`lean/Editor/Markdown/`).

use std::collections::BTreeMap;
use std::ops::Range;
use std::sync::Arc;

use editor_syntax::inject;
use editor_syntax::once::{self, OnceLanguage, OnceLayer};
use editor_syntax::query::captures_in;
use editor_syntax::{GrammarName, QueryKind, Syntax};
use editor_syntax_treesitter::{TreeSitter, TreeSitterQuery};
use editor_text::Text;

/// A document with a paragraph, a heading that opens a section, a fence, a
/// table whose cell holds a code span, and a list with a nested list.
const DOCUMENT: &str = "Intro *text*.\n\n## Two\n\n```rust\nfn f() {}\n```\n\n| a | `x` |\n|---|---|\n| 1 | 2 |\n\n- one\n  - nested\n- two\n";

/// A paragraph's text, as the inline grammar sees it: an emphasis and an
/// inline link with a title.
const INLINE: &str = "An *em* and [the text](https://example.com \"Title\").";

/// Each capture of the shipped rendered query of `grammar` over `text`, as
/// its name and the bytes it covers.
fn captures(grammar: &str, text: &str) -> Vec<(String, Range<usize>)> {
    let syntax = TreeSitter::default();
    let grammar = GrammarName::new(grammar);
    let source = syntax
        .shipped_query(&grammar, QueryKind::Rendered)
        .expect("a shipped rendered query");
    let query = syntax
        .compile(&grammar, &source)
        .expect("the query compiles");
    let names = syntax.capture_names(&query);
    let snapshot = Text::from(text).snapshot();
    let mut parser = syntax.parser(&grammar).expect("the grammar");
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

/// The ranges captured as `name`, in order.
fn named(captures: &[(String, Range<usize>)], name: &str) -> Vec<Range<usize>> {
    captures
        .iter()
        .filter(|(captured, _)| captured == name)
        .map(|(_, range)| range.clone())
        .collect()
}

/// The range of the first place `needle` is in `text`.
fn first(text: &str, needle: &str) -> Range<usize> {
    let start = text.find(needle).expect("in the text");
    start..start + needle.len()
}

/// Whether a capture named `name` is over exactly `bytes`.
fn over(captures: &[(String, Range<usize>)], name: &str, bytes: &Range<usize>) -> bool {
    captures
        .iter()
        .any(|(captured, range)| captured == name && range == bytes)
}

/// Whether the text of a capture named `name` starts with `prefix`.
fn starts_with(text: &str, ranges: &[Range<usize>], prefix: &str) -> bool {
    ranges
        .iter()
        .any(|range| text[range.clone()].starts_with(prefix))
}

#[test]
fn each_top_level_block_is_captured_once_as_a_block_a_sections_included_and_a_nested_lists_not() {
    let captured = captures("markdown", DOCUMENT);
    let blocks = named(&captured, "block");
    let texts: Vec<&str> = blocks
        .iter()
        .map(|range| DOCUMENT[range.clone()].lines().next().unwrap_or(""))
        .collect();
    // The paragraph, then the heading and the blocks of its section.
    assert_eq!(
        texts,
        ["Intro *text*.", "## Two", "```rust", "| a | `x` |", "- one"],
        "{captured:?}"
    );
    // The nested list is a list, but not a block.
    let lists = named(&captured, "list");
    assert_eq!(lists.len(), 2, "{captured:?}");
    assert!(starts_with(DOCUMENT, &lists, "- nested"));
    assert!(!starts_with(DOCUMENT, &blocks, "- nested"));
}

#[test]
fn a_heading_is_captured_by_its_level_with_its_marker_hidden_and_its_text_as_content() {
    let captured = captures("markdown", DOCUMENT);
    assert!(
        over(&captured, "heading.2", &first(DOCUMENT, "## Two\n")),
        "{captured:?}"
    );
    assert!(over(&captured, "hide", &first(DOCUMENT, "##")));
    assert!(over(&captured, "heading.content", &first(DOCUMENT, "Two")));
}

#[test]
fn a_fence_is_captured_with_its_language_and_its_content() {
    let captured = captures("markdown", DOCUMENT);
    assert!(over(&captured, "code.language", &first(DOCUMENT, "rust")));
    assert!(
        over(&captured, "code.content", &first(DOCUMENT, "fn f() {}\n")),
        "{captured:?}"
    );
}

#[test]
fn a_tables_cells_are_captured_each_and_its_delimiter_row_once() {
    let captured = captures("markdown", DOCUMENT);
    let cells: Vec<&str> = named(&captured, "table.cell")
        .into_iter()
        .map(|range| DOCUMENT[range].trim())
        .collect();
    assert_eq!(cells, ["a", "`x`", "1", "2"], "{captured:?}");
    assert_eq!(
        named(&captured, "table.delimiter"),
        [first(DOCUMENT, "|---|---|")]
    );
}

#[test]
fn the_rendered_injections_compile_and_make_a_table_cell_an_inline_layer_beside_every_inline() {
    let syntax = TreeSitter::default();
    let grammar = GrammarName::new("markdown");
    let source = syntax
        .rendered_injections(&grammar)
        .expect("markdown's rendered injections");
    let query = syntax
        .compile(&grammar, &source)
        .expect("the query compiles");
    let snapshot = Text::from(DOCUMENT).snapshot();
    let mut parser = syntax.parser(&grammar).expect("the grammar");
    let tree = syntax.parse(&mut parser, &snapshot, None);
    let whole = 0..DOCUMENT.len();
    let found = inject::found(
        &syntax,
        &query,
        &tree,
        &snapshot,
        std::slice::from_ref(&whole),
        &|name| name == "markdown_inline",
    );
    let contents: Vec<&str> = found
        .iter()
        .map(|found| DOCUMENT[found.ranges[0].clone()].trim())
        .collect();
    assert!(contents.contains(&"`x`"), "{contents:?}");
    assert!(contents.contains(&"Intro *text*."), "{contents:?}");
    assert!(contents.contains(&"Two"), "{contents:?}");
    assert!(contents.contains(&"nested"), "{contents:?}");
    // No other grammar has rendered injections.
    assert_eq!(
        syntax.rendered_injections(&GrammarName::new("markdown_inline")),
        None
    );
}

#[test]
fn an_inline_links_text_destination_and_brackets_are_captured() {
    let captured = captures("markdown_inline", INLINE);
    assert!(over(&captured, "link.text", &first(INLINE, "the text")));
    assert!(over(
        &captured,
        "link.destination",
        &first(INLINE, "https://example.com")
    ));
    assert!(over(&captured, "link.title", &first(INLINE, "\"Title\"")));
    for bracket in ["[", "]", "(", ")"] {
        let at = INLINE.rfind(bracket).expect("a bracket");
        assert!(over(&captured, "hide", &(at..at + 1)), "{bracket}");
    }
}

#[test]
fn an_emphasis_is_captured_with_its_two_delimiters_hidden() {
    let captured = captures("markdown_inline", INLINE);
    let emphasis = first(INLINE, "*em*");
    assert!(over(&captured, "emphasis", &emphasis));
    assert!(over(
        &captured,
        "hide",
        &(emphasis.start..emphasis.start + 1)
    ));
    assert!(over(&captured, "hide", &(emphasis.end - 1..emphasis.end)));
}

/// The language `grammar` of a text parsed once, answered with its shipped
/// query of `kind`, finding layers with `injections`, if given.
fn once_language(
    grammar: &str,
    kind: QueryKind,
    injections: Option<String>,
) -> OnceLanguage<TreeSitterQuery> {
    let syntax = TreeSitter::default();
    let name = GrammarName::new(grammar);
    let compile = |source: &str| Arc::new(syntax.compile(&name, source).expect("it compiles"));
    OnceLanguage {
        query: compile(&syntax.shipped_query(&name, kind).expect("a shipped query")),
        injections: injections.as_deref().map(compile),
        grammar: name.clone(),
    }
}

#[test]
fn once_parse_of_markdown() {
    let syntax = TreeSitter::default();
    let text = format!("{DOCUMENT}\n```json\n{{}}\n```\n");
    let shipped =
        |grammar: &str| syntax.shipped_query(&GrammarName::new(grammar), QueryKind::Injections);
    // Markdown with its rendered queries and injections, and Rust with its
    // highlights; JSON is not in the table.
    let table = BTreeMap::from([
        (
            "markdown".to_owned(),
            once_language(
                "markdown",
                QueryKind::Rendered,
                syntax.rendered_injections(&GrammarName::new("markdown")),
            ),
        ),
        (
            "markdown_inline".to_owned(),
            once_language(
                "markdown_inline",
                QueryKind::Rendered,
                shipped("markdown_inline"),
            ),
        ),
        (
            "rust".to_owned(),
            once_language("rust", QueryKind::Highlights, shipped("rust")),
        ),
    ]);
    let snapshot = Text::from(text.as_str()).snapshot();
    let layers = once::parse(&syntax, "markdown", &snapshot, &table).expect("markdown parses");

    assert_eq!(layers[0].language, "markdown");
    let whole = 0..text.len();
    assert_eq!(layers[0].depth, 0);
    assert_eq!(layers[0].ranges, std::slice::from_ref(&whole));
    assert_eq!(layers.iter().filter(|layer| layer.depth == 0).count(), 1);
    // An inline layer for each paragraph's and heading's text and for each
    // table cell.
    let inline: Vec<&str> = layers
        .iter()
        .filter(|layer| layer.language == "markdown_inline")
        .map(|layer| text[layer.ranges[0].clone()].trim())
        .collect();
    assert_eq!(
        inline,
        [
            "Intro *text*.",
            "Two",
            "a",
            "`x`",
            "1",
            "2",
            "one",
            "nested",
            "two"
        ],
        "{layers:?}"
    );
    // One Rust layer, over the fence's content, holding a keyword for `fn`.
    let rust: Vec<&OnceLayer> = layers
        .iter()
        .filter(|layer| layer.language == "rust")
        .collect();
    assert_eq!(rust.len(), 1, "{layers:?}");
    assert_eq!(rust[0].ranges, [first(&text, "fn f() {}\n")]);
    let names = syntax.capture_names(&table["rust"].query);
    let fn_keyword = first(&text, "fn");
    assert!(
        rust[0]
            .captures
            .iter()
            .any(|capture| names[capture.capture as usize] == "keyword"
                && capture.range() == fn_keyword),
        "{:?}",
        rust[0].captures
    );
    // The JSON fence, a language the table lacks, has no layer.
    assert!(
        layers
            .iter()
            .all(|layer| !text[layer.ranges[0].clone()].starts_with("{}"))
    );
}
