//! The window that draws: the real window run onto a queue, with a session
//! that draws a fixture frame in it through the wgpu renderer.
//!
//! This opens a window and makes a surface on it, so it is an example and
//! not a test: the gate builds it and never runs it. Two opt-in tasks run
//! it: `mise run linux-window`, under Xvfb in a container, where xdotool
//! gives it input, and `mise run window-contract`, on the desktop it is
//! started from, where a person does.
//!
//! It is the wiring the gate cannot run, with nothing of Lean in it: the
//! winit platform on the process's main thread, what it reports pushed on
//! a queue and stamped (`editor_ffi::window::run`), what it tells whatever
//! draws in it handed to a session (`editor_ffi::render::Session`), and the
//! session's renderer made on the window (`WgpuRenderer::on_window`). A
//! second thread stands in for the editor: it pulls the queue, prints each
//! input as it reads back from its event, and publishes a frame when it
//! learns the window's size and scale. The frame is a scene built with
//! layout's builders and laid out by the real shaper over the fixture
//! fonts of `tests/fonts`, compiled in: no file is read and no font of the
//! machine is used. Its text is 14 points, and that thread tells its
//! layout the scale the window says before it lays out, so the text is 14
//! physical pixels on a window at scale 1 and 28 on one at scale 2.
//!
//! ```text
//! window [--seconds <n> | --until-closed] [--require-picture | --no-picture]
//!        [--family <name>]
//!
//! --seconds <n>        how long the window stays once it is ready, if
//!                      nobody closes it (20 by default)
//! --until-closed       the window stays until a person closes it
//! --require-picture    fail unless every frame's picture was compared
//! --no-picture         read no picture back and compare none
//! --family <name>      lay the fixture out in that family of this
//!                      machine's fonts, in place of the fixture fonts
//! ```
//!
//! The last three are for a person at the window (`mise run
//! window-by-hand`, which gives the first two of them): a window to drag
//! between displays and put into fullscreen for as long as it takes; no
//! half second of read-back and comparison in every draw, which would
//! make each step of a resize look stalled; and text in a family another
//! app has, to hold beside it. A family the machine has not is said
//! before any window opens. `--until-closed` with `--seconds`, and
//! `--no-picture` with `--require-picture`, are not understood.
//!
//! What it checks, and its exit status is 0 only when all of it holds.
//! Five checks are numbered, and one more is made of every frame as it is
//! published:
//!
//! - **Each frame is laid out at the window's scale.** For each frame
//!   published that is not the one before it, it prints `window: frame <n>
//!   is laid out for <w> by <h> at scale <s>: 14 points are <p> pixels`:
//!   the size and scale are the ones the window said, and `<p>` is the
//!   size the frame's glyphs are drawn at, read from the fonts they name.
//!   The run fails unless `<p>` is 14 times `<s>`, to within a 64th of a
//!   pixel ([`judge::laid_out`]).
//!
//! 1. **A frame was presented**, with an entry in the frame journal.
//! 2. **The picture is the frame's.** Each frame presented is read back
//!    from the surface before it is presented and compared with what the
//!    headless renderer draws of the same frame on the same target: no
//!    channel of any pixel may differ by more than 3 of 255. A picture
//!    that could not be read back is a failure, always. One thing is not,
//!    unless `--require-picture` is given: a surface that says it does not
//!    let its texture be copied from (the renderer's answer to being asked
//!    to keep its pictures). There is then nothing to compare, the run
//!    says so for each frame, and that this check held is not known. A
//!    desktop's surface may be such a one. The container's is not, so
//!    `mise run linux-window` gives `--require-picture`: there, a frame
//!    whose picture was not compared fails the run, whatever the reason.
//!    With `--no-picture` nothing is read back, the run says so once, and
//!    this check was not made.
//! 3. **Nothing is drawn that nothing asked for.** Every draw of the run
//!    is for something: a frame that is not the one shown, a size that is
//!    not the one last drawn at, or damage the window told of since the
//!    last draw began. A draw of the frame shown, where it is shown, with
//!    no damage told, fails the run, whenever it happens. Once the window
//!    has drawn what was asked of it as it opened, the render loop must
//!    come to rest, and no more frames are drawn until it does than the
//!    window asked for meanwhile by being resized or damaged, which is
//!    none when the window is left alone; and over the whole run no more
//!    draws are made, presented or not, than things asked for one. At rest
//!    nothing is scheduled, so nothing can draw: the wait ends on that
//!    event, not on a second of real time. A loop that never rests, or a
//!    window that asks again and again before it does, more than a system
//!    uncovering it would, fails too: that is a timer by another name.
//! 4. **Input arrived on the queue**: at least one key or pointer event.
//! 5. **Left alone, the window shows what was laid out for it.** Whenever
//!    a second passes in which the window tells its drawer nothing, no
//!    frame is published and no draw begins or ends, and the window has
//!    not said it is hidden, the draw last presented must be of a frame
//!    laid out for the size and the scale the window last said, on that
//!    size and scale ([`alone::left_alone`]). It prints `window: left alone <k>
//!    times, and each time the window showed what was laid out for it`, or
//!    fails with which frame, laid out for what, was on what. This is "no
//!    stale frame", and "no frame of one scale left on a window at
//!    another", for as often as the window is left for a second: the time
//!    it stays once it is ready is the first such time, and a person makes
//!    the rest by
//!    waiting a second after a resize, a move to another display, going
//!    into fullscreen and out of it, and coming back from another Space.
//!    What the window shows between two sizes, while it is not left alone,
//!    is not judged: no program here can see it.
//!
//! It prints `window: ready for input` once the render loop is at rest:
//! that is when to type, click, drag, scroll and resize. Each input is printed
//! on a line beginning `input:`.
//!
//! # The ledger
//!
//! What asked for a draw and what was drawn are entered in one ledger
//! ([`ledger::Ledger`]), in the order they happened and stamped on the clock that
//! stamps the input: each thing the window tells its drawer, each frame
//! published, each draw as the renderer is entered and as it answers (with
//! the kind of mask the renderer says it drew its glyphs with: plain ones
//! or subpixel ones, which is how a change of antialiasing between two
//! displays is seen), and
//! the two ends of the wait for the render loop's rest. What asks is entered before its word is
//! left with the render loop, so no draw is entered before what asked for
//! it. [`tally::Tally`] is what the ledger comes to, and the run prints all of
//! it once the window has closed, each line with its time since the window
//! opened: that is what to read when the check fails on a desktop.
//!
//! Damage is the one demand a draw does not show on its face, so it is
//! read off the order of the ledger: damage told before a draw is entered
//! is that draw's. In the instant between the render loop taking what is
//! asked and the renderer being entered, damage told is the next draw's to
//! the loop and this draw's to the ledger, and the next draw would then
//! read as for nothing. The timeline shows such a pair a few microseconds
//! apart; it has not been seen.
//!
//! What it makes of what it saw is tested in the gate, by the unit tests
//! of its modules, which open no window: how the command line
//! is read, what is made of each thing found of a picture, which sizes a
//! frame's glyphs are drawn at and which of them fail, what each draw of a
//! ledger was for, which ledgers fail, and which ledgers show a window
//! left alone with something not laid out for it (`cargo test` runs them: the
//! manifest says `test = true` of this example). They state no size of
//! layout's and no rule of the renderer's: the frames they read are
//! written by hand, and a kind of mask is printed in the renderer's own
//! words.

mod alone;
mod command_line;
mod input;
mod judge;
mod ledger;
mod scene;
mod tally;
#[cfg(test)]
mod testing;
mod timing;

use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread;
use std::time::Duration;

use editor_ffi::events::{EventKind, Queue};
use editor_ffi::interrupt::Interrupt;
use editor_ffi::render::{Presenter, Session, target};
use editor_ffi::window::{self, Monotonic};
use editor_layout::Layout;
use editor_layout::frame::Frame;
use editor_platform::{Input, Platform, WindowOptions};
use editor_platform_winit::WinitPlatform;
use editor_render::clock::Clock;
use editor_shape_parley::{FontSet, ParleyShaper};

use crate::alone::left_alone;
use crate::command_line::{Options, options};
use crate::input::{described, read_back};
use crate::judge::{Picture, drawn_at, laid_out, pictured};
use crate::ledger::{Checked, Entered, Ledger, Watched, entering, renderer};
use crate::scene::{fonts, scene};
use crate::tally::{Happened, Tally};
use crate::timing::{journalled, on_demand, timeline};

/// hang guard: the first frame presented, which the ledger notifies; only a
/// window that never presents reaches it, and the run then fails for no
/// frame presented.
const FIRST_FRAME: Duration = Duration::from_secs(30);

/// hang guard: the window settling, which the ledger notifies. It is how
/// long the window has, once its first frame is presented, to draw what
/// else was asked of it as it opened, before the wait for the render
/// loop's rest begins whether or not it has: on purpose a bound to go on
/// at, which the run then says ("before the window had settled").
const SETTLE: Duration = Duration::from_secs(5);

/// hang guard: the render loop's rest once the window has settled; only a
/// loop that never rests reaches it, and the run then fails for it.
const REST: Duration = Duration::from_secs(10);

/// How many lines of the timeline are printed, and how many of the
/// journal: enough for a window as it opens, its wait for rest, and a
/// person's input. A window drawn at every refresh for the whole run
/// would fill thousands.
const TIMELINE: usize = 300;

/// How many lines of the timeline, and of the journal, are printed of a
/// window a person kept open (`--until-closed`): a drag between two
/// displays, an animation into fullscreen and one out of it are some
/// hundreds of sizes each.
const TIMELINE_BY_HAND: usize = 5000;

/// `main` runs on the process's main thread, and the platform is run from
/// `main`.
fn on_main_thread() -> bool {
    true
}

/// The process's window.
static PLATFORM: WinitPlatform = WinitPlatform::new(on_main_thread);

/// What the example's threads share.
struct Shared {
    /// The adapter's name and back end, once a renderer is made.
    adapter: Mutex<Option<String>>,
    /// What draws the glyphs of the renderer on the window and of the one
    /// it is compared with, once they are made.
    rasterizing: Mutex<Option<String>>,
    /// What each presented frame's picture was found to be, in order.
    pictures: Mutex<Vec<Picture>>,
    /// Why a draw was not presented, for each that was not.
    refusals: Mutex<Vec<String>>,
    /// Why a frame published was not laid out at its window's scale, for
    /// each that was not ([`laid_out`]).
    mislaid: Mutex<Vec<String>>,
    /// What asked for a draw, and every draw.
    ledger: Arc<Ledger>,
    /// How many events of the window came off the queue.
    inputs: AtomicU64,
    /// How many of them were keys or the pointer.
    touched: AtomicU64,
    /// Whether the render loop failed to come to rest within [`REST`] of
    /// the window settling.
    restless: AtomicBool,
}

impl Shared {
    /// What the threads share as the example begins, its ledger stamping
    /// by `clock`.
    fn new(clock: Arc<dyn Clock>) -> Self {
        Self {
            adapter: Mutex::default(),
            rasterizing: Mutex::default(),
            pictures: Mutex::default(),
            refusals: Mutex::default(),
            mislaid: Mutex::default(),
            ledger: Arc::new(Ledger::new(clock)),
            inputs: AtomicU64::new(0),
            touched: AtomicU64::new(0),
            restless: AtomicBool::new(false),
        }
    }
}

/// `mutex`, locked. Nothing here panics holding one, and each guards a
/// value that is whole whenever it is unlocked.
fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The editor's part, on a thread of its own: pulls `queue` until it is
/// quit, prints each input, publishes the fixture frame laid out for each
/// size and scale the window says it has, and closes the window when it is
/// asked to.
///
/// It is this thread that tells layout the window's scale: the scale of
/// the resize it read off the queue, before it lays the scene out for that
/// resize's size. The render loop is told the same scale for its target,
/// by the window, on another thread. Each frame that is not the one last
/// published is printed with the scale it was laid out for and the size
/// its glyphs are drawn at, and judged ([`laid_out`]).
///
/// The fixture is laid out by the real shaper over `fonts`, in the family
/// `family` when there is one ([`fonts`]).
fn edit(
    queue: &Queue,
    session: &Session<Watched>,
    shared: &Shared,
    fonts: FontSet,
    family: Option<&str>,
) -> Result<(), String> {
    let mut layout = Layout::new(ParleyShaper::new(fonts));
    // The frame last published, by its number.
    let mut last = None;
    loop {
        let event = queue.next();
        if event.kind == EventKind::Quit {
            return Ok(());
        }
        let Some(input) = read_back(&event) else {
            return Err(format!("an event that reads back as no input: {event:?}"));
        };
        println!("input: {}", described(&input));
        shared.inputs.fetch_add(1, Ordering::SeqCst);
        match input {
            Input::Key(_) | Input::Pointer(_) => {
                shared.touched.fetch_add(1, Ordering::SeqCst);
            }
            Input::Resized(size) => {
                // The window's size is known: the frame is laid out for it
                // and published, stamped with the resize it answers.
                if let Some(handle) = session.handle() {
                    // A theme's lengths are points, and the window has
                    // just said how many pixels a point is.
                    let window = target(size);
                    layout.set_scale(window.scale);
                    let frame: Arc<Frame> = Arc::new(layout.frame(&scene(size, family)));
                    // Entered before it is handed over: no draw of it is
                    // entered first.
                    let number = shared.ledger.published(&frame, window);
                    let sizes = drawn_at(&frame);
                    handle.submit(frame, Some(event.stamp));
                    if last != Some(number) {
                        last = Some(number);
                        let verdict = laid_out(number, window, &sizes);
                        if let Some(line) = verdict.line {
                            println!("window: {line}");
                        }
                        locked(&shared.mislaid).extend(verdict.failure);
                    }
                }
            }
            Input::CloseRequested => PLATFORM.close(),
            _ => {}
        }
    }
}

/// Watches the window from a thread of its own: waits for the first frame
/// and for whatever else was asked as the window opened to be drawn, each
/// on the ledger's notice of it ([`Ledger::wait`](ledger::Ledger::wait)),
/// then waits for the render loop to come to rest
/// (`RenderHandle::wait_resting`) and enters in the ledger when that wait
/// began and ended, says the window is ready for input, and closes the
/// window `stay` later if nobody has; with no `stay` the window is left
/// for a person to close.
///
/// The wait for rest begins settled, when it can: with nothing asked for
/// that is not yet drawn. A window is asked for more than its first frame
/// as it opens (on macOS the system asks for its content while that frame
/// is being drawn), and a wait that began the moment the first frame was
/// presented would see that drawn and nothing ask for it.
fn watch(session: &Session<Watched>, shared: &Shared, stay: Option<Duration>) {
    if shared
        .ledger
        .wait(FIRST_FRAME, |tally| tally.shown.is_some())
    {
        shared.ledger.wait(SETTLE, Tally::settled);
        shared.ledger.note(Happened::Idle(true));
        let rested = session
            .handle()
            .is_some_and(|handle| handle.wait_resting(REST));
        shared.ledger.note(Happened::Idle(false));
        if !rested {
            shared.restless.store(true, Ordering::SeqCst);
        }
    }
    println!("window: ready for input");
    if let Some(stay) = stay {
        // real time under test: how long the window stays open for a
        // person, or for the left-alone check, once it is ready.
        thread::sleep(stay);
        PLATFORM.close();
    }
}

/// What was found, printed; and why the check fails, when it does, in a
/// run that `options` asks for: whether pictures are read back, whether
/// each must be compared, and how much of the timeline is printed.
fn report(session: &Session<Watched>, shared: &Shared, options: &Options) -> Vec<String> {
    let mut failures = Vec::new();
    match locked(&shared.adapter).as_deref() {
        Some(adapter) => println!("window: the renderer is on {adapter}"),
        None => println!("window: no renderer was made"),
    }
    if let Some(rasterizing) = locked(&shared.rasterizing).as_deref() {
        println!("window: glyphs are drawn by {rasterizing}");
    }
    if let Some(reason) = session.failure() {
        failures.push(format!("nothing draws in the window: {reason}"));
    }

    // 1. A frame was presented, with a journal entry.
    let handle = session.handle();
    let journal = handle
        .as_ref()
        .map(|handle| handle.journal())
        .unwrap_or_default();
    let counters = handle
        .as_ref()
        .map(|handle| handle.counters())
        .unwrap_or_default();
    match journal.first() {
        Some(first) => println!(
            "window: {} frames presented, each with a journal entry; the first {:.1} ms after the size it answers arrived, {} rows built",
            journal.len(),
            first.present_ns.saturating_sub(first.input_ns) as f64 / 1e6,
            first.rows_rebuilt
        ),
        None => failures.push("no frame was presented".to_owned()),
    }
    for reason in locked(&shared.refusals).iter() {
        println!("window: a draw was not presented: {reason}");
    }

    // 2. The picture is the frame's.
    let found = pictured(
        &locked(&shared.pictures),
        options.read_picture,
        options.require_picture,
    );
    for line in found.lines {
        println!("window: {line}");
    }
    failures.extend(found.failures);

    // Each frame was laid out at its window's scale: said as each was
    // published, and failed here.
    failures.extend(locked(&shared.mislaid).iter().cloned());

    // 3. Nothing is drawn that nothing asked for.
    let (records, tally) = shared.ledger.read();
    let opened_ns = records.first().map_or(0, |(at_ns, _)| *at_ns);
    // What a line says of a draw depends only on what came before it, so
    // the lines printed are made from the records printed and no more. A
    // window a person kept open has more to show.
    let most = if options.stay.is_some() {
        TIMELINE
    } else {
        TIMELINE_BY_HAND
    };
    let printed = records.len().min(most);
    for line in timeline(&records[..printed]) {
        println!("window: at {line}");
    }
    if records.len() > printed {
        println!(
            "window: and {} things more, not printed",
            records.len() - printed
        );
    }
    for entry in journal.iter().take(most) {
        println!("window: {}", journalled(entry, opened_ns));
    }
    let found = on_demand(&tally, opened_ns, counters.draws + counters.draws_failed);
    for line in found.lines {
        println!("window: {line}");
    }
    failures.extend(found.failures);
    if shared.restless.load(Ordering::SeqCst) {
        failures.push(format!(
            "the render loop had not come to rest {REST:?} after the window settled: something asks for a draw again and again"
        ));
    }

    // 5. Left alone, the window shows what was laid out for it.
    let found = left_alone(&records, &shared.ledger.laid());
    for line in found.lines {
        println!("window: {line}");
    }
    failures.extend(found.failures);

    // 4. Input arrived on the queue.
    let (inputs, touched) = (
        shared.inputs.load(Ordering::SeqCst),
        shared.touched.load(Ordering::SeqCst),
    );
    println!("window: {inputs} inputs came off the queue, {touched} of them keys or the pointer");
    if touched == 0 {
        failures.push(
            "no key and no pointer event came off the queue: type or click in the window"
                .to_owned(),
        );
    }
    failures
}

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
    let Some(options) = options(&arguments) else {
        eprintln!(
            "usage: window [--seconds <n> | --until-closed] [--require-picture | --no-picture] [--family <name>]"
        );
        return ExitCode::from(2);
    };
    // Before any window opens: a family this machine has not is said now.
    let (fonts, family) = match fonts(options.family.as_deref()) {
        Ok(found) => found,
        Err(reason) => {
            println!("window: FAILED: {reason}");
            return ExitCode::FAILURE;
        }
    };
    if let Some(family) = &family {
        println!("window: the fixture is laid out in {family}, of this machine's fonts");
    }
    // One clock stamps the input, times the frames and stamps the ledger:
    // the journal's time from an input to its frame is a subtraction on
    // it, and so is the time from what asked for a draw to the draw.
    let clock = Arc::new(Monotonic::new());
    let shared = Arc::new(Shared::new(clock.clone()));
    let queue = Arc::new(Queue::new());
    let session = {
        let (shared, read) = (Arc::clone(&shared), options.read_picture);
        // A presenter of its own: the example submits its frames to the
        // session's handle itself, and binds no display.
        Session::new(
            clock.clone(),
            move |window, _| {
                let inner = renderer(window, &shared, read)?;
                let ledger = Arc::clone(&shared.ledger);
                Ok(Entered {
                    inner,
                    ledger,
                    masks: Checked::masks,
                })
            },
            Presenter::new(),
        )
    };

    let editor = {
        let (queue, session, shared) = (Arc::clone(&queue), session.clone(), Arc::clone(&shared));
        thread::spawn(move || edit(&queue, &session, &shared, fonts, family.as_deref()))
    };
    {
        let (session, shared, stay) = (session.clone(), Arc::clone(&shared), options.stay);
        // Detached: it sleeps out the window's time, and the process ends
        // without it when the window was closed sooner.
        thread::spawn(move || watch(&session, &shared, stay));
    }

    let drawer = entering(session.drawer(), Arc::clone(&shared.ledger));
    let ran = window::run(
        &PLATFORM,
        WindowOptions::default(),
        clock,
        Arc::clone(&queue),
        // A flag of its own with no interrupt key: nothing raises it.
        Arc::new(Interrupt::new()),
        drawer,
    );
    queue.quit();
    let edited = editor
        .join()
        .unwrap_or_else(|_| Err("the editor's thread panicked".to_owned()));

    let mut failures = report(&session, &shared, &options);
    if let Err(cannot_open) = ran {
        failures.push(format!("the window could not be opened: {cannot_open}"));
    }
    if let Err(reason) = edited {
        failures.push(reason);
    }
    if failures.is_empty() {
        println!(
            "window: the window drew the fixture frame, drew nothing it was not asked for, and its input arrived on the queue"
        );
        ExitCode::SUCCESS
    } else {
        for failure in &failures {
            println!("window: FAILED: {failure}");
        }
        ExitCode::FAILURE
    }
}
