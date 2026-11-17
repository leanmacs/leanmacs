//! Views that overlap, drawn by the headless adapter.
//!
//! The painter draws the frame's views in order, each over its own
//! background ([`painter`](editor_render_wgpu), "What is drawn, in
//! order"), so where two views overlap the later one is what shows: a
//! floating window, listed after the tiles it floats over, is drawn above
//! them. This pins that order, with no change to the painter.
//!
//! The frame is of layout's fake shaper, whose glyphs have no image, so the
//! earlier view's paint is a face's background over every character of its
//! text: what its glyphs would be drawn over.

use std::sync::Arc;

use editor_layout::Layout;
use editor_layout::face::{Color, Face, FaceDef};
use editor_layout::scene::{Decoration, Rect, Scene, Size, View, ViewId};
use editor_layout::shaper::fake::CellShaper;
use editor_render::port::{DrawRequest, Renderer, Target};
use editor_render_wgpu::{HeadlessRenderer, Image, Settings};

/// The default face's background: every view's paper.
const PAPER: [u8; 4] = [0x10, 0x20, 0x30, 0xff];
/// The background of the face the earlier view's text is decorated in.
const MARK: [u8; 4] = [0xff, 0x40, 0x80, 0xff];

/// The rectangle of the later view, inside the earlier one's.
const INNER: Rect = Rect {
    x: 16,
    y: 8,
    width: 40,
    height: 32,
};

/// A frame of 80 by 64 with two views: view 1, the whole frame, whose text
/// of three rows of ten characters is decorated in `mark` from end to end,
/// and view 2, `INNER`, which shows nothing; in that order, or the other
/// way round when `reversed`.
fn scene(reversed: bool) -> Scene {
    let text = "aaaaaaaaaa\naaaaaaaaaa\naaaaaaaaaa";
    let mut scene = Scene::of_text(
        text,
        Rect {
            x: 0,
            y: 0,
            width: 80,
            height: 64,
        },
    );
    scene.size = Size {
        width: 80,
        height: 64,
    };
    scene.views[0].decorations = vec![Decoration {
        start: 0,
        stop: text.len(),
        face: "mark".to_owned(),
    }];
    let inner = View {
        id: ViewId(2),
        rect: INNER,
        ..View::default()
    };
    if reversed {
        scene.views.insert(0, inner);
    } else {
        scene.views.push(inner);
    }
    let background = |[red, green, blue, _]: [u8; 4]| Face {
        background: Some(Color::rgb(red, green, blue)),
        ..Face::default()
    };
    scene.faces = Some(vec![
        FaceDef {
            name: "default".to_owned(),
            face: background(PAPER),
        },
        FaceDef {
            name: "mark".to_owned(),
            face: background(MARK),
        },
    ]);
    scene
}

/// `scene` laid out on the fake shaper, 8 pixels across and 16 down, and
/// drawn by the headless adapter.
fn drawn(scene: &Scene) -> Image {
    let frame = Arc::new(Layout::new(CellShaper::new(8.0, 16.0)).frame(scene));
    let mut renderer = HeadlessRenderer::new(Settings::default());
    let drawn = renderer.draw(&DrawRequest {
        frame: &frame,
        target: Target {
            width: 80,
            height: 64,
            scale: 1.0,
        },
    });
    assert!(drawn.presented);
    renderer.image().clone()
}

/// The pixels inside `INNER`.
fn inner_pixels() -> impl Iterator<Item = (u32, u32)> {
    (INNER.y..INNER.y + INNER.height)
        .flat_map(|y| (INNER.x..INNER.x + INNER.width).map(move |x| (x, y)))
}

#[test]
fn a_later_view_is_drawn_over_an_earlier_one_where_they_overlap() {
    let image = drawn(&scene(false));
    // The earlier view's paint is there outside the overlap.
    assert_eq!(image.pixel(4, 4), Some(MARK));
    assert_eq!(image.pixel(72, 40), Some(MARK));
    // And none of it inside: the later view's paper is all there is.
    for (x, y) in inner_pixels() {
        assert_eq!(image.pixel(x, y), Some(PAPER), "the pixel at {x}, {y}");
    }
}

#[test]
fn the_order_is_the_scenes_the_earlier_view_listed_last_is_drawn_over() {
    let image = drawn(&scene(true));
    // View 1, listed last, covers view 2 with its decorated text rows.
    assert!(inner_pixels().any(|(x, y)| image.pixel(x, y) == Some(MARK)));
}
