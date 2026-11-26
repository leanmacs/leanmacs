//! The contract of the syntax port: the rules every [`Syntax`] keeps, as a
//! check that runs one.
//!
//! [`check`] asks the syntax it is given about a [`Corpus`], what is
//! language-specific (a grammar, texts of it, a query), and returns the
//! names of the properties that fail. The fake passes it in this crate's
//! tests, against [`crate::fake::PARENS_CORPUS`], and each real adapter
//! runs it in its own, against a corpus for each grammar it has.
//!
//! The edits of [`GRAMMAR_QUALITY`] and of the properties over the same
//! edits go through a real [`Text`], so the patch a tree is told is the
//! edit log's own ([`Text::changes_since`]), with its edits in the form an
//! incremental parser takes ([`editor_text::Edit::input_edit`]): the
//! property holds the implementation and the log to each other. Its sweep
//! of random edits is from a fixed seed, with a small generator here and
//! not a property-test library, since the contract is published code.
//!
//! **What is promised after an edit.** A round keeps the incremental
//! reparse whatever the text holds ([`crate::session`]), and an idle
//! refresh restores exactness once the text is quiet. So the contract
//! holds a grammar equal to a fresh parse incrementally only on texts
//! without errors ([`GRAMMAR_QUALITY`]); holds every tree a round keeps to
//! be whole ([`DELIVERED_WHOLE`]); holds the core's rounds and refresh to
//! end at a fresh parse ([`CONVERGES`]); and holds the grammar to declare
//! the policy its corpus pins, which the core honours ([`REPARSE_POLICY`]).
//! A grammar that fails [`GRAMMAR_QUALITY`] still ships, as
//! [`ReparsePolicy::Whole`], and is then promised nothing incremental.
//!
//! **The oracle.** Each fresh parse a reparse is compared with is made on a
//! parser opened for the oracle, never the run's own, so a parser that
//! remembers what it parsed cannot hide its own answer.

use std::ops::Range;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use editor_text::{ChangeSet, InputEdit, Origin, Revision, Snapshot, Text, Transaction};

use crate::highlight::{HighlightSpan, Highlighter};
use crate::port::{
    Capture, GrammarName, GrammarSource, Match, Node, QueryError, QueryErrorKind, QueryKind,
    RegistrationRefusal, ReparsePolicy, Setting, Syntax,
};
use crate::query::{captures_in, flatten, overlaps, widened};
use crate::session::{Consumer, Latest, Outcome, Parsed, Session, Source};

pub mod registration;

/// What is language-specific in the contract: a grammar, texts of it, and
/// queries.
#[derive(Debug, Clone, Copy)]
pub struct Corpus {
    /// The grammar.
    pub grammar: &'static str,
    /// Texts of the grammar, some with errors.
    pub texts: &'static [&'static str],
    /// What the random edits insert.
    pub pieces: &'static [&'static str],
    /// A query that compiles and captures something in the texts.
    pub query: &'static str,
    /// The names of its captures, in order.
    pub query_names: &'static [&'static str],
    /// Queries that are refused, each with why.
    pub bad_queries: &'static [(&'static str, QueryErrorKind)],
    /// A query that names a node kind the grammar does not have.
    pub unknown_kind_query: &'static str,
    /// The kinds of query the grammar ships ([`Syntax::shipped_query`]).
    pub shipped: &'static [QueryKind],
    /// The highlights query [`HIGHLIGHTS_AFTER_EDITS`] and [`CONVERGES`]
    /// draw with when `shipped` lacks [`QueryKind::Highlights`]: how a
    /// grammar that ships no query, as one registered at run time ships
    /// none, is held to both with the query that sits beside its library.
    /// Ignored when the grammar ships its own; with neither, both fail.
    pub highlights: Option<&'static str>,
    /// A query whose patterns have `#set!` settings.
    pub settings_query: &'static str,
    /// The settings of each pattern of `settings_query`, in order: each a
    /// key and its value, if it has one.
    pub settings: &'static [&'static [(&'static str, Option<&'static str>)]],
    /// The reparse policy the grammar declares ([`Syntax::reparse_policy`]),
    /// pinned here as `shipped` pins its queries.
    pub policy: ReparsePolicy,
}

/// The corpus's grammar is listed and opens a parser; a grammar that is not
/// listed opens none.
pub const GRAMMARS: &str =
    "the corpus's grammar is listed and opens a parser, and one not listed opens none";
/// The root is the one node at depth 0 and reaches the text's end; every
/// node lies within its parent, on positions of the text, with points that
/// are its offsets'; and siblings are in order.
///
/// The root may start after the text's start: tree-sitter's starts where
/// its first token or extra does, after any blanks that lead the text.
pub const WHOLE: &str = "the root reaches the end of the text, every node lies within its parent on positions with their points, and siblings are in order";
/// Two fresh parses of one snapshot are equal.
pub const DETERMINISTIC: &str = "two fresh parses of one snapshot are equal";
/// Grammar quality: after edits, the tree told the log's patch and
/// reparsed with it, as the core reparses, equals a fresh parse of the
/// same snapshot whenever that fresh parse has no error or missing node
/// ([`Syntax::has_errors`], tied to the nodes by [`ERRORS`]); and at least
/// one reparse is compared, so the property is never held by none.
///
/// How a library recovers from an error can depend on what it reuses
/// (tree-sitter's did, on 11 of some 6,700 reparses of random edits of
/// Rust, seen on 2026-11-16), so a text with an error is promised only an
/// eventual fresh parse ([`CONVERGES`]). A grammar of the policy
/// [`ReparsePolicy::Whole`] is promised nothing incremental, and holds
/// this with nothing to compare.
pub const GRAMMAR_QUALITY: &str =
    "on a text without errors, an incremental reparse equals a fresh parse";
/// A tree has errors ([`Syntax::has_errors`]) exactly when one of its
/// nodes is an error or missing; and the corpus has texts of both.
pub const ERRORS: &str = "a tree has errors exactly when one of its nodes is an error or missing";
/// Each bad query is refused with its kind, and one that names an unknown
/// node kind with [`QueryErrorKind::NodeType`].
pub const QUERY_REFUSED: &str =
    "a bad query is refused as a value with its kind, and an unknown node kind as a node type";
/// A query's capture names are the corpus's, in order.
pub const QUERY_NAMES: &str = "a query's capture names are its captures', in order";
/// What a range answers is what the whole text answers, filtered by the
/// overlap rule: the port may answer more than a range, never less.
pub const RANGE: &str = "a range answers the whole text's captures that overlap it";
/// Every capture names one of the query's captures and is the range of a
/// node of the tree, and the answer is in the core's order with no
/// repeats.
pub const ORDER: &str =
    "every capture names a capture of the query and is a node's range, in the core's order, once";

/// The grammar is published with a query of each kind the corpus lists
/// ([`Corpus::shipped`], [`Syntax::shipped_query`]), each compiling for
/// it, and with none of any other kind; and a grammar that is not listed
/// ships none of any kind.
pub const SHIPPED: &str = "the corpus's grammar ships a query of each kind the corpus lists, which compiles, and none of another kind, and one not listed ships none";

/// Over three sets of ranges of each text (the whole text, its second
/// half, and its first and last thirds together, each end moved back to a
/// position): a parse in the whole text equals a fresh parse; every node
/// but the root lies within the hull of the ranges, and every leaf with
/// width starts in a range and ends in one; two parses in the same ranges
/// are equal; and a parse of the whole text after one in ranges equals a
/// fresh parse, so the parser parses the whole of a text again.
///
/// A leaf may run from one range into the next: tree-sitter's lexer goes
/// on reading a token at the next range's start (a `type_identifier` of
/// Rust from byte 205 to 415, over ranges `0..206` and `413..619`, seen on
/// 2026-11-16). What a leaf holds of the gap is not the layer's, and
/// highlights are cut to a layer's ranges ([`crate::highlight`]).
pub const IN_RANGES: &str = "a parse in ranges reads only the ranges, equals a fresh parse over the whole text, is the same twice, and leaves the parser parsing whole texts";

/// A range's matches ([`Syntax::matches`]), flattened and put through the
/// rule of [`captures_in`], are the captures [`captures_in`] answers of it;
/// and each captured node's named children are in order, apart, within it,
/// and the named children of a node of its range in the tree.
pub const MATCHES: &str =
    "a range's matches, flattened, are its captures, each with the named children of its node";

/// The corpus's settings query answers its settings, pattern by pattern,
/// and none for a pattern it does not have.
pub const SETTINGS: &str = "each pattern's settings are the ones its source sets, in order";

/// Over the same edits as [`GRAMMAR_QUALITY`], the cases and the sweep,
/// the spans the grammar's shipped highlights query draws
/// ([`crate::highlight::spans`], each capture in a face of its own) on the
/// tree reparsed as the core reparses equal those on a fresh parse of the
/// same snapshot, whenever that fresh parse has no error; and at least one
/// reparse is compared. A [`ReparsePolicy::Whole`] grammar holds it with
/// nothing to compare. A grammar that ships no highlights query is drawn
/// with the corpus's ([`Corpus::highlights`]), and fails with none.
pub const HIGHLIGHTS_AFTER_EDITS: &str = "on a text without errors, the shipped highlights of an incremental reparse equal those of a fresh parse";

/// Over the same edits as [`GRAMMAR_QUALITY`], every tree a round keeps,
/// incremental reparses of texts with errors among them, is whole
/// ([`is_whole`]) against its snapshot.
pub const DELIVERED_WHOLE: &str = "every tree a round keeps is whole";

/// From each text, over each named case and a short sweep, a real
/// [`Session`] driven round by round ([`Session::parse_once`]) and then
/// refreshed ([`Session::refresh_once`]) delivers a tree whose nodes equal
/// a fresh parse's, drawn with the shipped highlights (or, for a grammar
/// that ships none, the corpus's: [`Corpus::highlights`]) as a fresh
/// highlight draws them; and a second refresh is [`Outcome::UpToDate`] and calls no
/// consumer. Timing is the worker's rule, pinned in its own tests: here
/// there is no worker and no clock.
pub const CONVERGES: &str = "after the idle refresh the delivered tree equals a fresh parse, and a refresh that finds no difference delivers nothing";

/// The grammar declares the corpus's policy ([`Corpus::policy`]), a grammar
/// not listed declares none, and the core's rounds honour it: over the
/// named cases, a [`ReparsePolicy::Whole`] grammar's rounds are never
/// handed an old tree, and a [`ReparsePolicy::Incremental`] grammar's are
/// handed one at least once after an edit.
pub const REPARSE_POLICY: &str = "the grammar declares the corpus's reparse policy, an unlisted grammar has none, and the core's rounds honour it";

/// Every property, by name.
pub const PROPERTIES: [&str; 17] = [
    GRAMMARS,
    WHOLE,
    DETERMINISTIC,
    ERRORS,
    GRAMMAR_QUALITY,
    QUERY_REFUSED,
    QUERY_NAMES,
    RANGE,
    ORDER,
    SHIPPED,
    HIGHLIGHTS_AFTER_EDITS,
    IN_RANGES,
    MATCHES,
    SETTINGS,
    DELIVERED_WHOLE,
    CONVERGES,
    REPARSE_POLICY,
];

/// How many random edit sequences the sweep runs from each text.
const SEQUENCES: usize = 12;
/// How many random edit sequences [`CONVERGES`] runs from each text.
const CONVERGING_SEQUENCES: usize = 3;
/// How many reparses each sequence has.
const STEPS: usize = 8;

/// Holds `syntax` to the contract over `corpus`, and returns the names of
/// the properties that fail: none when it keeps them all. A grammar that
/// opens no parser fails every property that parses.
///
/// The syntax is cloned once, for [`REPARSE_POLICY`], which watches what
/// the core's rounds hand a clone of it behind a wrapper.
pub fn check<S: Syntax + Clone>(syntax: &S, corpus: &Corpus) -> Vec<&'static str> {
    let grammar = GrammarName::new(corpus.grammar);
    let grammars = grammars(syntax, &grammar);
    let parses = |property: fn(&S, &mut S::Parser, &Corpus) -> bool| {
        syntax
            .parser(&grammar)
            .is_some_and(|mut parser| property(syntax, &mut parser, corpus))
    };
    let results = [
        (GRAMMARS, grammars),
        (WHOLE, parses(whole)),
        (DETERMINISTIC, parses(deterministic)),
        (ERRORS, parses(errors)),
        (GRAMMAR_QUALITY, parses(grammar_quality)),
        (QUERY_REFUSED, query_refused(syntax, &grammar, corpus)),
        (QUERY_NAMES, query_names(syntax, &grammar, corpus)),
        (RANGE, parses(range)),
        (ORDER, parses(order)),
        (SHIPPED, shipped(syntax, &grammar, corpus)),
        (HIGHLIGHTS_AFTER_EDITS, parses(highlights_after_edits)),
        (IN_RANGES, parses(in_ranges)),
        (MATCHES, parses(matches)),
        (SETTINGS, settings(syntax, &grammar, corpus)),
        (DELIVERED_WHOLE, parses(delivered_whole)),
        (CONVERGES, converges(syntax, corpus)),
        (REPARSE_POLICY, reparse_policy(syntax, corpus)),
    ];
    results
        .into_iter()
        .filter_map(|(name, holds)| (!holds).then_some(name))
        .collect()
}

/// [`GRAMMARS`].
fn grammars<S: Syntax>(syntax: &S, grammar: &GrammarName) -> bool {
    let listed = syntax.grammars();
    let other = GrammarName::new(format!("{grammar}-that-is-not-listed"));
    listed.contains(grammar)
        && syntax.parser(grammar).is_some()
        && !listed.contains(&other)
        && syntax.parser(&other).is_none()
}

/// [`SHIPPED`].
fn shipped<S: Syntax>(syntax: &S, grammar: &GrammarName, corpus: &Corpus) -> bool {
    let other = GrammarName::new(format!("{grammar}-that-is-not-listed"));
    QueryKind::ALL.iter().all(|&kind| {
        let source = syntax.shipped_query(grammar, kind);
        let as_listed = if corpus.shipped.contains(&kind) {
            source.is_some_and(|source| syntax.compile(grammar, &source).is_ok())
        } else {
            source.is_none()
        };
        as_listed && syntax.shipped_query(&other, kind).is_none()
    })
}

/// `ranges` with the empty ones dropped, sorted, and those that touch or
/// overlap made one.
fn apart(mut ranges: Vec<Range<usize>>) -> Vec<Range<usize>> {
    ranges.retain(|range| !range.is_empty());
    ranges.sort_by_key(|range| range.start);
    let mut merged: Vec<Range<usize>> = Vec::new();
    for range in ranges {
        match merged.last_mut() {
            Some(last) if range.start <= last.end => last.end = last.end.max(range.end),
            _ => merged.push(range),
        }
    }
    merged
}

/// The sets of ranges [`IN_RANGES`] parses `text` in: the whole text, its
/// second half, and its first and last thirds together, each end moved
/// back to a position; a set left with no range is not asked.
fn range_sets(text: &Snapshot) -> Vec<Vec<Range<usize>>> {
    let len = text.len();
    let third = len / 3;
    [
        std::iter::once(0..len).collect(),
        std::iter::once(middle(text)..len).collect(),
        vec![0..boundary(text, third), boundary(text, len - third)..len],
    ]
    .into_iter()
    .map(apart)
    .filter(|ranges| !ranges.is_empty())
    .collect()
}

/// Whether the node at `index` of `nodes`, a tree in pre-order, has no
/// children.
fn is_leaf(nodes: &[Node], index: usize) -> bool {
    nodes
        .get(index + 1)
        .is_none_or(|next| next.depth <= nodes[index].depth)
}

/// [`IN_RANGES`].
fn in_ranges<S: Syntax>(syntax: &S, parser: &mut S::Parser, corpus: &Corpus) -> bool {
    corpus.texts.iter().all(|text| {
        let snapshot = snapshot_of(text);
        let fresh = syntax.nodes(&syntax.parse(parser, &snapshot, None));
        range_sets(&snapshot).into_iter().all(|ranges| {
            let nodes = syntax.nodes(&syntax.parse_in(parser, &snapshot, &ranges));
            let again = syntax.nodes(&syntax.parse_in(parser, &snapshot, &ranges));
            let whole_again = syntax.nodes(&syntax.parse(parser, &snapshot, None));
            let hull = ranges[0].start..ranges[ranges.len() - 1].end;
            let within_hull = nodes
                .iter()
                .skip(1)
                .all(|node| hull.start <= node.start && node.end <= hull.end);
            let leaves_within = (0..nodes.len()).all(|index| {
                let node = &nodes[index];
                let starts_in = ranges
                    .iter()
                    .any(|range| range.start <= node.start && node.start < range.end);
                let ends_in = ranges
                    .iter()
                    .any(|range| range.start < node.end && node.end <= range.end);
                !is_leaf(&nodes, index) || node.start == node.end || starts_in && ends_in
            });
            let whole = ranges.len() == 1 && ranges[0] == (0..snapshot.len());
            (!whole || nodes == fresh)
                && within_hull
                && leaves_within
                && nodes == again
                && whole_again == fresh
        })
    })
}

/// The ranges of the named children of the node at `index` of `nodes`, a
/// tree in pre-order.
fn named_children_of(nodes: &[Node], index: usize) -> Vec<Range<usize>> {
    let depth = nodes[index].depth;
    nodes[index + 1..]
        .iter()
        .take_while(|node| node.depth > depth)
        .filter(|node| node.depth == depth + 1 && node.named)
        .map(|node| node.start..node.end)
        .collect()
}

/// [`MATCHES`]: from every text, the whole text and each row; and at least
/// one capture with named children, so the children are never held only
/// by captures that have none.
fn matches<S: Syntax>(syntax: &S, parser: &mut S::Parser, corpus: &Corpus) -> bool {
    let grammar = GrammarName::new(corpus.grammar);
    let Ok(query) = syntax.compile(&grammar, corpus.query) else {
        return false;
    };
    let mut with_children = false;
    let every = corpus.texts.iter().all(|text| {
        let snapshot = snapshot_of(text);
        let tree = syntax.parse(parser, &snapshot, None);
        let nodes = syntax.nodes(&tree);
        let rows = (0..snapshot.row_count()).filter_map(|row| snapshot.row_range(row));
        let ranges: Vec<Range<usize>> = std::iter::once(0..snapshot.len()).chain(rows).collect();
        ranges.into_iter().all(|range| {
            let found = syntax.matches(&query, &tree, &snapshot, widened(&snapshot, &range));
            let mut flat: Vec<Capture> = flatten(&found)
                .into_iter()
                .filter(|capture| overlaps(capture.range(), range.clone()))
                .collect();
            crate::query::sort(&mut flat);
            let children_hold = found
                .iter()
                .flat_map(|found| &found.captures)
                .all(|capture| {
                    with_children |= !capture.named_children.is_empty();
                    let in_order = capture
                        .named_children
                        .windows(2)
                        .all(|pair| pair[0].end <= pair[1].start);
                    let within = capture
                        .named_children
                        .iter()
                        .all(|child| capture.start <= child.start && child.end <= capture.end);
                    let of_a_node = (0..nodes.len()).any(|index| {
                        nodes[index].start == capture.start
                            && nodes[index].end == capture.end
                            && named_children_of(&nodes, index) == capture.named_children
                    });
                    in_order && within && of_a_node
                });
            captures_in(syntax, &query, &tree, &snapshot, range) == Ok(flat) && children_hold
        })
    });
    every && with_children
}

/// [`SETTINGS`].
fn settings<S: Syntax>(syntax: &S, grammar: &GrammarName, corpus: &Corpus) -> bool {
    let Ok(query) = syntax.compile(grammar, corpus.settings_query) else {
        return false;
    };
    let as_set = corpus
        .settings
        .iter()
        .enumerate()
        .all(|(pattern, expected)| {
            let found = syntax.pattern_settings(&query, pattern);
            found.len() == expected.len()
                && found
                    .iter()
                    .zip(expected.iter())
                    .all(|(found, (key, value))| {
                        found.key == *key && found.value.as_deref() == *value
                    })
        });
    let some = corpus.settings.iter().any(|settings| !settings.is_empty());
    as_set
        && some
        && syntax
            .pattern_settings(&query, corpus.settings.len())
            .is_empty()
}

/// The snapshot of `text`.
fn snapshot_of(text: &str) -> Snapshot {
    Text::from(text).snapshot()
}

/// [`WHOLE`].
fn whole<S: Syntax>(syntax: &S, parser: &mut S::Parser, corpus: &Corpus) -> bool {
    corpus.texts.iter().all(|text| {
        let snapshot = snapshot_of(text);
        let tree = syntax.parse(parser, &snapshot, None);
        is_whole(&syntax.nodes(&tree), &snapshot)
    })
}

/// Whether `nodes` are a tree over the whole of `text` ([`WHOLE`]).
pub fn is_whole(nodes: &[Node], text: &Snapshot) -> bool {
    /// An ancestor of the node being looked at: its range, and where its
    /// last child seen ended.
    struct Level {
        range: Range<usize>,
        last_child_end: usize,
    }
    let len = text.len();
    let Some(root) = nodes.first() else {
        return false;
    };
    if root.depth != 0 || root.end != len {
        return false;
    }
    let mut levels: Vec<Level> = Vec::new();
    for (index, node) in nodes.iter().enumerate() {
        let depth = usize::try_from(node.depth).unwrap_or(usize::MAX);
        if (depth == 0) != (index == 0) || depth > levels.len() {
            return false;
        }
        let placed = node.start <= node.end
            && text.offset_to_point(node.start) == Some(node.start_point)
            && text.offset_to_point(node.end) == Some(node.end_point);
        if !placed {
            return false;
        }
        levels.truncate(depth);
        if let Some(parent) = levels.last_mut() {
            let within = parent.range.start <= node.start && node.end <= parent.range.end;
            if !within || node.start < parent.last_child_end {
                return false;
            }
            parent.last_child_end = node.end;
        }
        levels.push(Level {
            range: node.start..node.end,
            last_child_end: node.start,
        });
    }
    true
}

/// [`DETERMINISTIC`].
fn deterministic<S: Syntax>(syntax: &S, parser: &mut S::Parser, corpus: &Corpus) -> bool {
    corpus.texts.iter().all(|text| {
        let snapshot = snapshot_of(text);
        let first = syntax.nodes(&syntax.parse(parser, &snapshot, None));
        let second = syntax.nodes(&syntax.parse(parser, &snapshot, None));
        first == second
    })
}

/// [`ERRORS`].
fn errors<S: Syntax>(syntax: &S, parser: &mut S::Parser, corpus: &Corpus) -> bool {
    let (mut with, mut without) = (false, false);
    let every = corpus.texts.iter().all(|text| {
        let tree = syntax.parse(parser, &snapshot_of(text), None);
        let shown = syntax
            .nodes(&tree)
            .iter()
            .any(|node| node.error || node.missing);
        with |= shown;
        without |= !shown;
        syntax.has_errors(&tree) == shown
    });
    every && with && without
}

/// A text being edited, and the tree that follows it by reparsing from the
/// log's patches as the core reparses: for [`ReparsePolicy::Incremental`],
/// with the tree told the patch, keeping the result whatever it holds; for
/// [`ReparsePolicy::Whole`], with no old tree.
struct Run<'a, S: Syntax> {
    /// The implementation.
    syntax: &'a S,
    /// The policy the corpus pins.
    policy: ReparsePolicy,
    /// The text.
    text: Text,
    /// The tree of the text at `revision`.
    tree: S::Tree,
    /// The revision the tree is of.
    revision: Revision,
}

impl<'a, S: Syntax> Run<'a, S> {
    /// A run from `text`, parsed fresh, reparsed by `policy`.
    fn new(syntax: &'a S, parser: &mut S::Parser, text: &str, policy: ReparsePolicy) -> Self {
        let text = Text::from(text);
        let snapshot = text.snapshot();
        let tree = syntax.parse(parser, &snapshot, None);
        Self {
            syntax,
            policy,
            text,
            tree,
            revision: snapshot.revision(),
        }
    }

    /// The text as it is now.
    fn snapshot(&self) -> Snapshot {
        self.text.snapshot()
    }

    /// Reparses the text as the core reparses, keeps the result, and
    /// returns whether `same` holds of it and the oracle's fresh parse of
    /// the snapshot.
    fn reparse(
        &mut self,
        parser: &mut S::Parser,
        oracle: &mut S::Parser,
        same: Same<'_, S>,
    ) -> bool {
        let Ok(patch) = self.text.changes_since(self.revision) else {
            return false;
        };
        let snapshot = self.snapshot();
        let reparsed = match self.policy {
            ReparsePolicy::Incremental => {
                let mut edited = self.tree.clone();
                for edit in &patch.edits {
                    self.syntax.edit(&mut edited, &edit.input_edit());
                }
                self.syntax.parse(parser, &snapshot, Some(&edited))
            }
            ReparsePolicy::Whole => self.syntax.parse(parser, &snapshot, None),
        };
        let fresh = self.syntax.parse(oracle, &snapshot, None);
        let holds = same(&reparsed, &fresh, &snapshot);
        self.tree = reparsed;
        self.revision = snapshot.revision();
        holds
    }
}

/// Applies one transaction to `text`: each change a range of the text as it
/// is, in order and not overlapping, and what replaces it. False when the
/// text refused it.
fn apply(text: &mut Text, changes: &[(Range<usize>, &str)]) -> bool {
    let len = text.current().len();
    let mut set = ChangeSet::new();
    let mut kept = 0;
    for (range, insert) in changes {
        if range.start < kept {
            return false;
        }
        set.retain(range.start - kept);
        set.insert(insert);
        set.delete(range.end.saturating_sub(range.start));
        kept = range.end;
    }
    set.retain(len.saturating_sub(kept));
    text.apply(&Transaction::new(set), Origin::default())
        .is_ok()
}

/// Applies the inverse of every transaction applied to `text` so far, as
/// one transaction, which puts the text back as it was made. False when the
/// text refused it.
fn undo(text: &mut Text) -> bool {
    let last = text.current().revision();
    last == Revision::new(0)
        || text
            .apply_inverse(Revision::new(1), last, Origin::default())
            .is_ok()
}

/// The last position of `text` at or before `offset`, or its end.
fn boundary(text: &Snapshot, offset: usize) -> usize {
    let mut offset = offset.min(text.len());
    while !text.is_char_boundary(offset) {
        offset -= 1;
    }
    offset
}

/// The position nearest before the middle of `text`.
fn middle(text: &Snapshot) -> usize {
    boundary(text, text.len() / 2)
}

/// A named case of [`GRAMMAR_QUALITY`]: the transactions applied, each
/// computed from the text as it is, before one reparse.
type NamedCase = fn(&Snapshot, &Corpus) -> Vec<Vec<(Range<usize>, String)>>;

/// The named cases of [`GRAMMAR_QUALITY`].
const NAMED_CASES: [NamedCase; 10] = [
    // An insert inside a token: in the middle of the text.
    |text, corpus| {
        vec![vec![(
            middle(text)..middle(text),
            corpus.pieces[0].to_owned(),
        )]]
    },
    // A delete across lines: from the middle of the first row to the
    // middle of the second, or of the text when it has one row.
    |text, _| {
        let start = text
            .row_range(0)
            .map_or(0, |row| boundary(text, (row.start + row.end) / 2));
        let end = text
            .row_range(1)
            .map_or(text.len(), |row| boundary(text, (row.start + row.end) / 2))
            .max(start);
        vec![vec![(start..end, String::new())]]
    },
    // Everything replaced with nothing.
    |text, _| vec![vec![(0..text.len(), String::new())]],
    // An edit at offset 0.
    |_, corpus| {
        vec![vec![(
            0..0,
            corpus.pieces[corpus.pieces.len() - 1].to_owned(),
        )]]
    },
    // An edit at the end.
    |text, corpus| vec![vec![(text.len()..text.len(), corpus.pieces[0].to_owned())]],
    // A CRLF line ending put in.
    |text, _| vec![vec![(middle(text)..middle(text), "\r\n".to_owned())]],
    // Multibyte text put in, and a character of it taken out again.
    |text, _| {
        let at = middle(text);
        vec![
            vec![(at..at, "é漢😀".to_owned())],
            vec![(at + 2..at + 5, String::new())],
        ]
    },
    // One transaction of several changes, so the later ones start at
    // different points before and after: an insert at the start, a delete
    // in the middle, a replace at the end.
    |text, corpus| {
        let at = middle(text);
        let end = text.len();
        let deleted = at..boundary(text, at + 3).max(at);
        let last = boundary(text, end.saturating_sub(1)).max(deleted.end);
        vec![vec![
            (0..0, "\n".to_owned()),
            (deleted, String::new()),
            (last..end, corpus.pieces[0].to_owned()),
        ]]
    },
    // Several transactions coalesced into one pulled patch, the second
    // inside what the first inserted.
    |text, corpus| {
        let at = middle(text);
        vec![
            vec![(at..at, format!("{0}{0}", corpus.pieces[0]))],
            vec![(at + 1..at + 1, "\n".to_owned())],
            vec![(0..0, corpus.pieces[1].to_owned())],
        ]
    },
    // Everything put back after it was taken away.
    |text, _| {
        vec![
            vec![(0..text.len(), String::new())],
            vec![(0..0, text.to_string())],
        ]
    },
];

/// A named case's transaction, clamped to `text`, the text as it is when it
/// is applied: a case computes each of its transactions from the text
/// before the first.
fn clamped(text: &Snapshot, changes: &[(Range<usize>, String)]) -> Vec<(Range<usize>, String)> {
    changes
        .iter()
        .map(|(range, insert)| {
            let start = boundary(text, range.start);
            (start..boundary(text, range.end).max(start), insert.clone())
        })
        .collect()
}

/// `changes` with their inserts borrowed.
fn borrowed(changes: &[(Range<usize>, String)]) -> Vec<(Range<usize>, &str)> {
    changes
        .iter()
        .map(|(range, insert)| (range.clone(), insert.as_str()))
        .collect()
}

/// What a reparse is held to: whether a tree reparsed as the core reparses
/// and the oracle's fresh parse, both of the snapshot, agree.
type Same<'a, S> = &'a mut dyn FnMut(&<S as Syntax>::Tree, &<S as Syntax>::Tree, &Snapshot) -> bool;

/// [`GRAMMAR_QUALITY`]: the reparsed tree's nodes are a fresh parse's when
/// that has no error.
fn grammar_quality<S: Syntax>(syntax: &S, parser: &mut S::Parser, corpus: &Corpus) -> bool {
    if corpus.policy == ReparsePolicy::Whole {
        return true;
    }
    let mut compared = 0_usize;
    let mut same = |reparsed: &S::Tree, fresh: &S::Tree, _: &Snapshot| {
        if syntax.has_errors(fresh) {
            return true;
        }
        compared += 1;
        syntax.nodes(reparsed) == syntax.nodes(fresh)
    };
    after_edits(syntax, parser, corpus, &mut same) && compared > 0
}

/// [`HIGHLIGHTS_AFTER_EDITS`]: the shipped highlights of the reparsed tree
/// are a fresh parse's, each capture in a face of its own, when that has
/// no error.
fn highlights_after_edits<S: Syntax>(syntax: &S, parser: &mut S::Parser, corpus: &Corpus) -> bool {
    let Some(highlighter) = shipped_highlighter(syntax, corpus) else {
        return false;
    };
    if corpus.policy == ReparsePolicy::Whole {
        return true;
    }
    let drawn = |tree: &S::Tree, snapshot: &Snapshot| {
        captures_in(
            syntax,
            highlighter.query(),
            tree,
            snapshot,
            0..snapshot.len(),
        )
        .map(|captures| crate::highlight::spans(&highlighter, &captures))
    };
    let mut compared = 0_usize;
    let mut same = |reparsed: &S::Tree, fresh: &S::Tree, snapshot: &Snapshot| {
        if syntax.has_errors(fresh) {
            return true;
        }
        compared += 1;
        drawn(reparsed, snapshot) == drawn(fresh, snapshot)
    };
    after_edits(syntax, parser, corpus, &mut same) && compared > 0
}

/// [`DELIVERED_WHOLE`]: every reparsed tree is whole against its snapshot.
fn delivered_whole<S: Syntax>(syntax: &S, parser: &mut S::Parser, corpus: &Corpus) -> bool {
    let mut same = |reparsed: &S::Tree, _: &S::Tree, snapshot: &Snapshot| {
        is_whole(&syntax.nodes(reparsed), snapshot)
    };
    after_edits(syntax, parser, corpus, &mut same)
}

/// The highlights query the properties draw with, compiled, each capture
/// in a face named after it: the grammar's shipped one when the corpus
/// lists [`QueryKind::Highlights`], else the corpus's own
/// ([`Corpus::highlights`]); `None` when there is none that compiles.
fn shipped_highlighter<S: Syntax>(syntax: &S, corpus: &Corpus) -> Option<Highlighter<S::Query>> {
    let grammar = GrammarName::new(corpus.grammar);
    let source = if corpus.shipped.contains(&QueryKind::Highlights) {
        syntax.shipped_query(&grammar, QueryKind::Highlights)
    } else {
        corpus.highlights.map(str::to_owned)
    };
    let query = source.and_then(|source| syntax.compile(&grammar, &source).ok())?;
    let names = syntax.capture_names(&query);
    let faces = names.iter().cloned().map(Some).collect();
    Highlighter::new(Arc::new(query), names.len(), faces).ok()
}

/// The named cases from every text, and the sweep, each reparse held to
/// `same`, with the oracle's parses made on a parser of its own.
fn after_edits<S: Syntax>(
    syntax: &S,
    parser: &mut S::Parser,
    corpus: &Corpus,
    same: Same<'_, S>,
) -> bool {
    let Some(mut oracle) = syntax.parser(&GrammarName::new(corpus.grammar)) else {
        return false;
    };
    let named = corpus.texts.iter().all(|text| {
        NAMED_CASES.iter().all(|case| {
            let mut run = Run::new(syntax, parser, text, corpus.policy);
            let transactions = case(&run.snapshot(), corpus);
            let applied = transactions.iter().all(|changes| {
                let changes = clamped(&run.snapshot(), changes);
                apply(&mut run.text, &borrowed(&changes))
            });
            applied && run.reparse(parser, &mut oracle, same)
        })
    });
    named && sweep(syntax, parser, &mut oracle, corpus, same)
}

/// The sweep of [`GRAMMAR_QUALITY`] and the properties over the same edits:
/// from each text, random sequences of transactions, each step one to
/// three transactions of one to three changes, reparsed once a step; and
/// then the inverse of the whole sequence, which puts the text back as it
/// was, reparsed once more.
fn sweep<S: Syntax>(
    syntax: &S,
    parser: &mut S::Parser,
    oracle: &mut S::Parser,
    corpus: &Corpus,
    same: Same<'_, S>,
) -> bool {
    let mut random = Random(0x5eed_5eed_5eed_5eed);
    corpus.texts.iter().all(|text| {
        (0..SEQUENCES).all(|_| {
            let mut run = Run::new(syntax, parser, text, corpus.policy);
            (0..STEPS).all(|_| {
                let transactions = 1 + random.below(3);
                let applied = (0..transactions).all(|_| {
                    let changes = random.changes(&run.snapshot(), corpus.pieces);
                    apply(&mut run.text, &changes)
                });
                applied && run.reparse(parser, oracle, same)
            }) && undo(&mut run.text)
                && run.reparse(parser, oracle, same)
        })
    })
}

/// A text behind a lock, read by a contract's session as its source.
#[derive(Clone)]
struct Edited(Arc<Mutex<Text>>);

impl Edited {
    /// A text of `text`.
    fn new(text: &str) -> Self {
        Self(Arc::new(Mutex::new(Text::from(text))))
    }

    /// The text, locked.
    fn lock(&self) -> MutexGuard<'_, Text> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The text as it is now.
    fn snapshot(&self) -> Snapshot {
        self.lock().snapshot()
    }
}

impl Source for Edited {
    fn latest(&self, since: Option<Revision>) -> Option<Latest> {
        let text = self.lock();
        Some(Latest {
            snapshot: text.snapshot(),
            patch: since.and_then(|since| text.changes_since(since).ok()),
        })
    }
}

/// A consumer that counts what it is handed.
struct Counting(Arc<AtomicUsize>);

impl<T> Consumer<T> for Counting {
    fn deliver(&self, _: &Parsed<T>) {
        self.0.fetch_add(1, Ordering::Relaxed);
    }
}

/// A session of a text being edited, its first round run, and the count of
/// what it delivers.
struct Driven<S: Syntax> {
    /// The text.
    text: Edited,
    /// The session.
    session: Session<S>,
    /// How many results it has delivered.
    delivered: Arc<AtomicUsize>,
}

impl<S: Syntax> Driven<S> {
    /// A session of `text` with `grammar`, drawn with `highlighter` when
    /// there is one, its first round run; `None` when the syntax makes no
    /// session of it.
    fn new(
        syntax: &S,
        grammar: &GrammarName,
        text: &str,
        highlighter: Option<Highlighter<S::Query>>,
    ) -> Option<Self> {
        let text = Edited::new(text);
        let session = Session::new(syntax, grammar.clone(), Box::new(text.clone()))?;
        let delivered = Arc::new(AtomicUsize::new(0));
        session.subscribe(Box::new(Counting(delivered.clone())));
        if let Some(highlighter) = highlighter {
            session.set_highlighter(highlighter);
        }
        session.parse_once(syntax);
        Some(Self {
            text,
            session,
            delivered,
        })
    }

    /// Applies one transaction, tells the session and runs its round; false
    /// when the text refused it.
    fn edit(&self, syntax: &S, changes: &[(Range<usize>, &str)]) -> bool {
        let revision = {
            let mut text = self.text.lock();
            if !apply(&mut text, changes) {
                return false;
            }
            text.current().revision()
        };
        self.session.touch(revision);
        self.session.parse_once(syntax);
        true
    }

    /// Undoes every transaction, tells the session and runs its round;
    /// false when the text refused it.
    fn undo(&self, syntax: &S) -> bool {
        let revision = {
            let mut text = self.text.lock();
            if !undo(&mut text) {
                return false;
            }
            text.current().revision()
        };
        self.session.touch(revision);
        self.session.parse_once(syntax);
        true
    }

    /// Runs one named case's transactions, each a round.
    fn case(&self, syntax: &S, case: NamedCase, corpus: &Corpus) -> bool {
        case(&self.text.snapshot(), corpus).iter().all(|changes| {
            let changes = clamped(&self.text.snapshot(), changes);
            self.edit(syntax, &borrowed(&changes))
        })
    }
}

/// [`CONVERGES`].
fn converges<S: Syntax>(syntax: &S, corpus: &Corpus) -> bool {
    let grammar = GrammarName::new(corpus.grammar);
    let Some(mut oracle) = syntax.parser(&grammar) else {
        return false;
    };
    let Some(fresh_highlighter) = shipped_highlighter(syntax, corpus) else {
        return false;
    };
    // Refreshes the session, and holds what it then delivers to a fresh
    // parse and a fresh highlight, and a second refresh to nothing.
    let mut settled = |driven: &Driven<S>| {
        driven.session.refresh_once(syntax);
        let snapshot = driven.text.snapshot();
        let Some(parsed) = driven.session.parsed() else {
            return false;
        };
        let fresh = syntax.parse(&mut oracle, &snapshot, None);
        let drawn = driven.session.highlights(&snapshot).map(|highlights| {
            let mut spans: Vec<HighlightSpan> = Vec::new();
            highlights.spans(syntax, 0..snapshot.len(), &mut spans);
            spans
        });
        let fresh_drawn =
            crate::highlight::fresh(syntax, &fresh_highlighter, None, &mut oracle, &snapshot);
        let before = driven.delivered.load(Ordering::Relaxed);
        let again = driven.session.refresh_once(syntax);
        parsed.revision == snapshot.revision()
            && syntax.nodes(&parsed.tree) == syntax.nodes(&fresh)
            && drawn == Some(fresh_drawn)
            && again == Outcome::UpToDate
            && driven.delivered.load(Ordering::Relaxed) == before
    };
    let driven =
        |text: &str| Driven::new(syntax, &grammar, text, shipped_highlighter(syntax, corpus));
    let named = corpus.texts.iter().all(|text| {
        NAMED_CASES.iter().all(|&case| {
            driven(text).is_some_and(|driven| driven.case(syntax, case, corpus) && settled(&driven))
        })
    });
    let mut random = Random(0xc0ff_ee00_c0ff_ee00);
    let swept = corpus.texts.iter().all(|text| {
        (0..CONVERGING_SEQUENCES).all(|_| {
            let Some(driven) = driven(text) else {
                return false;
            };
            let edited = (0..STEPS).all(|_| {
                let changes = random.changes(&driven.text.snapshot(), corpus.pieces);
                driven.edit(syntax, &changes)
            });
            edited && settled(&driven) && driven.undo(syntax) && settled(&driven)
        })
    });
    named && swept
}

/// A syntax that forwards everything to the syntax it wraps, recording
/// whether each parse was handed an old tree: how [`REPARSE_POLICY`] sees
/// what the core's rounds hand the parser.
struct Watched<S: Syntax> {
    /// The syntax watched.
    syntax: S,
    /// Whether each parse was handed an old tree, in order.
    olds: Mutex<Vec<bool>>,
}

impl<S: Syntax> Watched<S> {
    /// Whether each parse was handed an old tree, in order.
    fn olds(&self) -> Vec<bool> {
        self.olds
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }
}

impl<S: Syntax> Syntax for Watched<S> {
    type Parser = S::Parser;
    type Tree = S::Tree;
    type Query = S::Query;

    fn grammars(&self) -> Vec<GrammarName> {
        self.syntax.grammars()
    }
    fn parser(&self, grammar: &GrammarName) -> Option<S::Parser> {
        self.syntax.parser(grammar)
    }
    fn reparse_policy(&self, grammar: &GrammarName) -> Option<ReparsePolicy> {
        self.syntax.reparse_policy(grammar)
    }
    fn register(&self, source: &GrammarSource) -> Result<GrammarName, RegistrationRefusal> {
        self.syntax.register(source)
    }
    fn parse(&self, parser: &mut S::Parser, text: &Snapshot, old: Option<&S::Tree>) -> S::Tree {
        self.olds
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(old.is_some());
        self.syntax.parse(parser, text, old)
    }
    fn edit(&self, tree: &mut S::Tree, edit: &InputEdit) {
        self.syntax.edit(tree, edit);
    }
    fn compile(&self, grammar: &GrammarName, source: &str) -> Result<S::Query, QueryError> {
        self.syntax.compile(grammar, source)
    }
    fn shipped_query(&self, grammar: &GrammarName, kind: QueryKind) -> Option<String> {
        self.syntax.shipped_query(grammar, kind)
    }
    fn capture_names(&self, query: &S::Query) -> Vec<String> {
        self.syntax.capture_names(query)
    }
    fn captures(
        &self,
        query: &S::Query,
        tree: &S::Tree,
        text: &Snapshot,
        range: Range<usize>,
    ) -> Vec<Capture> {
        self.syntax.captures(query, tree, text, range)
    }
    fn matches(
        &self,
        query: &S::Query,
        tree: &S::Tree,
        text: &Snapshot,
        range: Range<usize>,
    ) -> Vec<Match> {
        self.syntax.matches(query, tree, text, range)
    }
    fn pattern_settings(&self, query: &S::Query, pattern: usize) -> Vec<Setting> {
        self.syntax.pattern_settings(query, pattern)
    }
    fn parse_in(
        &self,
        parser: &mut S::Parser,
        text: &Snapshot,
        ranges: &[Range<usize>],
    ) -> S::Tree {
        self.syntax.parse_in(parser, text, ranges)
    }
    fn nodes(&self, tree: &S::Tree) -> Vec<Node> {
        self.syntax.nodes(tree)
    }
    fn has_errors(&self, tree: &S::Tree) -> bool {
        self.syntax.has_errors(tree)
    }
}

/// [`REPARSE_POLICY`].
fn reparse_policy<S: Syntax + Clone>(syntax: &S, corpus: &Corpus) -> bool {
    let grammar = GrammarName::new(corpus.grammar);
    let other = GrammarName::new(format!("{grammar}-that-is-not-listed"));
    let declared = syntax.reparse_policy(&grammar) == Some(corpus.policy)
        && syntax.reparse_policy(&other).is_none();
    let watched = Watched {
        syntax: syntax.clone(),
        olds: Mutex::new(Vec::new()),
    };
    // Over the named cases, whether any round was handed an old tree, and
    // whether any was after an edit.
    let (mut handed, mut after_an_edit) = (false, false);
    let rounds = corpus.texts.iter().all(|text| {
        NAMED_CASES.iter().all(|&case| {
            let Some(driven) = Driven::new(&watched, &grammar, text, None) else {
                return false;
            };
            let first = watched.olds().len();
            let applied = driven.case(&watched, case, corpus);
            let olds = watched.olds();
            handed |= olds.iter().any(|old| *old);
            after_an_edit |= olds[first..].iter().any(|old| *old);
            applied
        })
    });
    let honoured = match corpus.policy {
        ReparsePolicy::Whole => !handed,
        ReparsePolicy::Incremental => after_an_edit,
    };
    declared && rounds && honoured
}

/// [`QUERY_REFUSED`].
fn query_refused<S: Syntax>(syntax: &S, grammar: &GrammarName, corpus: &Corpus) -> bool {
    let refused = |source: &str, kind: QueryErrorKind| {
        syntax
            .compile(grammar, source)
            .is_err_and(|error| error.kind == kind)
    };
    !corpus.bad_queries.is_empty()
        && corpus
            .bad_queries
            .iter()
            .all(|&(source, kind)| refused(source, kind))
        && refused(corpus.unknown_kind_query, QueryErrorKind::NodeType)
}

/// [`QUERY_NAMES`].
fn query_names<S: Syntax>(syntax: &S, grammar: &GrammarName, corpus: &Corpus) -> bool {
    syntax
        .compile(grammar, corpus.query)
        .is_ok_and(|query| syntax.capture_names(&query) == corpus.query_names)
}

/// [`RANGE`]: from every text, the ranges of every row, empty ranges at
/// every row's ends, the empty ranges at the text's ends, and random
/// ranges; and at least one text whose whole answer is not empty.
fn range<S: Syntax>(syntax: &S, parser: &mut S::Parser, corpus: &Corpus) -> bool {
    let grammar = GrammarName::new(corpus.grammar);
    let Ok(query) = syntax.compile(&grammar, corpus.query) else {
        return false;
    };
    let mut random = Random(0x0a0b_0c0d_0e0f_1011);
    let mut answered = false;
    let every = corpus.texts.iter().all(|text| {
        let snapshot = snapshot_of(text);
        let tree = syntax.parse(parser, &snapshot, None);
        let Ok(whole) = captures_in(syntax, &query, &tree, &snapshot, 0..snapshot.len()) else {
            return false;
        };
        answered |= !whole.is_empty();
        let mut ranges = vec![0..0, snapshot.len()..snapshot.len()];
        for row in 0..snapshot.row_count() {
            if let Some(range) = snapshot.row_range(row) {
                ranges.push(range.start..range.start);
                ranges.push(range.end..range.end);
                ranges.push(range);
            }
        }
        for _ in 0..8 {
            let a = boundary(&snapshot, random.below(snapshot.len() + 1));
            let b = boundary(&snapshot, random.below(snapshot.len() + 1));
            ranges.push(a.min(b)..a.max(b));
        }
        ranges.into_iter().all(|range| {
            let expected: Vec<Capture> = whole
                .iter()
                .filter(|capture| overlaps(capture.range(), range.clone()))
                .copied()
                .collect();
            captures_in(syntax, &query, &tree, &snapshot, range) == Ok(expected)
        })
    });
    every && answered
}

/// [`ORDER`].
fn order<S: Syntax>(syntax: &S, parser: &mut S::Parser, corpus: &Corpus) -> bool {
    let grammar = GrammarName::new(corpus.grammar);
    let Ok(query) = syntax.compile(&grammar, corpus.query) else {
        return false;
    };
    let names = syntax.capture_names(&query).len();
    corpus.texts.iter().all(|text| {
        let snapshot = snapshot_of(text);
        let tree = syntax.parse(parser, &snapshot, None);
        let nodes = syntax.nodes(&tree);
        let Ok(answer) = captures_in(syntax, &query, &tree, &snapshot, 0..snapshot.len()) else {
            return false;
        };
        let mut sorted = answer.clone();
        crate::query::sort(&mut sorted);
        sorted == answer
            && answer.iter().all(|capture| {
                usize::try_from(capture.capture).is_ok_and(|index| index < names)
                    && nodes
                        .iter()
                        .any(|node| node.start == capture.start && node.end == capture.end)
            })
    })
}

/// A small generator of numbers from a seed: a linear congruential
/// generator, the same numbers on every machine.
struct Random(u64);

impl Random {
    /// The next number.
    fn next(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        self.0 >> 33
    }

    /// A number below `bound`, which is not 0.
    fn below(&mut self, bound: usize) -> usize {
        usize::try_from(self.next()).unwrap_or(0) % bound.max(1)
    }

    /// One to three changes of `text`, in order and apart: each a range of
    /// up to six bytes on positions, deleted or replaced by one of
    /// `pieces`.
    fn changes(
        &mut self,
        text: &Snapshot,
        pieces: &[&'static str],
    ) -> Vec<(Range<usize>, &'static str)> {
        let count = 1 + self.below(3);
        let mut starts: Vec<usize> = (0..count)
            .map(|_| boundary(text, self.below(text.len() + 1)))
            .collect();
        starts.sort_unstable();
        starts.dedup();
        let mut changes = Vec::with_capacity(starts.len());
        for (index, &start) in starts.iter().enumerate() {
            let limit = starts.get(index + 1).copied().unwrap_or(text.len());
            let end = boundary(text, (start + self.below(7)).min(limit)).max(start);
            let insert = if self.below(3) == 0 {
                ""
            } else {
                pieces[self.below(pieces.len())]
            };
            changes.push((start..end, insert));
        }
        changes
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake::{
        GRAMMAR, PARENS_CORPUS, PARENS_HIGHLIGHTS, Parens, ParensParser, ParensQuery, ParensTree,
    };

    #[test]
    fn the_properties_are_seventeen_and_each_is_named_once() {
        let mut names = PROPERTIES.to_vec();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), 17);
    }

    /// One rule a broken syntax breaks; everything else it answers as the
    /// fake does.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum Flaw {
        /// None: it is the fake.
        None,
        /// A parser opens for any grammar.
        AnyGrammar,
        /// The root stops a byte short of the text's end.
        ShortRoot,
        /// Every second parse loses its last node.
        Flaky,
        /// A reparse handed an old tree answers the old tree.
        StaleReuse,
        /// A reparse handed an old tree, whose tree has an error, answers
        /// the tree of the text with one more atom: it recovers otherwise,
        /// with a tree that runs past the text.
        RecoversOutsideText,
        /// A reparse handed an old tree, whose tree has an error, answers
        /// the fresh tree with its error and missing nodes dropped: whole,
        /// and not the fresh tree, as a real library may recover.
        RecoversOtherwiseWhole,
        /// A reparse handed an old tree, of a text with no error, answers
        /// the fresh tree with its last atom's kind renamed.
        ReparsesOtherwise,
        /// As [`Flaw::ReparsesOtherwise`], and it declares its grammar
        /// reparsed whole.
        ReparsesOtherwiseDeclaredWhole,
        /// It recovers as [`Flaw::RecoversOtherwiseWhole`], and its parser
        /// keeps the last tree it made from an old tree and answers it for
        /// a whole parse of the same text.
        StaleWhole,
        /// It declares `parens` reparsed whole.
        PolicyOtherwise,
        /// It declares a policy for a grammar it does not have.
        PolicyForAny,
        /// No tree has errors.
        NeverErrors,
        /// Every tree has errors.
        AlwaysErrors,
        /// Every query compiles.
        AcceptsAll,
        /// The capture names come back reversed.
        NamesReversed,
        /// A capture that starts where the asked range starts is dropped.
        DropsAtEdge,
        /// A capture's index is past the query's names.
        BadIndex,
        /// The highlights query it ships does not compile.
        BrokenShipped,
        /// It ships a highlights query for a grammar it does not have.
        ShipsForAny,
        /// A reparse handed an old tree answers the fresh tree, but marked,
        /// and a marked tree's captures leave out the first.
        StaleCaptures,
        /// A match's captures come without their named children.
        MatchesWithoutChildren,
        /// A pattern's last setting is dropped.
        DropsSetting,
        /// A parse in ranges reads the whole text.
        ParsesOutsideRanges,
        /// It ships its highlights query as a query of every kind.
        ShipsEveryKind,
        /// It ships no query of any kind, as a grammar registered at run
        /// time does.
        ShipsNone,
        /// As [`Flaw::ReparsesOtherwise`], and it ships no query of any
        /// kind.
        ReparsesOtherwiseShipsNone,
    }

    /// The fake with one flaw.
    struct Broken {
        flaw: Flaw,
        parses: AtomicUsize,
    }

    impl Broken {
        fn new(flaw: Flaw) -> Self {
            Self {
                flaw,
                parses: AtomicUsize::new(0),
            }
        }
    }

    impl Clone for Broken {
        fn clone(&self) -> Self {
            Self::new(self.flaw)
        }
    }

    /// The broken syntax's parser: the fake's, and the last tree it made
    /// from an old tree, with the text it is of.
    #[derive(Default)]
    struct BrokenParser {
        parser: ParensParser,
        remembered: Option<(String, ParensTree)>,
    }

    /// `tree`, the tree of `text`, marked as made from an old tree told
    /// `old`'s edits: its nodes are unchanged.
    fn marked(mut tree: ParensTree, old: &ParensTree) -> ParensTree {
        for edit in old.edits() {
            Parens.edit(&mut tree, edit);
        }
        tree
    }

    /// The fake's tree of `text` with its error and missing nodes dropped,
    /// when it has any.
    fn recovered_whole(tree: ParensTree) -> ParensTree {
        if !Parens.has_errors(&tree) {
            return tree;
        }
        let mut nodes = Parens.nodes(&tree);
        nodes.retain(|node| !node.error && !node.missing);
        ParensTree::of_nodes(nodes)
    }

    impl Syntax for Broken {
        type Parser = BrokenParser;
        type Tree = ParensTree;
        type Query = ParensQuery;

        fn grammars(&self) -> Vec<GrammarName> {
            Parens.grammars()
        }

        fn parser(&self, grammar: &GrammarName) -> Option<BrokenParser> {
            if self.flaw == Flaw::AnyGrammar {
                return Some(BrokenParser::default());
            }
            Parens.parser(grammar).map(|parser| BrokenParser {
                parser,
                remembered: None,
            })
        }

        fn register(&self, _: &GrammarSource) -> Result<GrammarName, RegistrationRefusal> {
            Err(RegistrationRefusal::Unsupported)
        }

        fn reparse_policy(&self, grammar: &GrammarName) -> Option<ReparsePolicy> {
            match self.flaw {
                Flaw::PolicyOtherwise | Flaw::ReparsesOtherwiseDeclaredWhole => {
                    Parens.reparse_policy(grammar).map(|_| ReparsePolicy::Whole)
                }
                Flaw::PolicyForAny => Some(ReparsePolicy::Incremental),
                _ => Parens.reparse_policy(grammar),
            }
        }

        fn parse(
            &self,
            parser: &mut BrokenParser,
            text: &Snapshot,
            old: Option<&ParensTree>,
        ) -> ParensTree {
            let fresh = Parens.parse(&mut parser.parser, text, old);
            let Some(old) = old else {
                if self.flaw == Flaw::StaleWhole
                    && let Some((remembered_text, tree)) = &parser.remembered
                    && *remembered_text == text.to_string()
                {
                    return tree.clone();
                }
                return fresh;
            };
            match self.flaw {
                Flaw::StaleReuse => old.clone(),
                // The fake's tree, with the old tree's edits as the mark:
                // its nodes are a fresh parse's.
                Flaw::StaleCaptures => marked(fresh, old),
                Flaw::RecoversOutsideText if Parens.has_errors(&fresh) => {
                    let other = Text::from(format!("{text} x").as_str()).snapshot();
                    Parens.parse(&mut parser.parser, &other, None)
                }
                Flaw::RecoversOtherwiseWhole => recovered_whole(fresh),
                Flaw::StaleWhole => {
                    let tree = recovered_whole(fresh);
                    parser.remembered = Some((text.to_string(), tree.clone()));
                    tree
                }
                Flaw::ReparsesOtherwise
                | Flaw::ReparsesOtherwiseDeclaredWhole
                | Flaw::ReparsesOtherwiseShipsNone
                    if !Parens.has_errors(&fresh) =>
                {
                    let mut nodes = Parens.nodes(&fresh);
                    if let Some(atom) = nodes.iter_mut().rev().find(|node| node.kind == "atom") {
                        atom.kind = "word".to_owned();
                    }
                    ParensTree::of_nodes(nodes)
                }
                _ => fresh,
            }
        }

        fn edit(&self, tree: &mut ParensTree, edit: &InputEdit) {
            Parens.edit(tree, edit);
        }

        fn compile(&self, grammar: &GrammarName, source: &str) -> Result<ParensQuery, QueryError> {
            match Parens.compile(grammar, source) {
                Err(_) if self.flaw == Flaw::AcceptsAll => Parens.compile(grammar, ""),
                compiled => compiled,
            }
        }

        fn shipped_query(&self, grammar: &GrammarName, kind: QueryKind) -> Option<String> {
            match self.flaw {
                Flaw::BrokenShipped => Some("((".to_owned()),
                Flaw::ShipsEveryKind => Parens.shipped_query(grammar, QueryKind::Highlights),
                Flaw::ShipsForAny => Parens.shipped_query(&GrammarName::new(GRAMMAR), kind),
                Flaw::ShipsNone | Flaw::ReparsesOtherwiseShipsNone => None,
                _ => Parens.shipped_query(grammar, kind),
            }
        }

        fn capture_names(&self, query: &ParensQuery) -> Vec<String> {
            let mut names = Parens.capture_names(query);
            if self.flaw == Flaw::NamesReversed {
                names.reverse();
            }
            names
        }

        fn captures(
            &self,
            query: &ParensQuery,
            tree: &ParensTree,
            text: &Snapshot,
            range: Range<usize>,
        ) -> Vec<Capture> {
            let mut captures = Parens.captures(query, tree, text, range.clone());
            match self.flaw {
                Flaw::DropsAtEdge if range.start > 0 => {
                    captures.retain(|capture| capture.start != range.start);
                }
                Flaw::BadIndex => {
                    for capture in &mut captures {
                        capture.capture += 100;
                    }
                }
                Flaw::StaleCaptures if !tree.edits().is_empty() && !captures.is_empty() => {
                    captures.remove(0);
                }
                _ => {}
            }
            captures
        }

        fn matches(
            &self,
            query: &ParensQuery,
            tree: &ParensTree,
            text: &Snapshot,
            range: Range<usize>,
        ) -> Vec<Match> {
            // The fake's, cut to its own captures, so a flaw of those is a
            // flaw of these too.
            let own = self.captures(query, tree, text, range.clone());
            let mut matches = Parens.matches(query, tree, text, range);
            for found in &mut matches {
                for capture in &mut found.captures {
                    if self.flaw == Flaw::BadIndex {
                        capture.capture += 100;
                    }
                    if self.flaw == Flaw::MatchesWithoutChildren {
                        capture.named_children.clear();
                    }
                }
            }
            matches.retain(|found| {
                crate::query::flatten(std::slice::from_ref(found))
                    .iter()
                    .all(|capture| own.contains(capture))
            });
            matches
        }

        fn pattern_settings(&self, query: &ParensQuery, pattern: usize) -> Vec<Setting> {
            let mut settings = Parens.pattern_settings(query, pattern);
            if self.flaw == Flaw::DropsSetting {
                settings.pop();
            }
            settings
        }

        fn parse_in(
            &self,
            parser: &mut BrokenParser,
            text: &Snapshot,
            ranges: &[Range<usize>],
        ) -> ParensTree {
            if self.flaw == Flaw::ParsesOutsideRanges {
                return Parens.parse(&mut parser.parser, text, None);
            }
            Parens.parse_in(&mut parser.parser, text, ranges)
        }

        fn nodes(&self, tree: &ParensTree) -> Vec<Node> {
            let mut nodes = Parens.nodes(tree);
            match self.flaw {
                Flaw::ShortRoot => {
                    if let Some(root) = nodes.first_mut() {
                        root.end = root.end.saturating_sub(1);
                    }
                }
                Flaw::Flaky if self.parses.fetch_add(1, Ordering::Relaxed) % 2 == 1 => {
                    nodes.pop();
                }
                _ => {}
            }
            nodes
        }

        fn has_errors(&self, tree: &ParensTree) -> bool {
            match self.flaw {
                Flaw::NeverErrors => false,
                Flaw::AlwaysErrors => true,
                _ => Parens.has_errors(tree),
            }
        }
    }

    /// The properties `flaw` fails.
    fn failed(flaw: Flaw) -> Vec<&'static str> {
        check(&Broken::new(flaw), &PARENS_CORPUS)
    }

    #[test]
    fn the_fake_behind_a_wrapper_with_no_flaw_keeps_the_contract() {
        assert_eq!(failed(Flaw::None), [""; 0]);
    }

    #[test]
    fn a_syntax_that_opens_a_parser_for_any_grammar_is_reported() {
        assert_eq!(failed(Flaw::AnyGrammar), [GRAMMARS]);
    }

    #[test]
    fn a_syntax_whose_root_stops_short_of_the_end_is_reported() {
        // Every tree it makes is short, a round's too. The fake's trees
        // carry no mark of a reparse once parsed, and a mark would set the
        // round's trees apart from the oracle's, so the flaw is not
        // narrowed to whole parses: both properties of wholeness catch it.
        assert_eq!(failed(Flaw::ShortRoot), [WHOLE, DELIVERED_WHOLE]);
    }

    #[test]
    fn a_syntax_whose_parses_of_one_text_differ_is_reported() {
        // Its nodes drop every second read, so every property that reads
        // nodes twice and compares them fails; the check runs in one order,
        // so the list is the same each time.
        assert_eq!(
            failed(Flaw::Flaky),
            [
                DETERMINISTIC,
                ERRORS,
                GRAMMAR_QUALITY,
                ORDER,
                IN_RANGES,
                MATCHES,
                DELIVERED_WHOLE,
                CONVERGES
            ]
        );
    }

    #[test]
    fn a_syntax_that_reuses_a_stale_tree_is_reported() {
        assert_eq!(
            failed(Flaw::StaleReuse),
            [GRAMMAR_QUALITY, HIGHLIGHTS_AFTER_EDITS, DELIVERED_WHOLE]
        );
    }

    #[test]
    fn a_syntax_whose_incremental_reparse_of_an_error_free_text_differs_is_reported() {
        assert_eq!(
            failed(Flaw::ReparsesOtherwise),
            [GRAMMAR_QUALITY, HIGHLIGHTS_AFTER_EDITS]
        );
    }

    #[test]
    fn a_whole_grammar_whose_incremental_reparses_differ_keeps_the_contract() {
        let corpus = Corpus {
            policy: ReparsePolicy::Whole,
            ..PARENS_CORPUS
        };
        assert_eq!(
            check(&Broken::new(Flaw::ReparsesOtherwiseDeclaredWhole), &corpus),
            [""; 0]
        );
    }

    #[test]
    fn a_syntax_that_recovers_with_a_tree_past_the_text_is_reported() {
        assert_eq!(failed(Flaw::RecoversOutsideText), [DELIVERED_WHOLE]);
    }

    #[test]
    fn a_syntax_that_recovers_otherwise_with_a_whole_tree_keeps_the_contract() {
        assert_eq!(failed(Flaw::RecoversOtherwiseWhole), [""; 0]);
    }

    #[test]
    fn a_syntax_whose_whole_parse_answers_a_remembered_incremental_tree_does_not_converge() {
        assert_eq!(failed(Flaw::StaleWhole), [CONVERGES]);
    }

    #[test]
    fn a_syntax_that_declares_another_policy_than_its_corpus_is_reported() {
        assert_eq!(failed(Flaw::PolicyOtherwise), [REPARSE_POLICY]);
    }

    #[test]
    fn a_syntax_that_declares_a_policy_for_a_grammar_it_lacks_is_reported() {
        assert_eq!(failed(Flaw::PolicyForAny), [REPARSE_POLICY]);
    }

    #[test]
    fn a_syntax_that_says_no_tree_has_errors_is_reported() {
        assert_eq!(failed(Flaw::NeverErrors), [ERRORS]);
    }

    #[test]
    fn a_syntax_that_says_every_tree_has_errors_is_reported_and_compares_no_reparse() {
        assert_eq!(
            failed(Flaw::AlwaysErrors),
            [ERRORS, GRAMMAR_QUALITY, HIGHLIGHTS_AFTER_EDITS]
        );
    }

    #[test]
    fn a_syntax_that_accepts_every_query_is_reported() {
        assert_eq!(failed(Flaw::AcceptsAll), [QUERY_REFUSED]);
    }

    #[test]
    fn a_syntax_whose_capture_names_are_out_of_order_is_reported() {
        assert_eq!(failed(Flaw::NamesReversed), [QUERY_NAMES]);
    }

    #[test]
    fn a_syntax_that_drops_a_capture_at_a_ranges_edge_is_reported() {
        assert_eq!(failed(Flaw::DropsAtEdge), [RANGE]);
    }

    #[test]
    fn a_syntax_that_answers_a_capture_the_query_has_not_is_reported() {
        assert_eq!(failed(Flaw::BadIndex), [ORDER]);
    }

    #[test]
    fn a_syntax_whose_shipped_highlights_query_does_not_compile_is_reported() {
        assert_eq!(
            failed(Flaw::BrokenShipped),
            [SHIPPED, HIGHLIGHTS_AFTER_EDITS, CONVERGES]
        );
    }

    #[test]
    fn a_syntax_that_ships_a_query_for_a_grammar_it_lacks_is_reported() {
        assert_eq!(failed(Flaw::ShipsForAny), [SHIPPED]);
    }

    #[test]
    fn a_syntax_whose_captures_of_a_reparsed_tree_differ_from_a_fresh_ones_is_reported() {
        // A refresh finds the marked tree's nodes equal to a fresh parse's
        // and keeps it, so what it draws stays short of a fresh highlight:
        // the check of the delivered highlights is what catches it.
        assert_eq!(
            failed(Flaw::StaleCaptures),
            [HIGHLIGHTS_AFTER_EDITS, CONVERGES]
        );
    }

    #[test]
    fn a_syntax_whose_matches_lack_their_named_children_is_reported() {
        assert_eq!(failed(Flaw::MatchesWithoutChildren), [MATCHES]);
    }

    #[test]
    fn a_syntax_that_drops_a_setting_is_reported() {
        assert_eq!(failed(Flaw::DropsSetting), [SETTINGS]);
    }

    #[test]
    fn a_syntax_that_parses_outside_its_ranges_is_reported() {
        assert_eq!(failed(Flaw::ParsesOutsideRanges), [IN_RANGES]);
    }

    #[test]
    fn a_syntax_that_ships_a_kind_its_corpus_does_not_list_is_reported() {
        assert_eq!(failed(Flaw::ShipsEveryKind), [SHIPPED]);
    }

    /// The fake's corpus for a grammar that ships no query, with `highlights`
    /// as the corpus's own highlights query.
    fn shipping_none(highlights: Option<&'static str>) -> Corpus {
        Corpus {
            shipped: &[],
            highlights,
            ..PARENS_CORPUS
        }
    }

    #[test]
    fn a_grammar_that_ships_no_query_keeps_the_contract_with_the_corpus_highlights() {
        assert_eq!(
            check(
                &Broken::new(Flaw::ShipsNone),
                &shipping_none(Some(PARENS_HIGHLIGHTS))
            ),
            [""; 0]
        );
    }

    #[test]
    fn a_grammar_that_ships_no_highlights_and_a_corpus_with_none_fails_highlights_after_edits() {
        // Both properties that draw highlights find nothing to draw with.
        assert_eq!(
            check(&Broken::new(Flaw::ShipsNone), &shipping_none(None)),
            [HIGHLIGHTS_AFTER_EDITS, CONVERGES]
        );
    }

    #[test]
    fn a_reparse_that_draws_other_highlights_is_reported_with_the_corpus_highlights() {
        assert_eq!(
            check(
                &Broken::new(Flaw::ReparsesOtherwiseShipsNone),
                &shipping_none(Some(PARENS_HIGHLIGHTS))
            ),
            [GRAMMAR_QUALITY, HIGHLIGHTS_AFTER_EDITS]
        );
    }

    #[test]
    fn a_syntax_whose_table_loses_a_kind_its_corpus_lists_is_reported() {
        let corpus = Corpus {
            shipped: &[QueryKind::Highlights, QueryKind::Indents],
            ..PARENS_CORPUS
        };
        assert_eq!(check(&Parens, &corpus), [SHIPPED]);
    }

    #[test]
    fn a_corpus_whose_grammar_the_syntax_lacks_fails_every_property() {
        let corpus = Corpus {
            grammar: "rust",
            ..PARENS_CORPUS
        };
        // Every query of a grammar the fake lacks is refused, as
        // `Language`, so no refusal has the kind the corpus names.
        assert_eq!(check(&Parens, &corpus), PROPERTIES);
    }

    #[test]
    fn a_whole_tree_has_one_root_over_the_text_and_children_in_order_within_their_parents() {
        let text = snapshot_of("(a b)");
        let tree = Parens.parse(&mut ParensParser, &text, None);
        let nodes = Parens.nodes(&tree);
        assert!(is_whole(&nodes, &text));

        let mut swapped = nodes.clone();
        swapped.swap(3, 4);
        assert!(!is_whole(&swapped, &text));

        let mut orphan = nodes.clone();
        orphan[2].depth = 3;
        assert!(!is_whole(&orphan, &text));

        let mut second_root = nodes.clone();
        second_root[1].depth = 0;
        assert!(!is_whole(&second_root, &text));

        let mut outside = nodes;
        outside[3].end = 9;
        assert!(!is_whole(&outside, &text));
    }
}
