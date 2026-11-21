//! The wgpu adapter on this machine's GPU (`mise run render-gpu`, and in
//! the Linux container on Mesa's software Vulkan, `mise run
//! linux-render`).
//!
//! On demand, never in the gate: what it finds depends on the machine's
//! adapter and its driver. The gate builds this example and never runs
//! it; there the wgpu adapter runs only on wgpu's no-op back end, which
//! checks its calls and draws nothing. This is where its picture is
//! looked at. It opens no window.
//!
//! It does three things, and its exit status is whether the first two
//! held:
//!
//! 1. holds a renderer on this machine's adapter to the `Renderer` port's
//!    contract;
//! 2. draws the fixture frame of `tests/common/mod.rs`, reads the target
//!    back and compares it with what the headless adapter draws: with the
//!    reference image `tests/render/frame.png`, which is in subpixel
//!    masks, when the adapter blends by a coverage for each channel; and
//!    in plain masks, as a display of scale 2 gets them, with the headless
//!    adapter's picture of the same frame drawn the same way. No channel
//!    of any pixel may differ by more than 3 of 255. Then the same again
//!    with the macOS setting (`Settings::core_text`: Core Text's weight
//!    of text, blended in sRGB-encoded values through a target that is
//!    not sRGB): in plain masks, and in subpixel masks when the adapter
//!    blends by a coverage for each channel, each against the headless
//!    adapter's picture drawn with the same settings, since the reference
//!    image is the default's. Then the fixture with its text in grey
//!    (`#808080`), blended encoded at a contrast of 1, against the CPU:
//!    the contrast is reckoned from the colour's linear light in either
//!    space, and a shader that took it from the encoded value would miss
//!    by about 9 of 255 at half coverage. Then a control that must miss:
//!    the GPU's encoded picture against the CPU's linear one, with the
//!    settings otherwise the same, must differ by more than 3, or the
//!    comparison cannot see the blending (`WITHIN`, and exit 1). Then the
//!    fixture with every glyph a colour image, made by a rasteriser of
//!    this example's ([`InColour`]), blended encoded: the GPU against the
//!    CPU, then the control, against the CPU blending in linear light,
//!    which must miss. The fixture's fonts have no colour glyph, so this
//!    is where the shader's colour image is drawn. Then the clear: a
//!    frame of no views on the ground `#2e3440`, in either blending, must
//!    be read back as that colour within 1 of 255 in every pixel, and the
//!    CPU's exactly that colour; with a control that must miss, the same
//!    frame on a black ground, which must differ from it by more than 1,
//!    or the comparison cannot see the clear (`WITHIN`, and exit 1). Each
//!    renderer says which space it blends in;
//! 3. prints how long a first frame, a frame with a row edited and a
//!    frame that differs only in its cursor took, with the rows each
//!    built. The times are for a person to read: nothing is asserted of
//!    them.

use std::process::ExitCode;
use std::sync::Arc;
use std::time::{Duration, Instant};

use editor_layout::face::Color;
use editor_layout::frame::Frame;
use editor_raster::{GlyphImage, GlyphRequest, Kind, Rasterize};
use editor_render::contract;
use editor_render::port::{DrawRequest, Drawn, Renderer};
use editor_render_wgpu::{
    Antialiasing, Blending, HeadlessRenderer, Image, NoAdapter, Settings, Weight, WgpuRenderer,
};

#[path = "../tests/common/mod.rs"]
mod common;

/// The reference image, as the file checked in.
const REFERENCE_PNG: &[u8] = include_bytes!("../../../tests/render/frame.png");

/// How far any channel of any pixel a GPU draws may be from the CPU
/// compositor's: 3 of 255. Looser than the gate's 2: a GPU's sRGB
/// conversion and its blend round as its driver chooses (Metal and
/// llvmpipe were one level apart on one blend).
const TOLERANCE: u8 = 3;

/// How far any channel of the GPU's clear may be from the frame's ground:
/// 1 of 255, for the rounding of a clear made linear and encoded again.
const CLEAR_TOLERANCE: u8 = 1;

/// The ground of the clear's comparison: a paper far from black.
const PAPER: Color = Color::rgb(0x2e, 0x34, 0x40);

/// A renderer on this machine's adapter.
fn on_this_machine(settings: Settings) -> Result<WgpuRenderer, NoAdapter> {
    #[expect(
        clippy::disallowed_methods,
        reason = "this example is the one place this machine's adapter is asked for: it is the adapter's check, run on demand"
    )]
    WgpuRenderer::on_this_machine(settings)
}

/// What `run` gave, and how long it took.
fn timed<T>(run: impl FnOnce() -> T) -> (T, Duration) {
    #[expect(
        clippy::disallowed_methods,
        reason = "this example is the one place a draw on a real adapter is timed, for a person to read; the times are printed and never asserted, and editor-render publishes no real clock"
    )]
    let start = Instant::now();
    let value = run();
    (value, start.elapsed())
}

/// Draws `frame` on `renderer`, and says how long that took.
fn draw(renderer: &mut WgpuRenderer, frame: &Arc<Frame>) -> (Drawn, Duration) {
    timed(|| {
        renderer.draw(&DrawRequest {
            frame,
            target: common::TARGET,
        })
    })
}

/// What makes a comparison's glyph images.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Glyphs {
    /// The fixture's fonts, through swash, as a renderer makes them until
    /// it is handed a rasteriser.
    Fonts,
    /// [`InColour`], for every glyph.
    InColour,
}

/// A rasteriser that draws every glyph as a colour image, which the
/// fixture's fonts have none of: a box of [`InColour::WIDTH`] by
/// [`InColour::HEIGHT`] pixels from the pen, in [`InColour::COLOUR`], its
/// alpha falling by 4 of 255 at each pixel across and down from opaque to
/// 19 of 255, and its colours multiplied by its alpha as a colour image's
/// are. So the colour image is laid over the fixture's grounds at sixty
/// alphas.
struct InColour;

impl InColour {
    /// How far across the box is.
    const WIDTH: u32 = 6;
    /// How far down, and how far above the baseline its top.
    const HEIGHT: u32 = 10;
    /// Its colour, as sRGB values, each far from its linear light.
    const COLOUR: [u8; 3] = [0x20, 0x70, 0xc0];
}

impl Rasterize for InColour {
    fn rasterize(&mut self, _: &GlyphRequest<'_>) -> Option<GlyphImage> {
        let pixels = Self::WIDTH * Self::HEIGHT;
        let data = (0..pixels)
            .flat_map(|pixel| {
                let alpha = 255 - 4 * pixel;
                let times = |channel: u8| ((u32::from(channel) * alpha + 127) / 255) as u8;
                let [red, green, blue] = Self::COLOUR;
                [times(red), times(green), times(blue), alpha as u8]
            })
            .collect();
        Some(GlyphImage {
            kind: Kind::Color,
            width: Self::WIDTH,
            height: Self::HEIGHT,
            left: 0,
            top: Self::HEIGHT as i32,
            data,
        })
    }

    fn name(&self) -> &'static str {
        "the example's colour images"
    }
}

/// What the headless adapter draws of `frame` with `settings`, its glyph
/// images made by `glyphs`.
fn on_the_cpu(frame: &Arc<Frame>, settings: Settings, glyphs: Glyphs) -> Image {
    let mut renderer = HeadlessRenderer::new(settings);
    if glyphs == Glyphs::InColour {
        renderer = renderer.rasterizing_with(InColour);
    }
    renderer.draw(&DrawRequest {
        frame,
        target: common::TARGET,
    });
    renderer.image().clone()
}

/// What a GPU renderer with `settings` draws of `frame`, its glyph images
/// made by `glyphs`, read back, after it says which space it blends in;
/// `None`, said, when there is no renderer or the draw is refused.
fn on_the_gpu(frame: &Arc<Frame>, settings: Settings, glyphs: Glyphs) -> Option<Image> {
    let mut renderer = match on_this_machine(settings) {
        Ok(renderer) if glyphs == Glyphs::InColour => renderer.rasterizing_with(InColour),
        Ok(renderer) => renderer,
        Err(none) => {
            println!("render-gpu: {none}");
            return None;
        }
    };
    let (drawn, _) = draw(&mut renderer, frame);
    println!(
        "render-gpu: asked to blend in {}, the renderer blends in {}",
        settings.blending,
        renderer.blending()
    );
    if !drawn.presented {
        println!(
            "render-gpu: the draw was refused: {}",
            renderer.refused().unwrap_or("no reason given")
        );
        return None;
    }
    Some(renderer.read_back())
}

/// Whether the GPU's picture of `frame` with `settings` is within the
/// tolerance of the CPU's with the same settings, which is `against`.
fn held_to_the_cpu(frame: &Arc<Frame>, settings: Settings, against: &str) -> bool {
    on_the_gpu(frame, settings, Glyphs::Fonts)
        .is_some_and(|image| compared(&image, &on_the_cpu(frame, settings, Glyphs::Fonts), against))
}

/// Says how `image`, read back from the GPU, differs from `expected`,
/// which is `against`: whether no channel of any pixel differs by more
/// than [`TOLERANCE`].
fn compared(image: &Image, expected: &Image, against: &str) -> bool {
    compared_within(image, expected, against, TOLERANCE)
}

/// [`compared`], with no channel of any pixel to differ by more than
/// `tolerance`.
fn compared_within(image: &Image, expected: &Image, against: &str, tolerance: u8) -> bool {
    let Some((worst, differing)) = common::difference(image, expected) else {
        println!(
            "render-gpu: the frame read back is {} by {} pixels, and {against} is {} by {}",
            image.width, image.height, expected.width, expected.height
        );
        return false;
    };
    let within = worst <= tolerance;
    let verdict = if within { "within" } else { "PAST" };
    println!(
        "render-gpu: the frame read back is {} by {} pixels; against {against}, {differing} pixels differ, the worst by {worst} of 255: {verdict} the tolerance of {tolerance}",
        image.width, image.height
    );
    within
}

/// The fixture frame with the default face's text in grey, `#808080`,
/// whose linear light (0.216) is far from its encoded value (0.502).
fn grey_text(layout: &mut editor_layout::Layout<editor_shape_parley::ParleyShaper>) -> Arc<Frame> {
    let mut scene = common::scene_of(common::TEXT, common::SELECTED);
    for def in scene.faces.iter_mut().flatten() {
        if def.name == "default" {
            def.face.foreground = Some(Color::rgb(0x80, 0x80, 0x80));
        }
    }
    Arc::new(layout.frame(&scene))
}

/// A frame of no views on `ground`.
fn grounded(ground: Color) -> Arc<Frame> {
    Arc::new(Frame {
        ground,
        ..Frame::default()
    })
}

/// Whether the clear holds with `settings`: the CPU's picture of a frame
/// of no views on [`PAPER`] is exactly that colour, the GPU's is within
/// [`CLEAR_TOLERANCE`] of it, and the control, the GPU's picture of the
/// same frame on black, misses it.
fn clear_held(settings: Settings) -> bool {
    let paper = grounded(PAPER);
    let expected = on_the_cpu(&paper, settings, Glyphs::Fonts);
    let [red, green, blue, _] = PAPER.0.to_be_bytes();
    let exact = expected
        .rgba
        .as_chunks::<4>()
        .0
        .iter()
        .all(|pixel| *pixel == [red, green, blue, 0xff]);
    println!(
        "render-gpu: the CPU's clear to #2e3440, {}: {}",
        settings.blending,
        if exact { "exactly it" } else { "NOT it" }
    );
    let against = format!("the frame's ground #2e3440 ({})", settings.blending);
    let Some(image) = on_the_gpu(&paper, settings, Glyphs::Fonts) else {
        return false;
    };
    let mut held = exact & compared_within(&image, &expected, &against, CLEAR_TOLERANCE);
    let Some(black) = on_the_gpu(&grounded(Color::rgb(0, 0, 0)), settings, Glyphs::Fonts) else {
        return false;
    };
    let control = format!("{against}, drawn on black (the control, which must miss)");
    if compared_within(&black, &expected, &control, CLEAR_TOLERANCE) {
        held = false;
        println!("render-gpu: WITHIN: the comparison cannot see the clear");
    }
    held
}

fn main() -> ExitCode {
    let mut renderer = match on_this_machine(common::settings()) {
        Ok(renderer) => renderer,
        Err(none) => {
            println!("render-gpu: {none}");
            return ExitCode::FAILURE;
        }
    };
    let per_channel = renderer.per_channel();
    println!(
        "render-gpu: adapter {}; blends by a coverage for each channel: {per_channel}; blends in {}",
        renderer.adapter(),
        renderer.blending()
    );
    let mut held = true;

    // 1. The contract. Its renderers are made as this one was, so each
    // can be made.
    let failed = contract::check(|| {
        on_this_machine(common::settings()).expect("the adapter that was there a moment ago")
    });
    if failed.is_empty() {
        println!(
            "render-gpu: all {} properties of the renderer contract hold",
            contract::PROPERTIES.len()
        );
    } else {
        held = false;
        for property in failed {
            println!("render-gpu: failed: {property}");
        }
    }

    // 2. The picture. Three frames of one layout: the fixture; then a
    // letter of its second row changed, with a bare cursor in place of
    // the selection; then that with its cursor elsewhere, which differs
    // in nothing else.
    let mut layout = common::layout();
    let fixture = Arc::new(layout.frame(&common::scene_of(common::TEXT, common::SELECTED)));
    let edited = common::TEXT.replacen("under", "undor", 1);
    let changed = Arc::new(layout.frame(&common::scene_of(&edited, 7..7)));
    let moved = Arc::new(layout.frame(&common::scene_of(&edited, 1..1)));

    let plain = Settings {
        antialiasing: Antialiasing::Grayscale,
        ..common::settings()
    };
    let masks = "the headless adapter's picture in plain masks";
    let (first, first_took) = draw(&mut renderer, &fixture);
    if !first.presented {
        held = false;
        println!(
            "render-gpu: the draw was refused: {}",
            renderer.refused().unwrap_or("no reason given")
        );
    }
    let image = renderer.read_back();
    if per_channel {
        // With a coverage for each channel, as the reference image was
        // drawn.
        let reference = common::decode(REFERENCE_PNG);
        held &= compared(&image, &reference, "tests/render/frame.png");
        // And in plain masks, as a display of two physical pixels to a
        // logical one gets them: another renderer, told to.
        match on_this_machine(plain) {
            Ok(mut other) => {
                held &= draw(&mut other, &fixture).0.presented;
                held &= compared(
                    &other.read_back(),
                    &on_the_cpu(&fixture, plain, Glyphs::Fonts),
                    masks,
                );
            }
            Err(none) => {
                held = false;
                println!("render-gpu: {none}");
            }
        }
    } else {
        // An adapter that cannot blend by a coverage for each channel
        // draws plain masks whatever it is told.
        held &= compared(&image, &on_the_cpu(&fixture, plain, Glyphs::Fonts), masks);
    }

    // The same frame at the macOS setting, blended as macOS blends: the
    // contrast and the blending reach the shader, the dilation the atlas,
    // and the GPU is held to the CPU drawing it with the same settings.
    let macos = Settings::core_text();
    let macos_plain = Settings {
        antialiasing: Antialiasing::Grayscale,
        ..macos
    };
    let macos_subpixel = Settings {
        antialiasing: common::settings().antialiasing,
        ..macos
    };
    let mut weighed = vec![(
        macos_plain,
        "the headless adapter's picture at the macOS setting in plain masks",
    )];
    if per_channel {
        weighed.push((
            macos_subpixel,
            "the headless adapter's picture at the macOS setting in subpixel masks",
        ));
    }
    for (settings, against) in weighed {
        held &= held_to_the_cpu(&fixture, settings, against);
    }

    // Grey text, blended encoded at a contrast of 1: the contrast is
    // reckoned from the colour's linear light on the GPU as on the CPU.
    let grey = grey_text(&mut layout);
    let contrasted = Settings {
        antialiasing: Antialiasing::Grayscale,
        weight: Weight {
            contrast: 1.0,
            dilation: 0.0,
        },
        blending: Blending::Encoded,
        ..common::settings()
    };
    held &= held_to_the_cpu(
        &grey,
        contrasted,
        "the headless adapter's picture of grey text, encoded, at a contrast of 1",
    );

    // The control: the GPU blending encoded against the CPU blending in
    // linear light, otherwise alike, must differ past the tolerance.
    let linear_plain = Settings {
        blending: Blending::Linear,
        ..macos_plain
    };
    match on_the_gpu(&fixture, macos_plain, Glyphs::Fonts) {
        Some(image) => {
            let against =
                "the headless adapter's picture in linear light (the control, which must miss)";
            if compared(
                &image,
                &on_the_cpu(&fixture, linear_plain, Glyphs::Fonts),
                against,
            ) {
                held = false;
                println!("render-gpu: WITHIN: the comparison cannot see the blending");
            }
        }
        None => held = false,
    }

    // Colour images, blended encoded: every glyph of the fixture one, the
    // GPU held to the CPU; and the control, the GPU against the CPU
    // blending in linear light, which must miss.
    match on_the_gpu(&fixture, macos_plain, Glyphs::InColour) {
        Some(image) => {
            held &= compared(
                &image,
                &on_the_cpu(&fixture, macos_plain, Glyphs::InColour),
                "the headless adapter's picture with every glyph a colour image, encoded",
            );
            let against = "the headless adapter's picture with every glyph a colour image, in linear light (the control, which must miss)";
            if compared(
                &image,
                &on_the_cpu(&fixture, linear_plain, Glyphs::InColour),
                against,
            ) {
                held = false;
                println!(
                    "render-gpu: WITHIN: the comparison cannot see how a colour image is blended"
                );
            }
        }
        None => held = false,
    }

    // The clear: a frame of no views is its ground, in either space.
    for blending in [Blending::Linear, Blending::Encoded] {
        held &= clear_held(Settings {
            blending,
            ..macos_plain
        });
    }

    // 3. The times, for a person.
    let (second, second_took) = draw(&mut renderer, &changed);
    let (third, third_took) = draw(&mut renderer, &moved);
    for (name, drawn, took) in [
        ("a first frame", first, first_took),
        (
            "a frame with a row edited and the selection gone",
            second,
            second_took,
        ),
        ("a frame that differs only in its cursor", third, third_took),
    ] {
        println!(
            "render-gpu: {name}: {took:?}; {} rows built, {} reused, {} glyphs rasterised",
            drawn.rows_rebuilt, drawn.rows_reused, drawn.glyphs_rasterised
        );
    }

    if held {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
