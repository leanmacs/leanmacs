//! The echo in the frame's bottom row, drawn by the headless adapter.
//!
//! Layout lays the echo out as one more view whose one row is a status
//! row (`editor_layout::frame`, "The bottom row"), so the painter draws it
//! as it draws any status row, and nothing here is new to the renderer.
//! This shows that: the row's background is in the strip, and nowhere
//! else. The frame is of layout's fake shaper, whose glyphs have no image.

use std::sync::Arc;

use editor_layout::Layout;
use editor_layout::face::{Color, Face, FaceDef};
use editor_layout::scene::{Rect, Scene, Size, StatusField, View, ViewId};
use editor_layout::shaper::fake::CellShaper;
use editor_render::port::{DrawRequest, Renderer, Target};
use editor_render_wgpu::{HeadlessRenderer, Settings};

/// The echo area's background.
const ECHO: [u8; 4] = [0xff, 0xe0, 0x40, 0xff];
/// The default face's background.
const PAPER: [u8; 4] = [0x10, 0x20, 0x30, 0xff];

#[test]
fn the_echo_is_drawn_in_the_bottom_row_in_the_echo_areas_background() {
    let background = |[red, green, blue, _]: [u8; 4]| Face {
        background: Some(Color::rgb(red, green, blue)),
        ..Face::default()
    };
    let named = |name: &str, face: Face| FaceDef {
        name: name.to_owned(),
        face,
    };
    // A window of the frame's top 32 pixels, with a status row, and the
    // echo `saved` in the bottom 16.
    let scene = Scene {
        size: Size {
            width: 80,
            height: 48,
        },
        views: vec![View {
            id: ViewId(1),
            rect: Rect {
                x: 0,
                y: 0,
                width: 80,
                height: 32,
            },
            status: vec![StatusField {
                text: "normal".to_owned(),
                face: "mode-line".to_owned(),
            }],
            ..View::default()
        }],
        echo: "saved".to_owned(),
        faces: Some(vec![
            named("default", background(PAPER)),
            named("echo-area", background(ECHO)),
        ]),
        ..Scene::default()
    };
    let frame = Arc::new(Layout::new(CellShaper::new(8.0, 16.0)).frame(&scene));
    let mut renderer = HeadlessRenderer::new(Settings::default());
    let drawn = renderer.draw(&DrawRequest {
        frame: &frame,
        target: Target {
            width: 80,
            height: 48,
            scale: 1.0,
        },
    });
    assert!(drawn.presented);
    let image = renderer.image();
    for y in 0..48 {
        for x in 0..80 {
            let echo = image.pixel(x, y) == Some(ECHO);
            assert_eq!(echo, y >= 32, "the pixel at {x}, {y}");
        }
    }
}
