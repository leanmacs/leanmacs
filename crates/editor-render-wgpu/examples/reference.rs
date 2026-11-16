//! Makes the reference image again (`mise run render-reference`).
//!
//! On demand, never in the gate: the gate builds this example and never
//! runs it, and no test writes a file. It draws the fixture frame of
//! `tests/common/mod.rs` through the headless adapter, at scale 1 with
//! subpixel antialiasing, exactly as `tests/reference.rs` does, and writes
//! the picture as a PNG file to the path given on the command line:
//!
//! ```sh
//! cargo run --locked --package editor-render-wgpu --example reference -- tests/render/frame.png
//! ```
//!
//! `tests/render/README.md` says when to run it and what to do with the
//! result: look at it before it is committed.

use std::process::ExitCode;
use std::sync::Arc;

use editor_render::port::{DrawRequest, Renderer};
use editor_render_wgpu::HeadlessRenderer;

#[path = "../tests/common/mod.rs"]
mod common;

fn main() -> ExitCode {
    let Some(path) = std::env::args().nth(1) else {
        eprintln!("usage: reference <path of the PNG file to write>");
        return ExitCode::from(2);
    };
    let frame = Arc::new(common::fixture_frame());
    let mut renderer = HeadlessRenderer::new(common::settings());
    let drawn = renderer.draw(&DrawRequest {
        frame: &frame,
        target: common::TARGET,
    });
    let image = renderer.image();
    let bytes = match image.to_png() {
        Ok(bytes) => bytes,
        Err(reason) => {
            eprintln!("reference: cannot write {path}: {reason}");
            return ExitCode::FAILURE;
        }
    };
    #[expect(
        clippy::disallowed_methods,
        reason = "this example is the one place the reference image is written, on demand; no test writes a file"
    )]
    let written = std::fs::write(&path, &bytes);
    if let Err(error) = written {
        eprintln!("reference: cannot write {path}: {error}");
        return ExitCode::FAILURE;
    }
    println!(
        "reference: wrote {path}: {} by {} pixels, {} bytes; {} rows built, {} glyphs rasterised, {} skipped",
        image.width,
        image.height,
        bytes.len(),
        drawn.rows_rebuilt,
        drawn.glyphs_rasterised,
        drawn.glyphs_skipped
    );
    ExitCode::SUCCESS
}
