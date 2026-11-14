//! The render loop over the headless adapter, on real text: what is not
//! done twice.
//!
//! This is wiring. That a frame submitted again is no demand is the
//! loop's rule, pinned in `editor-render` on its fake; that a row whose
//! hash is held is not built again is the row cache's, pinned there; that
//! a kept row asks the rasteriser nothing is the painter's, pinned in
//! this crate on a fake rasteriser. Here the three are put together with
//! the real shaper and the real rasteriser, and what is read is the
//! loop's own counters.

mod common;

use std::sync::Arc;

use editor_layout::frame::Frame;
use editor_render::clock::FakeClock;
use editor_render::journal::Counters;
use editor_render::render_loop::{RecordingPark, RenderHandle, RenderLoop, Step};
use editor_render_wgpu::HeadlessRenderer;

/// The refresh interval the loops here are told.
const REFRESH: u64 = 1000;

/// A loop over the headless adapter, on a clock the test moves.
fn rig() -> (RenderLoop<HeadlessRenderer>, RenderHandle, FakeClock) {
    let clock = FakeClock::new();
    let (render, handle) = RenderLoop::new(
        HeadlessRenderer::new(common::settings()),
        Arc::new(clock.clone()),
        Arc::new(RecordingPark::new()),
        common::TARGET,
    );
    handle.set_refresh(REFRESH);
    (render, handle, clock)
}

/// Submits `frame` and steps the loop once, a refresh after its last
/// draw: what the step did, and the counters after it.
fn submit(
    rig: &mut (RenderLoop<HeadlessRenderer>, RenderHandle, FakeClock),
    frame: &Arc<Frame>,
) -> (Step, Counters) {
    let (render, handle, clock) = rig;
    clock.advance(REFRESH);
    handle.submit(Arc::clone(frame), None);
    let step = render.step();
    (step, handle.counters())
}

#[test]
fn the_same_frame_again_is_not_drawn() {
    let mut rig = rig();
    // One layout, as an editor has: the scene laid out, and laid out
    // again.
    let mut layout = common::layout();
    let scene = common::scene_of(common::TEXT, common::SELECTED);
    let frame = Arc::new(layout.frame(&scene));
    let (first, drawn) = submit(&mut rig, &frame);
    assert!(matches!(first, Step::Drew(_)), "{first:?}");
    assert_eq!(drawn.draws, 1);
    // The same value, then an equal frame laid out again. Neither step
    // draws; what such a step answers instead is the loop's to say.
    let (again, counters) = submit(&mut rig, &frame);
    assert!(!matches!(again, Step::Drew(_)), "{again:?}");
    assert_eq!(counters.draws, 1);
    let equal = Arc::new(layout.frame(&scene));
    assert!(!Arc::ptr_eq(&equal, &frame));
    let (again, counters) = submit(&mut rig, &equal);
    assert!(!matches!(again, Step::Drew(_)), "{again:?}");
    // The draw counter stays where it was, and so does every count of
    // work.
    assert_eq!(
        Counters {
            frames_submitted: drawn.frames_submitted,
            ..counters
        },
        drawn
    );
}

#[test]
fn moving_the_cursor_on_real_text_rebuilds_no_row_and_rasterises_no_glyph() {
    let mut rig = rig();
    // One layout for both frames, as an editor has: the same text with a
    // cursor on the first row, then on the second.
    let mut layout = common::layout();
    let mut frame_at =
        |cursor: usize| Arc::new(layout.frame(&common::scene_of(common::TEXT, cursor..cursor)));
    let (first, second) = (frame_at(1), frame_at(20));
    assert_ne!(first.views[0].cursors, second.views[0].cursors);

    let (step, before) = submit(&mut rig, &first);
    assert!(matches!(step, Step::Drew(_)), "{step:?}");
    assert!(before.rows_rebuilt > 0 && before.glyphs_rasterised > 0);

    let (step, after) = submit(&mut rig, &second);
    assert!(matches!(step, Step::Drew(_)), "{step:?}");
    // It was drawn, and the rows-rebuilt counter stays where it was: so
    // does the count of glyphs rasterised.
    assert_eq!(after.draws, before.draws + 1);
    assert_eq!(after.rows_rebuilt, before.rows_rebuilt);
    assert_eq!(after.glyphs_rasterised, before.glyphs_rasterised);
    assert!(after.rows_reused > before.rows_reused);
    // And the picture changed: the cursor is drawn where it now is.
    let moved = rig.0.renderer().image().clone();
    let (_, _) = submit(&mut rig, &first);
    assert_ne!(rig.0.renderer().image(), &moved);
}
