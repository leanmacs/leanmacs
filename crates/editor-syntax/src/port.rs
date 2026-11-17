//! The port: what parses a text and answers queries of the tree, and the
//! plain data it answers in.
//!
//! Everything a [`Syntax`] hands back is in the port's own terms: a tree is
//! read as a list of [`Node`]s, a query's answer as [`Capture`]s or, match
//! by match, as [`Match`]es, a pattern's `#set!` settings as [`Setting`]s,
//! and a query that is refused as a [`QueryError`]. The tree, the parser and a
//! compiled query are the implementation's own types, which nothing above
//! the port looks inside.

use std::fmt;
use std::ops::Range;

use editor_text::{InputEdit, Point, Snapshot};

/// The name of a grammar a [`Syntax`] can parse with: `rust`, `json`.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct GrammarName(pub String);

impl GrammarName {
    /// The grammar called `name`.
    pub fn new(name: impl Into<String>) -> Self {
        Self(name.into())
    }

    /// The name.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for GrammarName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// One node of a tree, as plain data. A tree is read as its nodes in
/// pre-order ([`Syntax::nodes`]): a node, then its children in order, each
/// with theirs, so `depth` and the order together are the structure.
///
/// Two trees are equal when their nodes are: the same structure, kinds,
/// fields and ranges.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Node {
    /// The node's kind: a rule of the grammar (`function_item`) for a
    /// named node, the text of the token (`(`) for an anonymous one.
    pub kind: String,
    /// Whether the node is named: a rule of the grammar, not a literal
    /// token.
    pub named: bool,
    /// The field of its parent it is at, if any (`name`, `key`).
    pub field: Option<String>,
    /// How deep it is: 0 for the root, one more than its parent's for any
    /// other.
    pub depth: u32,
    /// The offset it starts at.
    pub start: usize,
    /// The offset it ends at, not included.
    pub end: usize,
    /// The point of `start`, with its column in bytes.
    pub start_point: Point,
    /// The point of `end`, with its column in bytes.
    pub end_point: Point,
    /// Whether it is an error: text the grammar could not place.
    pub error: bool,
    /// Whether it is missing: a token the grammar needed and the text did
    /// not have, put in with no width.
    pub missing: bool,
}

/// One capture of a query's answer: which pattern matched, which of the
/// query's captures it is ([`Syntax::capture_names`] indexes it), and the
/// range of the node it captured.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Capture {
    /// The index of the pattern that matched, in the query's text.
    pub pattern: usize,
    /// The index of the capture's name in [`Syntax::capture_names`].
    pub capture: u32,
    /// The offset the captured node starts at.
    pub start: usize,
    /// The offset the captured node ends at, not included.
    pub end: usize,
}

impl Capture {
    /// The captured node's range.
    pub fn range(&self) -> Range<usize> {
        self.start..self.end
    }
}

/// One match of a query: the pattern that matched, and its captures in
/// the order the pattern names them ([`Syntax::matches`]).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Match {
    /// The index of the pattern that matched, in the query's text.
    pub pattern: usize,
    /// Its captures, in order.
    pub captures: Vec<MatchCapture>,
}

/// A node a match captured: which of the query's captures, its range, and
/// the ranges of its named children, in order.
///
/// The named children are what an injection leaves out of its content
/// unless its pattern says `injection.include-children`
/// ([`crate::inject`]).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct MatchCapture {
    /// The index of the capture's name in [`Syntax::capture_names`].
    pub capture: u32,
    /// The offset the captured node starts at.
    pub start: usize,
    /// The offset the captured node ends at, not included.
    pub end: usize,
    /// The ranges of the node's named children, in order.
    pub named_children: Vec<Range<usize>>,
}

impl MatchCapture {
    /// The captured node's range.
    pub fn range(&self) -> Range<usize> {
        self.start..self.end
    }
}

/// One `#set!` of a pattern: its key and its value, if it has one
/// ([`Syntax::pattern_settings`]).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Setting {
    /// The key: `injection.language`.
    pub key: String,
    /// The value, if the setting has one: `rust`.
    pub value: Option<String>,
}

/// Which of a grammar's own queries: the queries a grammar is published
/// with, each for one job ([`Syntax::shipped_query`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum QueryKind {
    /// What to draw in which face: `highlights.scm`.
    Highlights,
    /// Which nodes hold text of another language: `injections.scm`.
    Injections,
    /// Which nodes are a function, a class or an argument, around and
    /// inside: `textobjects.scm`.
    TextObjects,
    /// Which nodes indent the rows they hold: `indents.scm`.
    Indents,
}

impl QueryKind {
    /// Every kind.
    pub const ALL: [Self; 4] = [
        Self::Highlights,
        Self::Injections,
        Self::TextObjects,
        Self::Indents,
    ];
}

/// How a grammar's texts are reparsed after an edit
/// ([`Syntax::reparse_policy`]): a grammar declares it, and the core
/// ([`crate::session`]) is the one reader.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ReparsePolicy {
    /// Each round reuses the old tree, told the edits since: a reparse
    /// costs what the edits touched. The grammar keeps
    /// [`crate::contract::GRAMMAR_QUALITY`]: on a text without errors, an
    /// incremental reparse equals a fresh parse.
    Incremental,
    /// Each round parses the text from scratch, handed no old tree: for a
    /// grammar whose incremental reparses of error-free texts were seen to
    /// differ from a fresh parse. It still ships.
    Whole,
}

/// Why a query was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum QueryErrorKind {
    /// The text is not a query: a paren unclosed, a stray character.
    Syntax,
    /// It names a node kind the grammar does not have.
    NodeType,
    /// It names a field the grammar does not have.
    Field,
    /// A predicate names a capture the pattern does not have.
    Capture,
    /// A predicate is malformed.
    Predicate,
    /// A pattern no tree of the grammar could match.
    Structure,
    /// The grammar itself was refused.
    Language,
}

/// A query refused, as a value: why, and the byte offset into the query's
/// text where the implementation found it. Offsets are each
/// implementation's own; the kind is what callers compare.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct QueryError {
    /// Why.
    pub kind: QueryErrorKind,
    /// Where, in bytes into the query's text.
    pub offset: usize,
}

impl fmt::Display for QueryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{:?} error at byte {} of the query",
            self.kind, self.offset
        )
    }
}

impl std::error::Error for QueryError {}

/// The port: what parses a text with a grammar, keeps a tree up to date
/// with edits, and answers queries of a tree.
///
/// Each method forwards to the parsing library; every decision above it
/// (which captures a range answers and in what order, when a tree is
/// reparsed and which result is handed out) is this crate's, and tested on
/// the fake ([`crate::fake::Parens`]). [`crate::contract::check`] is what
/// every implementation keeps.
pub trait Syntax: Send + Sync + 'static {
    /// What parses: one for each text being parsed, used by one thread at
    /// a time.
    type Parser: Send + 'static;
    /// A tree. A clone is cheap: it shares the tree.
    type Tree: Clone + Send + Sync + 'static;
    /// A compiled query.
    type Query: Send + Sync + 'static;

    /// The grammars this implementation can parse with.
    fn grammars(&self) -> Vec<GrammarName>;

    /// A parser for `grammar`; `None` for a grammar it does not have.
    fn parser(&self, grammar: &GrammarName) -> Option<Self::Parser>;

    /// How `grammar`'s texts are reparsed after an edit, as the grammar
    /// declares it; `None` for a grammar it does not have. Plain data: the
    /// core ([`crate::session`]) decides what a round hands the parser by
    /// it.
    fn reparse_policy(&self, grammar: &GrammarName) -> Option<ReparsePolicy>;

    /// The tree of `text`. With `old`, a tree of an earlier text that has
    /// been told every edit since ([`edit`](Self::edit)), the parse reuses
    /// what the edits left alone; the tree is the same either way.
    fn parse(
        &self,
        parser: &mut Self::Parser,
        text: &Snapshot,
        old: Option<&Self::Tree>,
    ) -> Self::Tree;

    /// Tells `tree` of one edit, so it can be handed to
    /// [`parse`](Self::parse) as `old`. A patch's edits are told in order.
    fn edit(&self, tree: &mut Self::Tree, edit: &InputEdit);

    /// The query `source` compiled for `grammar`, or why not.
    fn compile(&self, grammar: &GrammarName, source: &str) -> Result<Self::Query, QueryError>;

    /// The source of the query of `kind` that `grammar` is published with,
    /// pinned with the grammar it was written for; `None` for a grammar it
    /// does not have, or one published with no query of that kind.
    fn shipped_query(&self, grammar: &GrammarName, kind: QueryKind) -> Option<String>;

    /// The names of `query`'s captures, which a [`Capture`] indexes.
    fn capture_names(&self, query: &Self::Query) -> Vec<String>;

    /// The captures of `query` in `tree`, the tree of `text`, for nodes in
    /// or around `range`. It may answer more than the range, in any order
    /// and with repeats: [`crate::query::captures_in`] decides what a range
    /// answers.
    fn captures(
        &self,
        query: &Self::Query,
        tree: &Self::Tree,
        text: &Snapshot,
        range: Range<usize>,
    ) -> Vec<Capture>;

    /// The matches of `query` in `tree`, the tree of `text`, for nodes in
    /// or around `range`, its predicates applied: each match with its
    /// captures, and each captured node with the ranges of its named
    /// children. It may answer more than the range, in any order; the
    /// captures of every match, flattened, are what
    /// [`captures`](Self::captures) answers ([`crate::contract::MATCHES`]).
    fn matches(
        &self,
        query: &Self::Query,
        tree: &Self::Tree,
        text: &Snapshot,
        range: Range<usize>,
    ) -> Vec<Match>;

    /// The `#set!` settings of pattern `pattern` of `query`, in order;
    /// none for a pattern it does not have.
    fn pattern_settings(&self, query: &Self::Query, pattern: usize) -> Vec<Setting>;

    /// The tree of the bytes of `text` in `ranges` only, parsed whole with
    /// no old tree: what lies outside them is not read. `ranges` are one or
    /// more, sorted and apart, each two positions of the text. Nodes
    /// keep the text's offsets and points. The parser parses the whole of
    /// a text again afterwards.
    fn parse_in(
        &self,
        parser: &mut Self::Parser,
        text: &Snapshot,
        ranges: &[Range<usize>],
    ) -> Self::Tree;

    /// The whole tree as plain data, in pre-order.
    fn nodes(&self, tree: &Self::Tree) -> Vec<Node>;

    /// Whether `tree` has a node that is an error or missing
    /// ([`Node::error`], [`Node::missing`]): what [`nodes`](Self::nodes)
    /// would show, answered without reading the tree out.
    fn has_errors(&self, tree: &Self::Tree) -> bool;
}
