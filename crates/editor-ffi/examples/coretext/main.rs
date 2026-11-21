//! The composited sentence against Core Text's, on demand on macOS: the
//! second half of `mise run coretext-check`
//! (`docs/dev-practices/on-demand-checks.md`).
//!
//! What Core Text draws is the system's, and the GPU is the machine's, so
//! no test runs this: the gate builds it, and runs only the tests of its
//! pure module, `measure`. It lives here, in the crate that wires the Core
//! Text rasteriser into the renderers, as the window does.
//!
//! For each of the five captures of `tests/coretext/composited/`, what
//! macOS put in a bitmap when it drew the sentence, it draws the same
//! sentence (`sentence`) through the real renderers with the macOS
//! setting (`Settings::core_text`, blended in sRGB-encoded values) and the
//! Core Text rasteriser, smoothing on, as the captures were drawn
//! (`AppleFontSmoothing` not set); the machine's preference is not read:
//!
//! 1. on the CPU (`HeadlessRenderer`);
//! 2. on the GPU (`WgpuRenderer::on_this_machine`), read back.
//!
//! Each picture is compared with the capture's (`measure`): the ink and
//! the dark pixels within [0.995, 1.005], and no channel more than 3 of
//! 255 off at scale 2, 21 at scale 1. The GPU's picture is also held to
//! the CPU's within 3 of 255 in every channel of every pixel, as
//! `render-gpu` holds them. Then the controls, which must miss: if one is
//! within, the check prints `WITHIN: the comparison cannot see it` and
//! fails.
//!
//! - (a) Linear light, on the CPU, against all five captures: it must miss
//!   each in the direction that is why macOS blends encoded, the light
//!   text on dark heavier (ink past 1.005) and the dark text on light
//!   lighter (ink under 0.995). A miss the other way fails too.
//! - (b) The old contrast, 0.1, blended encoded, against `sentence.png`.
//! - (c) For the record and not asserted: swash alone at the macOS
//!   setting, against each capture.
//!
//! Its exit status is 0 when everything holds, 1 when anything does not
//! (no GPU adapter among it), and 2 off macOS.

#[cfg_attr(
    not(target_os = "macos"),
    allow(
        dead_code,
        reason = "off macOS the check only says it cannot run; its tests run everywhere"
    )
)]
mod measure;
#[cfg(target_os = "macos")]
mod sentence;

#[cfg(target_os = "macos")]
fn main() -> std::process::ExitCode {
    if check::run() {
        std::process::ExitCode::SUCCESS
    } else {
        std::process::ExitCode::FAILURE
    }
}

#[cfg(not(target_os = "macos"))]
fn main() -> std::process::ExitCode {
    eprintln!("coretext: Core Text is on macOS alone");
    std::process::ExitCode::from(2)
}

#[cfg(target_os = "macos")]
mod check {
    use std::sync::Arc;

    use editor_layout::frame::Frame;
    use editor_raster_coretext::CoreTextRasterizer;
    use editor_render::port::{DrawRequest, Renderer, Target};
    use editor_render_wgpu::{HeadlessRenderer, Image, Settings, Weight, WgpuRenderer};

    use crate::measure::{Composited, Direction, compare, thresholds};
    use crate::sentence::{CAPTURES, Capture, frame};

    /// How far any channel of the GPU's picture may be from the CPU's: 3
    /// of 255, as `render-gpu` holds them.
    const GPU_TOLERANCE: u8 = 3;

    /// The Core Text rasteriser, smoothing on, as the captures were drawn.
    fn core_text() -> CoreTextRasterizer {
        CoreTextRasterizer::new(true)
    }

    /// What the headless renderer with `settings` draws of `frame` on
    /// `target`, its glyphs by Core Text when `by_core_text` says so and by
    /// swash alone otherwise.
    fn on_the_cpu(
        frame: &Arc<Frame>,
        target: Target,
        settings: Settings,
        by_core_text: bool,
    ) -> Image {
        let mut renderer = HeadlessRenderer::new(settings);
        if by_core_text {
            renderer = renderer.rasterizing_with(core_text());
        }
        renderer.draw(&DrawRequest { frame, target });
        renderer.image().clone()
    }

    /// A GPU renderer on this machine with the macOS setting and Core
    /// Text's glyphs, after it says what it is; `None`, said, when there
    /// is no adapter. Each capture is drawn by a renderer of its own, as
    /// on the CPU: the frames are built by hand, and a renderer would
    /// take one capture's row for another's.
    fn gpu() -> Option<WgpuRenderer> {
        #[expect(
            clippy::disallowed_methods,
            reason = "this check is run on demand on macOS, on this machine's GPU; no test calls it"
        )]
        let made = WgpuRenderer::on_this_machine(Settings::core_text());
        match made {
            Ok(renderer) => {
                let renderer = renderer.rasterizing_with(core_text());
                println!(
                    "coretext: the GPU renderer is on {}; it blends in {}; glyphs are drawn by {}",
                    renderer.adapter(),
                    renderer.blending(),
                    renderer.rasterizing()
                );
                Some(renderer)
            }
            Err(none) => {
                println!("coretext: {none}");
                None
            }
        }
    }

    /// What `renderer` draws of `frame` on `target`, read back; `None`,
    /// said, when the draw is refused.
    fn on_the_gpu(
        renderer: &mut WgpuRenderer,
        frame: &Arc<Frame>,
        target: Target,
    ) -> Option<Image> {
        let drawn = renderer.draw(&DrawRequest { frame, target });
        if !drawn.presented {
            println!(
                "coretext: the GPU's draw was refused: {}",
                renderer.refused().unwrap_or("no reason given")
            );
            return None;
        }
        Some(renderer.read_back())
    }

    /// `ours` against `capture`'s picture `theirs`, printed as `what`;
    /// `None`, said, when the two are not one size.
    fn measured(ours: &Image, theirs: &Image, capture: &Capture, what: &str) -> Option<Composited> {
        let compared = compare(ours, theirs, capture.colours);
        if compared.is_none() {
            println!(
                "coretext: {}: {what} is {} by {}, the capture {} by {}",
                capture.name, ours.width, ours.height, theirs.width, theirs.height
            );
        }
        compared
    }

    /// Whether `ours` is within the capture's thresholds, printed.
    fn held(ours: &Image, theirs: &Image, capture: &Capture, what: &str) -> bool {
        let Some(compared) = measured(ours, theirs, capture, what) else {
            return false;
        };
        let verdict = compared.within(thresholds(capture.scale));
        println!(
            "coretext: {}: {what}: {compared}: {}",
            capture.name,
            match &verdict {
                Ok(()) => "within".to_owned(),
                Err(missed) => format!("PAST: {missed}"),
            }
        );
        verdict.is_ok()
    }

    /// Whether a control missed the capture, and in the direction it must
    /// when one is given: printed.
    fn missed(
        ours: &Image,
        theirs: &Image,
        capture: &Capture,
        what: &str,
        way: Option<Direction>,
    ) -> bool {
        let Some(compared) = measured(ours, theirs, capture, what) else {
            return false;
        };
        let verdict = compared.within(thresholds(capture.scale));
        let direction = compared.direction();
        let right_way = way.is_none_or(|way| way == direction);
        println!(
            "coretext: {}: control, {what}: {compared}, {direction:?}: {}",
            capture.name,
            match (&verdict, right_way) {
                (Ok(()), _) => "WITHIN: the comparison cannot see it".to_owned(),
                (Err(missed), true) => format!("missed as it must: {missed}"),
                (Err(_), false) => format!("MISSED THE WRONG WAY: {way:?} was due"),
            }
        );
        verdict.is_err() && right_way
    }

    /// Runs the check: whether everything held.
    pub fn run() -> bool {
        let mut held_all = true;
        let linear = Settings {
            blending: editor_render_wgpu::Blending::Linear,
            ..Settings::core_text()
        };
        let old_contrast = Settings {
            weight: Weight {
                contrast: 0.1,
                ..Weight::CORE_TEXT
            },
            ..Settings::core_text()
        };
        for capture in &CAPTURES {
            let theirs = match Image::from_png(capture.bytes) {
                Ok(image) => image,
                Err(refused) => {
                    println!("coretext: {}: {refused}", capture.name);
                    held_all = false;
                    continue;
                }
            };
            let (frame, target) = match frame(capture, (theirs.width, theirs.height)) {
                Ok((frame, target)) => (Arc::new(frame), target),
                Err(refused) => {
                    println!("coretext: {}: {refused}", capture.name);
                    held_all = false;
                    continue;
                }
            };
            // 1. The CPU.
            let cpu = on_the_cpu(&frame, target, Settings::core_text(), true);
            held_all &= held(
                &cpu,
                &theirs,
                capture,
                "the CPU, encoded, Core Text's glyphs",
            );
            // 2. The GPU, against the capture and against the CPU.
            let mut gpu = gpu();
            held_all &= gpu.is_some();
            if let Some(renderer) = gpu.as_mut() {
                match on_the_gpu(renderer, &frame, target) {
                    Some(image) => {
                        held_all &= held(
                            &image,
                            &theirs,
                            capture,
                            "the GPU, encoded, Core Text's glyphs",
                        );
                        match image.difference(&cpu) {
                            Some((worst, differing)) => {
                                let within = worst <= GPU_TOLERANCE;
                                println!(
                                    "coretext: {}: the GPU against the CPU: {differing} pixels differ, the worst by {worst} of 255: {}",
                                    capture.name,
                                    if within { "within" } else { "PAST" }
                                );
                                held_all &= within;
                            }
                            None => {
                                println!(
                                    "coretext: {}: the GPU's picture is not the CPU's size",
                                    capture.name
                                );
                                held_all = false;
                            }
                        }
                    }
                    None => held_all = false,
                }
            }
            // (a) Linear light must miss, the way the reason for the
            // phase says.
            let way = if capture.light_on_dark() {
                Direction::Heavier
            } else {
                Direction::Lighter
            };
            let ours = on_the_cpu(&frame, target, linear, true);
            held_all &= missed(
                &ours,
                &theirs,
                capture,
                "the CPU in linear light",
                Some(way),
            );
            // (b) The old contrast, on the black on white.
            if capture.name == "sentence.png" {
                let ours = on_the_cpu(&frame, target, old_contrast, true);
                held_all &= missed(
                    &ours,
                    &theirs,
                    capture,
                    "the CPU at the old contrast of 0.1",
                    None,
                );
            }
            // (c) Swash alone, for the record.
            let ours = on_the_cpu(&frame, target, Settings::core_text(), false);
            if let Some(compared) = measured(&ours, &theirs, capture, "swash alone") {
                println!(
                    "coretext: {}: for the record, swash alone at the macOS setting: {compared}",
                    capture.name
                );
            }
        }
        println!(
            "coretext: {}",
            if held_all {
                "everything held"
            } else {
                "FAILED"
            }
        );
        held_all
    }
}
