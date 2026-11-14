//! The headless adapter at two scales: what the picture's size is, and
//! what is thicker.
//!
//! A frame is in physical pixels, so one frame is drawn at both scales:
//! what changes is the target's scale, and with it the thickness of the
//! lines the renderer itself sizes. The frames are of layout's fake
//! shaper, whose glyphs have no image: the lines are what is looked at.

use std::collections::BTreeSet;
use std::sync::Arc;

use editor_layout::Layout;
use editor_layout::face::{Color, Face, FaceDef, Underline, UnderlineStyle};
use editor_layout::frame::Frame;
use editor_layout::scene::{Cursor, CursorShape, Decoration, Rect, Scene};
use editor_layout::shaper::fake::CellShaper;
use editor_render::port::{DrawRequest, Renderer, Target};
use editor_render_wgpu::{HeadlessRenderer, Image, Settings};

/// The colour of the fixture's underline.
const RED: [u8; 4] = [0xff, 0, 0, 0xff];
/// The colour of the fixture's cursor.
const GREEN: [u8; 4] = [0, 0xff, 0, 0xff];

/// A frame of one view, 120 by 48: a word underlined in red, and a green
/// bar cursor after it.
fn fixture() -> Arc<Frame> {
    let rect = Rect {
        x: 0,
        y: 0,
        width: 120,
        height: 48,
    };
    let named = |name: &str, face: Face| FaceDef {
        name: name.to_owned(),
        face,
    };
    let mut scene = Scene::of_text("under line", rect).selecting(7..7);
    scene.faces = Some(vec![
        named(
            "note",
            Face {
                underline: Some(Underline {
                    style: UnderlineStyle::Single,
                    color: Some(Color::rgb(0xff, 0, 0)),
                }),
                ..Face::default()
            },
        ),
        named(
            "cursor",
            Face {
                background: Some(Color::rgb(0, 0xff, 0)),
                ..Face::default()
            },
        ),
    ]);
    scene.views[0].decorations = vec![Decoration {
        start: 0,
        stop: 5,
        face: "note".to_owned(),
    }];
    scene.views[0].cursor = Cursor {
        shape: CursorShape::Bar,
        face: "cursor".to_owned(),
    };
    Arc::new(Layout::new(CellShaper::new(10.0, 16.0)).frame(&scene))
}

/// The fixture drawn on a target `width` by `height` at `scale`.
fn drawn(width: u32, height: u32, scale: f32) -> Image {
    let mut renderer = HeadlessRenderer::new(Settings::default());
    let target = Target {
        width,
        height,
        scale,
    };
    renderer.draw(&DrawRequest {
        frame: &fixture(),
        target,
    });
    renderer.image().clone()
}

/// The columns and the rows of `image` that hold a pixel of `color`.
fn extent(image: &Image, color: [u8; 4]) -> (usize, usize) {
    let (mut columns, mut rows) = (BTreeSet::new(), BTreeSet::new());
    for y in 0..image.height {
        for x in 0..image.width {
            if image.pixel(x, y) == Some(color) {
                columns.insert(x);
                rows.insert(y);
            }
        }
    }
    (columns.len(), rows.len())
}

#[test]
fn the_image_is_the_targets_size() {
    let small = drawn(120, 48, 1.0);
    assert_eq!((small.width, small.height), (120, 48));
    assert_eq!(small.rgba.len(), 120 * 48 * 4);
    let large = drawn(240, 96, 2.0);
    assert_eq!((large.width, large.height), (240, 96));
    assert_eq!(large.rgba.len(), 240 * 96 * 4);
    // A renderer drawn on again at another size gives a picture of that
    // size.
    let mut renderer = HeadlessRenderer::new(Settings::default());
    for (width, height) in [(120, 48), (60, 20), (300, 100)] {
        let target = Target {
            width,
            height,
            scale: 1.0,
        };
        renderer.draw(&DrawRequest {
            frame: &fixture(),
            target,
        });
        assert_eq!(
            (renderer.image().width, renderer.image().height),
            (width, height)
        );
    }
}

#[test]
fn an_underline_and_a_bar_cursor_are_twice_as_thick_at_scale_two() {
    let (one, two) = (drawn(120, 48, 1.0), drawn(120, 48, 2.0));
    // The underline: as wide at both scales, and twice as many rows.
    let (across, down) = extent(&one, RED);
    assert!(across > 1 && down > 0);
    assert_eq!(extent(&two, RED), (across, down * 2));
    // The bar cursor: as tall at both scales, and twice as many columns.
    let (across, down) = extent(&one, GREEN);
    assert!(across > 0 && down > 1);
    assert_eq!(extent(&two, GREEN), (across * 2, down));
}
