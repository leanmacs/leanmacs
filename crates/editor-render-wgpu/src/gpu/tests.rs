//! The wgpu device's tests: on wgpu's no-op back end, which checks every
//! call as a real one would and draws nothing. They need no GPU and no
//! driver, so they run in the gate.
//!
//! What they show is that the device's calls are ones wgpu accepts: that
//! the shader compiles in both its forms, that the pipeline's vertex
//! layout is the shader's, that every kind of quad and every kind of page
//! goes through. What the GPU then draws is not seen here: that is the
//! example `gpu`'s, on demand, on a real adapter.
//!
//! No test here runs a shaper or reads a font: the frames are of layout's
//! fake shaper, and the glyph images the fake rasteriser's. One test
//! draws real glyphs, with a weight other than the default: the weight
//! sentence of `crate::weight_tests`, built by hand with its font
//! compiled in.

use std::ptr::NonNull;

use editor_layout::Layout;
use editor_layout::face::{Color, Face, FaceDef, Underline, UnderlineStyle};
use editor_layout::frame::Frame;
use editor_layout::scene::{Decoration, Rect, Scene, StatusField};
use editor_layout::shaper::fake::CellShaper;
use editor_platform::NativeWindow;
use editor_render::contract;
use editor_render::port::{DrawRequest, Renderer, Target};

use super::{Device, INSTANCE_BYTES, Run, Window, globals, instances};
use crate::atlas::Atlas;
use editor_raster::fake::FakeRasterizer;

use crate::glyphs::Kind;
use crate::painter::Painter;
use crate::quads::{Quad, QuadKind};
use crate::surface::handles;
use crate::{Antialiasing, Blending, Settings, SubpixelOrder, Weight, WgpuRenderer};

/// An instance whose one adapter is wgpu's no-op back end.
fn noop() -> wgpu::Instance {
    let mut descriptor = wgpu::InstanceDescriptor::new_without_display_handle();
    descriptor.backends = wgpu::Backends::NOOP;
    descriptor.backend_options.noop.enable = true;
    wgpu::Instance::new(descriptor)
}

/// A device on the no-op back end, blending in linear light.
fn device(allow_per_channel: bool) -> Device {
    blending_in(allow_per_channel, Blending::Linear)
}

/// A device on the no-op back end, blending in `blending`'s space.
fn blending_in(allow_per_channel: bool, blending: Blending) -> Device {
    Device::new(&noop(), allow_per_channel, blending).expect("the no-op adapter")
}

/// Both spaces a device blends in.
const BLENDINGS: [Blending; 2] = [Blending::Linear, Blending::Encoded];

/// A target of 200 by 64 pixels at `scale`.
fn target(scale: f32) -> Target {
    Target {
        width: 200,
        height: 64,
        scale,
    }
}

/// A frame of layout's fake shaper with everything a frame can hold: two
/// rows, a word underlined on a coloured background, a selection with a
/// block cursor, and a status row.
fn dressed() -> Frame {
    let rect = Rect {
        x: 0,
        y: 0,
        width: 200,
        height: 64,
    };
    let (anchor, head) = (5, 3);
    let mut scene = Scene::of_text("ab cd\nef", rect).selecting(anchor..head);
    scene.faces = Some(vec![FaceDef {
        name: "mark".to_owned(),
        face: Face {
            background: Some(Color::rgb(0xff, 0xff, 0)),
            underline: Some(Underline {
                style: UnderlineStyle::Curly,
                color: Some(Color::rgb(0xff, 0, 0)),
            }),
            strike_through: Some(true),
            ..Face::default()
        },
    }]);
    scene.views[0].decorations = vec![Decoration {
        start: 0,
        stop: 2,
        face: "mark".to_owned(),
    }];
    scene.views[0].status = vec![StatusField {
        text: "st".to_owned(),
        face: "mode-line".to_owned(),
        ..StatusField::default()
    }];
    Layout::new(CellShaper::new(10.0, 16.0)).frame(&scene)
}

/// A painter over the fake rasteriser, in which the letter `c` is a
/// colour glyph, for a device that blends as `per_channel` says.
fn painter(antialiasing: Antialiasing, per_channel: bool) -> Painter<FakeRasterizer> {
    let mut rasterizer = FakeRasterizer::new();
    rasterizer.colour.insert(u32::from('c'));
    let settings = Settings {
        antialiasing,
        ..Settings::default()
    };
    Painter::new(rasterizer, &settings, per_channel, 64)
}

/// Which kinds of quad `painter`'s last frame came to.
fn kinds(painter: &Painter<FakeRasterizer>) -> Vec<QuadKind> {
    let mut kinds: Vec<QuadKind> = Vec::new();
    for quad in painter.quads() {
        if !kinds.contains(&quad.kind) {
            kinds.push(quad.kind);
        }
    }
    kinds
}

#[test]
fn the_wgpu_adapter_holds_the_renderer_contract_on_the_noop_back_end() {
    let failed = contract::check(|| {
        WgpuRenderer::over(&noop(), Settings::default(), true).expect("the no-op adapter")
    });
    assert_eq!(failed, Vec::<&str>::new(), "the properties that fail");
}

#[test]
fn every_kind_of_quad_and_of_page_is_drawn_with_no_validation_error() {
    for blending in BLENDINGS {
        let mut device = blending_in(true, blending);
        assert!(device.per_channel());
        let mut painter = painter(Antialiasing::Auto, device.per_channel());
        let frame = dressed();
        // At scale 1: fills, subpixel masks and a colour glyph.
        painter.paint(&frame, target(1.0));
        assert_eq!(
            kinds(&painter),
            vec![QuadKind::Fill, QuadKind::Subpixel, QuadKind::Color]
        );
        assert_eq!(
            device.draw(painter.quads(), painter.atlas(), 200, 64),
            Ok(()),
            "{blending:?}"
        );
        // At scale 2: plain masks, from a third kind of page.
        painter.paint(&frame, target(2.0));
        assert_eq!(
            kinds(&painter),
            vec![QuadKind::Fill, QuadKind::Mask, QuadKind::Color]
        );
        assert_eq!(
            device.draw(painter.quads(), painter.atlas(), 200, 64),
            Ok(()),
            "{blending:?}"
        );
        // The device holds a texture for each page of the atlas, as it
        // was when it was sent.
        let pages: Vec<(u32, Kind, u64)> = painter
            .atlas()
            .pages()
            .map(|page| (page.number, page.kind, page.written))
            .collect();
        let kinds: Vec<Kind> = pages.iter().map(|(_, kind, _)| *kind).collect();
        assert_eq!(kinds, vec![Kind::Subpixel, Kind::Color, Kind::Mask]);
        assert_eq!(device.pages.len(), pages.len());
        for (number, _, written) in pages {
            assert_eq!(
                device.pages.get(&number).map(|page| page.sent),
                Some(written)
            );
        }
    }
}

#[test]
fn a_device_without_dual_source_blending_draws_plain_masks_through_its_own_blend() {
    for blending in BLENDINGS {
        // The no-op adapter has the feature; the device is told not to
        // ask for it, as on an adapter that has none.
        let mut device = blending_in(false, blending);
        assert!(!device.per_channel());
        let stripes = Antialiasing::Subpixel(SubpixelOrder::Rgb);
        let mut painter = painter(stripes, device.per_channel());
        painter.paint(&dressed(), target(1.0));
        assert_eq!(
            kinds(&painter),
            vec![QuadKind::Fill, QuadKind::Mask, QuadKind::Color]
        );
        assert_eq!(
            device.draw(painter.quads(), painter.atlas(), 200, 64),
            Ok(()),
            "{blending:?}"
        );
        // And the renderer made over such a device says so, and still
        // draws.
        let settings = Settings {
            blending,
            ..Settings::default()
        };
        let mut renderer = WgpuRenderer::over(&noop(), settings, false).expect("the no-op adapter");
        assert!(!renderer.per_channel());
        let drawn = renderer.draw(&DrawRequest {
            frame: &std::sync::Arc::new(dressed()),
            target: target(1.0),
        });
        assert!(drawn.presented, "{:?}", renderer.refused());
        assert_eq!(renderer.refused(), None);
    }
}

#[test]
fn a_device_that_blends_encoded_draws_on_its_own_target_in_the_non_srgb_format() {
    let encoded = blending_in(true, Blending::Encoded);
    assert_eq!(encoded.format, wgpu::TextureFormat::Rgba8Unorm);
    assert_eq!(encoded.blending(), Blending::Encoded);
    let linear = blending_in(true, Blending::Linear);
    assert_eq!(linear.format, wgpu::TextureFormat::Rgba8UnormSrgb);
    assert_eq!(linear.blending(), Blending::Linear);
    // And what it draws on is of that format, and is read back.
    let mut encoded = encoded;
    assert_eq!(encoded.draw(&[], &Atlas::new(64), 20, 10), Ok(()));
    assert_eq!(
        encoded
            .target
            .as_ref()
            .map(|target| target.texture.format()),
        Some(wgpu::TextureFormat::Rgba8Unorm)
    );
    let image = encoded.read_back().expect("the target read back");
    assert_eq!((image.width, image.height), (20, 10));
}

#[test]
fn a_renderer_blends_as_its_settings_say() {
    for blending in BLENDINGS {
        let settings = Settings {
            blending,
            ..Settings::default()
        };
        let renderer = WgpuRenderer::over(&noop(), settings, true).expect("the no-op adapter");
        assert_eq!(renderer.blending(), blending);
    }
}

#[test]
fn a_draw_wgpu_refuses_is_not_presented_and_says_so_and_the_next_one_is() {
    let mut renderer =
        WgpuRenderer::over(&noop(), Settings::default(), true).expect("the no-op adapter");
    let frame = std::sync::Arc::new(dressed());
    // A target one pixel wider than the device says a texture may be.
    let limit = renderer.device.device.limits().max_texture_dimension_2d;
    let wide = Target {
        width: limit + 1,
        ..target(1.0)
    };
    let drawn = renderer.draw(&DrawRequest {
        frame: &frame,
        target: wide,
    });
    assert!(!drawn.presented);
    assert!(renderer.refused().is_some());
    // And there is no picture of it to read.
    let image = renderer.read_back();
    assert_eq!((image.width, image.height), (0, 0));
    assert!(renderer.refused().is_some());
    // The same frame on a target the device makes is presented, and
    // nothing is said of it.
    let drawn = renderer.draw(&DrawRequest {
        frame: &frame,
        target: target(1.0),
    });
    assert!(drawn.presented, "{:?}", renderer.refused());
    assert_eq!(renderer.refused(), None);
    let image = renderer.read_back();
    assert_eq!((image.width, image.height), (200, 64));
    assert_eq!(renderer.refused(), None);
}

#[test]
fn what_a_refused_draw_built_is_answered_by_the_draw_that_next_presents() {
    let noop = noop();
    let renderer = || WgpuRenderer::over(&noop, Settings::default(), true).expect("an adapter");
    let frame = std::sync::Arc::new(dressed());
    let on = |target: Target| DrawRequest {
        frame: &frame,
        target,
    };
    // What the frame costs a renderer that is never refused. Its glyphs
    // are of layout's fake shaper and have no image: each is skipped.
    let whole = renderer().draw(&on(target(1.0)));
    assert!(whole.presented);
    assert!(whole.rows_rebuilt > 0 && whole.glyphs_skipped > 0);
    assert_eq!(whole.rows_reused, 0);
    // A renderer whose first draw of it is refused, on a target wider
    // than the device makes one: the rows are built all the same.
    let mut renderer = renderer();
    let limit = renderer.device.device.limits().max_texture_dimension_2d;
    let wide = Target {
        width: limit + 1,
        ..target(1.0)
    };
    assert!(!renderer.draw(&on(wide)).presented);
    // The draw that presents the frame answers for them: it cost what it
    // costs a renderer that was not refused, and no row of it is reused.
    assert_eq!(renderer.draw(&on(target(1.0))), whole);
    // And once presented the frame costs nothing more.
    let again = renderer.draw(&on(target(1.0)));
    assert_eq!(
        (again.rows_rebuilt, again.rows_reused, again.glyphs_skipped),
        (0, whole.rows_rebuilt, 0)
    );
}

#[test]
fn the_target_read_back_is_the_size_last_drawn_at() {
    let mut device = device(true);
    // Before a first draw there is no picture.
    let none = device.read_back().expect("no draw to read");
    assert_eq!((none.width, none.height), (0, 0));
    for (width, height) in [(200, 64), (50, 20), (300, 7)] {
        assert_eq!(
            device.draw(&[], &crate::atlas::Atlas::new(64), width, height),
            Ok(())
        );
        let image = device.read_back().expect("the target read back");
        assert_eq!((image.width, image.height), (width, height));
        // Whatever a row's padding in the copy, the picture has four
        // bytes a pixel and no more.
        assert_eq!(image.rgba.len(), (width * height * 4) as usize);
    }
}

#[test]
fn a_renderer_with_a_target_of_its_own_says_its_picture_can_be_kept() {
    // It draws on no window: its target is always read back.
    let mut renderer =
        WgpuRenderer::over(&noop(), Settings::default(), true).expect("the no-op adapter");
    assert!(renderer.keep_picture());
}

#[test]
fn a_target_of_no_size_is_drawn_on_and_not_refused() {
    // A window made as small as it goes has a side of no pixels, and wgpu
    // makes no texture of none: the device draws on one pixel in its
    // place.
    let mut device = device(true);
    let atlas = Atlas::new(64);
    for (width, height) in [(0, 0), (0, 64), (200, 0)] {
        assert_eq!(
            device.draw(&[], &atlas, width, height),
            Ok(()),
            "{width} by {height}"
        );
        let image = device.read_back().expect("the target read back");
        assert_eq!(
            (image.width, image.height),
            (width.max(1), height.max(1)),
            "{width} by {height}"
        );
    }
    // So the adapter presents a frame on such a target, and the loop has
    // no draw to try again at every refresh.
    let mut renderer =
        WgpuRenderer::over(&noop(), Settings::default(), true).expect("the no-op adapter");
    let none = Target {
        width: 0,
        height: 0,
        scale: 1.0,
    };
    let drawn = renderer.draw(&DrawRequest {
        frame: &std::sync::Arc::new(dressed()),
        target: none,
    });
    assert!(drawn.presented, "{:?}", renderer.refused());
    assert_eq!(renderer.refused(), None);
}

#[test]
fn a_page_the_atlas_drops_is_dropped_by_the_device() {
    let mut device = device(true);
    let mut painter = painter(Antialiasing::Grayscale, true);
    painter.paint(&dressed(), target(1.0));
    assert_eq!(
        device.draw(painter.quads(), painter.atlas(), 200, 64),
        Ok(())
    );
    assert_eq!(device.pages.len(), 2);
    // A frame of another generation empties the atlas: of a frame of no
    // views nothing is left.
    let later = Frame {
        generation: 1,
        ..Frame::default()
    };
    painter.paint(&later, target(1.0));
    assert_eq!(painter.atlas().pages().count(), 0);
    assert_eq!(
        device.draw(painter.quads(), painter.atlas(), 200, 64),
        Ok(())
    );
    assert!(device.pages.is_empty());
}

/// Draws what `painter` last painted on `device`, on a target of 200 by
/// 64 pixels.
fn draw(device: &mut Device, painter: &Painter<FakeRasterizer>) -> Result<(), String> {
    device.draw(painter.quads(), painter.atlas(), 200, 64)
}

/// For each page of `atlas`, in order, whether `device` takes its texture
/// to hold the page as it now is.
fn sent(device: &Device, atlas: &Atlas) -> Vec<bool> {
    atlas
        .pages()
        .map(|page| device.pages.get(&page.number).map(|held| held.sent) == Some(page.written))
        .collect()
}

#[test]
fn the_pages_of_another_generation_are_sent_to_textures_of_their_own() {
    let mut device = device(true);
    let mut painter = painter(Antialiasing::Grayscale, true);
    painter.paint(&dressed(), target(1.0));
    assert_eq!(draw(&mut device, &painter), Ok(()));
    let written = |painter: &Painter<FakeRasterizer>| -> Vec<(Kind, u64)> {
        let pages = painter.atlas().pages();
        pages.map(|page| (page.kind, page.written)).collect()
    };
    let before = written(&painter);
    let earlier: Vec<wgpu::Texture> = device
        .pages
        .values()
        .map(|page| page.texture.clone())
        .collect();
    assert_eq!(earlier.len(), 2);
    // The same text under another generation of the fonts: the glyph
    // images are others, as many of them, in as many pages of the same
    // kinds.
    let later = Frame {
        generation: 1,
        ..dressed()
    };
    painter.paint(&later, target(1.0));
    assert_eq!(written(&painter), before);
    assert_eq!(draw(&mut device, &painter), Ok(()));
    // None of the textures drawn from is one that holds a page of the
    // generation before.
    assert_eq!(sent(&device, painter.atlas()), vec![true, true]);
    assert_eq!(device.pages.len(), 2);
    for page in device.pages.values() {
        assert!(!earlier.contains(&page.texture));
    }
}

/// An atlas of one page of `kind`, the first it numbers, with `images`
/// images written to it.
fn one_page(kind: Kind, images: usize) -> Atlas {
    let mut atlas = Atlas::new(64);
    atlas.add_page(kind);
    let data = vec![0x80; (6 * 10 * kind.bytes()) as usize];
    for _ in 0..images {
        assert!(atlas.place(kind, 6, 10, &data).is_some());
    }
    atlas
}

#[test]
fn a_texture_of_another_kind_than_its_page_is_made_again() {
    let mut device = device(true);
    let format = |device: &Device, atlas: &Atlas| {
        let number = atlas.pages().next().map(|page| page.number);
        let held = number.and_then(|number| device.pages.get(&number));
        held.map(|held| held.texture.format())
    };
    // Two atlases number their first page alike. The device is handed one
    // and then the other: the texture it holds under that number is of
    // the first one's kind.
    let masks = one_page(Kind::Mask, 1);
    assert_eq!(device.draw(&[], &masks, 200, 64), Ok(()));
    assert_eq!(format(&device, &masks), Some(wgpu::TextureFormat::R8Unorm));
    // As many images written, in colour.
    let colours = one_page(Kind::Color, 1);
    assert_eq!(device.draw(&[], &colours, 200, 64), Ok(()));
    assert_eq!(
        format(&device, &colours),
        Some(wgpu::TextureFormat::Rgba8Unorm)
    );
    assert_eq!(sent(&device, &colours), vec![true]);
    // And back, with more written: the page's bytes are not sent to a
    // texture of four bytes a pixel.
    let masks = one_page(Kind::Mask, 2);
    assert_eq!(device.draw(&[], &masks, 200, 64), Ok(()));
    assert_eq!(format(&device, &masks), Some(wgpu::TextureFormat::R8Unorm));
    assert_eq!(sent(&device, &masks), vec![true]);
}

#[test]
fn after_a_draw_that_is_refused_no_page_is_taken_as_sent() {
    let mut device = device(true);
    let mut painter = painter(Antialiasing::Grayscale, true);
    painter.paint(&dressed(), target(1.0));
    // A target wider than the device makes one: the draw is refused.
    let refused = device.draw(painter.quads(), painter.atlas(), 1_000_000, 64);
    assert!(refused.is_err(), "{refused:?}");
    // What reached the GPU in a draw it refused is not known.
    assert_eq!(sent(&device, painter.atlas()), vec![false, false]);
    // The next draw sends every page.
    assert_eq!(draw(&mut device, &painter), Ok(()));
    assert_eq!(sent(&device, painter.atlas()), vec![true, true]);
}

#[test]
fn an_instance_with_no_adapter_gives_no_renderer() {
    // The no-op back end not turned on: there is no adapter.
    let mut descriptor = wgpu::InstanceDescriptor::new_without_display_handle();
    descriptor.backends = wgpu::Backends::NOOP;
    let instance = wgpu::Instance::new(descriptor);
    let refused = WgpuRenderer::over(&instance, Settings::default(), true)
        .err()
        .expect("no adapter");
    assert!(
        refused
            .to_string()
            .starts_with("no GPU renderer: no adapter"),
        "{refused}"
    );
}

#[test]
fn a_window_no_adapter_can_present_to_gives_no_renderer() {
    // A window made up for the test: the no-op back end makes a surface
    // from any handle and never touches it, so the view is never read.
    let mut made_up = 0_u8;
    let window = NativeWindow::AppKit {
        view: NonNull::from(&mut made_up).cast(),
    };
    // SAFETY: the back end is the no-op one, which keeps the handle and
    // does nothing with it; the renderer, were one made, is dropped here,
    // before `made_up` is.
    let refused = unsafe { WgpuRenderer::over_window(&noop(), &window, Settings::default(), true) }
        .err()
        .expect("the no-op back end presents to no surface");
    // The no-op back end's adapter presents to no surface, and asked for
    // one that can present to this one, wgpu has none: no renderer is
    // made, and the reason is wgpu's. What the surface offers is never
    // asked.
    let reason = refused.to_string();
    assert!(
        reason.starts_with("no GPU renderer: no adapter") && reason.contains("surface"),
        "{reason}"
    );
}

#[test]
fn a_surface_that_offers_its_adapter_nothing_is_refused_and_says_so() {
    // As above, a window made up for the test and never touched.
    let mut made_up = 0_u8;
    let window = NativeWindow::AppKit {
        view: NonNull::from(&mut made_up).cast(),
    };
    let instance = noop();
    let (raw_window_handle, raw_display_handle) = handles(&window);
    // SAFETY: the back end is the no-op one, which keeps the handle and
    // does nothing with it; the surface is dropped here, before `made_up`
    // is.
    let surface = unsafe {
        instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::RawHandle {
            raw_display_handle: Some(raw_display_handle),
            raw_window_handle,
        })
    }
    .expect("the no-op back end makes a surface from any handle");
    // The adapter is asked for without the surface, so there is one: the
    // no-op back end's, which the surface offers nothing.
    let adapter = pollster::block_on(instance.request_adapter(&Default::default()))
        .expect("the no-op adapter");
    let refused = Window::new(
        surface,
        &adapter,
        crate::present::Asked::NOTHING,
        Blending::Linear,
    )
    .err();
    assert_eq!(
        refused.as_deref(),
        Some("the window's surface offers no format on this adapter")
    );
}

/// A quad of `kind` that reads the page `page`.
fn quad(kind: QuadKind, page: u32) -> Quad {
    Quad {
        x: 10,
        y: -2,
        width: 6,
        height: 10,
        kind,
        color: Color::rgba(1, 2, 3, 4),
        page,
        u: 7,
        v: 9,
    }
}

#[test]
fn a_list_of_more_quads_than_the_buffer_holds_is_given_a_larger_one() {
    let mut device = device(true);
    let atlas = Atlas::new(64);
    let fill = quad(QuadKind::Fill, 0);
    // How many quads the buffer the device has made holds.
    let room = |device: &Device| {
        let held = device.instances.as_ref().map_or(0, |(_, held)| *held);
        (held / INSTANCE_BYTES) as usize
    };
    // A few quads first: a buffer is made for them.
    assert_eq!(device.draw(&[fill; 3], &atlas, 200, 64), Ok(()));
    let first = room(&device);
    assert!(first >= 3);
    // Then one more than it holds, and then many times more: wgpu
    // refuses the quads written past the end of a buffer.
    for count in [first + 1, first * 8] {
        assert_eq!(device.draw(&vec![fill; count], &atlas, 200, 64), Ok(()));
        assert!(room(&device) >= count, "{count} quads");
    }
    // A shorter list after a longer one is drawn as well.
    assert_eq!(device.draw(&[fill; 3], &atlas, 200, 64), Ok(()));
}

#[test]
fn quads_are_drawn_in_runs_that_read_one_page_each() {
    let fill = quad(QuadKind::Fill, 0);
    let quads = [
        fill,
        fill,
        quad(QuadKind::Mask, 1),
        fill,
        quad(QuadKind::Mask, 1),
        quad(QuadKind::Subpixel, 2),
        fill,
        quad(QuadKind::Color, 3),
        // A page the device does not hold: left out.
        quad(QuadKind::Mask, 9),
        quad(QuadKind::Mask, 1),
    ];
    let (bytes, runs) = instances(&quads, |page| page != 9);
    assert_eq!(bytes.len() as u64, 9 * INSTANCE_BYTES);
    let run = |page, first, end| Run {
        page: Some(page),
        first,
        end,
    };
    // The fills before the first glyph join its run, and one between two
    // glyphs joins the run it falls in.
    assert_eq!(
        runs,
        vec![run(1, 0, 5), run(2, 5, 7), run(3, 7, 8), run(1, 8, 9)]
    );
    // Fills alone are one run that reads no page.
    let (_, runs) = instances(&[fill, fill], |_| true);
    assert_eq!(
        runs,
        vec![Run {
            page: None,
            first: 0,
            end: 2
        }]
    );
    assert_eq!(instances(&[], |_| true), (Vec::new(), Vec::new()));
}

#[test]
fn an_instance_is_a_quads_box_its_source_and_its_colour() {
    let (bytes, _) = instances(&[quad(QuadKind::Subpixel, 1)], |_| true);
    let mut expected = Vec::new();
    for value in [10_i32, -2, 6, 10] {
        expected.extend_from_slice(&value.to_ne_bytes());
    }
    // Where it reads, then its kind: 2 is a subpixel mask.
    for value in [7_u32, 9, 2, 0] {
        expected.extend_from_slice(&value.to_ne_bytes());
    }
    expected.extend_from_slice(&[1, 2, 3, 4]);
    assert_eq!(bytes, expected);
    assert_eq!(bytes.len() as u64, INSTANCE_BYTES);
    // The kinds, in the shader's numbers.
    let kind = |kind: QuadKind| instances(&[quad(kind, 1)], |_| true).0[24];
    assert_eq!(
        [
            kind(QuadKind::Fill),
            kind(QuadKind::Mask),
            kind(QuadKind::Subpixel),
            kind(QuadKind::Color)
        ],
        [0, 1, 2, 3]
    );
}

#[test]
fn the_globals_are_the_targets_size_the_contrast_and_the_blending() {
    for (blending, flag) in [(Blending::Encoded, 1.0_f32), (Blending::Linear, 0.0)] {
        let mut expected = Vec::new();
        for value in [200.0_f32, 64.0, 0.5, flag] {
            expected.extend_from_slice(&value.to_ne_bytes());
        }
        assert_eq!(globals(200, 64, 0.5, blending).to_vec(), expected);
    }
}

#[test]
fn a_renderer_draws_with_its_settings_contrast() {
    let weight = Weight {
        contrast: 0.5,
        dilation: 0.3,
    };
    let settings = Settings {
        weight,
        ..Settings::default()
    };
    let renderer = WgpuRenderer::over(&noop(), settings, true).expect("the no-op adapter");
    assert_eq!(renderer.device.contrast, 0.5);
    let renderer =
        WgpuRenderer::over(&noop(), Settings::default(), true).expect("the no-op adapter");
    assert_eq!(renderer.device.contrast, Weight::LINEAR.contrast);
}

#[test]
fn a_renderer_rasterises_at_its_settings_dilation() {
    // Two dilations, so that no one dilation put in place of the
    // settings' (none, or Core Text's) passes for both.
    for dilation in [0.3, Weight::CORE_TEXT.dilation] {
        let settings = Settings {
            weight: Weight {
                contrast: 0.0,
                dilation,
            },
            ..Settings::default()
        };
        let renderer = WgpuRenderer::over(&noop(), settings, true).expect("the no-op adapter");
        assert_eq!(
            renderer.painter.rasterizer().fallback().dilation(),
            dilation
        );
        // And handed a rasteriser, its fallback is still made at it.
        let handed = renderer.rasterizing_with(FakeRasterizer::new());
        assert_eq!(handed.painter.rasterizer().fallback().dilation(), dilation);
    }
}

#[test]
fn a_gpu_renderer_says_what_draws_its_glyphs() {
    let renderer =
        WgpuRenderer::over(&noop(), Settings::default(), true).expect("the no-op adapter");
    assert_eq!(renderer.rasterizing().to_string(), "swash");
    let handed = renderer.rasterizing_with(FakeRasterizer::new());
    assert_eq!(
        handed.rasterizing().to_string(),
        "the fake rasteriser, and swash for what it declines"
    );
}

#[test]
fn a_renderer_handed_a_rasteriser_draws_with_no_validation_error() {
    let mut renderer = WgpuRenderer::over(&noop(), Settings::default(), true)
        .expect("the no-op adapter")
        .rasterizing_with(FakeRasterizer::new());
    let drawn = renderer.draw(&DrawRequest {
        frame: &std::sync::Arc::new(dressed()),
        target: target(1.0),
    });
    assert!(drawn.presented, "{:?}", renderer.refused());
    assert!(drawn.glyphs_rasterised > 0);
}

#[test]
fn a_renderer_with_another_weight_draws_real_glyphs_with_no_validation_error() {
    let settings = Settings {
        weight: Weight {
            contrast: 0.5,
            dilation: 0.3,
        },
        ..Settings::default()
    };
    let mut renderer = WgpuRenderer::over(&noop(), settings, true).expect("the no-op adapter");
    let (frame, target) = crate::weight_tests::sentence();
    let drawn = renderer.draw(&DrawRequest {
        frame: &std::sync::Arc::new(frame),
        target,
    });
    assert!(drawn.presented, "{:?}", renderer.refused());
    assert!(drawn.glyphs_rasterised > 0);
}
