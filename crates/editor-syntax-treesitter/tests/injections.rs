//! The injection rule (`editor_syntax::inject`) on the real grammars:
//! Markdown's fences, by the block grammar's own injections query, and a
//! Rust macro's token tree, by the Rust grammar's.
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
use editor_syntax::{GrammarName, Node, QueryKind, Syntax};
use editor_syntax_treesitter::{TreeSitter, TreeSitterQuery, TreeSitterTree};
use editor_text::{Point, Text};

/// The fixture of fences.
const FENCED: &str = include_str!("../../../tests/syntax/markdown/fenced.md");

/// The query of `kind` `grammar` ships, compiled.
fn shipped(grammar: &str, kind: QueryKind) -> Arc<TreeSitterQuery> {
    let grammar = GrammarName::new(grammar);
    let source = TreeSitter.shipped_query(&grammar, kind).unwrap();
    Arc::new(TreeSitter.compile(&grammar, &source).unwrap())
}

/// The language `grammar`, drawn with its shipped highlights, each capture
/// in a face named after it, with its shipped injections, if it has any.
fn language(grammar: &str) -> Language<TreeSitterQuery> {
    let highlights = shipped(grammar, QueryKind::Highlights);
    let names = TreeSitter.capture_names(&highlights);
    let faces = names.iter().cloned().map(Some).collect();
    let name = GrammarName::new(grammar);
    Language {
        highlighter: Arc::new(Highlighter::new(highlights, names.len(), faces).unwrap()),
        injections: TreeSitter
            .shipped_query(&name, QueryKind::Injections)
            .map(|source| Arc::new(TreeSitter.compile(&name, &source).unwrap())),
        grammar: name,
    }
}

/// `host`'s shipped injections, with every grammar compiled in a language
/// of its name.
fn injections(host: &str) -> Injections<TreeSitterQuery> {
    Injections {
        query: Some(shipped(host, QueryKind::Injections)),
        languages: TreeSitter
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
        &TreeSitter,
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
    let mut parser = TreeSitter.parser(&GrammarName::new(grammar)).unwrap();
    let tree = TreeSitter.parse(&mut parser, &snapshot, None);
    TreeSitter
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
    assert_eq!(rust.ranges, [range.clone()]);
    assert_eq!(rust.grammar, GrammarName::new("rust"));
    assert_eq!(
        TreeSitter.nodes(&rust.tree),
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
    // `cobol` names no grammar, and inline text names `markdown_inline`,
    // which is not listed: neither is a layer.
    assert!(
        found
            .iter()
            .all(|(language, _, _)| ["rust", "json"].contains(language))
    );
    let cobol = nth(FENCED, "DISPLAY", 0);
    assert!(
        found
            .iter()
            .all(|(_, _, ranges)| ranges.iter().all(|range| !range.contains(&cobol.start)))
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
