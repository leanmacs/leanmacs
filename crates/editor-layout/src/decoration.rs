//! Decorations: spans of a snapshot drawn in a face, from sources, merged
//! into styled runs.
//!
//! A source ([`DecorationSource`]) gives the spans of a range of a
//! snapshot, and is asked only for the rows layout lays out, so what a
//! source costs is in proportion to what is visible. The first two are
//! the selections ([`SelectionSource`]) and the faces Lean names in the
//! scene ([`FaceSpanSource`]). Tree-sitter highlights become a third
//! source (syntax-tree-sitter), with no change here.
//!
//! A span names its face by a [`FaceId`] that a [`FaceTable`] interns from
//! the face's name. What a face holds and how faces that overlap are
//! merged into attributes are the display pipeline's phase 2; here
//! merging only says which faces cover which bytes ([`merge`]): each
//! styled run carries the faces over it, in the order of their sources
//! and then of their spans, and no precedence is decided.
//!
//! A face changes shaping only through the font it resolves to
//! ([`FaceTable::font`]). In phase 1 every face is in the default font
//! unless a test sets another, so decorations and selections are
//! paint-only: they shape and break nothing again.

use std::collections::HashMap;
use std::ops::Range;

use editor_text::{Selection, Snapshot};

use crate::shaper::FontId;

/// The name of the face the selections source draws in.
pub const SELECTION_FACE: &str = "selection";

/// Which face: a number a [`FaceTable`] gave a face's name.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct FaceId(pub u32);

/// A span of a snapshot drawn in a face.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Span {
    /// Its bytes in the snapshot.
    pub bytes: Range<usize>,
    /// Its face.
    pub face: FaceId,
}

/// A source of spans.
pub trait DecorationSource {
    /// Adds to `out`, in this source's order, the spans of `snapshot` that
    /// cover any of `bytes`, cut to it.
    fn spans(&self, snapshot: &Snapshot, bytes: Range<usize>, out: &mut Vec<Span>);
}

/// The faces by name, and the font each resolves to.
#[derive(Debug, Clone, Default)]
pub struct FaceTable {
    /// The id of each name interned.
    ids: HashMap<String, FaceId>,
    /// The name of each id, by id.
    names: Vec<String>,
    /// The font of each face that is not in the default font.
    fonts: HashMap<FaceId, FontId>,
}

impl FaceTable {
    /// The id of the face `name`, given it the first time it is asked.
    pub fn intern(&mut self, name: &str) -> FaceId {
        if let Some(&id) = self.ids.get(name) {
            return id;
        }
        let id = FaceId(u32::try_from(self.names.len()).unwrap_or(u32::MAX));
        self.names.push(name.to_owned());
        self.ids.insert(name.to_owned(), id);
        id
    }

    /// The name of the face `id`.
    pub fn name(&self, id: FaceId) -> Option<&str> {
        self.names
            .get(usize::try_from(id.0).ok()?)
            .map(String::as_str)
    }

    /// Resolves the face `name` to `font` from now on. Faces resolve to
    /// fonts in phase 2; this is for tests until then.
    pub fn set_font(&mut self, name: &str, font: FontId) {
        let id = self.intern(name);
        self.fonts.insert(id, font);
    }

    /// The font a run covered by `faces` is shaped in: that of the first
    /// face that names one, the default font when none does. Phase 2's
    /// merge of faces replaces this rule.
    pub fn font(&self, faces: &[FaceId]) -> FontId {
        faces
            .iter()
            .find_map(|face| self.fonts.get(face).copied())
            .unwrap_or_default()
    }
}

/// The selections of a view as a source: what each covers, drawn in the
/// selection face. A range with equal ends is a cursor and covers nothing
/// here: it is drawn as a cursor, so moving it changes no row's content.
#[derive(Debug, Clone, Default)]
pub struct SelectionSource {
    /// What the selections cover, in order.
    extents: Vec<Range<usize>>,
    /// The selection face.
    face: Option<FaceId>,
}

impl SelectionSource {
    /// The source of `selections` in `snapshot`, drawn in `face`. A
    /// selection with an end that is not a position of `snapshot` is left
    /// out.
    pub fn new(snapshot: &Snapshot, selections: &[Selection], face: FaceId) -> Self {
        let mut extents = Vec::new();
        for selection in selections {
            let ranges: Vec<_> = selection
                .ranges()
                .iter()
                .filter(|range| range.anchor != range.head)
                .copied()
                .collect();
            let Some(selection) = Selection::shaped(selection.shape(), ranges, 0) else {
                continue;
            };
            if let Some(covered) = snapshot.extents(&selection) {
                extents.extend(covered.into_iter().filter(|extent| !extent.is_empty()));
            }
        }
        Self {
            extents,
            face: Some(face),
        }
    }
}

/// `spans` cut to `bytes`, those that cover none of it left out, added to
/// `out` in order.
fn cut_to<'a>(
    spans: impl Iterator<Item = (&'a Range<usize>, FaceId)>,
    bytes: &Range<usize>,
    out: &mut Vec<Span>,
) {
    for (span, face) in spans {
        let start = span.start.max(bytes.start);
        let end = span.end.min(bytes.end);
        if start < end {
            out.push(Span {
                bytes: start..end,
                face,
            });
        }
    }
}

impl DecorationSource for SelectionSource {
    fn spans(&self, _snapshot: &Snapshot, bytes: Range<usize>, out: &mut Vec<Span>) {
        if let Some(face) = self.face {
            cut_to(
                self.extents.iter().map(|extent| (extent, face)),
                &bytes,
                out,
            );
        }
    }
}

/// Spans given as data: the decorations of a view in the scene.
#[derive(Debug, Clone, Default)]
pub struct FaceSpanSource {
    /// The spans, in the order given.
    spans: Vec<Span>,
}

impl FaceSpanSource {
    /// The source of `spans`.
    pub fn new(spans: Vec<Span>) -> Self {
        Self { spans }
    }
}

impl DecorationSource for FaceSpanSource {
    fn spans(&self, _snapshot: &Snapshot, bytes: Range<usize>, out: &mut Vec<Span>) {
        cut_to(
            self.spans.iter().map(|span| (&span.bytes, span.face)),
            &bytes,
            out,
        );
    }
}

/// A run of bytes covered by the same faces.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct StyledRun {
    /// Its bytes.
    pub bytes: Range<usize>,
    /// The faces over it, in the order of their spans.
    pub faces: Vec<FaceId>,
}

/// The styled runs of `bytes` under `spans`, given in source order and
/// then span order: they cover `bytes` from start to end, a run with no
/// face where no span is, and neighbours with the same faces are one run.
/// An empty range has no run.
pub fn merge(bytes: Range<usize>, spans: &[Span]) -> Vec<StyledRun> {
    let mut cuts: Vec<usize> = spans
        .iter()
        .flat_map(|span| [span.bytes.start, span.bytes.end])
        .filter(|cut| bytes.contains(cut))
        .chain([bytes.start, bytes.end])
        .collect();
    cuts.sort_unstable();
    cuts.dedup();
    let mut runs: Vec<StyledRun> = Vec::new();
    for pair in cuts.windows(2) {
        let (start, end) = (pair[0], pair[1]);
        let faces: Vec<FaceId> = spans
            .iter()
            .filter(|span| span.bytes.start <= start && end <= span.bytes.end)
            .map(|span| span.face)
            .collect();
        match runs.last_mut() {
            Some(last) if last.faces == faces => last.bytes.end = end,
            _ => runs.push(StyledRun {
                bytes: start..end,
                faces,
            }),
        }
    }
    runs
}

/// The spans of `runs` in a font other than the default, by `faces`.
pub fn font_spans(runs: &[StyledRun], faces: &FaceTable) -> Vec<(Range<usize>, FontId)> {
    if faces.fonts.is_empty() {
        return Vec::new();
    }
    runs.iter()
        .filter_map(|run| {
            let font = faces.font(&run.faces);
            (font != FontId::default()).then(|| (run.bytes.clone(), font))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use std::ops::Range;

    use editor_text::{Selection, SelectionRange, Shape, Text};

    use super::{
        DecorationSource, FaceId, FaceSpanSource, FaceTable, SelectionSource, Span, StyledRun,
        font_spans, merge,
    };
    use crate::shaper::FontId;

    /// The spans `source` gives for `bytes` of `text`.
    fn asked(source: &dyn DecorationSource, text: &str, bytes: Range<usize>) -> Vec<Span> {
        let mut out = Vec::new();
        source.spans(&Text::from(text).snapshot(), bytes, &mut out);
        out
    }

    /// A span of `bytes` in face `face`.
    fn span(bytes: Range<usize>, face: u32) -> Span {
        Span {
            bytes,
            face: FaceId(face),
        }
    }

    #[test]
    fn a_face_name_is_interned_once() {
        let mut faces = FaceTable::default();
        let keyword = faces.intern("keyword");
        assert_eq!(faces.intern("keyword"), keyword);
        assert_ne!(faces.intern("string"), keyword);
        assert_eq!(faces.name(keyword), Some("keyword"));
    }

    #[test]
    fn a_selection_covers_its_extent_and_a_cursor_covers_nothing() {
        let text = "abcdef\nghi";
        let snapshot = Text::from(text).snapshot();
        let selections = [
            Selection::new(
                vec![SelectionRange::new(1, 3), SelectionRange::new(5, 5)],
                0,
            )
            .unwrap(),
            Selection::shaped(Shape::Inclusive, vec![SelectionRange::new(8, 8)], 0).unwrap(),
            Selection::shaped(Shape::Line, vec![SelectionRange::new(8, 9)], 0).unwrap(),
        ];
        let source = SelectionSource::new(&snapshot, &selections, FaceId(7));
        assert_eq!(
            asked(&source, text, 0..10),
            vec![span(1..3, 7), span(7..10, 7)]
        );
        // Asked for part of the text, cut to it.
        assert_eq!(
            asked(&source, text, 2..8),
            vec![span(2..3, 7), span(7..8, 7)]
        );
        assert_eq!(asked(&source, text, 3..7), vec![]);
    }

    #[test]
    fn a_selection_with_an_end_off_the_text_is_left_out() {
        let snapshot = Text::from("ab").snapshot();
        let selections = [Selection::new(vec![SelectionRange::new(0, 9)], 0).unwrap()];
        let source = SelectionSource::new(&snapshot, &selections, FaceId(7));
        assert_eq!(asked(&source, "ab", 0..2), vec![]);
    }

    #[test]
    fn face_spans_are_given_cut_to_the_range_asked_in_their_order() {
        let source = FaceSpanSource::new(vec![span(4..9, 2), span(0..5, 1)]);
        assert_eq!(
            asked(&source, "abcdefghij", 3..6),
            vec![span(4..6, 2), span(3..5, 1)]
        );
        assert_eq!(asked(&source, "abcdefghij", 9..10), vec![]);
    }

    #[test]
    fn spans_merge_into_runs_that_carry_every_face_over_them_in_order() {
        let runs = merge(0..8, &[span(2..6, 2), span(0..4, 1)]);
        let run = |bytes: Range<usize>, faces: &[u32]| StyledRun {
            bytes,
            faces: faces.iter().map(|&face| FaceId(face)).collect(),
        };
        assert_eq!(
            runs,
            vec![
                run(0..2, &[1]),
                run(2..4, &[2, 1]),
                run(4..6, &[2]),
                run(6..8, &[])
            ]
        );
        assert_eq!(merge(3..3, &[span(0..4, 1)]), vec![]);
        // Neighbours with the same faces are one run.
        assert_eq!(
            merge(0..4, &[span(0..2, 1), span(2..4, 1)]),
            vec![run(0..4, &[1])]
        );
    }

    #[test]
    fn a_run_is_in_the_font_of_the_first_of_its_faces_that_names_one() {
        let mut faces = FaceTable::default();
        let plain = faces.intern("plain");
        let tall = faces.intern("tall");
        faces.set_font("tall", FontId(1));
        assert_eq!(faces.font(&[plain]), FontId(0));
        assert_eq!(faces.font(&[plain, tall]), FontId(1));
        let runs = merge(
            0..6,
            &[
                Span {
                    bytes: 2..4,
                    face: tall,
                },
                Span {
                    bytes: 0..6,
                    face: plain,
                },
            ],
        );
        assert_eq!(font_spans(&runs, &faces), vec![(2..4, FontId(1))]);
    }
}
