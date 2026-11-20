//! How heavy a run of text comes out: the renderer's against Core
//! Text's, and under each thing that makes it heavier.
//!
//! The target is `tests/coretext/sentence.png`: the sentence `the window
//! draws this` as Core Text draws it from the fixture font Noto Sans Mono
//! at 14 pt on a bitmap of scale 2, black on white
//! (`tests/coretext/README.md` says how it was captured). The renderer's
//! side is the same sentence drawn through its CPU path, a
//! [`HeadlessRenderer`], on a frame built by hand ([`sentence`]): each
//! glyph at the pen position Core Text gives it, on a target of the same
//! size, black on white. No shaper runs.
//!
//! Both are counted by one function, [`weigh`]: the pixels darker than
//! mid-grey (below 128), and the ink, how far below the white ground the
//! pixels are, summed. The ground adds nothing to either.
//!
//! The font is a stand-in for Menlo, whose licence keeps it out of the
//! repository: the numbers are of the stand-in, at one size, 28 pixels.
//!
//! # The fit
//!
//! `Weight::CORE_TEXT`, with the hinting `Settings::core_text` gives it,
//! was chosen by sweeping a grid ([`grid`]): the contrast from 0 to 1
//! and the dilation from 0 to 0.8 pixels, each in steps of 0.1, with
//! hinting on and off. Each point's error is the larger of the parts by
//! which its dark pixels and its ink miss the reference's; the point of
//! least error was taken, its error being under the tolerance of a tenth.
//! A finer step of 0.05 around it was not tried: its error, 0.010,
//! leaves no more than 0.01 to gain, which would fit the constant to one
//! sentence. The macOS setting is held to the tolerance, and to being
//! no worse than its neighbours on the grid and the default; the whole
//! grid is swept again by setting [`FULL_SWEEP`].
//!
//! The direction tests below draw each glyph over its own image, as if
//! no two touched, and state relations only: dilating the outline,
//! raising the coverage, blending on sRGB values and drawing black on
//! white each add ink. The counts are printed by
//! `cargo test --locked -p editor-render-wgpu --lib weight_tests -- --nocapture`,
//! and recorded in `docs/design/text-and-display.md`. Nothing here reads
//! a file or the environment: the font and the reference are compiled in.

use std::io::Cursor;
use std::sync::Arc;

use editor_layout::face::{Color, Paint};
use editor_layout::frame::{Frame, FrameRow, ViewFrame};
use editor_layout::scene::{Rect, ViewId};
use editor_layout::shaper::{Glyph, ResolvedFont, ResolvedFontId, VisualLine};
use editor_render::port::{DrawRequest, Renderer, Target};

use crate::glyphs::{GlyphImage, GlyphKey, GlyphRequest, Rasterize};
use crate::quads::QuadKind;
use crate::raster::SwashRasterizer;
use crate::raster::measure::{advance_of, glyph_of};
use crate::{HeadlessRenderer, Settings, Weight, blend};

/// Noto Sans Mono, the stand-in for Menlo.
const MONO: &[u8] = include_bytes!("../../../tests/fonts/NotoSansMono-Regular.subset.ttf");

/// Core Text's drawing of the sentence: `tests/coretext/sentence.png`.
const REFERENCE_PNG: &[u8] = include_bytes!("../../../tests/coretext/sentence.png");

/// How far across and down the reference is, as its README says.
const REFERENCE_SIZE: (u32, u32) = (385, 71);

/// The sentence the owner measured.
const SENTENCE: &str = "the window draws this";

/// Menlo 14 pt at scale 2, in pixels.
const SIZE: f32 = 28.0;

/// Where the reference's line starts, in pixels from its left edge.
const MARGIN: f32 = 16.0;

/// Where the reference's baseline is, in pixels up from its bottom.
const BASELINE_UP: f32 = 25.0;

/// The dilations swept by the direction tests, in pixels a stem is made
/// thicker.
const GROWTHS: [f32; 4] = [0.15, 0.3, 0.45, 0.6];

/// The amounts of the coverage adjustment swept by the direction tests.
const CONTRASTS: [f32; 3] = [0.25, 0.5, 1.0];

const BLACK: Color = Color::rgb(0, 0, 0);
const WHITE: Color = Color::rgb(0xff, 0xff, 0xff);

/// The stand-in font at the size the owner saw.
fn font() -> ResolvedFont {
    ResolvedFont {
        data: Arc::new(MONO),
        file: 1,
        index: 0,
        size: SIZE,
        coords: Vec::new(),
        embolden: false,
        skew: None,
    }
}

/// What is counted of a run of text on a white ground.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Counts {
    /// How many pixels are darker than mid-grey: below 128.
    dark: u64,
    /// How much darker than the ground the pixels are, summed.
    ink: u64,
}

/// The counts of `gray`, one value a pixel, over a ground of `ground`:
/// the one way both the reference and the renderer's drawing are counted.
fn weigh(gray: impl IntoIterator<Item = u8>, ground: u8) -> Counts {
    gray.into_iter()
        .fold(Counts { dark: 0, ink: 0 }, |counts, value| Counts {
            dark: counts.dark + u64::from(value < 128),
            ink: counts.ink + u64::from(ground.saturating_sub(value)),
        })
}

/// The reference's values, row by row from the top, checked to be 8-bit
/// grayscale of the size its README gives.
fn reference() -> Vec<u8> {
    let mut reader = png::Decoder::new(Cursor::new(REFERENCE_PNG))
        .read_info()
        .expect("a PNG file");
    let size = reader.output_buffer_size().expect("a size that fits");
    let mut buffer = vec![0; size];
    let info = reader.next_frame(&mut buffer).expect("the image's data");
    assert_eq!(info.bit_depth, png::BitDepth::Eight);
    assert_eq!(info.color_type, png::ColorType::Grayscale);
    assert_eq!((info.width, info.height), REFERENCE_SIZE);
    buffer.truncate(info.buffer_size());
    buffer
}

/// The sentence as a frame of one view the reference's size, white
/// behind, one row of black text on white, each glyph at its pen
/// position in the reference, and the target it is drawn on: the
/// reference's size, at scale 2.
pub(crate) fn sentence() -> (Frame, Target) {
    let (width, height) = REFERENCE_SIZE;
    let advance = advance_of(MONO, glyph_of(MONO, 't'), SIZE);
    let glyphs: Vec<Glyph> = SENTENCE
        .char_indices()
        .enumerate()
        .map(|(index, (cluster, character))| Glyph {
            id: glyph_of(MONO, character),
            font: ResolvedFontId(0),
            cluster,
            x: MARGIN + index as f32 * advance,
            dx: 0.0,
            dy: 0.0,
            advance: advance_of(MONO, glyph_of(MONO, character), SIZE),
        })
        .collect();
    let baseline = height as f32 - BASELINE_UP;
    let bytes = 0..SENTENCE.len();
    let paint = Paint {
        foreground: BLACK,
        background: WHITE,
        underline: None,
        strike_through: false,
    };
    let line = Arc::new(VisualLine {
        bytes: bytes.clone(),
        glyphs,
        width: MARGIN + SENTENCE.len() as f32 * advance,
        height: height as f32,
        baseline,
    });
    let row = FrameRow::text_row(0.0, 0.0, bytes.clone(), line, vec![(bytes, paint)], 1);
    let view = ViewFrame {
        id: ViewId(1),
        rect: Rect {
            x: 0,
            y: 0,
            width,
            height,
        },
        background: WHITE,
        rows: vec![row],
        status: None,
        cursors: Vec::new(),
        selections: Vec::new(),
        selection: WHITE,
    };
    let frame = Frame {
        views: vec![view],
        generation: 0,
        fonts: Arc::from(vec![font()]),
        dividers: Vec::new(),
    };
    let target = Target {
        width,
        height,
        scale: 2.0,
    };
    (frame, target)
}

/// The sentence drawn through the CPU path with `settings`: the first
/// channel of each pixel, row by row from the top.
fn drawn(settings: Settings) -> Vec<u8> {
    let (frame, target) = sentence();
    let mut renderer = HeadlessRenderer::new(settings);
    let answer = renderer.draw(&DrawRequest {
        frame: &Arc::new(frame),
        target,
    });
    assert!(answer.presented);
    assert!(answer.glyphs_rasterised > 0);
    let image = renderer.image();
    assert_eq!((image.width, image.height), REFERENCE_SIZE);
    image
        .rgba
        .as_chunks::<4>()
        .0
        .iter()
        .map(|pixel| pixel[0])
        .collect()
}

/// The counts of the sentence drawn with `weight`, hinted as `hinting`
/// says, and every other setting the default.
fn weighed(weight: Weight, hinting: bool) -> Counts {
    let settings = Settings {
        weight,
        hinting,
        ..Settings::default()
    };
    weigh(drawn(settings), 0xff)
}

#[test]
fn the_core_text_reference_is_black_on_white_of_its_readmes_size() {
    let values = reference();
    let (width, height) = REFERENCE_SIZE;
    assert_eq!(values.len(), (width * height) as usize);
    // White at its corners, and with ink in it.
    assert_eq!(values[0], 0xff);
    assert_eq!(values[values.len() - 1], 0xff);
    assert!(values.contains(&0));
}

#[test]
fn the_sentence_is_drawn_where_the_reference_has_it() {
    // The rows and the columns with ink in them are the same in both, to
    // within a pixel at each edge: the frame puts the line where Core
    // Text did.
    let (width, _) = REFERENCE_SIZE;
    let bounds = |values: &[u8]| {
        let inked: Vec<(usize, usize)> = values
            .iter()
            .enumerate()
            .filter(|(_, value)| **value < 128)
            .map(|(at, _)| (at % width as usize, at / width as usize))
            .collect();
        let xs = inked.iter().map(|(x, _)| *x);
        let ys = inked.iter().map(|(_, y)| *y);
        (
            xs.clone().min().unwrap_or(0),
            xs.max().unwrap_or(0),
            ys.clone().min().unwrap_or(0),
            ys.max().unwrap_or(0),
        )
    };
    let ours = bounds(&drawn(Settings::default()));
    let theirs = bounds(&reference());
    for (one, other) in [
        (ours.0, theirs.0),
        (ours.1, theirs.1),
        (ours.2, theirs.2),
        (ours.3, theirs.3),
    ] {
        assert!(one.abs_diff(other) <= 1, "{ours:?} {theirs:?}");
    }
}

#[test]
fn a_contrast_or_a_dilation_each_make_the_sentence_heavier() {
    let default = weighed(Weight::LINEAR, true);
    for weight in [
        Weight {
            contrast: 0.5,
            dilation: 0.0,
        },
        Weight {
            contrast: 0.0,
            dilation: 0.3,
        },
    ] {
        let heavier = weighed(weight, true);
        assert!(
            heavier.ink > default.ink,
            "{weight:?}: {heavier:?} {default:?}"
        );
        assert!(
            heavier.dark > default.dark,
            "{weight:?}: {heavier:?} {default:?}"
        );
    }
}

/// The glyphs of the sentence's characters, spaces left out: they have
/// no image.
fn glyphs() -> Vec<u32> {
    SENTENCE
        .chars()
        .filter(|character| *character != ' ')
        .map(|character| glyph_of(MONO, character))
        .collect()
}

/// The window's text colour and ground (`editor-ffi`'s example `window`).
const WINDOW: (Color, u8) = (Color::rgb(0x20, 0x20, 0x20), 0xf8);
/// TextEdit's: black on white.
const TEXTEDIT: (Color, u8) = (Color::rgb(0, 0, 0), 0xff);

/// The renderer's blend, in linear light.
fn linear(color: Color, ground: u8, coverage: u8) -> u8 {
    let under = [ground, ground, ground, 255];
    blend::blend(
        under,
        &blend::source(QuadKind::Mask, color, [coverage, 0, 0, 0]),
    )[0]
}

/// The counts of `masks`, each laid over a ground of `ground` in `color`
/// as `way` lays a coverage, each over its own image.
fn over_glyphs(
    masks: &[GlyphImage],
    (color, ground): (Color, u8),
    way: impl Fn(Color, u8, u8) -> u8,
) -> Counts {
    let values = masks
        .iter()
        .flat_map(|image| image.data.iter())
        .map(|coverage| way(color, ground, *coverage));
    weigh(values, ground)
}

/// The sentence's plain masks at bin 0, hinted or not, made by the
/// rasteriser with each stem `growth` pixels thicker.
fn masks(hint: bool, growth: f32) -> Vec<GlyphImage> {
    let font = font();
    let mut rasterizer = SwashRasterizer::dilated(growth);
    glyphs()
        .into_iter()
        .map(|glyph| {
            let key = GlyphKey {
                font: ResolvedFontId(0),
                glyph,
                bin: 0,
                subpixel: false,
                bucket: 0,
            };
            rasterizer
                .rasterize(&GlyphRequest {
                    font: &font,
                    key,
                    hint,
                })
                .expect("an image")
        })
        .collect()
}

/// The first channel of `color`.
fn red(color: Color) -> u8 {
    color.0.to_be_bytes()[0]
}

/// Blending on the sRGB values themselves, as if they were light.
fn gamma(color: Color, ground: u8, coverage: u8) -> u8 {
    let (under, over) = (f32::from(ground), f32::from(red(color)));
    (under + (over - under) * f32::from(coverage) / 255.0).round() as u8
}

/// The renderer's blend, with the coverage raised at `contrast`.
fn contrasted(contrast: f32) -> impl Fn(Color, u8, u8) -> u8 {
    move |color, ground, coverage| {
        let under = [ground, ground, ground, 255];
        blend::blend(
            under,
            &blend::source_with(QuadKind::Mask, color, [coverage, 0, 0, 0], contrast),
        )[0]
    }
}

#[test]
fn blending_in_srgb_values_darkens_dark_text_on_a_light_ground() {
    let masks = masks(true, 0.0);
    let (b, g) = (
        over_glyphs(&masks, WINDOW, linear),
        over_glyphs(&masks, WINDOW, gamma),
    );
    assert!(g.ink > b.ink, "{g:?} {b:?}");
    assert!(g.dark >= b.dark, "{g:?} {b:?}");
}

#[test]
fn dilation_adds_ink_with_its_strength() {
    let weights: Vec<Counts> = GROWTHS
        .iter()
        .map(|growth| over_glyphs(&masks(true, *growth), WINDOW, linear))
        .collect();
    let plain = over_glyphs(&masks(true, 0.0), WINDOW, linear);
    for (thinner, thicker) in std::iter::once(&plain).chain(&weights).zip(&weights) {
        assert!(thicker.ink > thinner.ink, "{thinner:?} {thicker:?}");
        assert!(thicker.dark >= thinner.dark, "{thinner:?} {thicker:?}");
    }
}

#[test]
fn contrast_adds_ink_and_none_at_zero() {
    let masks = masks(true, 0.0);
    let baseline = over_glyphs(&masks, WINDOW, linear);
    assert_eq!(over_glyphs(&masks, WINDOW, contrasted(0.0)), baseline);
    let mut lighter = baseline;
    for contrast in CONTRASTS {
        let heavier = over_glyphs(&masks, WINDOW, contrasted(contrast));
        assert!(
            heavier.ink > lighter.ink,
            "{contrast}: {lighter:?} {heavier:?}"
        );
        lighter = heavier;
    }
}

#[test]
fn black_on_white_has_more_ink_than_the_windows_colours_and_as_many_dark_pixels() {
    let masks = masks(true, 0.0);
    let (b, c) = (
        over_glyphs(&masks, WINDOW, linear),
        over_glyphs(&masks, TEXTEDIT, linear),
    );
    assert!(c.ink > b.ink, "{c:?} {b:?}");
    // In linear light the window's grey on its lighter grey crosses
    // mid-grey at about the coverage black on white does: the colours
    // move the dark pixels by under one in a hundred.
    assert!(c.dark.abs_diff(b.dark) * 100 < b.dark, "{c:?} {b:?}");
}

/// How far `counts` is from the reference's `target`, as the larger of
/// the two parts by which its dark pixels and its ink miss.
fn error(counts: Counts, target: Counts) -> f64 {
    let miss = |ours: u64, theirs: u64| (ours as f64 / theirs as f64 - 1.0).abs();
    miss(counts.dark, target.dark).max(miss(counts.ink, target.ink))
}

#[test]
fn the_default_weight_is_lighter_than_core_texts() {
    let target = weigh(reference(), 0xff);
    let default = weighed(Weight::LINEAR, true);
    let macos = weigh(drawn(Settings::core_text()), 0xff);
    println!("{SENTENCE:?}, Noto Sans Mono at {SIZE} px, black on white");
    println!(
        "{:<28} {:>6} {:>8} {:>7} {:>7}",
        "drawing", "dark", "ink", "dark/CT", "ink/CT"
    );
    for (name, counts) in [
        ("Core Text", target),
        ("default (linear)", default),
        ("macOS (Settings::core_text)", macos),
    ] {
        println!(
            "{:<28} {:>6} {:>8} {:>7.3} {:>7.3}",
            name,
            counts.dark,
            counts.ink,
            counts.dark as f64 / target.dark as f64,
            counts.ink as f64 / target.ink as f64,
        );
    }
    assert!(default.dark < target.dark, "{default:?} {target:?}");
    assert!(default.ink < target.ink, "{default:?} {target:?}");
    assert!(error(default, target) > 0.10);
}

/// How far the macOS setting's counts may be from the reference's, as a
/// part of the reference's, in dark pixels and in ink alike.
const TOLERANCE: f64 = 0.10;

/// The counts of the sentence drawn with `settings`.
fn weighed_with(settings: Settings) -> Counts {
    weigh(drawn(settings), 0xff)
}

#[test]
fn the_macos_weight_matches_core_texts_reference() {
    let target = weigh(reference(), 0xff);
    let macos = weighed_with(Settings::core_text());
    assert!(
        error(macos, target) <= TOLERANCE,
        "{macos:?} against {target:?}: dark x{:.3}, ink x{:.3}",
        macos.dark as f64 / target.dark as f64,
        macos.ink as f64 / target.ink as f64,
    );
}

/// The amounts the fit sweeps: each from 0 by 0.1, the contrast to 1,
/// past which the adjustment is no longer a coverage, and the dilation
/// to 0.8 pixels; and hinting on and off.
fn grid() -> Vec<(Weight, bool)> {
    let mut points = Vec::new();
    for hinting in [true, false] {
        for dilation in 0..=8 {
            for contrast in 0..=10 {
                let weight = Weight {
                    contrast: contrast as f32 / 10.0,
                    dilation: dilation as f32 / 10.0,
                };
                points.push((weight, hinting));
            }
        }
    }
    points
}

/// Whether [`the_core_text_weight_is_the_best_on_the_grid`] sweeps the
/// whole grid, as the fit did, and prints its nearest points. The sweep
/// draws the sentence 198 times, over 2 seconds in the debug profile, so
/// the gate holds the macOS setting to its neighbours on the grid and to
/// the default instead. Set it to `true` to fit again, and run
/// `cargo test --locked -p editor-render-wgpu --lib weight_tests -- --nocapture`.
const FULL_SWEEP: bool = false;

/// The points of the grid next to the macOS setting: a step of 0.1 up or
/// down in the contrast, in the dilation or in both, and the same with
/// hinting the other way; and the default.
fn neighbours() -> Vec<(Weight, bool)> {
    let chosen = Settings::core_text();
    let (weight, hinting) = (chosen.weight, chosen.hinting);
    let mut points = vec![(Weight::LINEAR, true), (weight, !hinting)];
    for contrast in [-0.1_f32, 0.0, 0.1] {
        for dilation in [-0.1_f32, 0.0, 0.1] {
            let next = Weight {
                contrast: weight.contrast + contrast,
                dilation: weight.dilation + dilation,
            };
            let on_grid = (0.0..=1.0).contains(&next.contrast)
                && (0.0..=0.8 + f32::EPSILON).contains(&next.dilation);
            if on_grid && next != weight {
                points.push((next, hinting));
                points.push((next, !hinting));
            }
        }
    }
    points
}

#[test]
fn the_core_text_weight_is_the_best_on_the_grid() {
    let target = weigh(reference(), 0xff);
    let chosen = Settings::core_text();
    let best = error(weighed_with(chosen), target);
    let points = if FULL_SWEEP { grid() } else { neighbours() };
    let mut table: Vec<(Weight, bool, Counts, f64)> = points
        .into_iter()
        .map(|(weight, hinting)| {
            let counts = weighed(weight, hinting);
            (weight, hinting, counts, error(counts, target))
        })
        .collect();
    table.sort_by(|one, other| one.3.total_cmp(&other.3));
    println!("the nearest points of the grid to Core Text's {target:?}:");
    for (weight, hinting, counts, miss) in table.iter().take(12) {
        println!(
            "contrast {:.2} dilation {:.2} hinting {hinting:<5} dark {:>5} ink {:>7} dark/CT {:.3} ink/CT {:.3} error {miss:.3}",
            weight.contrast,
            weight.dilation,
            counts.dark,
            counts.ink,
            counts.dark as f64 / target.dark as f64,
            counts.ink as f64 / target.ink as f64,
        );
    }
    for (weight, hinting, _, miss) in &table {
        assert!(
            *miss >= best,
            "{weight:?} hinting {hinting} misses by {miss:.4}, the macOS setting by {best:.4}"
        );
    }
}
