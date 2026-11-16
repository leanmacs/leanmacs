//! The render thread of a window, as it is wired: a platform run onto a
//! queue with a session as its drawer, the loop on a thread of its own.
//!
//! Which call each thing a window tells becomes is pinned in
//! `src/render.rs`, on a loop stepped by hand. These tests cover what only
//! the wiring shows: that the session makes a renderer when the window
//! opens, that a frame submitted then is drawn on the window's target and
//! again when the window is resized, that nothing else is drawn, and that
//! at closing the thread has ended and the renderer was dropped on the
//! thread that ran the window. Both halves of the window are there: what
//! it reports arrives on the queue while what it tells reaches the loop.
//!
//! Every window is the scripted platform's and every renderer the
//! recording fake, watched: nothing opens, and nothing is drawn. Nothing
//! sleeps to wait for something to happen. The renderer says on a channel
//! that it drew, and each word is read with a bound, so a loop that never
//! wakes fails the test and hangs nothing. The loop's clock is the fake
//! one, moved on by the test: the loop paces its draws by it, and a test
//! that waited for real time to pass would be waiting on a default this
//! crate does not own.
//!
//! What is read of the loop is its counters and its journal's length,
//! through its handle. No decision of the scheduler is stated.

use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread::{self, ThreadId};
use std::time::Duration;

use editor_ffi::events::{EventKind, Queue};
use editor_ffi::interrupt::Interrupt;
use editor_ffi::render::{Presenter, Session, target};
use editor_ffi::window::{self, CountingClock};
use editor_layout::Layout;
use editor_layout::frame::Frame;
use editor_layout::scene::{Rect, Scene};
use editor_layout::shaper::fake::CellShaper;
use editor_platform::{
    CannotOpen, Canvas, Drawer, Input, Platform, Resize, ScriptedPlatform, WindowOptions,
};
use editor_render::clock::FakeClock;
use editor_render::fake::RecordingRenderer;
use editor_render::port::{DrawRequest, Drawn, Renderer, Target};

/// How long a word from another thread is waited for before the test
/// fails.
const BOUND: Duration = Duration::from_secs(10);

/// A long time on the loop's clock: longer than the loop waits between two
/// draws, whatever its interval.
const LONG: u64 = 10_000_000_000;

/// A size a script resizes the window to.
const RESIZED: Resize = Resize {
    width: 800,
    height: 600,
    scale: 2.0,
    fullscreen: false,
};

/// What a watched renderer says of itself.
#[derive(Debug, PartialEq)]
enum Word {
    /// It was asked to draw on this target.
    Drew(Target),
    /// It was dropped, on this thread.
    Dropped(ThreadId),
}

/// The recording renderer, which also says on a channel what it drew on and
/// where it was dropped.
struct Watched {
    /// The fake.
    inner: RecordingRenderer,
    /// Where it says what it did, for the test.
    says: Sender<Word>,
    /// Where it says that it drew, for whoever waits for a draw.
    drew: Sender<()>,
}

impl Renderer for Watched {
    fn draw(&mut self, request: &DrawRequest<'_>) -> Drawn {
        let drawn = self.inner.draw(request);
        let _ = self.says.send(Word::Drew(request.target));
        let _ = self.drew.send(());
        drawn
    }
}

impl Drop for Watched {
    fn drop(&mut self) {
        let _ = self.says.send(Word::Dropped(thread::current().id()));
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

/// What the factory of a session under test was handed: whether there was
/// a native window, and the target.
type Asked = Arc<Mutex<Vec<(bool, Target)>>>;

/// A session under test, over watched renderers.
struct Rig {
    /// The session.
    session: Session<Watched>,
    /// The loop's clock.
    clock: FakeClock,
    /// What the session's renderers say.
    words: Receiver<Word>,
    /// What the factory was handed, each time it was asked.
    asked: Asked,
}

/// A session whose factory makes watched renderers, and where each of
/// their draws is announced.
fn rig() -> (Rig, Receiver<()>) {
    let clock = FakeClock::new();
    let (says, words) = channel();
    let (drew, draws) = channel();
    let asked = Asked::default();
    let session = {
        let asked = Arc::clone(&asked);
        // The factory is shared between threads, so what it hands each
        // renderer is behind a lock.
        let senders = Mutex::new((says, drew));
        Session::new(
            Arc::new(clock.clone()),
            move |window, target| {
                asked
                    .lock()
                    .expect("nothing panics holding it")
                    .push((window.is_some(), target));
                let (says, drew) = senders.lock().expect("nothing panics holding it").clone();
                Ok(Watched {
                    inner: RecordingRenderer::new(),
                    says,
                    drew,
                })
            },
            Presenter::new(),
        )
    };
    let rig = Rig {
        session,
        clock,
        words,
        asked,
    };
    (rig, draws)
}

impl Rig {
    /// The next thing a renderer says; panics if it says nothing by the
    /// bound.
    fn next_word(&self) -> Word {
        self.words
            .recv_timeout(BOUND)
            .expect("the renderer says its next thing")
    }
}

/// The drawer of an editor that publishes `frame` the moment the window
/// opens and waits for it to be shown before the window goes on: the
/// session's drawer, with that done after it is told the window opened.
/// What the window says next therefore finds a frame shown, whatever the
/// threads' timing, and finds it long after that draw on the loop's clock,
/// so that the loop's pacing holds nothing back.
fn publishing_at_open(rig: &Rig, frame: Arc<Frame>, draws: Receiver<()>) -> Drawer {
    let drawer = rig.session.drawer();
    let session = rig.session.clone();
    let clock = rig.clock.clone();
    let draws = Mutex::new(draws);
    Arc::new(move |canvas| {
        let opened = matches!(canvas, Canvas::Opened { .. });
        drawer(canvas);
        if opened {
            let handle = session.handle().expect("an open window has a loop");
            handle.submit(Arc::clone(&frame), None);
            draws
                .lock()
                .expect("nothing panics holding it")
                .recv_timeout(BOUND)
                .expect("the frame is drawn");
            clock.advance(LONG);
        }
    })
}

/// Runs `platform` onto `queue` on a thread of its own, with `drawer`, and
/// gives where the run's result and its thread's id arrive.
fn run_on_a_thread(
    platform: &Arc<ScriptedPlatform>,
    queue: &Arc<Queue>,
    drawer: Drawer,
) -> Receiver<(Result<(), CannotOpen>, ThreadId)> {
    let (finished, done) = channel();
    let (platform, queue) = (Arc::clone(platform), Arc::clone(queue));
    thread::spawn(move || {
        let options = WindowOptions::default();
        // A flag of its own with no interrupt key: nothing raises it.
        let interrupt = Arc::new(Interrupt::new());
        let clock = CountingClock::new();
        let result = window::run(&*platform, options, clock, queue, interrupt, drawer);
        let _ = finished.send((result, thread::current().id()));
    });
    done
}

/// The kinds of the next `count` events of `queue`; panics if they do not
/// arrive by the bound.
fn kinds(queue: &Arc<Queue>, count: usize) -> Vec<EventKind> {
    let (pulled, events) = channel();
    let queue = Arc::clone(queue);
    thread::spawn(move || {
        for _ in 0..count {
            let _ = pulled.send(queue.next().kind);
        }
    });
    (0..count)
        .map(|_| {
            events
                .recv_timeout(BOUND)
                .expect("the window's next event reaches the queue")
        })
        .collect()
}

#[test]
fn the_scripted_window_draws_once_for_its_frame_and_once_for_its_resize() {
    let (rig, draws) = rig();
    let script = vec![Input::Focus(true), Input::Resized(RESIZED)];
    let platform = Arc::new(ScriptedPlatform::new(script));
    let queue = Arc::new(Queue::new());
    let drawer = publishing_at_open(&rig, frame_of("one\ntwo"), draws);

    let done = run_on_a_thread(&platform, &queue, drawer);

    // The frame was drawn on the size the window opened at.
    assert_eq!(rig.next_word(), Word::Drew(target(ScriptedPlatform::SIZE)));
    // The window was resized: the frame shown is drawn again, on the new
    // size.
    assert_eq!(rig.next_word(), Word::Drew(target(RESIZED)));
    // Meanwhile what the window reported arrived on the queue.
    assert_eq!(
        kinds(&queue, 3),
        [
            EventKind::WindowOpened,
            EventKind::WindowFocus,
            EventKind::Resize
        ]
    );

    // Nothing more is drawn, however long the window stays open: the
    // loop's clock moves on a long way and nothing is asked.
    rig.clock.advance(LONG);
    platform.close();
    let (result, _) = done.recv_timeout(BOUND).expect("the run returns");
    assert_eq!(result, Ok(()));
    // The next thing the renderer says is that it was dropped: there was no
    // third draw.
    assert!(matches!(rig.next_word(), Word::Dropped(_)));
    let handle = rig
        .session
        .handle()
        .expect("the handle outlives the window");
    assert_eq!(handle.counters().draws, 2);
    assert_eq!(handle.journal().len(), 2);
    assert_eq!(rig.session.failure(), None);
    // The factory was asked once, with no native window, for the size the
    // window opened at.
    assert_eq!(
        *rig.asked.lock().expect("nothing panics holding it"),
        [(false, target(ScriptedPlatform::SIZE))]
    );
}

#[test]
fn when_the_window_closes_the_render_thread_has_ended_and_the_renderer_is_dropped_where_it_was_made()
 {
    let (rig, draws) = rig();
    let platform = Arc::new(ScriptedPlatform::new(Vec::new()));
    let queue = Arc::new(Queue::new());
    let drawer = publishing_at_open(&rig, frame_of("one"), draws);

    let done = run_on_a_thread(&platform, &queue, drawer);
    assert!(matches!(rig.next_word(), Word::Drew(_)));
    assert_eq!(kinds(&queue, 1), [EventKind::WindowOpened]);
    platform.close();

    let (result, window_thread) = done.recv_timeout(BOUND).expect("the run returns");
    assert_eq!(result, Ok(()));
    // The renderer was given back by the loop, so the loop had returned and
    // its thread was at its end; and it was dropped on the thread that ran
    // the window, which is the one that made it, before the run returned:
    // the word is already there.
    assert_eq!(rig.words.try_recv(), Ok(Word::Dropped(window_thread)));
    assert_ne!(window_thread, thread::current().id());

    // A frame submitted to a window that has closed is drawn by nobody.
    let handle = rig
        .session
        .handle()
        .expect("the handle outlives the window");
    handle.submit(frame_of("two"), None);
    rig.clock.advance(LONG);
    assert_eq!(handle.counters().draws, 1);
    assert!(rig.words.try_recv().is_err());
}

#[test]
fn a_session_has_no_loop_before_its_window_opens() {
    let (rig, _draws) = rig();
    assert!(rig.session.handle().is_none());
    assert_eq!(rig.session.failure(), None);
    // What a window says before it has opened, which a window that keeps
    // the port's contract never does, is said to nobody.
    let drawer = rig.session.drawer();
    drawer(Canvas::Damaged);
    drawer(Canvas::Closing);
    assert!(rig.session.handle().is_none());
    assert!(
        rig.asked
            .lock()
            .expect("nothing panics holding it")
            .is_empty()
    );
}

/// The window opened, with no native window, at the scripted platform's
/// size.
fn opened() -> Canvas {
    Canvas::Opened {
        window: None,
        size: ScriptedPlatform::SIZE,
        refresh_millihertz: None,
    }
}

#[test]
fn a_window_that_says_again_that_it_opened_keeps_the_renderer_it_has() {
    let (rig, _draws) = rig();
    let drawer = rig.session.drawer();
    drawer(opened());
    drawer(opened());
    drawer(Canvas::Closing);
    // One renderer was made, and it was the one dropped.
    assert_eq!(
        rig.asked.lock().expect("nothing panics holding it").len(),
        1
    );
    assert_eq!(rig.next_word(), Word::Dropped(thread::current().id()));
    assert!(rig.words.try_recv().is_err());

    // Once it has closed, a window that opens again is given a new one.
    drawer(opened());
    drawer(Canvas::Closing);
    assert_eq!(
        rig.asked.lock().expect("nothing panics holding it").len(),
        2
    );
    assert_eq!(rig.next_word(), Word::Dropped(thread::current().id()));
}

/// A renderer that cannot draw at all: it says that it was asked to, and
/// panics.
struct Broken {
    /// Where it says it was asked to draw.
    asked: Sender<()>,
}

impl Renderer for Broken {
    fn draw(&mut self, _: &DrawRequest<'_>) -> Drawn {
        let _ = self.asked.send(());
        panic!("this renderer is broken on purpose: the test expects this panic");
    }
}

#[test]
fn a_render_thread_that_panicked_is_a_reason_and_the_window_still_closes() {
    let (asked, draws) = channel();
    let asked = Mutex::new(asked);
    let session: Session<Broken> = Session::new(
        Arc::new(FakeClock::new()),
        move |_, _| {
            Ok(Broken {
                asked: asked.lock().expect("nothing panics holding it").clone(),
            })
        },
        Presenter::new(),
    );
    let drawer = session.drawer();
    drawer(opened());
    let handle = session.handle().expect("an open window has a loop");
    assert_eq!(session.failure(), None);
    // The draw panics, on the render thread.
    handle.submit(frame_of("one"), None);
    draws.recv_timeout(BOUND).expect("the renderer is asked");
    // Closing waits for that thread all the same, and neither hangs nor
    // panics here.
    drawer(Canvas::Closing);
    assert_eq!(
        session.failure().as_deref(),
        Some("the render thread panicked")
    );
}

#[test]
fn a_factory_that_fails_leaves_a_window_that_runs_and_a_reason() {
    let session: Session<Watched> = Session::new(
        Arc::new(FakeClock::new()),
        |_, _| Err("no adapter: pas de carte".to_owned()),
        Presenter::new(),
    );
    let script = vec![Input::Focus(true), Input::Resized(RESIZED)];
    let platform = Arc::new(ScriptedPlatform::new(script));
    let queue = Arc::new(Queue::new());

    let done = run_on_a_thread(&platform, &queue, session.drawer());

    // The window runs: everything it reports reaches the queue.
    assert_eq!(
        kinds(&queue, 3),
        [
            EventKind::WindowOpened,
            EventKind::WindowFocus,
            EventKind::Resize
        ]
    );
    platform.close();
    let (result, _) = done.recv_timeout(BOUND).expect("the run returns");
    assert_eq!(result, Ok(()));
    // Nothing draws in it, and the session says why.
    assert!(session.handle().is_none());
    assert_eq!(
        session.failure().as_deref(),
        Some("no adapter: pas de carte")
    );
}
