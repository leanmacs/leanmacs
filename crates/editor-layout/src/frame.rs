//! The frame: an immutable plain-data value of what to draw, built from a
//! scene.
//!
//! For each view, the visual rows it shows from its scroll anchor, as many
//! as fit its rectangle, each with its `y`, its glyphs (shared with the
//! line store, never copied), its styled runs and a content hash; and the
//! geometry of its cursors and of its selections. Geometry is in pixels
//! from the view's top left.
//!
//! A row's runs cover its glyphs from the first to the last and nothing
//! past them, and a selection's area on a row is as wide as the glyphs it
//! covers there. A tab whose spaces cross a soft wrap is drawn on both
//! rows, so each row takes the tab's faces and its selection over the
//! spaces it holds, though the tab's position is on the earlier row alone
//! ([`line`](mod@crate::line), which also says which of a tab's spaces are
//! no row at all in a view narrower than the tab).
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
    /// Its bytes in the view's snapshot, without its line break. A tab
    /// whose spaces it starts inside is not among them: the tab is the
    /// earlier row's.
    pub bytes: Range<usize>,
    /// Its glyphs, as the line store holds them. Their clusters are bytes of
    /// the segment's expanded text; `line.bytes` is the row's part of it.
    pub line: Arc<VisualLine>,
    /// Its styled runs, as bytes of the expanded text from the row's start
    /// (`line.bytes.start`), with the faces over each. They cover
    /// `line.bytes` from start to end; an empty row has none.
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

/// How far from the rows a view shows its text's entries are kept at a
/// publish, in view heights (counted in buffer rows): farther ones are
/// dropped, and laid out again if they are reached.
pub const KEPT_VIEW_HEIGHTS: usize = 4;

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
    /// Lays `scene` out into a frame. What is kept of every text it does
    /// not name is dropped, and of each text it names, every row farther
    /// than [`KEPT_VIEW_HEIGHTS`] view heights from the rows every view of
    /// it shows.
    pub fn frame(&mut self, scene: &Scene) -> Frame {
        let frame = Frame {
            views: scene
                .views
                .iter()
                .map(|view| self.view_frame(view, &[]))
                .collect(),
        };
        // The buffer rows each view shows, by text.
        let mut shown: HashMap<TextKey, Vec<Range<usize>>> = HashMap::new();
        for (view, laid) in scene.views.iter().zip(&frame.views) {
            let Some(text) = &view.text else { continue };
            let rows = shown.entry(text.key).or_default();
            let row_of = |offset| {
                text.snapshot
                    .offset_to_point(offset)
                    .map_or(0, |point| point.row)
            };
            if let (Some(first), Some(last)) = (laid.rows.first(), laid.rows.last()) {
                let (first, last) = (row_of(first.bytes.start), row_of(last.bytes.end));
                let reach = KEPT_VIEW_HEIGHTS * (last - first + 1);
                rows.push(first.saturating_sub(reach)..last + reach + 1);
            }
        }
        self.texts.retain(|key, _| shown.contains_key(key));
        for (key, state) in &mut self.texts {
            let near = &shown[key];
            state
                .wrap
                .retain_rows(|row| near.iter().any(|rows| rows.contains(&row)));
        }
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
            // The spans of the characters the row draws any of, which is
            // more than its bytes when it starts inside a tab's spaces.
            let drawn = entry.drawn_bytes(visual.line).unwrap_or(0..0);
            let (spans, selected) = spans_of(row_start + drawn.start..row_start + drawn.end);
            // Each span as the columns of the row it covers, from the row's
            // start: a tab's span is cut to the spaces of it the row holds.
            let columns = line.bytes.clone();
            let column = |offset: usize| {
                entry
                    .column(offset - row_start)
                    .clamp(columns.start, columns.end)
                    - columns.start
            };
            let on_row = |span: &Span| {
                let covered = column(span.bytes.start)..column(span.bytes.end);
                (!covered.is_empty()).then_some(Span {
                    bytes: covered,
                    face: span.face,
                })
            };
            for span in spans[..selected].iter().filter_map(on_row) {
                let left = entry.x_of_column(visual.line, columns.start + span.bytes.start);
                let right = entry.x_of_column(visual.line, columns.start + span.bytes.end);
                frame.selections.push(Area {
                    x: left,
                    y,
                    width: right - left,
                    height: line.height,
                });
            }
            let spans: Vec<Span> = spans.iter().filter_map(on_row).collect();
            let runs: Vec<(Range<usize>, Vec<FaceId>)> = merge(0..columns.len(), &spans)
                .into_iter()
                .map(|run| (run.bytes, run.faces))
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
    use crate::decoration::{DecorationSource, SELECTION_FACE, Span};
    use crate::scene::{
        Cursor, CursorShape, Decoration, Rect, Scene, TextKey, TextRef, View, ViewId,
    };
    use crate::shaper::fake::CellShaper;
    use crate::shaper::{FontId, VisualLine};

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
        assert_eq!(frame(&mut layout, tall.clone()).rows.len(), 2);
        // The rows query fits them by their heights too, in the fonts of
        // the last frame that showed the text.
        let text = tall.text.unwrap();
        assert_eq!(layout.rows_shown(&text, 40.0, 63.0, 0).unwrap().len(), 2);
        assert_eq!(layout.rows_shown(&text, 40.0, 64.0, 0).unwrap().len(), 3);
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
    fn scrolling_by_n_lines_reaches_every_row_of_a_text_with_tabs() {
        // Tabs that end a row, start one, cross a wrap and are wider than
        // the view, at every width from one column to twelve.
        let texts = [
            "abc\tdef\nzz",
            "abcdefghi\tx",
            "\tgh",
            "a\tb\tc",
            "é\t😀\tz",
            "ab\t",
            "\t\t\n\t",
        ];
        for text in texts {
            for columns in 1..=12_u32 {
                let mut layout = layout();
                let at_top = frame(&mut layout, view(text, columns, 1600, 0, &[]));
                let snapshot = TextRef::fixed(key(text), Text::from(text).snapshot());
                let width = columns as f32 * 10.0;
                for (n, expected) in at_top.rows.iter().enumerate() {
                    let lines = i64::try_from(n).unwrap();
                    let moved = layout
                        .lines_from(&snapshot, width, 0, lines, Some(0.0))
                        .unwrap();
                    let scrolled =
                        frame(&mut layout, view(text, columns, 1600, moved.position, &[]));
                    let first = &scrolled.rows[0];
                    let case = format!("{text:?} at {columns} columns, {n} lines down");
                    assert_eq!(first.bytes, expected.bytes, "{case}");
                    assert_eq!(first.line, expected.line, "{case}");
                    assert_eq!(first.hash, expected.hash, "{case}");
                }
            }
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
    fn a_tab_that_crosses_a_wrap_is_styled_and_selected_on_both_rows() {
        let mut layout = layout();
        // Tabs are 8 columns wide, so the tab is columns 9 to 16, and the
        // view is 10 columns wide: the tab's first space ends the first
        // row and its other six start the second, before the x.
        let mut crossing = view("abcdefghi\tx", 10, 64, 0, &[(8, 11)]);
        crossing.decorations = vec![Decoration {
            start: 9,
            stop: 10,
            face: "tab".to_owned(),
        }];
        let frame = frame(&mut layout, crossing);
        let selection = layout.faces_mut().intern(SELECTION_FACE);
        let tab = layout.faces_mut().intern("tab");
        let glyphs: Vec<usize> = frame.rows.iter().map(|row| row.line.glyphs.len()).collect();
        assert_eq!(glyphs, vec![10, 7]);
        // Each row's runs cover its glyphs and no more, and the tab's
        // spaces take the tab's faces on both rows.
        assert_eq!(
            frame.rows[0].runs,
            vec![
                (0..8, vec![]),
                (8..9, vec![selection]),
                (9..10, vec![selection, tab])
            ]
        );
        assert_eq!(
            frame.rows[1].runs,
            vec![(0..6, vec![selection, tab]), (6..7, vec![selection])]
        );
        assert_eq!(
            frame.selections,
            vec![
                Area {
                    x: 80.0,
                    y: 0.0,
                    width: 20.0,
                    height: 16.0
                },
                Area {
                    x: 0.0,
                    y: 16.0,
                    width: 70.0,
                    height: 16.0
                },
            ]
        );
    }

    #[test]
    fn every_rows_runs_cover_its_glyphs_and_a_selection_of_it_all_is_as_wide() {
        // Tabs that end a row, start one, cross a wrap and fill whole
        // rows, at every width from one column to twelve.
        let texts = [
            "abcdefghi\tx",
            "abc\tdef\nzz",
            "\tgh",
            "a\tb\tc",
            "é\t😀\tz",
            "ab\t",
            "\t\t\n\t",
        ];
        for text in texts {
            for columns in 1..=12 {
                let mut layout = layout();
                // The whole text selected, and each tab in a face.
                let mut all = view(text, columns, 1600, 0, &[(0, text.len())]);
                all.decorations = text
                    .match_indices('\t')
                    .map(|(at, _)| Decoration {
                        start: at,
                        stop: at + 1,
                        face: "tab".to_owned(),
                    })
                    .collect();
                let frame = frame(&mut layout, all);
                let mut areas = Vec::new();
                for row in &frame.rows {
                    let mut covered = 0;
                    for (bytes, _) in &row.runs {
                        assert_eq!(bytes.start, covered, "{text:?} at {columns}: {row:?}");
                        assert!(bytes.end > bytes.start, "{text:?} at {columns}: {row:?}");
                        covered = bytes.end;
                    }
                    assert_eq!(
                        covered,
                        row.line.bytes.len(),
                        "{text:?} at {columns}: {row:?}"
                    );
                    if !row.line.glyphs.is_empty() {
                        areas.push(Area {
                            x: 0.0,
                            y: row.y,
                            width: row.line.width,
                            height: row.height,
                        });
                    }
                }
                assert_eq!(frame.selections, areas, "{text:?} at {columns}");
            }
        }
    }

    /// The hash of each row of `frame`.
    fn hashes(frame: &ViewFrame) -> Vec<u64> {
        frame.rows.iter().map(|row| row.hash).collect()
    }

    #[test]
    fn rows_of_different_glyphs_have_different_hashes() {
        let mut layout = layout();
        // Four rows: "abcd" twice (one wrapped row), "abce" and "abcd".
        let rows = hashes(&frame(
            &mut layout,
            view("abcdabcd\nabce\nabcd", 4, 160, 0, &[]),
        ));
        assert_ne!(rows[0], rows[2]);
        // The same glyphs hash the same wherever the row is: further down,
        // further into the text, or the later part of a wrapped row.
        assert_eq!(rows[0], rows[1]);
        assert_eq!(rows[0], rows[3]);
        // An edit changes the hash of the row it is on, and of no other,
        // though the rows after it are further into the text.
        let edited = hashes(&frame(
            &mut layout,
            view("abcdabcd\nabcxe\nabcd", 4, 160, 0, &[]),
        ));
        assert_ne!(edited[2], rows[2]);
        assert_eq!((edited[0], edited[1]), (rows[0], rows[1]));
        assert_eq!(edited[4], rows[3]);
    }

    #[test]
    fn the_same_glyphs_at_another_height_or_advance_have_another_hash() {
        // The first row of "ab" in a layout on cells `advance` by `height`.
        let row = |advance: f32, height: f32| {
            let mut layout = Layout::new(CellShaper::new(advance, height));
            frame(&mut layout, view("ab", 4, 160, 0, &[]))
                .rows
                .remove(0)
        };
        let (short, tall, wide) = (row(10.0, 16.0), row(10.0, 32.0), row(12.0, 16.0));
        // Another line height: the same glyphs and runs, lower down.
        assert_eq!(short.line.glyphs, tall.line.glyphs);
        assert_eq!(short.runs, tall.runs);
        assert_ne!(short.hash, tall.hash);
        // Another advance: the same height, glyphs further across.
        assert_eq!((short.height, short.baseline), (wide.height, wide.baseline));
        assert_ne!(short.hash, wide.hash);
        assert_eq!(short.hash, row(10.0, 16.0).hash);
        // The fake's baseline follows its height, so each alone is checked
        // on a line made by hand.
        let line = |height: f32, baseline: f32| VisualLine {
            bytes: 0..0,
            glyphs: vec![],
            width: 0.0,
            height,
            baseline,
        };
        let plain = super::hash(&line(16.0, 12.0), &[]);
        assert_ne!(plain, super::hash(&line(20.0, 12.0), &[]));
        assert_ne!(plain, super::hash(&line(16.0, 10.0), &[]));
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
