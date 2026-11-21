//! A renderer handed a rasteriser (`rasterizing_with`): it draws its
//! glyphs with that one, and with swash for every glyph that one declines.
//!
//! Through the public API alone, on the headless adapter. The rasteriser
//! handed over is the port's published fake (`editor_raster::fake`). No
//! shaper runs: one frame is of layout's fake shaper, whose fonts have no
//! bytes, and the other is built by hand from the frame's public data, a
//! fixture font compiled in with its glyph ids and positions written out,
//! as `src/weight_tests.rs` builds its sentence. The ids are those of the
//! font's own character map (`H` 41, `I` 42, the space 1), read once
//! through swash's.

use std::sync::Arc;

use editor_layout::Layout;
use editor_layout::face::{Color, Paint};
use editor_layout::frame::{Frame, FrameRow, ViewFrame};
use editor_layout::scene::{Rect, Scene, ViewId};
use editor_layout::shaper::fake::CellShaper;
use editor_layout::shaper::{Glyph, ResolvedFont, ResolvedFontId, VisualLine};
use editor_raster::fake::FakeRasterizer;
use editor_render::port::{DrawRequest, Drawn, Renderer, Target};
use editor_render_wgpu::{Blending, HeadlessRenderer, Image, Settings};

/// Noto Sans Mono.
const MONO: &[u8] = include_bytes!("../../../tests/fonts/NotoSansMono-Regular.subset.ttf");

/// The ids of `H`, `I` and the space in it.
const IDS: [u32; 3] = [41, 42, 1];

/// The target: 120 by 40 pixels, at scale 1.
const TARGET: Target = Target {
    width: 120,
    height: 40,
    scale: 1.0,
};

const WHITE: Color = Color::rgb(0xff, 0xff, 0xff);
const BLACK: Color = Color::rgb(0, 0, 0);

/// Draws `frame` with `renderer`: what the draw said.
fn draw(renderer: &mut HeadlessRenderer, frame: Frame) -> Drawn {
    renderer.draw(&DrawRequest {
        frame: &Arc::new(frame),
        target: TARGET,
    })
}

/// How many pixels of `image` are not white.
fn inked(image: &Image) -> usize {
    image
        .rgba
        .as_chunks::<4>()
        .0
        .iter()
        .filter(|pixel| pixel[..3] != [0xff, 0xff, 0xff])
        .count()
}

/// A frame of layout's fake shaper: a line of text in one view the
/// target's size, white behind, with no cursor.
fn fake_shaped() -> Frame {
    let rect = Rect {
        x: 0,
        y: 0,
        width: TARGET.width,
        height: TARGET.height,
    };
    let frame = Layout::new(CellShaper::new(10.0, 16.0)).frame(&Scene::of_text("abc", rect));
    assert_eq!(frame.views[0].background, WHITE);
    frame
}

/// The fixture font at 16 pixels.
fn mono() -> ResolvedFont {
    ResolvedFont {
        data: Arc::new(MONO),
        file: 1,
        index: 0,
        size: 16.0,
        coords: Vec::new(),
        embolden: false,
        skew: None,
    }
}

/// `H I H` in the fixture font, black on white, in one view the target's
/// size, each glyph 9.6 pixels on from the last (the font's advance at 16
/// pixels) from 4.3 pixels in, so that the glyphs fall in several bins.
fn fixture_frame() -> Frame {
    let ids = [IDS[0], IDS[2], IDS[1], IDS[2], IDS[0]];
    let advance = 9.6;
    let glyphs: Vec<Glyph> = ids
        .iter()
        .enumerate()
        .map(|(index, id)| Glyph {
            id: *id,
            font: ResolvedFontId(0),
            cluster: index,
            x: 4.3 + index as f32 * advance,
            dx: 0.0,
            dy: 0.0,
            advance,
        })
        .collect();
    let bytes = 0..ids.len();
    let paint = Paint {
        foreground: BLACK,
        background: WHITE,
        underline: None,
        strike_through: false,
    };
    let line = Arc::new(VisualLine {
        bytes: bytes.clone(),
        glyphs,
        width: 4.3 + ids.len() as f32 * advance,
        height: 24.0,
        baseline: 18.0,
    });
    let row = FrameRow::text_row(0.0, 4.0, bytes.clone(), line, vec![(bytes, paint)], 1);
    Frame {
        ground: WHITE,
        views: vec![ViewFrame {
            id: ViewId(1),
            rect: Rect {
                x: 0,
                y: 0,
                width: TARGET.width,
                height: TARGET.height,
            },
            background: WHITE,
            rows: vec![row],
            status: None,
            cursors: Vec::new(),
            selections: Vec::new(),
            selection: WHITE,
        }],
        generation: 0,
        fonts: Arc::from(vec![mono()]),
        dividers: Vec::new(),
    }
}

#[test]
fn a_renderer_draws_no_glyph_of_a_font_with_no_bytes() {
    let mut renderer = HeadlessRenderer::new(Settings::default());
    let drawn = draw(&mut renderer, fake_shaped());
    assert!(drawn.glyphs_skipped > 0, "{drawn:?}");
    assert_eq!(inked(renderer.image()), 0);
}

#[test]
fn a_renderer_handed_a_rasteriser_draws_its_glyphs_with_it() {
    let mut renderer =
        HeadlessRenderer::new(Settings::default()).rasterizing_with(FakeRasterizer::new());
    let drawn = draw(&mut renderer, fake_shaped());
    assert!(drawn.glyphs_rasterised > 0, "{drawn:?}");
    // The fake's boxes are drawn in the text's colour, on the first row
    // alone.
    let image = renderer.image();
    assert!(inked(image) > 0);
    for y in 16..image.height {
        for x in 0..image.width {
            let pixel = image.pixel(x, y).expect("a pixel");
            assert_eq!(pixel[..3], [0xff, 0xff, 0xff], "at {x}, {y}");
        }
    }
}

#[test]
fn a_glyph_the_rasteriser_declines_is_drawn_by_swash_at_the_settings_weight() {
    // Core Text's settings, whose dilation is not none: the fallback is
    // made at the settings' weight, or the pictures would differ.
    let settings = Settings::core_text();
    let mut declines = FakeRasterizer::new();
    declines.missing.extend(IDS);
    let mut plain = HeadlessRenderer::new(settings);
    let mut handed = HeadlessRenderer::new(settings).rasterizing_with(declines);
    let (one, other) = (
        draw(&mut plain, fixture_frame()),
        draw(&mut handed, fixture_frame()),
    );
    assert!(one.glyphs_rasterised > 0 && other.glyphs_rasterised > 0);
    assert!(inked(plain.image()) > 0);
    assert_eq!(handed.image(), plain.image());
}

#[test]
fn a_renderer_blends_as_its_settings_say_and_encoded_is_never_lighter() {
    let in_space = |blending| {
        let mut renderer = HeadlessRenderer::new(Settings {
            blending,
            ..Settings::default()
        });
        assert_eq!(renderer.blending(), blending);
        let drawn = draw(&mut renderer, fixture_frame());
        assert!(drawn.glyphs_rasterised > 0, "{drawn:?}");
        renderer.image().clone()
    };
    let (encoded, linear) = (in_space(Blending::Encoded), in_space(Blending::Linear));
    assert_ne!(encoded, linear);
    // The sRGB encoding is concave, so a blend of two values in linear
    // light is never below the blend of the values themselves: linear
    // light thins dark text on a light ground, and thickens light text on
    // a dark one.
    for (index, (ours, theirs)) in encoded.rgba.iter().zip(&linear.rgba).enumerate() {
        assert!(
            ours <= theirs,
            "byte {index}: encoded {ours}, linear {theirs}"
        );
    }
}
