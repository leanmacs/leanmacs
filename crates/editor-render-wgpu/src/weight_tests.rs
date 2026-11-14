//! How heavy a run of text comes out, under each thing that might make
//! it lighter than the platform draws it.
//!
//! The owner saw the window's text lighter than TextEdit's, Menlo 14 pt
//! at scale 2 beside Menlo Regular 14 pt: on a screenshot, 1234 pixels
//! darker than mid-grey against 1839, and about 8% less ink. These tests
//! count the same two things for the same sentence, drawn as the window
//! draws it (the baseline: the real rasteriser's plain masks, the real
//! blend, the window's colours) and with each candidate cause changed on
//! its own and in pairs: TextEdit's colours, blending on sRGB values,
//! the outline dilated, hinting off, and the coverage adjustment the
//! renderer already has at amounts other than its placeholder.
//!
//! The font is Noto Sans Mono, a stand-in for Menlo, whose licence keeps
//! it out of the repository: the numbers are of the stand-in, and the
//! ratios between candidates are what carries over. Each glyph is
//! weighed over its own image, as if no two touched.
//!
//! The tests state relations only. The table of every candidate, with
//! its ratios to the baseline and its rank against the owner's ratios,
//! is printed by
//! `cargo test --locked -p editor-render-wgpu --lib weight_tests -- --nocapture`,
//! and recorded in `docs/design/text-and-display.md`. Nothing here reads
//! a file or the environment: the font is compiled in.

use std::sync::Arc;

use editor_layout::face::Color;
use editor_layout::shaper::{ResolvedFont, ResolvedFontId};

use crate::blend;
use crate::glyphs::{GlyphImage, GlyphKey, GlyphRequest, Rasterize};
use crate::quads::QuadKind;
use crate::raster::SwashRasterizer;
use crate::raster::measure::{glyph_of, mask};

/// Noto Sans Mono, the stand-in for Menlo.
const MONO: &[u8] = include_bytes!("../../../tests/fonts/NotoSansMono-Regular.subset.ttf");

/// The sentence the owner measured.
const SENTENCE: &str = "the window draws this";

/// Menlo 14 pt at scale 2, in pixels.
const SIZE: f32 = 28.0;

/// The dilations swept, in pixels a stem is made thicker.
const GROWTHS: [f32; 4] = [0.15, 0.3, 0.45, 0.6];

/// The amounts of the existing coverage adjustment swept.
const CONTRASTS: [f32; 3] = [0.25, 0.5, 1.0];

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

/// The glyphs of the sentence's characters, spaces left out: they have
/// no image.
fn glyphs() -> Vec<u32> {
    SENTENCE
        .chars()
        .filter(|character| *character != ' ')
        .map(|character| glyph_of(MONO, character))
        .collect()
}

#[test]
fn the_measuring_mask_is_the_rasterisers_at_no_dilation() {
    let font = font();
    let mut rasterizer = SwashRasterizer::new();
    for glyph in glyphs() {
        let key = GlyphKey {
            font: ResolvedFontId(0),
            glyph,
            bin: 0,
            subpixel: false,
        };
        for hint in [true, false] {
            let made = rasterizer
                .rasterize(&GlyphRequest {
                    font: &font,
                    key,
                    hint,
                })
                .expect("an image");
            assert_eq!(mask(&font, glyph, hint, 0.0), made, "{glyph} {hint}");
        }
    }
}

/// How wide the stem of `|` is, in pixels, at the middle row of `image`:
/// its coverage summed across that row.
fn stem(image: &GlyphImage) -> f32 {
    let width = image.width as usize;
    let middle = image.height as usize / 2;
    let row = &image.data[middle * width..(middle + 1) * width];
    row.iter().map(|byte| f32::from(*byte)).sum::<f32>() / 255.0
}

#[test]
fn a_growth_makes_a_stem_that_many_pixels_thicker() {
    let font = font();
    let bar = glyph_of(MONO, '|');
    let plain = stem(&mask(&font, bar, false, 0.0));
    for growth in [0.3, 0.6, 1.0] {
        let grown = stem(&mask(&font, bar, false, growth));
        assert!(
            (grown - plain - growth).abs() < 0.02,
            "{growth}: {plain} to {grown}"
        );
    }
}

/// What the owner counted of a run of text on a light ground.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Weight {
    /// How many pixels are darker than mid-grey: below 128.
    dark: u64,
    /// How much darker than the ground the pixels are, summed.
    ink: u64,
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

/// The weight of `masks`, each laid over a ground of `ground` in `color`
/// as `way` lays a coverage, each over its own image.
fn weigh(
    masks: &[GlyphImage],
    (color, ground): (Color, u8),
    way: impl Fn(Color, u8, u8) -> u8,
) -> Weight {
    let values = masks
        .iter()
        .flat_map(|image| image.data.iter())
        .map(|coverage| way(color, ground, *coverage));
    values.fold(Weight { dark: 0, ink: 0 }, |weight, value| Weight {
        dark: weight.dark + u64::from(value < 128),
        ink: weight.ink + u64::from(ground.saturating_sub(value)),
    })
}

/// The sentence's masks, hinted or not, with each stem `growth` pixels
/// thicker.
fn masks(hint: bool, growth: f32) -> Vec<GlyphImage> {
    let font = font();
    glyphs()
        .into_iter()
        .map(|glyph| mask(&font, glyph, hint, growth))
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

/// The renderer's blend, with the coverage raised by [`blend::adjusted`]
/// at `contrast`, built as [`blend::source`] builds a mask's source but
/// with this amount in place of [`blend::CONTRAST`].
fn contrasted(contrast: f32) -> impl Fn(Color, u8, u8) -> u8 {
    move |color, ground, coverage| {
        let [r, g, b, _] = color.0.to_be_bytes();
        let rgb = [
            blend::to_linear(r),
            blend::to_linear(g),
            blend::to_linear(b),
        ];
        let luminance = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
        let cover = blend::adjusted(f32::from(coverage) / 255.0, luminance, contrast);
        let under = [ground, ground, ground, 255];
        blend::blend(
            under,
            &blend::Source {
                rgb,
                coverage: [cover; 4],
            },
        )[0]
    }
}

#[test]
fn blending_in_srgb_values_darkens_dark_text_on_a_light_ground() {
    let masks = masks(true, 0.0);
    let (b, g) = (weigh(&masks, WINDOW, linear), weigh(&masks, WINDOW, gamma));
    assert!(g.ink > b.ink, "{g:?} {b:?}");
    assert!(g.dark >= b.dark, "{g:?} {b:?}");
}

#[test]
fn dilation_adds_ink_with_its_strength() {
    let weights: Vec<Weight> = GROWTHS
        .iter()
        .map(|growth| weigh(&masks(true, *growth), WINDOW, linear))
        .collect();
    let plain = weigh(&masks(true, 0.0), WINDOW, linear);
    for (thinner, thicker) in std::iter::once(&plain).chain(&weights).zip(&weights) {
        assert!(thicker.ink > thinner.ink, "{thinner:?} {thicker:?}");
        assert!(thicker.dark >= thinner.dark, "{thinner:?} {thicker:?}");
    }
}

#[test]
fn contrast_adds_ink_and_none_at_zero() {
    let masks = masks(true, 0.0);
    let baseline = weigh(&masks, WINDOW, linear);
    assert_eq!(weigh(&masks, WINDOW, contrasted(0.0)), baseline);
    let mut lighter = baseline;
    for contrast in CONTRASTS {
        let heavier = weigh(&masks, WINDOW, contrasted(contrast));
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
        weigh(&masks, WINDOW, linear),
        weigh(&masks, TEXTEDIT, linear),
    );
    assert!(c.ink > b.ink, "{c:?} {b:?}");
    // In linear light the window's grey on its lighter grey crosses
    // mid-grey at about the coverage black on white does: the colours
    // move the dark pixels by under one in a hundred.
    assert!(c.dark.abs_diff(b.dark) * 100 < b.dark, "{c:?} {b:?}");
}

/// TextEdit's dark pixels over the window's, on the owner's screenshot:
/// 1839 over 1234.
const DARK_GAP: f64 = 1839.0 / 1234.0;

/// TextEdit's ink over the window's, on the owner's screenshot: the
/// window had about 8% less.
const INK_GAP: f64 = 1.09;

/// How far a ratio may be from the gap it is held to, as a part of the
/// gap, for a candidate to explain it.
const NEAR: f64 = 0.10;

/// One row of the table: a candidate, its weight, and its weight over
/// the baseline's.
struct Row {
    name: String,
    weight: Weight,
    dark: f64,
    ink: f64,
}

impl Row {
    /// How far each ratio is from its gap, as a part of the gap.
    fn errors(&self) -> (f64, f64) {
        (
            (self.dark / DARK_GAP - 1.0).abs(),
            (self.ink / INK_GAP - 1.0).abs(),
        )
    }

    /// The two errors together, by which candidates are ranked.
    fn error(&self) -> f64 {
        let (dark, ink) = self.errors();
        dark + ink
    }

    /// Whether both ratios are within [`NEAR`] of their gaps.
    fn explains(&self) -> bool {
        let (dark, ink) = self.errors();
        dark <= NEAR && ink <= NEAR
    }
}

/// Every candidate's weight, the baseline first.
fn candidates() -> Vec<(String, Weight)> {
    let hinted = masks(true, 0.0);
    let plain = masks(false, 0.0);
    let grown = |growth: f32| masks(true, growth);
    let mut rows = vec![
        ("B  baseline".to_owned(), weigh(&hinted, WINDOW, linear)),
        (
            "C  black on white".to_owned(),
            weigh(&hinted, TEXTEDIT, linear),
        ),
        ("G  gamma blend".to_owned(), weigh(&hinted, WINDOW, gamma)),
        ("H  hinting off".to_owned(), weigh(&plain, WINDOW, linear)),
    ];
    for growth in GROWTHS {
        rows.push((
            format!("D({growth})"),
            weigh(&grown(growth), WINDOW, linear),
        ));
    }
    for contrast in CONTRASTS {
        rows.push((
            format!("K({contrast})"),
            weigh(&hinted, WINDOW, contrasted(contrast)),
        ));
    }
    rows.extend([
        ("C+G".to_owned(), weigh(&hinted, TEXTEDIT, gamma)),
        ("C+D(0.3)".to_owned(), weigh(&grown(0.3), TEXTEDIT, linear)),
        ("C+H".to_owned(), weigh(&plain, TEXTEDIT, linear)),
        ("G+D(0.3)".to_owned(), weigh(&grown(0.3), WINDOW, gamma)),
    ]);
    rows
}

#[test]
fn the_sentence_weighs_under_each_candidate() {
    let weights = candidates();
    let baseline = weights[0].1;
    let rows: Vec<Row> = weights
        .into_iter()
        .map(|(name, weight)| Row {
            name,
            weight,
            dark: weight.dark as f64 / baseline.dark as f64,
            ink: weight.ink as f64 / baseline.ink as f64,
        })
        .collect();
    println!("{SENTENCE:?}, Noto Sans Mono at {SIZE} px, plain masks, bin 0");
    println!("held to dark x{DARK_GAP:.3} and ink x{INK_GAP:.3}, each within {NEAR}");
    println!(
        "{:<20} {:>6} {:>8} {:>7} {:>7} {:>7}",
        "candidate", "dark", "ink", "dark/B", "ink/B", "error"
    );
    for row in &rows {
        assert!(row.weight.ink > 0, "{}", row.name);
        assert!(!row.dark.is_nan() && !row.ink.is_nan(), "{}", row.name);
        println!(
            "{:<20} {:>6} {:>8} {:>7.3} {:>7.3} {:>7.3}",
            row.name,
            row.weight.dark,
            row.weight.ink,
            row.dark,
            row.ink,
            row.error()
        );
    }
    let mut ranked: Vec<&Row> = rows.iter().skip(1).collect();
    ranked.sort_by(|one, other| one.error().total_cmp(&other.error()));
    println!("nearest first:");
    for row in &ranked {
        let verdict = if row.explains() {
            "explains the gap"
        } else {
            ""
        };
        println!("{:<20} {:>7.3} {verdict}", row.name, row.error());
    }
}
