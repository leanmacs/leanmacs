//! The syntax port's real adapter: [`TreeSitter`], a [`Syntax`] over
//! tree-sitter, with the Rust, JSON, Markdown, TOML and Lean grammars
//! compiled in, and Markdown's inline grammar; and the grammars registered
//! on it at run time, each loaded from a native library.
//!
//! The port, its fake, its contract, the rule for what a range answers, the
//! worker that reparses and the decisions about a registration are
//! `editor-syntax`'s. This crate is thin: each method of the port is one
//! call of the library's, and the answer is turned into the port's plain
//! data. No tree-sitter type is public: the parser, the tree and the query
//! are wrapped in types of this crate whose fields are private, and no
//! other crate depends on the library (`deny.toml`).
//!
//! # How grammars are loaded
//!
//! **Compiled in.** Each grammar is a crates.io grammar crate, pinned
//! exactly, or, for Lean, which has no usable crates.io crate, upstream's
//! own crate vendored unmodified under the repository's `vendor/`, and
//! built the same way: its build compiles the generated parser's C with
//! `cc` when Cargo builds this crate; the objects end up in the static
//! library Lean links. These grammars are the private table `GRAMMARS`: a
//! name, the language of the grammar's crate, its reparse policy, and the
//! queries it ships, each with its kind.
//!
//! **Native libraries, at run time.** A grammar the table lacks, or one
//! that takes a compiled-in grammar's place, is registered
//! ([`Syntax::register`]) from a shared library (`.dylib` on macOS, `.so`
//! on Linux) exporting `tree_sitter_<name>`: the same generated C, linked
//! as a library. This is how Emacs, Helix and Neovim load grammars. The
//! module `native` opens it with `libloading`, whose types stay there,
//! checks the language's ABI version against the range the pinned library
//! accepts before any parser is made, and refuses as values a library that
//! is not there, a file that will not open as one, a missing symbol and an
//! ABI outside the range. A loaded library is never unloaded: a language,
//! and every parser and tree of it, points into its code. The editor never
//! finds, fetches or compiles a grammar: the library's path is named by the
//! user's config or a package, and handed in. A registered grammar ships
//! no query; its queries are read in Lean from beside its library.
//!
//! Set aside (the decision is in `docs/design/README.md`'s table and
//! `docs/design/rust-library.md`, "Syntax, as built"):
//!
//! - **WebAssembly grammars**, through the library's `wasm` feature: it
//!   brings wasmtime, a JIT and hundreds of crates, and a `.wasm` build of
//!   each grammar made or fetched. Its sandbox protects against a grammar
//!   that is not trusted; a native grammar is the compiled C every other
//!   editor loads, and parses at native speed.
//! - **`tree-sitter-loader`**, which finds grammars in directories and
//!   compiles their C with the machine's compiler: the editor never does
//!   either.
//!
//! `deny.toml` bans `wasmtime` and `tree-sitter-loader` outright, so
//! neither enters the build unnoticed, and lets no crate but this one
//! depend on `libloading`.
//!
//! # Where each query comes from
//!
//! A grammar crate's own query is used wherever the crate is published with
//! one, pinned by the same exact version as the grammar it was written for.
//! Rust's crate ships no `indents.scm` or `textobjects.scm`, so those two
//! are this repository's, under `queries/rust/`, each opening with a comment
//! naming the Lean rule that reads it; their capture names follow
//! nvim-treesitter's, and no third-party query set is used, since each is
//! written for its own editor's rules (`docs/design/rust-library.md`,
//! "Injections, indentation and text objects, as built"). Markdown's block
//! highlights are this repository's too, `queries/markdown/highlights.scm`:
//! the crate's query, copied with its provenance and changed so a heading is
//! captured by its level and a code block apart from an inline code span,
//! which the crate's query gives one name; the `text.` faces need both
//! (`tests/highlights.rs`).
//!
//! | Grammar | Reparse | Highlights | Injections | Text objects | Indents |
//! |---|---|---|---|---|---|
//! | `json` | incremental | the crate's | none | none | none |
//! | `rust` | incremental | the crate's | the crate's | `queries/rust/textobjects.scm` | `queries/rust/indents.scm` |
//! | `markdown` | incremental | `queries/markdown/highlights.scm` | the crate's, of its block grammar | none | none |
//! | `markdown_inline` | whole | the crate's, of its inline grammar | the crate's, of its inline grammar | none | none |
//! | `toml` | incremental | the crate's | none | none | none |
//! | `lean` | incremental | upstream's, vendored with the grammar | none | none | none |
//!
//! **The reparse policy** (`editor_syntax::ReparsePolicy`) is declared in
//! the table and pinned by each grammar's corpus in `tests/contract.rs`.
//! A grammar is `incremental` when its incremental reparses of texts
//! without errors equal a fresh parse (the contract's `GRAMMAR_QUALITY`),
//! and `whole` otherwise: it still ships, and each round parses it from
//! scratch.
//!
//! Markdown is `tree-sitter-md`'s two grammars. The block grammar,
//! `markdown`, parses a document; its injections query hands each
//! `(inline)` node, a paragraph's or a heading's text, to the grammar named
//! `markdown_inline`, which is the inline grammar. The inline grammar is
//! `whole`: its incremental reparses of texts without errors were seen to
//! differ from a fresh parse (the crate's `Cargo.toml`). An injected layer
//! is parsed whole each round anyway. Its injections name `html` and
//! `latex`, which this adapter does not have, so they inject nothing.
//!
//! TOML is `tree-sitter-toml-ng`'s grammar, `toml`, with its crate's
//! highlights query and no other. It is `incremental`: its incremental
//! reparses of texts without errors were seen to equal a fresh parse (the
//! crate's `Cargo.toml`). Since every grammar here is a language a layer
//! can be injected in, a Markdown fence whose info string is `toml` is a
//! TOML layer.
//!
//! Lean is upstream's grammar, `lean`, vendored with its highlights query
//! of the same commit, the one query used. It is `incremental`: its
//! incremental reparses of texts without errors were seen to equal a fresh
//! parse (the crate's `Cargo.toml`). A Markdown fence whose info string is
//! `lean` is a Lean layer.
//!
//! # What each method forwards to
//!
//! A grammar registered under a name is the one that name means from then
//! on, a compiled-in grammar of the same name included; a parser opened
//! before keeps the language it was opened with.
//!
//! - [`Syntax::grammars`]: the compiled-in names in the table's order, then
//!   each registered name the table lacks (`editor_syntax::registry`).
//! - [`Syntax::reparse_policy`]: the registered entry's policy, else the
//!   grammar's policy in the table; none when the grammar is neither.
//! - [`Syntax::register`]: the source's library loaded by `native`, off the
//!   registry's lock, then the core's registry, which names it, keeps its
//!   policy (whole when the source declares none) and replaces any entry of
//!   the name; a refusal changes nothing.
//! - [`Syntax::parser`]: a new parser with the grammar's language set, the
//!   registered entry's or the table's; none when the grammar is neither,
//!   or the library refuses its language (an ABI it does not speak).
//! - [`Syntax::parse`]: the library's parse with a callback that hands it
//!   the snapshot's chunks ([`Snapshot::chunk_at`]): the text is never
//!   copied into one string.
//! - [`Syntax::edit`]: the library's edit of a tree, with the edit's
//!   fields and points carried over one for one.
//! - [`Syntax::compile`]: the library's query over the grammar's language,
//!   the registered entry's or the table's, its refusal carried over with
//!   its kind and offset.
//! - [`Syntax::shipped_query`]: none for a registered name, a compiled-in
//!   name it replaces included; else the query of that kind in the table,
//!   the grammar crate's export (`HIGHLIGHTS_QUERY`, `INJECTIONS_QUERY`) or
//!   one of `queries/`.
//! - [`Syntax::captures`]: a query cursor set to the range, whose
//!   predicates (`#eq?`, `#match?`) read the snapshot's chunks of a node.
//!   The library answers every match that meets the range, captures
//!   outside it included; `editor_syntax::query::captures_in` decides.
//! - [`Syntax::matches`]: the same cursor's matches, with each captured
//!   node's named children read with a tree cursor.
//! - [`Syntax::pattern_settings`]: the library's `#set!` properties of the
//!   pattern.
//! - [`Syntax::parse_in`]: the parser's included ranges set to the ranges,
//!   with their points from the snapshot, a parse with no old tree, and the
//!   included ranges set back to the whole text.
//! - [`Syntax::nodes`]: a walk of the tree with the library's cursor, in
//!   pre-order, with each node's field read from the cursor.
//!
//! # Tests
//!
//! `tests/contract.rs` holds the adapter to the port's contract, once for
//! each grammar compiled in, over the fixtures checked in under the
//! repository's `tests/syntax/` and a few texts written there, and once for
//! the fixture INI grammar (`editor-syntax-fixture-ini`) registered from
//! its native library and drawn with the highlights query beside it.
//! `tests/registration.rs` holds it to the registration contract on that
//! fixture library: a new grammar, one that overrides `json` (after which
//! `json` ships none of the compiled-in queries and is reparsed by the
//! source's policy), and one source for each refusal; and pins that a
//! loaded grammar outlives the syntax it was registered on. `native`'s unit
//! tests pin the ABI range with version numbers and the refusal of a
//! relative path. The unit tests here pin what the contract does not ask:
//! a Rust function's name captured by a field, a predicate that reads text
//! across two of the rope's chunks, and a query of a grammar that is not
//! compiled in.

#![deny(unsafe_code)]
#![deny(clippy::undocumented_unsafe_blocks)]

use std::fmt;
use std::ops::Range;
use std::sync::{Mutex, MutexGuard, PoisonError};

use editor_syntax::registry::Registry;
use editor_syntax::{
    Capture, GrammarName, GrammarSource, Match, MatchCapture, Node, QueryError, QueryErrorKind,
    QueryKind, RegistrationRefusal, ReparsePolicy, Setting, Syntax,
};
use editor_text::{InputEdit, Point, Snapshot};
use tree_sitter::{Language, Parser, Query, QueryCursor, StreamingIterator, Tree};

mod native;

/// The adapter: tree-sitter, with the grammars compiled in (`json`,
/// `rust`, `markdown`, `markdown_inline`, `toml` and `lean`), and the
/// grammars registered on it at run time.
#[derive(Default)]
pub struct TreeSitter {
    /// The grammars registered, each with its language. An entry wins over
    /// a compiled-in grammar of the same name.
    registry: Mutex<Registry<Language>>,
}

impl Clone for TreeSitter {
    /// Another adapter with the grammars registered on this one, which
    /// registrations on either do not reach.
    fn clone(&self) -> Self {
        Self {
            registry: Mutex::new(self.registry().clone()),
        }
    }
}

impl fmt::Debug for TreeSitter {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("TreeSitter")
            .field("registered", &self.registry().grammars([]))
            .finish()
    }
}

impl TreeSitter {
    /// The registry, locked. It is never left half-changed, so a poisoned
    /// lock is used as it is.
    fn registry(&self) -> MutexGuard<'_, Registry<Language>> {
        self.registry.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The language of the grammar `name`: the registered entry's, else
    /// the compiled-in grammar's; `None` for a grammar it has not.
    fn language(&self, name: &GrammarName) -> Option<Language> {
        if let Some(entry) = self.registry().get(name) {
            return Some(entry.grammar.clone());
        }
        grammar(name).map(|grammar| (grammar.language)())
    }
}

/// How to make a grammar's language.
type MakeLanguage = fn() -> Language;

/// A grammar compiled in.
struct Grammar {
    /// Its name.
    name: &'static str,
    /// How to make its language.
    language: MakeLanguage,
    /// How its texts are reparsed after an edit.
    policy: ReparsePolicy,
    /// The queries it ships, each with its kind: its crate's own, pinned
    /// with it, where the crate is published with one, and otherwise this
    /// crate's, under `queries/`. A kind not here it ships none of.
    queries: &'static [(QueryKind, &'static str)],
}

/// The grammars compiled in.
const GRAMMARS: [Grammar; 6] = [
    Grammar {
        name: "json",
        language: || Language::new(tree_sitter_json::LANGUAGE),
        policy: ReparsePolicy::Incremental,
        queries: &[(QueryKind::Highlights, tree_sitter_json::HIGHLIGHTS_QUERY)],
    },
    Grammar {
        name: "rust",
        language: || Language::new(tree_sitter_rust::LANGUAGE),
        policy: ReparsePolicy::Incremental,
        queries: &[
            (QueryKind::Highlights, tree_sitter_rust::HIGHLIGHTS_QUERY),
            (QueryKind::Injections, tree_sitter_rust::INJECTIONS_QUERY),
            (
                QueryKind::TextObjects,
                include_str!("../queries/rust/textobjects.scm"),
            ),
            (
                QueryKind::Indents,
                include_str!("../queries/rust/indents.scm"),
            ),
        ],
    },
    Grammar {
        name: "markdown",
        language: || Language::new(tree_sitter_md::LANGUAGE),
        policy: ReparsePolicy::Incremental,
        queries: &[
            (
                QueryKind::Highlights,
                include_str!("../queries/markdown/highlights.scm"),
            ),
            (QueryKind::Injections, tree_sitter_md::INJECTION_QUERY_BLOCK),
        ],
    },
    Grammar {
        name: "markdown_inline",
        language: || Language::new(tree_sitter_md::INLINE_LANGUAGE),
        // Its incremental reparses of texts without errors were seen to
        // differ from a fresh parse (the crate's `Cargo.toml`).
        policy: ReparsePolicy::Whole,
        queries: &[
            (
                QueryKind::Highlights,
                tree_sitter_md::HIGHLIGHT_QUERY_INLINE,
            ),
            (
                QueryKind::Injections,
                tree_sitter_md::INJECTION_QUERY_INLINE,
            ),
        ],
    },
    Grammar {
        name: "toml",
        language: || Language::new(tree_sitter_toml_ng::LANGUAGE),
        policy: ReparsePolicy::Incremental,
        queries: &[(QueryKind::Highlights, tree_sitter_toml_ng::HIGHLIGHTS_QUERY)],
    },
    Grammar {
        name: "lean",
        language: || Language::new(tree_sitter_lean::LANGUAGE),
        policy: ReparsePolicy::Incremental,
        queries: &[(QueryKind::Highlights, tree_sitter_lean::HIGHLIGHTS_QUERY)],
    },
];

/// The grammar `name`, if it is compiled in.
fn grammar(name: &GrammarName) -> Option<&'static Grammar> {
    GRAMMARS.iter().find(|known| known.name == name.as_str())
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
        self.registry().grammars(
            GRAMMARS
                .iter()
                .map(|grammar| GrammarName::new(grammar.name)),
        )
    }

    fn reparse_policy(&self, grammar: &GrammarName) -> Option<ReparsePolicy> {
        if let Some(entry) = self.registry().get(grammar) {
            return Some(entry.policy);
        }
        self::grammar(grammar).map(|grammar| grammar.policy)
    }

    fn register(&self, source: &GrammarSource) -> Result<GrammarName, RegistrationRefusal> {
        // The library is loaded before the lock is taken, so nothing that
        // reads the grammars waits for a `dlopen`; the registry then
        // decides the rest (`editor_syntax::registry`).
        let loaded = native::load(source);
        self.registry().register(source, |_| loaded)
    }

    fn parser(&self, grammar: &GrammarName) -> Option<TreeSitterParser> {
        let mut parser = Parser::new();
        parser.set_language(&self.language(grammar)?).ok()?;
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
        let Some(language) = self.language(grammar) else {
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

    fn shipped_query(&self, name: &GrammarName, kind: QueryKind) -> Option<String> {
        // A registered grammar ships no query, a compiled-in name it
        // replaces included.
        if self.registry().get(name).is_some() {
            return None;
        }
        grammar(name)?
            .queries
            .iter()
            .find(|(shipped, _)| *shipped == kind)
            .map(|(_, source)| (*source).to_owned())
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

    fn matches(
        &self,
        query: &TreeSitterQuery,
        tree: &TreeSitterTree,
        text: &Snapshot,
        range: Range<usize>,
    ) -> Vec<Match> {
        let mut cursor = QueryCursor::new();
        cursor.set_byte_range(range);
        let node_text = |node: tree_sitter::Node<'_>| {
            text.chunks_in(node.byte_range())
                .into_iter()
                .flatten()
                .map(str::as_bytes)
        };
        let mut found = cursor.matches(&query.0, tree.0.root_node(), node_text);
        let mut matches = Vec::new();
        while let Some(found) = found.next() {
            let captures = found
                .captures()
                .iter()
                .map(|capture| {
                    let mut walk = capture.node.walk();
                    MatchCapture {
                        capture: capture.index,
                        start: capture.node.start_byte(),
                        end: capture.node.end_byte(),
                        named_children: capture
                            .node
                            .named_children(&mut walk)
                            .map(|child| child.byte_range())
                            .collect(),
                    }
                })
                .collect();
            matches.push(Match {
                pattern: found.pattern_index,
                captures,
            });
        }
        matches
    }

    fn pattern_settings(&self, query: &TreeSitterQuery, pattern: usize) -> Vec<Setting> {
        if pattern >= query.0.pattern_count() {
            return Vec::new();
        }
        query
            .0
            .property_settings(pattern)
            .iter()
            .map(|property| Setting {
                key: property.key.to_string(),
                value: property.value.as_deref().map(str::to_owned),
            })
            .collect()
    }

    fn parse_in(
        &self,
        parser: &mut TreeSitterParser,
        text: &Snapshot,
        ranges: &[Range<usize>],
    ) -> TreeSitterTree {
        let point = |offset| point_to(text.offset_to_point(offset).unwrap_or(Point::new(0, 0)));
        let included: Vec<tree_sitter::Range> = ranges
            .iter()
            .map(|range| tree_sitter::Range {
                start_byte: range.start,
                end_byte: range.end,
                start_point: point(range.start),
                end_point: point(range.end),
            })
            .collect();
        // The library refuses ranges that are not sorted and apart, which
        // the port's caller never hands; it then keeps the ranges it had,
        // the whole text.
        let _ = parser.0.set_included_ranges(&included);
        let tree = self.parse(parser, text, None);
        // No ranges is the whole text again, which the library never
        // refuses.
        let _ = parser.0.set_included_ranges(&[]);
        tree
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

    fn has_errors(&self, tree: &TreeSitterTree) -> bool {
        // The library's error cost counts missing nodes as well as errors.
        tree.0.root_node().has_error()
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
        let syntax = TreeSitter::default();
        let mut parser = syntax.parser(&grammar).unwrap();
        let tree = syntax.parse(&mut parser, &snapshot, None);
        let query = syntax.compile(&grammar, source).unwrap();
        let names = syntax.capture_names(&query);
        captures_in(&syntax, &query, &tree, &snapshot, 0..snapshot.len())
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
        let syntax = TreeSitter::default();
        let mut parser = syntax.parser(&grammar).unwrap();
        let tree = syntax.parse(&mut parser, &snapshot, None);
        let query = syntax.compile(&grammar, &source).unwrap();
        let found = captures_in(&syntax, &query, &tree, &snapshot, 0..snapshot.len()).unwrap();
        assert_eq!(
            found.iter().map(Capture::range).collect::<Vec<_>>(),
            vec![start..start + name.len()]
        );
    }

    #[test]
    fn each_grammar_declares_the_reparse_policy_of_the_table_and_one_not_compiled_in_none() {
        let syntax = TreeSitter::default();
        let policy = |name: &str| syntax.reparse_policy(&GrammarName::new(name));

        assert_eq!(policy("rust"), Some(ReparsePolicy::Incremental));
        assert_eq!(policy("json"), Some(ReparsePolicy::Incremental));
        assert_eq!(policy("markdown"), Some(ReparsePolicy::Incremental));
        assert_eq!(policy("markdown_inline"), Some(ReparsePolicy::Whole));
        assert_eq!(policy("toml"), Some(ReparsePolicy::Incremental));
        assert_eq!(policy("lean"), Some(ReparsePolicy::Incremental));
        assert_eq!(policy("cobol"), None);
    }

    #[test]
    fn a_query_of_a_grammar_that_is_not_compiled_in_is_refused_as_the_language() {
        assert_eq!(
            TreeSitter::default()
                .compile(&GrammarName::new("cobol"), "(x) @x")
                .map(|_| ())
                .unwrap_err()
                .kind,
            QueryErrorKind::Language
        );
    }
}
