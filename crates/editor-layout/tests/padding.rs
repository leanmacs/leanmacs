//! A view's padding ([`View::padding`]) and the echo's
//! ([`Scene::echo_padding`]): whole points that layout multiplies at its
//! scale ([`Layout::padding_pixels`]), inset from the view's edges
//! ([`frame`](editor_layout::frame), "The padding"). The text rows, the
//! cursors and the selections move in by it, the text wraps at the width
//! less it and fills the height less it, and the rows query takes it off
//! by the same rule, so the frame and the query agree.
//!
//! The shaper is the fake, at 8 pixels across and 16 down at the base
//! size: its geometry is exact, so every count here is worked by hand.

use editor_layout::Layout;
use editor_layout::face::{Color, Face, FaceDef};
use editor_layout::frame::{ECHO_VIEW, Frame, StatusRow, ViewFrame};
use editor_layout::scene::{
    Padding, Rect, Scene, Side, Size, StatusField, TextKey, TextRef, View, ViewId,
};
use editor_layout::shaper::fake::CellShaper;
use editor_text::{Selection, SelectionRange, Text};

/// The mode line's background.
const MODE_PAPER: Color = Color::rgb(0x40, 0x40, 0x40);

/// A layout on the fake, with a mode line of its own background, at
/// `scale`.
fn layout_at(scale: f32) -> Layout<CellShaper> {
    let mut layout = Layout::new(CellShaper::new(8.0, 16.0));
    layout.define(&[FaceDef {
        name: "mode-line".to_owned(),
        face: Face {
            background: Some(MODE_PAPER),
            ..Face::default()
        },
    }]);
    layout.set_scale(scale);
    layout
}

/// `text`, as text 1.
fn text_of(text: &str) -> TextRef {
    TextRef::fixed(TextKey(1), Text::from(text).snapshot())
}

/// The text of 120 lines, `000` to `119`, each four bytes with its break.
fn lines() -> TextRef {
    let text: String = (0..120).map(|line| format!("{line:03}\n")).collect();
    text_of(&text)
}

/// A rectangle at the frame's top left.
fn rect(width: u32, height: u32) -> Rect {
    Rect {
        x: 0,
        y: 0,
        width,
        height,
    }
}

/// The padding `across` and `down`, with no top inset.
fn padding(across: u32, down: u32) -> Padding {
    Padding::new(across, down, 0)
}

/// The padding `across` and `down`, with the top inset `top`.
fn padding_under(across: u32, down: u32, top: u32) -> Padding {
    Padding::new(across, down, top)
}

/// A view of `text` in `rect` with `padding`, and no status field.
fn view(text: TextRef, rect: Rect, padding: Padding) -> View {
    View {
        id: ViewId(1),
        rect,
        text: Some(text),
        padding,
        ..View::default()
    }
}

/// A field `text` on `side`, in the mode line, with no padding of its own.
fn field(text: &str, side: Side) -> StatusField {
    StatusField {
        text: text.to_owned(),
        face: "mode-line".to_owned(),
        side,
        padding: 0,
    }
}

/// A frame 640 by 480 of `views`, its echo empty: no view reaches its
/// bottom edge unless it is 480 tall.
fn scene(views: Vec<View>) -> Scene {
    Scene {
        size: Size {
            width: 640,
            height: 480,
        },
        views,
        ..Scene::default()
    }
}

/// The one view of `frame` other than the echo's, which fills the bottom
/// row whenever no view covers it.
fn only(frame: &Frame) -> &ViewFrame {
    let views: Vec<&ViewFrame> = frame
        .views
        .iter()
        .filter(|view| view.id != ECHO_VIEW)
        .collect();
    assert_eq!(views.len(), 1, "{}", frame.describe());
    views[0]
}

/// The bytes each row of `view` starts and stops at.
fn rows_of(view: &ViewFrame) -> Vec<(usize, usize)> {
    view.rows
        .iter()
        .map(|row| (row.bytes.start, row.bytes.end))
        .collect()
}

/// What the rows query answers for `text` at `width` by `height` with
/// `padding`, from its start.
fn asked(
    layout: &mut Layout<CellShaper>,
    text: &TextRef,
    width: f32,
    height: f32,
    padding: Padding,
) -> Vec<(usize, usize)> {
    layout
        .rows_shown(text, width, height, padding, 0)
        .unwrap()
        .iter()
        .map(|row| (row.start, row.stop))
        .collect()
}

/// The x where each box of `status` starts and where it ends.
fn box_ends(status: &StatusRow) -> Vec<(f32, f32)> {
    status
        .boxes
        .iter()
        .map(|status_box| (status_box.x, status_box.x + status_box.width))
        .collect()
}

#[test]
fn a_views_first_glyph_cursor_and_selection_are_offset_by_its_padding() {
    let mut layout = layout_at(1.0);
    // `b` selected, its head after it: a selection over `b` and a cursor
    // on `c`.
    let selected = |padding: Padding| View {
        selections: Selection::new(vec![SelectionRange::new(1, 2)], 0)
            .into_iter()
            .collect(),
        ..view(text_of("abc\ndef"), rect(200, 100), padding)
    };
    let plain = layout.frame(&scene(vec![selected(Padding::default())]));
    let padded = layout.frame(&scene(vec![selected(padding(8, 8))]));
    let (plain, padded) = (only(&plain), only(&padded));

    // The rows: in 8 from the left and 8 down, the next row stacked under
    // the first; the glyphs themselves are the row's, from its start.
    assert_eq!((plain.rows[0].x, plain.rows[0].y), (0.0, 0.0));
    assert_eq!((padded.rows[0].x, padded.rows[0].y), (8.0, 8.0));
    assert_eq!((padded.rows[1].x, padded.rows[1].y), (8.0, 24.0));
    assert_eq!(padded.rows[0].line, plain.rows[0].line);
    // The cursor on `c`: its cell 16 in, and 8 more; on its row.
    assert_eq!(plain.cursors[0].area.x, 16.0);
    assert_eq!(padded.cursors[0].area.x, 8.0 + 16.0);
    assert_eq!(padded.cursors[0].area.y, padded.rows[0].y);
    // The selection over `b`: 8 in, and 8 more; on its row.
    assert_eq!(plain.selections[0].x, 8.0);
    assert_eq!(padded.selections[0].x, 8.0 + 8.0);
    assert_eq!(padded.selections[0].y, padded.rows[0].y);
    assert_eq!(padded.selections[0].width, plain.selections[0].width);
}

#[test]
fn text_wraps_at_the_views_width_less_its_padding() {
    let mut layout = layout_at(1.0);
    let thirteen = text_of("abcdefghijklm");
    // 112 across less 8 each side is 96: twelve cells, then the last.
    let padded = layout.frame(&scene(vec![view(
        thirteen.clone(),
        rect(112, 100),
        padding(8, 0),
    )]));
    let narrower = layout.frame(&scene(vec![view(
        thirteen,
        rect(96, 100),
        Padding::default(),
    )]));
    assert_eq!(rows_of(only(&padded)), vec![(0, 12), (12, 13)]);
    assert_eq!(rows_of(only(&padded)), rows_of(only(&narrower)));
}

#[test]
fn the_rows_fill_the_height_less_the_padding() {
    let mut layout = layout_at(1.0);
    let status = layout.heights().status;
    let text = lines();
    let shown = View {
        status: vec![field("normal", Side::Left)],
        ..view(text.clone(), rect(640, 200), padding(8, 8))
    };
    let frame = layout.frame(&scene(vec![shown]));
    // 200 less a status row of 16 less 8 above and 8 below: 168, which
    // holds ten rows of 16.
    assert_eq!(only(&frame).rows.len(), 10);
    let unpadded = asked(
        &mut layout,
        &text,
        640.0 - 16.0,
        (200 - status) as f32 - 16.0,
        Padding::default(),
    );
    let padded = asked(
        &mut layout,
        &text,
        640.0,
        (200 - status) as f32,
        padding(8, 8),
    );
    assert_eq!(rows_of(only(&frame)), unpadded);
    assert_eq!(rows_of(only(&frame)), padded);
    // The status row stays at the view's foot: the padding is above it.
    let row = only(&frame).status.as_ref().expect("a status row");
    assert_eq!(row.y, (200 - status) as f32);
}

#[test]
fn a_status_rows_background_spans_the_view_while_its_fields_are_inset() {
    let mut layout = layout_at(1.0);
    // A view 200 across: the left field from 8, the right ending at 192.
    let fields = |fields: Vec<StatusField>| View {
        status: fields,
        ..view(text_of("ab"), rect(200, 80), padding(8, 8))
    };
    let frame = layout.frame(&scene(vec![fields(vec![
        field("ab", Side::Left),
        field("cd", Side::Right),
    ])]));
    let status = only(&frame).status.clone().expect("a status row");
    assert_eq!(box_ends(&status), vec![(8.0, 24.0), (176.0, 192.0)]);
    // Its own background is the mode line's, which the renderer draws
    // across the whole view, so the padding beside the fields is in it.
    assert_eq!(status.background, MODE_PAPER);
    let xs: Vec<f32> = status.line.glyphs.iter().map(|glyph| glyph.x).collect();
    assert_eq!(xs, vec![8.0, 16.0, 176.0, 184.0]);

    // Both sides do not fit in a view 64 across: 48 between the insets.
    // The right side, 4 cells, starts at 64 - 8 - 32 = 24, and the left
    // side is cut there.
    let frame = layout.frame(&scene(vec![View {
        rect: rect(64, 80),
        ..fields(vec![
            field("abcdef", Side::Left),
            field("wxyz", Side::Right),
        ])
    }]));
    let status = only(&frame).status.clone().expect("a status row");
    assert_eq!(box_ends(&status), vec![(8.0, 24.0), (24.0, 56.0)]);
    // A right side wider than the row less its insets starts at the
    // inset.
    let frame = layout.frame(&scene(vec![View {
        rect: rect(40, 80),
        ..fields(vec![field("ab", Side::Left), field("wxyz", Side::Right)])
    }]));
    let status = only(&frame).status.clone().expect("a status row");
    assert_eq!(box_ends(&status), vec![(8.0, 40.0)]);
}

/// A frame 200 by 100 with no view, saying `echo`, its echo inset
/// `echo_padding` points.
fn echoing(echo: &str, echo_padding: u32) -> Scene {
    Scene {
        size: Size {
            width: 200,
            height: 100,
        },
        echo: echo.to_owned(),
        echo_padding,
        ..Scene::default()
    }
}

/// The echo's status row in `frame`.
fn echo_row(frame: &Frame) -> StatusRow {
    let echo = frame
        .views
        .iter()
        .find(|view| view.id == ECHO_VIEW)
        .expect("the echo's view");
    echo.status.clone().expect("the echo's row")
}

#[test]
fn the_echo_is_inset_by_the_scenes_echo_padding() {
    let mut layout = layout_at(1.0);
    let row = echo_row(&layout.frame(&echoing("hi", 14)));
    assert_eq!(row.boxes[0].x, 14.0);
    assert_eq!(row.line.glyphs[0].x, 14.0);
    // None, as before the padding.
    let row = echo_row(&layout.frame(&echoing("hi", 0)));
    assert_eq!(row.line.glyphs[0].x, 0.0);
}

#[test]
fn padding_is_points_multiplied_at_the_layouts_scale() {
    // At scale 2, 8 points are 16 pixels.
    let mut layout = layout_at(2.0);
    assert_eq!(layout.padding_pixels(8), 16.0);
    let frame = layout.frame(&scene(vec![View {
        status: vec![field("ab", Side::Left)],
        ..view(text_of("abc"), rect(400, 200), padding(8, 8))
    }]));
    let laid = only(&frame);
    assert_eq!((laid.rows[0].x, laid.rows[0].y), (16.0, 16.0));
    assert_eq!(laid.status.as_ref().expect("a status row").boxes[0].x, 16.0);
    // An echo padding of 14 points puts the echo's first glyph at 28.
    let row = echo_row(&layout.frame(&echoing("hi", 14)));
    assert_eq!(row.line.glyphs[0].x, 28.0);

    // At scale 1.5, unrounded: 8 points are 12 pixels and 3 are 4½.
    let mut layout = layout_at(1.5);
    assert_eq!(layout.padding_pixels(8), 12.0);
    assert_eq!(layout.padding_pixels(3), 4.5);
    let heights = layout.heights();
    let line = heights.text as f32;
    let tall = |padded: Padding| View {
        status: vec![field("ab", Side::Left)],
        ..view(lines(), rect(400, 120), padded)
    };
    let padded = layout.frame(&scene(vec![tall(padding(3, 3))]));
    assert_eq!(only(&padded).rows[0].x, 4.5);
    assert_eq!(only(&padded).rows[0].y, 4.5);
    // Rows and the status row are 24 at this scale. 120 less 24 less 4½
    // twice is 87, which holds three whole rows; four would need 96,
    // which the view without padding has.
    let text_height = (120 - heights.status) as f32;
    assert_eq!(text_height - 2.0 * 4.5, 87.0);
    assert_eq!(only(&padded).rows.len(), (87.0 / line).floor() as usize);
    assert_eq!(only(&padded).rows.len(), 3);
    let unpadded = layout.frame(&scene(vec![tall(Padding::default())]));
    assert_eq!(only(&unpadded).rows.len(), 4);
    // The query at the same scale and padding answers the same rows.
    let text = lines();
    assert_eq!(
        asked(&mut layout, &text, 400.0, text_height, padding(3, 3)),
        rows_of(only(&padded))
    );
}

#[test]
fn the_rows_query_takes_the_padding_off_at_the_layouts_scale() {
    let mut layout = layout_at(2.0);
    // Lines that wrap: 30 cells of 16 at scale 2 do not fit 400 less 32.
    let text = text_of(&"abcdefghij".repeat(3).repeat(8));
    let (width, height) = (400.0, 200.0);
    let frame = layout.frame(&scene(vec![view(
        text.clone(),
        rect(400, 200),
        padding(8, 8),
    )]));
    let query = asked(&mut layout, &text, width, height, padding(8, 8));
    assert_eq!(rows_of(only(&frame)), query);
    assert_eq!(
        query,
        asked(
            &mut layout,
            &text,
            width - 32.0,
            height - 32.0,
            Padding::default()
        )
    );
    // A move with the padding across goes as across a view 32 pixels
    // narrower.
    for lines in [1, 3, -1] {
        let padded = layout.lines_from(&text, width, 8, 20, lines, None);
        let narrower = layout.lines_from(&text, width - 32.0, 0, 20, lines, None);
        assert_eq!(padded, narrower, "{lines} lines");
    }
}

#[test]
fn a_view_padded_with_a_top_inset_starts_its_first_row_below_it_and_the_padding() {
    // At scale 2 a row is 32 pixels; 8 points are 16 pixels and 28 are 56.
    let mut layout = layout_at(2.0);
    let status = layout.heights().status;
    let line = layout.heights().text as f32;
    let text = lines();
    let shown = |padded: Padding| View {
        status: vec![field("normal", Side::Left)],
        ..view(text.clone(), rect(640, 400), padded)
    };
    let frame = layout.frame(&scene(vec![shown(padding_under(8, 8, 28))]));
    let laid = only(&frame);
    // The first row is the top inset and the padding down below the top.
    assert_eq!(laid.rows[0].y, 72.0);
    assert_eq!(laid.rows[0].x, 16.0);
    assert_eq!(laid.rows[1].y, 72.0 + line);
    // The rows that fit are those of the height less the status row less
    // 88 pixels: twice the padding down and the top inset once.
    let text_height = (400 - status) as f32;
    let fits = ((text_height - 88.0) / line).floor() as usize;
    assert_eq!(laid.rows.len(), fits);
    assert_eq!(
        rows_of(laid),
        asked(
            &mut layout,
            &text,
            640.0 - 32.0,
            text_height - 88.0,
            Padding::default()
        )
    );
    // The query with the same padding answers the rows the frame shows.
    assert_eq!(
        asked(
            &mut layout,
            &text,
            640.0,
            text_height,
            padding_under(8, 8, 28)
        ),
        rows_of(laid)
    );
    // The status row stays at the view's foot.
    let row = laid.status.as_ref().expect("a status row");
    assert_eq!(row.y, text_height);
}

#[test]
fn a_top_inset_of_0_lays_out_as_before() {
    let mut layout = layout_at(2.0);
    let text = lines();
    let frame = |layout: &mut Layout<CellShaper>, padded: Padding| {
        layout.frame(&scene(vec![View {
            status: vec![field("normal", Side::Left)],
            ..view(text.clone(), rect(640, 400), padded)
        }]))
    };
    let before = frame(&mut layout, padding(8, 8));
    let after = frame(&mut layout, padding_under(8, 8, 0));
    assert_eq!(only(&before).rows[0].y, 16.0);
    assert_eq!(only(&after), only(&before));
}

#[test]
fn a_row_hash_does_not_change_with_padding() {
    let mut layout = layout_at(1.0);
    let hashes =
        |frame: &Frame| -> Vec<u64> { only(frame).rows.iter().map(|row| row.hash).collect() };
    let plain = layout.frame(&scene(vec![view(
        text_of("ab\ncd"),
        rect(200, 100),
        Padding::default(),
    )]));
    let padded = layout.frame(&scene(vec![view(
        text_of("ab\ncd"),
        rect(200, 100),
        padding(8, 8),
    )]));
    assert_eq!(hashes(&plain), hashes(&padded));
}

#[test]
fn a_frame_describes_a_rows_x_only_when_it_is_not_0() {
    let mut layout = layout_at(1.0);
    let plain = layout.frame(&scene(vec![view(
        text_of("ab"),
        rect(200, 100),
        Padding::default(),
    )]));
    assert!(
        plain.describe().contains("  row y 0 height 16"),
        "{}",
        plain.describe()
    );
    let padded = layout.frame(&scene(vec![view(
        text_of("ab"),
        rect(200, 100),
        padding(8, 4),
    )]));
    assert!(
        padded.describe().contains("  row x 8 y 4 height 16"),
        "{}",
        padded.describe()
    );
}
