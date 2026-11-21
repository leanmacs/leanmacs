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
//!    with the macOS setting (`Settings::core_text`, Core Text's weight
//!    of text): in plain masks, and in subpixel masks when the adapter
//!    blends by a coverage for each channel, each against the headless
//!    adapter's picture drawn with the same settings, since the reference
//!    image is the default's. The fixture has no colour glyph, so a
//!    colour image is never drawn here;
//! 3. prints how long a first frame, a frame with a row edited and a
//!    frame that differs only in its cursor took, with the rows each
//!    built. The times are for a person to read: nothing is asserted of
//!    them.

use std::process::ExitCode;
use std::sync::Arc;
use std::time::{Duration, Instant};

use editor_layout::frame::Frame;
use editor_render::contract;
use editor_render::port::{DrawRequest, Drawn, Renderer};
use editor_render_wgpu::{
    Antialiasing, HeadlessRenderer, Image, NoAdapter, Settings, WgpuRenderer,
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
    // real time under test: how long the draw took, printed for a person
    // and never asserted.
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

/// What the headless adapter draws of `frame` with `settings`.
fn on_the_cpu(frame: &Arc<Frame>, settings: Settings) -> Image {
    let mut renderer = HeadlessRenderer::new(settings);
    renderer.draw(&DrawRequest {
        frame,
        target: common::TARGET,
    });
    renderer.image().clone()
}

/// Says how `image`, read back from the GPU, differs from `expected`,
/// which is `against`: whether no channel of any pixel differs by more
/// than [`TOLERANCE`].
fn compared(image: &Image, expected: &Image, against: &str) -> bool {
    let Some((worst, differing)) = common::difference(image, expected) else {
        println!(
            "render-gpu: the frame read back is {} by {} pixels, and {against} is {} by {}",
            image.width, image.height, expected.width, expected.height
        );
        return false;
    };
    let within = worst <= TOLERANCE;
    let verdict = if within { "within" } else { "PAST" };
    println!(
        "render-gpu: the frame read back is {} by {} pixels; against {against}, {differing} pixels differ, the worst by {worst} of 255: {verdict} the tolerance of {TOLERANCE}",
        image.width, image.height
    );
    within
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
        "render-gpu: adapter {}; blends by a coverage for each channel: {per_channel}",
        renderer.adapter()
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
    let mut frame =
        |text: &str, selected| Arc::new(layout.frame(&common::scene_of(text, selected)));
    let fixture = frame(common::TEXT, common::SELECTED);
    let edited = common::TEXT.replacen("under", "undor", 1);
    let changed = frame(&edited, 7..7);
    let moved = frame(&edited, 1..1);

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
                held &= compared(&other.read_back(), &on_the_cpu(&fixture, plain), masks);
            }
            Err(none) => {
                held = false;
                println!("render-gpu: {none}");
            }
        }
    } else {
        // An adapter that cannot blend by a coverage for each channel
        // draws plain masks whatever it is told.
        held &= compared(&image, &on_the_cpu(&fixture, plain), masks);
    }

    // The same frame at the macOS weight: the contrast reaches the
    // shader and the dilation the atlas, and the GPU is held to the CPU
    // drawing it with the same settings.
    let macos_plain = Settings {
        antialiasing: Antialiasing::Grayscale,
        ..Settings::core_text()
    };
    let macos_subpixel = Settings {
        antialiasing: common::settings().antialiasing,
        ..Settings::core_text()
    };
    let mut weighed = vec![(
        macos_plain,
        "the headless adapter's picture at the macOS weight in plain masks",
    )];
    if per_channel {
        weighed.push((
            macos_subpixel,
            "the headless adapter's picture at the macOS weight in subpixel masks",
        ));
    }
    for (settings, against) in weighed {
        match on_this_machine(settings) {
            Ok(mut other) => {
                held &= draw(&mut other, &fixture).0.presented;
                held &= compared(&other.read_back(), &on_the_cpu(&fixture, settings), against);
            }
            Err(none) => {
                held = false;
                println!("render-gpu: {none}");
            }
        }
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
