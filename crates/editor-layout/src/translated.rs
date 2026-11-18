//! Other texts' spans, drawn in this one: a [`TextSpans`] that answers for
//! a text made of pieces of other texts by asking each piece's source for
//! its own spans and moving them to where the piece is.
//!
//! It is layout's combinator of [`TextSpans`] and knows nothing of what
//! made the pieces. A binding builds one for a text whose bytes are
//! pieces of other texts (`editor-ffi` builds it from an excerpt
//! snapshot's list), so a highlight computed once on a source is drawn in
//! every piece of it.
//!
//! - It answers only for the snapshot of the revision it was made for,
//!   and nothing for any other.
//! - Each distinct source (the same [`TextSpans`] at the same source
//!   snapshot's revision) is resolved once per answer, however many
//!   pieces it has. A source that draws nothing over its snapshot draws
//!   nothing in its pieces, and when no source draws anything it draws
//!   nothing.
//! - Its faces are each resolved source's faces in turn, a span's face
//!   index offset by the faces of the sources before its own.
//! - A span is asked of a piece's source for the source's bytes the
//!   piece shows of what is asked, moved back by the piece's offset, and
//!   cut at the piece's edges. The bytes between pieces get no span.
//! - Its spans come in piece order and, within a piece, in its source's
//!   order, so the precedence of [`face`](crate::face) holds within each.

use std::ops::Range;
use std::sync::Arc;

use editor_text::{Revision, Snapshot};

use crate::scene::{SpansAt, TextSpans};

/// A piece of a text that shows a stretch of another.
#[derive(Clone)]
pub struct Piece {
    /// Its bytes in this text.
    pub range: Range<usize>,
    /// Where `range` starts in the source.
    pub source_start: usize,
    /// The source's snapshot the piece shows.
    pub source: Snapshot,
    /// The source's own spans.
    pub spans: Arc<dyn TextSpans>,
}

/// The spans of a text made of [`Piece`]s, each its source's (module
/// docs).
#[derive(Clone)]
pub struct TranslatedSpans {
    /// The revision of the snapshot it answers for.
    revision: Revision,
    /// The pieces, by where they start, none overlapping another.
    pieces: Vec<Piece>,
}

impl TranslatedSpans {
    /// The spans of the snapshot at `revision` whose bytes are `pieces`,
    /// which do not overlap.
    pub fn new(revision: Revision, mut pieces: Vec<Piece>) -> Self {
        pieces.sort_by_key(|piece| piece.range.start);
        Self { revision, pieces }
    }
}

impl TextSpans for TranslatedSpans {
    fn at(&self, snapshot: &Snapshot) -> Option<Box<dyn SpansAt>> {
        if snapshot.revision() != self.revision {
            return None;
        }
        // Each distinct source once: its spans, its snapshot's revision,
        // and what it answered with the offset of its faces.
        let mut sources: Vec<(&Arc<dyn TextSpans>, Revision, Option<usize>)> = Vec::new();
        let mut resolved: Vec<(Box<dyn SpansAt>, usize)> = Vec::new();
        let mut faces: Vec<String> = Vec::new();
        let mut pieces = Vec::new();
        for piece in &self.pieces {
            let revision = piece.source.revision();
            let known = sources
                .iter()
                .find(|(spans, at, _)| Arc::ptr_eq(spans, &piece.spans) && *at == revision);
            let answer = match known {
                Some((_, _, answer)) => *answer,
                None => {
                    let answer = piece.spans.at(&piece.source).map(|at| {
                        let offset = faces.len();
                        faces.extend(at.faces().iter().cloned());
                        resolved.push((at, offset));
                        resolved.len() - 1
                    });
                    sources.push((&piece.spans, revision, answer));
                    answer
                }
            };
            if let Some(source) = answer {
                pieces.push(PieceAt {
                    range: piece.range.clone(),
                    source_start: piece.source_start,
                    source,
                });
            }
        }
        if resolved.is_empty() {
            return None;
        }
        Some(Box::new(TranslatedAt {
            faces,
            sources: resolved,
            pieces,
        }))
    }
}

/// A piece whose source answered: its range, where it starts in the
/// source, and which answer is its source's.
struct PieceAt {
    range: Range<usize>,
    source_start: usize,
    source: usize,
}

/// [`TranslatedSpans`] over one snapshot.
struct TranslatedAt {
    /// Every resolved source's faces, in turn.
    faces: Vec<String>,
    /// Each resolved source, with the offset of its faces.
    sources: Vec<(Box<dyn SpansAt>, usize)>,
    /// The pieces whose source answered, by where they start.
    pieces: Vec<PieceAt>,
}

impl SpansAt for TranslatedAt {
    fn faces(&self) -> &[String] {
        &self.faces
    }

    fn spans(&self, bytes: Range<usize>, out: &mut Vec<(Range<usize>, usize)>) {
        let first = self
            .pieces
            .partition_point(|piece| piece.range.end <= bytes.start);
        let mut found = Vec::new();
        for piece in &self.pieces[first..] {
            if piece.range.start >= bytes.end {
                break;
            }
            let cut = piece.range.start.max(bytes.start)..piece.range.end.min(bytes.end);
            if cut.is_empty() {
                continue;
            }
            let (at, offset) = &self.sources[piece.source];
            let asked = piece.source_start + (cut.start - piece.range.start)
                ..piece.source_start + (cut.end - piece.range.start);
            found.clear();
            at.spans(asked.clone(), &mut found);
            for (span, face) in found.drain(..) {
                // Cut to what was asked, whatever the source gave.
                let start = span.start.max(asked.start);
                let end = span.end.min(asked.end);
                if start >= end {
                    continue;
                }
                let moved = start - piece.source_start + piece.range.start
                    ..end - piece.source_start + piece.range.start;
                out.push((moved, face + offset));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::ops::Range;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use editor_text::{Snapshot, Text};

    use super::{Piece, TranslatedSpans};
    use crate::Layout;
    use crate::face::{Color, Face, FaceDef};
    use crate::scene::{
        FixedSpans, Rect, Scene, SpansAt, TextKey, TextRef, TextSpans, View, ViewId, spans_contract,
    };
    use crate::shaper::fake::CellShaper;

    /// The source.
    const SOURCE: &str = "one\ntwo\nthree\n";

    /// Two excerpts of it that overlap, 0..8 and 4..14, joined with a
    /// line feed between: `two` is shown twice.
    const JOINED: &str = "one\ntwo\n\ntwo\nthree\n";

    /// The joined text's snapshot, and its spans from `spans` over the
    /// source.
    fn joined(spans: Arc<dyn TextSpans>) -> (Snapshot, TranslatedSpans) {
        let source = Text::from(SOURCE).snapshot();
        let snapshot = Text::from(JOINED).snapshot();
        let pieces = vec![
            Piece {
                range: 9..19,
                source_start: 4,
                source: source.clone(),
                spans: Arc::clone(&spans),
            },
            Piece {
                range: 0..8,
                source_start: 0,
                source,
                spans,
            },
        ];
        let translated = TranslatedSpans::new(snapshot.revision(), pieces);
        (snapshot, translated)
    }

    /// What `spans` gives over `bytes` of `snapshot`.
    fn asked(
        spans: &TranslatedSpans,
        snapshot: &Snapshot,
        bytes: Range<usize>,
    ) -> Vec<(Range<usize>, usize)> {
        let mut out = Vec::new();
        spans.at(snapshot).expect("spans").spans(bytes, &mut out);
        out
    }

    #[test]
    fn a_span_of_a_source_is_drawn_at_the_same_text_in_every_piece_of_it() {
        let (snapshot, spans) = joined(Arc::new(FixedSpans::new(&["kw"], vec![(4..7, 0)])));
        assert_eq!(asked(&spans, &snapshot, 0..19), vec![(4..7, 0), (9..12, 0)]);
        // Asked for part of the second piece alone.
        assert_eq!(asked(&spans, &snapshot, 10..12), vec![(10..12, 0)]);
    }

    #[test]
    fn a_span_across_a_pieces_edge_is_cut_to_it() {
        // `o\nth` of the source: the end of the first piece, and inside
        // the second.
        let (snapshot, spans) = joined(Arc::new(FixedSpans::new(&["kw"], vec![(6..10, 0)])));
        assert_eq!(
            asked(&spans, &snapshot, 0..19),
            vec![(6..8, 0), (11..15, 0)]
        );
    }

    #[test]
    fn the_bytes_between_pieces_get_no_span() {
        let (snapshot, spans) = joined(Arc::new(FixedSpans::new(&["kw"], vec![(0..14, 0)])));
        assert_eq!(asked(&spans, &snapshot, 8..9), vec![]);
        assert_eq!(asked(&spans, &snapshot, 0..19), vec![(0..8, 0), (9..19, 0)]);
    }

    #[test]
    fn two_sources_faces_are_told_apart() {
        let source = Text::from(SOURCE).snapshot();
        let snapshot = Text::from(JOINED).snapshot();
        let piece = |range: Range<usize>, start: usize, face: &str| Piece {
            range,
            source_start: start,
            source: source.clone(),
            spans: Arc::new(FixedSpans::new(&[face], vec![(0..14, 0)])),
        };
        let spans = TranslatedSpans::new(
            snapshot.revision(),
            vec![piece(0..8, 0, "a"), piece(9..19, 4, "b")],
        );
        let at = spans.at(&snapshot).unwrap();
        assert_eq!(at.faces(), ["a".to_owned(), "b".to_owned()]);
        assert_eq!(asked(&spans, &snapshot, 0..19), vec![(0..8, 0), (9..19, 1)]);
    }

    /// Spans that count how often they are resolved.
    struct Counting(AtomicUsize, FixedSpans);

    impl TextSpans for Counting {
        fn at(&self, snapshot: &Snapshot) -> Option<Box<dyn SpansAt>> {
            self.0.fetch_add(1, Ordering::Relaxed);
            self.1.at(snapshot)
        }
    }

    #[test]
    fn a_source_of_two_pieces_is_resolved_once() {
        let counting = Arc::new(Counting(
            AtomicUsize::new(0),
            FixedSpans::new(&["kw"], vec![(4..7, 0)]),
        ));
        let (snapshot, spans) = joined(Arc::clone(&counting) as Arc<dyn TextSpans>);
        let at = spans.at(&snapshot).unwrap();
        assert_eq!(counting.0.load(Ordering::Relaxed), 1);
        // And its faces are listed once.
        assert_eq!(at.faces(), ["kw".to_owned()]);
    }

    #[test]
    fn a_snapshot_of_another_revision_draws_nothing() {
        let (_, spans) = joined(Arc::new(FixedSpans::new(&["kw"], vec![(4..7, 0)])));
        let mut text = Text::from(JOINED);
        text.replace(0..0, "x").unwrap();
        assert!(spans.at(&text.snapshot()).is_none());
    }

    #[test]
    fn a_text_whose_sources_draw_nothing_draws_nothing() {
        struct Nothing;
        impl TextSpans for Nothing {
            fn at(&self, _snapshot: &Snapshot) -> Option<Box<dyn SpansAt>> {
                None
            }
        }
        let (snapshot, spans) = joined(Arc::new(Nothing));
        assert!(spans.at(&snapshot).is_none());
    }

    #[test]
    fn translated_spans_keep_the_contract() {
        let fixed = FixedSpans::new(&["a", "b"], vec![(0..3, 0), (4..7, 1), (6..12, 0)]);
        let (snapshot, spans) = joined(Arc::new(fixed));
        assert_eq!(spans_contract::check(&spans, &snapshot), [""; 0]);
    }

    #[test]
    fn a_view_of_the_joined_text_draws_a_sources_face_at_both_copies() {
        let (snapshot, spans) = joined(Arc::new(FixedSpans::new(&["kw"], vec![(4..7, 0)])));
        let green = Color::rgb(0, 0xcc, 0);
        let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
        layout.define(&[FaceDef {
            name: "kw".to_owned(),
            face: Face {
                foreground: Some(green),
                ..Face::default()
            },
        }]);
        let scene = Scene {
            views: vec![View {
                id: ViewId(1),
                rect: Rect {
                    x: 0,
                    y: 0,
                    width: 100,
                    height: 160,
                },
                text: Some(TextRef::fixed(TextKey(1), snapshot).with_spans(Arc::new(spans))),
                ..View::default()
            }],
            ..Scene::default()
        };
        let frame = layout.frame(&scene);
        let rows = &frame.views[0].rows;
        // Rows 1 and 3 are `two`, each drawn whole in the face.
        for index in [1, 3] {
            assert_eq!(rows[index].runs.len(), 1, "row {index}");
            assert_eq!(rows[index].runs[0].1.foreground, green, "row {index}");
        }
        // And `one` is not.
        assert_ne!(rows[0].runs[0].1.foreground, green);
    }
}
