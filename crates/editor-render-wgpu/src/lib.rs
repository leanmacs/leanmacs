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

pub mod glyphs;
pub mod quads;
