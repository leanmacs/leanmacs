//! The `Renderer` port's real adapters: frames drawn from a glyph atlas
//! and quads of our own.
//!
//! No published library draws subpixel text
//! (`docs/design/rendering-prior-art.md`, "The drawing library, as
//! chosen"), so what turns a frame into something to draw is written here:
//! which glyph images are kept and for how long ([`glyphs`]) and where
//! ([`atlas`]), what a frame comes to as rectangles ([`painter`],
//! [`quads`]), and how a rectangle's pixel is laid over what is under it
//! ([`blend`]).
//!
//! The modules are public only until the adapters that use them are
//! written: nothing outside this crate is meant to name them.

pub mod atlas;
pub mod blend;
pub mod glyphs;
pub mod painter;
pub mod quads;
pub mod raster;

#[cfg(test)]
mod settings_tests;

/// How many bytes the pages of the glyph atlas may come to, unless a
/// setting says otherwise: 64 MiB.
pub const DEFAULT_ATLAS_BUDGET: u64 = 64 * 1024 * 1024;

/// How far across and down a page of the glyph atlas is, in pixels.
pub const PAGE_SIZE: u32 = 1024;

/// How glyphs are antialiased.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Antialiasing {
    /// By the display: a coverage for each colour stripe, in the order
    /// red, green, blue, below two physical pixels to a logical one, and
    /// one coverage a pixel from two up.
    #[default]
    Auto,
    /// One coverage a pixel, whatever the display.
    Grayscale,
    /// A coverage for each colour stripe, in this order, whatever the
    /// display.
    Subpixel(SubpixelOrder),
}

/// What a renderer of this crate is told once, when it is made.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Settings {
    /// How glyphs are antialiased.
    pub antialiasing: Antialiasing,
    /// Whether glyph outlines are fitted to the pixel grid.
    pub hinting: bool,
    /// How many bytes the pages of the glyph atlas may come to. Glyphs in
    /// use are kept past it ([`glyphs`], "The bound").
    pub atlas_budget: u64,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            antialiasing: Antialiasing::Auto,
            hinting: true,
            atlas_budget: DEFAULT_ATLAS_BUDGET,
        }
    }
}

/// The order of the colour stripes of a display's pixels, from left to
/// right. No window system the editor runs on says which a display has,
/// so it is a setting.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum SubpixelOrder {
    /// Red, green, blue: nearly every display.
    #[default]
    Rgb,
    /// Blue, green, red.
    Bgr,
}
