//! One frame of real text, drawn by the headless adapter, against the
//! reference image checked in at `tests/render/frame.png`.
//!
//! This is wiring: the real shaper lays the fixture frame out
//! (`tests/common/mod.rs`), the real rasteriser makes its glyphs, and the
//! CPU compositor draws it. What each of those does is pinned in its own
//! crate or module; what is pinned here is that, put together, they draw
//! the picture a person looked at.
//!
//! The image is compiled in: no test reads or writes a file. It is made
//! again by `mise run render-reference`, and `tests/render/README.md`
//! says when.

mod common;

use std::sync::Arc;

use editor_layout::frame::Frame;
use editor_render::port::{DrawRequest, Renderer};
use editor_render_wgpu::{HeadlessRenderer, Image};

/// The reference image, as the file checked in.
const REFERENCE_PNG: &[u8] = include_bytes!("../../../tests/render/frame.png");

/// How far any channel of any pixel may be from the reference's: 2 of
/// 255. The compositor is deterministic on one machine; the 2 is for
/// what was never run, another processor's floating point.
const TOLERANCE: u8 = 2;

/// The reference image must differ from its own background in more than
/// this many pixels: a picture of nothing would match a frame that drew
/// nothing. As it was made it differs in 8047, of which the status row's
/// band is some 5600: the bound is past the band alone.
const INKED: usize = 6000;

/// The largest the reference image may be: 256 by 96 pixels, and 20 KB as
/// a file.
const LARGEST: (u32, u32, usize) = (256, 96, 20_000);

/// `frame` drawn by the headless adapter, as the reference image was.
fn drawn(frame: Frame) -> Image {
    let mut renderer = HeadlessRenderer::new(common::settings());
    let answer = renderer.draw(&DrawRequest {
        frame: &Arc::new(frame),
        target: common::TARGET,
    });
    assert!(answer.presented);
    renderer.image().clone()
}

#[test]
fn a_frame_through_the_headless_adapter_matches_the_reference_image() {
    let reference = common::decode(REFERENCE_PNG);
    let image = drawn(common::fixture_frame());
    assert_eq!(
        (image.width, image.height),
        (reference.width, reference.height)
    );
    let (worst, differing) = common::difference(&image, &reference).expect("images of one size");
    assert!(
        worst <= TOLERANCE,
        "{differing} pixels differ from tests/render/frame.png, one by {worst} of 255; the tolerance is {TOLERANCE}"
    );
}

#[test]
fn a_frame_with_one_character_changed_does_not_match_it() {
    // The tolerance is not slack: one letter of the fixture changed, an
    // `e` for an `o`, is a picture the comparison refuses.
    let changed = common::TEXT.replacen("fine", "fino", 1);
    assert_ne!(changed, common::TEXT);
    let frame = common::layout().frame(&common::scene_of(&changed, common::SELECTED));
    let reference = common::decode(REFERENCE_PNG);
    let (worst, differing) =
        common::difference(&drawn(frame), &reference).expect("images of one size");
    assert!(worst > TOLERANCE, "the largest difference is {worst}");
    // And it differs along one row of text, not everywhere: in fewer
    // than a tenth of the picture's pixels.
    let pixels = (reference.width * reference.height) as usize;
    assert!(differing < pixels / 10, "{differing} pixels differ");
}

#[test]
fn the_reference_is_not_its_background() {
    let reference = common::decode(REFERENCE_PNG);
    let inked = reference
        .rgba
        .as_chunks::<4>()
        .0
        .iter()
        .filter(|pixel| **pixel != common::BACKGROUND)
        .count();
    assert!(inked > INKED, "{inked} pixels are not the background");
    // And it is kept small.
    assert!(reference.width <= LARGEST.0 && reference.height <= LARGEST.1);
    assert!(REFERENCE_PNG.len() <= LARGEST.2, "{}", REFERENCE_PNG.len());
}
