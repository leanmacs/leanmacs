//! The wgpu device: the painter's quads drawn on a GPU, to an offscreen
//! target.
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
//! # Every draw is checked
//!
//! Each draw, and the making of the pipeline, is inside one of wgpu's
//! error scopes: a shader that does not compile, a vertex layout that
//! does not match it, a buffer or a texture of the wrong size is an error
//! the draw gives back, never a silent wrong picture. On wgpu's no-op
//! back end that is all a draw is, which is what the gate runs: the
//! calls are validated and nothing is drawn.
//!
//! # What is here and what is not
//!
//! The target is a texture this device makes, the size of the last draw's
//! target, and [`Device::read_back`] copies it out. There is no surface:
//! presenting to a window is the display pipeline's phase 6.
//!
//! A page's texture is sent again whole when an image has been written to
//! the page since it was last sent. That is one copy of at most a page
//! for each page that changed in a draw, and none for a draw that
//! rasterised nothing; sending only the rectangle that changed is not
//! done.

use std::collections::HashMap;
use std::fmt;

use crate::Image;
use crate::atlas::{Atlas, PageView};
use crate::blend::CONTRAST;
use crate::cpu::CLEAR;
use crate::glyphs::Kind;
use crate::quads::{Quad, QuadKind};

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

/// The format of the target: sRGB values, so that blending is in linear
/// light.
const TARGET_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8UnormSrgb;

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
    /// How many images had been written to the page when it was sent.
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
    /// The one pipeline.
    pipeline: wgpu::RenderPipeline,
    /// The layout of a page's bind group.
    page_layout: wgpu::BindGroupLayout,
    /// The target's size and the contrast, for the shader.
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
    /// The target.
    target: Option<TargetTexture>,
}

/// Waits for `future`, which wgpu resolves without an executor.
fn wait<T>(future: impl Future<Output = T>) -> T {
    pollster::block_on(future)
}

impl Device {
    /// A device on an adapter of `instance`, blending by a coverage for
    /// each channel when the adapter can and `allow_per_channel` says it
    /// may.
    pub fn new(instance: &wgpu::Instance, allow_per_channel: bool) -> Result<Self, Unavailable> {
        let adapter = wait(instance.request_adapter(&wgpu::RequestAdapterOptions::default()))
            .map_err(|error| Unavailable(format!("no adapter: {error}")))?;
        let info = adapter.get_info();
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
                    format: TARGET_FORMAT,
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
            pipeline,
            page_layout,
            globals,
            globals_bind,
            blank,
            pages: HashMap::new(),
            instances: None,
            target: None,
        })
    }

    /// Whether the device blends by a coverage for each channel, so that
    /// subpixel masks may be drawn on it.
    pub fn per_channel(&self) -> bool {
        self.per_channel
    }

    /// The adapter's name and back end, for a person.
    pub fn adapter(&self) -> &str {
        &self.adapter
    }

    /// Draws `quads`, in order, over a target `width` by `height` cleared
    /// first, reading glyph quads from `atlas`. The error is wgpu's, when
    /// it refuses a call of the draw.
    pub fn draw(
        &mut self,
        quads: &[Quad],
        atlas: &Atlas,
        width: u32,
        height: u32,
    ) -> Result<(), String> {
        let scope = self.device.push_error_scope(wgpu::ErrorFilter::Validation);
        self.send_pages(atlas);
        let (width, height) = (width.max(1), height.max(1));
        if !self
            .target
            .as_ref()
            .is_some_and(|target| (target.width, target.height) == (width, height))
        {
            self.target = Some(TargetTexture {
                texture: self.device.create_texture(&wgpu::TextureDescriptor {
                    label: Some("target"),
                    size: extent(width, height),
                    mip_level_count: 1,
                    sample_count: 1,
                    dimension: wgpu::TextureDimension::D2,
                    format: TARGET_FORMAT,
                    usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
                    view_formats: &[],
                }),
                width,
                height,
            });
        }
        let mut globals = Vec::with_capacity(16);
        for value in [width as f32, height as f32, CONTRAST, 0.0] {
            globals.extend_from_slice(&value.to_ne_bytes());
        }
        self.queue.write_buffer(&self.globals, 0, &globals);

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
        if let (Some(target), Some((buffer, _))) = (&self.target, &self.instances) {
            self.queue.write_buffer(buffer, 0, &bytes);
            let view = target.texture.create_view(&Default::default());
            let clear = wgpu::Color {
                r: f64::from(CLEAR[0]) / 255.0,
                g: f64::from(CLEAR[1]) / 255.0,
                b: f64::from(CLEAR[2]) / 255.0,
                a: f64::from(CLEAR[3]) / 255.0,
            };
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
        wait(scope.pop()).map_or(Ok(()), |error| Err(error.to_string()))
    }

    /// Makes the textures hold what `atlas`'s pages hold: one for each
    /// page, sent again when the page was written to since it was sent,
    /// and none for a page that is gone.
    fn send_pages(&mut self, atlas: &Atlas) {
        let mut held: Vec<u32> = Vec::new();
        for page in atlas.pages() {
            held.push(page.number);
            if self
                .pages
                .get(&page.number)
                .is_some_and(|texture| texture.sent == page.written)
            {
                continue;
            }
            let texture = self.pages.entry(page.number).or_insert_with(|| {
                page_texture(&self.device, &self.page_layout, page.kind, page.size)
            });
            texture.sent = page.written;
            send(&self.queue, &texture.texture, &page);
        }
        self.pages.retain(|number, _| held.contains(number));
    }

    /// The target as it was last drawn, read back from the GPU; a picture
    /// of no size before a first draw.
    pub fn read_back(&mut self) -> Result<Image, String> {
        let Some(target) = &self.target else {
            return Ok(Image {
                width: 0,
                height: 0,
                rgba: Vec::new(),
            });
        };
        let (width, height) = (target.width, target.height);
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
            target.texture.as_image_copy(),
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
        // The bytes as they are: a coverage is no colour, and a colour
        // image's are made linear by the shader.
        format: match kind {
            Kind::Mask => wgpu::TextureFormat::R8Unorm,
            Kind::Subpixel | Kind::Color => wgpu::TextureFormat::Rgba8Unorm,
        },
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
