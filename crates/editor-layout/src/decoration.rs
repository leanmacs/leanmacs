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
//! A span names its face by a [`FaceId`] interned from the face's name
//! ([`Styles::intern`]). Merging says which faces cover which bytes
//! ([`merge`]): each styled run carries the faces over it in the order
//! their spans were given, which is the order of their sources and then
//! of each source's spans. Whoever collects the spans gives the sources
//! lowest layer first, so a run's faces are a stack, lowest first, and
//! what the stack comes to is [`face`](crate::face)'s rule
//! ([`Styles::style`]).
//!
//! A face changes shaping only through the font its stack resolves to. A
//! face that sets no attribute of the font is paint only: it shapes and
//! breaks nothing again. Where no face but the default one sets an
//! attribute of the font, every run is in the base font and no source is
//! asked for a segment's fonts ([`fonts_of`]).

use std::cell::RefCell;
use std::collections::HashMap;
use std::ops::Range;

use editor_text::{Selection, Shape, Snapshot};

use crate::face::{FaceDef, FaceId, Faces, Paint};
use crate::shaper::{FontId, Shaper};

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

/// What a stack of faces comes to for a shaper: the id of the font its
/// runs are shaped in, and what they are painted with.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Style {
    /// The font.
    pub font: FontId,
    /// The paint.
    pub paint: Paint,
}

/// The faces a layout holds, and what each stack of them asked for so far
/// comes to, kept until the definitions change. A font's id is its
/// shaper's for the shaper's life, so what is kept stays true of the
/// shaper it was asked with.
#[derive(Debug, Default)]
pub struct Styles {
    /// The faces.
    faces: Faces,
    /// The style of each stack asked for since the definitions were given.
    kept: RefCell<HashMap<Vec<FaceId>, Style>>,
}

impl Styles {
    /// The id of the face `name` ([`Faces::intern`]).
    pub fn intern(&mut self, name: &str) -> FaceId {
        self.faces.intern(name)
    }

    /// Takes `definitions` in place of the definitions held, and says
    /// whether they differ ([`Faces::define`]).
    pub fn define(&mut self, definitions: &[FaceDef]) -> bool {
        let changed = self.faces.define(definitions);
        if changed {
            self.kept.get_mut().clear();
        }
        changed
    }

    /// Whether a face other than the default face sets an attribute of
    /// the font ([`Faces::any_sets_font`]).
    pub fn any_sets_font(&self) -> bool {
        self.faces.any_sets_font()
    }

    /// What the faces `stack`, given lowest first, come to over the
    /// default face ([`Faces::resolve`]), with the font as `shaper`'s id
    /// for it.
    pub fn style<S: Shaper>(&self, shaper: &S, stack: &[FaceId]) -> Style {
        if let Some(style) = self.kept.borrow().get(stack) {
            return *style;
        }
        let resolved = self.faces.resolve(stack);
        let style = Style {
            font: shaper.font(&resolved.font),
            paint: resolved.paint,
        };
        self.kept.borrow_mut().insert(stack.to_vec(), style);
        style
    }
}

/// The selections of a view as a source: what each covers, drawn in the
/// selection face. A range with equal ends of an exclusive, an inclusive
/// or a block selection is a cursor and covers nothing here: it is drawn
/// as a cursor, so moving it changes no row's content. A range of a
/// line-wise selection covers its rows whatever its ends, so one with
/// equal ends is given like any other.
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
            let cursors = equal_ends_are_a_cursor(selection.shape());
            let ranges: Vec<_> = selection
                .ranges()
                .iter()
                .filter(|range| !cursors || range.anchor != range.head)
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

/// Whether a range with equal ends of a selection of `shape` is a cursor
/// and no more: it covers nothing (exclusive) or only the cell its cursor
/// is drawn on (inclusive, block). In any other shape what such a range
/// covers is `editor-text`'s to say (`Snapshot::extents`).
fn equal_ends_are_a_cursor(shape: Shape) -> bool {
    matches!(shape, Shape::Exclusive | Shape::Inclusive | Shape::Block)
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
    /// The faces over it, in the order of their spans: a stack, lowest
    /// first, when the spans were given lowest layer first.
    pub faces: Vec<FaceId>,
}

/// The styled runs of `bytes` under `spans`, given lowest layer first:
/// they cover `bytes` from start to end, a run with no face where no span
/// is, and neighbours with the same faces are one run. An empty range has
/// no run.
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

/// The spans of `bytes` of `snapshot` in a font other than `base`, the
/// default face's: the spans of `sources`, given lowest layer first,
/// merged, each run in the font its faces come to by `styles`. No source
/// is asked when no face but the default one sets an attribute of the
/// font.
pub fn fonts_of<S: Shaper>(
    sources: &[&dyn DecorationSource],
    snapshot: &Snapshot,
    bytes: Range<usize>,
    styles: &Styles,
    shaper: &S,
    base: FontId,
) -> Vec<(Range<usize>, FontId)> {
    if !styles.any_sets_font() {
        return Vec::new();
    }
    let mut spans = Vec::new();
    for source in sources {
        source.spans(snapshot, bytes.clone(), &mut spans);
    }
    font_spans(&merge(bytes, &spans), styles, shaper, base)
}

/// The spans of `runs` in a font other than `base`, by `styles`.
pub fn font_spans<S: Shaper>(
    runs: &[StyledRun],
    styles: &Styles,
    shaper: &S,
    base: FontId,
) -> Vec<(Range<usize>, FontId)> {
    runs.iter()
        .filter_map(|run| {
            let font = styles.style(shaper, &run.faces).font;
            (font != base).then(|| (run.bytes.clone(), font))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::ops::Range;

    use editor_text::{Selection, SelectionRange, Shape, Snapshot, Text};

    use super::{
        DecorationSource, FaceSpanSource, SelectionSource, Span, Style, StyledRun, Styles,
        font_spans, fonts_of, merge,
    };
    use crate::face::{Color, Face, FaceDef, FaceId, Paint};
    use crate::shaper::fake::CellShaper;
    use crate::shaper::{FontId, FontSpec, Shaper, Weight};

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

    /// The definition of `name` as `face`.
    fn def(name: &str, face: Face) -> FaceDef {
        FaceDef {
            name: name.to_owned(),
            face,
        }
    }

    /// A face of the weight `weight` and nothing else.
    fn weighing(weight: u16) -> Face {
        Face {
            weight: Some(Weight(weight)),
            ..Face::default()
        }
    }

    /// The default font at the weight `weight`.
    fn weight(weight: u16) -> FontSpec {
        FontSpec {
            weight: Weight(weight),
            ..FontSpec::default()
        }
    }

    #[test]
    fn a_stack_of_faces_comes_to_the_shapers_font_for_what_it_resolves_to_and_its_paint() {
        let shaper = CellShaper::new(10.0, 16.0);
        let mut styles = Styles::default();
        let red = Color::rgb(9, 0, 0);
        styles.define(&[
            def("heavy", weighing(900)),
            def(
                "red",
                Face {
                    foreground: Some(red),
                    ..Face::default()
                },
            ),
        ]);
        let (heavy, red_face) = (styles.intern("heavy"), styles.intern("red"));
        // No face: the default font, font 0 while no default face is
        // defined, and the base paint.
        let plain = styles.style(&shaper, &[]);
        assert_eq!(
            plain,
            Style {
                font: FontId(0),
                paint: Paint::default()
            }
        );
        let both = styles.style(&shaper, &[heavy, red_face]);
        assert_eq!(both.font, shaper.font(&weight(900)));
        assert_eq!(both.paint.foreground, red);
        // A face that sets only paint is in the font of the stack under it.
        assert_eq!(styles.style(&shaper, &[red_face]).font, FontId(0));
        // The same stack again is the same style, and a change of the
        // definitions is seen by a stack already asked for.
        assert_eq!(styles.style(&shaper, &[heavy, red_face]), both);
        assert!(styles.define(&[def("heavy", weighing(100))]));
        let lighter = styles.style(&shaper, &[heavy, red_face]);
        assert_eq!(lighter.font, shaper.font(&weight(100)));
        assert_eq!(lighter.paint, Paint::default());
        // The same definitions again are no change.
        assert!(!styles.define(&[def("heavy", weighing(100))]));
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
    fn a_line_wise_range_with_equal_ends_covers_its_row() {
        let text = "abcdef\nghi";
        let snapshot = Text::from(text).snapshot();
        let source = |shape: Shape| {
            let selections =
                [Selection::shaped(shape, vec![SelectionRange::new(1, 1)], 0).unwrap()];
            SelectionSource::new(&snapshot, &selections, FaceId(7))
        };
        // Line-wise, a range covers its row whatever its ends.
        assert_eq!(
            asked(&source(Shape::Line), text, 0..10),
            vec![span(0..7, 7)]
        );
        // In the other shapes a range with equal ends is a cursor.
        for shape in [Shape::Exclusive, Shape::Inclusive, Shape::Block] {
            assert_eq!(asked(&source(shape), text, 0..10), vec![], "{shape:?}");
        }
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
    fn a_run_is_in_the_font_of_the_highest_of_its_faces_that_sets_one() {
        let shaper = CellShaper::new(10.0, 16.0);
        let mut styles = Styles::default();
        styles.define(&[
            def("light", weighing(100)),
            def("heavy", weighing(900)),
            def("plain", Face::default()),
        ]);
        let face = |styles: &mut Styles, bytes: Range<usize>, name: &str| Span {
            bytes,
            face: styles.intern(name),
        };
        // Lowest first: light over 0..6, heavy over 2..4, plain over 3..8.
        let spans = [
            face(&mut styles, 0..6, "light"),
            face(&mut styles, 2..4, "heavy"),
            face(&mut styles, 3..8, "plain"),
        ];
        let (light, heavy) = (shaper.font(&weight(100)), shaper.font(&weight(900)));
        let base = FontId(0);
        // Where both are, the later one's; a face that sets no font
        // leaves the font of the faces under it; and a run in the base
        // font is not given.
        assert_eq!(
            font_spans(&merge(0..10, &spans), &styles, &shaper, base),
            vec![(0..2, light), (2..3, heavy), (3..4, heavy), (4..6, light)]
        );
        // Given the other way up, the light face is over the heavy one.
        let reversed: Vec<Span> = spans.iter().rev().cloned().collect();
        assert_eq!(
            font_spans(&merge(0..10, &reversed), &styles, &shaper, base),
            vec![(0..2, light), (2..3, light), (3..4, light), (4..6, light)]
        );
        // Under another base, the runs in it are the ones left out.
        assert_eq!(
            font_spans(&merge(0..10, &spans), &styles, &shaper, light),
            vec![(2..3, heavy), (3..4, heavy), (6..8, base), (8..10, base)]
        );
    }

    /// A source that counts how often it is asked.
    struct Asked(Cell<usize>);

    impl DecorationSource for Asked {
        fn spans(&self, _snapshot: &Snapshot, _bytes: Range<usize>, _out: &mut Vec<Span>) {
            self.0.set(self.0.get() + 1);
        }
    }

    #[test]
    fn no_source_is_asked_for_fonts_while_no_face_but_the_default_sets_one() {
        let shaper = CellShaper::new(10.0, 16.0);
        let snapshot = Text::from("abcdef").snapshot();
        let asked = Asked(Cell::new(0));
        let fonts = |styles: &Styles| {
            let base = styles.style(&shaper, &[]).font;
            fonts_of(&[&asked], &snapshot, 0..6, styles, &shaper, base)
        };
        let mut styles = Styles::default();
        fonts(&styles);
        styles.define(&[
            def("default", weighing(900)),
            def(
                "red",
                Face {
                    foreground: Some(Color::rgb(9, 0, 0)),
                    ..Face::default()
                },
            ),
        ]);
        fonts(&styles);
        assert_eq!(asked.0.get(), 0);
        styles.define(&[def("heavy", weighing(900))]);
        fonts(&styles);
        assert_eq!(asked.0.get(), 1);
    }
}
