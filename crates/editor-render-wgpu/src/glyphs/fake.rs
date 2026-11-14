//! A hand-written fake of [`Rasterize`], for this crate's tests: it reads
//! no font.
//!
//! Every glyph has an image of one size, [`FakeRasterizer::WIDTH`] by
//! [`FakeRasterizer::HEIGHT`], placed with its left edge at the glyph's
//! place and its top [`FakeRasterizer::HEIGHT`] above the baseline. Its
//! bytes are made from what was asked, so two requests that differ in the
//! font's id, the glyph, the bin or the kind give different images, and
//! the same request the same one. A glyph is a mask or a subpixel mask as
//! it is asked for, in colour whichever was asked when a test put its id
//! in [`FakeRasterizer::colour`], and has no image when its id is in
//! [`FakeRasterizer::missing`]. It keeps every request it is given.

use std::collections::HashSet;
use std::sync::Arc;

use editor_layout::shaper::ResolvedFont;

use super::{GlyphImage, GlyphKey, GlyphRequest, Kind, Rasterize};

/// The fake rasteriser.
#[derive(Debug, Default)]
pub(crate) struct FakeRasterizer {
    /// Every request, in order: its key, its font's size, and whether it
    /// asked for hinting.
    pub(crate) asked: Vec<(GlyphKey, f32, bool)>,
    /// The glyph ids that are colour glyphs.
    pub(crate) colour: HashSet<u32>,
    /// The glyph ids that have no image.
    pub(crate) missing: HashSet<u32>,
    /// The size of every image, when a test wants another than
    /// [`Self::WIDTH`] by [`Self::HEIGHT`].
    pub(crate) size: Option<(u32, u32)>,
}

impl FakeRasterizer {
    /// How far across an image is.
    pub(crate) const WIDTH: u32 = 6;
    /// How far down an image is, and how far above the baseline its top.
    pub(crate) const HEIGHT: u32 = 10;

    /// A rasteriser in which every glyph is a mask or a subpixel mask.
    pub(crate) fn new() -> Self {
        Self::default()
    }
}

impl Rasterize for FakeRasterizer {
    fn rasterize(&mut self, request: &GlyphRequest<'_>) -> Option<GlyphImage> {
        let key = request.key;
        self.asked.push((key, request.font.size, request.hint));
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
        let (width, height) = self.size.unwrap_or((Self::WIDTH, Self::HEIGHT));
        // A byte made from everything the image is asked by, and from
        // where in the image it is, never 0: the image has ink everywhere.
        let seed = key
            .glyph
            .wrapping_mul(31)
            .wrapping_add(key.font.0.wrapping_mul(17))
            .wrapping_add(u32::from(key.bin) * 7)
            .wrapping_add(u32::from(key.subpixel) * 3);
        let data = (0..width * height * kind.bytes())
            .map(|index| (seed.wrapping_add(index) % 255 + 1) as u8)
            .collect();
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

/// A resolved font of `size` pixels with no bytes, as layout's fake
/// shaper describes its fonts.
pub(crate) fn font(size: f32) -> ResolvedFont {
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
