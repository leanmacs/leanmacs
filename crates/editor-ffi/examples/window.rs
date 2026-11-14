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
//! learns the window's size. The frame is a scene built with layout's
//! builders and laid out by the real shaper over the fixture fonts of
//! `tests/fonts`, compiled in: no file is read and no font of the machine
//! is used.
//!
//! ```text
//! window [--seconds <n>] [--require-picture]
//!
//! --seconds <n>        how long the window stays once it is ready, if
//!                      nobody closes it (20 by default)
//! --require-picture    fail unless every frame's picture was compared
//! ```
//!
//! What it checks, and its exit status is 0 only when all four hold:
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
//! 3. **Nothing is drawn that nothing asked for.** Every draw of the run
//!    is for something: a frame that is not the one shown, a size that is
//!    not the one last drawn at, or damage the window told of since the
//!    last draw began. A draw of the frame shown, where it is shown, with
//!    no damage told, fails the run, whenever it happens. The window is
//!    also left alone for a second, once it has drawn what was asked of it
//!    as it opened: no more frames are drawn in that second than the
//!    window asked for in it by being resized or damaged, which is none
//!    when the window is left alone; and over the whole run no more draws
//!    are made, presented or not, than things asked for one. A window that
//!    asks again and again in that second, more than a system uncovering
//!    it would, fails too: that is a timer by another name.
//! 4. **Input arrived on the queue**: at least one key or pointer event.
//!
//! It prints `window: ready for input` once the idle second is over: that
//! is when to type, click, drag, scroll and resize. Each input is printed
//! on a line beginning `input:`.
//!
//! # The ledger
//!
//! What asked for a draw and what was drawn are entered in one ledger
//! ([`Ledger`]), in the order they happened and stamped on the clock that
//! stamps the input: each thing the window tells its drawer, each frame
//! published, each draw as the renderer is entered and as it answers, and
//! the idle second's two ends. What asks is entered before its word is
//! left with the render loop, so no draw is entered before what asked for
//! it. [`Tally`] is what the ledger comes to, and the run prints all of
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
//! at the foot of this file, which open no window: how the command line
//! is read, what is made of each thing found of a picture, what each draw
//! of a ledger was for, and which ledgers fail (`cargo test` runs them:
//! the manifest says `test = true` of this example).

use std::process::ExitCode;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread;
use std::time::{Duration, Instant};

use editor_ffi::events::{Event, EventKind, Queue};
use editor_ffi::render::{Session, target};
use editor_ffi::window::{self, Monotonic};
use editor_layout::Layout;
use editor_layout::face::{Color, Face, FaceDef};
use editor_layout::frame::Frame;
use editor_layout::scene::{Rect, Scene, StatusField};
use editor_platform::{
    Button, Canvas, Composition, Drawer, Input, Key, LogicalKey, Modifiers, NativeWindow,
    PhysicalKey, Platform, Pointer, PointerAction, Resize, WheelDelta, WindowOptions,
};
use editor_platform_winit::WinitPlatform;
use editor_render::clock::Clock;
use editor_render::journal::Entry;
use editor_render::port::{DrawRequest, Drawn, Renderer, Target};
use editor_render_wgpu::{Antialiasing, HeadlessRenderer, Image, Settings, WgpuRenderer};
use editor_shape_parley::{FontSet, ParleyShaper};

/// Noto Sans: the default family.
const SANS: &[u8] = include_bytes!("../../../tests/fonts/NotoSans-Regular.subset.ttf");
/// Noto Sans Hebrew, a fallback.
const HEBREW: &[u8] = include_bytes!("../../../tests/fonts/NotoSansHebrew-Regular.ttf");
/// Noto Sans JP, a fallback.
const JP: &[u8] = include_bytes!("../../../tests/fonts/NotoSansJP-Regular.subset.otf");

/// The text of the fixture: a ligature (`fi`), a right-to-left run and a
/// character of the CJK fallback, in two rows.
const TEXT: &str = "fine שלום 日\nthe window draws this";

/// How far any channel of any pixel the window's surface holds may be from
/// the headless renderer's: 3 of 255, as the renderer's own check on a real
/// adapter allows (`crates/editor-render-wgpu/examples/gpu.rs`).
const TOLERANCE: u8 = 3;

/// How long the window is left alone, with nothing published, to see that
/// nothing is drawn.
const IDLE: Duration = Duration::from_secs(1);

/// How many times a window left alone for [`IDLE`] may ask to be drawn
/// again: a system that uncovers the window, or settles its size as it
/// opens, asks a few times. A window that asks at every refresh asks sixty
/// times and more.
const IDLE_ASKS: u64 = 5;

/// How long the first frame has to be presented.
const FIRST_FRAME: Duration = Duration::from_secs(30);

/// How long the window has, once its first frame is presented, to draw
/// what else was asked of it as it opened, before the idle second begins
/// whether or not it has.
const SETTLE: Duration = Duration::from_secs(5);

/// How many lines of the timeline are printed, and how many of the
/// journal: enough for a window as it opens, its idle second, and a
/// person's input. A window drawn at every refresh for the whole run
/// would fill thousands.
const TIMELINE: usize = 300;

/// `main` runs on the process's main thread, and the platform is run from
/// `main`.
fn on_main_thread() -> bool {
    true
}

/// The process's window.
static PLATFORM: WinitPlatform = WinitPlatform::new(on_main_thread);

/// What a presented frame's picture was found to be.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Picture {
    /// It was compared with the headless renderer's: how many pixels it
    /// has, how many differ, and the largest difference of any channel.
    Compared {
        /// The pixels of the picture.
        pixels: usize,
        /// The pixels that differ at all.
        differing: usize,
        /// The largest difference of any channel.
        worst: u8,
    },
    /// It is not the size of its target.
    WrongSize(u32, u32),
    /// There is none: the window's surface does not let its texture be
    /// copied from.
    NotCopied,
    /// It could not be read back, from a surface that lets its texture be
    /// copied from: why.
    Unread(String),
}

/// What the command line asks for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Options {
    /// How long the window stays once it is ready, if nobody closes it.
    stay: Duration,
    /// Whether every frame's picture must be compared for the run to pass.
    require_picture: bool,
}

/// The options `arguments` ask for; `None` when they are not understood.
fn options(arguments: &[&str]) -> Option<Options> {
    let mut options = Options {
        stay: Duration::from_secs(20),
        require_picture: false,
    };
    let mut rest = arguments;
    loop {
        rest = match rest {
            [] => return Some(options),
            ["--seconds", seconds, rest @ ..] => {
                options.stay = Duration::from_secs(seconds.parse().ok()?);
                rest
            }
            ["--require-picture", rest @ ..] => {
                options.require_picture = true;
                rest
            }
            _ => return None,
        };
    }
}

/// What is found of a frame's picture without comparing it, when it cannot
/// be compared: a surface that is not copied from (`copies` says which it
/// is) has no picture, and one that is, and whose picture the renderer
/// then refused to read (`refused` says why), could not be read. `None`
/// when there is a picture to compare.
fn uncompared(copies: bool, refused: Option<&str>) -> Option<Picture> {
    if !copies {
        return Some(Picture::NotCopied);
    }
    refused.map(|reason| Picture::Unread(reason.to_owned()))
}

/// What is made of one frame's picture.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Verdict {
    /// What is printed of it, when anything is.
    line: Option<String>,
    /// Why the run fails by it, when it does.
    failure: Option<String>,
}

/// What is made of `picture`, the picture of the frame presented
/// `number`th, in a run that requires a comparison when `require_picture`
/// says so.
fn judged(number: usize, picture: &Picture, require_picture: bool) -> Verdict {
    match picture {
        Picture::Compared {
            pixels,
            differing,
            worst,
        } => Verdict {
            line: Some(format!(
                "frame {number}: read back from the surface, {differing} of {pixels} pixels differ from the headless renderer's, the worst by {worst} of 255"
            )),
            failure: (*worst > TOLERANCE).then(|| {
                format!(
                    "frame {number}'s picture differs by {worst} of 255, past the tolerance of {TOLERANCE}"
                )
            }),
        },
        Picture::WrongSize(width, height) => Verdict {
            line: None,
            failure: Some(format!(
                "frame {number}'s picture is {width} by {height}, not the size of its target"
            )),
        },
        // What a surface offers is not a failure of the window, unless the
        // run is one that must compare: in the container the surface is
        // known to let its texture be copied from.
        Picture::NotCopied => Verdict {
            line: Some(format!(
                "frame {number}: the surface does not let its texture be copied from, so its picture is not compared"
            )),
            failure: require_picture.then(|| {
                format!(
                    "frame {number}'s picture was not compared, and this run requires it (--require-picture): the surface does not let its texture be copied from"
                )
            }),
        },
        // A read that failed is a failure wherever it happens: the surface
        // said its texture could be copied from.
        Picture::Unread(reason) => Verdict {
            line: None,
            failure: Some(format!(
                "frame {number}'s picture could not be read back: {reason}"
            )),
        },
    }
}

/// One thing that bears on whether a draw was asked for, as the example
/// saw it happen.
#[derive(Debug, Clone, PartialEq)]
enum Happened {
    /// The window told its drawer that it opened.
    Opened {
        /// The size it opened at.
        size: Target,
        /// How often its display refreshes, in thousandths of a hertz,
        /// when the platform says.
        refresh: Option<u32>,
    },
    /// The window told its drawer its new size or scale.
    Resized(Target),
    /// The window told its drawer that the system asks for its content to
    /// be drawn again.
    Damaged,
    /// The window told its drawer something else, which asks for no draw:
    /// as it prints.
    Told(String),
    /// A frame was published: which, counted from 1. Frames that are equal
    /// are one frame, as they are to the render loop.
    Published(usize),
    /// The renderer was asked to draw.
    Began {
        /// The frame to draw, by its number; `None` for a frame nobody
        /// published.
        frame: Option<usize>,
        /// What to draw it on.
        target: Target,
    },
    /// The renderer answered the draw last begun.
    Ended {
        /// Whether it presented the frame.
        presented: bool,
    },
    /// The idle second began (`true`) or ended (`false`).
    Idle(bool),
}

/// One thing that happened, and when on the example's clock, in
/// nanoseconds.
type Record = (u64, Happened);

/// What `canvas`, a thing the window tells its drawer, is to the ledger.
///
/// Three things a window tells bear on what is drawn: the size it opened
/// at, a new size, and damage. Whatever else it tells asks for no draw by
/// itself (a refresh rate, hidden or shown, closing) and is kept as it
/// prints, so the match names those three and no more. A thing a window
/// comes to tell that does ask for a draw would show here as a draw for
/// nothing, which fails the run: that is when to name it.
fn happened(canvas: &Canvas) -> Happened {
    match canvas {
        Canvas::Opened {
            size,
            refresh_millihertz,
            ..
        } => Happened::Opened {
            size: target(*size),
            refresh: *refresh_millihertz,
        },
        Canvas::Resized(size) => Happened::Resized(target(*size)),
        Canvas::Damaged => Happened::Damaged,
        other => Happened::Told(format!("{other:?}")),
    }
}

/// What a draw was for: each thing asked that it was the first draw to
/// answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
struct Served {
    /// A frame that is not the one shown.
    frame: bool,
    /// A size or a scale that is not the one last drawn at.
    size: bool,
    /// Damage the window told of.
    damage: bool,
}

impl Served {
    /// Whether it is nothing at all.
    fn nothing(self) -> bool {
        !(self.frame || self.size || self.damage)
    }
}

/// One draw the renderer was asked for.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Draw {
    /// When it began.
    began_ns: u64,
    /// Whether it presented its frame; `false` while it is in progress.
    presented: bool,
    /// What it was for.
    served: Served,
    /// Whether it began in the idle second.
    idle: bool,
}

/// What the idle second showed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Idle {
    /// Whether everything asked before it began had been drawn by then.
    settled: bool,
    /// The draws that began in it and presented.
    drawn: u64,
    /// The things that asked for a draw in it.
    asked: u64,
}

/// The draw in progress.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Drawing {
    /// The frame it draws.
    frame: Option<usize>,
    /// What it draws on.
    target: Target,
    /// How many times the window had told of damage that it answers.
    damage: u64,
}

/// What the ledger comes to: which draw was for what, and what is still
/// asked for.
///
/// It keeps the render loop's own rule of what a demand is
/// (`editor_render::render_loop`): a frame that is not the one shown, a
/// size that is not the one last drawn at, and a mark that the frame shown
/// must be drawn again, which here only damage the window tells of leaves.
/// The first two it reads off the draw itself, by what was shown before
/// it; the third off what the window told since the last draw began. A
/// draw that presents answers all three; one that does not leaves them to
/// the next.
#[derive(Debug, Clone, Default)]
struct Tally {
    /// The frame last published.
    published: Option<usize>,
    /// The size the window last told.
    told: Option<Target>,
    /// The frame last presented, and what it was presented on.
    shown: Option<(Option<usize>, Target)>,
    /// How many times the window told of damage that no draw has begun
    /// since.
    damage: u64,
    /// The draw in progress.
    drawing: Option<Drawing>,
    /// Every draw, in order.
    draws: Vec<Draw>,
    /// How many things asked for a draw: a frame published, a new size
    /// told and damage told.
    asked: u64,
    /// Whether the idle second is under way.
    idling: bool,
    /// What the idle second showed, once it has begun.
    idle: Option<Idle>,
}

impl Tally {
    /// Takes in one thing that happened at `at_ns`.
    fn note(&mut self, at_ns: u64, happened: &Happened) {
        match happened {
            Happened::Opened { size, .. } => self.told = Some(*size),
            Happened::Resized(size) => {
                self.told = Some(*size);
                self.ask();
            }
            Happened::Damaged => {
                self.damage += 1;
                self.ask();
            }
            Happened::Told(_) => {}
            Happened::Published(frame) => {
                self.published = Some(*frame);
                self.ask();
            }
            Happened::Began { frame, target } => {
                let served = Served {
                    frame: self.shown.is_none_or(|(shown, _)| shown != *frame),
                    size: self.shown.is_some_and(|(_, on)| on != *target),
                    damage: self.damage > 0,
                };
                // The damage told so far is this draw's to answer: what is
                // told from here on is the next one's.
                self.drawing = Some(Drawing {
                    frame: *frame,
                    target: *target,
                    damage: std::mem::take(&mut self.damage),
                });
                self.draws.push(Draw {
                    began_ns: at_ns,
                    presented: false,
                    served,
                    idle: self.idling,
                });
            }
            Happened::Ended { presented } => {
                let Some(drawing) = self.drawing.take() else {
                    return;
                };
                if !*presented {
                    // Nothing was answered: the damage is still told.
                    self.damage += drawing.damage;
                    return;
                }
                self.shown = Some((drawing.frame, drawing.target));
                if let Some(draw) = self.draws.last_mut() {
                    draw.presented = true;
                    if let (true, Some(idle)) = (draw.idle, &mut self.idle) {
                        idle.drawn += 1;
                    }
                }
            }
            Happened::Idle(true) => {
                self.idle = Some(Idle {
                    settled: self.settled(),
                    drawn: 0,
                    asked: 0,
                });
                self.idling = true;
            }
            Happened::Idle(false) => self.idling = false,
        }
    }

    /// Counts one thing that asked for a draw.
    fn ask(&mut self) {
        self.asked += 1;
        if let (true, Some(idle)) = (self.idling, &mut self.idle) {
            idle.asked += 1;
        }
    }

    /// What is asked for and not yet shown.
    fn wanted(&self) -> Served {
        let shown = self.shown;
        Served {
            frame: self
                .published
                .is_some_and(|published| shown.is_none_or(|(frame, _)| frame != Some(published))),
            size: shown.is_some_and(|(_, on)| self.told.is_some_and(|told| told != on)),
            damage: self.damage > 0,
        }
    }

    /// Whether a frame is shown and nothing more is asked for or being
    /// drawn.
    fn settled(&self) -> bool {
        self.shown.is_some() && self.drawing.is_none() && self.wanted().nothing()
    }

    /// The draws that were for nothing, each with its number from 1.
    fn unasked(&self) -> Vec<(usize, Draw)> {
        (1..)
            .zip(self.draws.iter().copied())
            .filter(|(_, draw)| draw.served.nothing())
            .collect()
    }
}

/// What is made of something the example saw: the lines to print of it,
/// and why the run fails by it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
struct Findings {
    /// What is printed.
    lines: Vec<String>,
    /// Why the run fails.
    failures: Vec<String>,
}

/// How long after `opened_ns` the time `at_ns` is, in milliseconds.
fn since(opened_ns: u64, at_ns: u64) -> f64 {
    (at_ns as f64 - opened_ns as f64) / 1e6
}

/// What is made of the draws `tally` holds, in a window that opened at
/// `opened_ns` and whose render loop counts `counted` draws, presented or
/// not: that none was for nothing.
fn on_demand(tally: &Tally, opened_ns: u64, counted: u64) -> Findings {
    let mut found = Findings::default();
    match tally.idle {
        Some(Idle {
            settled,
            drawn,
            asked,
        }) => {
            if !settled {
                found.lines.push(
                    "idle: the second began before the window had settled: a draw was in progress, or something asked for was not yet drawn"
                        .to_owned(),
                );
            }
            found.lines.push(format!(
                "idle: over {} s in which nothing was published, {drawn} frames were drawn and the window asked for {asked}",
                IDLE.as_secs()
            ));
            // A second that began before the window had settled may draw
            // for what was asked before it: each draw is judged by itself,
            // below.
            if settled && drawn > asked {
                found.failures.push(format!(
                    "{drawn} frames were drawn while idle and {asked} were asked for"
                ));
            }
            if asked > IDLE_ASKS {
                found.failures.push(format!(
                    "the window asked to be drawn {asked} times while idle: more than {IDLE_ASKS} is a timer"
                ));
            }
        }
        None => found
            .failures
            .push("the window was never seen idle: no frame was presented".to_owned()),
    }
    let unasked = tally.unasked();
    if let Some((number, first)) = unasked.first() {
        found.failures.push(format!(
            "{} of the {} draws were asked for by nothing: the first is draw {number}, which began {:.1} ms after the window opened",
            unasked.len(),
            tally.draws.len(),
            since(opened_ns, first.began_ns)
        ));
    }
    let asked = tally.asked;
    found.lines.push(format!(
        "over the whole run, {counted} draws for {asked} things that asked for one"
    ));
    if counted > asked {
        found.failures.push(format!(
            "{counted} draws were made and {asked} were asked for"
        ));
    }
    let entered = tally.draws.len() as u64;
    if counted != entered {
        found.failures.push(format!(
            "the render loop counts {counted} draws and its renderer was asked for {entered}"
        ));
    }
    found
}

/// The timeline of `records`: one line for each, its time since the first
/// and what happened.
fn timeline(records: &[Record]) -> Vec<String> {
    let Some((opened_ns, _)) = records.first() else {
        return Vec::new();
    };
    let on = |target: &Target| {
        format!(
            "{} by {} at scale {}",
            target.width, target.height, target.scale
        )
    };
    // What each draw was for is the tally's to say, as the records go by.
    let mut tally = Tally::default();
    let mut lines = Vec::new();
    for (at_ns, happened) in records {
        let again =
            matches!(happened, Happened::Published(frame) if tally.published == Some(*frame));
        let settled = tally.settled();
        tally.note(*at_ns, happened);
        let draw = tally.draws.len();
        let what = match happened {
            Happened::Opened { size, refresh } => format!(
                "the window told its drawer it opened, {}, on a display that {}",
                on(size),
                refresh.map_or_else(
                    || "does not say how often it refreshes".to_owned(),
                    |rate| format!("refreshes {rate} thousandths of a hertz")
                )
            ),
            Happened::Resized(size) => format!("the window told its drawer it is {}", on(size)),
            Happened::Damaged => "the window told its drawer it is damaged".to_owned(),
            Happened::Told(said) => format!("the window told its drawer {said}"),
            Happened::Published(frame) => format!(
                "frame {frame} was published{}",
                if again { " again" } else { "" }
            ),
            Happened::Began { frame, target } => format!(
                "draw {draw} began, of {} on {}, for {}",
                frame.map_or_else(
                    || "a frame nobody published".to_owned(),
                    |frame| format!("frame {frame}")
                ),
                on(target),
                tally
                    .draws
                    .last()
                    .map_or_else(String::new, |draw| reasons(draw.served))
            ),
            Happened::Ended { presented } => format!(
                "draw {draw} ended, {}",
                if *presented {
                    "presented"
                } else {
                    "not presented"
                }
            ),
            Happened::Idle(true) => format!(
                "the idle second began{}",
                if settled {
                    ""
                } else {
                    ", before the window had settled"
                }
            ),
            Happened::Idle(false) => "the idle second ended".to_owned(),
        };
        lines.push(format!("{:>9.1} ms: {what}", since(*opened_ns, *at_ns)));
    }
    lines
}

/// What a draw was for, for a person.
fn reasons(served: Served) -> String {
    let reasons: Vec<&str> = [
        (served.frame, "a frame not yet shown"),
        (served.size, "a size not yet drawn at"),
        (served.damage, "damage"),
    ]
    .into_iter()
    .filter_map(|(served, reason)| served.then_some(reason))
    .collect();
    match reasons.as_slice() {
        [] => "nothing that was asked".to_owned(),
        [one] => (*one).to_owned(),
        [first @ .., last] => format!("{} and {last}", first.join(", ")),
    }
}

/// What the render loop's journal says of one frame presented, in a window
/// that opened at `opened_ns`.
fn journalled(entry: &Entry, opened_ns: u64) -> String {
    format!(
        "the journal's frame {} answers something asked {:.1} ms after the window opened: its draw began at {:.1} ms and it was presented at {:.1} ms",
        entry.serial,
        since(opened_ns, entry.input_ns),
        since(opened_ns, entry.draw_ns),
        since(opened_ns, entry.present_ns)
    )
}

/// What the ledger keeps.
#[derive(Default)]
struct Kept {
    /// Everything that happened, in order.
    records: Vec<Record>,
    /// What it comes to.
    tally: Tally,
    /// Each frame published that is equal to none before it: frame `n` is
    /// at `n - 1`.
    frames: Vec<Arc<Frame>>,
}

/// The ledger: everything that asked for a draw and every draw, in the
/// order they happened, each stamped on one clock.
///
/// What asks is entered before its word is left with the render loop, and
/// a draw as the renderer is entered, so no draw is entered before what
/// asked for it.
struct Ledger {
    /// The clock that stamps.
    clock: Arc<dyn Clock>,
    /// What it keeps.
    kept: Mutex<Kept>,
}

impl Ledger {
    /// A ledger nothing is entered in, stamping by `clock`.
    fn new(clock: Arc<dyn Clock>) -> Self {
        Self {
            clock,
            kept: Mutex::new(Kept::default()),
        }
    }

    /// Enters one thing that happened, now.
    fn note(&self, happened: Happened) {
        let mut kept = locked(&self.kept);
        // Read under the lock: the order of the records is the order of
        // their stamps.
        let at_ns = self.clock.now_ns();
        kept.tally.note(at_ns, &happened);
        kept.records.push((at_ns, happened));
    }

    /// Enters that `frame` is published, and gives its number.
    fn published(&self, frame: &Arc<Frame>) -> usize {
        let number = {
            let mut kept = locked(&self.kept);
            number_of(&kept.frames, frame).unwrap_or_else(|| {
                kept.frames.push(Arc::clone(frame));
                kept.frames.len()
            })
        };
        self.note(Happened::Published(number));
        number
    }

    /// Enters that a draw of `frame` on `target` begins.
    fn began(&self, frame: &Arc<Frame>, target: Target) {
        let frame = number_of(&locked(&self.kept).frames, frame);
        self.note(Happened::Began { frame, target });
    }

    /// Whether a frame is shown and nothing more is asked for or being
    /// drawn.
    fn settled(&self) -> bool {
        locked(&self.kept).tally.settled()
    }

    /// Everything entered so far and what it comes to, as copies.
    fn read(&self) -> (Vec<Record>, Tally) {
        let kept = locked(&self.kept);
        (kept.records.clone(), kept.tally.clone())
    }
}

/// The number of `frame` among `frames`, the frames published: one more
/// than where the first that is it, or equal to it, is.
fn number_of(frames: &[Arc<Frame>], frame: &Arc<Frame>) -> Option<usize> {
    frames
        .iter()
        .position(|published| Arc::ptr_eq(published, frame) || published == frame)
        .map(|at| at + 1)
}

/// A renderer whose every draw is entered in the ledger: as it begins,
/// and as it ends with whether it presented.
struct Entered<R> {
    /// The renderer.
    inner: R,
    /// Where its draws are entered.
    ledger: Arc<Ledger>,
}

impl<R: Renderer> Renderer for Entered<R> {
    fn draw(&mut self, request: &DrawRequest<'_>) -> Drawn {
        self.ledger.began(request.frame, request.target);
        let drawn = self.inner.draw(request);
        self.ledger.note(Happened::Ended {
            presented: drawn.presented,
        });
        drawn
    }
}

/// What draws in the example's window: the checked renderer, each of its
/// draws entered in the ledger.
type Watched = Entered<Checked>;

/// `drawer`, with each thing the window tells entered in `ledger` before
/// `drawer` hears it.
fn entering(drawer: Drawer, ledger: Arc<Ledger>) -> Drawer {
    Arc::new(move |canvas| {
        ledger.note(happened(&canvas));
        drawer(canvas);
    })
}

/// What the example's threads share.
struct Shared {
    /// The adapter's name and back end, once a renderer is made.
    adapter: Mutex<Option<String>>,
    /// What each presented frame's picture was found to be, in order.
    pictures: Mutex<Vec<Picture>>,
    /// Why a draw was not presented, for each that was not.
    refusals: Mutex<Vec<String>>,
    /// What asked for a draw, and every draw.
    ledger: Arc<Ledger>,
    /// How many events of the window came off the queue.
    inputs: AtomicU64,
    /// How many of them were keys or the pointer.
    touched: AtomicU64,
}

impl Shared {
    /// What the threads share as the example begins, its ledger stamping
    /// by `clock`.
    fn new(clock: Arc<dyn Clock>) -> Self {
        Self {
            adapter: Mutex::default(),
            pictures: Mutex::default(),
            refusals: Mutex::default(),
            ledger: Arc::new(Ledger::new(clock)),
            inputs: AtomicU64::new(0),
            touched: AtomicU64::new(0),
        }
    }
}

/// `mutex`, locked. Nothing here panics holding one, and each guards a
/// value that is whole whenever it is unlocked.
fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The wgpu renderer on the window, with each frame it presents read back
/// and compared with the headless renderer's picture of the same frame.
struct Checked {
    /// The renderer on the window.
    gpu: WgpuRenderer,
    /// Whether the window's surface lets its texture be copied from: what
    /// the renderer answered when it was asked to keep its pictures.
    copies: bool,
    /// The renderer it is compared with.
    headless: HeadlessRenderer,
    /// Where what it finds goes.
    shared: Arc<Shared>,
}

impl Renderer for Checked {
    fn draw(&mut self, request: &DrawRequest<'_>) -> Drawn {
        let drawn = self.gpu.draw(request);
        if !drawn.presented {
            let reason = self.gpu.refused().unwrap_or("no reason given").to_owned();
            locked(&self.shared.refusals).push(reason);
            return drawn;
        }
        let picture = self.gpu.read_back();
        let found = uncompared(self.copies, self.gpu.refused()).unwrap_or_else(|| {
            self.headless.draw(request);
            compare(&picture, self.headless.image(), request.target)
        });
        locked(&self.shared.pictures).push(found);
        drawn
    }
}

/// What `picture` is found to be against `expected`, both of `target`.
fn compare(picture: &Image, expected: &Image, target: Target) -> Picture {
    let size = (picture.width, picture.height);
    if size != (expected.width, expected.height) || size != (target.width, target.height) {
        return Picture::WrongSize(picture.width, picture.height);
    }
    let (mut differing, mut worst) = (0, 0);
    for (got, wanted) in picture
        .rgba
        .as_chunks::<4>()
        .0
        .iter()
        .zip(expected.rgba.as_chunks::<4>().0)
    {
        let difference = got
            .iter()
            .zip(wanted)
            .map(|(a, b)| a.abs_diff(*b))
            .max()
            .unwrap_or(0);
        if difference > 0 {
            differing += 1;
        }
        worst = worst.max(difference);
    }
    Picture::Compared {
        pixels: picture.rgba.len() / 4,
        differing,
        worst,
    }
}

/// A renderer on `window`, checked. The error is why there is none.
fn renderer(window: Option<&NativeWindow>, shared: &Arc<Shared>) -> Result<Checked, String> {
    let window = window.ok_or("the platform named no native window to draw in")?;
    // SAFETY: the window port tells of `window` when it opens, on this
    // thread, and it stays live until the drawer returns from being told
    // the window is closing. The session drops this renderer, on this
    // thread, while it is being told so.
    #[expect(
        clippy::disallowed_methods,
        reason = "this example is the one place a renderer is made on a window: it is the window's check, run on demand"
    )]
    let made = unsafe { WgpuRenderer::on_window(window, Settings::default()) };
    let mut gpu = made.map_err(|error| error.to_string())?;
    let copies = gpu.keep_picture();
    *locked(&shared.adapter) = Some(format!(
        "{}, blending by a coverage for each channel: {}",
        gpu.adapter(),
        gpu.per_channel()
    ));
    // An adapter that cannot blend by a coverage for each channel draws
    // plain masks whatever it is asked: so must what it is compared with.
    let settings = if gpu.per_channel() {
        Settings::default()
    } else {
        Settings {
            antialiasing: Antialiasing::Grayscale,
            ..Settings::default()
        }
    };
    Ok(Checked {
        gpu,
        copies,
        headless: HeadlessRenderer::new(settings),
        shared: Arc::clone(shared),
    })
}

/// A layout over the real shaper and the fixture fonts.
fn layout() -> Result<Layout<ParleyShaper>, String> {
    let files: Vec<Vec<u8>> = [SANS, HEBREW, JP]
        .iter()
        .map(|bytes| bytes.to_vec())
        .collect();
    let fallbacks = ["Noto Sans Hebrew", "Noto Sans JP"];
    let fonts = FontSet::only("Noto Sans", &fallbacks, files)
        .map_err(|error| format!("the fixture fonts: {error}"))?;
    Ok(Layout::new(ParleyShaper::new(fonts)))
}

/// The fixture scene in a window of `size`: [`TEXT`] in one view that
/// fills it, a selection with its cursor, and a status row.
fn scene(size: Resize) -> Scene {
    let target = target(size);
    let rect = Rect {
        x: 0,
        y: 0,
        width: target.width,
        height: target.height,
    };
    let named = |name: &str, face: Face| FaceDef {
        name: name.to_owned(),
        face,
    };
    let rgb = |red: u8, green: u8, blue: u8| Some(Color::rgb(red, green, blue));
    let mut scene = Scene::of_text(TEXT, rect).selecting(2..7);
    scene.faces = Some(vec![
        named(
            "default",
            Face {
                foreground: rgb(0x20, 0x20, 0x20),
                background: rgb(0xf8, 0xf8, 0xf8),
                ..Face::default()
            },
        ),
        named(
            "selection",
            Face {
                background: rgb(0xc0, 0xd8, 0xff),
                ..Face::default()
            },
        ),
        named(
            "mode-line",
            Face {
                foreground: rgb(0xf0, 0xf0, 0xf0),
                background: rgb(0x40, 0x40, 0x40),
                ..Face::default()
            },
        ),
    ]);
    scene.views[0].status = vec![StatusField {
        text: format!("window  {} by {}", size.width, size.height),
        face: "mode-line".to_owned(),
    }];
    scene
}

/// The modifiers held, for a person: `shift+control`, or `none`.
fn held(modifiers: Modifiers) -> String {
    let names: Vec<&str> = [
        (modifiers.shift, "shift"),
        (modifiers.control, "control"),
        (modifiers.alt, "alt"),
        (modifiers.super_key, "super"),
    ]
    .into_iter()
    .filter_map(|(held, name)| held.then_some(name))
    .collect();
    if names.is_empty() {
        "none".to_owned()
    } else {
        names.join("+")
    }
}

/// A key, for a person.
fn key(key: &Key) -> String {
    let what = match (key.pressed, key.repeat) {
        (true, false) => "press",
        (true, true) => "repeat",
        (false, _) => "release",
    };
    let logical = match &key.logical {
        LogicalKey::Character(characters) => format!("'{characters}'"),
        LogicalKey::Named(name) => name.clone(),
        LogicalKey::Dead(Some(character)) => format!("dead '{character}'"),
        LogicalKey::Dead(None) => "dead".to_owned(),
        LogicalKey::Unidentified => "unidentified".to_owned(),
    };
    let physical = match &key.physical {
        PhysicalKey::Code(code) => code.as_str(),
        PhysicalKey::Unidentified => "unidentified",
    };
    format!(
        "key {what} {logical} at {physical} with {}, text {:?}",
        held(key.modifiers),
        key.text
    )
}

/// What the pointer did, for a person.
fn pointer(pointer: &Pointer) -> String {
    let button = match pointer.button {
        Some(Button::Primary) => "primary".to_owned(),
        Some(Button::Secondary) => "secondary".to_owned(),
        Some(Button::Middle) => "middle".to_owned(),
        Some(Button::Back) => "back".to_owned(),
        Some(Button::Forward) => "forward".to_owned(),
        Some(Button::Other(number)) => format!("button {number}"),
        None => "no button".to_owned(),
    };
    let what = match pointer.action {
        PointerAction::Press => format!("press {button}"),
        PointerAction::Drag => format!("drag {button}"),
        PointerAction::Release => format!("release {button}"),
        PointerAction::Wheel(WheelDelta::Lines { x, y }) => {
            format!("wheel {x} across and {y} down in lines")
        }
        PointerAction::Wheel(WheelDelta::Pixels { x, y }) => {
            format!("wheel {x} across and {y} down in pixels")
        }
    };
    format!(
        "pointer {what} at ({}, {}) with {}",
        pointer.x,
        pointer.y,
        held(pointer.modifiers)
    )
}

/// One thing the window reported, for a person: one line.
fn described(input: &Input) -> String {
    match input {
        Input::Opened { platform } => format!("opened by {platform}"),
        Input::Focus(true) => "focus gained".to_owned(),
        Input::Focus(false) => "focus lost".to_owned(),
        Input::Key(pressed) => key(pressed),
        Input::Composition(Composition::Enabled) => "composition enabled".to_owned(),
        Input::Composition(Composition::Preedit(text)) => format!("composition preedit {text:?}"),
        Input::Composition(Composition::Commit(text)) => format!("composition commit {text:?}"),
        Input::Composition(Composition::Disabled) => "composition disabled".to_owned(),
        Input::Pointer(did) => pointer(did),
        Input::Resized(size) => format!(
            "resized {} by {} at scale {}",
            size.width, size.height, size.scale
        ),
        Input::CloseRequested => "close requested".to_owned(),
    }
}

/// The input `event` stands for, read back from the event as Lean reads
/// it: its kind, its code, its text and its words, each word as eight
/// bytes, least significant first.
fn read_back(event: &Event) -> Option<Input> {
    let words: Vec<u8> = event
        .words
        .iter()
        .flat_map(|word| word.to_le_bytes())
        .collect();
    window::input(event.kind, event.code, &event.text, &words)
}

/// The editor's part, on a thread of its own: pulls `queue` until it is
/// quit, prints each input, publishes the fixture frame laid out for each
/// size the window says it has, and closes the window when it is asked to.
fn edit(queue: &Queue, session: &Session<Watched>, shared: &Shared) -> Result<(), String> {
    let mut layout = layout()?;
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
                    let frame: Arc<Frame> = Arc::new(layout.frame(&scene(size)));
                    // Entered before it is handed over: no draw of it is
                    // entered first.
                    shared.ledger.published(&frame);
                    handle.submit(frame, Some(event.stamp));
                }
            }
            Input::CloseRequested => PLATFORM.close(),
            _ => {}
        }
    }
}

/// Watches the window from a thread of its own: waits for the first frame
/// and for whatever else was asked as the window opened to be drawn, then
/// leaves the window alone for [`IDLE`] and enters in the ledger when
/// that second began and ended, says the window is ready for input, and
/// closes the window `stay` later if nobody has.
///
/// The idle second begins settled, when it can: with nothing asked for
/// that is not yet drawn. A window is asked for more than its first frame
/// as it opens (on macOS the system asks for its content while that frame
/// is being drawn), and a second that began the moment the first frame
/// was presented would see that drawn and nothing ask for it.
fn watch(session: &Session<Watched>, shared: &Shared, stay: Duration) {
    let began = Instant::now();
    let presented = || session.handle().map_or(0, |handle| handle.counters().draws);
    while presented() == 0 && began.elapsed() < FIRST_FRAME {
        thread::sleep(Duration::from_millis(10));
    }
    if presented() > 0 {
        let shown = Instant::now();
        while !shared.ledger.settled() && shown.elapsed() < SETTLE {
            thread::sleep(Duration::from_millis(10));
        }
        shared.ledger.note(Happened::Idle(true));
        thread::sleep(IDLE);
        shared.ledger.note(Happened::Idle(false));
    }
    println!("window: ready for input");
    thread::sleep(stay);
    PLATFORM.close();
}

/// What was found, printed; and why the check fails, when it does, in a
/// run that requires every frame's picture to be compared when
/// `require_picture` says so.
fn report(session: &Session<Watched>, shared: &Shared, require_picture: bool) -> Vec<String> {
    let mut failures = Vec::new();
    match locked(&shared.adapter).as_deref() {
        Some(adapter) => println!("window: the renderer is on {adapter}"),
        None => println!("window: no renderer was made"),
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
    let pictures = locked(&shared.pictures);
    for (number, picture) in pictures.iter().enumerate() {
        let verdict = judged(number + 1, picture, require_picture);
        if let Some(line) = verdict.line {
            println!("window: {line}");
        }
        failures.extend(verdict.failure);
    }
    drop(pictures);

    // 3. Nothing is drawn that nothing asked for.
    let (records, tally) = shared.ledger.read();
    let opened_ns = records.first().map_or(0, |(at_ns, _)| *at_ns);
    // What a line says of a draw depends only on what came before it, so
    // the lines printed are made from the records printed and no more.
    let printed = records.len().min(TIMELINE);
    for line in timeline(&records[..printed]) {
        println!("window: at {line}");
    }
    if records.len() > printed {
        println!(
            "window: and {} things more, not printed",
            records.len() - printed
        );
    }
    for entry in journal.iter().take(TIMELINE) {
        println!("window: {}", journalled(entry, opened_ns));
    }
    let found = on_demand(&tally, opened_ns, counters.draws + counters.draws_failed);
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
    let Some(Options {
        stay,
        require_picture,
    }) = options(&arguments)
    else {
        eprintln!("usage: window [--seconds <n>] [--require-picture]");
        return ExitCode::from(2);
    };
    // One clock stamps the input, times the frames and stamps the ledger:
    // the journal's time from an input to its frame is a subtraction on
    // it, and so is the time from what asked for a draw to the draw.
    let clock = Arc::new(Monotonic::new());
    let shared = Arc::new(Shared::new(clock.clone()));
    let queue = Arc::new(Queue::new());
    let session = {
        let shared = Arc::clone(&shared);
        Session::new(clock.clone(), move |window, _| {
            let inner = renderer(window, &shared)?;
            let ledger = Arc::clone(&shared.ledger);
            Ok(Entered { inner, ledger })
        })
    };

    let editor = {
        let (queue, session, shared) = (Arc::clone(&queue), session.clone(), Arc::clone(&shared));
        thread::spawn(move || edit(&queue, &session, &shared))
    };
    {
        let (session, shared) = (session.clone(), Arc::clone(&shared));
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
        drawer,
    );
    queue.quit();
    let edited = editor
        .join()
        .unwrap_or_else(|_| Err("the editor's thread panicked".to_owned()));

    let mut failures = report(&session, &shared, require_picture);
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

/// What the example decides of what it saw, with no window: these run in
/// the gate.
#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use editor_layout::Layout;
    use editor_layout::frame::Frame;
    use editor_layout::scene::{Rect, Scene};
    use editor_layout::shaper::fake::CellShaper;
    use editor_platform::{Canvas, Drawer, Resize};
    use editor_render::clock::FakeClock;
    use editor_render::fake::RecordingRenderer;
    use editor_render::journal::Entry;
    use editor_render::port::{DrawRequest, Renderer, Target};

    use super::{
        Draw, Entered, Findings, Happened, IDLE_ASKS, Idle, Ledger, Options, Picture, Served,
        TOLERANCE, Tally, Verdict, entering, happened, journalled, judged, on_demand, options,
        timeline, uncompared,
    };

    /// A size a window has.
    const SMALL: Target = Target {
        width: 400,
        height: 300,
        scale: 1.0,
    };

    /// Another.
    const LARGE: Target = Target {
        width: 800,
        height: 600,
        scale: 2.0,
    };

    /// A millisecond, in nanoseconds.
    const MS: u64 = 1_000_000;

    /// A draw of frame `frame` on `target` begins.
    fn began(frame: usize, target: Target) -> Happened {
        Happened::Began {
            frame: Some(frame),
            target,
        }
    }

    /// The draw last begun presented.
    const PRESENTED: Happened = Happened::Ended { presented: true };

    /// The draw last begun did not present.
    const REFUSED: Happened = Happened::Ended { presented: false };

    /// `happened`, each a millisecond after the one before, the first at a
    /// millisecond.
    fn records(happened: &[Happened]) -> Vec<(u64, Happened)> {
        (1..)
            .map(|at| at * MS)
            .zip(happened.iter().cloned())
            .collect()
    }

    /// What `happened` comes to.
    fn tallied(happened: &[Happened]) -> Tally {
        let mut tally = Tally::default();
        for (at_ns, happened) in records(happened) {
            tally.note(at_ns, &happened);
        }
        tally
    }

    /// What each draw of `tally` was for, in order.
    fn served(tally: &Tally) -> Vec<Served> {
        tally.draws.iter().map(|draw| draw.served).collect()
    }

    /// A draw for a frame alone, for a size alone, for damage alone.
    const FRAME: Served = Served {
        frame: true,
        size: false,
        damage: false,
    };
    const SIZE: Served = Served {
        frame: false,
        size: true,
        damage: false,
    };
    const DAMAGE: Served = Served {
        frame: false,
        size: false,
        damage: true,
    };

    /// A window that opened at `SMALL` and shows frame 1 there.
    fn showing() -> Vec<Happened> {
        vec![
            Happened::Opened {
                size: SMALL,
                refresh: None,
            },
            Happened::Published(1),
            began(1, SMALL),
            PRESENTED,
        ]
    }

    /// `first`, then `then`.
    fn and(first: Vec<Happened>, then: &[Happened]) -> Vec<Happened> {
        first.into_iter().chain(then.iter().cloned()).collect()
    }

    #[test]
    fn a_draw_is_for_the_frame_the_size_and_the_damage_it_is_the_first_to_answer() {
        let tally = tallied(&and(
            showing(),
            &[
                // The window is resized: the frame shown is drawn again
                // there.
                Happened::Resized(LARGE),
                began(1, LARGE),
                PRESENTED,
                // The window says it is damaged: the same again.
                Happened::Damaged,
                began(1, LARGE),
                PRESENTED,
                // A new frame, with damage told as well, and twice: one
                // draw is for both.
                Happened::Published(2),
                Happened::Damaged,
                Happened::Damaged,
                began(2, LARGE),
                PRESENTED,
            ],
        ));
        assert_eq!(
            served(&tally),
            [
                FRAME,
                SIZE,
                DAMAGE,
                Served {
                    frame: true,
                    size: false,
                    damage: true,
                },
            ]
        );
        assert_eq!(tally.unasked(), []);
        assert!(tally.settled());
    }

    #[test]
    fn a_draw_of_what_is_shown_where_it_is_shown_with_no_damage_told_is_for_nothing() {
        // The frame shown is drawn again and again, and nobody asked.
        let storm = [
            began(1, SMALL),
            PRESENTED,
            began(1, SMALL),
            PRESENTED,
            began(1, SMALL),
        ];
        let tally = tallied(&and(showing(), &storm));
        assert_eq!(
            served(&tally),
            [
                FRAME,
                Served::default(),
                Served::default(),
                Served::default()
            ]
        );
        let unasked: Vec<usize> = tally.unasked().iter().map(|(number, _)| *number).collect();
        assert_eq!(unasked, [2, 3, 4]);
        // Each with when it began: the fifth thing that happened, at 5 ms.
        assert_eq!(tally.unasked()[0].1.began_ns, 5 * MS);
    }

    #[test]
    fn what_is_asked_while_a_draw_is_in_progress_is_for_the_next_draw() {
        // What a desktop did as its window opened: while the first frame
        // was being drawn the window said its size three times more, the
        // same frame was published for each, and the system asked for the
        // content again.
        let opening = [
            Happened::Opened {
                size: LARGE,
                refresh: Some(120_000),
            },
            Happened::Published(1),
            began(1, LARGE),
            Happened::Resized(LARGE),
            Happened::Published(1),
            Happened::Resized(LARGE),
            Happened::Published(1),
            Happened::Resized(LARGE),
            Happened::Published(1),
            Happened::Damaged,
            PRESENTED,
        ];
        let first = tallied(&opening);
        // The first frame is shown, and the window is not settled: the
        // damage is still to be answered. The size and the frame said
        // again ask for nothing.
        assert_eq!(first.wanted(), DAMAGE);
        assert!(!first.settled());

        // The draw that answers it is for the damage, and then nothing is
        // left.
        let second = tallied(&and(opening.to_vec(), &[began(1, LARGE), PRESENTED]));
        assert_eq!(served(&second), [FRAME, DAMAGE]);
        assert_eq!(second.unasked(), []);
        assert_eq!(second.wanted(), Served::default());
        assert!(second.settled());

        // What was said again gave nothing to draw for: a third draw is
        // for nothing.
        let third = tallied(&and(
            opening.to_vec(),
            &[began(1, LARGE), PRESENTED, began(1, LARGE), PRESENTED],
        ));
        assert_eq!(served(&third), [FRAME, DAMAGE, Served::default()]);
    }

    #[test]
    fn a_draw_that_did_not_present_leaves_what_it_was_for_to_the_next() {
        let tally = tallied(&and(
            showing(),
            &[
                Happened::Damaged,
                began(1, SMALL),
                REFUSED,
                // Tried again: still for the damage.
                began(1, SMALL),
                PRESENTED,
                // A new frame and a new size, refused, then drawn.
                Happened::Published(2),
                Happened::Resized(LARGE),
                began(2, LARGE),
                REFUSED,
                began(2, LARGE),
                PRESENTED,
                // And then nothing is left to draw for.
                began(2, LARGE),
                PRESENTED,
            ],
        ));
        let both = Served {
            frame: true,
            size: true,
            damage: false,
        };
        assert_eq!(
            served(&tally),
            [FRAME, DAMAGE, DAMAGE, both, both, Served::default()]
        );
        assert_eq!(
            tally
                .draws
                .iter()
                .map(|draw| draw.presented)
                .collect::<Vec<_>>(),
            [true, false, true, false, true, true]
        );
    }

    #[test]
    fn a_window_is_settled_once_what_was_asked_is_shown_and_no_draw_is_in_progress() {
        let opened = Happened::Opened {
            size: SMALL,
            refresh: None,
        };
        // Nothing is shown yet.
        assert!(!tallied(std::slice::from_ref(&opened)).settled());
        let published = [opened, Happened::Published(1)];
        assert_eq!(tallied(&published).wanted(), FRAME);
        // Nor while the first draw is in progress.
        let drawing = and(published.to_vec(), &[began(1, SMALL)]);
        assert!(!tallied(&drawing).settled());
        // Shown: settled.
        assert!(tallied(&showing()).settled());

        // A frame published and not yet shown, a size told and not yet
        // drawn at, and damage not yet answered each unsettle it.
        for (asked, wanted) in [
            (Happened::Published(2), FRAME),
            (Happened::Resized(LARGE), SIZE),
            (Happened::Damaged, DAMAGE),
        ] {
            let tally = tallied(&and(showing(), &[asked]));
            assert_eq!(tally.wanted(), wanted);
            assert!(!tally.settled());
        }
        // The frame shown, published again, the size drawn at, told again,
        // and what else a window tells do not.
        for said in [
            Happened::Published(1),
            Happened::Resized(SMALL),
            Happened::Told("Hidden(false)".to_owned()),
        ] {
            let tally = tallied(&and(showing(), std::slice::from_ref(&said)));
            assert!(tally.settled(), "{said:?}");
        }
        // A size told and then the old one again leaves nothing to draw.
        let back = [Happened::Resized(LARGE), Happened::Resized(SMALL)];
        assert!(tallied(&and(showing(), &back)).settled());
    }

    #[test]
    fn the_idle_second_counts_what_asked_in_it_and_the_draws_that_began_in_it() {
        // Before it has begun, nothing is known of it.
        assert_eq!(tallied(&showing()).idle, None);

        let tally = tallied(&and(
            showing(),
            &[
                Happened::Idle(true),
                Happened::Damaged,
                began(1, SMALL),
                PRESENTED,
                Happened::Resized(LARGE),
                began(1, LARGE),
                // It ends while a draw is in progress: the draw began in
                // it.
                Happened::Idle(false),
                PRESENTED,
                // What comes after is not of it.
                Happened::Damaged,
                began(1, LARGE),
                PRESENTED,
            ],
        ));
        assert_eq!(
            tally.idle,
            Some(Idle {
                settled: true,
                drawn: 2,
                asked: 2,
            })
        );
        assert_eq!(
            tally.draws.iter().map(|draw| draw.idle).collect::<Vec<_>>(),
            [false, true, true, false]
        );

        // One that began before the window had settled says so, and a
        // draw that did not present is not counted.
        let unsettled = tallied(&and(
            showing(),
            &[
                Happened::Damaged,
                Happened::Idle(true),
                began(1, SMALL),
                REFUSED,
                Happened::Idle(false),
            ],
        ));
        assert_eq!(
            unsettled.idle,
            Some(Idle {
                settled: false,
                drawn: 0,
                asked: 0,
            })
        );
    }

    #[test]
    fn a_frame_published_a_new_size_and_damage_each_ask_and_nothing_else_does() {
        let tally = tallied(&and(
            showing(),
            &[
                Happened::Published(1),
                Happened::Resized(SMALL),
                Happened::Damaged,
                Happened::Told("Refresh(Some(60000))".to_owned()),
                Happened::Idle(true),
                Happened::Idle(false),
            ],
        ));
        // The frame published as the window opened, and these three: the
        // count is of what asked, whether or not it gave anything to draw.
        assert_eq!(tally.asked, 4);
    }

    /// A tally of `draws` draws, the idle second as `idle`, and `asked`
    /// things that asked.
    fn tally_of(draws: &[Draw], idle: Option<Idle>, asked: u64) -> Tally {
        Tally {
            draws: draws.to_vec(),
            idle,
            asked,
            ..Tally::default()
        }
    }

    /// A draw that began at `began_ns` and presented, for `served`.
    fn draw(began_ns: u64, served: Served) -> Draw {
        Draw {
            began_ns,
            presented: true,
            served,
            idle: false,
        }
    }

    /// An idle second that began settled.
    fn idle(drawn: u64, asked: u64) -> Option<Idle> {
        Some(Idle {
            settled: true,
            drawn,
            asked,
        })
    }

    #[test]
    fn draws_that_were_each_asked_for_pass_and_say_what_the_idle_second_showed() {
        let tally = tally_of(
            &[draw(5 * MS, FRAME), draw(900 * MS, DAMAGE)],
            idle(0, 0),
            8,
        );
        assert_eq!(
            on_demand(&tally, MS, 2),
            Findings {
                lines: vec![
                    "idle: over 1 s in which nothing was published, 0 frames were drawn and the window asked for 0".to_owned(),
                    "over the whole run, 2 draws for 8 things that asked for one".to_owned(),
                ],
                failures: Vec::new(),
            }
        );
        // A window that asked in its idle second, and was drawn for it.
        let asked = on_demand(&tally_of(&[draw(5 * MS, FRAME)], idle(2, 2), 3), MS, 1);
        assert_eq!(
            asked.lines[0],
            "idle: over 1 s in which nothing was published, 2 frames were drawn and the window asked for 2"
        );
        assert_eq!(asked.failures, [] as [String; 0]);
    }

    #[test]
    fn a_draw_for_nothing_fails_wherever_it_is_and_says_which_and_when() {
        let storm = [
            draw(5 * MS, FRAME),
            draw(1_500 * MS + MS / 2, Served::default()),
            draw(1_600 * MS, Served::default()),
        ];
        // Whatever the idle second showed, and however many things asked.
        let found = on_demand(&tally_of(&storm, idle(0, 0), 9), MS, 3);
        assert_eq!(
            found.failures,
            [
                "2 of the 3 draws were asked for by nothing: the first is draw 2, which began 1499.5 ms after the window opened"
            ]
        );
    }

    #[test]
    fn more_frames_drawn_in_an_idle_second_than_were_asked_for_in_it_fails() {
        let found = on_demand(&tally_of(&[draw(5 * MS, FRAME)], idle(10, 0), 20), MS, 1);
        assert_eq!(
            found.failures,
            ["10 frames were drawn while idle and 0 were asked for"]
        );
        // Unless the second began before the window had settled: what was
        // drawn in it may be for that, and each draw is judged by itself.
        let unsettled = Some(Idle {
            settled: false,
            drawn: 1,
            asked: 0,
        });
        let found = on_demand(&tally_of(&[draw(5 * MS, FRAME)], unsettled, 2), MS, 1);
        assert_eq!(found.failures, [] as [String; 0]);
        assert_eq!(
            found.lines[0],
            "idle: the second began before the window had settled: a draw was in progress, or something asked for was not yet drawn"
        );
    }

    #[test]
    fn a_window_that_asks_again_and_again_while_idle_fails_as_a_timer() {
        let asks = IDLE_ASKS + 1;
        let most = on_demand(&tally_of(&[], idle(0, IDLE_ASKS), IDLE_ASKS), MS, 0);
        assert_eq!(most.failures, [] as [String; 0]);
        let found = on_demand(&tally_of(&[], idle(0, asks), asks), MS, 0);
        assert_eq!(
            found.failures,
            [format!(
                "the window asked to be drawn {asks} times while idle: more than {IDLE_ASKS} is a timer"
            )]
        );
    }

    #[test]
    fn a_window_never_seen_idle_and_more_draws_than_things_that_asked_fail() {
        let found = on_demand(&tally_of(&[draw(5 * MS, FRAME)], None, 1), MS, 1);
        assert_eq!(
            found.failures,
            ["the window was never seen idle: no frame was presented"]
        );
        // The loop counts its draws, presented or not: three for two asks.
        let found = on_demand(
            &tally_of(
                &[
                    draw(5 * MS, FRAME),
                    draw(6 * MS, FRAME),
                    draw(7 * MS, FRAME),
                ],
                idle(0, 0),
                2,
            ),
            MS,
            3,
        );
        assert_eq!(found.failures, ["3 draws were made and 2 were asked for"]);
        // And the renderer was asked for as many draws as the loop counts.
        let found = on_demand(&tally_of(&[draw(5 * MS, FRAME)], idle(0, 0), 4), MS, 2);
        assert_eq!(
            found.failures,
            ["the render loop counts 2 draws and its renderer was asked for 1"]
        );
    }

    #[test]
    fn the_timeline_says_each_thing_with_its_time_since_the_window_opened() {
        let lines = timeline(&records(&[
            Happened::Opened {
                size: LARGE,
                refresh: Some(120_000),
            },
            Happened::Published(1),
            began(1, LARGE),
            Happened::Resized(LARGE),
            Happened::Published(1),
            Happened::Damaged,
            Happened::Told("Hidden(true)".to_owned()),
            PRESENTED,
            began(1, LARGE),
            REFUSED,
            Happened::Idle(true),
            Happened::Published(2),
            Happened::Resized(SMALL),
            began(2, SMALL),
            PRESENTED,
            began(2, SMALL),
            Happened::Idle(false),
            Happened::Began {
                frame: None,
                target: SMALL,
            },
        ]));
        assert_eq!(
            lines,
            [
                "      0.0 ms: the window told its drawer it opened, 800 by 600 at scale 2, on a display that refreshes 120000 thousandths of a hertz",
                "      1.0 ms: frame 1 was published",
                "      2.0 ms: draw 1 began, of frame 1 on 800 by 600 at scale 2, for a frame not yet shown",
                "      3.0 ms: the window told its drawer it is 800 by 600 at scale 2",
                "      4.0 ms: frame 1 was published again",
                "      5.0 ms: the window told its drawer it is damaged",
                "      6.0 ms: the window told its drawer Hidden(true)",
                "      7.0 ms: draw 1 ended, presented",
                "      8.0 ms: draw 2 began, of frame 1 on 800 by 600 at scale 2, for damage",
                "      9.0 ms: draw 2 ended, not presented",
                "     10.0 ms: the idle second began, before the window had settled",
                "     11.0 ms: frame 2 was published",
                "     12.0 ms: the window told its drawer it is 400 by 300 at scale 1",
                "     13.0 ms: draw 3 began, of frame 2 on 400 by 300 at scale 1, for a frame not yet shown, a size not yet drawn at and damage",
                "     14.0 ms: draw 3 ended, presented",
                "     15.0 ms: draw 4 began, of frame 2 on 400 by 300 at scale 1, for nothing that was asked",
                "     16.0 ms: the idle second ended",
                "     17.0 ms: draw 5 began, of a frame nobody published on 400 by 300 at scale 1, for a frame not yet shown",
            ]
        );
        assert_eq!(timeline(&[]), [] as [String; 0]);

        // A display that does not say how often it refreshes, and an idle
        // second that began with nothing left to draw.
        let quiet = timeline(&records(&and(showing(), &[Happened::Idle(true)])));
        assert_eq!(
            quiet[0],
            "      0.0 ms: the window told its drawer it opened, 400 by 300 at scale 1, on a display that does not say how often it refreshes"
        );
        assert_eq!(quiet[4], "      4.0 ms: the idle second began");
    }

    #[test]
    fn a_journal_entry_says_when_what_it_answers_was_asked_and_when_it_was_drawn() {
        let entry = Entry {
            serial: 2,
            input_ns: 13 * MS + MS / 4,
            draw_ns: 588 * MS,
            present_ns: 801 * MS + MS / 2,
            rows_rebuilt: 0,
            rows_reused: 3,
        };
        assert_eq!(
            journalled(&entry, MS),
            "the journal's frame 2 answers something asked 12.2 ms after the window opened: its draw began at 587.0 ms and it was presented at 800.5 ms"
        );
    }

    #[test]
    fn what_a_window_tells_its_drawer_is_what_the_ledger_takes_it_for() {
        let size = Resize {
            width: 800,
            height: 600,
            scale: 2.0,
        };
        assert_eq!(
            happened(&Canvas::Opened {
                window: None,
                size,
                refresh_millihertz: Some(60_000),
            }),
            Happened::Opened {
                size: LARGE,
                refresh: Some(60_000),
            }
        );
        assert_eq!(happened(&Canvas::Resized(size)), Happened::Resized(LARGE));
        assert_eq!(happened(&Canvas::Damaged), Happened::Damaged);
        // What asks for no draw is kept as it prints.
        for (canvas, said) in [
            (Canvas::Hidden(true), "Hidden(true)"),
            (Canvas::Refresh(Some(50_000)), "Refresh(Some(50000))"),
            (Canvas::Closing, "Closing"),
        ] {
            assert_eq!(happened(&canvas), Happened::Told(said.to_owned()));
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

    /// A ledger on a clock that moves on a millisecond at every reading.
    fn ledger() -> Arc<Ledger> {
        Arc::new(Ledger::new(Arc::new(FakeClock::stepping(MS))))
    }

    /// What was entered in `ledger`, without the times.
    fn entered(ledger: &Ledger) -> Vec<Happened> {
        let (records, _) = ledger.read();
        records.into_iter().map(|(_, happened)| happened).collect()
    }

    #[test]
    fn frames_published_are_numbered_from_one_and_equal_frames_are_one_frame() {
        let ledger = ledger();
        let one = frame_of("one");
        assert_eq!(ledger.published(&one), 1);
        // The same value again, and another that is equal to it.
        assert_eq!(ledger.published(&one), 1);
        assert_eq!(ledger.published(&frame_of("one")), 1);
        assert_eq!(ledger.published(&frame_of("two")), 2);
        // The first again, after another: still the first.
        assert_eq!(ledger.published(&frame_of("one")), 1);
        assert_eq!(entered(&ledger), [1, 1, 1, 2, 1].map(Happened::Published));
        // Each is stamped as it is entered, on the ledger's clock.
        let (records, tally) = ledger.read();
        let stamps: Vec<u64> = records.iter().map(|(at_ns, _)| *at_ns).collect();
        assert_eq!(stamps, [1, 2, 3, 4, 5].map(|at| at * MS + 1));
        // And taken in by the tally.
        assert_eq!(tally.asked, 5);
    }

    #[test]
    fn a_draw_is_entered_as_it_begins_and_as_it_ends_with_whether_it_presented() {
        let ledger = ledger();
        let mut renderer = Entered {
            inner: RecordingRenderer::new(),
            ledger: Arc::clone(&ledger),
        };
        let (one, two) = (frame_of("one"), frame_of("two"));
        ledger.published(&one);
        ledger.published(&two);

        let drawn = renderer.draw(&DrawRequest {
            frame: &two,
            target: SMALL,
        });
        assert!(drawn.presented);
        // A draw that does not present, of a frame equal to one published.
        renderer.inner.fail_next_present();
        let again = frame_of("one");
        let refused = renderer.draw(&DrawRequest {
            frame: &again,
            target: LARGE,
        });
        assert!(!refused.presented);
        // And of a frame nobody published.
        renderer.draw(&DrawRequest {
            frame: &frame_of("three"),
            target: LARGE,
        });

        assert_eq!(
            entered(&ledger)[2..],
            [
                began(2, SMALL),
                PRESENTED,
                began(1, LARGE),
                REFUSED,
                Happened::Began {
                    frame: None,
                    target: LARGE,
                },
                PRESENTED,
            ]
        );
        // The renderer was asked for each.
        assert_eq!(renderer.inner.requests().len(), 3);
        assert!(!ledger.settled());
    }

    #[test]
    fn what_the_window_tells_is_entered_before_the_drawer_hears_it() {
        let ledger = ledger();
        // What the drawer heard, and how much was entered when it did.
        let heard = Arc::new(Mutex::new(Vec::new()));
        let drawer: Drawer = {
            let (heard, ledger) = (Arc::clone(&heard), Arc::clone(&ledger));
            Arc::new(move |canvas| {
                let entered = ledger.read().0.len();
                heard
                    .lock()
                    .expect("nothing panics holding it")
                    .push((format!("{canvas:?}"), entered));
            })
        };
        let drawer = entering(drawer, Arc::clone(&ledger));

        drawer(Canvas::Damaged);
        drawer(Canvas::Hidden(true));

        assert_eq!(
            *heard.lock().expect("nothing panics holding it"),
            [("Damaged".to_owned(), 1), ("Hidden(true)".to_owned(), 2)]
        );
        assert_eq!(
            entered(&ledger),
            [Happened::Damaged, Happened::Told("Hidden(true)".to_owned())]
        );
    }

    #[test]
    fn the_command_line_says_how_long_the_window_stays_and_whether_a_picture_is_required() {
        let asked = |stay, require_picture| {
            Some(Options {
                stay: Duration::from_secs(stay),
                require_picture,
            })
        };
        assert_eq!(options(&[]), asked(20, false));
        assert_eq!(options(&["--seconds", "6"]), asked(6, false));
        assert_eq!(options(&["--require-picture"]), asked(20, true));
        // In either order.
        assert_eq!(
            options(&["--seconds", "6", "--require-picture"]),
            asked(6, true)
        );
        assert_eq!(
            options(&["--require-picture", "--seconds", "6"]),
            asked(6, true)
        );
    }

    #[test]
    fn a_command_line_that_is_not_understood_gives_no_options() {
        for arguments in [
            &["--seconds"][..],
            &["--seconds", "soon"],
            &["--seconds", "--require-picture"],
            &["--require-pictures"],
            &["6"],
        ] {
            assert_eq!(options(arguments), None, "{arguments:?}");
        }
    }

    #[test]
    fn a_surface_that_is_not_copied_from_has_no_picture_and_a_read_that_was_refused_is_unread() {
        // Whatever the renderer then said of reading it.
        assert_eq!(uncompared(false, None), Some(Picture::NotCopied));
        assert_eq!(
            uncompared(false, Some("not copied from")),
            Some(Picture::NotCopied)
        );
        assert_eq!(
            uncompared(true, Some("the copy was refused")),
            Some(Picture::Unread("the copy was refused".to_owned()))
        );
        // Read: there is a picture to compare.
        assert_eq!(uncompared(true, None), None);
    }

    #[test]
    fn a_picture_within_the_tolerance_passes_and_one_past_it_fails() {
        let compared = |worst| Picture::Compared {
            pixels: 100,
            differing: 7,
            worst,
        };
        for require_picture in [false, true] {
            let within = judged(2, &compared(TOLERANCE), require_picture);
            assert_eq!(
                within,
                Verdict {
                    line: Some(format!(
                        "frame 2: read back from the surface, 7 of 100 pixels differ from the headless renderer's, the worst by {TOLERANCE} of 255"
                    )),
                    failure: None,
                }
            );
            let past = judged(2, &compared(TOLERANCE + 1), require_picture);
            assert!(past.line.is_some(), "{past:?}");
            assert_eq!(
                past.failure,
                Some(format!(
                    "frame 2's picture differs by {} of 255, past the tolerance of {TOLERANCE}",
                    TOLERANCE + 1
                ))
            );
        }
    }

    #[test]
    fn a_picture_of_the_wrong_size_fails() {
        for require_picture in [false, true] {
            assert_eq!(
                judged(1, &Picture::WrongSize(0, 0), require_picture).failure,
                Some("frame 1's picture is 0 by 0, not the size of its target".to_owned())
            );
        }
    }

    #[test]
    fn a_picture_that_could_not_be_read_back_fails_whether_or_not_one_is_required() {
        let unread = Picture::Unread("the copy was refused".to_owned());
        for require_picture in [false, true] {
            assert_eq!(
                judged(3, &unread, require_picture).failure,
                Some("frame 3's picture could not be read back: the copy was refused".to_owned()),
                "required: {require_picture}"
            );
        }
    }

    #[test]
    fn a_surface_that_is_not_copied_from_fails_only_a_run_that_requires_the_picture() {
        let said = Some(
            "frame 1: the surface does not let its texture be copied from, so its picture is not compared"
                .to_owned(),
        );
        assert_eq!(
            judged(1, &Picture::NotCopied, false),
            Verdict {
                line: said.clone(),
                failure: None,
            }
        );
        assert_eq!(
            judged(1, &Picture::NotCopied, true),
            Verdict {
                line: said,
                failure: Some(
                    "frame 1's picture was not compared, and this run requires it (--require-picture): the surface does not let its texture be copied from"
                        .to_owned()
                ),
            }
        );
    }
}
