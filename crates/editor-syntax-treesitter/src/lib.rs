//! The syntax port's real adapter: [`TreeSitter`], a [`Syntax`] over
//! tree-sitter, with the grammars registered on it at run time, each loaded
//! from a native library. It compiles in no grammar.
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
//! **Native libraries, at run time, and no other way.** Every grammar is
//! registered ([`Syntax::register`]) from a shared library (`.dylib` on
//! macOS, `.so` on Linux) exporting `tree_sitter_<name>`: a grammar's
//! generated C, linked as a library. This is how Emacs, Helix and Neovim
//! load grammars. The module `native` opens it with `libloading`, whose
//! types stay there, checks the language's ABI version against the range
//! the pinned library accepts before any parser is made, and refuses as
//! values a library that is not there, a file that will not open as one, a
//! missing symbol and an ABI outside the range. A loaded library is never
//! unloaded: a language, and every parser and tree of it, points into its
//! code. The editor never finds, fetches or compiles a grammar: the
//! library's path is named by the user's config or a package, and handed
//! in. A registered grammar ships no query; its queries are read in Lean
//! from beside its library.
//!
//! **Where the editor's grammars come from.** The default package
//! `languages` ships every grammar the editor's shipped languages use
//! (`rust`, `json`, `markdown`, `markdown_inline`, `toml`, `lean`) and
//! `yaml`, each built from pinned source by the set's build
//! (`packages/languages/README.md`). They were compiled into this crate
//! until phase 4 of the roadmap `shipped-grammars-package`, which moved
//! them, their pins and their queries into the package. So a fresh adapter
//! ([`TreeSitter::default`], and so the process's syntax service in
//! `editor-ffi`) lists no grammar, opens no parser and compiles no query
//! until one is registered.
//!
//! **Measured.** With no grammar compiled in, the release archive Lean
//! links (`libeditor_rust.a`) is 76.5 MB against 86.8 MB before, and its
//! clean build about 27 s wall either way (2026-11-27;
//! `docs/design/rust-library.md`, "Syntax, as built", "Measured").
//!
//! **The moment before.** Every editor registers its grammars at startup,
//! through the core's `register-grammars` job: its first install of
//! config's, or, with no config to load or a first reload that is
//! rejected, that of the packages' grammars alone (`lean/Editor/Config/Reload.lean`,
//! "The packages' grammars with no config"). A file opened before the job's command runs is drawn
//! plain for that moment, then highlighted when the command records the
//! answers (`docs/design/keymaps-and-modes.md`, "Declared grammars"). This
//! is accepted.
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
//! No query is this crate's. A grammar's queries are read in Lean from the
//! directory its declaration names, and handed to the port as sources. The
//! `languages` package keeps its grammars' queries in its
//! `grammars/queries/<name>/`, with the table of which grammar ships which
//! in its README; the reparse policy each declares is in
//! `packages/languages/Languages/Grammars.lean`, and how each was found is
//! in `packages/languages/rust/Cargo.toml`.
//!
//! # What each method forwards to
//!
//! A grammar registered under a name is the one that name means from then
//! on; a parser opened before keeps the language it was opened with.
//!
//! - [`Syntax::grammars`]: each registered name, in the order first
//!   registered (`editor_syntax::registry`).
//! - [`Syntax::reparse_policy`]: the registered entry's policy; none for a
//!   grammar not registered.
//! - [`Syntax::register`]: the source's library loaded by `native`, off the
//!   registry's lock, then the core's registry, which names it, keeps its
//!   policy (whole when the source declares none) and replaces any entry of
//!   the name; a refusal changes nothing.
//! - [`Syntax::parser`]: a new parser with the registered entry's language
//!   set; none when the grammar is not registered, or the library refuses
//!   its language (an ABI it does not speak).
//! - [`Syntax::parse`]: the library's parse with a callback that hands it
//!   the snapshot's chunks ([`Snapshot::chunk_at`]): the text is never
//!   copied into one string.
//! - [`Syntax::edit`]: the library's edit of a tree, with the edit's
//!   fields and points carried over one for one.
//! - [`Syntax::compile`]: the library's query over the registered entry's
//!   language, its refusal carried over with its kind and offset.
//! - [`Syntax::shipped_query`]: none, for every grammar and kind: that is
//!   the adapter's whole answer, since every grammar it has was registered
//!   from a library, whose queries Lean reads beside it. The port keeps the
//!   method for its fake (the task `syntax-port-drop-shipped-query`).
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
//! `tests/contract.rs` holds the adapter to the port's contract once for
//! each of the six grammars loaded from the native library
//! `editor-syntax-fixture-grammars` builds from the `languages` package's
//! pins, each drawn with the package's highlights staged beside it, and
//! once for the fixture INI grammar (`editor-syntax-fixture-ini`), over the
//! fixtures checked in under the repository's `tests/syntax/` and a few
//! texts written there (`tests/corpora/mod.rs`). Each corpus's reparse
//! policy is the one the package declares, pinned by the contract's
//! `GRAMMAR_QUALITY`. `tests/injections.rs` and `tests/refresh.rs` register
//! the grammars they use from the same crate and draw with its queries.
//! `tests/registration.rs` holds the adapter to the registration contract
//! on the INI fixture library, its `OVERRIDES` registering over a `json`
//! registered before from the fixture grammars, with one source for each
//! refusal, and pins that a loaded grammar outlives the syntax it was
//! registered on. `native`'s unit tests pin the ABI range with version
//! numbers and the refusal of a relative path. `tests/highlights.rs` and
//! `tests/rendered.rs` register `markdown`, `markdown_inline` and `rust`
//! from the fixture crate: they hold the package's Markdown highlights and
//! rendered queries, and `editor_syntax::once::parse`, on those grammars.
//! The unit tests here pin what the contracts do not ask: that a fresh
//! adapter lists no grammar, a Rust function's name captured by a field and
//! a predicate that reads text across two of the rope's chunks (each over
//! the fixture's rust), a query of a grammar the adapter has not, and the
//! source a registered grammar answers, which a compile answers beside its
//! query ([`TreeSitter::registered_source`],
//! [`TreeSitter::compile_registered`]).

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

/// The adapter: tree-sitter, with the grammars registered on it at run
/// time. It compiles in none.
#[derive(Default)]
pub struct TreeSitter {
    /// The grammars registered, each with its language.
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

    /// The language of the grammar `name`, the registered entry's; `None`
    /// for a grammar not registered.
    fn language(&self, name: &GrammarName) -> Option<Language> {
        self.registry().get(name).map(|entry| entry.grammar.clone())
    }

    /// Where the grammar `name` was registered from, the registered
    /// entry's source; `None` for a grammar not registered. What a cache
    /// of compiled queries keys by, so a grammar registered again from
    /// another library never meets a query compiled for the old one.
    pub fn registered_source(&self, name: &GrammarName) -> Option<GrammarSource> {
        self.registry().get(name).map(|entry| entry.source.clone())
    }

    /// The query `source` compiled for the grammar `name`, or the
    /// library's refusal, with where the grammar was registered from: the
    /// source and the language read together under one lock, so the
    /// source is the one of the language the query was compiled for, even
    /// when a registration lands beside the call. `None` for a grammar not
    /// registered.
    pub fn compile_registered(
        &self,
        name: &GrammarName,
        source: &str,
    ) -> Option<(GrammarSource, Result<TreeSitterQuery, QueryError>)> {
        let (language, registered) = {
            let registry = self.registry();
            let entry = registry.get(name)?;
            (entry.grammar.clone(), entry.source.clone())
        };
        Some((registered, compiled(&language, source)))
    }
}

/// `source` compiled for `language`, or the library's refusal as the port
/// says it.
fn compiled(language: &Language, source: &str) -> Result<TreeSitterQuery, QueryError> {
    Query::new(language, source)
        .map(TreeSitterQuery)
        .map_err(|error| QueryError {
            kind: kind_of(&error.kind),
            offset: error.offset,
        })
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
        self.registry().grammars([])
    }

    fn reparse_policy(&self, grammar: &GrammarName) -> Option<ReparsePolicy> {
        self.registry().get(grammar).map(|entry| entry.policy)
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
        compiled(&language, source)
    }

    fn shipped_query(&self, _name: &GrammarName, _kind: QueryKind) -> Option<String> {
        // Every grammar is registered from a library, whose queries Lean
        // reads beside it: the adapter ships none (the crate docs).
        None
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
    use editor_syntax_fixture_grammars as fixture;
    use editor_text::Text;

    use super::*;

    /// The texts of the captures of `source` in `text`, parsed with the
    /// rust grammar registered from the fixture crate, each with its
    /// capture's name.
    fn captured(source: &str, text: &str) -> Vec<(String, String)> {
        let grammar = GrammarName::new("rust");
        let snapshot = Text::from(text).snapshot();
        let syntax = with_registered(&fixture::RUST);
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

    /// An adapter with the fixture `grammar` registered from its native
    /// library.
    fn with_registered(grammar: &fixture::Grammar) -> TreeSitter {
        let syntax = TreeSitter::default();
        let policy = if grammar.incremental {
            ReparsePolicy::Incremental
        } else {
            ReparsePolicy::Whole
        };
        syntax
            .register(&GrammarSource {
                library: grammar.library.into(),
                symbol: grammar.symbol.to_owned(),
                policy: Some(policy),
            })
            .unwrap_or_else(|refusal| panic!("registering {}: {refusal:?}", grammar.name));
        syntax
    }

    /// `(name, text)` as owned.
    fn pair(name: &str, text: &str) -> (String, String) {
        (name.to_owned(), text.to_owned())
    }

    #[test]
    fn a_rust_functions_name_is_captured_through_its_field() {
        assert_eq!(
            captured(
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
        let syntax = with_registered(&fixture::RUST);
        let mut parser = syntax.parser(&grammar).unwrap();
        let tree = syntax.parse(&mut parser, &snapshot, None);
        let query = syntax.compile(&grammar, &source).unwrap();
        let found = captures_in(&syntax, &query, &tree, &snapshot, 0..snapshot.len()).unwrap();
        assert_eq!(
            found.iter().map(Capture::range).collect::<Vec<_>>(),
            vec![start..start + name.len()]
        );
    }

    /// The six grammars the adapter compiled in until phase 4 of the
    /// roadmap `shipped-grammars-package`, which the `languages` package
    /// now ships.
    const FORMER_BUILT_INS: [&str; 6] = [
        "json",
        "rust",
        "markdown",
        "markdown_inline",
        "toml",
        "lean",
    ];

    #[test]
    fn a_fresh_adapter_lists_no_grammar_and_for_each_former_built_in_opens_no_parser_compiles_no_query_declares_no_policy_and_ships_no_query()
     {
        let syntax = TreeSitter::default();
        assert_eq!(syntax.grammars(), Vec::<GrammarName>::new());
        assert_eq!(syntax.clone().grammars(), Vec::<GrammarName>::new());
        for name in FORMER_BUILT_INS {
            let grammar = GrammarName::new(name);
            assert!(syntax.parser(&grammar).is_none(), "{name}");
            assert_eq!(
                syntax
                    .compile(&grammar, "(_) @x")
                    .map(|_| ())
                    .unwrap_err()
                    .kind,
                QueryErrorKind::Language,
                "{name}"
            );
            assert_eq!(syntax.reparse_policy(&grammar), None, "{name}");
            for kind in QueryKind::ALL {
                assert_eq!(syntax.shipped_query(&grammar, kind), None, "{name}");
            }
            assert_eq!(syntax.registered_source(&grammar), None, "{name}");
            assert!(syntax.compile_registered(&grammar, "(_) @x").is_none());
        }
    }

    /// Where the fixture `grammar` is registered from, with its policy.
    fn source_of(grammar: &fixture::Grammar) -> GrammarSource {
        GrammarSource {
            library: grammar.library.into(),
            symbol: grammar.symbol.to_owned(),
            policy: Some(if grammar.incremental {
                ReparsePolicy::Incremental
            } else {
                ReparsePolicy::Whole
            }),
        }
    }

    #[test]
    fn a_registered_grammar_answers_the_source_it_was_registered_from_and_compiles_with_it() {
        let syntax = with_registered(&fixture::JSON);
        let json = GrammarName::new("json");
        assert_eq!(
            syntax.registered_source(&json),
            Some(source_of(&fixture::JSON))
        );
        let (source, compiled) = syntax
            .compile_registered(&json, "(object) @o")
            .expect("json is registered");
        assert_eq!(source, source_of(&fixture::JSON));
        assert!(compiled.is_ok());
        let (_, refused) = syntax
            .compile_registered(&json, "((")
            .expect("json is registered");
        assert_eq!(
            refused.map(|_| ()).unwrap_err().kind,
            QueryErrorKind::Syntax
        );

        // Registered again from another library, `json` answers the new
        // source, and a query is compiled for the new language.
        let ini = GrammarSource {
            library: editor_syntax_fixture_ini::LIBRARY.into(),
            symbol: editor_syntax_fixture_ini::OVERRIDING_SYMBOL.to_owned(),
            policy: None,
        };
        assert_eq!(syntax.register(&ini), Ok(json.clone()));
        assert_eq!(syntax.registered_source(&json), Some(ini.clone()));
        let (source, compiled) = syntax
            .compile_registered(&json, "(object) @o")
            .expect("json is registered");
        assert_eq!(source, ini);
        assert_eq!(
            compiled.map(|_| ()).unwrap_err().kind,
            QueryErrorKind::NodeType
        );
    }

    #[test]
    fn a_query_of_a_grammar_that_is_not_registered_is_refused_as_the_language() {
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
