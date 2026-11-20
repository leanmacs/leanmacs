//! The rasteriser port's swash adapter: glyph images made by `swash`, on
//! every platform, and the fallback for what another rasteriser declines.
//!
//! One glyph of one resolved font, by its id in the font, at the font's
//! size and variation coordinates, moved right by its subpixel bin's
//! fraction of a pixel, in the kind asked for. The font is read from the
//! bytes the frame carries for it: no file is opened and no font of the
//! machine is looked for.
//!
//! What comes back is what the font has, tried in this order: a colour
//! outline (COLR version 0 layers, in the font's first palette), a colour
//! bitmap, then the plain outline. The first two are colour images
//! whichever kind was asked; the outline is a mask, or a subpixel mask
//! with a coverage for each of red, green and blue.
//!
//! A resolved font's synthesis is applied to the outline: `embolden`
//! makes it bolder by [`EMBOLDEN`] of the font's size, and `skew` slants
//! it by that many degrees.
//!
//! There is no image for a font with no bytes (layout's fake shaper's),
//! for bytes that are no font, or for a glyph id past 16 bits, which is
//! all swash's glyph id holds.
//!
//! # What is not tuned, and not checked
//!
//! [`EMBOLDEN`] is a placeholder. No fixture font has a colour glyph, so
//! a colour image has never come out of this adapter in a test: the
//! cache, the painter and the compositor are tested for colour on images
//! their tests make.

use editor_raster::ResolvedFont;
use swash::FontRef;
use swash::scale::image::Content;
use swash::scale::{Render, ScaleContext, Source, StrikeWith};
use swash::zeno::{Angle, Format, Transform, Vector};

use crate::glyphs::{GlyphImage, GlyphRequest, Kind, Rasterize, SUBPIXEL_BINS};

/// How much bolder a synthetic bold is, as a part of the font's size. A
/// placeholder.
pub const EMBOLDEN: f32 = 1.0 / 32.0;

/// The rasteriser over swash.
pub struct SwashRasterizer {
    /// What swash keeps between glyphs.
    context: ScaleContext,
    /// How many pixels thicker each stem is drawn than its outline
    /// (`Weight::dilation`).
    dilation: f32,
}

impl SwashRasterizer {
    /// A rasteriser that has made nothing, and draws each outline as it
    /// is: [`SwashRasterizer::dilated`] at 0. The renderers make theirs
    /// from their settings, so only the tests ask for this one.
    #[cfg(test)]
    pub fn new() -> Self {
        Self::dilated(0.0)
    }

    /// A rasteriser that has made nothing, and draws each stem
    /// `dilation` pixels thicker than its outline: the outline is
    /// stroked as swash's `embolden` does it, FreeType's
    /// `FT_Outline_EmboldenXY` without that function's halving of the
    /// strength, so each edge moves out by the whole strength, and a
    /// stem `dilation` thicker is a strength of half of it.
    pub fn dilated(dilation: f32) -> Self {
        Self {
            context: ScaleContext::new(),
            dilation,
        }
    }

    /// How many pixels thicker it draws each stem than its outline: what
    /// it was made with ([`SwashRasterizer::dilated`]).
    #[cfg(test)]
    pub fn dilation(&self) -> f32 {
        self.dilation
    }
}

/// The bytes of the file of `font`.
fn bytes(font: &ResolvedFont) -> &[u8] {
    (*font.data).as_ref()
}

impl Rasterize for SwashRasterizer {
    fn rasterize(&mut self, request: &GlyphRequest<'_>) -> Option<GlyphImage> {
        let (font, key) = (request.font, request.key);
        let glyph = u16::try_from(key.glyph).ok()?;
        let face = FontRef::from_index(bytes(font), usize::try_from(font.index).ok()?)?;
        let mut scaler = self
            .context
            .builder(face)
            .size(font.size)
            .hint(request.hint)
            .normalized_coords(font.coords.iter().copied())
            .build();
        let mut render = Render::new(&[
            Source::ColorOutline(0),
            Source::ColorBitmap(StrikeWith::BestFit),
            Source::Outline,
        ]);
        let format = if key.subpixel {
            Format::Subpixel
        } else {
            Format::Alpha
        };
        // The bin is how many quarters of a pixel right of a whole pixel
        // the glyph is drawn.
        let across = f32::from(key.bin) / f32::from(SUBPIXEL_BINS);
        render.format(format).offset(Vector::new(across, 0.0));
        // A synthetic bold and the dilation add. At none, swash is not
        // asked to embolden, so an outline is drawn as it was before
        // there was a dilation.
        let bold = if font.embolden {
            font.size * EMBOLDEN
        } else {
            0.0
        };
        let strength = if self.dilation > 0.0 {
            bold + self.dilation / 2.0
        } else {
            bold
        };
        if strength > 0.0 {
            render.embolden(strength);
        }
        render.transform(
            font.skew
                .map(|degrees| Transform::skew(Angle::from_degrees(degrees), Angle::ZERO)),
        );
        let image = render.render(&mut scaler, glyph)?;
        Some(GlyphImage {
            kind: match image.content {
                Content::Mask => Kind::Mask,
                Content::SubpixelMask => Kind::Subpixel,
                Content::Color => Kind::Color,
            },
            width: image.placement.width,
            height: image.placement.height,
            left: image.placement.left,
            top: image.placement.top,
            data: image.data,
        })
    }
}

#[cfg(test)]
pub(crate) mod measure {
    //! What the measurement of a run's weight (`crate::weight_tests`)
    //! asks of a font, kept here so that swash is named by this module
    //! alone: a glyph's id and its advance.

    use swash::FontRef;

    /// The id of the glyph the font `bytes` draws `character` with, read
    /// from the font's own character map.
    pub fn glyph_of(bytes: &[u8], character: char) -> u32 {
        let face = FontRef::from_index(bytes, 0).expect("a fixture font");
        let glyph = face.charmap().map(character);
        assert_ne!(glyph, 0, "the fixture has no glyph for {character:?}");
        u32::from(glyph)
    }

    /// How far `glyph` of the font `bytes` moves the pen at `size`
    /// pixels to the em, read from the font's own metrics.
    pub fn advance_of(bytes: &[u8], glyph: u32, size: f32) -> f32 {
        let face = FontRef::from_index(bytes, 0).expect("a fixture font");
        let glyph = u16::try_from(glyph).expect("a glyph of 16 bits");
        face.glyph_metrics(&[]).scale(size).advance_width(glyph)
    }
}

#[cfg(test)]
mod tests {
    //! On the fixture fonts under `tests/fonts`, compiled in. A glyph id
    //! is read from the font's own character map, through swash, for a
    //! character the fixtures' README says the file keeps: no id and no
    //! pixel count is written here, and no shaper runs. Each test states
    //! a relation between two images, or that an image has ink.
    //!
    //! No test is of a colour glyph: no fixture font has one.

    use std::sync::Arc;

    use editor_raster::fake::font;
    use editor_raster::{ResolvedFont, ResolvedFontId};
    use swash::FontRef;

    use super::SwashRasterizer;
    use crate::glyphs::{GlyphImage, GlyphKey, GlyphRequest, Kind, Rasterize};

    /// Noto Sans.
    const SANS: &[u8] = include_bytes!("../../../tests/fonts/NotoSans-Regular.subset.ttf");
    /// Noto Sans JP.
    const JP: &[u8] = include_bytes!("../../../tests/fonts/NotoSansJP-Regular.subset.otf");
    /// Noto Emoji, which has a weight axis.
    const EMOJI: &[u8] = include_bytes!("../../../tests/fonts/NotoEmoji.subset.ttf");

    /// The face 0 of the file `bytes`, 16 pixels, as it is.
    fn resolved(bytes: &'static [u8]) -> ResolvedFont {
        ResolvedFont {
            data: Arc::new(bytes),
            file: 1,
            index: 0,
            size: 16.0,
            coords: Vec::new(),
            embolden: false,
            skew: None,
        }
    }

    /// The id of the glyph the font `bytes` draws `character` with, read
    /// from the font's own character map.
    fn glyph_of(bytes: &[u8], character: char) -> u32 {
        let face = FontRef::from_index(bytes, 0).expect("a fixture font");
        let glyph = face.charmap().map(character);
        assert_ne!(glyph, 0, "the fixture has no glyph for {character:?}");
        u32::from(glyph)
    }

    /// The key of the plain mask of `glyph` at bin 0.
    fn key(glyph: u32) -> GlyphKey {
        GlyphKey {
            font: ResolvedFontId(0),
            glyph,
            bin: 0,
            subpixel: false,
            bucket: 0,
        }
    }

    /// The image of `key` in `font`, hinted.
    fn image(font: &ResolvedFont, key: GlyphKey) -> Option<GlyphImage> {
        SwashRasterizer::new().rasterize(&GlyphRequest {
            font,
            key,
            hint: true,
        })
    }

    /// The image of the glyph `font` draws `character` with: a plain
    /// mask at bin 0.
    fn mask(font: &ResolvedFont, bytes: &[u8], character: char) -> GlyphImage {
        image(font, key(glyph_of(bytes, character))).expect("an image")
    }

    /// How much ink `image` has: the sum of its bytes.
    fn ink(image: &GlyphImage) -> u64 {
        image.data.iter().map(|byte| u64::from(*byte)).sum()
    }

    #[test]
    fn a_glyph_of_each_fixture_is_a_mask_with_ink() {
        for (bytes, character) in [(SANS, 'a'), (JP, '日'), (EMOJI, '😀')] {
            let made = mask(&resolved(bytes), bytes, character);
            assert_eq!(made.kind, Kind::Mask, "{character:?}");
            assert!(made.width > 0 && made.height > 0, "{character:?}");
            assert_eq!(made.data.len() as u32, made.width * made.height);
            assert!(ink(&made) > 0, "{character:?}");
            // It stands on or about the baseline: its top is above it.
            assert!(made.top > 0, "{character:?}");
        }
    }

    #[test]
    fn a_subpixel_mask_has_a_coverage_for_each_channel() {
        let font = resolved(SANS);
        let glyph = glyph_of(SANS, 'a');
        let made = image(
            &font,
            GlyphKey {
                subpixel: true,
                ..key(glyph)
            },
        )
        .expect("an image");
        assert_eq!(made.kind, Kind::Subpixel);
        assert_eq!(made.data.len() as u32, made.width * made.height * 4);
        // Somewhere along an edge the three stripes are covered unequally.
        let unequal = made
            .data
            .as_chunks::<4>()
            .0
            .iter()
            .any(|pixel| pixel[0] != pixel[1] || pixel[1] != pixel[2]);
        assert!(unequal);
        // And it is another image than the plain mask.
        assert_ne!(Some(made), image(&font, key(glyph)));
    }

    #[test]
    fn the_four_bins_give_four_images() {
        let font = resolved(SANS);
        let glyph = glyph_of(SANS, 'a');
        let bins: Vec<GlyphImage> = (0..4)
            .map(|bin| image(&font, GlyphKey { bin, ..key(glyph) }).expect("an image"))
            .collect();
        for (index, one) in bins.iter().enumerate() {
            for other in &bins[index + 1..] {
                assert_ne!(one, other);
            }
        }
    }

    #[test]
    fn a_place_on_a_variation_axis_gives_another_image() {
        // Noto Emoji's weight axis, at its default and at its heaviest.
        let regular = resolved(EMOJI);
        let heavy = ResolvedFont {
            coords: vec![16384],
            ..resolved(EMOJI)
        };
        let light = mask(&regular, EMOJI, '😀');
        let bold = mask(&heavy, EMOJI, '😀');
        assert_ne!(light, bold);
        assert!(ink(&bold) > ink(&light));
    }

    #[test]
    fn an_emboldened_outline_has_more_ink() {
        let bolder = ResolvedFont {
            embolden: true,
            ..resolved(SANS)
        };
        assert!(ink(&mask(&bolder, SANS, 'l')) > ink(&mask(&resolved(SANS), SANS, 'l')));
    }

    #[test]
    fn a_skewed_outline_is_wider() {
        let slanted = ResolvedFont {
            skew: Some(14.0),
            ..resolved(SANS)
        };
        assert!(mask(&slanted, SANS, 'l').width > mask(&resolved(SANS), SANS, 'l').width);
    }

    #[test]
    fn a_larger_size_gives_a_larger_image() {
        let large = ResolvedFont {
            size: 32.0,
            ..resolved(SANS)
        };
        let (small, large) = (mask(&resolved(SANS), SANS, 'a'), mask(&large, SANS, 'a'));
        assert!(large.width > small.width && large.height > small.height);
        assert!(large.top > small.top);
    }

    #[test]
    fn the_same_request_twice_gives_the_same_image() {
        let font = resolved(SANS);
        let request = GlyphRequest {
            font: &font,
            key: key(glyph_of(SANS, 'a')),
            hint: true,
        };
        // From one rasteriser, which keeps state between glyphs, and from
        // a fresh one.
        let mut rasterizer = SwashRasterizer::new();
        let first = rasterizer.rasterize(&request);
        assert!(first.is_some());
        assert_eq!(rasterizer.rasterize(&request), first);
        assert_eq!(SwashRasterizer::new().rasterize(&request), first);
    }

    #[test]
    fn an_outline_not_fitted_to_the_pixel_grid_gives_another_image() {
        // Noto Sans is its upstream's hinted build: at 16 pixels its hints
        // move the edges of the `a`.
        let font = resolved(SANS);
        let request = |hint: bool| GlyphRequest {
            font: &font,
            key: key(glyph_of(SANS, 'a')),
            hint,
        };
        // From one rasteriser, which keeps state between glyphs.
        let mut rasterizer = SwashRasterizer::new();
        let fitted = rasterizer.rasterize(&request(true)).expect("an image");
        let plain = rasterizer.rasterize(&request(false)).expect("an image");
        assert_ne!(plain, fitted);
        assert_eq!(plain.kind, Kind::Mask);
        assert!(ink(&plain) > 0);
        // Each is the image a rasteriser that has made nothing gives:
        // what is kept of one does not reach the other.
        assert_eq!(rasterizer.rasterize(&request(true)), Some(fitted));
        assert_eq!(
            SwashRasterizer::new().rasterize(&request(false)),
            Some(plain)
        );
    }

    #[test]
    fn a_space_is_an_image_of_no_size() {
        let made = mask(&resolved(SANS), SANS, ' ');
        assert_eq!(made.width * made.height, 0);
        assert!(made.data.is_empty());
    }

    #[test]
    fn a_font_with_no_bytes_and_a_glyph_past_16_bits_give_nothing() {
        // The font of layout's fake shaper: no file.
        assert_eq!(image(&font(16.0), key(1)), None);
        // Bytes that are no font.
        let junk = ResolvedFont {
            data: Arc::new(&b"not a font"[..]),
            ..resolved(SANS)
        };
        assert_eq!(image(&junk, key(1)), None);
        // One more than a glyph id of swash's holds: a bound, not an id
        // of any font.
        let past = u32::from(u16::MAX) + 1;
        assert_eq!(image(&resolved(SANS), key(past)), None);
        // The largest it holds is asked of the font, which has no such
        // glyph and draws nothing for it.
        let last = image(&resolved(SANS), key(u32::from(u16::MAX)));
        assert!(last.is_none_or(|made| made.width * made.height == 0));
    }

    /// Noto Sans Mono, the stand-in for Menlo.
    const MONO: &[u8] = include_bytes!("../../../tests/fonts/NotoSansMono-Regular.subset.ttf");

    /// Noto Sans Mono at 28 pixels, Menlo 14 pt at scale 2.
    fn mono() -> ResolvedFont {
        ResolvedFont {
            size: 28.0,
            ..resolved(MONO)
        }
    }

    /// The plain mask at bin 0 of the glyph `font` draws `character`
    /// with, made by `rasterizer`, hinted as `hint` says.
    fn made_by(
        rasterizer: &mut SwashRasterizer,
        font: &ResolvedFont,
        bytes: &[u8],
        character: char,
        hint: bool,
    ) -> GlyphImage {
        rasterizer
            .rasterize(&GlyphRequest {
                font,
                key: key(glyph_of(bytes, character)),
                hint,
            })
            .expect("an image")
    }

    /// How wide the stem of `|` is, in pixels, at the middle row of
    /// `image`: its coverage summed across that row.
    fn stem(image: &GlyphImage) -> f32 {
        let width = image.width as usize;
        let middle = image.height as usize / 2;
        let row = &image.data[middle * width..(middle + 1) * width];
        row.iter().map(|byte| f32::from(*byte)).sum::<f32>() / 255.0
    }

    #[test]
    fn the_swash_rasteriser_holds_to_the_rasteriser_contract() {
        use editor_raster::contract::{Fixture, check};
        for size in [16.0, 28.0] {
            for hint in [true, false] {
                let fixture = Fixture {
                    font: ResolvedFont {
                        size,
                        ..resolved(MONO)
                    },
                    h: glyph_of(MONO, 'H'),
                    i: glyph_of(MONO, 'I'),
                    space: glyph_of(MONO, ' '),
                    hint,
                };
                let failures = check(&mut || Box::new(SwashRasterizer::new()), &fixture);
                assert!(failures.is_empty(), "{size} px, hint {hint}: {failures:#?}");
            }
        }
    }

    #[test]
    fn a_rasteriser_that_dilates_nothing_is_the_plain_one() {
        let font = mono();
        for character in "the window draws this".chars() {
            for hint in [true, false] {
                assert_eq!(
                    made_by(
                        &mut SwashRasterizer::dilated(0.0),
                        &font,
                        MONO,
                        character,
                        hint
                    ),
                    made_by(&mut SwashRasterizer::new(), &font, MONO, character, hint),
                    "{character:?} {hint}"
                );
            }
        }
    }

    #[test]
    fn a_growth_makes_a_stem_that_many_pixels_thicker() {
        let font = mono();
        let plain = stem(&made_by(
            &mut SwashRasterizer::new(),
            &font,
            MONO,
            '|',
            false,
        ));
        for growth in [0.3, 0.6, 1.0] {
            let grown = stem(&made_by(
                &mut SwashRasterizer::dilated(growth),
                &font,
                MONO,
                '|',
                false,
            ));
            assert!(
                (grown - plain - growth).abs() < 0.02,
                "{growth}: {plain} to {grown}"
            );
        }
    }

    #[test]
    fn a_dilated_synthetic_bold_is_thicker_than_either_alone() {
        let font = mono();
        let bold = ResolvedFont {
            embolden: true,
            ..mono()
        };
        let width = |rasterizer: &mut SwashRasterizer, font: &ResolvedFont| {
            stem(&made_by(rasterizer, font, MONO, '|', false))
        };
        let plain = width(&mut SwashRasterizer::new(), &font);
        let dilated = width(&mut SwashRasterizer::dilated(0.6), &font);
        let emboldened = width(&mut SwashRasterizer::new(), &bold);
        let both = width(&mut SwashRasterizer::dilated(0.6), &bold);
        assert!(
            dilated > plain && emboldened > plain,
            "{plain} {dilated} {emboldened}"
        );
        assert!(
            both > dilated && both > emboldened,
            "{dilated} {emboldened} {both}"
        );
    }
}
