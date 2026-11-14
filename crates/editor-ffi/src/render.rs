//! The render thread of a window: what the window tells whatever draws in
//! it, turned into demands on the render loop.
//!
//! The window port has a second listener, the drawer
//! (`editor_platform::Drawer`), and the render loop is reached through a
//! handle that only leaves word (`editor_render::render_loop`). This module
//! is the adapter from the one to the other, as [`crate::window`] is the
//! adapter from the port's report to the event queue. A [`Session`] is the
//! life of what draws in one window:
//!
//! | The window tells | The session |
//! |---|---|
//! | `Opened` | Makes the renderer, on the calling thread, with the native window and the size; makes the loop over it; starts the render thread, which runs the loop until it is stopped. Then leaves word of the size and of the refresh rate |
//! | `Resized` | `RenderHandle::resize`, with the size as a target |
//! | `Refresh` | `RenderHandle::set_refresh`, with the rate as an interval; nothing when the display does not say |
//! | `Damaged` | `RenderHandle::mark_dirty` |
//! | `Hidden` | `RenderHandle::set_hidden` |
//! | `Closing` | `RenderHandle::stop`; then joins the render thread and drops the renderer, on the calling thread |
//!
//! [`leave_word`] is the right-hand column but for making and ending the
//! thread, as one function over a handle, so that it is pinned on a loop
//! stepped by hand.
//!
//! # Threads
//!
//! The thread that runs the window tells the drawer, so it is the calling
//! thread above: the process's main thread. It makes the renderer, because
//! a surface on macOS must be made on the main thread, and it drops it,
//! before the window is gone. In between the renderer is the render
//! thread's alone, and the main thread only leaves word, which never
//! waits. It waits once, at `Closing`, for the render thread to end: for at
//! most the draw in progress.
//!
//! The render thread waits on the render loop's own park, a lock and a
//! condition variable, with no deadline when nothing is asked. Every word
//! left wakes it. Nothing it does has to wake the window's loop.
//!
//! # The clock
//!
//! The loop tells the time by a clock the session is given. The clock that
//! stamps the window's input is this crate's ([`crate::window::Monotonic`]),
//! and it is the render loop's clock too (`editor_render::clock::Clock` is
//! implemented for it here): the journal's time from an input to its frame
//! is then a subtraction on one clock.
//!
//! # A renderer that cannot be made
//!
//! The factory may fail: no adapter, no device. The window then runs as it
//! would with nothing drawing in it, every input still reaches the queue,
//! and [`Session::failure`] says why. Nothing is retried.
//!
//! # Where a test goes
//!
//! Which call each thing told becomes, and the two conversions, are pinned
//! here on a loop stepped by hand over `editor-render`'s published fakes.
//! That the thread starts, draws and ends is wiring, in
//! `tests/render_session.rs`, over the scripted platform. Neither states a
//! decision of the scheduler: what a call on the handle leads to is
//! `editor-render`'s, and is read here only by doing the same to two loops.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};

use editor_platform::{Canvas, Drawer, NativeWindow, Resize};
use editor_render::clock::Clock;
use editor_render::port::{Renderer, Target};
use editor_render::render_loop::{CondvarPark, RenderHandle, RenderLoop};

use crate::window::{CountingClock, InputClock, Monotonic};

impl Clock for Monotonic {
    fn now_ns(&self) -> u64 {
        InputClock::now_ns(self)
    }
}

impl Clock for CountingClock {
    fn now_ns(&self) -> u64 {
        InputClock::now_ns(self)
    }
}

/// The interval between two refreshes of a display that refreshes
/// `millihertz` thousandths of a hertz, in nanoseconds, to the nearest;
/// `None` for a rate of 0, which is no rate.
pub fn refresh_ns(millihertz: u32) -> Option<u64> {
    // A thousandth of a hertz is one refresh in a thousand seconds.
    const NS_AT_ONE_MILLIHERTZ: u64 = 1_000_000_000_000;
    let rate = u64::from(millihertz);
    (rate != 0).then(|| (NS_AT_ONE_MILLIHERTZ + rate / 2) / rate)
}

/// The target a window of `size` is: its width, its height and its scale.
/// A side too long for a target is as long as a target can be.
pub fn target(size: Resize) -> Target {
    let side = |length: u64| u32::try_from(length).unwrap_or(u32::MAX);
    Target {
        width: side(size.width),
        height: side(size.height),
        // A scale factor is a small number: nothing of it is lost.
        scale: size.scale as f32,
    }
}

/// Leaves with the loop behind `handle` the word that `canvas` is: the
/// table in the module docs, but for making the loop and ending its
/// thread, which are the session's.
///
/// The match on what a window tells is exhaustive on purpose. This crate
/// must act on every one of them: a thing a window says about its drawing
/// that reached no demand would be lost, and the window would show what it
/// showed before. A new variant has to be given its call here before the
/// crate builds.
pub fn leave_word(handle: &RenderHandle, canvas: &Canvas) {
    // A display that does not say how often it refreshes, or says 0,
    // leaves the loop's interval as it is.
    let paced = |rate: Option<u32>| {
        if let Some(interval) = rate.and_then(refresh_ns) {
            handle.set_refresh(interval);
        }
    };
    match canvas {
        Canvas::Opened {
            window: _,
            size,
            refresh_millihertz,
        } => {
            handle.resize(target(*size));
            paced(*refresh_millihertz);
        }
        Canvas::Resized(size) => handle.resize(target(*size)),
        Canvas::Refresh(rate) => paced(*rate),
        Canvas::Damaged => handle.mark_dirty(),
        Canvas::Hidden(hidden) => handle.set_hidden(*hidden),
        Canvas::Closing => handle.stop(),
    }
}

/// What makes a renderer for a window: handed the native window, when the
/// platform has one, and the target the window opened at. It answers the
/// renderer, or why there is none.
type Factory<R> = dyn Fn(Option<&NativeWindow>, Target) -> Result<R, String> + Send + Sync;

/// What draws in one window, for as long as the window is open: a renderer
/// of `R`, the loop over it, and the thread that runs the loop.
///
/// A clone is the same session.
pub struct Session<R> {
    /// What its clones and its drawer share.
    shared: Arc<Shared<R>>,
}

impl<R> Clone for Session<R> {
    fn clone(&self) -> Self {
        Self {
            shared: Arc::clone(&self.shared),
        }
    }
}

/// What a session's clones and its drawer share.
struct Shared<R> {
    /// What makes the renderer.
    make: Box<Factory<R>>,
    /// The clock the loop tells the time by.
    clock: Arc<dyn Clock>,
    /// What the session has made.
    state: Mutex<State<R>>,
}

/// What a session has made so far.
struct State<R> {
    /// The way to the loop, from when the window opened. It is kept after
    /// the window has closed, for the journal and the counters.
    handle: Option<RenderHandle>,
    /// The render thread, while it runs: it gives the renderer back.
    thread: Option<JoinHandle<R>>,
    /// Why nothing draws in the window, when nothing does.
    failure: Option<String>,
}

impl<R: Renderer + Send + 'static> Session<R> {
    /// A session that has made nothing yet. `make` is asked for a renderer
    /// when the window opens, on the thread that tells so, and the loop
    /// tells the time by `clock`.
    pub fn new(
        clock: Arc<dyn Clock>,
        make: impl Fn(Option<&NativeWindow>, Target) -> Result<R, String> + Send + Sync + 'static,
    ) -> Self {
        Self {
            shared: Arc::new(Shared {
                make: Box::new(make),
                clock,
                state: Mutex::new(State {
                    handle: None,
                    thread: None,
                    failure: None,
                }),
            }),
        }
    }

    /// The drawer to run the window with: it hands this session each thing
    /// the window tells.
    pub fn drawer(&self) -> Drawer {
        let session = self.clone();
        Arc::new(move |canvas| session.tell(&canvas))
    }

    /// The way to the render loop: to submit a frame, and to read the
    /// journal and the counters. `None` until the window has opened, and
    /// when the renderer could not be made. It is still there once the
    /// window has closed, when the loop no longer draws.
    pub fn handle(&self) -> Option<RenderHandle> {
        self.state().handle.clone()
    }

    /// Why nothing draws in the window, when nothing does: what the factory
    /// said, or that the render thread could not be started or did not end
    /// well.
    pub fn failure(&self) -> Option<String> {
        self.state().failure.clone()
    }

    /// Takes one thing the window tells: the table in the module docs.
    fn tell(&self, canvas: &Canvas) {
        if let Canvas::Opened { window, size, .. } = canvas {
            self.open(window.as_ref(), target(*size));
        }
        // Before the window has opened, and when no renderer could be
        // made, there is no loop to leave word with.
        if let Some(handle) = self.handle() {
            leave_word(&handle, canvas);
        }
        if matches!(canvas, Canvas::Closing) {
            self.close();
        }
    }

    /// Makes the renderer for `window`, on the calling thread, and the loop
    /// over it, drawing on `target`; and starts the render thread, which
    /// runs the loop until it is stopped and gives the renderer back. A
    /// session whose thread runs is left as it is.
    fn open(&self, window: Option<&NativeWindow>, target: Target) {
        if self.state().thread.is_some() {
            return;
        }
        let made = (self.shared.make)(window, target).and_then(|renderer| {
            let clock = Arc::clone(&self.shared.clock);
            let park = Arc::new(CondvarPark::new(Arc::clone(&clock)));
            let (render_loop, handle) = RenderLoop::new(renderer, clock, park, target);
            thread::Builder::new()
                .name("render".into())
                .spawn(move || render_loop.run())
                .map(|thread| (handle, thread))
                .map_err(|error| format!("the render thread could not be started: {error}"))
        });
        let mut state = self.state();
        match made {
            Ok((handle, thread)) => {
                state.handle = Some(handle);
                state.thread = Some(thread);
                state.failure = None;
            }
            Err(reason) => state.failure = Some(reason),
        }
    }

    /// Waits for the render thread, which has been told to stop, to end,
    /// and drops the renderer it gives back, on the calling thread.
    fn close(&self) {
        let thread = self.state().thread.take();
        let Some(thread) = thread else {
            return;
        };
        match thread.join() {
            // The renderer is let go here, on the thread that made it,
            // while the window it draws in is still there.
            Ok(renderer) => drop(renderer),
            Err(_) => {
                self.state().failure = Some("the render thread panicked".to_owned());
            }
        }
    }

    /// Locks what the session has made. The lock is never held while a
    /// renderer is made, a thread joined or a word left, so a poisoned
    /// lock still guards a whole value.
    fn state(&self) -> MutexGuard<'_, State<R>> {
        self.shared
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use editor_layout::Layout;
    use editor_layout::frame::Frame;
    use editor_layout::scene::{Rect, Scene};
    use editor_layout::shaper::fake::CellShaper;
    use editor_platform::{Canvas, Resize};
    use editor_render::clock::{Clock, FakeClock};
    use editor_render::fake::RecordingRenderer;
    use editor_render::port::Target;
    use editor_render::render_loop::{RecordingPark, RenderHandle, RenderLoop, Step};

    use super::{leave_word, refresh_ns, target};
    use crate::window::{CountingClock, InputClock, Monotonic};

    /// The size the loops begin at, and the target it is.
    const SIZE: Resize = Resize {
        width: 400,
        height: 300,
        scale: 1.0,
    };

    /// Another size.
    const LARGER: Resize = Resize {
        width: 800,
        height: 600,
        scale: 2.0,
    };

    /// A long time on the loop's clock: longer than any refresh interval a
    /// test sets or the loop begins with.
    const LONG: u64 = 10_000_000_000;

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

    /// What a loop did: each step it took, and the target of each draw it
    /// asked its renderer for.
    #[derive(Debug, PartialEq)]
    struct Did {
        /// The steps, in order.
        steps: Vec<Step>,
        /// The targets drawn on, in order.
        targets: Vec<Target>,
    }

    /// What a loop that shows a frame does once `word` has been left with
    /// it, over a fixed run of steps: one at once; one with the frame
    /// marked dirty; one a moment after that with it marked again, which
    /// shows how the loop paces; and one a long time on.
    ///
    /// Two words that lead to the same are the same word to the loop, and
    /// that is all a test here says of the loop: what a call on its handle
    /// leads to is `editor-render`'s to pin.
    fn after(word: impl FnOnce(&RenderHandle)) -> Did {
        let clock = FakeClock::new();
        let (mut render, handle) = RenderLoop::new(
            RecordingRenderer::new(),
            Arc::new(clock.clone()),
            Arc::new(RecordingPark::new()),
            target(SIZE),
        );
        handle.submit(frame_of("one"), None);
        let mut steps = vec![render.step()];
        clock.advance(LONG);

        word(&handle);
        steps.push(render.step());
        handle.mark_dirty();
        steps.push(render.step());
        clock.advance(1);
        handle.mark_dirty();
        steps.push(render.step());
        clock.advance(LONG);
        steps.push(render.step());
        let targets = render
            .renderer()
            .requests()
            .iter()
            .map(|request| request.target)
            .collect();
        Did { steps, targets }
    }

    /// What the loop does when no word is left.
    fn untold() -> Did {
        after(|_| {})
    }

    #[test]
    fn a_refresh_rate_in_millihertz_is_its_interval_in_nanoseconds() {
        assert_eq!(refresh_ns(60_000), Some(16_666_667));
        assert_eq!(refresh_ns(120_000), Some(8_333_333));
        assert_eq!(refresh_ns(50_000), Some(20_000_000));
        // A rate that is not a whole number of hertz, to the nearest.
        assert_eq!(refresh_ns(59_940), Some(16_683_350));
        assert_eq!(refresh_ns(1), Some(1_000_000_000_000));
        assert_eq!(refresh_ns(u32::MAX), Some(233));
        // No rate is no interval.
        assert_eq!(refresh_ns(0), None);
    }

    #[test]
    fn a_size_is_the_target_of_its_width_its_height_and_its_scale() {
        assert_eq!(
            target(LARGER),
            Target {
                width: 800,
                height: 600,
                scale: 2.0,
            }
        );
        assert_eq!(
            target(Resize {
                width: 1,
                height: 0,
                scale: 1.25,
            }),
            Target {
                width: 1,
                height: 0,
                scale: 1.25,
            }
        );
        // A side no target can be as long as is as long as one can be.
        let huge = target(Resize {
            width: u64::MAX,
            height: u64::from(u32::MAX) + 1,
            scale: 1.0,
        });
        assert_eq!((huge.width, huge.height), (u32::MAX, u32::MAX));
    }

    #[test]
    fn what_the_window_tells_is_what_the_loop_is_asked() {
        let told = |canvas: Canvas| after(|handle| leave_word(handle, &canvas));

        // A new size is the loop's new target.
        let resized = told(Canvas::Resized(LARGER));
        assert_eq!(resized, after(|handle| handle.resize(target(LARGER))));
        assert_ne!(resized, untold());

        // Damage is a dirty mark.
        let damaged = told(Canvas::Damaged);
        assert_eq!(damaged, after(RenderHandle::mark_dirty));
        assert_ne!(damaged, untold());

        // Hidden is hidden, and shown is shown.
        let hidden = told(Canvas::Hidden(true));
        assert_eq!(hidden, after(|handle| handle.set_hidden(true)));
        assert_ne!(hidden, untold());
        let shown = after(|handle| {
            handle.set_hidden(true);
            leave_word(handle, &Canvas::Hidden(false));
        });
        assert_eq!(shown, untold());

        // Closing stops the loop.
        let closing = told(Canvas::Closing);
        assert_eq!(closing, after(RenderHandle::stop));
        assert_ne!(closing, untold());

        // A window that opens says its size and its rate: both are left.
        let opened = told(Canvas::Opened {
            window: None,
            size: LARGER,
            refresh_millihertz: Some(50_000),
        });
        assert_eq!(
            opened,
            after(|handle| {
                handle.resize(target(LARGER));
                handle.set_refresh(20_000_000);
            })
        );
        // With no rate, the size alone.
        assert_eq!(
            told(Canvas::Opened {
                window: None,
                size: LARGER,
                refresh_millihertz: None,
            }),
            resized
        );
    }

    #[test]
    fn the_rate_the_window_tells_is_the_interval_the_loop_paces_by() {
        // 50 hertz is 20 milliseconds: a rate chosen here, and not the one
        // the loop begins with.
        let paced = after(|handle| leave_word(handle, &Canvas::Refresh(Some(50_000))));
        assert_eq!(paced, after(|handle| handle.set_refresh(20_000_000)));
        assert_ne!(paced, untold());
        // Another rate is another pace.
        assert_ne!(
            paced,
            after(|handle| leave_word(handle, &Canvas::Refresh(Some(100_000))))
        );
        // A display that does not say leaves the pace as it was.
        assert_eq!(
            after(|handle| leave_word(handle, &Canvas::Refresh(None))),
            untold()
        );
        // And so does a rate of nothing.
        assert_eq!(
            after(|handle| leave_word(handle, &Canvas::Refresh(Some(0)))),
            untold()
        );
    }

    #[test]
    fn telling_the_size_and_the_refresh_it_has_draws_nothing() {
        let clock = FakeClock::new();
        let (mut render, handle) = RenderLoop::new(
            RecordingRenderer::new(),
            Arc::new(clock.clone()),
            Arc::new(RecordingPark::new()),
            target(SIZE),
        );
        leave_word(&handle, &Canvas::Refresh(Some(50_000)));
        handle.submit(frame_of("one"), None);
        render.step();
        assert_eq!(render.renderer().requests().len(), 1);

        // The window says again what it said: the same size, the same rate.
        for _ in 0..3 {
            clock.advance(LONG);
            leave_word(&handle, &Canvas::Resized(SIZE));
            leave_word(&handle, &Canvas::Refresh(Some(50_000)));
            render.step();
        }
        assert_eq!(render.renderer().requests().len(), 1);
        assert_eq!(handle.counters().draws, 1);
    }

    #[test]
    fn the_render_loops_clock_is_the_clock_that_stamps_input() {
        // One clock read through both ports: each reading is the next.
        let counting = CountingClock::new();
        assert_eq!(Clock::now_ns(&counting), 1);
        assert_eq!(InputClock::now_ns(&counting), 2);
        assert_eq!(Clock::now_ns(&counting), 3);

        let real = Monotonic::new();
        let stamped = InputClock::now_ns(&real);
        let drawn = Clock::now_ns(&real);
        let stamped_again = InputClock::now_ns(&real);
        assert!(stamped > 0, "0 would read as no stamp");
        assert!(stamped <= drawn && drawn <= stamped_again);
    }
}
