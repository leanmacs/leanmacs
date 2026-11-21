//! The port's published fake: a rasteriser that reads no font.
//!
//! Every glyph is a box of ink, drawn as geometry, so that the fake keeps
//! the port's contract ([`contract`](crate::contract)) as a real
//! rasteriser must:
//!
//! - At bin 0 the box is [`FakeRasterizer::WIDTH`] columns across and
//!   [`FakeRasterizer::HEIGHT`] rows down, its left edge at the pen and
//!   its top [`FakeRasterizer::HEIGHT`] above the baseline.
//! - A bin moves it right by its fraction of a pixel ([`GlyphKey::offset`]):
//!   its edge columns are then partly covered, and the image is one column
//!   wider at every bin but 0.
//! - A tinted fake ([`FakeRasterizer::tinted`]) reads the luminance: each
//!   bucket widens the box by a quarter of a column. An untinted one draws
//!   every bucket alike.
//!
//! The level of the box's ink is made from the font's id, the glyph and
//! the kind asked for, and from the row, and is never 0: so two glyphs,
//! two fonts or two kinds give different bytes, and so do two places in
//! one image and the four bytes of a pixel of a subpixel mask or a colour
//! image. Two bins differ by their geometry, and so do two buckets of
//! a tinted fake; the level does not depend on either, so the ink is the
//! same at every bin, as the contract asks.
//!
//! A glyph is a mask or a subpixel mask as it is asked for, in colour
//! whichever was asked when a test put its id in
//! [`FakeRasterizer::colour`], draws nothing (a space) when its id is in
//! [`FakeRasterizer::blank`], and has no image when its id is in
//! [`FakeRasterizer::missing`]. It keeps every request it is given.

use std::collections::HashSet;
use std::sync::Arc;

use crate::{GlyphImage, GlyphKey, GlyphRequest, Kind, Rasterize, ResolvedFont};

/// The fake rasteriser.
#[derive(Debug, Default)]
pub struct FakeRasterizer {
    /// Every request, in order: its key, its font's size, and whether it
    /// asked for hinting.
    pub asked: Vec<(GlyphKey, f32, bool)>,
    /// The glyph ids that are colour glyphs.
    pub colour: HashSet<u32>,
    /// The glyph ids that have no image.
    pub missing: HashSet<u32>,
    /// The glyph ids that draw nothing, as a space: an image of no size.
    pub blank: HashSet<u32>,
    /// The size of the box at bin 0, when a test wants another than
    /// [`Self::WIDTH`] by [`Self::HEIGHT`].
    pub size: Option<(u32, u32)>,
    /// Whether its images depend on the luminance bucket
    /// ([`Rasterize::by_luminance`]).
    pub tinted: bool,
}

impl FakeRasterizer {
    /// How far across the box is at bin 0, untinted.
    pub const WIDTH: u32 = 6;
    /// How far down an image is, and how far above the baseline its top.
    pub const HEIGHT: u32 = 10;

    /// A rasteriser in which every glyph is a mask or a subpixel mask,
    /// whatever the luminance.
    pub fn new() -> Self {
        Self::default()
    }

    /// The image it makes for `key`, without recording a request.
    pub fn image(&self, key: GlyphKey) -> Option<GlyphImage> {
        if self.missing.contains(&key.glyph) {
            return None;
        }
        let kind = if self.colour.contains(&key.glyph) {
            Kind::Color
        } else if key.subpixel {
            Kind::Subpixel
        } else {
            Kind::Mask
        };
        if self.blank.contains(&key.glyph) {
            return Some(GlyphImage {
                kind,
                width: 0,
                height: 0,
                left: 0,
                top: 0,
                data: Vec::new(),
            });
        }
        let (across, height) = self.size.unwrap_or((Self::WIDTH, Self::HEIGHT));
        // The box, in pixels from the pen: from the bin's offset, as wide
        // as its size and, tinted, a quarter of a column for each bucket.
        let from = f64::from(key.offset());
        let wide = if self.tinted {
            f64::from(across) + f64::from(key.bucket) / 4.0
        } else {
            f64::from(across)
        };
        let to = from + wide;
        let width = if across == 0 { 0 } else { to.ceil() as u32 };
        // A level made from everything but the bin and the bucket, and
        // from the row, never 0.
        let seed = key
            .glyph
            .wrapping_mul(31)
            .wrapping_add(key.font.0.wrapping_mul(17))
            .wrapping_add(u32::from(key.subpixel) * 3)
            .wrapping_add(u32::from(kind == Kind::Color) * 5);
        let mut data = Vec::with_capacity((width * height * kind.bytes()) as usize);
        for row in 0..height {
            let level = f64::from(64 + seed.wrapping_add(row.wrapping_mul(37)) % 192);
            for column in 0..width {
                let (left, right) = (f64::from(column), f64::from(column) + 1.0);
                let covered = (right.min(to) - left.max(from)).clamp(0.0, 1.0);
                // Each byte of a pixel of four its own, so that an order
                // of the stripes is seen in the bytes.
                data.extend(
                    (0..kind.bytes())
                        .map(|byte| ((level - 16.0 * f64::from(byte)) * covered).round() as u8),
                );
            }
        }
        Some(GlyphImage {
            kind,
            width,
            height,
            left: 0,
            top: height as i32,
            data,
        })
    }
}

impl Rasterize for FakeRasterizer {
    fn rasterize(&mut self, request: &GlyphRequest<'_>) -> Option<GlyphImage> {
        let key = request.key;
        self.asked.push((key, request.font.size, request.hint));
        self.image(key)
    }

    fn by_luminance(&self) -> bool {
        self.tinted
    }
}

/// A resolved font of `size` pixels with no bytes, as layout's fake
/// shaper describes its fonts.
pub fn font(size: f32) -> ResolvedFont {
    ResolvedFont {
        data: Arc::new([0_u8; 0]),
        file: 0,
        index: 0,
        size,
        coords: Vec::new(),
        embolden: false,
        skew: None,
    }
}
