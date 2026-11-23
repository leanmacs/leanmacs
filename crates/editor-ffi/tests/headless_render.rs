//! The headless render session, as it is wired: a loop on a thread of its
//! own over a renderer the session makes, whose frames are what a bound
//! display publishes, on a target the size of each scene, at scale 1.
//!
//! This is the constructor `editor_ffi_render_headless_start` calls with
//! the CPU renderer, the process's clock and the process's presenter. Here
//! it is handed a fresh presenter, the recording renderer, watched, and
//! `editor-render`'s fake clock, so nothing here reaches a process-wide
//! value and the tests may run on parallel threads.
//!
//! Wiring only, in `tests/render_session.rs`'s form: nothing sleeps or
//! polls, each word from the render thread, and its rest
//! (`RenderHandle::wait_resting`), is waited for on its own signal with a
//! bound that is a hang guard, and no rule of the scheduler is stated.
//! That an equal frame draws nothing, and that a loop at rest draws
//! nothing, are `editor-render`'s, pinned there.

use std::io;
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use editor_wait::HangGuard;

use editor_ffi::display::{Display, WireScene, WireView};
use editor_ffi::document::Document;
use editor_ffi::render::{HeadlessRefusal, Presenter, headless, headless_with, start_into};
use editor_ffi::snapshot::Snapshot;
use editor_render::clock::FakeClock;
use editor_render::fake::RecordingRenderer;
use editor_render::port::{DrawRequest, Drawn, Renderer, Target};

/// hang guard: a word from the render thread, or its rest; only a hang
/// reaches the bound, and the test then fails as a hang.
const BOUND: HangGuard = HangGuard::on(
    "a word from the render thread, or its rest",
    Duration::from_secs(10),
);

/// The recording renderer, which also says on a channel the target of each
/// draw.
struct Watched {
    /// The fake.
    inner: RecordingRenderer,
    /// Where it says it drew, and on what.
    drew: Sender<Target>,
}

impl Renderer for Watched {
    fn draw(&mut self, request: &DrawRequest<'_>) -> Drawn {
        let drawn = self.inner.draw(request);
        let _ = self.drew.send(request.target);
        drawn
    }
}

/// Publishes to `display` a scene `width` by `height` of one view of
/// `snapshot` across it.
fn publish(display: &Display, snapshot: &Snapshot, width: u64, height: u64) {
    let wire = WireScene {
        size: [width, height],
        views: vec![WireView {
            id: 1,
            rect: [0, 0, width, height],
            snapshot: Some(0),
            ..WireView::default()
        }],
        ..WireScene::default()
    };
    let (words, strings) = wire.encode();
    assert!(display.publish(&words, &strings, &[snapshot]));
}

#[test]
fn a_bound_displays_frame_is_drawn_at_the_scenes_size_with_its_stamp_and_the_loop_rests() {
    let presenter = Presenter::new();
    let (drew, draws) = channel();
    let session = headless(
        move || Watched {
            inner: RecordingRenderer::new(),
            drew,
        },
        Arc::new(FakeClock::new()),
        Arc::clone(&presenter),
    )
    .expect("the render thread starts");
    let handle = session.handle();
    // The session is the presenter's target, and its last.
    assert!(
        presenter
            .target()
            .is_some_and(|target| target.same(&handle))
    );
    assert!(presenter.last().is_some_and(|last| last.same(&handle)));

    let display = Display::cells(8, 16);
    display.present_to(Arc::clone(&presenter));
    let document = Document::new("one\ntwo");
    let snapshot = Snapshot::of(&document);
    presenter.answering().note(1234);
    publish(&display, &snapshot, 640, 480);
    let target = editor_wait::recv(&draws, BOUND).expect("the frame is drawn");
    assert_eq!(
        target,
        Target {
            width: 640,
            height: 480,
            scale: 1.0,
        }
    );
    assert!(handle.wait_resting(BOUND), "the loop comes to rest");
    let journal = handle.journal();
    assert_eq!(journal.len(), 1);
    assert_eq!(journal[0].input_ns, 1234);

    // A display that is not bound reaches nothing.
    let submitted = handle.counters().frames_submitted;
    publish(&Display::cells(8, 16), &snapshot, 640, 480);
    assert_eq!(handle.counters().frames_submitted, submitted);

    // Stopped: the presenter has no target, and the last session's
    // handle still reads its journal and its counters.
    session.stop();
    assert!(presenter.target().is_none());
    let last = presenter.last().expect("the last session's handle");
    assert_eq!(last.journal().len(), 1);
    assert_eq!(last.counters().draws, 1);
    assert!(draws.try_recv().is_err());
}

/// A spawner of the render thread that cannot start one, as a process out
/// of threads gives: no hermetic test can make the real one fail.
fn no_thread(
    _: Box<dyn FnOnce() -> RecordingRenderer + Send>,
) -> io::Result<JoinHandle<RecordingRenderer>> {
    Err(io::Error::other("no more threads"))
}

/// What a session whose render thread cannot start says.
const NO_THREAD: &str = "the render thread could not be started: no more threads";

#[test]
fn a_render_thread_that_cannot_be_started_is_a_reason_and_leaves_the_presenter_as_it_was() {
    let presenter = Presenter::new();
    let refused = headless_with(
        RecordingRenderer::new,
        Arc::new(FakeClock::new()),
        Arc::clone(&presenter),
        no_thread,
    );
    assert_eq!(refused.err().as_deref(), Some(NO_THREAD));
    // Nothing is the presenter's target, nor its last session.
    assert!(presenter.target().is_none());
    assert!(presenter.last().is_none());
}

#[test]
fn a_slot_starts_one_session_and_refuses_another_while_it_runs_or_one_whose_thread_cannot_start() {
    let presenter = Presenter::new();
    let clock = Arc::new(FakeClock::new());
    let slot = Mutex::new(None);
    // A thread that cannot start: refused with its reason, and the slot
    // stays empty.
    let failed = start_into(&slot, || {
        headless_with(
            RecordingRenderer::new,
            clock.clone(),
            Arc::clone(&presenter),
            no_thread,
        )
    });
    assert_eq!(failed, Err(HeadlessRefusal::NoThread(NO_THREAD.to_owned())));
    assert!(slot.lock().unwrap().is_none());
    // One that starts fills the slot.
    let started = start_into(&slot, || {
        headless(
            RecordingRenderer::new,
            clock.clone(),
            Arc::clone(&presenter),
        )
    });
    assert_eq!(started, Ok(()));
    // While it runs another is refused, and is not made.
    let mut made = false;
    let again = start_into(&slot, || {
        made = true;
        headless(
            RecordingRenderer::new,
            clock.clone(),
            Arc::clone(&presenter),
        )
    });
    assert_eq!(again, Err(HeadlessRefusal::Running));
    assert!(!made);
    // Each refusal crosses as its tag, the started session being 0.
    assert_eq!(
        (
            HeadlessRefusal::Running.tag(),
            HeadlessRefusal::NoThread(String::new()).tag()
        ),
        (1, 2)
    );
    slot.lock().unwrap().take().expect("the session").stop();
}
