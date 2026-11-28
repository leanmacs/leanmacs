//! Gutter marks: a column of its own before a view's text, a mark drawn in
//! it beside each row its range covers ([`GutterMark`]; the frame's module
//! docs, "The gutter").
//!
//! The faces `diff.added`, `diff.removed` and `diff.changed` are defined
//! in three inks, and `gutter` with a paper of its own, so a mark's paint
//! shows which face it took and that `gutter` is under it. The shaper is
//! the fake, at 10 pixels across and 16 down, so every number here is
//! worked by hand.

use editor_layout::Layout;
use editor_layout::face::{Color, Face, FaceDef, Paint};
use editor_layout::frame::{FrameRow, ViewFrame};
use editor_layout::query::Around;
use editor_layout::scene::{
    Cursor, GutterMark, Padding, Rect, Scene, TextKey, TextRef, View, ViewId,
};
use editor_layout::shaper::fake::CellShaper;
use editor_text::{Selection, SelectionRange, Text};

const GREEN: Color = Color::rgb(0, 0xaa, 0);
const RED: Color = Color::rgb(0xcc, 0, 0);
const BLUE: Color = Color::rgb(0, 0, 0xcc);
const GREY: Color = Color::rgb(0xdd, 0xdd, 0xdd);

/// A layout on cells 10 by 16, with the three diff faces in their inks
/// and `gutter` on grey.
fn layout() -> Layout<CellShaper> {
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    let ink = |name: &str, color| FaceDef {
        name: name.to_owned(),
        face: Face {
            foreground: Some(color),
            ..Face::default()
        },
    };
    layout.define(&[
        ink("diff.added", GREEN),
        ink("diff.removed", RED),
        ink("diff.changed", BLUE),
        FaceDef {
            name: "gutter".to_owned(),
            face: Face {
                background: Some(GREY),
                ..Face::default()
            },
        },
    ]);
    layout
}

/// A mark of `text` over `start..stop`, in `face`.
fn mark(start: usize, stop: usize, text: &str, face: &str) -> GutterMark {
    GutterMark {
        start,
        stop,
        text: text.to_owned(),
        face: face.to_owned(),
    }
}

/// A view of `text` `width` pixels wide and `rows` rows tall, with a
/// gutter of `gutter` points and `marks`.
fn view(text: &str, width: u32, rows: u32, gutter: u32, marks: Vec<GutterMark>) -> View {
    View {
        id: ViewId(1),
        rect: Rect {
            x: 0,
            y: 0,
            width,
            height: rows * 16,
        },
        text: Some(TextRef::fixed(TextKey(1), Text::from(text).snapshot())),
        cursor: Cursor {
            face: "cursor".to_owned(),
            ..Cursor::default()
        },
        padding: Padding {
            gutter,
            ..Padding::default()
        },
        marks,
        ..View::default()
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

/// Each mark row as its mark, its left and its top.
fn mark_rows(rows: &[FrameRow]) -> Vec<(usize, f32, f32)> {
    rows.iter()
        .filter_map(|row| Some((row.mark?, row.x, row.y)))
        .collect()
}

/// Each text row as its left, its top and its bytes.
fn text_rows(rows: &[FrameRow]) -> Vec<(f32, f32, (usize, usize))> {
    rows.iter()
        .filter(|row| row.is_text())
        .map(|row| (row.x, row.y, (row.bytes.start, row.bytes.end)))
        .collect()
}

/// The paint of a mark in the ink `ink` over the gutter's grey.
fn marked(ink: Color) -> Paint {
    Paint {
        foreground: ink,
        background: GREY,
        ..Paint::default()
    }
}

#[test]
fn marks_are_drawn_in_a_column_before_the_text_in_their_faces() {
    let mut layout = layout();
    let marks = vec![
        mark(0, 2, "+", "diff.added"),
        mark(4, 6, "~", "diff.changed"),
        mark(6, 6, "-", "diff.removed"),
    ];
    let laid = frame(&mut layout, view("a\nb\nc\nd\n", 100, 8, 20, marks));
    // The text is 20 pixels in, the gutter's width.
    assert_eq!(
        text_rows(&laid.rows),
        vec![
            (20.0, 0.0, (0, 1)),
            (20.0, 16.0, (2, 3)),
            (20.0, 32.0, (4, 5)),
            (20.0, 48.0, (6, 7)),
            (20.0, 64.0, (8, 8)),
        ]
    );
    // Each mark is in the column, at the view's left, beside its row:
    // the added one beside row 0, the changed one beside row 2, and the
    // empty removed one beside row 3, which holds its start. Row 1 has
    // none.
    assert_eq!(
        mark_rows(&laid.rows),
        vec![(0, 0.0, 0.0), (1, 0.0, 32.0), (2, 0.0, 48.0)]
    );
    // Each in its face's ink over the gutter's paper, and on its text
    // row's baseline.
    let paints: Vec<_> = laid
        .rows
        .iter()
        .filter(|row| row.mark.is_some())
        .map(|row| (row.runs.clone(), row.baseline))
        .collect();
    let baseline = laid.rows[0].baseline;
    assert_eq!(
        paints,
        vec![
            (vec![(0..1, marked(GREEN))], baseline),
            (vec![(0..1, marked(BLUE))], baseline),
            (vec![(0..1, marked(RED))], baseline),
        ]
    );
    // A mark row draws its text: the glyphs a row of that text has.
    let plain = frame(&mut self::layout(), view("+~-", 100, 8, 0, vec![]));
    let ids = |row: &FrameRow| row.line.glyphs.iter().map(|g| g.id).collect::<Vec<_>>();
    let first_mark = laid.rows.iter().find(|row| row.mark == Some(0)).unwrap();
    assert_eq!(ids(first_mark), ids(&plain.rows[0])[..1]);
}

#[test]
fn a_mark_is_drawn_on_every_visual_line_of_a_wrapped_row() {
    let mut layout = layout();
    // 60 pixels less a gutter of 20 is 4 cells: the row wraps in three.
    let laid = frame(
        &mut layout,
        view(
            "abcdefghij\nk\n",
            60,
            8,
            20,
            vec![mark(0, 11, "~", "diff.changed")],
        ),
    );
    assert_eq!(
        text_rows(&laid.rows)[..3],
        [
            (20.0, 0.0, (0, 4)),
            (20.0, 16.0, (4, 8)),
            (20.0, 32.0, (8, 10)),
        ]
    );
    assert_eq!(
        mark_rows(&laid.rows),
        vec![(0, 0.0, 0.0), (0, 0.0, 16.0), (0, 0.0, 32.0)]
    );
}

#[test]
fn the_rows_spot_and_move_queries_take_the_gutter_off_as_the_frame_does() {
    let mut layout = layout();
    let text = "abcdefghij\nk\n";
    let mut shown = view(text, 60, 8, 20, vec![]);
    shown.selections = vec![Selection::new(vec![SelectionRange::new(5, 5)], 0).unwrap()];
    let laid = frame(&mut layout, shown.clone());
    let reference = shown.text.clone().unwrap();
    let padding = shown.padding;
    // The rows: wrapped at 4 cells, as the frame wraps them.
    let rows = layout
        .rows_shown(&reference, 60.0, 128.0, padding, 0)
        .unwrap();
    let framed: Vec<_> = text_rows(&laid.rows)
        .into_iter()
        .map(|(_, _, bytes)| bytes)
        .collect();
    assert_eq!(
        rows.iter()
            .map(|row| (row.start, row.stop))
            .collect::<Vec<_>>(),
        framed
    );
    // The spot: the gutter is to its left, where the frame's cursor is.
    let spot = layout
        .spot(&reference, 60.0, 128.0, padding, 0, 5)
        .unwrap()
        .unwrap();
    assert_eq!(
        (spot.x, spot.y),
        (laid.cursors[0].area.x, laid.cursors[0].area.y)
    );
    assert_eq!(spot.x, 30.0);
    // A move wraps at the same width: from 5, the second cell of the
    // second visual line, one line down is the second cell of the third.
    let moved = layout
        .lines_from_padded(&reference, 60.0, padding, 5, 1, None, Around::default())
        .unwrap();
    assert_eq!(moved.position, 9);
}

#[test]
fn marks_outside_the_rows_shown_draw_nothing() {
    let mut layout = layout();
    let laid = frame(
        &mut layout,
        view(
            "a\nb\nc\nd\n",
            100,
            2,
            20,
            vec![mark(6, 8, "+", "diff.added")],
        ),
    );
    assert_eq!(text_rows(&laid.rows).len(), 2);
    assert_eq!(mark_rows(&laid.rows), vec![]);
}

#[test]
fn an_offset_past_the_text_is_marked_on_the_last_row() {
    let mut layout = layout();
    let laid = frame(
        &mut layout,
        view("a\nb", 100, 8, 20, vec![mark(99, 99, "-", "diff.removed")]),
    );
    assert_eq!(mark_rows(&laid.rows), vec![(0, 0.0, 16.0)]);
}

#[test]
fn mark_and_block_rows_are_not_text_rows() {
    let mut layout = layout();
    let mut shown = view("a\nb\n", 100, 8, 20, vec![mark(0, 2, "+", "diff.added")]);
    shown.blocks = vec![editor_layout::scene::Block {
        before: 0,
        text: "header".to_owned(),
        decorations: vec![],
    }];
    let laid = frame(&mut layout, shown);
    let kinds: Vec<_> = laid
        .rows
        .iter()
        .map(|row| (row.is_text(), row.block, row.mark))
        .collect();
    assert_eq!(
        kinds,
        vec![
            (false, Some(0), None),
            (true, None, None),
            (false, None, Some(0)),
            (true, None, None),
            (true, None, None),
        ]
    );
}

#[test]
fn an_unchanged_mark_keeps_its_rows_hash_and_a_view_with_no_gutter_lays_out_as_before() {
    let mut layout = layout();
    let marks = vec![mark(0, 2, "+", "diff.added"), mark(4, 6, "+", "diff.added")];
    let first = frame(&mut layout, view("a\nb\nc\n", 100, 8, 20, marks.clone()));
    let again = frame(&mut layout, view("a\nb\nc\nX\n", 100, 8, 20, marks));
    let hashes = |laid: &ViewFrame| {
        laid.rows
            .iter()
            .filter(|row| row.mark.is_some())
            .map(|row| row.hash)
            .collect::<Vec<_>>()
    };
    assert_eq!(hashes(&first), hashes(&again));
    // Two marks of one text and face are one row's content.
    assert_eq!(hashes(&first)[0], hashes(&first)[1]);
    // With no gutter and no mark, a view is laid out as it was before
    // there were either.
    let bare = frame(&mut layout, view("a\nb\nc\n", 100, 8, 0, vec![]));
    let plain = frame(
        &mut layout,
        View {
            padding: Padding::default(),
            marks: vec![],
            ..view("a\nb\nc\n", 100, 8, 0, vec![])
        },
    );
    assert_eq!(bare, plain);
    assert!(bare.rows.iter().all(|row| row.x == 0.0 && row.is_text()));
}
