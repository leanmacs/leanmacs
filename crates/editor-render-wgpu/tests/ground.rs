//! What a renderer clears its target to: the frame's ground, the theme's
//! paper, and never black.
//!
//! Through the public API alone, on the headless adapter, with a frame
//! built by hand from the frame's public data: no shaper runs and no
//! glyph is drawn.

use std::sync::Arc;

use editor_layout::face::Color;
use editor_layout::frame::{Frame, ViewFrame};
use editor_layout::scene::{Rect, ViewId};
use editor_render::port::{DrawRequest, Renderer, Target};
use editor_render_wgpu::{Blending, HeadlessRenderer, Settings};

/// A paper that is not black.
const PAPER: Color = Color::rgb(0x2e, 0x34, 0x40);

/// The background of the one view.
const VIEW: Color = Color::rgb(0xec, 0xef, 0xf4);

/// The target: 40 by 10 pixels, at scale 1.
const TARGET: Target = Target {
    width: 40,
    height: 10,
    scale: 1.0,
};

/// A frame on the ground [`PAPER`] whose one view, on [`VIEW`], covers the
/// left half of the target: what a frame laid out for a smaller target
/// is on a larger one.
fn half_covered() -> Frame {
    Frame {
        ground: PAPER,
        views: vec![ViewFrame {
            id: ViewId(1),
            rect: Rect {
                x: 0,
                y: 0,
                width: TARGET.width / 2,
                height: TARGET.height,
            },
            background: VIEW,
            rows: Vec::new(),
            status: None,
            cursors: Vec::new(),
            selections: Vec::new(),
            selection: VIEW,
        }],
        ..Frame::default()
    }
}

/// The opaque pixel of `color`.
fn pixel(color: Color) -> [u8; 4] {
    let [red, green, blue, _] = color.0.to_be_bytes();
    [red, green, blue, 0xff]
}

#[test]
fn where_no_view_is_the_target_is_the_frames_ground_and_nowhere_black() {
    for blending in [Blending::Linear, Blending::Encoded] {
        let mut renderer = HeadlessRenderer::new(Settings {
            blending,
            ..Settings::default()
        });
        let drawn = renderer.draw(&DrawRequest {
            frame: &Arc::new(half_covered()),
            target: TARGET,
        });
        assert!(drawn.presented);
        let image = renderer.image();
        for y in 0..TARGET.height {
            for x in 0..TARGET.width {
                let expected = if x < TARGET.width / 2 { VIEW } else { PAPER };
                assert_eq!(
                    image.pixel(x, y),
                    Some(pixel(expected)),
                    "{blending:?} at {x}, {y}"
                );
            }
        }
    }
}

#[test]
fn a_frame_made_by_hand_with_no_ground_is_cleared_to_opaque_black() {
    let mut renderer = HeadlessRenderer::new(Settings::default());
    renderer.draw(&DrawRequest {
        frame: &Arc::new(Frame::default()),
        target: TARGET,
    });
    let image = renderer.image();
    assert!(
        image
            .rgba
            .as_chunks::<4>()
            .0
            .iter()
            .all(|pixel| *pixel == [0, 0, 0, 0xff])
    );
}
