//! The real adapter of the `Shaper` port (`editor_layout::shaper`), over
//! Parley and fontique.
//!
//! No type of Parley or of fontique is public here: a caller hands this
//! crate font files as bytes and gets the port's own types back.

mod fonts;

pub use fonts::{FontSet, FontSetError};
