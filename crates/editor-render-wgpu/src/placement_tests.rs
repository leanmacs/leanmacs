//! The painter puts each glyph on Core Text's own grid, from Core Text's
//! own places.
//!
//! A frame built by hand, as `weight_tests` builds its sentence: each glyph
//! of "the window draws this" at the place Core Text gave it on macOS
//! (`tests/coretext/positions.txt`, compiled in), painted through a
//! [`Painter`] over the rasteriser port's published fake at scale 1 and 2.
//! For each glyph, its quad's whole pixel plus its bin's offset is Core
//! Text's place floored to Core Text's grid, as measured on macOS 27.2.1
//! (thirds of a pixel at scale 1, halves at scale 2; `glyphs::bin_of`),
//! and its baseline is the row's whole pixel. No shaper runs: the shaper's
//! own places are held to Core Text's by `editor-shape-parley`'s
//! `tests/core_text.rs`, within an eighth of a pixel, so together the two
//! bound where a glyph is drawn against where Core Text draws it.
//!
//! This checks the painter's rule against new data, so it passed at its
//! first run. Seen to bite once by hand (2026-11-20): with every glyph of
//! the frame moved right by 0.3 px, the test failed at its second glyph
//! at scale 1, Core Text's 8.4 on its grid at 8 1/3 and ours at 8 2/3.

use std::sync::Arc;

use editor_layout::face::{Color, Paint};
use editor_layout::frame::{Frame, FrameRow, ViewFrame};
use editor_layout::scene::{Rect, ViewId};
use editor_layout::shaper::{Glyph, ResolvedFontId, VisualLine};
use editor_raster::fake::{FakeRasterizer, font};
use editor_render::port::Target;

use crate::glyphs::{GlyphKey, SUBPIXEL_BINS};
use crate::painter::Painter;
use crate::quads::QuadKind;
use crate::{Antialiasing, Settings};

/// Core Text's places of the sentence in the fixture font at 14 points.
const POSITIONS: &str = include_str!("../../../tests/coretext/positions.txt");

/// The text's colour, which picks its quads out of the paint.
const INK: Color = Color::rgb(0, 0, 0);

/// The row's baseline, in pixels down from the view's top.
const BASELINE: f32 = 40.0;

/// Core Text's places at `scale`, each a glyph's id and its pen's place
/// across, in device pixels from the line's origin.
fn places(scale: u32) -> Vec<(u32, f64)> {
    POSITIONS
        .lines()
        .filter(|line| !line.trim().is_empty() && !line.starts_with('#'))
        .map(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            let number = |at: usize| fields[at].parse::<f64>().expect("a number");
            (number(0) as u32, number(1) as u32, number(2))
        })
        .filter(|(at, _, _)| *at == scale)
        .map(|(_, glyph, x)| (glyph, x))
        .collect()
}

/// Core Text's grid at `scale`, measured: how many places a pixel.
fn core_texts_places(scale: u32) -> f64 {
    match scale {
        1 => 3.0,
        2 => 2.0,
        _ => 1.0,
    }
}

/// The frame of the glyphs of `places` on one row, at 14 points at
/// `scale`.
fn frame(places: &[(u32, f64)], scale: u32) -> Frame {
    let glyphs: Vec<Glyph> = places
        .iter()
        .enumerate()
        .map(|(cluster, (id, x))| Glyph {
            id: *id,
            font: ResolvedFontId(0),
            cluster,
            x: *x as f32,
            dx: 0.0,
            dy: 0.0,
            advance: 8.4 * scale as f32,
        })
        .collect();
    let bytes = 0..glyphs.len();
    let paint = Paint {
        foreground: INK,
        background: Color::rgb(0xff, 0xff, 0xff),
        underline: None,
        strike_through: false,
    };
    let line = Arc::new(VisualLine {
        bytes: bytes.clone(),
        glyphs,
        width: 400.0,
        height: 60.0,
        baseline: BASELINE,
    });
    let row = FrameRow::text_row(0.0, 0.0, bytes.clone(), line, vec![(bytes, paint)], 1);
    Frame {
        ground: Color::rgb(0xff, 0xff, 0xff),
        views: vec![ViewFrame {
            id: ViewId(1),
            rect: Rect {
                x: 0,
                y: 0,
                width: 400,
                height: 60,
            },
            background: Color::rgb(0xff, 0xff, 0xff),
            rows: vec![row],
            status: None,
            cursors: Vec::new(),
            selections: Vec::new(),
            selection: Color::rgb(0xff, 0xff, 0xff),
        }],
        generation: 0,
        fonts: Arc::from(vec![font(14.0 * scale as f32)]),
        dividers: Vec::new(),
    }
}

/// Each glyph's quad's whole pixel, its bin and its baseline, as the
/// painter put it at `scale`, in the order of the glyphs.
fn painted(places: &[(u32, f64)], scale: u32) -> Vec<(i32, u8, i32)> {
    let settings = Settings {
        antialiasing: Antialiasing::Grayscale,
        ..Settings::default()
    };
    let mut painter = Painter::new(FakeRasterizer::new(), &settings, true, 1024);
    painter.paint(
        &frame(places, scale),
        Target {
            width: 400,
            height: 60,
            scale: scale as f32,
        },
    );
    // The fake is asked once for each key, in the order the glyphs first
    // need it, and a key's quads all read its one image: so each new image
    // read is the next key asked.
    let mut asked = painter.rasterizer().asked.iter().map(|(key, _, _)| *key);
    let mut keys: Vec<((u32, u32, u32), GlyphKey)> = Vec::new();
    painter
        .quads()
        .iter()
        .filter(|quad| quad.kind == QuadKind::Mask && quad.color == INK)
        .map(|quad| {
            let image = (quad.page, quad.u, quad.v);
            let key = match keys.iter().find(|(seen, _)| *seen == image) {
                Some((_, key)) => *key,
                None => {
                    let key = asked.next().expect("a key for each image");
                    keys.push((image, key));
                    key
                }
            };
            // The fake's image is its height above the baseline, its left
            // at the pen.
            (quad.x, key.bin, quad.y + quad.height as i32)
        })
        .collect()
}

#[test]
fn each_glyph_is_on_core_texts_grid_at_core_texts_place_at_both_scales() {
    for scale in [1, 2] {
        let places = places(scale);
        assert_eq!(places.len(), "the window draws this".len(), "at {scale}");
        let quads = painted(&places, scale);
        assert_eq!(quads.len(), places.len(), "at {scale}");
        let per = core_texts_places(scale);
        for (index, ((_, x), (whole, bin, baseline))) in places.iter().zip(&quads).enumerate() {
            let theirs = (x * per).floor() / per;
            let ours = f64::from(*whole) + f64::from(*bin) / f64::from(SUBPIXEL_BINS);
            assert!(
                (ours - theirs).abs() < 1e-9,
                "glyph {index} at scale {scale}: Core Text's place {x} is {theirs} on its grid, ours {ours}"
            );
            assert_eq!(*baseline, BASELINE as i32, "glyph {index} at scale {scale}");
        }
    }
}
