//! The `Renderer` port's real adapters: frames drawn from a glyph atlas
//! and quads of our own.
//!
//! No published library draws subpixel text
//! (`docs/design/rendering-prior-art.md`, "The drawing library, as
//! chosen"), so what turns a frame into something to draw is written here:
//! which glyph images are kept and for how long ([`glyphs`]), and what a
//! row of a frame comes to as rectangles ([`quads`]).
//!
//! The modules are public only until the adapters that use them are
//! written: nothing outside this crate is meant to name them.

pub mod atlas;
pub mod glyphs;
pub mod painter;
pub mod quads;

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
