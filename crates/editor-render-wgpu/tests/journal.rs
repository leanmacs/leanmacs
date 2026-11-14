//! The frame journal of a loop over the headless adapter, on a fake
//! clock.
//!
//! This is wiring: what an entry holds and when one is written is the
//! render loop's rule, pinned in `editor-render` on its fake. Here the
//! loop drives the real adapter, and the test reads the journal.
//!
//! The frames are of layout's fake shaper: a journal needs no glyph.

use std::sync::Arc;

use editor_layout::Layout;
use editor_layout::frame::Frame;
use editor_layout::scene::{Rect, Scene};
use editor_layout::shaper::fake::CellShaper;
use editor_render::clock::{Clock, FakeClock};
use editor_render::port::Target;
use editor_render::render_loop::{RecordingPark, RenderHandle, RenderLoop, Step};
use editor_render_wgpu::{HeadlessRenderer, Settings};

/// The refresh interval the loops here are told.
const REFRESH: u64 = 1000;

/// The target the loops draw on.
const TARGET: Target = Target {
    width: 120,
    height: 48,
    scale: 1.0,
};

/// The frame of `text` in one view the size of the target, laid out on
/// the fake shaper.
fn frame_of(text: &str) -> Arc<Frame> {
    let rect = Rect {
        x: 0,
        y: 0,
        width: TARGET.width,
        height: TARGET.height,
    };
    Arc::new(Layout::new(CellShaper::new(10.0, 16.0)).frame(&Scene::of_text(text, rect)))
}

/// A loop over the headless adapter on `clock`.
fn rig(clock: &FakeClock) -> (RenderLoop<HeadlessRenderer>, RenderHandle) {
    let (render, handle) = RenderLoop::new(
        HeadlessRenderer::new(Settings::default()),
        Arc::new(clock.clone()),
        Arc::new(RecordingPark::new()),
        TARGET,
    );
    handle.set_refresh(REFRESH);
    (render, handle)
}

#[test]
fn every_frame_drawn_has_an_entry_with_its_three_stamps() {
    // A clock that moves on at every reading: no two stamps are the same.
    let clock = FakeClock::stepping(1);
    let (mut render, handle) = rig(&clock);
    let mut stamps = Vec::new();
    for text in ["one", "two", "three"] {
        // The input's stamp, read from the clock by whoever publishes.
        let stamp = clock.now_ns();
        stamps.push(stamp);
        handle.submit(frame_of(text), Some(stamp));
        let step = render.step();
        assert!(matches!(step, Step::Drew(_)), "{step:?}");
        clock.advance(REFRESH);
    }
    let journal = handle.journal();
    assert_eq!(journal.len(), 3);
    for (entry, stamp) in journal.iter().zip(&stamps) {
        assert_eq!(entry.input_ns, *stamp);
        assert!(entry.input_ns < entry.draw_ns, "{entry:?}");
        assert!(entry.draw_ns < entry.present_ns, "{entry:?}");
    }
    // In the order they were drawn.
    assert!(
        journal
            .windows(2)
            .all(|pair| pair[0].present_ns < pair[1].input_ns)
    );
    assert_eq!(handle.counters().draws, 3);
}

#[test]
fn an_idle_period_adds_no_entry() {
    let clock = FakeClock::stepping(1);
    let (mut render, handle) = rig(&clock);
    handle.submit(frame_of("one"), None);
    assert!(matches!(render.step(), Step::Drew(_)));
    let before = (handle.journal(), handle.counters());
    assert_eq!(before.0.len(), 1);
    // A second goes by, a step at a time, with nothing asked for.
    for _ in 0..100 {
        clock.advance(10_000_000);
        assert_eq!(render.step(), Step::Wait(None));
    }
    assert_eq!((handle.journal(), handle.counters()), before);
}
