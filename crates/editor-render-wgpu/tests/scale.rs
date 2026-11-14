//! The headless adapter at two scales: what the picture's size is, what
//! is thicker, and which masks it says it asked for.
//!
//! A frame is in physical pixels: layout has already multiplied a theme's
//! lengths by the scale it was laid out for, and the renderer multiplies
//! nothing in it. So one frame is drawn here at both scales, to show what
//! the target's scale alone changes: the thickness of the lines the
//! renderer itself sizes, and the kind of mask. (A window's frames are
//! laid out again at a new scale, and this is what would be seen if one
//! were not.) The frames are of layout's fake shaper, whose glyphs have no
//! image: the lines are what is looked at.

use std::collections::BTreeSet;
use std::sync::Arc;

use editor_layout::Layout;
use editor_layout::face::{Color, Face, FaceDef, Underline, UnderlineStyle};
use editor_layout::frame::Frame;
use editor_layout::scene::{Cursor, CursorShape, Decoration, Rect, Scene};
use editor_layout::shaper::fake::CellShaper;
use editor_render::port::{DrawRequest, Renderer, Target};
use editor_render_wgpu::{HeadlessRenderer, Image, Masks, Settings, SubpixelOrder};

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
fn a_target_of_no_size_is_presented_as_a_picture_of_no_size() {
    // A window made as small as it goes has a side of no pixels. The
    // frame is presented all the same, so the loop has no draw to try
    // again, and the picture has no pixel.
    let mut renderer = HeadlessRenderer::new(Settings::default());
    for (width, height) in [(0, 0), (0, 48), (120, 0)] {
        let target = Target {
            width,
            height,
            scale: 1.0,
        };
        let drawn = renderer.draw(&DrawRequest {
            frame: &fixture(),
            target,
        });
        assert!(drawn.presented, "{width} by {height}");
        let image = renderer.image();
        assert_eq!((image.width, image.height), (width, height));
        assert!(image.rgba.is_empty(), "{width} by {height}");
    }
    // And the renderer draws as before on a target with a size again.
    let target = Target {
        width: 120,
        height: 48,
        scale: 1.0,
    };
    let drawn = renderer.draw(&DrawRequest {
        frame: &fixture(),
        target,
    });
    assert!(drawn.presented);
    assert_eq!(renderer.image(), &self::drawn(120, 48, 1.0));
}

#[test]
fn the_headless_renderer_says_the_masks_of_its_last_draw() {
    let mut renderer = HeadlessRenderer::new(Settings::default());
    assert_eq!(renderer.masks(), None);
    let mut draw_at = |scale: f32| {
        let target = Target {
            width: 120,
            height: 48,
            scale,
        };
        renderer.draw(&DrawRequest {
            frame: &fixture(),
            target,
        });
        renderer.masks()
    };
    // As the settings come, the kind follows the target's scale. Which
    // scale it changes at is the renderer's rule, and its own tests'.
    assert_eq!(draw_at(1.0), Some(Masks::Subpixel(SubpixelOrder::Rgb)));
    assert_eq!(draw_at(2.0), Some(Masks::Plain));
    assert_eq!(draw_at(1.0), Some(Masks::Subpixel(SubpixelOrder::Rgb)));
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
