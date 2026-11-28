//! The injection rule (`editor_syntax::inject`) on the real grammars:
//! Markdown's fences and its inline text, by the block grammar's own
//! injections query, and a Rust macro's token tree, by the Rust grammar's.
//! The six grammars are registered from the native libraries
//! `editor-syntax-fixture-grammars` builds, and their queries are the ones
//! staged beside them, the `languages` package's.
//!
//! A layer's tree is held to the content parsed alone and shifted by its
//! offset, the oracle a spike grounded on 2026-11-16 (a fence's content
//! parsed as Rust with included ranges gives the nodes of the content
//! parsed alone).

use std::collections::BTreeMap;
use std::ops::Range;
use std::sync::Arc;

use editor_syntax::highlight::Highlighter;
use editor_syntax::inject::{self, Injections, Language, Layer};
use editor_syntax::{GrammarName, GrammarSource, Node, ReparsePolicy, Syntax};
use editor_syntax_fixture_grammars as grammars;
use editor_syntax_treesitter::{TreeSitter, TreeSitterQuery, TreeSitterTree};
use editor_text::{Point, Text};

/// The fixture of fences.
const FENCED: &str = include_str!("../../../tests/syntax/markdown/fenced.md");

/// An adapter with the six fixture grammars registered, each with its
/// policy.
fn syntax() -> TreeSitter {
    let syntax = TreeSitter::default();
    for grammar in grammars::ALL {
        let policy = if grammar.incremental {
            ReparsePolicy::Incremental
        } else {
            ReparsePolicy::Whole
        };
        let source = GrammarSource {
            library: grammar.library.into(),
            symbol: grammar.symbol.to_owned(),
            policy: Some(policy),
        };
        assert_eq!(syntax.register(&source), Ok(GrammarName::new(grammar.name)));
    }
    syntax
}

/// The fixture grammar `name`.
fn fixture(name: &str) -> grammars::Grammar {
    grammars::ALL
        .into_iter()
        .find(|grammar| grammar.name == name)
        .unwrap()
}

/// `source`, a query of `grammar`, compiled.
fn compiled(grammar: &str, source: &str) -> Arc<TreeSitterQuery> {
    Arc::new(
        syntax()
            .compile(&GrammarName::new(grammar), source)
            .unwrap(),
    )
}

/// The language `grammar`, drawn with the highlights staged beside its
/// library, each capture in a face named after it, with its injections, if
/// it has any.
fn language(grammar: &str) -> Language<TreeSitterQuery> {
    let fixture = fixture(grammar);
    let highlights = compiled(grammar, fixture.highlights);
    let names = syntax().capture_names(&highlights);
    let faces = names.iter().cloned().map(Some).collect();
    Language {
        highlighter: Arc::new(Highlighter::new(highlights, names.len(), faces).unwrap()),
        injections: fixture.injections.map(|source| compiled(grammar, source)),
        grammar: GrammarName::new(grammar),
    }
}

/// `host`'s injections, with every registered grammar a language of its
/// name.
fn injections(host: &str) -> Injections<TreeSitterQuery> {
    Injections {
        query: fixture(host)
            .injections
            .map(|source| compiled(host, source)),
        languages: syntax()
            .grammars()
            .into_iter()
            .map(|grammar| (grammar.0.clone(), language(&grammar.0)))
            .collect::<BTreeMap<_, _>>(),
    }
}

/// The layers of `text` parsed with `host`.
fn layers_of(host: &str, text: &str) -> Vec<Layer<TreeSitterTree>> {
    let snapshot = Text::from(text).snapshot();
    let (_, layers) = inject::fresh(
        &syntax(),
        &GrammarName::new(host),
        &injections(host),
        &snapshot,
    )
    .unwrap();
    layers
}

/// The range of the `nth` place `needle` is in `text`, from 0.
fn nth(text: &str, needle: &str, nth: usize) -> Range<usize> {
    let start = text.match_indices(needle).nth(nth).unwrap().0;
    start..start + needle.len()
}

/// The nodes of `content` parsed alone with `grammar`, moved to `offset`
/// of a text where it starts at the start of row `row`.
fn alone_at(grammar: &str, content: &str, offset: usize, row: usize) -> Vec<Node> {
    let snapshot = Text::from(content).snapshot();
    let syntax = syntax();
    let mut parser = syntax.parser(&GrammarName::new(grammar)).unwrap();
    let tree = syntax.parse(&mut parser, &snapshot, None);
    syntax
        .nodes(&tree)
        .into_iter()
        .map(|node| {
            let at = |point: Point| Point::new(point.row + row, point.column);
            Node {
                start: node.start + offset,
                end: node.end + offset,
                start_point: at(node.start_point),
                end_point: at(node.end_point),
                ..node
            }
        })
        .collect()
}

#[test]
fn a_fenced_rust_blocks_layer_is_its_content_parsed_as_rust() {
    let layers = layers_of("markdown", FENCED);
    let content = "fn main() {\n    let x = (1, [2, 3]);\n    println!(\"{x:?}\");\n}\n";
    let range = nth(FENCED, content, 0);
    let row = FENCED[..range.start].matches('\n').count();

    let rust = layers
        .iter()
        .find(|layer| layer.language == "rust" && layer.depth == 1)
        .unwrap();
    assert_eq!(rust.ranges, std::slice::from_ref(&range));
    assert_eq!(rust.grammar, GrammarName::new("rust"));
    assert_eq!(
        TreeSitter::default().nodes(&rust.tree),
        alone_at("rust", content, range.start, row)
    );
}

#[test]
fn a_fenced_json_block_is_a_json_layer_and_an_unknown_language_none() {
    let layers = layers_of("markdown", FENCED);
    let found: Vec<(&str, u32, Vec<Range<usize>>)> = layers
        .iter()
        .map(|layer| (layer.language.as_str(), layer.depth, layer.ranges.clone()))
        .collect();

    let json = nth(FENCED, "{\"a\": [1, true, null]}\n", 0);
    assert!(found.contains(&("json", 1, vec![json])));
    // `cobol` names no grammar, so it is no layer; inline text is a
    // `markdown_inline` layer.
    assert!(
        found
            .iter()
            .all(|(language, _, _)| ["rust", "json", "markdown_inline"].contains(language))
    );
    let cobol = nth(FENCED, "DISPLAY", 0);
    assert!(
        found
            .iter()
            .all(|(_, _, ranges)| ranges.iter().all(|range| !range.contains(&cobol.start)))
    );
}

#[test]
fn a_paragraphs_inline_node_is_a_markdown_inline_layer() {
    let layers = layers_of("markdown", FENCED);
    let content = "A Rust block:";
    let range = nth(FENCED, content, 0);
    let row = FENCED[..range.start].matches('\n').count();

    let inline = layers
        .iter()
        .find(|layer| layer.language == "markdown_inline" && layer.ranges == [range.clone()])
        .unwrap();
    assert_eq!(inline.grammar, GrammarName::new("markdown_inline"));
    assert_eq!(inline.depth, 1);
    assert_eq!(
        TreeSitter::default().nodes(&inline.tree),
        alone_at("markdown_inline", content, range.start, row)
    );
}

#[test]
fn a_block_quoted_fences_layer_leaves_out_each_quote_marker() {
    let layers = layers_of("markdown", FENCED);
    let lines = ["fn quoted() -> u8 {\n", "    7\n", "}\n"];
    // Each line found after the one before it.
    let mut from = nth(FENCED, "> ```rust", 0).end;
    let expected: Vec<Range<usize>> = lines
        .iter()
        .map(|line| {
            let start = from + FENCED[from..].find(line).unwrap();
            from = start + line.len();
            start..from
        })
        .collect();

    let quoted = layers
        .iter()
        .find(|layer| layer.language == "rust" && layer.ranges.len() > 1)
        .unwrap();
    assert_eq!(quoted.ranges, expected);
    // Each line's `> ` is just before its range, and left out.
    for range in &quoted.ranges {
        assert_eq!(&FENCED[range.start - 2..range.start], "> ");
    }
}

#[test]
fn a_fence_in_a_list_item_is_a_rust_layer_too() {
    let layers = layers_of("markdown", FENCED);
    let listed = nth(FENCED, "struct Listed;", 0);

    assert!(layers.iter().any(|layer| {
        layer.language == "rust"
            && layer
                .ranges
                .iter()
                .any(|range| range.start <= listed.start && listed.end <= range.end)
    }));
}

#[test]
fn a_rust_macros_token_tree_is_a_rust_layer_with_its_children() {
    let text = "fn f() {\n    let v = vec![1, g(2)];\n}\n";
    let layers = layers_of("rust", text);

    let tree = nth(text, "[1, g(2)]", 0);
    let found: Vec<(&str, u32, Vec<Range<usize>>)> = layers
        .iter()
        .map(|layer| (layer.language.as_str(), layer.depth, layer.ranges.clone()))
        .collect();
    assert_eq!(found, [("rust", 1, vec![tree])]);
}
