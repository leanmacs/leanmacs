//! Align-to stops ([`AlignStop`]): the cells of a view's rows placed at
//! pixel columns, by frame and by query.
//!
//! The shaper is the fake: a glyph of the default family is 10 pixels
//! across and a line 16 down at the base size, and a glyph of the family
//! `narrow` 7 across. So `ab ` is 30 pixels wide in the default face and
//! `abcd ` 50, `nnnnnnn ` in `narrow` 56, and a stop at 60 points is 60
//! pixels at scale 1 and 120 at scale 2. No count of spaces puts a cell
//! after each of those three at one x; a stop does.

use editor_layout::Layout;
use editor_layout::face::{Face, FaceDef};
use editor_layout::frame::ViewFrame;
use editor_layout::query::Spot;
use editor_layout::scene::{
    AlignStop, Decoration, Padding, Rect, Scene, TextKey, TextRef, View, ViewId,
};
use editor_layout::shaper::fake::CellShaper;
use editor_text::{Selection, SelectionRange, Text};

/// The fake, with the family `narrow` 7 pixels a glyph.
fn layout() -> Layout<CellShaper> {
    Layout::new(CellShaper::new(10.0, 16.0).with_family("narrow", 7.0, 16.0))
}

/// The face `narrow`: its family and nothing else.
fn narrow() -> FaceDef {
    FaceDef {
        name: "narrow".to_owned(),
        face: Face {
            family: Some("narrow".to_owned()),
            ..Face::default()
        },
    }
}

/// `text` as text 1.
fn text_ref(text: &str) -> TextRef {
    TextRef::fixed(TextKey(1), Text::from(text).snapshot())
}

/// A view of `text`, `width` pixels wide and 160 down, with `stops`.
fn view(text: &TextRef, width: u32, stops: Vec<AlignStop>) -> View {
    View {
        id: ViewId(1),
        rect: Rect {
            x: 0,
            y: 0,
            width,
            height: 160,
        },
        text: Some(text.clone()),
        stops,
        ..View::default()
    }
}

/// A scene of `view`, with the face `narrow` defined.
fn scene(view: View) -> Scene {
    Scene {
        views: vec![view],
        faces: Some(vec![narrow()]),
        ..Scene::default()
    }
}

/// The frame of the one view of `scene`.
fn frame(layout: &mut Layout<CellShaper>, scene: &Scene) -> ViewFrame {
    layout.frame(scene).views.remove(0)
}

/// A stop at the byte `offset`, `x` points from the start of the row.
fn stop(offset: usize, x: u32) -> AlignStop {
    AlignStop { offset, x }
}

/// Where the character at `offset` of `text` is drawn in `frame`: the
/// index of its row among the text rows, and its glyph's x from the
/// view's left. The text has no tab and no row longer than a segment, so
/// a glyph's cluster is its byte from its row's start.
fn drawn(frame: &ViewFrame, text: &str, offset: usize) -> (usize, f32) {
    let row_start = text[..offset].rfind('\n').map_or(0, |at| at + 1);
    let column = offset - row_start;
    frame
        .rows
        .iter()
        .filter(|row| row.is_text())
        .enumerate()
        .find_map(|(index, row)| {
            if !row.bytes.contains(&offset) {
                return None;
            }
            let glyph = row
                .line
                .glyphs
                .iter()
                .find(|glyph| glyph.cluster == column)?;
            Some((index, row.x + glyph.x))
        })
        .expect("a glyph drawn for the offset")
}

/// The bytes of each text row of `frame`.
fn rows(frame: &ViewFrame) -> Vec<(usize, usize)> {
    frame
        .rows
        .iter()
        .filter(|row| row.is_text())
        .map(|row| (row.bytes.start, row.bytes.end))
        .collect()
}

/// The rows the rows query answers for a view of `text` `width` wide
/// and 160 down, with no padding, from the start.
fn asked(layout: &mut Layout<CellShaper>, text: &TextRef, width: f32) -> Vec<(usize, usize)> {
    layout
        .rows_shown(text, width, 160.0, Padding::default(), 0)
        .unwrap()
        .iter()
        .map(|row| (row.start, row.stop))
        .collect()
}

/// Three rows whose first cells differ in length and in family, each with
/// a second cell; the third row's first cell is in `narrow`.
const TABLE: &str = "ab x\nabcd y\nnnnnnnn z";

/// The offset of each second cell of [`TABLE`].
fn second_cells() -> [usize; 3] {
    ["x", "y", "z"].map(|cell| TABLE.find(cell).unwrap())
}

/// A view of [`TABLE`] with a stop at each second cell, 60 points in,
/// and the third row's first cell in `narrow`.
fn table(width: u32) -> View {
    let stops = second_cells().map(|offset| stop(offset, 60)).to_vec();
    View {
        decorations: vec![Decoration {
            start: TABLE.find('n').unwrap(),
            stop: TABLE.find('z').unwrap(),
            face: "narrow".to_owned(),
        }],
        ..view(&text_ref(TABLE), width, stops)
    }
}

#[test]
fn cells_in_one_column_line_up_whatever_the_widths_before_them() {
    let mut layout = layout();
    let laid = frame(&mut layout, &scene(table(400)));
    let at = second_cells().map(|offset| drawn(&laid, TABLE, offset));
    assert_eq!(at, [(0, 60.0), (1, 60.0), (2, 60.0)]);
    // The cells before them are of three widths, 30, 50 and 56: the
    // space that ends each starts at 20, 40 and 49.
    let ends = laid
        .rows
        .iter()
        .map(|row| row.line.glyphs[row.line.glyphs.len() - 2].x)
        .collect::<Vec<_>>();
    assert_eq!(ends, vec![20.0, 40.0, 49.0]);
    // At scale 2 the stop is 120 pixels in.
    layout.set_scale(2.0);
    let laid = frame(&mut layout, &scene(table(800)));
    let at = second_cells().map(|offset| drawn(&laid, TABLE, offset));
    assert_eq!(at, [(0, 120.0), (1, 120.0), (2, 120.0)]);
    // With a padding and a gutter, from where the text rows start.
    let mut layout = self::layout();
    let padded = View {
        padding: Padding {
            gutter: 6,
            ..Padding::new(4, 0, 0)
        },
        ..table(400)
    };
    let laid = frame(&mut layout, &scene(padded));
    let at = second_cells().map(|offset| drawn(&laid, TABLE, offset));
    assert_eq!(at, [(0, 70.0), (1, 70.0), (2, 70.0)]);
}

#[test]
fn a_face_over_part_of_a_cell_after_a_stop_shapes_just_that_part_in_its_font() {
    let source = "ab xyz";
    let text = text_ref(source);
    let mut layout = layout();
    // Each glyph's offset, x from the view's left and advance.
    let placed = |layout: &mut Layout<CellShaper>, decoration: Decoration| {
        let laid = frame(
            layout,
            &scene(View {
                decorations: vec![decoration],
                ..view(&text, 400, vec![stop(3, 60)])
            }),
        );
        let row = &laid.rows[0];
        row.line
            .glyphs
            .iter()
            .map(|glyph| (glyph.cluster, row.x + glyph.x, glyph.advance))
            .collect::<Vec<_>>()
    };
    // `narrow` over `yz`, starting inside the cell after the stop: `x`
    // is 10 pixels at the stop, `y` and `z` 7 each, so `z` is at 77, not
    // 80.
    let inside = Decoration {
        start: 4,
        stop: 6,
        face: "narrow".to_owned(),
    };
    assert_eq!(
        placed(&mut layout, inside),
        vec![
            (0, 0.0, 10.0),
            (1, 10.0, 10.0),
            (2, 20.0, 40.0),
            (3, 60.0, 10.0),
            (4, 70.0, 7.0),
            (5, 77.0, 7.0),
        ]
    );
    // `narrow` over `b xy`, across the stop from the first cell into the
    // second: `b` and the space are 7 pixels, the space spanning the gap
    // to the stop, then `x` and `y` 7 at the stop and `z` 10.
    let across = Decoration {
        start: 1,
        stop: 5,
        face: "narrow".to_owned(),
    };
    assert_eq!(
        placed(&mut layout, across),
        vec![
            (0, 0.0, 10.0),
            (1, 10.0, 7.0),
            (2, 17.0, 43.0),
            (3, 60.0, 7.0),
            (4, 67.0, 7.0),
            (5, 74.0, 10.0),
        ]
    );
}

#[test]
fn a_stop_past_the_width_breaks_the_row_before_its_cell_which_starts_at_x_0() {
    let source = "ab cd\nef";
    let text = text_ref(source);
    let mut layout = layout();
    // 50 pixels wide: `ab cd` would fit, but its second cell's stop is
    // at 60.
    let laid = frame(&mut layout, &scene(view(&text, 50, vec![stop(3, 60)])));
    assert_eq!(rows(&laid), vec![(0, 3), (3, 5), (6, 8)]);
    assert_eq!(drawn(&laid, source, 3), (1, 0.0));
    // The rows query answers the frame's rows.
    assert_eq!(asked(&mut layout, &text, 50.0), rows(&laid));
    // The cell's first position is at x 0, one row down.
    assert_eq!(
        layout.spot(&text, 50.0, 160.0, Padding::default(), 0, 3),
        Ok(Some(Spot {
            x: 0.0,
            y: 16.0,
            height: 16.0
        }))
    );
    // A move down from `b` lands on `d`, below it, and back up on `b`;
    // from the row's start down is the cell's start.
    let moved = |layout: &mut Layout<CellShaper>, position, lines| {
        layout
            .lines_from(&text, 50.0, 0, position, lines, None)
            .unwrap()
            .position
    };
    assert_eq!(moved(&mut layout, 1, 1), 4);
    assert_eq!(moved(&mut layout, 4, -1), 1);
    assert_eq!(moved(&mut layout, 0, 1), 3);
    assert_eq!(moved(&mut layout, 3, 1), 6);
}

#[test]
fn a_long_cell_after_a_stop_inside_the_width_hangs_under_the_stop() {
    let source = "ab cdefghijkl";
    let text = text_ref(source);
    let mut layout = layout();
    // 70 pixels right of the stop hold seven glyphs: `cdefghi`, and `jkl`
    // hangs under the stop.
    let laid = frame(&mut layout, &scene(view(&text, 100, vec![stop(3, 30)])));
    assert_eq!(rows(&laid), vec![(0, 10), (10, 13)]);
    assert_eq!(drawn(&laid, source, 3), (0, 30.0));
    assert_eq!(drawn(&laid, source, 10), (1, 30.0));
    assert_eq!(asked(&mut layout, &text, 100.0), rows(&laid));
}

#[test]
fn a_cell_that_runs_past_the_next_stop_pushes_the_cell_after_it_right() {
    let source = "abcdefgh x";
    let mut layout = layout();
    let laid = frame(
        &mut layout,
        &scene(view(&text_ref(source), 400, vec![stop(9, 30)])),
    );
    assert_eq!(drawn(&laid, source, 9), (0, 90.0));
}

#[test]
fn the_character_before_a_stop_spans_the_gap_for_a_cursor_and_a_move() {
    let source = "ab cd\nabcdefgh";
    let text = text_ref(source);
    let mut layout = layout();
    // A cursor on the space before the stop at 60 is 40 pixels wide.
    let mut on_space = view(&text, 400, vec![stop(3, 60)]);
    on_space.selections = vec![Selection::new(vec![SelectionRange::new(2, 2)], 0).unwrap()];
    let laid = frame(&mut layout, &scene(on_space));
    let cursor = laid.cursors[0].area;
    assert_eq!((cursor.x, cursor.width), (20.0, 40.0));
    // A move up with a goal in the gap lands on the space.
    let moved = layout
        .lines_from(&text, 400.0, 0, 10, -1, Some(45.0))
        .unwrap();
    assert_eq!(moved.position, 2);
}

#[test]
fn a_query_lays_a_row_out_under_the_stops_of_the_last_frame() {
    let mut edited = Text::from("ab cd");
    let text = TextRef::fixed(TextKey(1), edited.snapshot());
    let mut layout = layout();
    // Before any frame of the text the query knows no stop: `ab cd` fits
    // 50 pixels.
    assert_eq!(asked(&mut layout, &text, 50.0), vec![(0, 5)]);
    let laid = frame(&mut layout, &scene(view(&text, 50, vec![stop(3, 60)])));
    assert_eq!(rows(&laid), vec![(0, 3), (3, 5)]);
    // After it, the query agrees with it.
    assert_eq!(asked(&mut layout, &text, 50.0), rows(&laid));
    // At a newer revision no frame has shown, no stop again.
    edited.replace(5..5, "!").unwrap();
    let newer = TextRef::fixed(TextKey(1), edited.snapshot());
    assert_eq!(asked(&mut layout, &newer, 50.0), vec![(0, 5), (5, 6)]);
}

#[test]
fn a_query_after_a_change_of_scale_lays_a_row_out_under_its_stops_at_the_new_scale() {
    let source = "ab cd\nxy z";
    let text = text_ref(source);
    let mut layout = layout();
    let stops = vec![stop(3, 40), stop(9, 40)];
    frame(&mut layout, &scene(view(&text, 100, stops.clone())));
    // At scale 2 a glyph is 20 pixels and the stop 80: `c` is at 80 and
    // `d` hangs under it. At the stop's pixels of scale 1, 40, `cd` would
    // start after `ab `, at 60, and fit. `z` is at 80 and fits.
    layout.set_scale(2.0);
    let asked_rows = asked(&mut layout, &text, 100.0);
    assert_eq!(asked_rows, vec![(0, 4), (4, 5), (6, 10)]);
    let spot = layout
        .spot(&text, 100.0, 160.0, Padding::default(), 0, 3)
        .unwrap()
        .expect("a spot");
    assert_eq!((spot.x, spot.y), (80.0, 0.0));
    // And the next frame is what the queries said.
    let laid = frame(&mut layout, &scene(view(&text, 100, stops)));
    assert_eq!(rows(&laid), asked_rows);
    assert_eq!(drawn(&laid, source, 3), (0, 80.0));
}
