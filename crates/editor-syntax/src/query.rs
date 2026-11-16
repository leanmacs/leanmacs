//! The rule for what a query answers of a range: which captures, in what
//! order. It is the core's, so every implementation of the port answers
//! alike, and the Lean model states the same rule
//! (`lean/Editor/SyntaxTree/Model.lean`).

use std::fmt;
use std::ops::Range;

use editor_text::Snapshot;

use crate::port::{Capture, Syntax};

/// A range refused: its ends are not two positions of the text in order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BadRange;

impl fmt::Display for BadRange {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("the range is not two positions of the text in order")
    }
}

impl std::error::Error for BadRange {}

/// Whether a node over `node` is in `range`: it overlaps it
/// (`start < range.end && range.start < end`), or, when the node or the
/// range is empty, the node starts within the range, its ends included.
pub fn overlaps(node: Range<usize>, range: Range<usize>) -> bool {
    if node.is_empty() || range.is_empty() {
        range.start <= node.start && node.start <= range.end
    } else {
        node.start < range.end && range.start < node.end
    }
}

/// The captures of `query` in `tree`, the tree of `text`, whose nodes are
/// in `range` ([`overlaps`]): each once, by start, then the longer first,
/// then by pattern, then by capture.
///
/// Refused when the range is not two positions of the text in order. The
/// port is asked about the range widened by a byte on each side, within the
/// text, and may answer more, or the same capture twice: what it answers is
/// filtered and sorted here.
pub fn captures_in<S: Syntax>(
    syntax: &S,
    query: &S::Query,
    tree: &S::Tree,
    text: &Snapshot,
    range: Range<usize>,
) -> Result<Vec<Capture>, BadRange> {
    let positions = range.start <= range.end
        && text.is_char_boundary(range.start)
        && text.is_char_boundary(range.end);
    if !positions {
        return Err(BadRange);
    }
    // The port is asked a byte wider on each side: a library may leave out
    // a node that only touches an end of the range, and answer nothing of
    // an empty range (tree-sitter does both). What it answers beyond the
    // range is filtered out below.
    let asked = range.start.saturating_sub(1)..range.end.saturating_add(1).min(text.len());
    let mut captures: Vec<Capture> = syntax
        .captures(query, tree, text, asked)
        .into_iter()
        .filter(|capture| overlaps(capture.range(), range.clone()))
        .collect();
    sort(&mut captures);
    Ok(captures)
}

/// Puts `captures` in the core's order, by start, then the longer first,
/// then by pattern, then by capture, and drops repeats.
pub fn sort(captures: &mut Vec<Capture>) {
    captures.sort_by(|a, b| {
        a.start
            .cmp(&b.start)
            .then(b.end.cmp(&a.end))
            .then(a.pattern.cmp(&b.pattern))
            .then(a.capture.cmp(&b.capture))
    });
    captures.dedup();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake::{GRAMMAR, Parens, ParensParser};
    use crate::port::GrammarName;
    use editor_text::{InputEdit, Text};

    /// A capture of pattern 0's capture 0 over `range`.
    fn over(range: Range<usize>) -> Capture {
        Capture {
            pattern: 0,
            capture: 0,
            start: range.start,
            end: range.end,
        }
    }

    #[test]
    fn a_node_overlaps_a_range_it_shares_a_byte_with() {
        assert!(overlaps(2..5, 4..9));
        assert!(overlaps(2..5, 0..3));
        assert!(overlaps(2..5, 3..4));
        assert!(overlaps(2..5, 0..9));
        // Touching is not sharing a byte.
        assert!(!overlaps(2..5, 5..9));
        assert!(!overlaps(2..5, 0..2));
    }

    #[test]
    fn an_empty_node_or_range_overlaps_when_the_node_starts_within_the_range_ends_included() {
        assert!(overlaps(5..5, 2..5));
        assert!(overlaps(2..2, 2..5));
        assert!(!overlaps(6..6, 2..5));
        // An empty range at the node's start; inside the node it overlaps
        // by the first rule only when not empty.
        assert!(overlaps(2..5, 2..2));
        assert!(!overlaps(2..5, 3..3));
        assert!(!overlaps(2..5, 5..5));
        assert!(overlaps(3..3, 3..3));
    }

    #[test]
    fn captures_are_sorted_by_start_then_the_longer_first_then_pattern_then_capture_and_once_each()
    {
        let mut captures = vec![
            over(4..5),
            Capture {
                pattern: 1,
                ..over(0..9)
            },
            over(0..2),
            over(0..9),
            Capture {
                capture: 1,
                ..over(0..9)
            },
            over(4..5),
        ];
        sort(&mut captures);

        assert_eq!(
            captures,
            [
                over(0..9),
                Capture {
                    capture: 1,
                    ..over(0..9)
                },
                Capture {
                    pattern: 1,
                    ..over(0..9)
                },
                over(0..2),
                over(4..5),
            ]
        );
    }

    /// A syntax that answers the fake's captures as its function makes of
    /// them and the range it was asked.
    struct Answering(fn(Vec<Capture>, Range<usize>) -> Vec<Capture>);

    /// Backwards and twice: the rule must put them right.
    const SHUFFLED: Answering = Answering(|mut captures, _| {
        captures.extend(captures.clone());
        captures.reverse();
        captures
    });

    /// Only the captures that share a byte with the range asked, as
    /// tree-sitter answers: none that only touch it, and none at all of an
    /// empty range.
    const STRICT: Answering = Answering(|mut captures, asked| {
        captures.retain(|capture| capture.start < asked.end && asked.start < capture.end);
        captures
    });

    impl Syntax for Answering {
        type Parser = ParensParser;
        type Tree = <Parens as Syntax>::Tree;
        type Query = <Parens as Syntax>::Query;

        fn grammars(&self) -> Vec<GrammarName> {
            Parens.grammars()
        }
        fn parser(&self, grammar: &GrammarName) -> Option<ParensParser> {
            Parens.parser(grammar)
        }
        fn parse(
            &self,
            parser: &mut ParensParser,
            text: &Snapshot,
            old: Option<&Self::Tree>,
        ) -> Self::Tree {
            Parens.parse(parser, text, old)
        }
        fn edit(&self, tree: &mut Self::Tree, edit: &InputEdit) {
            Parens.edit(tree, edit);
        }
        fn compile(
            &self,
            grammar: &GrammarName,
            source: &str,
        ) -> Result<Self::Query, crate::QueryError> {
            Parens.compile(grammar, source)
        }
        fn capture_names(&self, query: &Self::Query) -> Vec<String> {
            Parens.capture_names(query)
        }
        fn captures(
            &self,
            query: &Self::Query,
            tree: &Self::Tree,
            text: &Snapshot,
            range: Range<usize>,
        ) -> Vec<Capture> {
            (self.0)(Parens.captures(query, tree, text, range.clone()), range)
        }
        fn nodes(&self, tree: &Self::Tree) -> Vec<crate::Node> {
            Parens.nodes(tree)
        }
        fn has_errors(&self, tree: &Self::Tree) -> bool {
            Parens.has_errors(tree)
        }
    }

    /// The ranges of the captures `syntax` answers of `range` in `(a b)
    /// (c)`, for atoms and lists.
    fn ranges(syntax: &Answering, range: Range<usize>) -> Vec<Range<usize>> {
        let snapshot = Text::from("(a b) (c)").snapshot();
        let tree = syntax.parse(&mut ParensParser, &snapshot, None);
        let query = syntax
            .compile(&GrammarName::new(GRAMMAR), "atom @atom\nlist @list")
            .unwrap();
        captures_in(syntax, &query, &tree, &snapshot, range)
            .unwrap()
            .iter()
            .map(Capture::range)
            .collect()
    }

    #[test]
    fn a_range_answers_the_captures_of_the_nodes_in_it_in_the_cores_order() {
        assert_eq!(ranges(&SHUFFLED, 0..9), [0..5, 1..2, 3..4, 6..9, 7..8]);
        assert_eq!(ranges(&SHUFFLED, 3..7), [0..5, 3..4, 6..9]);
        assert_eq!(ranges(&SHUFFLED, 5..6), Vec::<Range<usize>>::new());
        assert_eq!(ranges(&SHUFFLED, 6..6), vec![6..9]);
    }

    #[test]
    fn the_port_is_asked_a_byte_wider_so_a_library_that_leaves_out_what_touches_the_range_answers_the_rule()
     {
        // An empty range at a list's start: the list starts in it.
        assert_eq!(ranges(&STRICT, 6..6), vec![6..9]);
        // An empty range at an atom's start, inside a list: the atom
        // starts in it, the list does not.
        assert_eq!(ranges(&STRICT, 1..1), vec![1..2]);
        assert_eq!(ranges(&STRICT, 3..7), [0..5, 3..4, 6..9]);
        assert_eq!(ranges(&STRICT, 9..9), Vec::<Range<usize>>::new());
    }

    #[test]
    fn a_range_that_is_not_two_positions_in_order_is_refused() {
        let snapshot = Text::from("(é)").snapshot();
        let tree = Parens.parse(&mut ParensParser, &snapshot, None);
        let query = Parens
            .compile(&GrammarName::new(GRAMMAR), "atom @a")
            .unwrap();
        let asked = |range| captures_in(&Parens, &query, &tree, &snapshot, range);

        assert_eq!(asked(2..4), Err(BadRange));
        assert_eq!(asked(Range { start: 3, end: 1 }), Err(BadRange));
        assert_eq!(asked(0..5), Err(BadRange));
        assert_eq!(asked(0..4).map(|c| c.len()), Ok(1));
        assert_eq!(asked(4..4).map(|c| c.len()), Ok(0));
    }
}
