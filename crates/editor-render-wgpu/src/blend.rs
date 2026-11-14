//! How one quad's pixel is laid over what is already drawn, and which
//! kind of antialiasing a glyph gets.
//!
//! Text is blended over what is under it, pixel by pixel: nothing is
//! composited against a background it is assumed to sit on. For each of
//! red, green and blue,
//!
//! ```text
//! out = text × coverage + under × (1 − coverage)
//! ```
//!
//! in linear light: the target holds sRGB values, which are converted on
//! the way in and on the way out, so half coverage of white on black is
//! 188 of 255 and not 128. A plain mask has one coverage for the three
//! channels; a subpixel mask has one for each, which is what makes text
//! sharper on a display whose pixels are stripes of red, green and blue.
//!
//! [`blend`] and [`source_with`] are that arithmetic, stated once. The
//! CPU compositor calls them for every pixel, and the GPU's shader states
//! the same expressions: on a GPU, blending a colour by a coverage for
//! each channel is dual-source blending, the colour as one output and the
//! coverages as the other.
//!
//! # Which antialiasing
//!
//! [`stripes`]: subpixel masks on a display below two physical pixels to
//! a logical one, where a stripe is wide enough to matter, and plain
//! masks from two up; or always one or the other, as the setting says.
//! A device that cannot blend by a coverage for each channel gets plain
//! masks whatever the setting.
//!
//! # The contrast
//!
//! [`adjusted`] raises the coverage of dark text on a light ground, which
//! otherwise looks thin once blending is in linear light. Its amount is a
//! renderer's setting (`Weight::contrast`), passed to [`source_with`] and
//! to the shader alike. The default weight's, [`CONTRAST`], is 0, which
//! leaves every coverage as it is.

use std::sync::LazyLock;

use editor_layout::face::Color;

use crate::quads::QuadKind;
use crate::{Antialiasing, SubpixelOrder};

/// How much the coverage of dark text is raised ([`adjusted`]) by the
/// default weight (`Weight::LINEAR`): 0, which raises nothing.
pub const CONTRAST: f32 = 0.0;

/// The scale from which `Antialiasing::Auto` gives plain masks.
pub const GRAYSCALE_FROM_SCALE: f32 = 2.0;

/// The stripe order glyphs are rasterised for at `scale`, or `None` for
/// plain masks, on a device that blends by a coverage for each channel
/// (`per_channel`) or one that cannot.
pub fn stripes(antialiasing: Antialiasing, scale: f32, per_channel: bool) -> Option<SubpixelOrder> {
    if !per_channel {
        return None;
    }
    match antialiasing {
        Antialiasing::Auto => (scale < GRAYSCALE_FROM_SCALE).then_some(SubpixelOrder::Rgb),
        Antialiasing::Grayscale => None,
        Antialiasing::Subpixel(order) => Some(order),
    }
}

/// The linear-light value, from 0 to 1, of each sRGB value.
static LINEAR: LazyLock<[f32; 256]> = LazyLock::new(|| {
    std::array::from_fn(|value| {
        let encoded = value as f32 / 255.0;
        if encoded <= 0.040_45 {
            encoded / 12.92
        } else {
            ((encoded + 0.055) / 1.055).powf(2.4)
        }
    })
});

/// The linear-light value, from 0 to 1, of the sRGB value `srgb`.
pub fn to_linear(srgb: u8) -> f32 {
    LINEAR[usize::from(srgb)]
}

/// The sRGB value of the linear-light value `linear`, which is held to 0
/// and 1.
pub fn to_srgb(linear: f32) -> u8 {
    let linear = linear.clamp(0.0, 1.0);
    let encoded = if linear <= 0.003_130_8 {
        linear * 12.92
    } else {
        1.055 * linear.powf(1.0 / 2.4) - 0.055
    };
    (encoded * 255.0).round() as u8
}

/// The coverage `coverage`, raised by `contrast` for text whose colour
/// has the linear-light luminance `luminance`: not at all for white
/// text, most for black, and never at no coverage or at full coverage.
pub fn adjusted(coverage: f32, luminance: f32, contrast: f32) -> f32 {
    coverage + contrast * (1.0 - luminance) * coverage * (1.0 - coverage)
}

/// The linear-light luminance of the linear-light colour `rgb`.
fn luminance(rgb: [f32; 3]) -> f32 {
    0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
}

/// The byte `byte` as a fraction of 255.
fn unit(byte: u8) -> f32 {
    f32::from(byte) / 255.0
}

/// What a quad lays over one pixel: a colour, and how much of each
/// channel of the pixel it covers.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Source {
    /// Red, green and blue, in linear light.
    pub rgb: [f32; 3],
    /// How much of the pixel's red, green, blue and alpha it covers, each
    /// from 0 to 1.
    pub coverage: [f32; 4],
}

/// What a quad of `kind` and `color` lays over a pixel at which its
/// atlas page reads `texel`: for a fill, which reads no page, `texel` is
/// not looked at; for a mask only its first byte is.
///
/// It is [`source_with`] at the default weight's [`CONTRAST`], and only
/// the tests ask for it.
#[cfg(test)]
pub fn source(kind: QuadKind, color: Color, texel: [u8; 4]) -> Source {
    source_with(kind, color, texel, CONTRAST)
}

/// What a quad of `kind` and `color` lays over a pixel at which its
/// atlas page reads `texel`, with the coverage of text raised by
/// `contrast` ([`adjusted`]): a renderer's setting (`Weight::contrast`).
/// For a fill, which reads no page, `texel` is not looked at; for a mask
/// only its first byte is.
pub fn source_with(kind: QuadKind, color: Color, texel: [u8; 4], contrast: f32) -> Source {
    let [red, green, blue, alpha] = color.0.to_be_bytes();
    let rgb = [to_linear(red), to_linear(green), to_linear(blue)];
    let alpha = unit(alpha);
    // The coverage of text, adjusted for its colour and held back by the
    // colour's alpha.
    let text = |mask: u8| adjusted(unit(mask), luminance(rgb), contrast) * alpha;
    match kind {
        QuadKind::Fill => Source {
            rgb,
            coverage: [alpha; 4],
        },
        QuadKind::Mask => Source {
            rgb,
            coverage: [text(texel[0]); 4],
        },
        QuadKind::Subpixel => {
            let each = [text(texel[0]), text(texel[1]), text(texel[2])];
            let mean = (each[0] + each[1] + each[2]) / 3.0;
            Source {
                rgb,
                coverage: [each[0], each[1], each[2], mean],
            }
        }
        QuadKind::Color => {
            // The image's colours are multiplied by its alpha, as sRGB
            // values: divided out before they are made linear.
            let cover = unit(texel[3]);
            let own = |channel: u8| {
                if cover > 0.0 {
                    to_linear((unit(channel) / cover * 255.0).round().min(255.0) as u8)
                } else {
                    0.0
                }
            };
            Source {
                rgb: [own(texel[0]), own(texel[1]), own(texel[2])],
                coverage: [cover; 4],
            }
        }
    }
}

/// The pixel `under`, red, green, blue and alpha as the target holds
/// them, with `source` laid over it.
pub fn blend(under: [u8; 4], source: &Source) -> [u8; 4] {
    let channel = |index: usize| {
        let cover = source.coverage[index];
        to_srgb(source.rgb[index] * cover + to_linear(under[index]) * (1.0 - cover))
    };
    let cover = source.coverage[3];
    let alpha = cover + unit(under[3]) * (1.0 - cover);
    [
        channel(0),
        channel(1),
        channel(2),
        (alpha * 255.0).round() as u8,
    ]
}

#[cfg(test)]
mod tests {
    use editor_layout::face::Color;

    use super::{CONTRAST, adjusted, blend, source, stripes, to_linear, to_srgb};
    use super::{Source, source_with};
    use crate::quads::QuadKind;
    use crate::{Antialiasing, SubpixelOrder};

    const WHITE: Color = Color::rgb(0xff, 0xff, 0xff);
    const BLACK: Color = Color::rgb(0, 0, 0);

    /// A pixel of the target, opaque.
    fn opaque(red: u8, green: u8, blue: u8) -> [u8; 4] {
        [red, green, blue, 255]
    }

    /// `under` with a quad of `kind` and `color` laid over it, where its
    /// page reads `texel`.
    fn over(under: [u8; 4], kind: QuadKind, color: Color, texel: [u8; 4]) -> [u8; 4] {
        blend(under, &source(kind, color, texel))
    }

    #[test]
    fn srgb_and_linear_light_convert_there_and_back() {
        assert_eq!(to_linear(0), 0.0);
        assert_eq!(to_linear(255), 1.0);
        // The middle of the sRGB range is a fifth of the light.
        assert!((to_linear(128) - 0.2158).abs() < 0.0001);
        // Below the knee the curve is a straight line.
        assert!((to_linear(10) - 10.0 / 255.0 / 12.92).abs() < 1e-6);
        for value in 0..=255 {
            assert_eq!(to_srgb(to_linear(value)), value);
        }
        // What is outside 0 and 1 is held to them.
        assert_eq!((to_srgb(-0.5), to_srgb(1.5)), (0, 255));
    }

    #[test]
    fn half_coverage_of_white_on_black_is_188() {
        // Half of the light, not half of the sRGB value.
        assert_eq!(to_srgb(0.5), 188);
        let half = [128, 0, 0, 0];
        assert_eq!(
            over(opaque(0, 0, 0), QuadKind::Mask, WHITE, half),
            opaque(188, 188, 188)
        );
        // And black on white at the same coverage is its mirror in
        // light, 187, not in sRGB values.
        assert_eq!(
            over(opaque(255, 255, 255), QuadKind::Mask, BLACK, half),
            opaque(187, 187, 187)
        );
    }

    #[test]
    fn a_subpixel_mask_blends_each_channel_by_its_own_coverage() {
        // White text covering all of the red stripe, half of the green
        // and none of the blue, over black.
        let texel = [255, 128, 0, 128];
        assert_eq!(
            over(opaque(0, 0, 0), QuadKind::Subpixel, WHITE, texel),
            opaque(255, 188, 0)
        );
        // The same coverages as a plain mask would cover the three alike
        // by the first.
        assert_eq!(
            over(opaque(0, 0, 0), QuadKind::Mask, WHITE, texel),
            opaque(255, 255, 255)
        );
    }

    #[test]
    fn text_is_blended_over_what_is_under_it() {
        // One pixel of black text at half coverage, over white and over
        // red: each is the blend with what was under it, so the red
        // stays red where the text does not cover it.
        let half = [128, 0, 0, 0];
        assert_eq!(
            over(opaque(255, 255, 255), QuadKind::Mask, BLACK, half),
            opaque(187, 187, 187)
        );
        assert_eq!(
            over(opaque(255, 0, 0), QuadKind::Mask, BLACK, half),
            opaque(187, 0, 0)
        );
        // No coverage leaves what is under as it is; full coverage is
        // the text's colour.
        let under = opaque(12, 34, 56);
        let red = Color::rgb(200, 0, 0);
        assert_eq!(over(under, QuadKind::Mask, red, [0, 0, 0, 0]), under);
        assert_eq!(
            over(under, QuadKind::Mask, red, [255, 0, 0, 0]),
            opaque(200, 0, 0)
        );
    }

    #[test]
    fn a_fill_covers_by_its_colours_alpha() {
        let under = opaque(0, 0, 0);
        let texel = [9, 9, 9, 9];
        // Opaque: the colour. The page is not read.
        assert_eq!(
            over(under, QuadKind::Fill, Color::rgb(10, 20, 30), texel),
            opaque(10, 20, 30)
        );
        // Half: half of the light.
        assert_eq!(
            over(
                under,
                QuadKind::Fill,
                Color::rgba(255, 255, 255, 128),
                texel
            ),
            opaque(188, 188, 188)
        );
        // None: nothing.
        assert_eq!(
            over(under, QuadKind::Fill, Color::rgba(255, 255, 255, 0), texel),
            under
        );
        // And text in a colour with an alpha is covered that much less.
        assert_eq!(
            over(
                under,
                QuadKind::Mask,
                Color::rgba(255, 255, 255, 128),
                [255, 0, 0, 0]
            ),
            opaque(188, 188, 188)
        );
    }

    #[test]
    fn a_colour_image_is_laid_over_in_its_own_colours() {
        // A pixel of a colour glyph: red at half alpha, its colour
        // multiplied by its alpha. The quad's own colour is not used.
        let texel = [128, 0, 0, 128];
        let any = Color::rgb(0, 255, 0);
        assert_eq!(
            over(opaque(0, 0, 0), QuadKind::Color, any, texel),
            opaque(188, 0, 0)
        );
        assert_eq!(
            over(opaque(255, 255, 255), QuadKind::Color, any, texel),
            opaque(255, 187, 187)
        );
        // An opaque pixel is itself; a clear one leaves what is under.
        assert_eq!(
            over(opaque(1, 2, 3), QuadKind::Color, any, [10, 20, 30, 255]),
            opaque(10, 20, 30)
        );
        assert_eq!(
            over(opaque(1, 2, 3), QuadKind::Color, any, [0, 0, 0, 0]),
            opaque(1, 2, 3)
        );
    }

    #[test]
    fn the_targets_alpha_is_covered_like_a_channel() {
        let clear = [0, 0, 0, 0];
        assert_eq!(
            over(
                clear,
                QuadKind::Fill,
                Color::rgba(255, 255, 255, 128),
                clear
            )[3],
            128
        );
        assert_eq!(over(clear, QuadKind::Fill, WHITE, clear)[3], 255);
        // A subpixel mask covers the alpha by the mean of its three.
        assert_eq!(
            over(clear, QuadKind::Subpixel, WHITE, [255, 128, 0, 128])[3],
            128
        );
        assert_eq!(over(clear, QuadKind::Mask, WHITE, [64, 0, 0, 0])[3], 64);
    }

    #[test]
    fn the_adjustment_raises_the_coverage_of_dark_text_alone() {
        // No amount: nothing changes, whatever the text.
        for coverage in [0.0, 0.25, 0.5, 1.0] {
            assert_eq!(adjusted(coverage, 0.0, 0.0), coverage);
        }
        // With an amount, black text at half coverage covers more.
        assert_eq!(adjusted(0.5, 0.0, 1.0), 0.75);
        assert!(adjusted(0.5, 0.0, 0.5) > 0.5);
        // White text is left as it is, and so are none and all.
        assert_eq!(adjusted(0.5, 1.0, 1.0), 0.5);
        assert_eq!(adjusted(0.0, 0.0, 1.0), 0.0);
        assert_eq!(adjusted(1.0, 0.0, 1.0), 1.0);
        // The amount in use is the placeholder.
        assert_eq!(CONTRAST, 0.0);
    }

    /// A sample of texels: none, some and all of a pixel covered, and
    /// stripes covered unequally.
    const TEXELS: [[u8; 4]; 5] = [
        [0, 0, 0, 0],
        [64, 64, 64, 64],
        [128, 0, 0, 0],
        [255, 128, 0, 128],
        [255, 255, 255, 255],
    ];

    #[test]
    fn a_source_at_the_default_contrast_is_the_source() {
        let colours = [WHITE, BLACK, Color::rgba(0x20, 0x40, 0x80, 0xc0)];
        for kind in [
            QuadKind::Fill,
            QuadKind::Mask,
            QuadKind::Subpixel,
            QuadKind::Color,
        ] {
            for color in colours {
                for texel in TEXELS {
                    assert_eq!(
                        source_with(kind, color, texel, CONTRAST),
                        source(kind, color, texel),
                        "{kind:?} {color:?} {texel:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn a_contrast_raises_the_coverage_of_black_text_by_the_adjustment() {
        let half = [128, 0, 0, 0];
        let raised = adjusted(128.0 / 255.0, 0.0, 1.0);
        assert!(raised > 128.0 / 255.0);
        assert_eq!(
            source_with(QuadKind::Mask, BLACK, half, 1.0),
            Source {
                rgb: [0.0; 3],
                coverage: [raised; 4],
            }
        );
        // So the pixel it lays over white is darker than at none.
        let white = opaque(255, 255, 255);
        let darker = blend(white, &source_with(QuadKind::Mask, BLACK, half, 1.0));
        assert!(darker[0] < over(white, QuadKind::Mask, BLACK, half)[0]);
    }

    #[test]
    fn a_contrast_leaves_white_text_as_it_is() {
        for contrast in [0.0, 0.25, 0.5, 1.0] {
            for texel in TEXELS {
                for kind in [QuadKind::Mask, QuadKind::Subpixel] {
                    assert_eq!(
                        source_with(kind, WHITE, texel, contrast),
                        source(kind, WHITE, texel),
                        "{contrast} {kind:?} {texel:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn antialiasing_is_subpixel_below_scale_two() {
        let rgb = Some(SubpixelOrder::Rgb);
        for scale in [1.0, 1.25, 1.5, 1.99] {
            assert_eq!(stripes(Antialiasing::Auto, scale, true), rgb, "at {scale}");
        }
        for scale in [2.0, 2.5, 3.0] {
            assert_eq!(stripes(Antialiasing::Auto, scale, true), None, "at {scale}");
        }
        // A setting that says which is that at every scale.
        let bgr = Antialiasing::Subpixel(SubpixelOrder::Bgr);
        for scale in [1.0, 2.0, 3.0] {
            assert_eq!(stripes(Antialiasing::Grayscale, scale, true), None);
            assert_eq!(stripes(bgr, scale, true), Some(SubpixelOrder::Bgr));
        }
        // A device that cannot blend by a coverage for each channel gets
        // plain masks whatever the setting.
        for antialiasing in [Antialiasing::Auto, Antialiasing::Grayscale, bgr] {
            assert_eq!(stripes(antialiasing, 1.0, false), None);
        }
    }
}
