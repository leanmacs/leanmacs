//! The wgpu device: the painter's quads drawn on a GPU, to an offscreen
//! target or to a window's surface.
//!
//! It draws what the CPU compositor draws, from the same list of quads
//! and the same bytes of the atlas: a texture for each page, one pipeline
//! of instanced quads in drawing order, and one shader (`shader.wgsl`)
//! that states `blend`'s arithmetic. The quads of a draw are one instance
//! buffer; they are drawn in runs that read one page each, a fill joining
//! whichever run it falls in.
//!
//! # Blending by a coverage for each channel
//!
//! A subpixel mask covers red, green and blue each by its own amount,
//! which a GPU blends with two sources: the colour and the coverages
//! (`DUAL_SOURCE_BLENDING`). A device with the feature is asked for it,
//! and [`Device::per_channel`] says so. One without it is given another
//! fragment output and another blend, one coverage for the three, and the
//! painter is told to ask for plain masks.
//!
//! # The blending
//!
//! A device blends in one space for the whole frame
//! (`Settings::blending`), since a render pass has one attachment format.
//! In linear light it draws through an sRGB format, which the GPU makes
//! linear before it blends and encodes after. In sRGB-encoded values, as
//! macOS blends, it draws through the same bytes in a format that is not
//! sRGB ([`own_format`] for a target of its own, `surface::choose_format`
//! for a window's), so that the fixed-function blend works on the stored
//! values / 255 as they are, and the shader is told, by the globals'
//! fourth float, to take the colour as given in place of making it linear.
//! The CPU and the GPU then both compute in unit values and round once.
//! [`Device::blending`] says which space a device blends in: a window's
//! surface that offers no format to blend encoded through blends in
//! linear light.
//!
//! # Every draw is checked
//!
//! Each draw, and the making of the pipeline, is inside one of wgpu's
//! error scopes: a shader that does not compile, a vertex layout that
//! does not match it, a buffer or a texture of the wrong size is an error
//! the draw gives back, never a silent wrong picture. On wgpu's no-op
//! back end that is all a draw is, which is what the gate runs: the
//! calls are validated and nothing is drawn.
//!
//! What reached the GPU in a draw it refused is not known, so a page is
//! taken as sent only by a draw wgpu accepted: what a refused draw sent,
//! the next sends again.
//!
//! # What is drawn on
//!
//! A device draws on one of two things, decided when it is made.
//!
//! One made with [`Device::new`] draws on a texture of its own, the size
//! of the last draw's target, and [`Device::read_back`] copies it out.
//!
//! One made with [`Device::on_surface`] draws on a window's surface and
//! presents it. Its adapter is one that can present to the surface. The
//! surface is configured at the size of a draw when it is not, or is of
//! another size, with the format, the present mode and the frame latency
//! chosen when the device was made (`surface`, `present`). Each draw asks
//! the surface for its next texture, does what `surface::next` says of
//! the answer, draws through the same pipeline, and presents. A draw the
//! surface gave no texture for is not presented, and says why. The
//! picture of a draw is copied out of the surface's texture, before it is
//! presented, only when that is asked for ([`Device::keep_picture`]): it
//! is a copy of every pixel for every frame, which a check wants and the
//! editor does not.
//!
//! None of that is decided here. `surface::State` holds what is known of
//! the surface and decides all of it: what the surface is configured with
//! and when, what is done with each answer, and whether and in what order
//! of bytes its picture is read. It makes its calls through a port
//! (`surface::Calls`), and this module's part is that port over wgpu
//! (`OnSurface`), one call of wgpu's for each, and the copy of a texture
//! out of the GPU.
//!
//! The no-op back end presents to no surface, so wgpu's calls run in no
//! test of the gate: what decides them is pinned in `surface`, on a
//! surface that is a script, and the calls themselves are run on a real
//! window, on demand.
//!
//! # What is not done
//!
//! A page's texture is sent again whole when an image has been written to
//! the page since it was last sent. That is one copy of at most a page
//! for each page that changed in a draw, and none for a draw that
//! rasterised nothing; sending only the rectangle that changed is not
//! done.
//!
//! The device knows what a page holds by the page's number and by how
//! many images have been written to it. That is so of the pages of one
//! atlas, which never uses a number again
//! ([`Slot::page`](crate::atlas::Slot::page)), and the glyph cache keeps
//! one atlas across the generations of the fonts. A texture whose format
//! is not its page's kind's is not written to: one is made in its place.

use std::collections::HashMap;
use std::fmt;

use editor_layout::face::Color;

use crate::atlas::{Atlas, PageView};
use crate::blend::to_linear;
use crate::glyphs::Kind;
use crate::layer::{Layer, LayerReading, metal_format};
use crate::present::{Asked, Offered};
use crate::quads::{Quad, QuadKind};
use crate::surface::{Answer, Calls, State};
use crate::{Blending, Image, Weight};

/// The body of the shader, shared by both blends.
const SHADER: &str = include_str!("shader.wgsl");

/// The fragment stage when the device blends by a coverage for each
/// channel: the colour times its coverages, and the coverages.
const PER_CHANNEL: &str = "
enable dual_source_blending;

struct Out {
    @location(0) @blend_src(0) color: vec4<f32>,
    @location(0) @blend_src(1) coverage: vec4<f32>,
}

@fragment
fn fragment(in: Varying) -> Out {
    let over = laid(in);
    return Out(vec4<f32>(over.rgb * over.coverage.rgb, over.coverage.a), over.coverage);
}
";

/// The fragment stage when it cannot: one coverage for the three
/// channels, the alpha's.
const ONE_COVERAGE: &str = "
@fragment
fn fragment(in: Varying) -> @location(0) vec4<f32> {
    let over = laid(in);
    return vec4<f32>(over.rgb * over.coverage.a, over.coverage.a);
}
";

/// The format of a target of the device's own that blends in linear
/// light: sRGB values, which the GPU makes linear before it blends and
/// encodes after. One that blends in encoded values draws on the same
/// bytes in this format's non-sRGB form ([`own_format`]). A window's
/// surface has the format chosen from what it offers
/// (`surface::choose_format`).
const OWN_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8UnormSrgb;

/// The format of a target of the device's own that blends in `blending`'s
/// space: [`OWN_FORMAT`], or its non-sRGB form, through which the GPU's
/// fixed-function blend works on the sRGB values themselves.
fn own_format(blending: Blending) -> wgpu::TextureFormat {
    match blending {
        Blending::Linear => OWN_FORMAT,
        Blending::Encoded => OWN_FORMAT.remove_srgb_suffix(),
    }
}

/// How many bytes one quad takes in the instance buffer: its box, its
/// source and its colour.
const INSTANCE_BYTES: u64 = 36;

/// Why there is no device: no adapter, or one that could not be used.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Unavailable(pub String);

impl fmt::Display for Unavailable {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// A page's texture, as the device holds it.
struct PageTexture {
    /// The texture.
    texture: wgpu::Texture,
    /// What binds it for a run of quads.
    bind: wgpu::BindGroup,
    /// How many images had been written to the page when it was last sent
    /// in a draw wgpu accepted.
    sent: u64,
}

/// The target: a texture the size of the last draw.
struct TargetTexture {
    /// The texture.
    texture: wgpu::Texture,
    /// How far across it is.
    width: u32,
    /// How far down.
    height: u32,
}

/// A window's surface, as the device holds it.
struct Window {
    /// The surface.
    surface: wgpu::Surface<'static>,
    /// What is known of it, and every decision about it: how it is
    /// configured and when, what is done with its answers, and how its
    /// picture is taken.
    state: State,
    /// The picture of the last draw, or why there is none; `None` when no
    /// picture is kept or nothing was drawn.
    picture: Option<Result<Image, String>>,
}

impl Window {
    /// The surface, with what `surface::State` decides from what it offers
    /// `adapter`, what the run `asked` for and the space it is to blend in.
    /// The error says why nothing can be drawn on it.
    fn new(
        surface: wgpu::Surface<'static>,
        adapter: &wgpu::Adapter,
        asked: Asked,
        blending: Blending,
    ) -> Result<Self, String> {
        let state = State::new(&surface.get_capabilities(adapter), asked, blending)?;
        Ok(Self {
            surface,
            state,
            picture: None,
        })
    }

    /// The surface's next texture, `width` by `height`, as
    /// `surface::State::acquire` gets it with wgpu's calls. The error says
    /// why there is no texture, and the draw is then not presented.
    fn acquire(
        &mut self,
        device: &wgpu::Device,
        width: u32,
        height: u32,
    ) -> Result<wgpu::SurfaceTexture, String> {
        let mut calls = OnSurface {
            surface: &self.surface,
            device,
        };
        self.state.acquire(&mut calls, width, height)
    }
}

/// The calls `surface::State` makes on a surface, as wgpu's: each is one
/// call of wgpu's, and nothing is decided here.
struct OnSurface<'a> {
    /// The surface.
    surface: &'a wgpu::Surface<'static>,
    /// The device it is configured on.
    device: &'a wgpu::Device,
}

impl Calls for OnSurface<'_> {
    type Texture = wgpu::SurfaceTexture;

    fn configure(&mut self, config: &wgpu::SurfaceConfiguration) {
        self.surface.configure(self.device, config);
    }

    fn next_texture(&mut self) -> (Answer, Option<wgpu::SurfaceTexture>) {
        match self.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(texture) => (Answer::Success, Some(texture)),
            wgpu::CurrentSurfaceTexture::Suboptimal(texture) => (Answer::Suboptimal, Some(texture)),
            wgpu::CurrentSurfaceTexture::Timeout => (Answer::Timeout, None),
            wgpu::CurrentSurfaceTexture::Occluded => (Answer::Occluded, None),
            wgpu::CurrentSurfaceTexture::Outdated => (Answer::Outdated, None),
            wgpu::CurrentSurfaceTexture::Lost => (Answer::Lost, None),
            wgpu::CurrentSurfaceTexture::Validation => (Answer::Validation, None),
        }
    }
}

/// The device.
pub struct Device {
    /// wgpu's device.
    device: wgpu::Device,
    /// Its queue.
    queue: wgpu::Queue,
    /// The adapter's name and back end, for a person.
    adapter: String,
    /// Whether it blends by a coverage for each channel.
    per_channel: bool,
    /// The space it blends in: what the format it draws through gives,
    /// and what the shader is told.
    blending: Blending,
    /// The format of what the pipeline draws on.
    format: wgpu::TextureFormat,
    /// The one pipeline.
    pipeline: wgpu::RenderPipeline,
    /// The layout of a page's bind group.
    page_layout: wgpu::BindGroupLayout,
    /// The target's size, the contrast and the blending, for the shader.
    globals: wgpu::Buffer,
    /// What binds `globals`.
    globals_bind: wgpu::BindGroup,
    /// What a run of fills binds where a page goes: a texture of one
    /// pixel.
    blank: wgpu::BindGroup,
    /// The textures of the atlas's pages, by page number.
    pages: HashMap<u32, PageTexture>,
    /// The quads of a draw, and how many bytes it holds.
    instances: Option<(wgpu::Buffer, u64)>,
    /// The target of the device's own, when it draws on no window.
    target: Option<TargetTexture>,
    /// The window's surface, when it draws on one.
    window: Option<Window>,
    /// How much the coverage of dark text is raised, for the shader: the
    /// renderer's `Weight::contrast`, which it sets once it has the
    /// device, and the default weight's until it does.
    pub contrast: f32,
}

/// The bytes of the shader's globals: the target's size, `width` by
/// `height`, then `contrast`, then whether `blending` is in encoded values
/// (1) or in linear light (0), each a float in the machine's byte order.
fn globals(width: u32, height: u32, contrast: f32, blending: Blending) -> [u8; 16] {
    let encoded = match blending {
        Blending::Linear => 0.0,
        Blending::Encoded => 1.0,
    };
    let mut bytes = [0; 16];
    for (at, value) in [width as f32, height as f32, contrast, encoded]
        .into_iter()
        .enumerate()
    {
        bytes[at * 4..at * 4 + 4].copy_from_slice(&value.to_ne_bytes());
    }
    bytes
}

/// What a target that blends in `blending`'s space is cleared to for the
/// frame's ground `ground`, at full opacity whatever its alpha: the
/// ground's bytes over 255 where the target holds the encoded values as
/// they are, and each made linear where the target is drawn through an
/// sRGB view, since the GPU encodes a clear made on one as it stores it.
fn clear_color(ground: Color, blending: Blending) -> wgpu::Color {
    let [red, green, blue, _] = ground.0.to_be_bytes();
    let channel = |byte: u8| match blending {
        Blending::Encoded => f64::from(byte) / 255.0,
        Blending::Linear => f64::from(to_linear(byte)),
    };
    wgpu::Color {
        r: channel(red),
        g: channel(green),
        b: channel(blue),
        a: 1.0,
    }
}

/// What `surface`'s Metal layer reads now: the layer wgpu-hal draws on
/// (`render_layer`), reached through wgpu's re-export of wgpu-hal. Every
/// read is a method of the layer or a field of what it returns, whose type
/// is never named, so this crate depends on no binding of Core Animation
/// or Core Graphics (`deny.toml`). The colour space is read as present or
/// not.
#[cfg(target_os = "macos")]
fn read_layer(surface: &wgpu::Surface<'_>) -> Option<LayerReading> {
    // SAFETY: the layer is only read, on the thread that holds the
    // renderer, under wgpu-hal's own lock of it, and nothing of it is kept
    // past this call: the surface is not destroyed, and wgpu-hal's state is
    // left as it was.
    let hal = unsafe { surface.as_hal::<wgpu::hal::api::Metal>() }?;
    let layer = hal.render_layer().lock();
    let bounds = layer.bounds();
    let drawable = layer.drawableSize();
    Some(LayerReading {
        bounds: (bounds.size.width, bounds.size.height),
        contents_scale: layer.contentsScale(),
        drawable: (drawable.width, drawable.height),
        opaque: layer.isOpaque(),
        colorspace: layer.colorspace().is_some(),
        format: layer.pixelFormat().0 as u64,
        gravity: layer.contentsGravity().to_string(),
    })
}

/// No surface off macOS has a Metal layer.
#[cfg(not(target_os = "macos"))]
fn read_layer(_: &wgpu::Surface<'_>) -> Option<LayerReading> {
    None
}

/// Waits for `future`, which wgpu resolves without an executor.
fn wait<T>(future: impl Future<Output = T>) -> T {
    pollster::block_on(future)
}

impl Device {
    /// A device on an adapter of `instance` that draws on a target of its
    /// own, blending in `blending`'s space, and by a coverage for each
    /// channel when the adapter can and `allow_per_channel` says it may.
    pub fn new(
        instance: &wgpu::Instance,
        allow_per_channel: bool,
        blending: Blending,
    ) -> Result<Self, Unavailable> {
        Self::build(instance, None, allow_per_channel, blending)
    }

    /// A device on an adapter of `instance` that can present to `surface`,
    /// and draws on it, presenting as `asked` says of each half the run
    /// asked for (`present::choose`), and blending in `blending`'s space
    /// where the surface offers a format to, in linear light where it does
    /// not (`surface::choose_format`; [`Device::blending`] says which). It
    /// is refused, with the reason, when no adapter can, or when the
    /// surface offers nothing to configure it with.
    pub fn on_surface(
        instance: &wgpu::Instance,
        surface: wgpu::Surface<'static>,
        asked: Asked,
        allow_per_channel: bool,
        blending: Blending,
    ) -> Result<Self, Unavailable> {
        Self::build(
            instance,
            Some((surface, asked)),
            allow_per_channel,
            blending,
        )
    }

    /// A device on an adapter of `instance`, drawing on `surface` when
    /// there is one and on a target of its own otherwise, blending in
    /// `blending`'s space.
    fn build(
        instance: &wgpu::Instance,
        surface: Option<(wgpu::Surface<'static>, Asked)>,
        allow_per_channel: bool,
        blending: Blending,
    ) -> Result<Self, Unavailable> {
        let adapter = wait(instance.request_adapter(&wgpu::RequestAdapterOptions {
            compatible_surface: surface.as_ref().map(|(surface, _)| surface),
            ..Default::default()
        }))
        .map_err(|error| Unavailable(format!("no adapter: {error}")))?;
        let info = adapter.get_info();
        let window = surface
            .map(|(surface, asked)| Window::new(surface, &adapter, asked, blending))
            .transpose()
            .map_err(|reason| Unavailable(format!("{reason} ({})", info.name)))?;
        let format = window
            .as_ref()
            .map_or(own_format(blending), |window| window.state.target());
        // What the surface can blend in, when there is one.
        let blending = window
            .as_ref()
            .map_or(blending, |window| window.state.blending());
        let dual = wgpu::Features::DUAL_SOURCE_BLENDING;
        let per_channel = allow_per_channel && adapter.features().contains(dual);
        let (device, queue) = wait(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("editor-render-wgpu"),
            required_features: if per_channel {
                dual
            } else {
                wgpu::Features::empty()
            },
            ..Default::default()
        }))
        .map_err(|error| Unavailable(format!("no device on {}: {error}", info.name)))?;

        let scope = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let fragment = if per_channel {
            PER_CHANNEL
        } else {
            ONE_COVERAGE
        };
        // The `enable` directive of the per-channel stage must come
        // before any declaration.
        let source = format!("{fragment}\n{SHADER}");
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("quads"),
            source: wgpu::ShaderSource::Wgsl(source.into()),
        });
        let globals_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("globals"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });
        let page_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("page"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: false },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            }],
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("quads"),
            bind_group_layouts: &[Some(&globals_layout), Some(&page_layout)],
            immediate_size: 0,
        });
        let one = wgpu::BlendFactor::One;
        let blend = if per_channel {
            wgpu::BlendState {
                color: wgpu::BlendComponent {
                    src_factor: one,
                    dst_factor: wgpu::BlendFactor::OneMinusSrc1,
                    operation: wgpu::BlendOperation::Add,
                },
                alpha: wgpu::BlendComponent {
                    src_factor: one,
                    dst_factor: wgpu::BlendFactor::OneMinusSrc1Alpha,
                    operation: wgpu::BlendOperation::Add,
                },
            }
        } else {
            wgpu::BlendState::PREMULTIPLIED_ALPHA_BLENDING
        };
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("quads"),
            layout: Some(&layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vertex"),
                compilation_options: Default::default(),
                buffers: &[Some(wgpu::VertexBufferLayout {
                    array_stride: INSTANCE_BYTES,
                    step_mode: wgpu::VertexStepMode::Instance,
                    attributes: &wgpu::vertex_attr_array![
                        0 => Sint32x4,
                        1 => Uint32x4,
                        2 => Unorm8x4,
                    ],
                })],
            },
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleStrip,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: Default::default(),
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fragment"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: Some(blend),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            multiview_mask: None,
            cache: None,
        });
        let globals = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("globals"),
            size: 16,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let globals_bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("globals"),
            layout: &globals_layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: globals.as_entire_binding(),
            }],
        });
        let blank = page_texture(&device, &page_layout, Kind::Mask, 1).bind;
        if let Some(error) = wait(scope.pop()) {
            return Err(Unavailable(format!(
                "the pipeline is refused on {}: {error}",
                info.name
            )));
        }
        Ok(Self {
            device,
            queue,
            adapter: format!("{} ({:?})", info.name, info.backend),
            per_channel,
            blending,
            format,
            pipeline,
            page_layout,
            globals,
            globals_bind,
            blank,
            pages: HashMap::new(),
            instances: None,
            target: None,
            window,
            contrast: Weight::LINEAR.contrast,
        })
    }

    /// Keeps the picture of each draw on a window from here on, for
    /// [`Device::read_back`]: the surface's texture is copied out before
    /// it is presented. Nothing changes for a device that draws on a
    /// target of its own, which is always read back.
    ///
    /// It answers whether there is a texture to copy from: `false` for a
    /// window whose surface does not let its texture be copied from
    /// (`surface::State::keep_picture`), which then has no picture.
    pub fn keep_picture(&mut self) -> bool {
        self.window
            .as_mut()
            .is_none_or(|window| window.state.keep_picture())
    }

    /// Whether the window's surface, when it was last asked for a texture,
    /// gave none because the window is occluded
    /// (`surface::State::hidden`). A device that draws on a target of its
    /// own is never hidden.
    pub fn hidden(&self) -> bool {
        self.window
            .as_ref()
            .is_some_and(|window| window.state.hidden())
    }

    /// What the window's surface offered and was configured with
    /// (`surface::State::presentation`); `None` for a device that draws on
    /// a target of its own, and before the surface is first configured.
    pub fn presentation(&self) -> Option<Offered> {
        self.window.as_ref()?.state.presentation()
    }

    /// The window's Metal layer as read now, with the format its surface
    /// is configured with (`layer`); `None` off macOS, for a device that
    /// draws on a target of its own, and for a surface whose format has
    /// no Metal number of this crate's.
    pub fn layer(&self) -> Option<Layer> {
        let window = self.window.as_ref()?;
        let configured = metal_format(window.state.configured_format())?;
        let reading = read_layer(&window.surface)?;
        Some(Layer {
            reading,
            configured,
        })
    }

    /// Whether the device blends by a coverage for each channel, so that
    /// subpixel masks may be drawn on it.
    pub fn per_channel(&self) -> bool {
        self.per_channel
    }

    /// The space the device blends in.
    pub fn blending(&self) -> Blending {
        self.blending
    }

    /// The adapter's name and back end, for a person.
    pub fn adapter(&self) -> &str {
        &self.adapter
    }

    /// Draws `quads`, in order, over a target `width` by `height` cleared
    /// first to `ground` at full opacity (the frame's ground,
    /// [`clear_color`]), reading glyph quads from `atlas`: on the window's
    /// surface, which is then presented, or on the device's own target.
    /// The error is wgpu's, when it refuses a call of the draw, or says
    /// that the window's surface gave no texture to draw on.
    pub fn draw(
        &mut self,
        quads: &[Quad],
        atlas: &Atlas,
        width: u32,
        height: u32,
        ground: Color,
    ) -> Result<(), String> {
        let scope = self.device.push_error_scope(wgpu::ErrorFilter::Validation);
        let sent = self.send_pages(atlas);
        let clear = clear_color(ground, self.blending);
        let drawn = self.draw_on(quads, width.max(1), height.max(1), clear);
        if let Some(error) = wait(scope.pop()) {
            return Err(error.to_string());
        }
        drawn?;
        // The draw was accepted: what it sent is what the textures hold.
        for (number, written) in sent {
            if let Some(texture) = self.pages.get_mut(&number) {
                texture.sent = written;
            }
        }
        Ok(())
    }

    /// What is drawn on, `width` by `height`: the window's next texture,
    /// seen through the format the pipeline draws in, or the device's own
    /// target, made anew when its size is another. The error says why the
    /// window's surface gave no texture.
    fn canvas(
        &mut self,
        width: u32,
        height: u32,
    ) -> Result<(wgpu::TextureView, Option<wgpu::SurfaceTexture>), String> {
        if let Some(window) = &mut self.window {
            let texture = window.acquire(&self.device, width, height)?;
            let view = texture.texture.create_view(&wgpu::TextureViewDescriptor {
                format: Some(self.format),
                ..Default::default()
            });
            return Ok((view, Some(texture)));
        }
        let target = match self.target.take() {
            Some(target) if (target.width, target.height) == (width, height) => target,
            _ => TargetTexture {
                texture: self.device.create_texture(&wgpu::TextureDescriptor {
                    label: Some("target"),
                    size: extent(width, height),
                    mip_level_count: 1,
                    sample_count: 1,
                    dimension: wgpu::TextureDimension::D2,
                    format: self.format,
                    usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
                    view_formats: &[],
                }),
                width,
                height,
            },
        };
        let view = target.texture.create_view(&Default::default());
        self.target = Some(target);
        Ok((view, None))
    }

    /// The calls of one draw, on a target `width` by `height`, neither of
    /// them 0, cleared to `clear`. The error says why the window's surface
    /// gave no texture.
    fn draw_on(
        &mut self,
        quads: &[Quad],
        width: u32,
        height: u32,
        clear: wgpu::Color,
    ) -> Result<(), String> {
        let (view, presented) = self.canvas(width, height)?;
        let written = globals(width, height, self.contrast, self.blending);
        self.queue.write_buffer(&self.globals, 0, &written);

        let (bytes, runs) = instances(quads, |page| self.pages.contains_key(&page));
        let needed = bytes.len() as u64;
        if !self
            .instances
            .as_ref()
            .is_some_and(|(_, held)| *held >= needed)
        {
            // Room for twice what is needed, so a frame a little larger
            // than the last makes no new buffer.
            let size = (needed * 2).max(INSTANCE_BYTES * 256);
            let buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("quads"),
                size,
                usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
            self.instances = Some((buffer, size));
        }
        let mut encoder = self.device.create_command_encoder(&Default::default());
        if let Some((buffer, _)) = &self.instances {
            self.queue.write_buffer(buffer, 0, &bytes);
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("frame"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(clear),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            pass.set_pipeline(&self.pipeline);
            pass.set_bind_group(0, &self.globals_bind, &[]);
            pass.set_vertex_buffer(0, buffer.slice(..));
            for run in &runs {
                let bind = run
                    .page
                    .and_then(|page| self.pages.get(&page))
                    .map_or(&self.blank, |page| &page.bind);
                pass.set_bind_group(1, bind, &[]);
                pass.draw(0..4, run.first..run.end);
            }
        }
        self.queue.submit([encoder.finish()]);
        if let Some(texture) = presented {
            // The picture is taken while the texture is still this
            // device's: presented, it is the window system's.
            let picture = self.picture_of(&texture.texture, width, height);
            if let Some(window) = &mut self.window {
                window.picture = picture;
            }
            self.queue.present(texture);
        }
        Ok(())
    }

    /// The picture of a window's `texture`, `width` by `height`, when the
    /// window's pictures are kept: the texture copied out and its pixels
    /// put in the order a picture has them, as `surface::State::picture`
    /// says. The error is that function's, where there is no picture to
    /// take, or wgpu's, where it refuses the copy.
    fn picture_of(
        &self,
        texture: &wgpu::Texture,
        width: u32,
        height: u32,
    ) -> Option<Result<Image, String>> {
        let order = self.window.as_ref()?.state.picture()?;
        Some(order.and_then(|order| {
            self.copy_out(texture, width, height)
                .map(|image| order.rgba(image))
        }))
    }

    /// Makes the textures hold what `atlas`'s pages hold: one for each
    /// page, of the page's kind, sent again when the page was written to
    /// since it was sent, and none for a page that is gone. It gives the
    /// number of each page it sent with how many images had been written
    /// to it: the draw takes them as sent once wgpu has accepted it.
    fn send_pages(&mut self, atlas: &Atlas) -> Vec<(u32, u64)> {
        let mut held: Vec<u32> = Vec::new();
        let mut sent: Vec<(u32, u64)> = Vec::new();
        for page in atlas.pages() {
            held.push(page.number);
            match self.pages.get(&page.number) {
                // A texture of another kind cannot hold the page's bytes:
                // one is made in its place.
                Some(texture) if texture.texture.format() != format_of(page.kind) => {
                    self.pages.remove(&page.number);
                }
                Some(texture) if texture.sent == page.written => continue,
                _ => {}
            }
            let texture = self.pages.entry(page.number).or_insert_with(|| {
                page_texture(&self.device, &self.page_layout, page.kind, page.size)
            });
            send(&self.queue, &texture.texture, &page);
            sent.push((page.number, page.written));
        }
        self.pages.retain(|number, _| held.contains(number));
        sent
    }

    /// The target as it was last drawn, read back from the GPU; a picture
    /// of no size before a first draw. For a device that draws on a
    /// window, the picture kept of the last draw, and a picture of no size
    /// when none is kept ([`Device::keep_picture`]).
    pub fn read_back(&mut self) -> Result<Image, String> {
        let nothing = Image {
            width: 0,
            height: 0,
            rgba: Vec::new(),
        };
        if let Some(window) = &self.window {
            return window.picture.clone().unwrap_or(Ok(nothing));
        }
        let Some(target) = &self.target else {
            return Ok(nothing);
        };
        self.copy_out(&target.texture, target.width, target.height)
    }

    /// The pixels of `texture`, `width` by `height` and four bytes a
    /// pixel, copied out of the GPU in the order the texture holds them.
    fn copy_out(&self, texture: &wgpu::Texture, width: u32, height: u32) -> Result<Image, String> {
        let scope = self.device.push_error_scope(wgpu::ErrorFilter::Validation);
        // A row of the copy is padded to a multiple of 256 bytes.
        let row = (width * 4).next_multiple_of(wgpu::COPY_BYTES_PER_ROW_ALIGNMENT);
        let buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("read back"),
            size: u64::from(row) * u64::from(height),
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        let mut encoder = self.device.create_command_encoder(&Default::default());
        encoder.copy_texture_to_buffer(
            texture.as_image_copy(),
            wgpu::TexelCopyBufferInfo {
                buffer: &buffer,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(row),
                    rows_per_image: Some(height),
                },
            },
            extent(width, height),
        );
        self.queue.submit([encoder.finish()]);
        buffer.map_async(wgpu::MapMode::Read, .., |_| {});
        self.device
            .poll(wgpu::PollType::wait_indefinitely())
            .map_err(|error| error.to_string())?;
        if let Some(error) = wait(scope.pop()) {
            return Err(error.to_string());
        }
        let mapped = buffer
            .get_mapped_range(..)
            .map_err(|error| error.to_string())?;
        let rgba = mapped
            .chunks(row as usize)
            .flat_map(|line| line[..width as usize * 4].iter().copied())
            .collect();
        Ok(Image {
            width,
            height,
            rgba,
        })
    }
}

/// A size of one layer, `width` by `height`.
fn extent(width: u32, height: u32) -> wgpu::Extent3d {
    wgpu::Extent3d {
        width,
        height,
        depth_or_array_layers: 1,
    }
}

/// The format of the texture of a page of `kind`. The bytes as they are:
/// a coverage is no colour, and a colour image's are made linear by the
/// shader.
fn format_of(kind: Kind) -> wgpu::TextureFormat {
    match kind {
        Kind::Mask => wgpu::TextureFormat::R8Unorm,
        Kind::Subpixel | Kind::Color => wgpu::TextureFormat::Rgba8Unorm,
    }
}

/// A texture for a page of `kind`, `size` pixels across and down, with
/// what binds it; nothing has been sent to it.
fn page_texture(
    device: &wgpu::Device,
    layout: &wgpu::BindGroupLayout,
    kind: Kind,
    size: u32,
) -> PageTexture {
    let texture = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("page"),
        size: extent(size, size),
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: format_of(kind),
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });
    let bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("page"),
        layout,
        entries: &[wgpu::BindGroupEntry {
            binding: 0,
            resource: wgpu::BindingResource::TextureView(&texture.create_view(&Default::default())),
        }],
    });
    PageTexture {
        texture,
        bind,
        sent: u64::MAX,
    }
}

/// Sends the pixels of `page` to `texture`, whole.
fn send(queue: &wgpu::Queue, texture: &wgpu::Texture, page: &PageView<'_>) {
    queue.write_texture(
        texture.as_image_copy(),
        page.pixels,
        wgpu::TexelCopyBufferLayout {
            offset: 0,
            bytes_per_row: Some(page.size * page.kind.bytes()),
            rows_per_image: Some(page.size),
        },
        extent(page.size, page.size),
    );
}

/// A run of quads that read one page: the instances from `first` up to
/// `end`.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Run {
    /// The page they read; `None` when they are all fills.
    page: Option<u32>,
    /// The first instance.
    first: u32,
    /// One past the last.
    end: u32,
}

/// The bytes of the instance buffer for `quads`, and the runs they are
/// drawn in. A quad that reads a page the device has no texture for
/// (`held` says which it has) is left out: it would read whatever was
/// bound.
fn instances(quads: &[Quad], held: impl Fn(u32) -> bool) -> (Vec<u8>, Vec<Run>) {
    let mut bytes = Vec::with_capacity(quads.len() * INSTANCE_BYTES as usize);
    let mut runs: Vec<Run> = Vec::new();
    let mut count = 0;
    for quad in quads {
        let (kind, page) = match quad.kind {
            QuadKind::Fill => (0_u32, None),
            QuadKind::Mask => (1, Some(quad.page)),
            QuadKind::Subpixel => (2, Some(quad.page)),
            QuadKind::Color => (3, Some(quad.page)),
        };
        if page.is_some_and(|page| !held(page)) {
            continue;
        }
        let (across, down) = (quad.width as i32, quad.height as i32);
        for value in [quad.x, quad.y, across, down] {
            bytes.extend_from_slice(&value.to_ne_bytes());
        }
        for value in [quad.u, quad.v, kind, 0] {
            bytes.extend_from_slice(&value.to_ne_bytes());
        }
        bytes.extend_from_slice(&quad.color.0.to_be_bytes());
        // A fill joins the run it falls in; a quad that reads another
        // page than the run's begins a run.
        match runs.last_mut() {
            Some(run) if page.is_none() || run.page == page => run.end = count + 1,
            Some(run) if run.page.is_none() => {
                run.page = page;
                run.end = count + 1;
            }
            _ => runs.push(Run {
                page,
                first: count,
                end: count + 1,
            }),
        }
        count += 1;
    }
    (bytes, runs)
}

#[cfg(test)]
mod tests;
