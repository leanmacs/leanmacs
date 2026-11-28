//! Folds: the rows of a range of a view's text drawn as one placeholder
//! row ([`Fold`]; the `folds` module's docs, "The rule"; `query`'s module
//! docs, "Folds").
//!
//! The text is five rows, `zero` to `four`; rows 1 to 3 are folded, in
//! a face `fold-summary` defined red on yellow. The shaper is the fake, at
//! 10 pixels across and 16 down, so every number here is worked by hand.

use editor_layout::Layout;
use editor_layout::face::{Color, Face, FaceDef, Paint};
use editor_layout::frame::{Area, FrameRow, ViewFrame};
use editor_layout::query::{Around, Moved, RowRange, Spot};
use editor_layout::scene::{
    Block, Cursor, Decoration, Fold, GutterMark, Padding, Rect, Scene, TextKey, TextRef, View,
    ViewId,
};
use editor_layout::shaper::fake::CellShaper;
use editor_text::{Selection, SelectionRange, Text};

/// Five rows: `zero` at 0, `one` at 5, `two` at 9, `three` at 13 and
/// `four` at 19.
const TEXT: &str = "zero\none\ntwo\nthree\nfour";

/// What the placeholder says: nine characters.
const SUMMARY: &str = "… 3 lines";

const RED: Color = Color::rgb(0xcc, 0, 0);
const YELLOW: Color = Color::rgb(0xee, 0xee, 0);

/// A layout on cells 10 by 16, with `fold-summary` red on yellow and
/// `gutter` defined.
fn layout() -> Layout<CellShaper> {
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.define(&[FaceDef {
        name: "fold-summary".to_owned(),
        face: Face {
            foreground: Some(RED),
            background: Some(YELLOW),
            ..Face::default()
        },
    }]);
    layout
}

/// The fold of rows 1 to 3, saying [`SUMMARY`] in `fold-summary`.
fn folded() -> Fold {
    Fold {
        start: 5,
        stop: 18,
        text: SUMMARY.to_owned(),
        decorations: vec![Decoration {
            start: 0,
            stop: SUMMARY.len(),
            face: "fold-summary".to_owned(),
        }],
    }
}

/// [`TEXT`], as text 1.
fn text() -> TextRef {
    TextRef::fixed(TextKey(1), Text::from(TEXT).snapshot())
}

/// A view of [`TEXT`] `columns` cells wide and `rows` rows tall, with
/// `folds`.
fn view(columns: u32, rows: u32, folds: Vec<Fold>) -> View {
    View {
        id: ViewId(1),
        rect: Rect {
            x: 0,
            y: 0,
            width: columns * 10,
            height: rows * 16,
        },
        text: Some(text()),
        cursor: Cursor {
            face: "cursor".to_owned(),
            ..Cursor::default()
        },
        folds,
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

/// Each row as its fold, its top and its bytes.
fn described(rows: &[FrameRow]) -> Vec<(Option<usize>, f32, (usize, usize))> {
    rows.iter()
        .map(|row| (row.fold, row.y, (row.bytes.start, row.bytes.end)))
        .collect()
}

/// The glyph ids of `row`, as a string.
fn glyphs(row: &FrameRow) -> String {
    row.line
        .glyphs
        .iter()
        .filter_map(|glyph| char::from_u32(glyph.id))
        .collect()
}

/// `view` with one selection from `anchor` to `head`.
fn selecting(mut view: View, anchor: usize, head: usize) -> View {
    view.selections = vec![Selection::new(vec![SelectionRange::new(anchor, head)], 0).unwrap()];
    view
}

#[test]
fn a_folded_range_is_drawn_as_its_placeholder_row_with_the_row_after_it_below() {
    let mut layout = layout();
    let laid = frame(&mut layout, view(40, 10, vec![folded()]));
    assert_eq!(
        described(&laid.rows),
        vec![
            (None, 0.0, (0, 4)),
            (Some(0), 16.0, (5, 18)),
            (None, 32.0, (19, 23)),
        ]
    );
    let placeholder = &laid.rows[1];
    assert!(placeholder.is_text());
    assert_eq!(glyphs(placeholder), SUMMARY);
    assert_eq!(
        placeholder.runs,
        vec![(
            0..SUMMARY.len(),
            Paint {
                foreground: RED,
                background: YELLOW,
                ..placeholder.runs[0].1
            }
        )]
    );
    assert_eq!(glyphs(&laid.rows[2]), "four");
    // Without the fold, every row is drawn.
    let plain = frame(&mut layout, view(40, 10, vec![]));
    assert_eq!(plain.rows.len(), 5);
}

/// The rows, the moves and the spots of [`TEXT`] with [`folded`], at
/// `scale`: a cell is `10 * scale` across and `16 * scale` down.
fn queries_at(scale: f32) {
    let mut layout = layout();
    layout.set_scale(scale);
    let folds = [folded()];
    let around = Around {
        blocks: &[],
        folds: &folds,
    };
    let (width, height) = (400.0 * scale, 160.0 * scale);
    let rows = layout
        .rows_shown_with_blocks(&text(), width, height, Padding::default(), 0, around)
        .unwrap();
    assert_eq!(
        rows,
        vec![
            RowRange { start: 0, stop: 4 },
            RowRange { start: 5, stop: 18 },
            RowRange {
                start: 19,
                stop: 23
            },
        ],
        "at {scale}"
    );
    // An anchor inside the fold shows from its placeholder.
    let from_inside = layout
        .rows_shown_with_blocks(&text(), width, height, Padding::default(), 10, around)
        .unwrap();
    assert_eq!(from_inside, rows[1..].to_vec(), "at {scale}");
    let cell = 10.0 * scale;
    let mut moved = |position: usize, lines: i64, goal: Option<f32>| {
        layout
            .lines_from_padded(
                &text(),
                width,
                Padding::default(),
                position,
                lines,
                goal,
                around,
            )
            .unwrap()
    };
    // Down from `e` of `zero` lands on the fold's start, and the goal is
    // passed back unchanged; one more lands on `o` of `four`.
    assert_eq!(
        moved(1, 1, None),
        Moved {
            position: 5,
            goal: cell
        }
    );
    assert_eq!(moved(5, 1, Some(cell)).position, 20);
    assert_eq!(moved(1, 2, None).position, 20);
    // And up mirrors it.
    assert_eq!(
        moved(20, -1, None),
        Moved {
            position: 5,
            goal: cell
        }
    );
    assert_eq!(moved(5, -1, Some(cell)).position, 1);
    // A position inside the fold is at its placeholder's x 0.
    assert_eq!(
        moved(10, 1, None),
        Moved {
            position: 19,
            goal: 0.0
        }
    );
    let mut spot = |position: usize| {
        layout
            .spot_with_blocks(
                &text(),
                width,
                height,
                Padding::default(),
                0,
                position,
                around,
            )
            .unwrap()
    };
    let tall = 16.0 * scale;
    for inside in [5, 10, 18] {
        assert_eq!(
            spot(inside),
            Some(Spot {
                x: 0.0,
                y: tall,
                height: tall
            }),
            "{inside} at {scale}"
        );
    }
    assert_eq!(
        spot(20),
        Some(Spot {
            x: cell,
            y: 2.0 * tall,
            height: tall
        }),
        "at {scale}"
    );
}

#[test]
fn the_rows_moves_and_spots_count_a_fold_as_one_row() {
    queries_at(1.0);
    queries_at(2.0);
}

#[test]
fn a_cursor_inside_a_fold_is_drawn_at_its_placeholders_start() {
    let mut layout = layout();
    let laid = frame(&mut layout, selecting(view(40, 10, vec![folded()]), 10, 10));
    assert_eq!(laid.cursors.len(), 1);
    assert_eq!(
        laid.cursors[0].area,
        Area {
            x: 0.0,
            y: 16.0,
            width: 10.0,
            height: 16.0
        }
    );
}

#[test]
fn a_selection_that_ends_inside_a_fold_fills_its_whole_placeholder() {
    let mut layout = layout();
    let laid = frame(&mut layout, selecting(view(40, 10, vec![folded()]), 1, 10));
    let on_placeholder: Vec<&Area> = laid
        .selections
        .iter()
        .filter(|area| area.y == 16.0)
        .collect();
    assert_eq!(
        on_placeholder,
        vec![&Area {
            x: 0.0,
            y: 16.0,
            width: 90.0,
            height: 16.0
        }]
    );
    // One that covers nothing of the fold leaves it alone.
    let before = frame(&mut layout, selecting(view(40, 10, vec![folded()]), 0, 2));
    assert!(before.selections.iter().all(|area| area.y == 0.0));
}

#[test]
fn a_block_before_the_first_covered_row_is_drawn_above_the_placeholder_and_one_before_a_later_row_is_not()
 {
    let block = |before: usize, text: &str| Block {
        before,
        text: text.to_owned(),
        decorations: vec![],
    };
    let mut layout = layout();
    let mut shown = view(40, 10, vec![folded()]);
    shown.blocks = vec![block(5, "above"), block(10, "hidden")];
    let laid = frame(&mut layout, shown);
    let rows: Vec<(Option<usize>, Option<usize>, f32)> = laid
        .rows
        .iter()
        .map(|row| (row.block, row.fold, row.y))
        .collect();
    assert_eq!(
        rows,
        vec![
            (None, None, 0.0),
            (Some(0), None, 16.0),
            (None, Some(0), 32.0),
            (None, None, 48.0),
        ]
    );
}

#[test]
fn the_gutter_marks_of_the_first_covered_row_sit_beside_the_placeholder() {
    let mark = |start: usize, stop: usize, text: &str| GutterMark {
        start,
        stop,
        text: text.to_owned(),
        face: "diff.added".to_owned(),
    };
    let mut layout = layout();
    let mut shown = view(40, 10, vec![folded()]);
    shown.padding = Padding {
        gutter: 10,
        ..Padding::default()
    };
    shown.marks = vec![mark(5, 8, "+"), mark(9, 12, "~")];
    let laid = frame(&mut layout, shown);
    let marks: Vec<(usize, f32, String)> = laid
        .rows
        .iter()
        .filter_map(|row| row.mark.map(|mark| (mark, row.y, glyphs(row))))
        .collect();
    assert_eq!(marks, vec![(0, 16.0, "+".to_owned())]);
}

#[test]
fn a_placeholder_wider_than_the_view_is_one_line() {
    let mut layout = layout();
    let laid = frame(&mut layout, view(4, 10, vec![folded()]));
    assert_eq!(
        described(&laid.rows),
        vec![
            (None, 0.0, (0, 4)),
            (Some(0), 16.0, (5, 18)),
            (None, 32.0, (19, 23)),
        ]
    );
    assert_eq!(glyphs(&laid.rows[1]), SUMMARY);
    assert_eq!(laid.rows[1].line.width, 90.0);
}
