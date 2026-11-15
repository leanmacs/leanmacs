//! The echo in the frame's bottom row ([`frame`](editor_layout::frame),
//! "The bottom row"): when the scene's echo is not empty and no view's
//! rectangle covers any of the frame's bottom [`Heights::message`] pixels,
//! the frame ends with one more view frame, [`ECHO_VIEW`], whose one row is
//! a status row holding the echo in the face `echo-area` over the default
//! face.
//!
//! The shaper is the fake, at 8 pixels across and 16 down at the base
//! size.

use editor_layout::Layout;
use editor_layout::face::{Color, Face, FaceDef};
use editor_layout::frame::{ECHO_VIEW, Frame, Heights, ViewFrame};
use editor_layout::scene::{Rect, Scene, Size, StatusField, TextKey, TextRef, View, ViewId};
use editor_layout::shaper::fake::CellShaper;
use editor_text::Text;

/// The default face's colours.
const PAPER: Color = Color::rgb(0xf8, 0xf8, 0xf8);
/// The default face's foreground.
const INK: Color = Color::rgb(0x20, 0x20, 0x20);
/// The echo area's foreground.
const ECHO_INK: Color = Color::rgb(0, 0, 0xc0);
/// The echo area's background.
const ECHO_PAPER: Color = Color::rgb(0xff, 0xff, 0xe0);
/// The mode line's background.
const MODE_PAPER: Color = Color::rgb(0x40, 0x40, 0x40);

/// The faces: a default, an echo area and a mode line of colours each its
/// own.
fn theme() -> Vec<FaceDef> {
    let named = |name: &str, foreground: Color, background: Color| FaceDef {
        name: name.to_owned(),
        face: Face {
            foreground: Some(foreground),
            background: Some(background),
            ..Face::default()
        },
    };
    vec![
        named("default", INK, PAPER),
        named("echo-area", ECHO_INK, ECHO_PAPER),
        named("mode-line", Color::rgb(0xff, 0xff, 0xff), MODE_PAPER),
    ]
}

/// A rectangle.
fn rect(x: u32, y: u32, width: u32, height: u32) -> Rect {
    Rect {
        x,
        y,
        width,
        height,
    }
}

/// A view of a short text in `rect`, with one status field.
fn window(id: u64, rect: Rect) -> View {
    View {
        id: ViewId(id),
        rect,
        text: Some(TextRef::fixed(
            TextKey(id),
            Text::from("one\ntwo\nthree\n").snapshot(),
        )),
        status: vec![StatusField {
            text: "normal".to_owned(),
            face: "mode-line".to_owned(),
        }],
        ..View::default()
    }
}

/// A frame `width` by `height` of `views`, saying `echo`, in the theme.
fn scene(width: u32, height: u32, views: Vec<View>, echo: &str) -> Scene {
    Scene {
        size: Size { width, height },
        views,
        echo: echo.to_owned(),
        faces: Some(theme()),
        ..Scene::default()
    }
}

/// The frame of `scene`, laid out at `scale`.
fn laid(scene: &Scene, scale: f32) -> Frame {
    let mut layout = Layout::new(CellShaper::new(8.0, 16.0));
    layout.set_scale(scale);
    layout.frame(scene)
}

/// The echo view of `frame`, which must be its last, or `None` when no
/// view of it is the echo's.
fn echo_of(frame: &Frame) -> Option<&ViewFrame> {
    let echoes: Vec<usize> = (0..frame.views.len())
        .filter(|index| frame.views[*index].id == ECHO_VIEW)
        .collect();
    match echoes.as_slice() {
        [] => None,
        [index] => {
            assert_eq!(*index, frame.views.len() - 1, "the echo view is the last");
            Some(&frame.views[*index])
        }
        _ => panic!("two echo views: {}", frame.describe()),
    }
}

#[test]
fn the_echo_is_the_last_view_in_the_bottom_row_when_no_view_covers_it() {
    let frame = laid(
        &scene(640, 480, vec![window(1, rect(0, 0, 640, 464))], "saved"),
        1.0,
    );
    assert_eq!(frame.views.len(), 2);
    let echo = echo_of(&frame).expect("an echo view");
    assert_eq!(echo.id, ViewId(u64::MAX));
    assert_eq!(echo.rect, rect(0, 464, 640, 16));
    assert!(echo.rows.is_empty());
    assert!(echo.cursors.is_empty());
    assert!(echo.selections.is_empty());
    let status = echo.status.as_ref().expect("its one row");
    assert_eq!((status.y, status.height), (0.0, 16.0));
    // `saved`, one glyph a character, in the echo area's paint over the
    // default face: not the mode line's.
    let glyphs: Vec<u32> = status.line.glyphs.iter().map(|glyph| glyph.id).collect();
    assert_eq!(glyphs, "saved".chars().map(u32::from).collect::<Vec<_>>());
    assert_eq!(status.runs.len(), 1);
    let (bytes, paint) = &status.runs[0];
    assert_eq!(bytes, &(0..5));
    assert_eq!((paint.foreground, paint.background), (ECHO_INK, ECHO_PAPER));
    assert_eq!(status.background, ECHO_PAPER);
    // The window above it is laid out as it was, its status row the
    // status height.
    let window = &frame.views[0];
    assert_eq!(window.id, ViewId(1));
    let status = window.status.as_ref().expect("the window's status row");
    assert_eq!((status.y, status.height), (448.0, 16.0));
    assert_eq!(status.background, MODE_PAPER);
}

#[test]
fn an_empty_echo_lays_nothing_out() {
    let frame = laid(
        &scene(640, 480, vec![window(1, rect(0, 0, 640, 464))], ""),
        1.0,
    );
    assert!(echo_of(&frame).is_none());
    assert_eq!(frame.views.len(), 1);
}

#[test]
fn at_scale_two_the_bottom_row_is_the_message_height_at_it() {
    let frame = laid(
        &scene(1280, 960, vec![window(1, rect(0, 0, 1280, 928))], "saved"),
        2.0,
    );
    let echo = echo_of(&frame).expect("an echo view");
    assert_eq!(echo.rect, rect(0, 928, 1280, 32));
    let status = echo.status.as_ref().expect("its one row");
    assert_eq!((status.y, status.height), (0.0, 32.0));
}

#[test]
fn a_view_that_reaches_the_bottom_row_covers_it_and_its_status_row_is_the_bottom_row() {
    // The minibuffer's view while a prompt is open: its input row and the
    // bottom row, under a window.
    let frame = laid(
        &scene(
            640,
            480,
            vec![
                window(1, rect(0, 0, 640, 432)),
                window(2, rect(0, 432, 640, 48)),
            ],
            "saved",
        ),
        1.0,
    );
    assert!(echo_of(&frame).is_none());
    let minibuffer = &frame.views[1];
    let status = minibuffer.status.as_ref().expect("the prompt's row");
    assert_eq!((status.y, status.height), (32.0, 16.0));
}

#[test]
fn a_view_that_covers_any_of_the_bottom_row_covers_it() {
    // As the display fixture's second view does: it reaches the bottom
    // edge across two thirds of the width, and has no status field.
    let mut short = window(2, rect(0, 80, 64, 32));
    short.status.clear();
    let frame = laid(
        &scene(
            96,
            112,
            vec![window(1, rect(0, 0, 96, 80)), short],
            "fixture",
        ),
        1.0,
    );
    assert!(echo_of(&frame).is_none());
    // One pixel of the bottom row is enough.
    let frame = laid(
        &scene(
            640,
            480,
            vec![
                window(1, rect(0, 0, 640, 464)),
                window(2, rect(639, 479, 1, 1)),
            ],
            "saved",
        ),
        1.0,
    );
    assert!(echo_of(&frame).is_none());
    // A view that ends where the bottom row begins does not.
    let frame = laid(
        &scene(
            640,
            480,
            vec![
                window(1, rect(0, 0, 640, 464)),
                window(2, rect(600, 400, 40, 64)),
            ],
            "saved",
        ),
        1.0,
    );
    assert!(echo_of(&frame).is_some());
}

#[test]
fn a_frame_with_no_height_or_no_width_has_no_bottom_row() {
    for (width, height) in [(0, 0), (640, 0), (0, 480)] {
        let frame = laid(&scene(width, height, vec![], "saved"), 1.0);
        assert!(echo_of(&frame).is_none(), "{width} by {height}");
    }
    // A frame shorter than the message row gives it all its height.
    let frame = laid(&scene(640, 10, vec![], "saved"), 1.0);
    let echo = echo_of(&frame).expect("an echo view");
    assert_eq!(echo.rect, rect(0, 0, 640, 10));
}

#[test]
fn the_echo_row_is_the_message_height_of_the_faces_as_defined() {
    // An echo area twice as tall as the mode line.
    let mut faces = theme();
    faces[1].face.line_height = Some(editor_layout::shaper::LineHeight::Multiple(128));
    let mut layout = Layout::new(CellShaper::new(8.0, 16.0));
    let mut tall = scene(640, 480, vec![window(1, rect(0, 0, 640, 448))], "saved");
    tall.faces = Some(faces);
    let frame = layout.frame(&tall);
    assert_eq!(
        layout.heights(),
        Heights {
            text: 16,
            status: 16,
            message: 32
        }
    );
    let echo = echo_of(&frame).expect("an echo view");
    assert_eq!(echo.rect, rect(0, 448, 640, 32));
}
