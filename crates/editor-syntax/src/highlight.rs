//! Highlighting: a query's captures drawn in faces, and highlights carried
//! through edits until the reparse that replaces them.
//!
//! # The highlighter
//!
//! A [`Highlighter`] is a compiled query and a face, or none, for each of
//! its captures: what a mode's config chose (the capture-to-face rule is
//! Lean's, `lean/Editor/Highlight.lean`, and only its answer crosses). It
//! is refused ([`BadFaces`]) unless it has exactly one entry for each of
//! the query's capture names. The faces are kept as indices into the
//! distinct face names ([`Highlighter::names`]), which is what layout
//! interns once a frame.
//!
//! # The highlight rule ([`spans`])
//!
//! A query's captures, in the core's order ([`crate::query::sort`]: by
//! start, the longer first, then by pattern), become spans:
//!
//! 1. a capture whose face is none is dropped, so a capture nothing maps
//!    never hides one that is mapped;
//! 2. a capture of an empty node is dropped;
//! 3. of the captures of one node (the same start and end), the first is
//!    kept, which is the earliest pattern, as tree-sitter-highlight does:
//!    an earlier pattern of `highlights.scm` wins;
//! 4. the core's order is kept, so an inner node comes after the node
//!    around it, and layout, which stacks spans in the order given, draws
//!    an inner node (an escape inside a string) over its outer one.
//!
//! [`fresh`] is a whole parse, the captures of the whole text, and the rule:
//! the reference every carried or reparsed highlight is compared with.
//!
//! # Carrying through a patch ([`back`], [`carry`])
//!
//! Highlights are drawn from the tree delivered last, of revision M, over a
//! snapshot of revision N at or after it ([`crate::session`], "Highlights").
//! With the edit log's patch from M to N:
//!
//! - **Back** ([`back`]): a range of N is mapped to M. Text the patch kept
//!   is moved by the edits before it. An end inside an edit's new span goes
//!   to that edit's old start (a range's start) or old end (a range's end),
//!   so the range of M covers all that the range of N could come from.
//! - **Forward** ([`carry`]): a span of M keeps its parts outside every
//!   edit's old span, each moved by the edits before it. A part inside an
//!   edited range is dropped: text typed since M is plain until the reparse
//!   that replaces these highlights. Parts that end up touching are one.
//!
//! Every end lands on a position of N: kept text moves whole, and an edit's
//! ends are positions.

use std::fmt;
use std::ops::Range;
use std::sync::Arc;

use editor_text::{Edit, Patch, Revision, Snapshot};

use crate::port::{Capture, Syntax};
use crate::query::captures_in;
use crate::session::Parsed;

/// A face table refused: it does not have one entry for each of the
/// query's capture names.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BadFaces;

impl fmt::Display for BadFaces {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("the faces are not one for each of the query's capture names")
    }
}

impl std::error::Error for BadFaces {}

/// A query, and the face each of its captures is drawn in.
pub struct Highlighter<Q> {
    /// The query.
    query: Arc<Q>,
    /// For each capture, by index, the index of its face in `names`; none
    /// for a capture that draws nothing.
    faces: Vec<Option<usize>>,
    /// The distinct face names, in the order of the first capture that
    /// names each.
    names: Vec<String>,
}

impl<Q> Highlighter<Q> {
    /// The highlighter of `query`, which has `capture_count` capture names,
    /// drawing capture `i` in `faces[i]`, or nothing for none; refused
    /// unless there is exactly one entry for each capture name.
    pub fn new(
        query: Arc<Q>,
        capture_count: usize,
        faces: Vec<Option<String>>,
    ) -> Result<Self, BadFaces> {
        if faces.len() != capture_count {
            return Err(BadFaces);
        }
        let mut names: Vec<String> = Vec::new();
        let faces = faces
            .into_iter()
            .map(|face| {
                let face = face?;
                Some(match names.iter().position(|name| *name == face) {
                    Some(index) => index,
                    None => {
                        names.push(face);
                        names.len() - 1
                    }
                })
            })
            .collect();
        Ok(Self {
            query,
            faces,
            names,
        })
    }

    /// The query.
    pub fn query(&self) -> &Q {
        &self.query
    }

    /// The distinct face names its spans name by index.
    pub fn names(&self) -> &[String] {
        &self.names
    }

    /// The index in [`names`](Self::names) of the face capture `capture`
    /// is drawn in; none when it draws nothing.
    pub fn face_of(&self, capture: u32) -> Option<usize> {
        let index = usize::try_from(capture).ok()?;
        self.faces.get(index).copied().flatten()
    }
}

/// A span of a text drawn in a face of a highlighter's.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct HighlightSpan {
    /// Its bytes.
    pub bytes: Range<usize>,
    /// Its face, an index into [`Highlighter::names`].
    pub face: usize,
}

/// The spans of `captures`, given in the core's order, by the highlight
/// rule of the module docs.
pub fn spans<Q>(highlighter: &Highlighter<Q>, captures: &[Capture]) -> Vec<HighlightSpan> {
    let mut drawn = Vec::new();
    // The node of the last capture kept: a later capture of it is of a
    // later pattern, which the first wins over.
    let mut last: Option<Range<usize>> = None;
    for capture in captures {
        let Some(face) = highlighter.face_of(capture.capture) else {
            continue;
        };
        let bytes = capture.range();
        if bytes.is_empty() || last.as_ref() == Some(&bytes) {
            continue;
        }
        last = Some(bytes.clone());
        drawn.push(HighlightSpan { bytes, face });
    }
    drawn
}

/// The spans of the whole of `snapshot` from a fresh parse: the reference
/// that carried and reparsed highlights are compared with.
pub fn fresh<S: Syntax>(
    syntax: &S,
    highlighter: &Highlighter<S::Query>,
    parser: &mut S::Parser,
    snapshot: &Snapshot,
) -> Vec<HighlightSpan> {
    let tree = syntax.parse(parser, snapshot, None);
    let captures = captures_in(
        syntax,
        highlighter.query(),
        &tree,
        snapshot,
        0..snapshot.len(),
    )
    .unwrap_or_default();
    spans(highlighter, &captures)
}

/// `bytes`, a range of the text `patch` reaches, mapped back to the text
/// it starts from, as the module docs say.
pub fn back(patch: &Patch, bytes: Range<usize>) -> Range<usize> {
    back_start(patch, bytes.start)..back_end(patch, bytes.end)
}

/// `offset` of the text `patch` reaches moved back by the last edit that
/// ends at or before it, as text that edit kept after it.
fn moved_back(offset: usize, before: Option<&Edit>) -> usize {
    before.map_or(offset, |edit| offset - edit.new.end + edit.old.end)
}

/// The start of a range of the text `patch` reaches, mapped back: inside an
/// edit's new span (its start included), the edit's old start.
fn back_start(patch: &Patch, offset: usize) -> usize {
    let mut before = None;
    for edit in &patch.edits {
        if offset < edit.new.start {
            break;
        }
        if offset < edit.new.end {
            return edit.old.start;
        }
        before = Some(edit);
    }
    moved_back(offset, before)
}

/// The end of a range of the text `patch` reaches, mapped back: inside an
/// edit's new span (its end included), the edit's old end.
fn back_end(patch: &Patch, offset: usize) -> usize {
    let mut before = None;
    for edit in &patch.edits {
        if offset <= edit.new.start {
            break;
        }
        if offset <= edit.new.end {
            return edit.old.end;
        }
        before = Some(edit);
    }
    moved_back(offset, before)
}

/// The parts of `bytes`, a range of the text `patch` starts from, that the
/// patch kept, moved to the text it reaches, in order, those that touch
/// made one.
pub fn carry(patch: &Patch, bytes: Range<usize>) -> Vec<Range<usize>> {
    let mut parts: Vec<Range<usize>> = Vec::new();
    let mut keep = |kept: Range<usize>, before: Option<&Edit>| {
        let start = kept.start.max(bytes.start);
        let end = kept.end.min(bytes.end);
        if start >= end {
            return;
        }
        // Moved by the last edit before it: from its old end to its new.
        let shift =
            |offset: usize| before.map_or(offset, |edit| offset - edit.old.end + edit.new.end);
        let part = shift(start)..shift(end);
        match parts.last_mut() {
            Some(last) if last.end == part.start => last.end = part.end,
            _ => parts.push(part),
        }
    };
    let mut before: Option<&Edit> = None;
    for edit in &patch.edits {
        let from = before.map_or(0, |edit| edit.old.end);
        keep(from..edit.old.start, before);
        before = Some(edit);
    }
    keep(before.map_or(0, |edit| edit.old.end)..usize::MAX, before);
    parts
}

/// What a text is drawn with for one snapshot: the tree delivered last, the
/// highlighter, and the patch from the tree's revision to the snapshot's
/// when they differ ([`crate::Session::highlights`]). It is fixed once
/// made.
pub struct Highlights<S: Syntax> {
    /// The tree delivered, with its snapshot.
    parsed: Arc<Parsed<S::Tree>>,
    /// The highlighter.
    highlighter: Arc<Highlighter<S::Query>>,
    /// From the tree's revision to the snapshot's; none when they are one.
    patch: Option<Patch>,
}

impl<S: Syntax> Highlights<S> {
    /// The highlights of `parsed` by `highlighter`, carried through
    /// `patch` when there is one.
    pub(crate) fn new(
        parsed: Arc<Parsed<S::Tree>>,
        highlighter: Arc<Highlighter<S::Query>>,
        patch: Option<Patch>,
    ) -> Self {
        Self {
            parsed,
            highlighter,
            patch,
        }
    }

    /// The face names its spans name by index.
    pub fn faces(&self) -> &[String] {
        self.highlighter.names()
    }

    /// The revision of the tree it draws from.
    pub fn revision(&self) -> Revision {
        self.parsed.revision
    }

    /// Adds to `out` its spans that cover any of `bytes`, a range of the
    /// snapshot it was made for, cut to it, in the order of the highlight
    /// rule: `bytes` mapped back to the tree's text ([`back`]), the query's
    /// captures there drawn by the rule ([`spans`]), each carried forward
    /// ([`carry`]), and cut. Nothing for a range that is not two positions
    /// in order.
    pub fn spans(&self, syntax: &S, bytes: Range<usize>, out: &mut Vec<HighlightSpan>) {
        let asked = match &self.patch {
            Some(patch) => back(patch, bytes.clone()),
            None => bytes.clone(),
        };
        let parsed = &self.parsed;
        let Ok(captures) = captures_in(
            syntax,
            self.highlighter.query(),
            &parsed.tree,
            &parsed.snapshot,
            asked,
        ) else {
            return;
        };
        for span in spans(&self.highlighter, &captures) {
            let parts = match &self.patch {
                Some(patch) => carry(patch, span.bytes),
                None => vec![span.bytes],
            };
            for part in parts {
                let cut = part.start.max(bytes.start)..part.end.min(bytes.end);
                if !cut.is_empty() {
                    out.push(HighlightSpan {
                        bytes: cut,
                        face: span.face,
                    });
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use editor_text::Text;

    use super::*;
    use crate::fake::{GRAMMAR, Parens, ParensParser, ParensQuery};
    use crate::port::GrammarName;

    /// The fake's query `source`, with `faces` for its captures.
    fn highlighter(source: &str, faces: &[Option<&str>]) -> Highlighter<ParensQuery> {
        let query = Parens.compile(&GrammarName::new(GRAMMAR), source).unwrap();
        let count = Parens.capture_names(&query).len();
        let faces = faces.iter().map(|face| face.map(str::to_owned)).collect();
        Highlighter::new(Arc::new(query), count, faces).unwrap()
    }

    /// The spans of `text` by `highlighter`, each as its bytes and the name
    /// of its face.
    fn drawn(highlighter: &Highlighter<ParensQuery>, text: &str) -> Vec<(Range<usize>, String)> {
        let snapshot = Text::from(text).snapshot();
        fresh(&Parens, highlighter, &mut ParensParser, &snapshot)
            .into_iter()
            .map(|span| (span.bytes, highlighter.names()[span.face].clone()))
            .collect()
    }

    /// `(bytes, face)` as owned.
    fn at(bytes: Range<usize>, face: &str) -> (Range<usize>, String) {
        (bytes, face.to_owned())
    }

    #[test]
    fn each_capture_is_drawn_in_its_face_by_start_and_the_outer_node_first() {
        let parens = highlighter(
            "\"(\" @paren\n\")\" @paren\nlist @list\natom @atom",
            &[
                Some("syntax.punctuation"),
                Some("syntax.list"),
                Some("syntax.atom"),
            ],
        );

        assert_eq!(
            drawn(&parens, "(a b)"),
            [
                at(0..5, "syntax.list"),
                at(0..1, "syntax.punctuation"),
                at(1..2, "syntax.atom"),
                at(3..4, "syntax.atom"),
                at(4..5, "syntax.punctuation"),
            ]
        );
    }

    #[test]
    fn the_faces_are_named_once_each_in_the_order_captures_first_name_them() {
        let parens = highlighter(
            "atom @a\nlist @b\n\"(\" @c",
            &[Some("one"), Some("two"), Some("one")],
        );

        assert_eq!(parens.names(), ["one", "two"]);
        assert_eq!(
            [parens.face_of(0), parens.face_of(1), parens.face_of(2)],
            [Some(0), Some(1), Some(0)]
        );
        assert_eq!(parens.face_of(3), None);
    }

    #[test]
    fn a_capture_nothing_maps_draws_nothing_and_never_hides_a_mapped_one() {
        let parens = highlighter(
            "atom @plain\natom @atom\nlist @list",
            &[None, Some("atom"), None],
        );

        assert_eq!(drawn(&parens, "(a)"), [at(1..2, "atom")]);
    }

    #[test]
    fn of_two_patterns_on_one_node_the_first_wins() {
        let parens = highlighter(
            "atom @variable\natom @constant",
            &[Some("variable"), Some("constant")],
        );

        assert_eq!(drawn(&parens, "x"), [at(0..1, "variable")]);
    }

    #[test]
    fn a_capture_of_an_empty_node_draws_nothing() {
        // `(a` ends with a `)` that is missing: no width, at the end.
        let parens = highlighter("\")\" @paren\natom @atom", &[Some("paren"), Some("atom")]);

        assert_eq!(drawn(&parens, "(a"), [at(1..2, "atom")]);
        let empty = Capture {
            pattern: 0,
            capture: 0,
            start: 2,
            end: 2,
        };
        assert_eq!(spans(&parens, &[empty]), []);
    }

    #[test]
    fn a_face_table_not_one_for_each_capture_name_is_refused() {
        let query = Parens
            .compile(&GrammarName::new(GRAMMAR), "atom @a\nlist @b")
            .unwrap();
        let query = Arc::new(query);

        assert!(Highlighter::new(query.clone(), 2, vec![None]).is_err());
        assert!(Highlighter::new(query.clone(), 2, vec![None, None, None]).is_err());
        assert!(Highlighter::new(query, 2, vec![None, Some("b".to_owned())]).is_ok());
    }

    /// The patch of `text` from revision 0 after `edits`, each a range of
    /// the text as it is then and what replaces it.
    fn patch(text: &str, edits: &[(Range<usize>, &str)]) -> Patch {
        let mut text = Text::from(text);
        for (range, with) in edits {
            text.replace(range.clone(), with).unwrap();
        }
        text.changes_since(Revision::new(0)).unwrap()
    }

    #[test]
    fn kept_text_is_carried_moved_by_the_edits_before_it() {
        // `abcdef` with `XY` put in at 1 and `e` taken out.
        let edited = patch("abcdef", &[(1..1, "XY"), (6..7, "")]);

        // Before every edit: as it was.
        assert_eq!(carry(&edited, 0..1), vec![0..1]);
        // Between the two: moved on by the insert.
        assert_eq!(carry(&edited, 2..4), vec![4..6]);
        // After both: moved on by two and back by one.
        assert_eq!(carry(&edited, 5..6), vec![6..7]);
        assert_eq!(back(&edited, 6..7), 5..6);
        assert_eq!(back(&edited, 4..6), 2..4);
        assert_eq!(back(&edited, 0..1), 0..1);
    }

    #[test]
    fn a_span_with_text_put_in_inside_it_is_carried_around_the_new_text() {
        // `(abc)`, with `XY` typed after the `a`.
        let edited = patch("(abc)", &[(2..2, "XY")]);

        assert_eq!(carry(&edited, 0..5), [0..2, 4..7]);
        assert_eq!(carry(&edited, 1..4), [1..2, 4..6]);
        // A range of the new text maps back to where it was put in, and a
        // range that holds it to the span around it.
        assert_eq!(back(&edited, 2..4), 2..2);
        assert_eq!(back(&edited, 3..3), 2..2);
        assert_eq!(back(&edited, 1..5), 1..3);
    }

    #[test]
    fn a_span_an_edit_deletes_across_keeps_what_is_left_of_it_as_one() {
        // `abcdefgh` with `cdef` taken out.
        let edited = patch("abcdefgh", &[(2..6, "")]);

        // What is left either side touches, and is one.
        assert_eq!(carry(&edited, 1..7), vec![1..3]);
        // A span inside what was taken out is gone.
        assert_eq!(carry(&edited, 3..5), Vec::<Range<usize>>::new());
        // A span from inside it to after it keeps what follows.
        assert_eq!(carry(&edited, 4..8), vec![2..4]);
        // Back: a range ending where the deletion was ends at its start,
        // and one starting there starts at its end.
        assert_eq!(back(&edited, 0..2), 0..2);
        assert_eq!(back(&edited, 2..4), 6..8);
        assert_eq!(back(&edited, 1..3), 1..7);
    }

    #[test]
    fn a_replacement_drops_what_it_replaced_and_maps_its_new_text_to_the_old() {
        // `abcdef` with `cd` replaced by `XYZ`.
        let edited = patch("abcdef", &[(2..4, "XYZ")]);

        assert_eq!(carry(&edited, 0..6), [0..2, 5..7]);
        assert_eq!(back(&edited, 3..4), 2..4);
        assert_eq!(back(&edited, 0..7), 0..6);
        assert_eq!(back(&edited, 5..7), 4..6);
    }

    #[test]
    fn multibyte_text_is_carried_on_positions() {
        // `é漢😀`, with `ü` put in after the `é`, and the `😀` taken out.
        let edited = patch("é漢😀", &[(2..2, "ü"), (7..11, "")]);

        assert_eq!(carry(&edited, 0..9), [0..2, 4..7]);
        assert_eq!(back(&edited, 4..7), 2..5);
        assert_eq!(back(&edited, 2..4), 2..2);
    }
}
