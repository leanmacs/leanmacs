//! The `Renderer` port: a frame and a target in, what drawing it cost out.
//!
//! A renderer draws one frame of `editor-layout` on its target, presents
//! it, and answers with plain data ([`Drawn`]). It is one method. What it
//! draws with stays behind it: no type of a drawing library, a GPU or a
//! font rasteriser is named here or by anything above the port.

use std::sync::Arc;

use editor_layout::frame::Frame;

/// What a renderer draws on: a size in physical pixels, and how many of
/// them make one logical pixel.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Target {
    /// Across, in physical pixels.
    pub width: u32,
    /// Down, in physical pixels.
    pub height: u32,
    /// Physical pixels for each logical pixel: 1 on a low-resolution
    /// display, 2 on most high-resolution ones.
    pub scale: f32,
}

/// What a renderer is asked to draw.
#[derive(Debug, Clone, Copy)]
pub struct DrawRequest<'a> {
    /// The frame.
    pub frame: &'a Arc<Frame>,
    /// What to draw it on.
    pub target: Target,
}

/// What a draw did and what it cost, counted and never timed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Drawn {
    /// Whether the frame was presented; `false` when the target could not
    /// be drawn on this time, and the draw is to be tried again.
    pub presented: bool,
    /// The rows it built draw data for: those of the frame whose content
    /// hash it did not hold, once for each distinct hash.
    pub rows_rebuilt: u64,
    /// The rows it drew from what it held, once for each distinct hash.
    pub rows_reused: u64,
    /// The glyph images it rasterised.
    pub glyphs_rasterised: u64,
    /// The glyph images it was asked for and already held.
    pub glyphs_reused: u64,
    /// The glyph images it dropped to make room.
    pub glyphs_evicted: u64,
    /// The glyphs it could not draw: of a font with no bytes, or with no
    /// image.
    pub glyphs_skipped: u64,
    /// The bytes its glyph images take up now.
    pub atlas_bytes: u64,
}

/// The port: draws a frame.
pub trait Renderer {
    /// Draws `request.frame` on the renderer's target at `request.target`'s
    /// size and scale, presents it, and says what that cost.
    fn draw(&mut self, request: &DrawRequest<'_>) -> Drawn;
}
