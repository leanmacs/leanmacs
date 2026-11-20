//! The rasteriser port: what makes a glyph's image.
//!
//! A renderer draws a glyph from an image of it, and this crate owns the
//! port that makes one ([`Rasterize`]) and its data: what an image is kept
//! by ([`GlyphKey`]), what a rasteriser is asked ([`GlyphRequest`]) and
//! what it gives back ([`GlyphImage`], of a [`Kind`]). It depends on
//! `editor-layout` alone, for the font a glyph is drawn in and the colour
//! its run is painted with, and re-exports both, so an adapter needs no
//! edge of its own to layout. It names no rasterising library: the
//! adapters are swash's, in `editor-render-wgpu`, and Core Text's, in
//! `editor-raster-coretext`.
//!
//! - [`luminance_bucket`]: which of five greys a run's colour is drawn
//!   as, for a rasteriser whose masks depend on it
//!   ([`Rasterize::by_luminance`]).
//! - [`Fallback`]: one rasteriser, and another for what the first
//!   declines.
//! - [`fake`]: the port's published fake, which reads no font.
//! - [`contract`]: the rules the fake and every real adapter are held to.
//!
//! # Where an addition goes
//!
//! A new fact a rasteriser is asked is a field of [`GlyphRequest`], or of
//! [`GlyphKey`] when the image depends on it. A new fact an adapter states
//! about itself is a method of [`Rasterize`] with a default, as
//! [`Rasterize::by_luminance`] is; the decision made from it stays in the
//! painter. A new rule every adapter keeps is a property of [`contract`],
//! seen to fail on a rasteriser written to break it.

pub use editor_layout::face::Color;
pub use editor_layout::shaper::{ResolvedFont, ResolvedFontId};

pub mod contract;
pub mod fake;

/// How many places across a pixel a glyph is rasterised at.
pub const SUBPIXEL_BINS: u8 = 4;

/// What a glyph image holds for each pixel.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Kind {
    /// One byte: how much of the pixel the glyph covers.
    Mask,
    /// Four bytes: how much of the pixel's red, green and blue stripes
    /// the glyph covers, and a fourth that is not read.
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
    /// The luminance bucket of the run's colour, from 0 (black) to 4
    /// (white) ([`luminance_bucket`]); 0 for a rasteriser whose images do
    /// not depend on it ([`Rasterize::by_luminance`]).
    pub bucket: u8,
}

impl GlyphKey {
    /// How far right of a whole pixel the glyph is drawn, in pixels: its
    /// bin's fraction of a pixel.
    pub fn offset(&self) -> f32 {
        f32::from(self.bin) / f32::from(SUBPIXEL_BINS)
    }
}

/// One glyph to rasterise.
#[derive(Debug, Clone, Copy)]
pub struct GlyphRequest<'a> {
    /// The font: its bytes, its face, its size and its synthesis.
    pub font: &'a ResolvedFont,
    /// What the image will be kept by: the glyph, the bin, the kind asked
    /// for and the luminance bucket.
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

/// What makes a glyph's image.
pub trait Rasterize {
    /// The image of the glyph `request` names; `None` when there is none
    /// to make: the font has no bytes, no such glyph, or is one this
    /// rasteriser declines to draw.
    fn rasterize(&mut self, request: &GlyphRequest<'_>) -> Option<GlyphImage>;

    /// Whether its images depend on the luminance of the run's colour, so
    /// that a glyph is kept once for each bucket ([`GlyphKey::bucket`]).
    /// A fact the adapter states; the painter decides from it.
    fn by_luminance(&self) -> bool {
        false
    }
}

impl<R: Rasterize + ?Sized> Rasterize for Box<R> {
    fn rasterize(&mut self, request: &GlyphRequest<'_>) -> Option<GlyphImage> {
        (**self).rasterize(request)
    }

    fn by_luminance(&self) -> bool {
        (**self).by_luminance()
    }
}

/// The luminance bucket of `color`, from 0 (black) to 4 (white): its
/// Rec. 709 luminance over the sRGB-encoded channels, `0.2126 r + 0.7152
/// g + 0.0722 b` with each channel from 0 to 1, times 4 and rounded.
/// Alpha is not read. Zed's rule: a rasteriser whose masks depend on the
/// colour draws each bucket in the grey `bucket / 4`.
pub fn luminance_bucket(color: Color) -> u8 {
    let [red, green, blue, _] = color.0.to_be_bytes();
    let channel = |value: u8| f32::from(value) / 255.0;
    let luminance = 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue);
    (4.0 * luminance + 0.5).floor().clamp(0.0, 4.0) as u8
}

/// One rasteriser, and a second for every glyph the first declines.
///
/// Its images depend on the luminance as its first's do: the key the
/// painter asks by is the first's, and the second is handed the same key.
#[derive(Debug)]
pub struct Fallback<A, B> {
    /// The rasteriser asked first.
    first: A,
    /// The one asked for what the first declines.
    second: B,
}

impl<A, B> Fallback<A, B> {
    /// `first`, falling back to `second`.
    pub fn new(first: A, second: B) -> Self {
        Self { first, second }
    }

    /// The rasteriser asked first.
    pub fn first(&self) -> &A {
        &self.first
    }

    /// The rasteriser asked for what the first declines.
    pub fn fallback(&self) -> &B {
        &self.second
    }
}

impl<A: Rasterize, B: Rasterize> Rasterize for Fallback<A, B> {
    fn rasterize(&mut self, request: &GlyphRequest<'_>) -> Option<GlyphImage> {
        self.first
            .rasterize(request)
            .or_else(|| self.second.rasterize(request))
    }

    fn by_luminance(&self) -> bool {
        self.first.by_luminance()
    }
}

#[cfg(test)]
mod tests;
