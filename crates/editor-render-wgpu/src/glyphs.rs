//! The glyph cache: each glyph image rasterised once and kept.
//!
//! A glyph is drawn from an image of it, and making that image is the
//! costly part of drawing text. The cache makes each image once, through
//! the [`Rasterize`] trait, and hands the same one back whenever it is
//! asked for again.
//!
//! # What an image is kept by
//!
//! Its [`GlyphKey`]: the resolved font's id, the glyph's id in that font,
//! the subpixel bin it is drawn at, and the kind that was asked for. A
//! resolved font's size, variation coordinates and synthesis are fixed for
//! a generation of the frame's fonts, so the font's id stands for them.
//!
//! # Positions
//!
//! A glyph's place across a row is a fraction of a pixel, and its image
//! depends on that fraction. Keeping an image for every fraction would
//! keep nothing, so a place is rounded to a quarter of a pixel
//! ([`SUBPIXEL_BINS`], [`bin_of`]): a glyph is drawn at most an eighth of
//! a pixel from where it was shaped, and has at most four images. There
//! are no bins down the page: a baseline is a whole pixel.
//!
//! # Kinds
//!
//! An image is one of three [`Kind`]s, each drawn by its own rule: a mask
//! (one coverage a pixel), a subpixel mask (a coverage for each of red,
//! green and blue) or a colour image. What is asked for is a mask or a
//! subpixel mask; a colour glyph comes back in colour whichever was asked,
//! and is kept under the key it was asked by.

use std::collections::HashMap;
use std::collections::hash_map::Entry;

use editor_layout::shaper::{ResolvedFont, ResolvedFontId};

/// How many places across a pixel a glyph is rasterised at.
pub const SUBPIXEL_BINS: u8 = 4;

/// What a glyph image holds for each pixel.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Kind {
    /// One byte: how much of the pixel the glyph covers.
    Mask,
    /// Four bytes: how much of the pixel's red, green and blue stripes
    /// the glyph covers, and their mean.
    Subpixel,
    /// Four bytes: red, green, blue and alpha, the colours multiplied by
    /// the alpha.
    Color,
}

impl Kind {
    /// How many bytes a pixel of this kind takes.
    pub const fn bytes(self) -> u32 {
        match self {
            Self::Mask => 1,
            Self::Subpixel | Self::Color => 4,
        }
    }
}

/// What a glyph image is kept by.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct GlyphKey {
    /// The font it is drawn in.
    pub font: ResolvedFontId,
    /// The glyph's id in that font.
    pub glyph: u32,
    /// Which quarter of a pixel it is drawn at, from 0.
    pub bin: u8,
    /// Whether a subpixel mask was asked for, and not a plain one.
    pub subpixel: bool,
}

/// The whole pixel and the bin of a place `x` pixels across: `x` rounded
/// to the nearest quarter of a pixel, as the pixel it falls in and how
/// many quarters past that pixel's left edge.
pub fn bin_of(x: f32) -> (i32, u8) {
    let bins = i32::from(SUBPIXEL_BINS);
    let quarters = (x * f32::from(SUBPIXEL_BINS)).round() as i32;
    (quarters.div_euclid(bins), quarters.rem_euclid(bins) as u8)
}

/// One glyph to rasterise.
#[derive(Debug, Clone, Copy)]
pub struct GlyphRequest<'a> {
    /// The font: its bytes, its face, its size and its synthesis.
    pub font: &'a ResolvedFont,
    /// What the image will be kept by: the glyph, the bin and the kind
    /// asked for.
    pub key: GlyphKey,
    /// Whether the outline is fitted to the pixel grid.
    pub hint: bool,
}

/// A rasterised glyph.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GlyphImage {
    /// What it holds for each pixel.
    pub kind: Kind,
    /// How far across it is, in pixels; 0 for a glyph that draws nothing.
    pub width: u32,
    /// How far down.
    pub height: u32,
    /// How far right of the glyph's whole-pixel place its left edge is.
    pub left: i32,
    /// How far above the baseline its top edge is.
    pub top: i32,
    /// Its pixels, row by row from the top: `width * height` times the
    /// kind's bytes.
    pub data: Vec<u8>,
}

/// What makes a glyph's image. The real one is over a font rasteriser;
/// the cache's and the painter's tests run on a fake.
pub trait Rasterize {
    /// The image of the glyph `request` names; `None` when there is none
    /// to make: the font has no bytes, or no such glyph.
    fn rasterize(&mut self, request: &GlyphRequest<'_>) -> Option<GlyphImage>;
}

/// A glyph image the cache holds, as what draws it needs it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Placed {
    /// What the image holds for each pixel.
    pub kind: Kind,
    /// How far across it is; 0 for a glyph that draws nothing.
    pub width: u32,
    /// How far down.
    pub height: u32,
    /// How far right of the glyph's whole-pixel place its left edge is.
    pub left: i32,
    /// How far above the baseline its top edge is.
    pub top: i32,
    /// Its pixels.
    pub data: Vec<u8>,
}

/// What a cache has done since it was made, counted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Stats {
    /// The images it had made.
    pub rasterised: u64,
    /// The images it was asked for and held.
    pub reused: u64,
    /// The glyphs it was asked for that have no image.
    pub skipped: u64,
}

/// The glyph images kept, by key.
#[derive(Debug, Default)]
pub struct GlyphCache {
    /// The images.
    entries: HashMap<GlyphKey, Placed>,
    /// What it has done.
    stats: Stats,
}

impl GlyphCache {
    /// A cache that holds nothing.
    pub fn new() -> Self {
        Self::default()
    }

    /// The image for `key`, a glyph of `font`: the one held, or one
    /// `rasterizer` makes now and the cache keeps. `None` when the glyph
    /// has no image, which is counted and not kept.
    pub fn get<Z: Rasterize>(
        &mut self,
        key: GlyphKey,
        font: &ResolvedFont,
        hint: bool,
        rasterizer: &mut Z,
    ) -> Option<&Placed> {
        match self.entries.entry(key) {
            Entry::Occupied(held) => {
                self.stats.reused += 1;
                Some(held.into_mut())
            }
            Entry::Vacant(vacant) => {
                let Some(image) = rasterizer.rasterize(&GlyphRequest { font, key, hint }) else {
                    self.stats.skipped += 1;
                    return None;
                };
                self.stats.rasterised += 1;
                Some(vacant.insert(Placed {
                    kind: image.kind,
                    width: image.width,
                    height: image.height,
                    left: image.left,
                    top: image.top,
                    data: image.data,
                }))
            }
        }
    }

    /// How many images are held.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether no image is held.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// What the cache has done since it was made.
    pub fn stats(&self) -> Stats {
        self.stats
    }
}

#[cfg(test)]
pub(crate) mod fake;

#[cfg(test)]
mod tests {
    use editor_layout::shaper::ResolvedFontId;

    use super::fake::{FakeRasterizer, font};
    use super::{GlyphCache, GlyphKey, Kind, SUBPIXEL_BINS, Stats, bin_of};

    /// The key of the glyph `glyph` of font 0 at bin 0, as a plain mask.
    fn key(glyph: u32) -> GlyphKey {
        GlyphKey {
            font: ResolvedFontId(0),
            glyph,
            bin: 0,
            subpixel: false,
        }
    }

    #[test]
    fn a_glyph_is_rasterised_once_and_reused() {
        let (mut cache, mut rasterizer) = (GlyphCache::new(), FakeRasterizer::new());
        let font = font(16.0);
        let first = cache.get(key(7), &font, true, &mut rasterizer).cloned();
        let again = cache.get(key(7), &font, true, &mut rasterizer).cloned();
        assert!(first.is_some());
        assert_eq!(again, first);
        assert_eq!(rasterizer.asked.len(), 1);
        // Another glyph is another image.
        let other = cache.get(key(8), &font, true, &mut rasterizer).cloned();
        assert_ne!(other, first);
        assert_eq!(rasterizer.asked.len(), 2);
        assert_eq!(
            cache.stats(),
            Stats {
                rasterised: 2,
                reused: 1,
                skipped: 0,
            }
        );
        assert_eq!(cache.len(), 2);
    }

    #[test]
    fn the_rasteriser_is_asked_for_the_glyph_as_it_is_kept() {
        let (mut cache, mut rasterizer) = (GlyphCache::new(), FakeRasterizer::new());
        let font = font(24.0);
        let asked = GlyphKey {
            font: ResolvedFontId(3),
            glyph: 9,
            bin: 2,
            subpixel: true,
        };
        cache.get(asked, &font, false, &mut rasterizer);
        assert_eq!(rasterizer.asked, vec![(asked, 24.0, false)]);
    }

    #[test]
    fn a_mask_a_subpixel_and_a_colour_glyph_each_keep_their_kind() {
        let (mut cache, mut rasterizer) = (GlyphCache::new(), FakeRasterizer::new());
        rasterizer.colour.insert(40);
        let font = font(16.0);
        let subpixel = |glyph| GlyphKey {
            subpixel: true,
            ..key(glyph)
        };
        let mut kind = |key: GlyphKey| {
            cache
                .get(key, &font, true, &mut rasterizer)
                .map(|placed| (placed.kind, placed.data.len() as u32))
        };
        // Each has as many bytes a pixel as its kind says.
        let pixels = FakeRasterizer::WIDTH * FakeRasterizer::HEIGHT;
        assert_eq!(kind(key(7)), Some((Kind::Mask, pixels)));
        assert_eq!(kind(subpixel(7)), Some((Kind::Subpixel, pixels * 4)));
        // A colour glyph is in colour whichever was asked.
        assert_eq!(kind(key(40)), Some((Kind::Color, pixels * 4)));
        assert_eq!(kind(subpixel(40)), Some((Kind::Color, pixels * 4)));
        // The mask and the subpixel mask of one glyph are two images, and
        // asking for one again does not give the other.
        assert_eq!(kind(key(7)), Some((Kind::Mask, pixels)));
        assert_eq!(kind(subpixel(7)), Some((Kind::Subpixel, pixels * 4)));
        assert_eq!(rasterizer.asked.len(), 4);
        assert_eq!(cache.len(), 4);
    }

    #[test]
    fn a_place_is_rounded_to_the_nearest_quarter_of_a_pixel() {
        assert_eq!(SUBPIXEL_BINS, 4);
        let places = [
            (10.0, (10, 0)),
            (10.1, (10, 0)),
            (10.2, (10, 1)),
            (10.25, (10, 1)),
            (10.5, (10, 2)),
            (10.7, (10, 3)),
            // Within an eighth of the next pixel: that pixel, bin 0.
            (10.9, (11, 0)),
            (0.0, (0, 0)),
            // Left of the row's start.
            (-0.1, (0, 0)),
            (-0.25, (-1, 3)),
            (-1.5, (-2, 2)),
        ];
        for (x, expected) in places {
            assert_eq!(bin_of(x), expected, "at {x}");
        }
    }

    #[test]
    fn positions_within_a_quarter_pixel_share_an_entry_and_others_do_not() {
        let (mut cache, mut rasterizer) = (GlyphCache::new(), FakeRasterizer::new());
        let font = font(16.0);
        let mut image = |x: f32| {
            let (_, bin) = bin_of(x);
            cache
                .get(GlyphKey { bin, ..key(7) }, &font, true, &mut rasterizer)
                .cloned()
        };
        let at = image(3.0);
        // The same bin, at another pixel and a little off it.
        assert_eq!(image(8.0), at);
        assert_eq!(image(8.1), at);
        // Each other quarter is an image of its own.
        let quarter = image(8.25);
        let half = image(8.5);
        let three = image(8.75);
        assert_eq!(image(20.3), quarter);
        for (index, one) in [&at, &quarter, &half, &three].iter().enumerate() {
            for other in [&at, &quarter, &half, &three].iter().skip(index + 1) {
                assert_ne!(one, other);
            }
        }
        assert_eq!(rasterizer.asked.len(), 4);
        assert_eq!(cache.len(), 4);
    }

    #[test]
    fn the_same_glyph_of_another_font_is_another_entry() {
        let (mut cache, mut rasterizer) = (GlyphCache::new(), FakeRasterizer::new());
        let (small, large) = (font(16.0), font(32.0));
        let first = cache.get(key(7), &small, true, &mut rasterizer).cloned();
        let other = GlyphKey {
            font: ResolvedFontId(1),
            ..key(7)
        };
        let second = cache.get(other, &large, true, &mut rasterizer).cloned();
        assert_ne!(first, second);
        assert_eq!(cache.len(), 2);
    }

    #[test]
    fn a_glyph_with_no_image_is_counted_and_not_kept() {
        let (mut cache, mut rasterizer) = (GlyphCache::new(), FakeRasterizer::new());
        rasterizer.missing.insert(99);
        let font = font(16.0);
        assert_eq!(cache.get(key(99), &font, true, &mut rasterizer), None);
        assert_eq!(cache.get(key(99), &font, true, &mut rasterizer), None);
        assert!(cache.is_empty());
        assert_eq!(
            cache.stats(),
            Stats {
                rasterised: 0,
                reused: 0,
                skipped: 2,
            }
        );
    }
}
