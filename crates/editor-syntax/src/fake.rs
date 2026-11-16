//! The port's published fake: [`Parens`], a [`Syntax`] of a toy grammar
//! small enough to be obviously right.
//!
//! The grammar is called `parens`:
//!
//! - **The root** is a `document` over the whole text.
//! - **A list** is `( … )`: a named `list` node, whose children are the
//!   anonymous `"("` at the field `open`, what is between, and the
//!   anonymous `")"` at the field `close`. A list still open at the end of
//!   the text ends there, with a `")"` that is missing: no width, at the
//!   end.
//! - **An atom** is a run of characters that are neither blanks (a space,
//!   a tab, a carriage return, a line feed) nor parens: a named `atom`.
//! - **A `)` with no list open** is an `ERROR` node, named, with `error`
//!   set.
//!
//! A tree is kept as its nodes. [`Syntax::edit`] records the edit in the
//! tree and [`Syntax::parse`] always parses the whole text, so a reparse
//! that is handed an old tree equals a fresh one trivially.
//!
//! **Queries** are one pattern a line: `kind @name`, for a named node of
//! that kind (`document`, `list`, `atom`, `ERROR`), or `"(" @name` and
//! `")" @name` for the anonymous parens. Blank lines are skipped. A word
//! that names no kind is refused with [`QueryErrorKind::NodeType`] at its
//! offset; any other line that is not a pattern with
//! [`QueryErrorKind::Syntax`] at the line's. A capture's name is numbered
//! where it first appears. A query answers every capture of the tree,
//! whatever range it is asked: [`crate::query::captures_in`] keeps what the
//! range holds.
//!
//! It is public, not `cfg(test)`, so the tests of any crate above the port
//! run on it. [`PARENS_CORPUS`] is what [`crate::contract::check`] holds it
//! to.

use std::ops::Range;
use std::sync::Arc;

use editor_text::{InputEdit, Point, Snapshot};

use crate::contract::Corpus;
use crate::port::{Capture, GrammarName, Node, QueryError, QueryErrorKind, Syntax};

/// The fake: the `parens` grammar.
#[derive(Debug, Default, Clone, Copy)]
pub struct Parens;

/// The name of the fake's one grammar.
pub const GRAMMAR: &str = "parens";

/// The named kinds of the `parens` grammar.
const NAMED_KINDS: [&str; 4] = ["document", "list", "atom", "ERROR"];

/// The fake's parser. It holds nothing: every parse reads the whole text.
#[derive(Debug, Default)]
pub struct ParensParser;

/// A tree of the `parens` grammar: its nodes in pre-order, shared by
/// clones, and the edits it has been told since it was parsed.
#[derive(Debug, Clone)]
pub struct ParensTree {
    /// The nodes, in pre-order.
    nodes: Arc<Vec<Node>>,
    /// The edits told, in order.
    edits: Vec<InputEdit>,
}

impl ParensTree {
    /// The edits the tree has been told since it was parsed, in order.
    pub fn edits(&self) -> &[InputEdit] {
        &self.edits
    }
}

/// A compiled query of the `parens` grammar.
#[derive(Debug, Clone)]
pub struct ParensQuery {
    /// Each pattern: what node it matches, and the index of its capture.
    patterns: Vec<(Kind, u32)>,
    /// The names of the captures, by index.
    names: Vec<String>,
}

/// What node a pattern matches.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Kind {
    /// A named node of this kind.
    Named(String),
    /// An anonymous node whose text is this.
    Anonymous(String),
}

impl Kind {
    /// Whether `node` is of this kind.
    fn matches(&self, node: &Node) -> bool {
        match self {
            Self::Named(kind) => node.named && node.kind == *kind,
            Self::Anonymous(text) => !node.named && node.kind == *text,
        }
    }
}

impl Syntax for Parens {
    type Parser = ParensParser;
    type Tree = ParensTree;
    type Query = ParensQuery;

    fn grammars(&self) -> Vec<GrammarName> {
        vec![GrammarName::new(GRAMMAR)]
    }

    fn parser(&self, grammar: &GrammarName) -> Option<ParensParser> {
        (grammar.as_str() == GRAMMAR).then_some(ParensParser)
    }

    fn parse(&self, _: &mut ParensParser, text: &Snapshot, _: Option<&ParensTree>) -> ParensTree {
        ParensTree {
            nodes: Arc::new(parse(text)),
            edits: Vec::new(),
        }
    }

    fn edit(&self, tree: &mut ParensTree, edit: &InputEdit) {
        tree.edits.push(*edit);
    }

    fn compile(&self, grammar: &GrammarName, source: &str) -> Result<ParensQuery, QueryError> {
        if grammar.as_str() != GRAMMAR {
            return Err(QueryError {
                kind: QueryErrorKind::Language,
                offset: 0,
            });
        }
        compile(source)
    }

    fn capture_names(&self, query: &ParensQuery) -> Vec<String> {
        query.names.clone()
    }

    fn captures(
        &self,
        query: &ParensQuery,
        tree: &ParensTree,
        _: &Snapshot,
        _: Range<usize>,
    ) -> Vec<Capture> {
        let mut captures = Vec::new();
        for node in tree.nodes.iter() {
            for (pattern, (kind, capture)) in query.patterns.iter().enumerate() {
                if kind.matches(node) {
                    captures.push(Capture {
                        pattern,
                        capture: *capture,
                        start: node.start,
                        end: node.end,
                    });
                }
            }
        }
        captures
    }

    fn nodes(&self, tree: &ParensTree) -> Vec<Node> {
        tree.nodes.as_ref().clone()
    }
}

/// A node being built: the node, with its depth left to the flattening,
/// and its children.
struct Built {
    /// Its kind.
    kind: &'static str,
    /// Whether it is named.
    named: bool,
    /// Its field.
    field: Option<&'static str>,
    /// Its range.
    range: Range<usize>,
    /// Whether it is an error.
    error: bool,
    /// Whether it is missing.
    missing: bool,
    /// Its children, in order.
    children: Vec<Built>,
}

impl Built {
    /// A node of no children.
    fn leaf(
        kind: &'static str,
        named: bool,
        field: Option<&'static str>,
        range: Range<usize>,
    ) -> Self {
        Self {
            kind,
            named,
            field,
            range,
            error: false,
            missing: false,
            children: Vec::new(),
        }
    }

    /// Adds this node and its children to `nodes`, in pre-order, at
    /// `depth`.
    fn flatten(self, depth: u32, text: &Snapshot, nodes: &mut Vec<Node>) {
        let point = |offset| text.offset_to_point(offset).unwrap_or(Point::new(0, 0));
        nodes.push(Node {
            kind: self.kind.to_owned(),
            named: self.named,
            field: self.field.map(str::to_owned),
            depth,
            start: self.range.start,
            end: self.range.end,
            start_point: point(self.range.start),
            end_point: point(self.range.end),
            error: self.error,
            missing: self.missing,
        });
        for child in self.children {
            child.flatten(depth + 1, text, nodes);
        }
    }
}

/// Whether `c` separates atoms.
fn is_blank(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\r' | '\n')
}

/// The nodes of `text` in the `parens` grammar, in pre-order.
fn parse(text: &Snapshot) -> Vec<Node> {
    let source = text.to_string();
    // The children of the root, and of each list still open, innermost
    // last, with where each list opened.
    let mut root: Vec<Built> = Vec::new();
    let mut open: Vec<(usize, Vec<Built>)> = Vec::new();
    let mut atom: Option<usize> = None;
    let push = |open: &mut Vec<(usize, Vec<Built>)>, root: &mut Vec<Built>, node: Built| match open
        .last_mut()
    {
        Some((_, children)) => children.push(node),
        None => root.push(node),
    };
    for (offset, c) in source.char_indices().chain([(source.len(), ' ')]) {
        let ends_atom = is_blank(c) || c == '(' || c == ')';
        if ends_atom {
            if let Some(start) = atom.take() {
                push(
                    &mut open,
                    &mut root,
                    Built::leaf("atom", true, None, start..offset),
                );
            }
        } else if atom.is_none() {
            atom = Some(offset);
        }
        if offset == source.len() {
            break;
        }
        match c {
            '(' => open.push((
                offset,
                vec![Built::leaf("(", false, Some("open"), offset..offset + 1)],
            )),
            ')' => match open.pop() {
                Some((start, mut children)) => {
                    children.push(Built::leaf(")", false, Some("close"), offset..offset + 1));
                    let list = Built {
                        children,
                        ..Built::leaf("list", true, None, start..offset + 1)
                    };
                    push(&mut open, &mut root, list);
                }
                None => {
                    let error = Built {
                        error: true,
                        ..Built::leaf("ERROR", true, None, offset..offset + 1)
                    };
                    push(&mut open, &mut root, error);
                }
            },
            _ => {}
        }
    }
    let end = source.len();
    while let Some((start, mut children)) = open.pop() {
        children.push(Built {
            missing: true,
            ..Built::leaf(")", false, Some("close"), end..end)
        });
        let list = Built {
            children,
            ..Built::leaf("list", true, None, start..end)
        };
        push(&mut open, &mut root, list);
    }
    let document = Built {
        children: root,
        ..Built::leaf("document", true, None, 0..end)
    };
    let mut nodes = Vec::new();
    document.flatten(0, text, &mut nodes);
    nodes
}

/// The query `source` spells, in the `parens` grammar.
fn compile(source: &str) -> Result<ParensQuery, QueryError> {
    let mut query = ParensQuery {
        patterns: Vec::new(),
        names: Vec::new(),
    };
    let mut line_start = 0;
    for line in source.split_inclusive('\n') {
        let at = line_start;
        line_start += line.len();
        let words: Vec<(usize, &str)> = words(line).collect();
        if words.is_empty() {
            continue;
        }
        let syntax = QueryError {
            kind: QueryErrorKind::Syntax,
            offset: at,
        };
        let [(kind_at, kind), (_, name)] = words[..] else {
            return Err(syntax);
        };
        let Some(name) = name.strip_prefix('@').filter(|name| !name.is_empty()) else {
            return Err(syntax);
        };
        let kind = match kind {
            "\"(\"" => Kind::Anonymous("(".to_owned()),
            "\")\"" => Kind::Anonymous(")".to_owned()),
            kind if NAMED_KINDS.contains(&kind) => Kind::Named(kind.to_owned()),
            kind if kind.chars().all(|c| c.is_alphanumeric() || c == '_') => {
                return Err(QueryError {
                    kind: QueryErrorKind::NodeType,
                    offset: at + kind_at,
                });
            }
            _ => return Err(syntax),
        };
        let capture = match query.names.iter().position(|known| known == name) {
            Some(index) => index,
            None => {
                query.names.push(name.to_owned());
                query.names.len() - 1
            }
        };
        query
            .patterns
            .push((kind, u32::try_from(capture).unwrap_or(u32::MAX)));
    }
    Ok(query)
}

/// The words of `line`, split at blanks, each with its offset in the line.
fn words(line: &str) -> impl Iterator<Item = (usize, &str)> {
    line.split(is_blank)
        .scan(0, |at, word| {
            let start = *at;
            *at += word.len() + 1;
            Some((start, word))
        })
        .filter(|(_, word)| !word.is_empty())
}

/// What [`crate::contract::check`] holds [`Parens`] to.
pub const PARENS_CORPUS: Corpus = Corpus {
    grammar: GRAMMAR,
    texts: &[
        "",
        "atom",
        "(a b) c",
        "(a (b c)\n  (d))\r\n(e",
        "((é 漢)) ) (😀\n",
        "  (\n(\n)  x)\n\n",
    ],
    pieces: &["(", ")", " ", "\n", "x", "é", "(y z)", "\r\n"],
    query: "list @list\natom @leaf\n\"(\" @paren\n\")\" @paren\nERROR @error\n",
    query_names: &["list", "leaf", "paren", "error"],
    bad_queries: &[
        ("list", QueryErrorKind::Syntax),
        ("list @", QueryErrorKind::Syntax),
        ("[list] @x", QueryErrorKind::Syntax),
        ("nope @x", QueryErrorKind::NodeType),
    ],
    unknown_kind_query: "atom @a\nvector @v\n",
};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::contract;
    use editor_text::Text;

    /// The nodes of `text`, each as its kind, depth and range.
    fn shape(text: &str) -> Vec<(String, u32, Range<usize>)> {
        let snapshot = Text::from(text).snapshot();
        let tree = Parens.parse(&mut ParensParser, &snapshot, None);
        Parens
            .nodes(&tree)
            .into_iter()
            .map(|node| (node.kind, node.depth, node.start..node.end))
            .collect()
    }

    /// `(kind, depth, range)` as owned.
    fn node(kind: &str, depth: u32, range: Range<usize>) -> (String, u32, Range<usize>) {
        (kind.to_owned(), depth, range)
    }

    #[test]
    fn the_fake_keeps_the_ports_contract() {
        assert_eq!(contract::check(&Parens, &PARENS_CORPUS), [""; 0]);
    }

    #[test]
    fn a_list_is_its_parens_and_what_is_between_them_and_atoms_are_runs_of_other_characters() {
        assert_eq!(
            shape("(a bc) d"),
            [
                node("document", 0, 0..8),
                node("list", 1, 0..6),
                node("(", 2, 0..1),
                node("atom", 2, 1..2),
                node("atom", 2, 3..5),
                node(")", 2, 5..6),
                node("atom", 1, 7..8),
            ]
        );
    }

    #[test]
    fn a_list_open_at_the_end_closes_with_a_missing_paren_and_a_stray_close_is_an_error() {
        let snapshot = Text::from(") (a").snapshot();
        let nodes = Parens.nodes(&Parens.parse(&mut ParensParser, &snapshot, None));

        let kinds: Vec<_> = nodes
            .iter()
            .map(|node| {
                (
                    node.kind.as_str(),
                    node.start..node.end,
                    node.error,
                    node.missing,
                )
            })
            .collect();
        assert_eq!(
            kinds,
            [
                ("document", 0..4, false, false),
                ("ERROR", 0..1, true, false),
                ("list", 2..4, false, false),
                ("(", 2..3, false, false),
                ("atom", 3..4, false, false),
                (")", 4..4, false, true),
            ]
        );
        assert_eq!(nodes[3].field.as_deref(), Some("open"));
        assert_eq!(nodes[5].field.as_deref(), Some("close"));
    }

    #[test]
    fn points_count_rows_by_line_feed_and_columns_in_bytes() {
        let snapshot = Text::from("é\r\n(x)").snapshot();
        let nodes = Parens.nodes(&Parens.parse(&mut ParensParser, &snapshot, None));

        let list = &nodes[2];
        assert_eq!(list.kind, "list");
        assert_eq!(list.start_point, Point::new(1, 0));
        assert_eq!(list.end_point, Point::new(1, 3));
        assert_eq!(nodes[0].end_point, Point::new(1, 3));
    }

    #[test]
    fn a_query_captures_each_node_of_its_kinds_with_its_patterns_index() {
        let query = Parens
            .compile(&GrammarName::new(GRAMMAR), "atom @a\n\n\"(\" @p\nlist @a")
            .unwrap();
        let snapshot = Text::from("(x)").snapshot();
        let tree = Parens.parse(&mut ParensParser, &snapshot, None);

        assert_eq!(Parens.capture_names(&query), ["a", "p"]);
        let captures = Parens.captures(&query, &tree, &snapshot, 0..3);
        let at = |pattern, capture, range: Range<usize>| Capture {
            pattern,
            capture,
            start: range.start,
            end: range.end,
        };
        assert_eq!(captures, [at(2, 0, 0..3), at(1, 1, 0..1), at(0, 0, 1..2)]);
    }

    #[test]
    fn a_query_that_is_not_one_is_refused_where_it_goes_wrong() {
        let refused = |source: &str| {
            Parens
                .compile(&GrammarName::new(GRAMMAR), source)
                .unwrap_err()
        };

        assert_eq!(
            refused("atom @a\nvector @v"),
            QueryError {
                kind: QueryErrorKind::NodeType,
                offset: 8
            }
        );
        assert_eq!(
            refused("atom @a\n  atom"),
            QueryError {
                kind: QueryErrorKind::Syntax,
                offset: 8
            }
        );
        assert_eq!(
            Parens
                .compile(&GrammarName::new("rust"), "atom @a")
                .unwrap_err()
                .kind,
            QueryErrorKind::Language
        );
    }

    #[test]
    fn an_edit_is_recorded_in_the_tree_and_a_parse_reads_the_whole_text() {
        let mut text = Text::from("(a)");
        let old = Parens.parse(&mut ParensParser, &text.snapshot(), None);
        let mut edited = old.clone();
        text.replace(1..2, "bc").unwrap();
        let patch = text.changes_since(editor_text::Revision::new(0)).unwrap();
        Parens.edit(&mut edited, &patch.edits[0].input_edit());

        assert_eq!(edited.edits(), [patch.edits[0].input_edit()]);
        let snapshot = text.snapshot();
        let reparsed = Parens.parse(&mut ParensParser, &snapshot, Some(&edited));
        let fresh = Parens.parse(&mut ParensParser, &snapshot, None);
        assert_eq!(Parens.nodes(&reparsed), Parens.nodes(&fresh));
    }
}
