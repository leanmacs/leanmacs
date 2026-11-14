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
//! [`WgpuRenderer`] draws them with wgpu (`gpu`), to a target of its own:
//! the gate runs it on wgpu's no-op back end, and its picture is checked
//! on demand. [`present`] holds how a frame is to be presented to a
//! window, as a decision and a pure function; no surface is made here.

mod atlas;
mod blend;
mod cpu;
mod glyphs;
mod gpu;
mod painter;
pub mod present;
mod quads;
mod raster;

#[cfg(test)]
mod settings_tests;

use std::error::Error;
use std::fmt;

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

/// Why there is no GPU renderer: this machine has no adapter wgpu can
/// use, or the adapter refused the device or the pipeline.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NoAdapter {
    /// What wgpu said.
    reason: String,
}

impl fmt::Display for NoAdapter {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "no GPU renderer: {}", self.reason)
    }
}

impl Error for NoAdapter {}

/// The GPU adapter of the `Renderer` port: it draws a frame with wgpu, to
/// a target of its own that can be read back.
///
/// It is the same painter as [`HeadlessRenderer`]'s, down to the list of
/// quads and the bytes of the atlas; what it does of its own is send the
/// atlas to textures and draw the quads through one pipeline (the module
/// `gpu`). It presents to no window: the surface is the display
/// pipeline's phase 6.
///
/// A draw wgpu refuses answers `presented: false`, when the frame is
/// already painted. What was painted for it is not lost from the count:
/// the next draw that presents answers for it too, as if the two were one
/// draw (the module `painter`, "What a paint answers").
///
/// The gate runs it on wgpu's no-op back end only, which checks every
/// call and draws nothing. Its picture is compared with the reference
/// image on demand, on a real adapter (`mise run render-gpu`).
pub struct WgpuRenderer {
    /// What turns a frame into quads.
    painter: Painter<SwashRasterizer>,
    /// The GPU.
    device: gpu::Device,
    /// What wgpu said of the last draw it refused.
    refused: Option<String>,
}

impl WgpuRenderer {
    /// A renderer on an adapter of this machine, with no window.
    ///
    /// What it finds depends on the machine, so no test calls it: the
    /// crate's `clippy.toml` forbids it to them, and its one caller is
    /// the example `gpu`.
    pub fn on_this_machine(settings: Settings) -> Result<Self, NoAdapter> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle());
        Self::over(&instance, settings, true)
    }

    /// A renderer on an adapter of `instance`, which blends by a coverage
    /// for each channel when the adapter can and `allow_per_channel` says
    /// it may.
    fn over(
        instance: &wgpu::Instance,
        settings: Settings,
        allow_per_channel: bool,
    ) -> Result<Self, NoAdapter> {
        let device = gpu::Device::new(instance, allow_per_channel)
            .map_err(|gpu::Unavailable(reason)| NoAdapter { reason })?;
        let painter = Painter::new(
            SwashRasterizer::new(),
            &settings,
            device.per_channel(),
            PAGE_SIZE,
        );
        Ok(Self {
            painter,
            device,
            refused: None,
        })
    }

    /// The adapter's name and back end, for a person.
    pub fn adapter(&self) -> String {
        self.device.adapter().to_owned()
    }

    /// Whether the adapter blends by a coverage for each channel. When it
    /// cannot, glyphs are antialiased with one coverage a pixel whatever
    /// the settings say.
    pub fn per_channel(&self) -> bool {
        self.device.per_channel()
    }

    /// What wgpu said of the last draw, when it refused it: that draw
    /// answered `presented: false`.
    pub fn refused(&self) -> Option<&str> {
        self.refused.as_deref()
    }

    /// The picture of the frame last drawn, read back from the GPU; a
    /// picture of no size before a first draw, or when it cannot be read.
    pub fn read_back(&mut self) -> Image {
        self.device.read_back().unwrap_or_else(|refused| {
            self.refused = Some(refused);
            cpu::cleared(0, 0)
        })
    }
}

impl Renderer for WgpuRenderer {
    fn draw(&mut self, request: &DrawRequest<'_>) -> Drawn {
        let target = request.target;
        let drawn = self.painter.paint(request.frame, target);
        let sent = self.device.draw(
            self.painter.quads(),
            self.painter.atlas(),
            target.width,
            target.height,
        );
        self.refused = sent.err();
        if self.refused.is_some() {
            // What was painted is held, and answered by the draw that
            // next presents.
            self.painter.refused();
        }
        Drawn {
            presented: self.refused.is_none(),
            ..drawn
        }
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
