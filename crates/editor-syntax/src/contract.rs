//! The contract of the syntax port: the rules every [`Syntax`] keeps, as a
//! check that runs one.
//!
//! [`check`] asks the syntax it is given about a [`Corpus`], what is
//! language-specific (a grammar, texts of it, a query), and returns the
//! names of the properties that fail. The fake passes it in this crate's
//! tests, against [`crate::fake::PARENS_CORPUS`], and each real adapter
//! runs it in its own, against a corpus for each grammar it has.
//!
//! The edits of [`INCREMENTAL`] go through a real [`Text`], so the patch a
//! tree is told is the edit log's own ([`Text::changes_since`]), with its
//! edits in the form an incremental parser takes
//! ([`editor_text::Edit::input_edit`]): the property holds the
//! implementation and the log to each other. Its sweep of random edits is
//! from a fixed seed, with a small generator here and not a property-test
//! library, since the contract is published code.

use std::cell::Cell;
use std::ops::Range;
use std::sync::Arc;

use editor_text::{ChangeSet, Origin, Revision, Snapshot, Text, Transaction};

use crate::highlight::Highlighter;
use crate::port::{Capture, GrammarName, Node, QueryErrorKind, QueryKind, Syntax};
use crate::query::{captures_in, overlaps};
use crate::session::reparse;

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
/// After edits, the tree told the log's patch and reparsed with it, as the
/// core reparses ([`crate::session::reparse`]), equals a fresh parse of the
/// same snapshot, for every text, with errors or without.
///
/// The core drops an incremental parse whose tree has an error or a missing
/// node and parses the text whole, since how a library recovers from an
/// error can depend on what it reuses (tree-sitter's did, on 11 of some
/// 6,700 reparses of random edits of Rust, seen on 2026-11-16). So what
/// this holds the implementation to is that an incremental parse with no
/// error equals a fresh one, and [`ERRORS`] that it says truly when a tree
/// has one; and at least one incremental parse must be kept, so the
/// property is never held only by whole parses.
pub const INCREMENTAL: &str =
    "after an edit, the incrementally reparsed tree equals a fresh full parse of the same snapshot";
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

/// The grammar is published with a highlights query
/// ([`Syntax::shipped_query`]) that compiles for it, and a grammar that is
/// not listed ships none.
pub const SHIPPED: &str =
    "the corpus's grammar ships a highlights query that compiles, and one not listed ships none";

/// Over the same edits as [`INCREMENTAL`], the cases and the sweep, the
/// spans the grammar's shipped highlights query draws
/// ([`crate::highlight::spans`], each capture in a face of its own) on the
/// tree reparsed as the core reparses equal those on a fresh parse of the
/// same snapshot; and at least one incremental parse is kept, so the
/// property is never held only by whole parses.
pub const HIGHLIGHTS_AFTER_EDITS: &str =
    "after an edit, the shipped highlights of the reparsed tree equal those of a fresh full parse";

/// Every property, by name.
pub const PROPERTIES: [&str; 11] = [
    GRAMMARS,
    WHOLE,
    DETERMINISTIC,
    ERRORS,
    INCREMENTAL,
    QUERY_REFUSED,
    QUERY_NAMES,
    RANGE,
    ORDER,
    SHIPPED,
    HIGHLIGHTS_AFTER_EDITS,
];

/// How many random edit sequences the sweep runs from each text.
const SEQUENCES: usize = 12;
/// How many reparses each sequence has.
const STEPS: usize = 8;

/// Holds `syntax` to the contract over `corpus`, and returns the names of
/// the properties that fail: none when it keeps them all. A grammar that
/// opens no parser fails every property that parses.
pub fn check<S: Syntax>(syntax: &S, corpus: &Corpus) -> Vec<&'static str> {
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
        (INCREMENTAL, parses(incremental)),
        (QUERY_REFUSED, query_refused(syntax, &grammar, corpus)),
        (QUERY_NAMES, query_names(syntax, &grammar, corpus)),
        (RANGE, parses(range)),
        (ORDER, parses(order)),
        (SHIPPED, shipped(syntax, &grammar)),
        (HIGHLIGHTS_AFTER_EDITS, parses(highlights_after_edits)),
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
fn shipped<S: Syntax>(syntax: &S, grammar: &GrammarName) -> bool {
    let other = GrammarName::new(format!("{grammar}-that-is-not-listed"));
    syntax
        .shipped_query(grammar, QueryKind::Highlights)
        .is_some_and(|source| syntax.compile(grammar, &source).is_ok())
        && syntax
            .shipped_query(&other, QueryKind::Highlights)
            .is_none()
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
/// log's patches.
struct Run<'a, S: Syntax> {
    /// The implementation.
    syntax: &'a S,
    /// The text.
    text: Text,
    /// The tree of the text at `revision`.
    tree: S::Tree,
    /// The revision the tree is of.
    revision: Revision,
    /// How many incremental parses were kept and compared with a fresh
    /// parse, across every run of one check.
    kept: &'a Cell<usize>,
}

impl<'a, S: Syntax> Run<'a, S> {
    /// A run from `text`, parsed fresh, that counts the incremental parses
    /// it keeps in `kept`.
    fn new(syntax: &'a S, parser: &mut S::Parser, text: &str, kept: &'a Cell<usize>) -> Self {
        let text = Text::from(text);
        let snapshot = text.snapshot();
        let tree = syntax.parse(parser, &snapshot, None);
        Self {
            syntax,
            text,
            tree,
            revision: snapshot.revision(),
            kept,
        }
    }

    /// The text as it is now.
    fn snapshot(&self) -> Snapshot {
        self.text.snapshot()
    }

    /// Applies one transaction: each change a range of the text as it is,
    /// in order and not overlapping, and what replaces it. False when the
    /// text refused it.
    fn apply(&mut self, changes: &[(Range<usize>, &str)]) -> bool {
        let len = self.text.current().len();
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
        self.text
            .apply(&Transaction::new(set), Origin::default())
            .is_ok()
    }

    /// Applies the inverse of every transaction applied so far, as one
    /// transaction, which puts the text back as it was made. False when the
    /// text refused it.
    fn undo(&mut self) -> bool {
        let last = self.text.current().revision();
        last == Revision::new(0)
            || self
                .text
                .apply_inverse(Revision::new(1), last, Origin::default())
                .is_ok()
    }

    /// Tells the tree the log's patch since its revision, reparses with it
    /// as the core reparses ([`crate::session::reparse`]), keeps the result,
    /// and returns whether `same` holds of it and a fresh parse of the
    /// snapshot.
    fn reparse(&mut self, parser: &mut S::Parser, same: Same<'_, S>) -> bool {
        let Ok(patch) = self.text.changes_since(self.revision) else {
            return false;
        };
        let mut edited = self.tree.clone();
        for edit in &patch.edits {
            self.syntax.edit(&mut edited, &edit.input_edit());
        }
        let snapshot = self.snapshot();
        let reparsed = reparse(self.syntax, parser, &snapshot, Some(&edited));
        if reparsed.incremental {
            self.kept.set(self.kept.get() + 1);
        }
        let fresh = self.syntax.parse(parser, &snapshot, None);
        let holds = same(&reparsed.tree, &fresh, &snapshot);
        self.tree = reparsed.tree;
        self.revision = snapshot.revision();
        holds
    }
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

/// A named case of [`INCREMENTAL`]: the transactions applied, each
/// computed from the text as it is, before one reparse.
type NamedCase = fn(&Snapshot, &Corpus) -> Vec<Vec<(Range<usize>, String)>>;

/// The named cases of [`INCREMENTAL`].
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

/// What a reparse is held to: whether a tree reparsed as the core reparses
/// and a fresh parse, both of the snapshot, agree.
type Same<'a, S> = &'a dyn Fn(&<S as Syntax>::Tree, &<S as Syntax>::Tree, &Snapshot) -> bool;

/// [`INCREMENTAL`]: the reparsed tree's nodes are a fresh parse's.
fn incremental<S: Syntax>(syntax: &S, parser: &mut S::Parser, corpus: &Corpus) -> bool {
    let same = |reparsed: &S::Tree, fresh: &S::Tree, _: &Snapshot| {
        syntax.nodes(reparsed) == syntax.nodes(fresh)
    };
    after_edits(syntax, parser, corpus, &same)
}

/// [`HIGHLIGHTS_AFTER_EDITS`]: the shipped highlights of the reparsed tree
/// are a fresh parse's, each capture in a face of its own.
fn highlights_after_edits<S: Syntax>(syntax: &S, parser: &mut S::Parser, corpus: &Corpus) -> bool {
    let grammar = GrammarName::new(corpus.grammar);
    let Some(query) = syntax
        .shipped_query(&grammar, QueryKind::Highlights)
        .and_then(|source| syntax.compile(&grammar, &source).ok())
    else {
        return false;
    };
    let names = syntax.capture_names(&query);
    let faces = names.iter().cloned().map(Some).collect();
    let Ok(highlighter) = Highlighter::new(Arc::new(query), names.len(), faces) else {
        return false;
    };
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
    let same = |reparsed: &S::Tree, fresh: &S::Tree, snapshot: &Snapshot| {
        drawn(reparsed, snapshot) == drawn(fresh, snapshot)
    };
    after_edits(syntax, parser, corpus, &same)
}

/// The named cases from every text, and the sweep, each reparse held to
/// `same`; and at least one incremental parse kept, so that a property is
/// never held only by whole parses.
fn after_edits<S: Syntax>(
    syntax: &S,
    parser: &mut S::Parser,
    corpus: &Corpus,
    same: Same<'_, S>,
) -> bool {
    let kept = Cell::new(0);
    let named = corpus.texts.iter().all(|text| {
        NAMED_CASES.iter().all(|case| {
            let mut run = Run::new(syntax, parser, text, &kept);
            let transactions = case(&run.snapshot(), corpus);
            let applied = transactions.iter().all(|changes| {
                // A case computes each transaction from the text before
                // the first, so later ones are clamped to the text as it
                // is when applied.
                let snapshot = run.snapshot();
                let changes: Vec<(Range<usize>, &str)> = changes
                    .iter()
                    .map(|(range, insert)| {
                        let start = boundary(&snapshot, range.start);
                        (
                            start..boundary(&snapshot, range.end).max(start),
                            insert.as_str(),
                        )
                    })
                    .collect();
                run.apply(&changes)
            });
            applied && run.reparse(parser, same)
        })
    });
    named && sweep(syntax, parser, corpus, &kept, same) && kept.get() > 0
}

/// The sweep of [`INCREMENTAL`] and [`HIGHLIGHTS_AFTER_EDITS`]: from each
/// text, random sequences of
/// transactions, each step one to three transactions of one to three
/// changes, reparsed once a step; and then the inverse of the whole
/// sequence, which puts the text back as it was, reparsed once more. Every
/// reparse is compared exactly.
fn sweep<S: Syntax>(
    syntax: &S,
    parser: &mut S::Parser,
    corpus: &Corpus,
    kept: &Cell<usize>,
    same: Same<'_, S>,
) -> bool {
    let mut random = Random(0x5eed_5eed_5eed_5eed);
    corpus.texts.iter().all(|text| {
        (0..SEQUENCES).all(|_| {
            let mut run = Run::new(syntax, parser, text, kept);
            (0..STEPS).all(|_| {
                let transactions = 1 + random.below(3);
                let applied = (0..transactions).all(|_| {
                    let changes = random.changes(&run.snapshot(), corpus.pieces);
                    let changes: Vec<(Range<usize>, &str)> = changes
                        .iter()
                        .map(|(range, insert)| (range.clone(), *insert))
                        .collect();
                    run.apply(&changes)
                });
                applied && run.reparse(parser, same)
            }) && run.undo()
                && run.reparse(parser, same)
        })
    })
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
    use std::sync::atomic::{AtomicUsize, Ordering};

    use editor_text::InputEdit;

    use super::*;
    use crate::fake::{GRAMMAR, PARENS_CORPUS, Parens, ParensParser, ParensQuery, ParensTree};
    use crate::port::QueryError;

    #[test]
    fn the_properties_are_eleven_and_each_is_named_once() {
        let mut names = PROPERTIES.to_vec();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), 11);
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
        /// another tree than a fresh parse: it recovers otherwise, as a
        /// real library may.
        RecoversOtherwise,
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

    impl Syntax for Broken {
        type Parser = ParensParser;
        type Tree = ParensTree;
        type Query = ParensQuery;

        fn grammars(&self) -> Vec<GrammarName> {
            Parens.grammars()
        }

        fn parser(&self, grammar: &GrammarName) -> Option<ParensParser> {
            if self.flaw == Flaw::AnyGrammar {
                return Some(ParensParser);
            }
            Parens.parser(grammar)
        }

        fn parse(
            &self,
            parser: &mut ParensParser,
            text: &Snapshot,
            old: Option<&ParensTree>,
        ) -> ParensTree {
            match (self.flaw, old) {
                (Flaw::StaleReuse, Some(old)) => old.clone(),
                (Flaw::StaleCaptures, Some(old)) => {
                    // The fake's tree, with the old tree's edits as the
                    // mark: its nodes are a fresh parse's.
                    let mut tree = Parens.parse(parser, text, None);
                    for edit in old.edits() {
                        Parens.edit(&mut tree, edit);
                    }
                    tree
                }
                (Flaw::RecoversOtherwise, Some(old)) => {
                    let tree = Parens.parse(parser, text, Some(old));
                    if Parens.has_errors(&tree) {
                        let other = Text::from(format!("{text} x").as_str()).snapshot();
                        Parens.parse(parser, &other, None)
                    } else {
                        tree
                    }
                }
                _ => Parens.parse(parser, text, old),
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
                Flaw::ShipsForAny => Parens.shipped_query(&GrammarName::new(GRAMMAR), kind),
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
        assert_eq!(failed(Flaw::ShortRoot), [WHOLE]);
    }

    #[test]
    fn a_syntax_whose_parses_of_one_text_differ_is_reported() {
        assert!(failed(Flaw::Flaky).contains(&DETERMINISTIC));
    }

    #[test]
    fn a_syntax_that_reuses_a_stale_tree_is_reported() {
        assert_eq!(
            failed(Flaw::StaleReuse),
            [INCREMENTAL, HIGHLIGHTS_AFTER_EDITS]
        );
    }

    #[test]
    fn a_syntax_that_recovers_otherwise_when_reparsing_keeps_the_contract_since_the_core_parses_it_whole()
     {
        assert_eq!(failed(Flaw::RecoversOtherwise), [""; 0]);
    }

    #[test]
    fn a_syntax_that_says_no_tree_has_errors_is_reported() {
        assert_eq!(failed(Flaw::NeverErrors), [ERRORS]);
    }

    #[test]
    fn a_syntax_that_says_every_tree_has_errors_is_reported_and_keeps_no_incremental_parse() {
        assert_eq!(
            failed(Flaw::AlwaysErrors),
            [ERRORS, INCREMENTAL, HIGHLIGHTS_AFTER_EDITS]
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
            [SHIPPED, HIGHLIGHTS_AFTER_EDITS]
        );
    }

    #[test]
    fn a_syntax_that_ships_a_query_for_a_grammar_it_lacks_is_reported() {
        assert_eq!(failed(Flaw::ShipsForAny), [SHIPPED]);
    }

    #[test]
    fn a_syntax_whose_captures_of_a_reparsed_tree_differ_from_a_fresh_ones_is_reported() {
        assert_eq!(failed(Flaw::StaleCaptures), [HIGHLIGHTS_AFTER_EDITS]);
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
