//! The frame: an immutable plain-data value of what to draw, built from a
//! scene.
//!
//! For each view, the visual rows it shows from its scroll anchor, as many
//! as fit its rectangle, each with its `y`, its glyphs (shared with the
//! line store, never copied), its styled runs and a content hash; and the
//! geometry of its cursors and of its selections. Geometry is in pixels
//! from the view's top left.
//!
//! A row's hash covers its glyphs, its runs and its height, all relative to
//! the row's start: never its `y` or an absolute offset. So scrolling, and
//! an edit on another row, leave it as it was, and a renderer reuses what it
//! built for a row whose hash it has seen. A cursor is not part of any row,
//! so moving one changes no hash.
//!
//! Offsets in the scene that are not positions of the view's snapshot (a
//! marker read at a newer revision than the snapshot) are moved back to the
//! nearest position at or before them, and past the end to the end.
//!
//! [`Frame::describe`] is the frame as text, for tests: geometry, glyph ids
//! and face ids, no hash.

use std::fmt::Write as _;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::ops::Range;
use std::sync::Arc;

use editor_text::{Selection, SelectionRange, Snapshot};

use crate::Layout;
use std::collections::HashMap;

use crate::cache::state;
use crate::decoration::{
    DecorationSource, FaceId, FaceSpanSource, SELECTION_FACE, SelectionSource, Span, fonts_of,
    merge,
};
use crate::query::{Visual, Walker};
use crate::scene::{CursorShape, Rect, Scene, TextKey, View, ViewId};
use crate::shaper::{Shaper, VisualLine};
use crate::wrap::Outcome;

/// A rectangle in pixels from a view's top left.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Area {
    /// From the left.
    pub x: f32,
    /// From the top.
    pub y: f32,
    /// Across.
    pub width: f32,
    /// Down.
    pub height: f32,
}

/// One visual row of a view's frame.
#[derive(Debug, Clone, PartialEq)]
pub struct FrameRow {
    /// Its top, from the view's top.
    pub y: f32,
    /// How far down it is.
    pub height: f32,
    /// Its baseline, from its top.
    pub baseline: f32,
    /// Its bytes in the view's snapshot, without its line break.
    pub bytes: Range<usize>,
    /// Its glyphs, as the line store holds them. Their clusters are bytes of
    /// the segment's expanded text; `line.bytes` is the row's part of it.
    pub line: Arc<VisualLine>,
    /// Its styled runs, as bytes of the expanded text from the row's start
    /// (`line.bytes.start`), with the faces over each.
    pub runs: Vec<(Range<usize>, Vec<FaceId>)>,
    /// The content hash.
    pub hash: u64,
}

/// One cursor of a view.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CursorBox {
    /// The cell it is on: the glyph at its position, or past a line's last
    /// glyph one default advance.
    pub area: Area,
    /// Its shape.
    pub shape: CursorShape,
    /// Its face.
    pub face: FaceId,
}

/// The frame of one view.
#[derive(Debug, Clone, PartialEq)]
pub struct ViewFrame {
    /// Which view.
    pub id: ViewId,
    /// Where it is in the frame.
    pub rect: Rect,
    /// Its rows, top to bottom.
    pub rows: Vec<FrameRow>,
    /// Its cursors on the rows shown: the head of every range of every
    /// selection.
    pub cursors: Vec<CursorBox>,
    /// What its selections cover on the rows shown, one area per row and
    /// span.
    pub selections: Vec<Area>,
}

/// What to draw: every view, in drawing order.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Frame {
    /// The views.
    pub views: Vec<ViewFrame>,
}

impl Frame {
    /// The frame as text: per view its rectangle, then per row its
    /// geometry, its glyphs as `id@x` and its runs, then its cursors and
    /// selections. No hash.
    pub fn describe(&self) -> String {
        let mut out = String::new();
        for view in &self.views {
            let rect = view.rect;
            let _ = writeln!(
                out,
                "view {} rect {} {} {} {}",
                view.id.0, rect.x, rect.y, rect.width, rect.height
            );
            for row in &view.rows {
                let _ = write!(
                    out,
                    "  row y {} height {} baseline {} bytes {}..{} glyphs",
                    row.y, row.height, row.baseline, row.bytes.start, row.bytes.end
                );
                for glyph in &row.line.glyphs {
                    let _ = write!(out, " {}@{}", glyph.id, glyph.x);
                }
                out.push_str(" runs");
                for (bytes, faces) in &row.runs {
                    let faces: Vec<String> = faces.iter().map(|face| face.0.to_string()).collect();
                    let _ = write!(out, " {}..{}:[{}]", bytes.start, bytes.end, faces.join(","));
                }
                out.push('\n');
            }
            for cursor in &view.cursors {
                let shape = match cursor.shape {
                    CursorShape::Block => "block",
                    CursorShape::Bar => "bar",
                    CursorShape::Underline => "underline",
                    CursorShape::Hollow => "hollow",
                };
                let area = cursor.area;
                let _ = writeln!(
                    out,
                    "  cursor {shape} face {} at {} {} {} {}",
                    cursor.face.0, area.x, area.y, area.width, area.height
                );
            }
            for area in &view.selections {
                let _ = writeln!(
                    out,
                    "  selection at {} {} {} {}",
                    area.x, area.y, area.width, area.height
                );
            }
        }
        out
    }
}

/// The nearest position of `snapshot` at or before `offset`; its end for an
/// offset past it.
pub fn at_or_before(snapshot: &Snapshot, offset: usize) -> usize {
    let mut at = offset.min(snapshot.len());
    while !snapshot.is_char_boundary(at) {
        at -= 1;
    }
    at
}

impl<S: Shaper> Layout<S> {
    /// Lays `scene` out into a frame, and drops what is kept of every text
    /// it does not name.
    pub fn frame(&mut self, scene: &Scene) -> Frame {
        let frame = Frame {
            views: scene
                .views
                .iter()
                .map(|view| self.view_frame(view, &[]))
                .collect(),
        };
        let named: Vec<TextKey> = scene
            .views
            .iter()
            .filter_map(|view| view.text.as_ref().map(|text| text.key))
            .collect();
        self.texts.retain(|key, _| named.contains(key));
        frame
    }

    /// The frame of `view`, with `extra` sources of spans after its
    /// selections and its decorations.
    pub(crate) fn view_frame(&mut self, view: &View, extra: &[&dyn DecorationSource]) -> ViewFrame {
        let mut frame = ViewFrame {
            id: view.id,
            rect: view.rect,
            rows: Vec::new(),
            cursors: Vec::new(),
            selections: Vec::new(),
        };
        let Some(text) = &view.text else {
            return frame;
        };
        let snapshot = &text.snapshot;
        let cursor_face = self.faces.intern(&view.cursor.face);
        let selection_face = self.faces.intern(SELECTION_FACE);
        let decorations: Vec<Span> = view
            .decorations
            .iter()
            .map(|decoration| {
                let start = at_or_before(snapshot, decoration.start);
                Span {
                    bytes: start..at_or_before(snapshot, decoration.stop).max(start),
                    face: self.faces.intern(&decoration.face),
                }
            })
            .collect();
        let selections: Vec<Selection> = view
            .selections
            .iter()
            .filter_map(|selection| moved_back(snapshot, selection))
            .collect();
        let selection_source = SelectionSource::new(snapshot, &selections, selection_face);
        let face_source = FaceSpanSource::new(decorations);
        let mut sources: Vec<&dyn DecorationSource> = vec![&face_source];
        sources.extend_from_slice(extra);
        // Every source's spans of `bytes`, the selections' first.
        let spans_of = |bytes: Range<usize>| {
            let mut spans = Vec::new();
            selection_source.spans(snapshot, bytes.clone(), &mut spans);
            let selected = spans.len();
            for source in &sources {
                source.spans(snapshot, bytes.clone(), &mut spans);
            }
            (spans, selected)
        };
        let faces = &self.faces;
        let fonts = |bytes: Range<usize>| {
            let mut all: Vec<&dyn DecorationSource> = vec![&selection_source];
            all.extend_from_slice(&sources);
            fonts_of(&all, snapshot, bytes, faces)
        };
        let mut held = state(
            &mut self.texts,
            text,
            self.tab_width,
            Some(view.rect.width as f32),
        );
        let state = &mut *held;
        let mut seen: HashMap<(usize, usize), Outcome> = HashMap::new();
        let mut walker = Walker {
            shaper: &self.shaper,
            wrap: &mut state.wrap,
            fonts: &fonts,
            outcome: &mut |row, segment, outcome| {
                seen.entry((row, segment)).or_insert(outcome);
            },
        };
        let anchor = at_or_before(snapshot, view.scroll);
        let shown = walker
            .rows_shown(view.rect.height as f32, anchor)
            .unwrap_or_default();
        let mut y = 0.0;
        for &visual in &shown {
            let Some(entry) = walker.entry(visual.row, visual.segment) else {
                continue;
            };
            let Some(line) = entry.lines().get(visual.line).cloned() else {
                continue;
            };
            let range = walker.range(visual);
            let bytes = range.start..range.stop;
            let row_start = snapshot.row_range(visual.row).map_or(0, |row| row.start);
            let (spans, selected) = spans_of(bytes.clone());
            for span in &spans[..selected] {
                let left = entry.x_of(visual.line, span.bytes.start - row_start);
                let right = entry.x_of(visual.line, span.bytes.end - row_start);
                frame.selections.push(Area {
                    x: left,
                    y,
                    width: right - left,
                    height: line.height,
                });
            }
            let column = |offset: usize| entry.column(offset - row_start) - line.bytes.start;
            let runs: Vec<(Range<usize>, Vec<FaceId>)> = merge(bytes.clone(), &spans)
                .into_iter()
                .map(|run| (column(run.bytes.start)..column(run.bytes.end), run.faces))
                .collect();
            frame.rows.push(FrameRow {
                y,
                height: line.height,
                baseline: line.baseline,
                bytes,
                hash: hash(&line, &runs),
                line: Arc::clone(&line),
                runs,
            });
            y += line.height;
        }
        // The cursors on the rows shown.
        let last = shown.last().copied().unwrap_or(Visual {
            row: 0,
            segment: 0,
            line: 0,
        });
        let from = frame.rows.first().map_or(0, |row| row.bytes.start);
        let to = snapshot
            .row_range(last.row)
            .map_or(snapshot.len(), |row| row.end);
        let advance = self.shaper.metrics().advance;
        for range in selections.iter().flat_map(|selection| selection.ranges()) {
            let head = range.head;
            if shown.is_empty() || head < from || head > to {
                continue;
            }
            let Ok((visual, x)) = walker.locate(head) else {
                continue;
            };
            let Some(index) = shown.iter().position(|shown| *shown == visual) else {
                continue;
            };
            let row = &frame.rows[index];
            let row_start = snapshot.row_range(visual.row).map_or(0, |row| row.start);
            let width = walker
                .entry(visual.row, visual.segment)
                .and_then(|entry| {
                    let column = entry.column(head - row_start);
                    row.line
                        .glyphs
                        .iter()
                        .find(|glyph| glyph.cluster == column)
                        .map(|glyph| glyph.advance)
                })
                .unwrap_or(advance);
            frame.cursors.push(CursorBox {
                area: Area {
                    x,
                    y: row.y,
                    width,
                    height: row.height,
                },
                shape: view.cursor.shape,
                face: cursor_face,
            });
        }
        state.sources = Some((selection_source.clone(), face_source.clone()));
        self.counters.add(&seen);
        frame
    }
}

/// `selection` with each end moved back to a position of `snapshot`.
fn moved_back(snapshot: &Snapshot, selection: &Selection) -> Option<Selection> {
    let ranges = selection
        .ranges()
        .iter()
        .map(|range| {
            SelectionRange::new(
                at_or_before(snapshot, range.anchor),
                at_or_before(snapshot, range.head),
            )
        })
        .collect();
    Selection::shaped(selection.shape(), ranges, selection.primary())
}

/// The content hash of a row of `line` with `runs`: its glyphs and runs
/// relative to its start, and its height.
fn hash(line: &VisualLine, runs: &[(Range<usize>, Vec<FaceId>)]) -> u64 {
    let mut hasher = DefaultHasher::new();
    line.height.to_bits().hash(&mut hasher);
    line.baseline.to_bits().hash(&mut hasher);
    for glyph in &line.glyphs {
        (glyph.id, glyph.font, glyph.cluster - line.bytes.start).hash(&mut hasher);
        (glyph.x.to_bits(), glyph.advance.to_bits()).hash(&mut hasher);
    }
    runs.hash(&mut hasher);
    hasher.finish()
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::hash::{DefaultHasher, Hash, Hasher};
    use std::ops::Range;

    use editor_text::{Selection, SelectionRange, Snapshot, Text};

    use super::{Area, Frame, FrameRow, ViewFrame};
    use crate::Layout;
    use crate::decoration::{DecorationSource, Span};
    use crate::scene::{
        Cursor, CursorShape, Decoration, Rect, Scene, TextKey, TextRef, View, ViewId,
    };
    use crate::shaper::FontId;
    use crate::shaper::fake::CellShaper;

    /// A layout on cells 10 by 16, with a font 1 of lines 32 tall that the
    /// face `tall` is in.
    fn layout() -> Layout<CellShaper> {
        let mut layout = Layout::new(CellShaper::new(10.0, 16.0).with_font(FontId(1), 10.0, 32.0));
        layout.faces_mut().set_font("tall", FontId(1));
        layout
    }

    /// A key for `text`: one per text, as the binding gives one per
    /// document.
    fn key(text: &str) -> TextKey {
        let mut hasher = DefaultHasher::new();
        text.hash(&mut hasher);
        TextKey(hasher.finish())
    }

    /// A view of `text` `columns` cells wide and `height` pixels tall,
    /// scrolled to `scroll`, with the cursors and selections `ranges`.
    fn view(
        text: &str,
        columns: u32,
        height: u32,
        scroll: usize,
        ranges: &[(usize, usize)],
    ) -> View {
        View {
            id: ViewId(1),
            rect: Rect {
                x: 0,
                y: 0,
                width: columns * 10,
                height,
            },
            text: Some(TextRef::fixed(key(text), Text::from(text).snapshot())),
            scroll,
            selections: if ranges.is_empty() {
                vec![]
            } else {
                vec![
                    Selection::new(
                        ranges
                            .iter()
                            .map(|&(anchor, head)| SelectionRange::new(anchor, head))
                            .collect(),
                        0,
                    )
                    .unwrap(),
                ]
            },
            cursor: Cursor {
                shape: CursorShape::Block,
                face: "cursor".to_owned(),
            },
            decorations: vec![],
            status: vec![],
        }
    }

    /// The frame of `view` alone.
    fn frame(layout: &mut Layout<CellShaper>, view: View) -> ViewFrame {
        let scene = Scene {
            views: vec![view],
            ..Scene::default()
        };
        layout.frame(&scene).views.remove(0)
    }

    /// The tops of `rows`.
    fn tops(rows: &[FrameRow]) -> Vec<f32> {
        rows.iter().map(|row| row.y).collect()
    }

    #[test]
    fn rows_of_different_heights_stack() {
        let mut layout = layout();
        let mut tall = view("ab\ncd\nef", 4, 64, 0, &[]);
        tall.decorations = vec![Decoration {
            start: 3,
            stop: 5,
            face: "tall".to_owned(),
        }];
        let rows = frame(&mut layout, tall.clone()).rows;
        assert_eq!(
            rows.iter().map(|row| row.height).collect::<Vec<_>>(),
            vec![16.0, 32.0, 16.0]
        );
        assert_eq!(tops(&rows), vec![0.0, 16.0, 48.0]);
        // The rows that fit are counted by their heights: 63 pixels hold
        // the first two.
        tall.rect.height = 63;
        assert_eq!(frame(&mut layout, tall).rows.len(), 2);
    }

    #[test]
    fn scrolling_by_n_lines_starts_the_frame_n_rows_down() {
        let text = "abcdefgh\nij\nklmnopqrst\nuv";
        let mut layout = layout();
        let at_top = frame(&mut layout, view(text, 4, 160, 0, &[]));
        let snapshot = TextRef::fixed(key(text), Text::from(text).snapshot());
        for n in 1..=5 {
            let moved = layout.lines_from(&snapshot, 40.0, 0, n, Some(0.0)).unwrap();
            let scrolled = frame(&mut layout, view(text, 4, 160, moved.position, &[]));
            let expected = &at_top.rows[usize::try_from(n).unwrap()];
            let first = &scrolled.rows[0];
            assert_eq!(first.bytes, expected.bytes, "{n} lines down");
            assert_eq!(first.line, expected.line);
            assert_eq!(first.hash, expected.hash);
            assert_eq!(first.y, 0.0);
        }
    }

    #[test]
    fn the_cursor_at_a_line_end_sits_after_its_last_glyph() {
        let mut layout = layout();
        let mut area = |text: &str, columns: u32, head: usize| {
            frame(&mut layout, view(text, columns, 64, 0, &[(head, head)])).cursors[0].area
        };
        assert_eq!(
            area("abc", 10, 3),
            Area {
                x: 30.0,
                y: 0.0,
                width: 10.0,
                height: 16.0
            }
        );
        // The end of a wrapped line, on its last visual row.
        assert_eq!(
            area("abcdef", 4, 6),
            Area {
                x: 20.0,
                y: 16.0,
                width: 10.0,
                height: 16.0
            }
        );
        // The wrap point is the start of the later row.
        assert_eq!(
            area("abcdef", 4, 4),
            Area {
                x: 0.0,
                y: 16.0,
                width: 10.0,
                height: 16.0
            }
        );
    }

    #[test]
    fn every_range_of_every_selection_has_a_cursor_and_its_extent() {
        let mut layout = layout();
        let mut two = view("abcdef\nghij", 10, 64, 0, &[(1, 3)]);
        two.selections.push(
            Selection::new(
                vec![SelectionRange::new(9, 9), SelectionRange::new(4, 6)],
                0,
            )
            .unwrap(),
        );
        let frame = frame(&mut layout, two);
        let heads: Vec<(f32, f32)> = frame
            .cursors
            .iter()
            .map(|cursor| (cursor.area.x, cursor.area.y))
            .collect();
        assert_eq!(heads, vec![(30.0, 0.0), (60.0, 0.0), (20.0, 16.0)]);
        assert_eq!(
            frame.selections,
            vec![
                Area {
                    x: 10.0,
                    y: 0.0,
                    width: 20.0,
                    height: 16.0
                },
                Area {
                    x: 40.0,
                    y: 0.0,
                    width: 20.0,
                    height: 16.0
                },
            ]
        );
    }

    #[test]
    fn a_cursor_move_keeps_every_row_hash() {
        let mut layout = layout();
        let text = "abcdef\nghij\nklm";
        let before = frame(&mut layout, view(text, 4, 160, 0, &[(1, 1)]));
        let after = frame(&mut layout, view(text, 4, 160, 0, &[(9, 9)]));
        let hashes = |frame: &ViewFrame| frame.rows.iter().map(|row| row.hash).collect::<Vec<_>>();
        assert_eq!(hashes(&before), hashes(&after));
        assert_ne!(before.cursors, after.cursors);
        // A selection is part of its rows.
        let selected = frame(&mut layout, view(text, 4, 160, 0, &[(1, 3)]));
        assert_ne!(hashes(&selected)[0], hashes(&before)[0]);
        assert_eq!(hashes(&selected)[1..], hashes(&before)[1..]);
    }

    #[test]
    fn an_offset_that_is_not_a_position_is_moved_back() {
        let mut layout = layout();
        // 2 is inside é: the anchor is moved back to 1, on row 0.
        let rows = frame(&mut layout, view("aé\nb", 4, 16, 2, &[(9, 9)])).rows;
        assert_eq!(rows[0].bytes, 0..3);
        let cursors = frame(&mut layout, view("aé\nb", 4, 64, 0, &[(9, 9)])).cursors;
        assert_eq!((cursors[0].area.x, cursors[0].area.y), (10.0, 16.0));
    }

    /// A source that records the ranges it is asked for.
    struct Counting {
        asked: RefCell<Vec<Range<usize>>>,
    }

    impl DecorationSource for Counting {
        fn spans(&self, _snapshot: &Snapshot, bytes: Range<usize>, _out: &mut Vec<Span>) {
            self.asked.borrow_mut().push(bytes);
        }
    }

    #[test]
    fn decorations_are_asked_only_for_the_rows_shown() {
        let text = "row\n".repeat(1000);
        let mut layout = layout();
        // Row 500 starts at byte 2000; five rows are shown.
        let shown = view(&text, 10, 80, 2000, &[]);
        let counting = Counting {
            asked: RefCell::new(vec![]),
        };
        let frame = layout.view_frame(&shown, &[&counting]);
        assert_eq!(frame.rows.len(), 5);
        let asked = counting.asked.into_inner();
        assert!(!asked.is_empty());
        assert!(
            asked
                .iter()
                .all(|bytes| bytes.start >= 2000 && bytes.end <= 2019),
            "{asked:?}"
        );
    }

    #[test]
    fn a_frame_is_shared_between_threads_as_it_is() {
        fn shared<T: Send + Sync>() {}
        shared::<Frame>();
    }
}
