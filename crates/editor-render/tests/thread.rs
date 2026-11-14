//! The render loop on a thread of its own, on the real park.
//!
//! Every rule of the loop is pinned on its `step`, by hand, in the crate's
//! unit tests. This is the one test that runs it as it is run: `run` on
//! another thread, parked on a lock and a condition variable, with a frame
//! submitted and the stop asked from this one. Nothing sleeps: a channel
//! from the renderer says a draw happened, and another that the loop
//! returned, each read with a bound so that a loop that never wakes fails
//! the test and hangs nothing.

use std::sync::Arc;
use std::sync::mpsc::{Sender, channel};
use std::time::Duration;

use editor_layout::Layout;
use editor_layout::frame::Frame;
use editor_layout::scene::{Rect, Scene};
use editor_layout::shaper::fake::CellShaper;
use editor_render::clock::FakeClock;
use editor_render::fake::RecordingRenderer;
use editor_render::port::{DrawRequest, Drawn, Renderer, Target};
use editor_render::render_loop::{CondvarPark, RenderLoop};

/// How long a word from the other thread is waited for before the test
/// fails.
const BOUND: Duration = Duration::from_secs(10);

/// The recording renderer, which also says on a channel that it drew.
struct Signalling {
    /// The fake.
    inner: RecordingRenderer,
    /// Where each draw is announced.
    drew: Sender<()>,
}

impl Renderer for Signalling {
    fn draw(&mut self, request: &DrawRequest<'_>) -> Drawn {
        let drawn = self.inner.draw(request);
        let _ = self.drew.send(());
        drawn
    }
}

/// The frame of `text` in one view, laid out on the fake shaper.
fn frame_of(text: &str) -> Arc<Frame> {
    let rect = Rect {
        x: 0,
        y: 0,
        width: 400,
        height: 300,
    };
    Arc::new(Layout::new(CellShaper::new(10.0, 16.0)).frame(&Scene::of_text(text, rect)))
}

#[test]
fn a_parked_loop_draws_a_frame_submitted_from_another_thread_and_stops_when_told() {
    let clock = Arc::new(FakeClock::new());
    let park = Arc::new(CondvarPark::new(clock.clone()));
    let (drew, draws) = channel();
    let renderer = Signalling {
        inner: RecordingRenderer::new(),
        drew,
    };
    let target = Target {
        width: 400,
        height: 300,
        scale: 1.0,
    };
    let (render, handle) = RenderLoop::new(renderer, clock, park, target);
    let (returned, renderers) = channel();
    std::thread::spawn(move || {
        let _ = returned.send(render.run());
    });

    // With nothing asked for, nothing is drawn: the loop is parked, or
    // about to be.
    assert!(draws.try_recv().is_err());
    let frame = frame_of("one\ntwo");
    handle.submit(Arc::clone(&frame), None);
    draws
        .recv_timeout(BOUND)
        .expect("the frame submitted from this thread is drawn");

    handle.stop();
    let renderer = renderers
        .recv_timeout(BOUND)
        .expect("the loop returns when it is told to stop");
    let requests = renderer.inner.requests();
    assert_eq!(requests.len(), 1);
    assert!(Arc::ptr_eq(&requests[0].frame, &frame));
    assert_eq!(handle.counters().draws, 1);
    assert_eq!(handle.journal().len(), 1);
}
