//! The Metal layer a window's renderer draws on, read on the real window
//! and held to the surface's configuration (`mise run window-layer`, its
//! second half; macOS only).
//!
//! It runs the real window through the port, with a drawer that, when the
//! window says it opened and on the main thread:
//!
//! 1. makes a `WgpuRenderer` on the window, with the settings the
//!    process's window draws with on macOS (`Settings::core_text()`);
//! 2. draws one frame laid out at the size the window opened at, with
//!    `Renderer::draw` and no render loop, and prints whether it was
//!    presented, which is not judged: a locked screen occludes the window,
//!    and the surface is configured before a texture is asked for all the
//!    same (`surface::State::acquire`);
//! 3. reads the layer (`WgpuRenderer::layer`) and holds it to
//!    `layer::misses` with the target of the size the window opened at,
//!    printing every field of the reading and each miss; and, as a control
//!    that must miss, to the same target at the other of the scales 1 and
//!    2, or it prints `WITHIN` and fails;
//! 4. sets the scale of the view layer the Metal layer follows to another
//!    and back (`WgpuRenderer::follow_scale`), and holds the Metal layer to
//!    following it both ways: the observation of a change of scale, seen
//!    on one display. The backing scale itself is not changed, which only
//!    a move to a display of another scale does;
//! 5. reads the layer again, which must miss nothing still;
//!
//! then asks the platform to close the window. It exits 0 with no miss, 1
//! with any, and 2 off macOS or when no window could be opened.

use std::process::ExitCode;
use std::sync::{Arc, Mutex, PoisonError};

use editor_ffi::render::target;
use editor_layout::Layout;
use editor_layout::frame::Frame;
use editor_layout::scene::{Rect, Scene};
use editor_layout::shaper::fake::CellShaper;
use editor_platform::{Canvas, NativeWindow, Platform, Resize, WindowOptions};
use editor_platform_winit::WinitPlatform;
use editor_render::port::{DrawRequest, Renderer, Target};
use editor_render_wgpu::layer::{self, Layer};
use editor_render_wgpu::{Settings, WgpuRenderer};

/// `main` runs on the process's main thread, and the platform is run from
/// `main`.
fn on_main_thread() -> bool {
    true
}

/// The window.
static PLATFORM: WinitPlatform = WinitPlatform::new(on_main_thread);

/// What the check came to: `None` until the window has opened, then
/// whether nothing missed.
static HELD: Mutex<Option<bool>> = Mutex::new(None);

/// A frame laid out for `target`: one view of text its size, at its scale.
fn frame_for(target: Target) -> Arc<Frame> {
    let rect = Rect {
        x: 0,
        y: 0,
        width: target.width,
        height: target.height,
    };
    let mut layout = Layout::new(CellShaper::new(8.0, 16.0));
    layout.set_scale(target.scale);
    Arc::new(layout.frame(&Scene::of_text("the window draws this", rect)))
}

/// Prints every field of `layer`'s reading, then each miss on `target`;
/// whether there was none.
fn judged(layer: &Layer, target: Target, when: &str) -> bool {
    let reading = &layer.reading;
    println!(
        "window-layer: {when}: bounds {} by {} points, contentsScale {}, drawable {} by {}, opaque {}, colour space {}, pixel format {} (configured {}), gravity {}",
        reading.bounds.0,
        reading.bounds.1,
        reading.contents_scale,
        reading.drawable.0,
        reading.drawable.1,
        reading.opaque,
        if reading.colorspace {
            "present"
        } else {
            "NONE"
        },
        reading.format,
        layer.configured,
        reading.gravity
    );
    let missed = layer::misses(layer, target);
    for miss in &missed {
        println!("window-layer: MISS: {when}: {miss}");
    }
    missed.is_empty()
}

/// The check, on the main thread, on the window that opened at `size`.
fn check(window: Option<&NativeWindow>, size: Resize) -> bool {
    let Some(window) = window else {
        println!("window-layer: the platform named no native window");
        return false;
    };
    let target = target(size);
    println!(
        "window-layer: the window opened at {} by {} pixels, scale {}",
        target.width, target.height, target.scale
    );
    // SAFETY: the window port tells of `window` when it opens, on this
    // thread, and it stays live until the drawer returns from being told
    // the window is closing; the renderer is dropped before this returns.
    #[expect(
        clippy::disallowed_methods,
        reason = "the layer check reads the layer of a renderer on the window, on demand; no test makes one"
    )]
    let made = unsafe { WgpuRenderer::on_window(window, Settings::core_text()) };
    let mut renderer = match made {
        Ok(renderer) => renderer,
        Err(none) => {
            println!("window-layer: no renderer on the window: {none}");
            return false;
        }
    };
    println!(
        "window-layer: the renderer is on {}; it blends in {}",
        renderer.adapter(),
        renderer.blending()
    );
    let drawn = renderer.draw(&DrawRequest {
        frame: &frame_for(target),
        target,
    });
    println!(
        "window-layer: the frame was presented: {}; hidden: {}; {}",
        drawn.presented,
        drawn.hidden,
        renderer.refused().unwrap_or("nothing refused")
    );
    let Some(read) = renderer.layer() else {
        println!("window-layer: MISS: the renderer's layer could not be read");
        return false;
    };
    let mut held = judged(&read, target, "after the draw");
    let other = if read.reading.contents_scale == 1.0 {
        2.0
    } else {
        1.0
    };
    // The control: the same reading held to the target at the other scale
    // must miss, or the rules cannot see a scale.
    let elsewhere = Target {
        scale: other as f32,
        ..target
    };
    let control = layer::misses(&read, elsewhere);
    if control.is_empty() {
        held = false;
        println!("window-layer: WITHIN: the reading held to scale {other} misses nothing");
    } else {
        let said: Vec<String> = control.iter().map(ToString::to_string).collect();
        println!(
            "window-layer: the control, held to scale {other}, misses as it must: {}",
            said.join("; ")
        );
    }
    match renderer.follow_scale(other) {
        Some(followed) => {
            println!(
                "window-layer: the view layer's scale {} set to {}: the Metal layer read {}; set back: it read {}",
                followed.before, followed.asked, followed.read, followed.back
            );
            if followed.holds() {
                println!("window-layer: the Metal layer followed the view layer's scale both ways");
            } else {
                held = false;
                println!(
                    "window-layer: MISS: the Metal layer did not follow the view layer's scale"
                );
            }
        }
        None => {
            held = false;
            println!("window-layer: MISS: the view layer's scale could not be set");
        }
    }
    match renderer.layer() {
        Some(again) => held &= judged(&again, target, "after the scale was set back"),
        None => held = false,
    }
    println!(
        "window-layer: the reading is at the scale the window opened at, {}; the backing scale itself did not change",
        target.scale
    );
    held
}

fn main() -> ExitCode {
    if !cfg!(target_os = "macos") {
        println!("window-layer: macOS only");
        return ExitCode::from(2);
    }
    let drawer = Arc::new(|canvas: Canvas| {
        if let Canvas::Opened { window, size, .. } = canvas {
            let held = check(window.as_ref(), size);
            *HELD.lock().unwrap_or_else(PoisonError::into_inner) = Some(held);
            PLATFORM.close();
        }
    });
    if let Err(cannot) = PLATFORM.run(WindowOptions::default(), Arc::new(|_| {}), drawer) {
        println!("window-layer: no window could be opened: {cannot:?}");
        return ExitCode::from(2);
    }
    match *HELD.lock().unwrap_or_else(PoisonError::into_inner) {
        None => {
            println!("window-layer: the window never said it opened");
            ExitCode::from(2)
        }
        Some(true) => {
            println!(
                "window-layer: the layer is drawn pixel for pixel, opaque, with a colour space and the configured format"
            );
            ExitCode::SUCCESS
        }
        Some(false) => ExitCode::FAILURE,
    }
}
