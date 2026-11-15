//! The heights of a view's rows ([`Layout::heights`]), and the rule that
//! makes them exact: a status row is exactly [`Heights::status`] tall, or
//! [`Heights::message`] tall at the frame's bottom edge, and the text rows
//! of a view are those the rows query answers at the view's height less
//! that row. So a caller that asks the rows of a view's text area at that
//! height is answered with the rows the frame shows.
//!
//! The shaper is the fake, at 8 pixels across and 16 down at the base
//! size: its geometry is exact, so every count here is worked by hand.

use editor_layout::Layout;
use editor_layout::face::{Face, FaceDef};
use editor_layout::frame::{Frame, Heights, ViewFrame};
use editor_layout::scene::{Rect, Scene, Size, StatusField, TextKey, TextRef, View, ViewId};
use editor_layout::shaper::fake::CellShaper;
use editor_layout::shaper::{Length, LineHeight};
use editor_text::Text;

/// The fake shaper: cells 8 across and 16 down.
fn shaper() -> CellShaper {
    CellShaper::new(8.0, 16.0)
}

/// A face of the line height `line_height` and nothing else.
fn lined(line_height: LineHeight) -> Face {
    Face {
        line_height: Some(line_height),
        ..Face::default()
    }
}

/// A line height of `pixels` and `sixty_fourths` 64ths of a pixel.
fn pixels(pixels: u32, sixty_fourths: u32) -> LineHeight {
    LineHeight::Pixels(Length(pixels * 64 + sixty_fourths))
}

/// The faces `faces`, by name.
fn theme(faces: &[(&str, Face)]) -> Vec<FaceDef> {
    faces
        .iter()
        .map(|(name, face)| FaceDef {
            name: (*name).to_owned(),
            face: face.clone(),
        })
        .collect()
}

/// A layout that has been handed `faces` and is at `scale`.
fn layout_with(faces: &[(&str, Face)], scale: f32) -> Layout<CellShaper> {
    let mut layout = Layout::new(shaper());
    layout.frame(&Scene {
        faces: Some(theme(faces)),
        ..Scene::default()
    });
    layout.set_scale(scale);
    layout
}

/// The text of 120 lines, `000` to `119`, each four bytes with its break.
fn lines() -> TextRef {
    let text: String = (0..120).map(|line| format!("{line:03}\n")).collect();
    TextRef::fixed(TextKey(1), Text::from(text.as_str()).snapshot())
}

/// A frame 640 wide and `frame_height` tall, of one view of [`lines`] in
/// `rect` from `anchor`, with one status field; and no echo.
fn scene(frame_height: u32, rect: Rect, anchor: usize) -> Scene {
    Scene {
        size: Size {
            width: 640,
            height: frame_height,
        },
        views: vec![View {
            id: ViewId(1),
            rect,
            text: Some(lines()),
            scroll: anchor,
            status: vec![StatusField {
                text: "normal".to_owned(),
                face: "mode-line".to_owned(),
            }],
            ..View::default()
        }],
        ..Scene::default()
    }
}

/// The one view of `frame`.
fn view(frame: &Frame) -> &ViewFrame {
    assert_eq!(frame.views.len(), 1, "{}", frame.describe());
    &frame.views[0]
}

/// The bytes each row of `view` starts and stops at.
fn rows_of(view: &ViewFrame) -> Vec<(usize, usize)> {
    view.rows
        .iter()
        .map(|row| (row.bytes.start, row.bytes.end))
        .collect()
}

/// What the rows query answers for [`lines`] in a view `rect` wide, at
/// `height`, from `anchor`.
fn asked(
    layout: &mut Layout<CellShaper>,
    rect: Rect,
    height: u32,
    anchor: usize,
) -> Vec<(usize, usize)> {
    layout
        .rows_shown(&lines(), rect.width as f32, height as f32, anchor)
        .unwrap()
        .iter()
        .map(|row| (row.start, row.stop))
        .collect()
}

#[test]
fn the_heights_are_the_default_faces_line_at_the_scale() {
    assert_eq!(
        layout_with(&[], 1.0).heights(),
        Heights {
            text: 16,
            status: 16,
            message: 16
        }
    );
    assert_eq!(
        layout_with(&[], 2.0).heights(),
        Heights {
            text: 32,
            status: 32,
            message: 32
        }
    );
}

#[test]
fn the_status_height_is_the_mode_lines_and_the_message_height_the_taller_of_it_and_the_echo_areas()
{
    // A mode line one and a half times as tall: 24, which the message row
    // takes too, being the taller.
    let mut layout = layout_with(&[("mode-line", lined(LineHeight::Multiple(96)))], 1.0);
    assert_eq!(
        layout.heights(),
        Heights {
            text: 16,
            status: 24,
            message: 24
        }
    );
    // An echo area twice as tall: the message row is 32, and the status
    // row keeps the mode line's 16.
    let mut layout = layout_with(&[("echo-area", lined(LineHeight::Multiple(128)))], 1.0);
    assert_eq!(
        layout.heights(),
        Heights {
            text: 16,
            status: 16,
            message: 32
        }
    );
}

#[test]
fn a_height_is_rounded_up_to_a_whole_pixel() {
    // Lines of 16¼ pixels, which every face inherits from the default.
    let mut layout = layout_with(&[("default", lined(pixels(16, 16)))], 1.0);
    assert_eq!(
        layout.heights(),
        Heights {
            text: 17,
            status: 17,
            message: 17
        }
    );
}

/// Requires the frame of one view of [`lines`] in `rect` of a frame
/// `frame_height` tall, from `anchor`, to show exactly the rows the rows
/// query answers at the view's height less its bottom row: the status
/// height, or the message height when the view ends at the frame's bottom
/// edge; and its status row to be that tall, at the view's bottom.
fn assert_agrees(layout: &mut Layout<CellShaper>, frame_height: u32, rect: Rect, anchor: usize) {
    let heights = layout.heights();
    let at_bottom = rect.y + rect.height >= frame_height;
    let bottom = if at_bottom {
        heights.message
    } else {
        heights.status
    };
    let frame = layout.frame(&scene(frame_height, rect, anchor));
    let laid = view(&frame);
    let context = format!(
        "rect {rect:?} of a frame {frame_height} tall, from {anchor}, at scale {}",
        layout.scale()
    );
    let status = laid.status.as_ref().expect("a status row");
    assert_eq!(status.height, bottom as f32, "{context}");
    assert_eq!(
        status.y,
        rect.height.saturating_sub(bottom) as f32,
        "{context}"
    );
    let query = asked(layout, rect, rect.height.saturating_sub(bottom), anchor);
    assert_eq!(rows_of(laid), query, "{context}");
}

#[test]
fn a_views_text_rows_are_the_rows_query_at_its_height_less_its_bottom_row() {
    // Mid-text: the start of line 60.
    for anchor in [0, 240] {
        for scale in [1.0, 2.0] {
            let mut layout = layout_with(&[], scale);
            for height in [480, 100, 33] {
                // A window above the frame's bottom edge: the minibuffer's
                // bottom row is below it.
                let above = Rect {
                    x: 0,
                    y: 0,
                    width: 640,
                    height,
                };
                assert_agrees(&mut layout, height + 16, above, anchor);
                // A view that ends at the frame's bottom edge, as the
                // minibuffer's does.
                assert_agrees(&mut layout, height, above, anchor);
            }
        }
    }
}

#[test]
fn a_status_row_of_a_fractional_line_takes_its_whole_pixels_from_the_text() {
    // Rows of 16¼ pixels, and a status row of 17, its ceiling. In a view
    // 49 tall the text has 49 - 17 = 32 pixels, which hold one row of
    // 16¼ (two would need 32½). Had the status row kept its shaped 16¼,
    // the text would have 32¾, which holds two: the query at the height
    // less the status height would answer one and the frame show two.
    let mut layout = layout_with(&[("default", lined(pixels(16, 16)))], 1.0);
    let rect = Rect {
        x: 0,
        y: 0,
        width: 640,
        height: 49,
    };
    assert_agrees(&mut layout, 100, rect, 0);
    let frame = layout.frame(&scene(100, rect, 0));
    assert_eq!(view(&frame).rows.len(), 1);
}

#[test]
fn a_view_at_the_bottom_edge_gives_the_message_height_to_its_status_row() {
    // An echo area twice as tall as the mode line: a window keeps a status
    // row of 16, and the view at the bottom edge has one of 32.
    let mut layout = layout_with(&[("echo-area", lined(LineHeight::Multiple(128)))], 1.0);
    for height in [480, 100, 33] {
        let rect = Rect {
            x: 0,
            y: 0,
            width: 640,
            height,
        };
        assert_agrees(&mut layout, height + 32, rect, 0);
        assert_agrees(&mut layout, height, rect, 0);
    }
    // At 480 at the bottom edge: 448 pixels of text, 28 rows of 16.
    let rect = Rect {
        x: 0,
        y: 0,
        width: 640,
        height: 480,
    };
    let frame = layout.frame(&scene(480, rect, 0));
    assert_eq!(view(&frame).rows.len(), 28);
}

#[test]
fn a_view_with_no_status_field_gives_its_whole_height_to_its_text_at_the_bottom_edge_too() {
    // As the fixture's second view does: it reaches the bottom edge, has
    // no status row, and shows as many rows as its height holds.
    let mut layout = layout_with(&[("echo-area", lined(LineHeight::Multiple(128)))], 1.0);
    let rect = Rect {
        x: 0,
        y: 80,
        width: 64,
        height: 32,
    };
    let mut scene = scene(112, rect, 0);
    scene.views[0].status.clear();
    let frame = layout.frame(&scene);
    let laid = view(&frame);
    assert!(laid.status.is_none());
    assert_eq!(rows_of(laid), asked(&mut layout, rect, 32, 0));
    assert_eq!(laid.rows.len(), 2);
}
