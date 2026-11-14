//! The `Renderer` port's real adapters: frames drawn from a glyph atlas
//! and quads of our own.
//!
//! No published library draws subpixel text
//! (`docs/design/rendering-prior-art.md`, "The drawing library, as
//! chosen"), so what turns a frame into something to draw is written here:
//! which glyph images are kept and for how long (the module `glyphs`) and
//! where (`atlas`), what a frame comes to as rectangles (`painter`,
//! `quads`), and how a rectangle's pixel is laid over what is under it
//! (`blend`). Glyph images are made by `swash` (`raster`) and packed by
//! `etagere` (`atlas`); no type of either is public here. Those modules
//! are private, and their docs say what each decides.
//!
//! [`HeadlessRenderer`] lays the quads over a pixel buffer on the CPU
//! (`cpu`): it needs no GPU, and every test of it runs in the gate.

mod atlas;
mod blend;
mod cpu;
mod glyphs;
mod painter;
mod quads;
mod raster;

#[cfg(test)]
mod settings_tests;

use editor_render::port::{DrawRequest, Drawn, Renderer};

use crate::painter::Painter;
use crate::raster::SwashRasterizer;

/// A picture: what a renderer drew, read back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Image {
    /// How far across it is, in pixels.
    pub width: u32,
    /// How far down.
    pub height: u32,
    /// Its pixels, row by row from the top: red, green, blue and alpha
    /// for each, as sRGB values.
    pub rgba: Vec<u8>,
}

impl Image {
    /// The pixel `x` across and `y` down; `None` outside the image.
    pub fn pixel(&self, x: u32, y: u32) -> Option<[u8; 4]> {
        if x >= self.width || y >= self.height {
            return None;
        }
        let start = (y as usize * self.width as usize + x as usize) * 4;
        self.rgba.get(start..start + 4)?.try_into().ok()
    }
}

/// The headless adapter of the `Renderer` port: it draws a frame into a
/// picture in memory, with no window and no GPU.
///
/// It is the same painter as the GPU adapter's, down to the list of quads
/// and the bytes of the atlas; what it does of its own is lay those quads
/// over a pixel buffer on the CPU (the module `cpu`). Glyphs are rasterised from
/// the font bytes a frame carries, so a frame of layout's fake shaper,
/// whose fonts have no bytes, is drawn without its glyphs.
pub struct HeadlessRenderer {
    /// What turns a frame into quads.
    painter: Painter<SwashRasterizer>,
    /// The picture of the frame last drawn.
    image: Image,
}

impl HeadlessRenderer {
    /// A renderer that has drawn nothing: its picture is of no size.
    pub fn new(settings: Settings) -> Self {
        Self {
            painter: Painter::new(SwashRasterizer::new(), &settings, true, PAGE_SIZE),
            image: cpu::cleared(0, 0),
        }
    }

    /// The picture of the frame last drawn, the size of its target.
    pub fn image(&self) -> &Image {
        &self.image
    }
}

impl Renderer for HeadlessRenderer {
    fn draw(&mut self, request: &DrawRequest<'_>) -> Drawn {
        let target = request.target;
        let drawn = self.painter.paint(request.frame, target);
        self.image = cpu::cleared(target.width, target.height);
        cpu::composite(&mut self.image, self.painter.quads(), self.painter.atlas());
        Drawn {
            presented: true,
            ..drawn
        }
    }
}

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
    /// use are kept past it (the module `glyphs`, "The bound").
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
