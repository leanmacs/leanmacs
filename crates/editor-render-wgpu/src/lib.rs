//! The `Renderer` port's real adapters: frames drawn from a glyph atlas
//! and quads of our own.
//!
//! No published library draws subpixel text
//! (`docs/design/rendering-prior-art.md`, "The drawing library, as
//! chosen"), so what turns a frame into something to draw is written here:
//! which glyph images are kept and for how long (the module `glyphs`) and
//! where (`atlas`), what a frame comes to as rectangles (`painter`,
//! `quads`), and how a rectangle's pixel is laid over what is under it
//! (`blend`). Glyph images are made through the rasteriser port, which
//! `editor-raster` owns: by `swash` (`raster`) unless the program hands a
//! renderer another rasteriser, and by swash for every glyph that one
//! declines. They are packed by `etagere` (`atlas`); no type of either
//! library is public here. Those modules are private, and their docs say
//! what each decides.
//!
//! [`HeadlessRenderer`] lays the quads over a pixel buffer on the CPU
//! (`cpu`): it needs no GPU, and every test of it runs in the gate.
//! [`WgpuRenderer`] draws them with wgpu (`gpu`): to a target of its own,
//! or to a window's surface, which it presents
//! ([`WgpuRenderer::on_window`]). The gate runs it on wgpu's no-op back
//! end, to a target of its own, and its picture is checked on demand.
//! [`present`] holds how a frame is presented to a window, as a decision
//! and a pure function, and `surface` what else is decided about a
//! window's surface: the handles wgpu is given, the format, when the
//! surface is configured, what is done when it gives no texture, and how
//! its picture is read. The window reaches this crate
//! as the window port's own data (`editor_platform::NativeWindow`), and
//! that type is all of the port this crate uses.
//!
//! The calls that make a surface, configure it, take its texture and
//! present it need a window, so no test in the gate reaches them: the
//! no-op back end presents to no surface. They are run on demand, by
//! `editor-ffi`'s example `window`, on a real window.

mod atlas;
mod blend;
mod cpu;
mod glyphs;
mod gpu;
mod painter;
mod png;
pub mod present;
mod quads;
mod raster;
mod surface;

#[cfg(test)]
mod placement_tests;
#[cfg(test)]
mod rasterizer_tests;
#[cfg(test)]
mod settings_tests;
#[cfg(test)]
mod weight_tests;

use std::error::Error;
use std::fmt;

use editor_platform::NativeWindow;
use editor_raster::{Fallback, GlyphImage, GlyphRequest, Rasterize};
use editor_render::port::{DrawRequest, Drawn, Renderer};

use crate::painter::Painter;
use crate::present::{Asked, Offered};
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

    /// The picture the PNG file `bytes` holds: 8 bits a channel, RGB or
    /// RGBA, an RGB one read as opaque. Refused, with a sentence, when the
    /// bytes are not such a file.
    pub fn from_png(bytes: &[u8]) -> Result<Image, String> {
        png::decode(bytes)
    }

    /// The picture as the bytes of a PNG file: RGB, 8 bits a channel, at
    /// high compression. Its alpha is not written: what this crate draws
    /// is opaque everywhere. Refused, with a sentence, when the picture
    /// has no pixels across or down, which a PNG file cannot hold.
    pub fn to_png(&self) -> Result<Vec<u8>, String> {
        png::encode(self)
    }

    /// How the picture differs from `other`: `None` when they are not the
    /// same size, and otherwise the largest difference of any channel of
    /// any pixel, with how many pixels differ at all.
    pub fn difference(&self, other: &Image) -> Option<(u8, usize)> {
        png::difference(self, other)
    }
}

/// What a renderer's glyph images are made by: the rasteriser it was
/// handed ([`HeadlessRenderer::rasterizing_with`],
/// [`WgpuRenderer::rasterizing_with`]), and swash, at the settings'
/// weight, for every glyph that one declines.
type Rasterizers = Fallback<Box<dyn Rasterize + Send>, SwashRasterizer>;

/// The rasteriser a renderer asks first until it is handed one: it
/// declines every glyph, so swash draws them all.
struct Declines;

impl Rasterize for Declines {
    fn rasterize(&mut self, _: &GlyphRequest<'_>) -> Option<GlyphImage> {
        None
    }

    fn name(&self) -> &'static str {
        DECLINES
    }
}

/// What [`Declines`] is called.
const DECLINES: &str = "no rasteriser";

/// What draws a renderer's glyph images, for a person
/// ([`HeadlessRenderer::rasterizing`], [`WgpuRenderer::rasterizing`]):
/// `swash`, or the rasteriser it was handed and swash for what that one
/// declines. Whatever prints it prints this, as it does [`Masks`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rasterizing {
    /// The name of the rasteriser asked first ([`Rasterize::name`]).
    first: &'static str,
}

impl Rasterizing {
    /// What draws the glyphs of `rasterizers`.
    fn of(rasterizers: &Rasterizers) -> Self {
        Self {
            first: rasterizers.first().name(),
        }
    }
}

impl fmt::Display for Rasterizing {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.first == DECLINES {
            formatter.write_str("swash")
        } else {
            write!(formatter, "{}, and swash for what it declines", self.first)
        }
    }
}

/// `first`, falling back to swash at `dilation` ([`Weight::dilation`]).
fn rasterizers(first: Box<dyn Rasterize + Send>, dilation: f32) -> Rasterizers {
    Fallback::new(first, SwashRasterizer::dilated(dilation))
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
    painter: Painter<Rasterizers>,
    /// The picture of the frame last drawn.
    image: Image,
    /// How much the coverage of dark text is raised ([`Weight::contrast`]).
    contrast: f32,
    /// The space it blends in ([`Settings::blending`]).
    blending: Blending,
}

impl HeadlessRenderer {
    /// A renderer that has drawn nothing: its picture is of no size.
    pub fn new(settings: Settings) -> Self {
        let rasterizer = rasterizers(Box::new(Declines), settings.weight.dilation);
        Self {
            painter: Painter::new(rasterizer, &settings, true, PAGE_SIZE),
            image: cpu::cleared(0, 0),
            contrast: settings.weight.contrast,
            blending: settings.blending,
        }
    }

    /// The renderer, drawing its glyphs with `rasterizer`, and with swash
    /// at its settings' weight for every glyph `rasterizer` declines. Made
    /// after a draw, the next draw makes every glyph image again and
    /// builds every row again.
    pub fn rasterizing_with(mut self, rasterizer: impl Rasterize + Send + 'static) -> Self {
        let dilation = self.painter.rasterizer().fallback().dilation();
        self.painter
            .set_rasterizer(rasterizers(Box::new(rasterizer), dilation));
        self
    }

    /// The picture of the frame last drawn, the size of its target.
    pub fn image(&self) -> &Image {
        &self.image
    }

    /// The kind of mask the last draw asked its glyph images in; none
    /// before a first draw ([`Masks`]).
    pub fn masks(&self) -> Option<Masks> {
        self.painter.masks()
    }

    /// What draws its glyph images.
    pub fn rasterizing(&self) -> Rasterizing {
        Rasterizing::of(self.painter.rasterizer())
    }

    /// The space it blends in: its settings', which the CPU can always
    /// blend in.
    pub fn blending(&self) -> Blending {
        self.blending
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
/// a target of its own that can be read back
/// ([`WgpuRenderer::on_this_machine`]) or to a window, which it presents
/// to ([`WgpuRenderer::on_window`]).
///
/// It is the same painter as [`HeadlessRenderer`]'s, down to the list of
/// quads and the bytes of the atlas; what it does of its own is send the
/// atlas to textures and draw the quads through one pipeline (the module
/// `gpu`).
///
/// A draw wgpu refuses answers `presented: false`, when the frame is
/// already painted, and so does a draw on a window whose surface gave no
/// texture: a window that is occluded, or a surface that stays outdated
/// once it has been configured again. Of the first it also answers
/// `hidden: true`, so that the render loop does not try again every
/// refresh while nobody can see the window. What was painted for it is
/// not lost from the count:
/// the next draw that presents answers for it too, as if the two were one
/// draw (the module `painter`, "What a paint answers").
///
/// The gate runs it on wgpu's no-op back end only, which checks every
/// call and draws nothing. Its picture is compared with the reference
/// image on demand, on a real adapter (`mise run render-gpu`).
pub struct WgpuRenderer {
    /// What turns a frame into quads.
    painter: Painter<Rasterizers>,
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

    /// A renderer that presents to `window`: on an adapter of this machine
    /// that can, through a surface made on the window. Each draw is then
    /// drawn on the window and presented, as
    /// [`present::choose`] says: without tearing, one frame waiting at
    /// most.
    ///
    /// It is refused, with the reason, when no surface can be made on the
    /// window, when no adapter can present to it, or when the surface
    /// offers nothing to configure it with.
    ///
    /// What it finds depends on the machine and needs a window, so no test
    /// calls it: the crate's `clippy.toml` forbids it to them.
    ///
    /// # Safety
    ///
    /// `window` is a live window of the system, and stays one until the
    /// renderer is dropped: the surface holds its handles and nothing
    /// keeps the window alive for it. It is called on the thread that runs
    /// the window, which is where the window port tells of the window
    /// (`Canvas::Opened`): macOS makes a surface nowhere else. The renderer
    /// may then be sent to another thread to draw, and is dropped before
    /// the window is.
    pub unsafe fn on_window(window: &NativeWindow, settings: Settings) -> Result<Self, NoAdapter> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle());
        // SAFETY: the caller's.
        unsafe { Self::over_window(&instance, window, settings, true) }
    }

    /// Keeps the picture of each draw from here on, for
    /// [`WgpuRenderer::read_back`]: a renderer on a window copies what it
    /// drew out of the surface before presenting it. That is for checking
    /// a window's picture, and the editor never asks for it. A renderer
    /// with a target of its own is always read back, and is not changed.
    ///
    /// It answers whether there is a picture to keep: `false` on a window
    /// whose surface does not let its texture be copied from. That is
    /// what the surface offers and nothing went wrong, so a check may let
    /// it pass where it must not let a read that failed: any other reason
    /// a picture cannot be read back comes from
    /// [`WgpuRenderer::read_back`], through [`WgpuRenderer::refused`].
    pub fn keep_picture(&mut self) -> bool {
        self.device.keep_picture()
    }

    /// A renderer on an adapter of `instance` that presents to `window`.
    ///
    /// # Safety
    ///
    /// As [`WgpuRenderer::on_window`].
    unsafe fn over_window(
        instance: &wgpu::Instance,
        window: &NativeWindow,
        settings: Settings,
        allow_per_channel: bool,
    ) -> Result<Self, NoAdapter> {
        let (raw_window_handle, raw_display_handle) = surface::handles(window);
        let target = wgpu::SurfaceTargetUnsafe::RawHandle {
            raw_display_handle: Some(raw_display_handle),
            raw_window_handle,
        };
        // SAFETY: the caller's: the window is live, and outlives the
        // renderer that holds the surface.
        let surface =
            unsafe { instance.create_surface_unsafe(target) }.map_err(|error| NoAdapter {
                reason: format!("no surface on the window: {error}"),
            })?;
        Self::with(
            gpu::Device::on_surface(instance, surface, settings.presentation, allow_per_channel),
            settings,
        )
    }

    /// A renderer on an adapter of `instance`, which blends by a coverage
    /// for each channel when the adapter can and `allow_per_channel` says
    /// it may.
    fn over(
        instance: &wgpu::Instance,
        settings: Settings,
        allow_per_channel: bool,
    ) -> Result<Self, NoAdapter> {
        Self::with(
            gpu::Device::new(instance, allow_per_channel, settings.blending),
            settings,
        )
    }

    /// A renderer over `device`, if there is one.
    fn with(
        device: Result<gpu::Device, gpu::Unavailable>,
        settings: Settings,
    ) -> Result<Self, NoAdapter> {
        let mut device = device.map_err(|gpu::Unavailable(reason)| NoAdapter { reason })?;
        device.contrast = settings.weight.contrast;
        let painter = Painter::new(
            rasterizers(Box::new(Declines), settings.weight.dilation),
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

    /// The renderer, drawing its glyphs with `rasterizer`, and with swash
    /// at its settings' weight for every glyph `rasterizer` declines. Made
    /// after a draw, the next draw makes every glyph image again and
    /// builds every row again.
    pub fn rasterizing_with(mut self, rasterizer: impl Rasterize + Send + 'static) -> Self {
        let dilation = self.painter.rasterizer().fallback().dilation();
        self.painter
            .set_rasterizer(rasterizers(Box::new(rasterizer), dilation));
        self
    }

    /// What the window's surface offered, what the run asked for
    /// ([`Settings::presentation`]) and what the surface was configured
    /// with; `None` for a renderer with no window, and before its first
    /// draw configures the surface.
    pub fn presentation(&self) -> Option<Offered> {
        self.device.presentation()
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

    /// The space it blends in: its settings' ([`Settings::blending`]),
    /// unless it draws on a window whose surface cannot blend in that
    /// space, which then blends in linear light.
    pub fn blending(&self) -> Blending {
        self.device.blending()
    }

    /// The kind of mask the last draw asked its glyph images in, whether
    /// or not it was presented; none before a first draw ([`Masks`]).
    pub fn masks(&self) -> Option<Masks> {
        self.painter.masks()
    }

    /// What draws its glyph images.
    pub fn rasterizing(&self) -> Rasterizing {
        Rasterizing::of(self.painter.rasterizer())
    }

    /// Why the last draw was not presented, when it was not: what wgpu
    /// said in refusing it, or that the window's surface gave no texture.
    /// That draw answered `presented: false`. It is also why the last
    /// picture could not be read back, when it could not.
    pub fn refused(&self) -> Option<&str> {
        self.refused.as_deref()
    }

    /// The picture of the frame last drawn, read back from the GPU; a
    /// picture of no size before a first draw, or when it cannot be read.
    ///
    /// A renderer on a window gives the picture it kept of its last draw
    /// ([`WgpuRenderer::keep_picture`]), as the surface held it before it
    /// was presented: a picture of no size when none is kept, and when the
    /// surface's texture cannot be copied from or is of a format that is
    /// not a picture's, which [`WgpuRenderer::refused`] then says.
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
            // A window that is occluded gave no texture: the loop is not
            // to try again until the window says more.
            hidden: self.refused.is_some() && self.device.hidden(),
            ..drawn
        }
    }
}

impl Renderer for HeadlessRenderer {
    fn draw(&mut self, request: &DrawRequest<'_>) -> Drawn {
        let target = request.target;
        let drawn = self.painter.paint(request.frame, target);
        self.image = cpu::cleared(target.width, target.height);
        cpu::composite(
            &mut self.image,
            self.painter.quads(),
            self.painter.atlas(),
            self.contrast,
            self.blending,
        );
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

/// The space a quad is blended over what is under it in, the whole frame
/// alike: fills, masks and colour images (the module `blend`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Blending {
    /// In linear light: the target's sRGB values are made linear, blended
    /// and encoded again, so half coverage of white on black is 188 of
    /// 255. What every platform gets unless its program says otherwise.
    #[default]
    Linear,
    /// In the sRGB-encoded values themselves, with no conversion either
    /// way, so half coverage of white on black is 128: as Core Graphics
    /// composites in an 8-bit sRGB bitmap, which is how macOS draws text
    /// (`tests/coretext/blend.txt`).
    Encoded,
}

/// The space for a person, to end a sentence that says how a renderer
/// blends: `linear light`, or `sRGB-encoded values, as macOS blends`.
/// Whatever prints a blending prints this, so that one added here needs
/// no other crate changed.
impl fmt::Display for Blending {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Linear => "linear light",
            Self::Encoded => "sRGB-encoded values, as macOS blends",
        })
    }
}

/// What a renderer of this crate is told once, when it is made.
///
/// The default draws text in linear light, its outlines as they are
/// ([`Weight::LINEAR`]). Which weight a program draws with is the
/// program's choice, made where it wires the renderer: nothing in this
/// crate asks which system it runs on.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Settings {
    /// How glyphs are antialiased.
    pub antialiasing: Antialiasing,
    /// Whether glyph outlines are fitted to the pixel grid.
    pub hinting: bool,
    /// How many bytes the pages of the glyph atlas may come to. Glyphs in
    /// use are kept past it (the module `glyphs`, "The bound").
    pub atlas_budget: u64,
    /// How heavy text is drawn.
    pub weight: Weight,
    /// The space every quad is blended in: linear light, or the
    /// sRGB-encoded values, as macOS blends ([`Blending`]). A renderer on
    /// a window whose surface cannot blend in the space asked for says
    /// which it blends in ([`WgpuRenderer::blending`]).
    pub blending: Blending,
    /// The present mode and the frame latency a run asks for in place of
    /// the decision's, each on its own, to measure another
    /// ([`present::choose`]); a half not asked for, as in the default
    /// ([`Asked::NOTHING`]), is the decision's. Only a renderer on a window
    /// presents.
    pub presentation: Asked,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            antialiasing: Antialiasing::Auto,
            hinting: true,
            atlas_budget: DEFAULT_ATLAS_BUDGET,
            weight: Weight::LINEAR,
            blending: Blending::Linear,
            presentation: Asked::NOTHING,
        }
    }
}

impl Settings {
    /// The default settings, with text drawn as Core Text draws it: its
    /// weight ([`Weight::CORE_TEXT`]) and the hinting fitted with it,
    /// which is off: the fit came nearest Core Text's drawing with
    /// outlines not fitted to the pixel grid. Glyphs are plain masks at
    /// every scale ([`Antialiasing::Grayscale`]): macOS draws no subpixel
    /// text.
    pub fn core_text() -> Self {
        Self {
            antialiasing: Antialiasing::Grayscale,
            hinting: false,
            weight: Weight::CORE_TEXT,
            ..Self::default()
        }
    }
}

/// How heavy text is drawn: what is added to a glyph's coverage beyond
/// its outline, on the CPU and the GPU alike.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Weight {
    /// How much the coverage of dark text on a light ground is raised,
    /// from 0 (none) to 1; past 1 the adjustment is no longer a coverage
    /// (the module `blend`).
    pub contrast: f32,
    /// How many pixels thicker each stem is drawn than its outline, as a
    /// stroke laid around it; 0 dilates nothing.
    pub dilation: f32,
}

impl Weight {
    /// Linear light, the outline as it is: what every platform gets unless
    /// its program says otherwise.
    pub const LINEAR: Weight = Weight {
        contrast: blend::CONTRAST,
        dilation: 0.0,
    };

    /// Core Text's weight, with hinting off ([`Settings::core_text`]):
    /// fitted to Core Text's drawing of a sentence of the fixture font
    /// Noto Sans Mono at 28 pixels, black on white
    /// (`tests/coretext/sentence.png`).
    ///
    /// Drawn with it, the sentence has 1910 pixels darker than mid-grey
    /// against Core Text's 1891 (1.010 of them) and ink of 499078
    /// against 503470 (0.991); the default draws 0.699 and 0.721 of
    /// them. Of the amounts the fit swept, contrast and dilation each in
    /// steps of 0.1 and hinting on and off, it is the nearest, and the
    /// tests in `weight_tests` hold it to that and to within a tenth of
    /// each count.
    ///
    /// The dilation is a number of pixels whatever the size, fitted at
    /// one size: what it comes to at other sizes is not measured.
    pub const CORE_TEXT: Weight = Weight {
        contrast: 0.1,
        dilation: 0.8,
    };
}

impl Default for Weight {
    fn default() -> Self {
        Self::LINEAR
    }
}

/// The kind of mask a draw asked its glyph images in: what was done, as
/// the renderer that did it says ([`HeadlessRenderer::masks`],
/// [`WgpuRenderer::masks`]).
///
/// It is the answer for one draw of what [`Antialiasing`] leaves to the
/// display and to the device: a setting of [`Antialiasing::Auto`] comes to
/// one kind on a target at one scale and to the other at another, and a
/// device that cannot blend by a coverage for each channel is given plain
/// masks whatever the setting. A glyph whose font has an image of its own
/// (a colour glyph) is drawn from that image under either.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Masks {
    /// One coverage a pixel.
    Plain,
    /// A coverage for each colour stripe, in this order.
    Subpixel(SubpixelOrder),
}

/// The kind for a person, to end a sentence that says how glyphs were
/// drawn: `plain masks`, or `subpixel masks, red first`. Whatever prints
/// a kind prints this, so that a kind added here needs no other crate
/// changed.
impl fmt::Display for Masks {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Plain => "plain masks",
            Self::Subpixel(SubpixelOrder::Rgb) => "subpixel masks, red first",
            Self::Subpixel(SubpixelOrder::Bgr) => "subpixel masks, blue first",
        })
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
