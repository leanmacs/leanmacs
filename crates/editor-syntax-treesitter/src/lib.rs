//! The syntax port's real adapter: [`TreeSitter`], a [`Syntax`] over
//! tree-sitter, with the Rust and JSON grammars compiled in.
//!
//! The port, its fake, its contract, the rule for what a range answers and
//! the worker that reparses are `editor-syntax`'s. This crate is thin: each
//! method of the port is one call of the library's, and the answer is
//! turned into the port's plain data. No tree-sitter type is public: the
//! parser, the tree and the query are wrapped in types of this crate whose
//! fields are private, and no other crate depends on the library
//! (`deny.toml`).
//!
//! # How grammars are loaded
//!
//! **Compiled in.** Each grammar is a crates.io grammar crate, pinned
//! exactly, whose build compiles the generated parser's C with `cc` when
//! Cargo builds this crate; the objects end up in the static library Lean
//! links. Nothing is fetched, generated or loaded at run time, and the
//! grammars are the private table `GRAMMARS`: a name, and the language of
//! the grammar's crate.
//!
//! The other two ways were set aside (the decision is in
//! `docs/design/README.md`'s table and `docs/design/rust-library.md`,
//! "Syntax, as built"):
//!
//! - **Native libraries**, loaded with `dlopen`: a second build product for
//!   each grammar and platform, a search path, a check of the ABI when one
//!   is loaded, a failure at run time ("grammar not found"), and bundling
//!   into the app, for no gain while the set of grammars is fixed when the
//!   library is built.
//! - **WebAssembly grammars**, through the library's `wasm` feature: it
//!   brings wasmtime, a JIT and hundreds of crates, and a `.wasm` build of
//!   each grammar made or fetched. Its sandbox protects against a grammar
//!   that is not trusted, and every grammar here is pinned and reviewed.
//!
//! `deny.toml` bans `wasmtime` and `tree-sitter-loader` outright, so
//! neither way enters the build unnoticed.
//!
//! # What each method forwards to
//!
//! - [`Syntax::parser`]: a new parser with the grammar's language set; none
//!   when the grammar is not in the table, or the library refuses its
//!   language (an ABI it does not speak).
//! - [`Syntax::parse`]: the library's parse with a callback that hands it
//!   the snapshot's chunks ([`Snapshot::chunk_at`]): the text is never
//!   copied into one string.
//! - [`Syntax::edit`]: the library's edit of a tree, with the edit's
//!   fields and points carried over one for one.
//! - [`Syntax::compile`]: the library's query, its refusal carried over
//!   with its kind and offset.
//! - [`Syntax::captures`]: a query cursor set to the range, whose
//!   predicates (`#eq?`, `#match?`) read the snapshot's chunks of a node.
//!   The library answers every match that meets the range, captures
//!   outside it included; `editor_syntax::query::captures_in` decides.
//! - [`Syntax::nodes`]: a walk of the tree with the library's cursor, in
//!   pre-order, with each node's field read from the cursor.
//!
//! # Tests
//!
//! `tests/contract.rs` holds the adapter to the port's contract, once for
//! each grammar, over the fixtures checked in under the repository's
//! `tests/syntax/` and a few texts written there. The unit tests here pin
//! what the contract does not ask: a Rust function's name captured by a
//! field, a predicate that reads text across two of the rope's chunks, and
//! a query of a grammar that is not compiled in. That a grammar whose ABI
//! the library refuses opens no parser is not tested: no such grammar can
//! be built here honestly, and `contract::GRAMMARS` holds the case of one
//! that opens.

use std::ops::Range;

use editor_syntax::{Capture, GrammarName, Node, QueryError, QueryErrorKind, Syntax};
use editor_text::{InputEdit, Point, Snapshot};
use tree_sitter::{Language, Parser, Query, QueryCursor, StreamingIterator, Tree};

/// The adapter: tree-sitter, with the grammars compiled in: `json` and
/// `rust`.
#[derive(Debug, Default, Clone, Copy)]
pub struct TreeSitter;

/// How to make a grammar's language.
type MakeLanguage = fn() -> Language;

/// The grammars compiled in: each name, and how to make its language.
const GRAMMARS: [(&str, MakeLanguage); 2] = [
    ("json", || Language::new(tree_sitter_json::LANGUAGE)),
    ("rust", || Language::new(tree_sitter_rust::LANGUAGE)),
];

/// The language of the grammar `name`, if it is compiled in.
fn language(name: &GrammarName) -> Option<Language> {
    GRAMMARS
        .iter()
        .find(|(known, _)| *known == name.as_str())
        .map(|(_, language)| language())
}

/// A parser of one grammar.
pub struct TreeSitterParser(Parser);

/// A tree. A clone shares it.
#[derive(Clone)]
pub struct TreeSitterTree(Tree);

/// A compiled query.
pub struct TreeSitterQuery(Query);

/// A point of the library's, from one of the port's: both count rows by
/// line feed and columns in bytes.
fn point_to(point: Point) -> tree_sitter::Point {
    tree_sitter::Point {
        row: point.row,
        column: point.column,
    }
}

/// A point of the port's, from one of the library's.
fn point_from(point: tree_sitter::Point) -> Point {
    Point::new(point.row, point.column)
}

/// The kind of the library's refusal of a query, as the port says it.
fn kind_of(kind: &tree_sitter::QueryErrorKind) -> QueryErrorKind {
    match kind {
        tree_sitter::QueryErrorKind::Syntax => QueryErrorKind::Syntax,
        tree_sitter::QueryErrorKind::NodeType => QueryErrorKind::NodeType,
        tree_sitter::QueryErrorKind::Field => QueryErrorKind::Field,
        tree_sitter::QueryErrorKind::Capture => QueryErrorKind::Capture,
        tree_sitter::QueryErrorKind::Predicate => QueryErrorKind::Predicate,
        tree_sitter::QueryErrorKind::Structure => QueryErrorKind::Structure,
        tree_sitter::QueryErrorKind::Language => QueryErrorKind::Language,
    }
}

/// The bytes of `text` from `offset` on, to the end of the chunk that
/// holds it: what the library's parse asks for. Nothing at or past the end.
fn read(text: &Snapshot, offset: usize) -> &[u8] {
    text.chunk_at(offset)
        .and_then(|(chunk, start)| chunk.as_bytes().get(offset - start..))
        .unwrap_or_default()
}

impl Syntax for TreeSitter {
    type Parser = TreeSitterParser;
    type Tree = TreeSitterTree;
    type Query = TreeSitterQuery;

    fn grammars(&self) -> Vec<GrammarName> {
        GRAMMARS
            .iter()
            .map(|(name, _)| GrammarName::new(*name))
            .collect()
    }

    fn parser(&self, grammar: &GrammarName) -> Option<TreeSitterParser> {
        let mut parser = Parser::new();
        parser.set_language(&language(grammar)?).ok()?;
        Some(TreeSitterParser(parser))
    }

    fn parse(
        &self,
        parser: &mut TreeSitterParser,
        text: &Snapshot,
        old: Option<&TreeSitterTree>,
    ) -> TreeSitterTree {
        let mut chunks = |offset: usize, _: tree_sitter::Point| read(text, offset);
        let tree = parser
            .0
            .parse_with_options(&mut chunks, old.map(|old| &old.0), None)
            // The library answers no tree only for a parser with no
            // language, which `parser` never hands out, or a parse
            // cancelled through options, which are never given.
            .expect("a parser with a language and no cancellation answers a tree");
        TreeSitterTree(tree)
    }

    fn edit(&self, tree: &mut TreeSitterTree, edit: &InputEdit) {
        tree.0.edit(&tree_sitter::InputEdit {
            start_byte: edit.start_byte,
            old_end_byte: edit.old_end_byte,
            new_end_byte: edit.new_end_byte,
            start_position: point_to(edit.start_point),
            old_end_position: point_to(edit.old_end_point),
            new_end_position: point_to(edit.new_end_point),
        });
    }

    fn compile(&self, grammar: &GrammarName, source: &str) -> Result<TreeSitterQuery, QueryError> {
        let Some(language) = language(grammar) else {
            return Err(QueryError {
                kind: QueryErrorKind::Language,
                offset: 0,
            });
        };
        Query::new(&language, source)
            .map(TreeSitterQuery)
            .map_err(|error| QueryError {
                kind: kind_of(&error.kind),
                offset: error.offset,
            })
    }

    fn capture_names(&self, query: &TreeSitterQuery) -> Vec<String> {
        query
            .0
            .capture_names()
            .iter()
            .map(|name| (*name).to_owned())
            .collect()
    }

    fn captures(
        &self,
        query: &TreeSitterQuery,
        tree: &TreeSitterTree,
        text: &Snapshot,
        range: Range<usize>,
    ) -> Vec<Capture> {
        let mut cursor = QueryCursor::new();
        cursor.set_byte_range(range);
        let node_text = |node: tree_sitter::Node<'_>| {
            text.chunks_in(node.byte_range())
                .into_iter()
                .flatten()
                .map(str::as_bytes)
        };
        let mut matches = cursor.captures(&query.0, tree.0.root_node(), node_text);
        let mut captures = Vec::new();
        while let Some((found, index)) = matches.next() {
            if let Some(capture) = found.captures().get(*index) {
                captures.push(Capture {
                    pattern: found.pattern_index,
                    capture: capture.index,
                    start: capture.node.start_byte(),
                    end: capture.node.end_byte(),
                });
            }
        }
        captures
    }

    fn nodes(&self, tree: &TreeSitterTree) -> Vec<Node> {
        let mut nodes = Vec::new();
        let mut cursor = tree.0.walk();
        let mut depth = 0_u32;
        loop {
            let node = cursor.node();
            nodes.push(Node {
                kind: node.kind().to_owned(),
                named: node.is_named(),
                field: cursor.field_name().map(str::to_owned),
                depth,
                start: node.start_byte(),
                end: node.end_byte(),
                start_point: point_from(node.start_position()),
                end_point: point_from(node.end_position()),
                error: node.is_error(),
                missing: node.is_missing(),
            });
            if cursor.goto_first_child() {
                depth += 1;
                continue;
            }
            while !cursor.goto_next_sibling() {
                if !cursor.goto_parent() {
                    return nodes;
                }
                depth -= 1;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use editor_syntax::query::captures_in;
    use editor_text::Text;

    use super::*;

    /// The texts of the captures of `source` in `text`, parsed with
    /// `grammar`, each with its capture's name.
    fn captured(grammar: &str, source: &str, text: &str) -> Vec<(String, String)> {
        let grammar = GrammarName::new(grammar);
        let snapshot = Text::from(text).snapshot();
        let mut parser = TreeSitter.parser(&grammar).unwrap();
        let tree = TreeSitter.parse(&mut parser, &snapshot, None);
        let query = TreeSitter.compile(&grammar, source).unwrap();
        let names = TreeSitter.capture_names(&query);
        captures_in(&TreeSitter, &query, &tree, &snapshot, 0..snapshot.len())
            .unwrap()
            .into_iter()
            .map(|capture| {
                let name = names[usize::try_from(capture.capture).unwrap()].clone();
                (name, snapshot.slice_to_string(capture.range()).unwrap())
            })
            .collect()
    }

    /// `(name, text)` as owned.
    fn pair(name: &str, text: &str) -> (String, String) {
        (name.to_owned(), text.to_owned())
    }

    #[test]
    fn a_rust_functions_name_is_captured_through_its_field() {
        assert_eq!(
            captured(
                "rust",
                "(function_item name: (identifier) @name)",
                "fn one() {}\nstruct S;\nimpl S { fn two(&self) {} }\n",
            ),
            [pair("name", "one"), pair("name", "two")]
        );
    }

    #[test]
    fn a_predicate_reads_a_node_whose_text_straddles_two_of_the_ropes_chunks() {
        let mut text = String::from("fn f() {\n");
        for line in 0..2000 {
            text.push_str(&format!("    let name_{line:05} = 1;\n"));
        }
        text.push_str("}\n");
        let snapshot = Text::from(text.as_str()).snapshot();
        // A chunk boundary that falls inside an identifier.
        let mut boundaries = snapshot.chunks().scan(0, |end, chunk| {
            *end += chunk.len();
            Some(*end)
        });
        let (start, name) = boundaries
            .find_map(|boundary| {
                let row = snapshot.offset_to_point(boundary)?.row;
                let range = snapshot.row_range(row)?;
                let start = range.start + "    let ".len();
                let end = start + "name_00000".len();
                (start < boundary && boundary < end)
                    .then(|| (start, snapshot.slice_to_string(start..end).unwrap()))
            })
            .expect("a chunk boundary inside a name");

        let source = format!("((identifier) @found (#eq? @found \"{name}\"))");
        let grammar = GrammarName::new("rust");
        let mut parser = TreeSitter.parser(&grammar).unwrap();
        let tree = TreeSitter.parse(&mut parser, &snapshot, None);
        let query = TreeSitter.compile(&grammar, &source).unwrap();
        let found = captures_in(&TreeSitter, &query, &tree, &snapshot, 0..snapshot.len()).unwrap();
        assert_eq!(
            found.iter().map(Capture::range).collect::<Vec<_>>(),
            vec![start..start + name.len()]
        );
    }

    #[test]
    fn a_query_of_a_grammar_that_is_not_compiled_in_is_refused_as_the_language() {
        assert_eq!(
            TreeSitter
                .compile(&GrammarName::new("cobol"), "(x) @x")
                .map(|_| ())
                .unwrap_err()
                .kind,
            QueryErrorKind::Language
        );
    }
}
