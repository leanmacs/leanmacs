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
//!   pixel ([`laid_out`]).
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
//!    no damage told, fails the run, whenever it happens. The window is
//!    also left alone for a second, once it has drawn what was asked of it
//!    as it opened: no more frames are drawn in that second than the
//!    window asked for in it by being resized or damaged, which is none
//!    when the window is left alone; and over the whole run no more draws
//!    are made, presented or not, than things asked for one. A window that
//!    asks again and again in that second, more than a system uncovering
//!    it would, fails too: that is a timer by another name.
//! 4. **Input arrived on the queue**: at least one key or pointer event.
//! 5. **Left alone, the window shows what was laid out for it.** Whenever
//!    a second passes in which the window tells its drawer nothing, no
//!    frame is published and no draw begins or ends, and the window has
//!    not said it is hidden, the draw last presented must be of a frame
//!    laid out for the size and the scale the window last said, on that
//!    size and scale ([`left_alone`]). It prints `window: left alone <k>
//!    times, and each time the window showed what was laid out for it`, or
//!    fails with which frame, laid out for what, was on what. This is "no
//!    stale frame", and "no frame of one scale left on a window at
//!    another", for as often as the window is left for a second: the idle
//!    second is the first such time, and a person makes the rest by
//!    waiting a second after a resize, a move to another display, going
//!    into fullscreen and out of it, and coming back from another Space.
//!    What the window shows between two sizes, while it is not left alone,
//!    is not judged: no program here can see it.
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
//! published, each draw as the renderer is entered and as it answers (with
//! the kind of mask the renderer says it drew its glyphs with: plain ones
//! or subpixel ones, which is how a change of antialiasing between two
//! displays is seen), and
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
//! is read, what is made of each thing found of a picture, which sizes a
//! frame's glyphs are drawn at and which of them fail, what each draw of a
//! ledger was for, which ledgers fail, and which ledgers show a window
//! left alone with something not laid out for it (`cargo test` runs them: the
//! manifest says `test = true` of this example). They state no size of
//! layout's and no rule of the renderer's: the frames they read are
//! written by hand, and a kind of mask is printed in the renderer's own
//! words.

use std::process::ExitCode;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread;
use std::time::{Duration, Instant};

use editor_ffi::events::{Event, EventKind, Queue};
use editor_ffi::interrupt::Interrupt;
use editor_ffi::render::{Presenter, Session, target};
use editor_ffi::window::{self, Monotonic};
use editor_layout::Layout;
use editor_layout::face::{Color, Face, FaceDef};
use editor_layout::frame::Frame;
use editor_layout::scene::{Rect, Scene, StatusField};
use editor_layout::shaper::Length;
use editor_platform::{
    Button, Canvas, Composition, Drawer, Input, Key, LogicalKey, Modifiers, NativeWindow,
    PhysicalKey, Platform, Pointer, PointerAction, Resize, WheelDelta, WindowOptions,
};
use editor_platform_winit::WinitPlatform;
use editor_render::clock::Clock;
use editor_render::journal::Entry;
use editor_render::port::{DrawRequest, Drawn, Renderer, Target};
use editor_render_wgpu::{Antialiasing, HeadlessRenderer, Image, Masks, Settings, WgpuRenderer};
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

/// The size the fixture's default face states, in points: what a person
/// compares with the same size in another app.
const POINTS: u32 = 14;

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

/// How many lines of the timeline, and of the journal, are printed of a
/// window a person kept open (`--until-closed`): a drag between two
/// displays, an animation into fullscreen and one out of it are some
/// hundreds of sizes each.
const TIMELINE_BY_HAND: usize = 5000;

/// How long a window must be told nothing, with nothing published and no
/// draw begun or ended, to count as left alone.
const ALONE: Duration = Duration::from_secs(1);

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
#[derive(Debug, Clone, PartialEq, Eq)]
struct Options {
    /// How long the window stays once it is ready, if nobody closes it;
    /// `None` when it stays until a person closes it.
    stay: Option<Duration>,
    /// Whether every frame's picture must be compared for the run to pass.
    require_picture: bool,
    /// Whether each frame's picture is read back and compared at all.
    read_picture: bool,
    /// The family of the machine's fonts the fixture is laid out in;
    /// `None` for the fixture fonts.
    family: Option<String>,
}

/// The options `arguments` ask for; `None` when they are not understood.
/// Two pairs contradict each other and are not understood together: a
/// time to stay (`--seconds`) with staying until closed
/// (`--until-closed`), and a picture required (`--require-picture`) with
/// none read (`--no-picture`). A family is a name: not nothing, and not
/// another option.
fn options(arguments: &[&str]) -> Option<Options> {
    let mut options = Options {
        stay: Some(Duration::from_secs(20)),
        require_picture: false,
        read_picture: true,
        family: None,
    };
    // Whether a time to stay was given, and whether staying was.
    let (mut timed, mut until_closed) = (false, false);
    let mut rest = arguments;
    loop {
        rest = match rest {
            [] => break,
            ["--seconds", seconds, rest @ ..] => {
                options.stay = Some(Duration::from_secs(seconds.parse().ok()?));
                timed = true;
                rest
            }
            ["--require-picture", rest @ ..] => {
                options.require_picture = true;
                rest
            }
            ["--until-closed", rest @ ..] => {
                until_closed = true;
                rest
            }
            ["--no-picture", rest @ ..] => {
                options.read_picture = false;
                rest
            }
            ["--family", name, rest @ ..] if !name.is_empty() && !name.starts_with("--") => {
                options.family = Some((*name).to_owned());
                rest
            }
            _ => return None,
        };
    }
    if until_closed {
        options.stay = None;
    }
    let contradicts = (timed && until_closed) || (options.require_picture && !options.read_picture);
    (!contradicts).then_some(options)
}

/// The machine's own name for the family `name`, of `families`, the
/// families it has: the one that is `name` whatever the case of its
/// letters. The error is that it has none, for a person.
fn family_of(name: &str, families: &[String]) -> Result<String, String> {
    families
        .iter()
        .find(|family| family.eq_ignore_ascii_case(name))
        .cloned()
        .ok_or_else(|| {
            format!(
                "this machine has no font family named {name}, of its {} families",
                families.len()
            )
        })
}

/// What is made of `pictures`, what each frame presented was found to be,
/// in order, in a run that reads pictures back when `read` says so and
/// requires each to be compared when `require` does. A run that reads
/// none says so, once, and fails for none: nothing was found of any.
fn pictured(pictures: &[Picture], read: bool, require: bool) -> Findings {
    if !read {
        return Findings {
            lines: vec![
                "pictures were not read back (--no-picture): the picture was not checked in this run"
                    .to_owned(),
            ],
            failures: Vec::new(),
        };
    }
    let mut found = Findings::default();
    for (number, picture) in pictures.iter().enumerate() {
        let verdict = judged(number + 1, picture, require);
        found.lines.extend(verdict.line);
        found.failures.extend(verdict.failure);
    }
    found
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

/// The sizes the glyphs of `frame` are drawn at, in pixels, smallest first
/// and each once: the size of each font a glyph of a row or of a status
/// row names. A font of the frame's table that no glyph names is not
/// among them: the table is the shaper's, and keeps the fonts of every
/// scale it was asked at. A glyph that names no font of the table has no
/// size.
fn drawn_at(frame: &Frame) -> Vec<f32> {
    let lines = frame.views.iter().flat_map(|view| {
        let rows = view.rows.iter().map(|row| &row.line);
        rows.chain(view.status.iter().map(|status| &status.line))
    });
    let mut sizes: Vec<f32> = lines
        .flat_map(|line| line.glyphs.iter())
        .filter_map(|glyph| frame.fonts.get(usize::try_from(glyph.font.0).ok()?))
        .map(|font| font.size)
        .collect();
    sizes.sort_by(f32::total_cmp);
    sizes.dedup();
    sizes
}

/// `items` as a person lists them: `a`, `a and b`, `a, b and c`; nothing
/// for none.
fn listed(items: &[String]) -> String {
    match items {
        [] => String::new(),
        [one] => one.clone(),
        [first @ .., last] => format!("{} and {last}", first.join(", ")),
    }
}

/// What is made of the sizes `sizes` that the glyphs of the frame published
/// `number`th are drawn at ([`drawn_at`]), when it was laid out for a
/// window that says it is `window`.
///
/// The fixture states one size, [`POINTS`] points, and a point is as many
/// pixels as the window's scale. So the glyphs must be drawn at one size,
/// that many pixels to within a 64th of one, which is what a length is
/// kept in. This is the whole path from the scale a window says, through
/// the layout that was told it, to the size the shaper made its glyphs at:
/// a layout that was not told the scale fails here.
fn laid_out(number: usize, window: Target, sizes: &[f32]) -> Verdict {
    let Target {
        width,
        height,
        scale,
    } = window;
    let laid = format!("frame {number} is laid out for {width} by {height} at scale {scale}");
    match sizes {
        [] => Verdict {
            line: Some(format!("{laid}: it has no glyph")),
            failure: Some(format!(
                "frame {number} has no glyph, so nothing says what size {POINTS} points are drawn at"
            )),
        },
        [size] => {
            let expected = POINTS as f32 * scale;
            Verdict {
                line: Some(format!("{laid}: {POINTS} points are {size} pixels")),
                failure: ((size - expected).abs() > 1.0 / 64.0).then(|| {
                    format!(
                        "frame {number} is laid out for a window at scale {scale}, where {POINTS} points are {expected} pixels, and its glyphs are drawn at {size} pixels"
                    )
                }),
            }
        }
        several => {
            let sizes: Vec<String> = several.iter().map(f32::to_string).collect();
            let sizes = listed(&sizes);
            Verdict {
                line: Some(format!("{laid}: its glyphs are drawn at {sizes} pixels")),
                failure: Some(format!(
                    "frame {number}'s glyphs are drawn at {sizes} pixels, and the fixture states one size, {POINTS} points"
                )),
            }
        }
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
    /// The window told its drawer that nobody can see it (`true`), or that
    /// somebody can again (`false`): it is covered, off the screen, or on
    /// another Space. It asks for no draw.
    Hidden(bool),
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
        /// The kind of mask it drew its glyphs with, as the renderer says;
        /// `None` for a renderer that does not say.
        masks: Option<Masks>,
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
/// at, a new size, and damage. A fourth bears on whether anybody can see
/// what is drawn: hidden or shown. Whatever else it tells asks for no
/// draw by itself (a refresh rate, closing) and is kept as it prints, so
/// the match names those four and no more. A thing a window comes to tell
/// that does ask for a draw would show here as a draw for nothing, which
/// fails the run: that is when to name it.
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
        Canvas::Hidden(hidden) => Happened::Hidden(*hidden),
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
            Happened::Hidden(_) | Happened::Told(_) => {}
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
            Happened::Ended { presented, .. } => {
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

/// A size and a scale, for a person: `800 by 600 at scale 2`.
fn sized(target: &Target) -> String {
    format!(
        "{} by {} at scale {}",
        target.width, target.height, target.scale
    )
}

/// What is made of the times the window of `records` was left alone, when
/// frame `n` of them was laid out for the window `laid[n - 1]`: that each
/// time, what it showed was laid out for it.
///
/// A window is left alone when [`ALONE`] passes in which it tells its
/// drawer nothing, no frame is published and no draw begins or ends. The
/// example's own idle second is not something that happened to the window,
/// and breaks no such stretch. A stretch is judged when somebody can see
/// the window (it has not said it is hidden), a frame has been presented,
/// and no draw is in progress. Then the draw last presented must be of a
/// frame laid out for the size and the scale the window last said, on that
/// size and scale: anything else is a stale frame, or a frame of one scale
/// on a window at another, left on the screen. This is what is asked of a
/// window after it is resized, moved to a display at another scale, put
/// into the system's fullscreen and taken out of it, and shown again after
/// another Space, each time a person waits a second before going on.
fn left_alone(records: &[Record], laid: &[Target]) -> Findings {
    let opened_ns = records.first().map_or(0, |(at_ns, _)| *at_ns);
    let mut tally = Tally::default();
    let mut hidden = false;
    // When the last thing happened that was not the example's own doing.
    let mut quiet_since: Option<u64> = None;
    let (mut times, mut stale) = (0_usize, Vec::new());
    for (at_ns, happened) in records {
        if !matches!(happened, Happened::Idle(_)) {
            // Judged by what was so through the stretch that now ends:
            // before this record is taken in.
            let alone = quiet_since
                .is_some_and(|since| at_ns.saturating_sub(since) >= ALONE.as_nanos() as u64);
            let seen = !hidden && tally.drawing.is_none();
            if let (true, true, Some((frame, on)), Some(told), Some(from_ns)) =
                (alone, seen, tally.shown, tally.told, quiet_since)
            {
                times += 1;
                let laid_for = frame.and_then(|frame| laid.get(frame.checked_sub(1)?));
                if laid_for != Some(&told) || on != told {
                    let showed = match (frame, laid_for) {
                        (Some(frame), Some(laid_for)) => {
                            format!("frame {frame}, laid out for {}", sized(laid_for))
                        }
                        (Some(frame), None) => {
                            format!("frame {frame}, laid out for nothing the ledger was told")
                        }
                        (None, _) => "a frame nobody published".to_owned(),
                    };
                    stale.push(format!(
                        "left alone from {:.1} ms after it opened, the window showed {showed}, on {}, when it had last said it is {}",
                        since(opened_ns, from_ns),
                        sized(&on),
                        sized(&told)
                    ));
                }
            }
            quiet_since = Some(*at_ns);
        }
        if let Happened::Hidden(now) = happened {
            hidden = *now;
        }
        tally.note(*at_ns, happened);
    }
    let line = match (times, stale.len()) {
        (0, _) => "the window was never left alone for a second while it showed a frame, so what it shows when it is left alone was not judged".to_owned(),
        (times, 0) => format!(
            "left alone {times} times, and each time the window showed what was laid out for it"
        ),
        (times, stale) => format!(
            "left alone {times} times, and {stale} of them the window did not show what was laid out for it"
        ),
    };
    Findings {
        lines: vec![line],
        failures: stale,
    }
}

/// The timeline of `records`: one line for each, its time since the first
/// and what happened.
fn timeline(records: &[Record]) -> Vec<String> {
    let Some((opened_ns, _)) = records.first() else {
        return Vec::new();
    };
    let on = sized;
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
            Happened::Hidden(hidden) => format!("the window told its drawer Hidden({hidden})"),
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
            Happened::Ended { presented, masks } => format!(
                "draw {draw} ended, {}",
                match (presented, masks) {
                    // The kind of mask in the renderer's own words for it.
                    (true, Some(masks)) => format!("presented, its glyphs as {masks}"),
                    (true, None) => "presented".to_owned(),
                    (false, _) => "not presented".to_owned(),
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
    let reasons: Vec<String> = [
        (served.frame, "a frame not yet shown"),
        (served.size, "a size not yet drawn at"),
        (served.damage, "damage"),
    ]
    .into_iter()
    .filter(|(served, _)| *served)
    .map(|(_, reason)| reason.to_owned())
    .collect();
    if reasons.is_empty() {
        "nothing that was asked".to_owned()
    } else {
        listed(&reasons)
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
    /// The window each of those frames was laid out for, as it was first
    /// published: its size and its scale.
    laid: Vec<Target>,
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

    /// Enters that `frame`, laid out for the window `window`, is
    /// published, and gives its number.
    fn published(&self, frame: &Arc<Frame>, window: Target) -> usize {
        let number = {
            let mut kept = locked(&self.kept);
            number_of(&kept.frames, frame).unwrap_or_else(|| {
                kept.frames.push(Arc::clone(frame));
                kept.laid.push(window);
                kept.frames.len()
            })
        };
        self.note(Happened::Published(number));
        number
    }

    /// The window each frame published was laid out for: frame `n`'s is
    /// at `n - 1`.
    fn laid(&self) -> Vec<Target> {
        locked(&self.kept).laid.clone()
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
/// and as it ends with whether it presented and the kind of mask it says
/// it drew its glyphs with.
struct Entered<R> {
    /// The renderer.
    inner: R,
    /// Where its draws are entered.
    ledger: Arc<Ledger>,
    /// The kind of mask the renderer says its last draw used, asked as
    /// each draw ends; `None` of a renderer that does not say.
    masks: fn(&R) -> Option<Masks>,
}

impl<R: Renderer> Renderer for Entered<R> {
    fn draw(&mut self, request: &DrawRequest<'_>) -> Drawn {
        self.ledger.began(request.frame, request.target);
        let drawn = self.inner.draw(request);
        self.ledger.note(Happened::Ended {
            presented: drawn.presented,
            masks: (self.masks)(&self.inner),
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
    /// Why a frame published was not laid out at its window's scale, for
    /// each that was not ([`laid_out`]).
    mislaid: Mutex<Vec<String>>,
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
            mislaid: Mutex::default(),
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
    /// Whether each frame presented is read back and compared: not in a
    /// run a person watches (`--no-picture`), where the half second a
    /// comparison takes would make every resize look stalled.
    read: bool,
    /// Whether the window's surface lets its texture be copied from: what
    /// the renderer answered when it was asked to keep its pictures.
    copies: bool,
    /// The renderer it is compared with.
    headless: HeadlessRenderer,
    /// Where what it finds goes.
    shared: Arc<Shared>,
}

impl Checked {
    /// The kind of mask the renderer on the window says its last draw
    /// asked its glyph images in.
    fn masks(&self) -> Option<Masks> {
        self.gpu.masks()
    }
}

impl Renderer for Checked {
    fn draw(&mut self, request: &DrawRequest<'_>) -> Drawn {
        let drawn = self.gpu.draw(request);
        if !drawn.presented {
            let reason = self.gpu.refused().unwrap_or("no reason given").to_owned();
            locked(&self.shared.refusals).push(reason);
            return drawn;
        }
        if !self.read {
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

/// The renderer's settings for this window: the platform's weight of
/// text, and plain masks where the adapter cannot blend by a coverage for
/// each channel (`per_channel`).
///
/// Where the platform draws with Core Text (`matches_core_text`, which
/// the caller sets on macOS), text is drawn to Core Text's weight
/// ([`Settings::core_text`]); everywhere else it keeps the default,
/// linear light and the outlines as they are. This is the one place the
/// target system is asked: whatever later makes the editor's own
/// renderer applies the same rule.
fn settings(per_channel: bool, matches_core_text: bool) -> Settings {
    let platform = if matches_core_text {
        Settings::core_text()
    } else {
        Settings::default()
    };
    if per_channel {
        platform
    } else {
        Settings {
            antialiasing: Antialiasing::Grayscale,
            ..platform
        }
    }
}

/// A renderer on `window`, checked: each frame it presents is read back
/// and compared when `read` says so. The error is why there is none.
fn renderer(
    window: Option<&NativeWindow>,
    shared: &Arc<Shared>,
    read: bool,
) -> Result<Checked, String> {
    let window = window.ok_or("the platform named no native window to draw in")?;
    // Its antialiasing is the device's to settle: one that cannot blend
    // by a coverage for each channel draws plain masks whatever it is
    // told. What it is told that matters is the weight and the hinting.
    let macos = cfg!(target_os = "macos");
    // SAFETY: the window port tells of `window` when it opens, on this
    // thread, and it stays live until the drawer returns from being told
    // the window is closing. The session drops this renderer, on this
    // thread, while it is being told so.
    #[expect(
        clippy::disallowed_methods,
        reason = "this example is the one place a renderer is made on a window: it is the window's check, run on demand"
    )]
    let made = unsafe { WgpuRenderer::on_window(window, settings(true, macos)) };
    let mut gpu = made.map_err(|error| error.to_string())?;
    // A run that reads no picture asks the renderer to keep none: a draw
    // then costs what the editor's own would, and not a read-back more.
    let copies = read && gpu.keep_picture();
    *locked(&shared.adapter) = Some(format!(
        "{}, blending by a coverage for each channel: {}",
        gpu.adapter(),
        gpu.per_channel()
    ));
    // An adapter that cannot blend by a coverage for each channel draws
    // plain masks whatever it is asked: so must what it is compared with,
    // at the same weight.
    let compared = settings(gpu.per_channel(), macos);
    Ok(Checked {
        gpu,
        read,
        copies,
        headless: HeadlessRenderer::new(compared),
        shared: Arc::clone(shared),
    })
}

/// The fonts the fixture is laid out in, and the family its default face
/// names: the fixture fonts, compiled in, and no family; or, when `family`
/// is given, the fonts of this machine and that family as the machine
/// names it. The error is why there are none: a family the machine has
/// not is one.
fn fonts(family: Option<&str>) -> Result<(FontSet, Option<String>), String> {
    let Some(name) = family else {
        let files: Vec<Vec<u8>> = [SANS, HEBREW, JP]
            .iter()
            .map(|bytes| bytes.to_vec())
            .collect();
        let fallbacks = ["Noto Sans Hebrew", "Noto Sans JP"];
        let fonts = FontSet::only("Noto Sans", &fallbacks, files)
            .map_err(|error| format!("the fixture fonts: {error}"))?;
        return Ok((fonts, None));
    };
    #[expect(
        clippy::disallowed_methods,
        reason = "a person who asks for a family of this machine's fonts (--family) is the one caller: no test and no other run reads the machine's fonts"
    )]
    let fonts = FontSet::system();
    let family = family_of(name, &fonts.families())?;
    Ok((fonts, Some(family)))
}

/// The fixture scene in a window of `size`: [`TEXT`] in one view that
/// fills it, a selection with its cursor, and a status row, in a default
/// face of [`POINTS`] points, and of the family `family` when there is
/// one. Its rectangle and the size its status row reads are physical
/// pixels; the face's size is the one length here that is not.
fn scene(size: Resize, family: Option<&str>) -> Scene {
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
                family: family.map(str::to_owned),
                // In points: layout puts it at the window's scale.
                size: Some(Length::pixels(POINTS)),
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
        Input::OpenFiles(paths) => format!("open files: {}", paths.join(", ")),
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
/// and for whatever else was asked as the window opened to be drawn, then
/// leaves the window alone for [`IDLE`] and enters in the ledger when
/// that second began and ended, says the window is ready for input, and
/// closes the window `stay` later if nobody has; with no `stay` the window
/// is left for a person to close.
///
/// The idle second begins settled, when it can: with nothing asked for
/// that is not yet drawn. A window is asked for more than its first frame
/// as it opens (on macOS the system asks for its content while that frame
/// is being drawn), and a second that began the moment the first frame
/// was presented would see that drawn and nothing ask for it.
fn watch(session: &Session<Watched>, shared: &Shared, stay: Option<Duration>) {
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
    if let Some(stay) = stay {
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

/// What the example decides of what it saw, with no window: these run in
/// the gate.
#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use editor_layout::Layout;
    use editor_layout::face::Color;
    use editor_layout::frame::{Frame, FrameRow, StatusRow, ViewFrame};
    use editor_layout::scene::{Rect, Scene, ViewId};
    use editor_layout::shaper::fake::CellShaper;
    use editor_layout::shaper::{Glyph, ResolvedFont, ResolvedFontId, VisualLine};
    use editor_platform::{Canvas, Drawer, Resize};
    use editor_render::clock::FakeClock;
    use editor_render::fake::RecordingRenderer;
    use editor_render::journal::Entry;
    use editor_render::port::{DrawRequest, Renderer, Target};
    use editor_render_wgpu::{Antialiasing, Masks, Settings, SubpixelOrder};

    use super::settings;

    #[test]
    fn the_window_draws_to_core_texts_weight_where_it_matches_core_text_and_linear_elsewhere() {
        let plain = |settings: Settings| Settings {
            antialiasing: Antialiasing::Grayscale,
            ..settings
        };
        assert_eq!(settings(true, false), Settings::default());
        assert_eq!(settings(false, false), plain(Settings::default()));
        assert_eq!(settings(true, true), Settings::core_text());
        assert_eq!(settings(false, true), plain(Settings::core_text()));
    }

    use super::{
        Draw, Entered, Findings, Happened, IDLE_ASKS, Idle, Ledger, Options, Picture, Served,
        TOLERANCE, Tally, Verdict, drawn_at, entering, family_of, happened, journalled, judged,
        laid_out, left_alone, on_demand, options, pictured, timeline, uncompared,
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

    /// The draw last begun presented, by a renderer that does not say
    /// which masks it used.
    const PRESENTED: Happened = Happened::Ended {
        presented: true,
        masks: None,
    };

    /// The draw last begun did not present.
    const REFUSED: Happened = Happened::Ended {
        presented: false,
        masks: None,
    };

    /// The draw last begun presented, with its glyphs as `masks`.
    fn presented_as(masks: Masks) -> Happened {
        Happened::Ended {
            presented: true,
            masks: Some(masks),
        }
    }

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
            Happened::Hidden(false),
            Happened::Told("Refresh(Some(60000))".to_owned()),
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
            Happened::Hidden(true),
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
    fn the_timeline_says_which_masks_a_presented_draw_used() {
        // The kinds a renderer says, in the renderer's own words for each.
        let kinds = [
            Masks::Plain,
            Masks::Subpixel(SubpixelOrder::Rgb),
            Masks::Subpixel(SubpixelOrder::Bgr),
        ];
        for masks in kinds {
            let lines = timeline(&records(&[
                Happened::Opened {
                    size: SMALL,
                    refresh: None,
                },
                Happened::Published(1),
                began(1, SMALL),
                presented_as(masks),
                // A draw that did not present says nothing of its masks.
                Happened::Damaged,
                began(1, SMALL),
                Happened::Ended {
                    presented: false,
                    masks: Some(masks),
                },
            ]));
            assert_eq!(
                lines[3],
                format!("      3.0 ms: draw 1 ended, presented, its glyphs as {masks}")
            );
            assert_eq!(lines[6], "      6.0 ms: draw 2 ended, not presented");
        }
        // The masks of a draw change nothing of what it was for.
        let tally = tallied(&and(
            showing(),
            &[
                Happened::Damaged,
                began(1, SMALL),
                presented_as(Masks::Plain),
            ],
        ));
        assert_eq!(served(&tally), [FRAME, DAMAGE]);
        assert!(tally.settled());
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
            fullscreen: false,
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
        // Hidden and shown ask for no draw, and say whether a window left
        // alone is one anybody can see.
        for hidden in [true, false] {
            assert_eq!(happened(&Canvas::Hidden(hidden)), Happened::Hidden(hidden));
        }
        // What else asks for no draw is kept as it prints.
        for (canvas, said) in [
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
        assert_eq!(ledger.laid(), []);
        assert_eq!(ledger.published(&one, SMALL), 1);
        // The same value again, and another that is equal to it.
        assert_eq!(ledger.published(&one, SMALL), 1);
        assert_eq!(ledger.published(&frame_of("one"), SMALL), 1);
        assert_eq!(ledger.published(&frame_of("two"), LARGE), 2);
        // The first again, after another: still the first.
        assert_eq!(ledger.published(&frame_of("one"), SMALL), 1);
        assert_eq!(entered(&ledger), [1, 1, 1, 2, 1].map(Happened::Published));
        // Each frame is kept with the window it was laid out for, once.
        assert_eq!(ledger.laid(), [SMALL, LARGE]);
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
        // A renderer that says its masks by how many draws it was asked
        // for: plain ones for the first, and from then on subpixel ones.
        let mut renderer = Entered {
            inner: RecordingRenderer::new(),
            ledger: Arc::clone(&ledger),
            masks: |inner| {
                Some(match inner.requests().len() {
                    1 => Masks::Plain,
                    _ => Masks::Subpixel(SubpixelOrder::Rgb),
                })
            },
        };
        let (one, two) = (frame_of("one"), frame_of("two"));
        ledger.published(&one, SMALL);
        ledger.published(&two, SMALL);

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

        // Each ends with what the renderer says of its masks once it has
        // drawn, whether or not it presented.
        let stripes = Masks::Subpixel(SubpixelOrder::Rgb);
        assert_eq!(
            entered(&ledger)[2..],
            [
                began(2, SMALL),
                presented_as(Masks::Plain),
                began(1, LARGE),
                Happened::Ended {
                    presented: false,
                    masks: Some(stripes),
                },
                Happened::Began {
                    frame: None,
                    target: LARGE,
                },
                presented_as(stripes),
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
            [Happened::Damaged, Happened::Hidden(true)]
        );
    }

    /// A line of one glyph for each of `fonts`, each naming that entry of
    /// its frame's table.
    fn line_in(fonts: &[u32]) -> Arc<VisualLine> {
        let glyphs: Vec<Glyph> = (0..)
            .zip(fonts)
            .map(|(at, font)| Glyph {
                id: 1,
                font: ResolvedFontId(*font),
                cluster: at,
                x: at as f32 * 10.0,
                dx: 0.0,
                dy: 0.0,
                advance: 10.0,
            })
            .collect();
        Arc::new(VisualLine {
            bytes: 0..glyphs.len(),
            width: glyphs.len() as f32 * 10.0,
            glyphs,
            height: 16.0,
            baseline: 12.0,
        })
    }

    /// A frame written by hand, of one view: a row for each of `rows` and
    /// a status row of `status` when there is one, each a line of one
    /// glyph for each font it lists ([`line_in`]); and a table of one font
    /// for each of `sizes`, of that size.
    fn frame_in(rows: &[&[u32]], status: Option<&[u32]>, sizes: &[f32]) -> Frame {
        let white = Color::rgb(0xff, 0xff, 0xff);
        let rows = rows
            .iter()
            .map(|fonts| FrameRow {
                y: 0.0,
                height: 16.0,
                baseline: 12.0,
                bytes: 0..fonts.len(),
                line: line_in(fonts),
                runs: Vec::new(),
                hash: 0,
            })
            .collect();
        let status = status.map(|fonts| StatusRow {
            y: 0.0,
            height: 16.0,
            baseline: 12.0,
            line: line_in(fonts),
            runs: Vec::new(),
            background: white,
            hash: 0,
        });
        let fonts = sizes
            .iter()
            .map(|size| ResolvedFont {
                data: Arc::new([0_u8; 0]),
                file: 0,
                index: 0,
                size: *size,
                coords: Vec::new(),
                embolden: false,
                skew: None,
            })
            .collect();
        Frame {
            views: vec![ViewFrame {
                id: ViewId(1),
                rect: Rect::default(),
                background: white,
                rows,
                status,
                cursors: Vec::new(),
                selections: Vec::new(),
                selection: white,
            }],
            generation: 0,
            fonts,
        }
    }

    #[test]
    fn the_sizes_a_frames_glyphs_are_drawn_at_are_those_of_the_fonts_they_name() {
        // The table of a shaper that has been asked for fonts at several
        // scales: within a generation it only grows, so the fonts of an
        // earlier scale stay in it, and a frame names the ones it uses.
        let table = [16.0, 14.0, 28.0, 21.0];
        // One size, named by every row and by the status row.
        let frame = frame_in(&[&[2, 2], &[2]], Some(&[2]), &table);
        assert_eq!(drawn_at(&frame), [28.0]);
        // Several: smallest first, each once, the status row's among them.
        let frame = frame_in(&[&[3, 1], &[1]], Some(&[2]), &table);
        assert_eq!(drawn_at(&frame), [14.0, 21.0, 28.0]);
        // A view with no status row.
        assert_eq!(drawn_at(&frame_in(&[&[0]], None, &table)), [16.0]);
        // A frame with no glyph is drawn at no size, whatever its table
        // holds, and a glyph that names no font of the table has no size.
        let none: [f32; 0] = [];
        assert_eq!(drawn_at(&frame_in(&[&[]], None, &table)), none);
        assert_eq!(drawn_at(&frame_in(&[&[9]], None, &table)), none);
        assert_eq!(drawn_at(&Frame::default()), none);
    }

    #[test]
    fn fourteen_points_at_a_scale_are_that_many_pixels_and_any_other_size_fails_the_run() {
        let at = |scale: f32| Target {
            width: 1600,
            height: 1200,
            scale,
        };
        let passes = |line: &str| Verdict {
            line: Some(line.to_owned()),
            failure: None,
        };
        assert_eq!(
            laid_out(1, at(2.0), &[28.0]),
            passes("frame 1 is laid out for 1600 by 1200 at scale 2: 14 points are 28 pixels")
        );
        assert_eq!(
            laid_out(3, SMALL, &[14.0]),
            passes("frame 3 is laid out for 400 by 300 at scale 1: 14 points are 14 pixels")
        );
        // A fractional scale, and a size that is within a 64th of a pixel
        // of the product: a length is kept in 64ths.
        assert_eq!(
            laid_out(2, at(1.25), &[17.5]),
            passes("frame 2 is laid out for 1600 by 1200 at scale 1.25: 14 points are 17.5 pixels")
        );
        assert_eq!(laid_out(2, at(1.3333), &[18.671_875]).failure, None);
        assert_eq!(laid_out(2, at(2.0), &[28.0 + 1.0 / 64.0]).failure, None);

        // Any other size fails: a layout that was never told the scale
        // draws 14 points at 14 pixels on a window at scale 2.
        assert_eq!(
            laid_out(1, at(2.0), &[14.0]),
            Verdict {
                line: Some(
                    "frame 1 is laid out for 1600 by 1200 at scale 2: 14 points are 14 pixels"
                        .to_owned()
                ),
                failure: Some(
                    "frame 1 is laid out for a window at scale 2, where 14 points are 28 pixels, and its glyphs are drawn at 14 pixels"
                        .to_owned()
                ),
            }
        );
        // Past a 64th, on either side.
        for size in [28.0 + 2.0 / 64.0, 28.0 - 2.0 / 64.0] {
            assert!(laid_out(1, at(2.0), &[size]).failure.is_some(), "{size}");
        }
        // The fixture states one size: a frame drawn at several fails, and
        // so does one with no glyph to read a size from.
        assert_eq!(
            laid_out(1, at(2.0), &[14.0, 21.0, 28.0]),
            Verdict {
                line: Some(
                    "frame 1 is laid out for 1600 by 1200 at scale 2: its glyphs are drawn at 14, 21 and 28 pixels"
                        .to_owned()
                ),
                failure: Some(
                    "frame 1's glyphs are drawn at 14, 21 and 28 pixels, and the fixture states one size, 14 points"
                        .to_owned()
                ),
            }
        );
        assert_eq!(
            laid_out(1, at(2.0), &[]),
            Verdict {
                line: Some(
                    "frame 1 is laid out for 1600 by 1200 at scale 2: it has no glyph".to_owned()
                ),
                failure: Some(
                    "frame 1 has no glyph, so nothing says what size 14 points are drawn at"
                        .to_owned()
                ),
            }
        );
    }

    /// What a command line with none of the options asks for: twenty
    /// seconds, pictures read and compared where the surface gives one, in
    /// the fixture fonts.
    fn as_it_comes() -> Options {
        Options {
            stay: Some(Duration::from_secs(20)),
            require_picture: false,
            read_picture: true,
            family: None,
        }
    }

    #[test]
    fn the_command_line_says_how_long_the_window_stays_and_whether_a_picture_is_required() {
        let asked = |stay, require_picture| {
            Some(Options {
                stay: Some(Duration::from_secs(stay)),
                require_picture,
                ..as_it_comes()
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
    fn the_command_line_says_whether_the_window_stays_whether_pictures_are_read_and_in_which_family()
     {
        // Until a person closes it.
        assert_eq!(
            options(&["--until-closed"]),
            Some(Options {
                stay: None,
                ..as_it_comes()
            })
        );
        // No picture is read back.
        assert_eq!(
            options(&["--no-picture"]),
            Some(Options {
                read_picture: false,
                ..as_it_comes()
            })
        );
        // In a family of the machine's fonts, whose name may be several
        // words.
        assert_eq!(
            options(&["--family", "Menlo"]),
            Some(Options {
                family: Some("Menlo".to_owned()),
                ..as_it_comes()
            })
        );
        assert_eq!(
            options(&["--family", "Helvetica Neue"]).and_then(|options| options.family),
            Some("Helvetica Neue".to_owned())
        );
        // All three, as a person runs it by hand, in any order.
        let by_hand = Some(Options {
            stay: None,
            require_picture: false,
            read_picture: false,
            family: Some("Menlo".to_owned()),
        });
        assert_eq!(
            options(&["--until-closed", "--no-picture", "--family", "Menlo"]),
            by_hand
        );
        assert_eq!(
            options(&["--family", "Menlo", "--no-picture", "--until-closed"]),
            by_hand
        );
        // Each with what it does not contradict.
        assert_eq!(
            options(&["--seconds", "2", "--no-picture"]),
            Some(Options {
                stay: Some(Duration::from_secs(2)),
                read_picture: false,
                ..as_it_comes()
            })
        );
        assert_eq!(
            options(&["--until-closed", "--require-picture"]),
            Some(Options {
                stay: None,
                require_picture: true,
                ..as_it_comes()
            })
        );
    }

    #[test]
    fn options_that_contradict_each_other_are_not_understood() {
        for arguments in [
            // A window cannot both close after a time and stay.
            &["--until-closed", "--seconds", "6"][..],
            &["--seconds", "6", "--until-closed"],
            // A picture cannot be required and not read.
            &["--no-picture", "--require-picture"],
            &["--require-picture", "--no-picture"],
            &["--until-closed", "--no-picture", "--require-picture"],
        ] {
            assert_eq!(options(arguments), None, "{arguments:?}");
        }
    }

    #[test]
    fn a_command_line_that_is_not_understood_gives_no_options() {
        for arguments in [
            &["--seconds"][..],
            &["--seconds", "soon"],
            &["--seconds", "--require-picture"],
            &["--require-pictures"],
            &["6"],
            // A family is a name, and a name is not an option or nothing.
            &["--family"],
            &["--family", ""],
            &["--family", "--no-picture"],
            &["--no-pictures"],
            &["--until-close"],
        ] {
            assert_eq!(options(arguments), None, "{arguments:?}");
        }
    }

    #[test]
    fn a_family_is_one_the_machine_has_by_its_own_name_for_it_and_any_other_is_refused() {
        let families = ["Courier", "Helvetica Neue", "Menlo"].map(str::to_owned);
        assert_eq!(family_of("Menlo", &families), Ok("Menlo".to_owned()));
        // Whatever the case it was asked in, it is the machine's name.
        assert_eq!(
            family_of("helvetica neue", &families),
            Ok("Helvetica Neue".to_owned())
        );
        // One it has not is said, with how many it has.
        assert_eq!(
            family_of("Noto Sans", &families),
            Err("this machine has no font family named Noto Sans, of its 3 families".to_owned())
        );
        // A part of a name is not the name.
        assert!(family_of("Helvetica", &families).is_err());
        assert!(family_of("Menlo", &[]).is_err());
    }

    #[test]
    fn a_run_that_reads_no_picture_says_so_and_fails_for_none() {
        // Nothing was read, so nothing was found of any picture.
        assert_eq!(
            pictured(&[], false, false),
            Findings {
                lines: vec![
                    "pictures were not read back (--no-picture): the picture was not checked in this run"
                        .to_owned()
                ],
                failures: Vec::new(),
            }
        );
        // A run that reads them says what each was found to be, as before,
        // and nothing of this.
        let compared = Picture::Compared {
            pixels: 100,
            differing: 7,
            worst: TOLERANCE + 1,
        };
        let pictures = [compared.clone(), Picture::NotCopied];
        for require in [false, true] {
            let found = pictured(&pictures, true, require);
            let each = [
                judged(1, &compared, require),
                judged(2, &Picture::NotCopied, require),
            ];
            assert_eq!(
                found.lines,
                each.iter()
                    .filter_map(|verdict| verdict.line.clone())
                    .collect::<Vec<_>>()
            );
            assert_eq!(
                found.failures,
                each.iter()
                    .filter_map(|verdict| verdict.failure.clone())
                    .collect::<Vec<_>>()
            );
            assert_eq!(found.lines.len(), 2);
            assert_eq!(found.failures.len(), if require { 2 } else { 1 });
        }
        assert_eq!(pictured(&[], true, true), Findings::default());
    }

    /// `happened`, each at its time since the first in milliseconds.
    fn timed(happened: &[(u64, Happened)]) -> Vec<(u64, Happened)> {
        happened
            .iter()
            .map(|(at_ms, happened)| (MS + at_ms * MS, happened.clone()))
            .collect()
    }

    /// The size of `LARGE` at the scale of `SMALL`: a window dragged to a
    /// display at another scale keeps its size in pixels for a moment.
    const WIDE: Target = Target {
        width: 800,
        height: 600,
        scale: 1.0,
    };

    /// The line of a window that was left alone `times` times and showed
    /// what was laid out for it each time.
    fn alone(times: usize) -> String {
        format!(
            "left alone {times} times, and each time the window showed what was laid out for it"
        )
    }

    #[test]
    fn left_alone_a_window_that_shows_what_was_laid_out_for_it_passes() {
        let records = timed(&[
            (
                0,
                Happened::Opened {
                    size: SMALL,
                    refresh: None,
                },
            ),
            (10, Happened::Published(1)),
            (11, began(1, SMALL)),
            (20, PRESENTED),
            // The example's own second is nothing the window did: with it
            // or without, this is one stretch of a second and more.
            (30, Happened::Idle(true)),
            (1030, Happened::Idle(false)),
            // A resize: the frame shown is drawn on the new size, and then
            // the frame laid out for it.
            (1500, Happened::Resized(WIDE)),
            (1501, began(1, WIDE)),
            (1510, PRESENTED),
            (1511, Happened::Published(2)),
            (1512, began(2, WIDE)),
            (1520, PRESENTED),
            // A change of scale alone, a second to the millisecond later.
            (2520, Happened::Resized(LARGE)),
            (2521, Happened::Published(3)),
            (2522, began(3, LARGE)),
            (2530, PRESENTED),
            // The window says the same again, and the same frame is
            // published again: nothing is drawn, and nothing is stale.
            (4000, Happened::Resized(LARGE)),
            (4001, Happened::Published(3)),
            // Damage, a millisecond short of a second later: not alone.
            (5000, Happened::Damaged),
            (5001, began(3, LARGE)),
            (5010, PRESENTED),
            (7000, Happened::Told("Closing".to_owned())),
        ]);
        // Frame 1 was laid out for SMALL, 2 for WIDE and 3 for LARGE.
        let laid = [SMALL, WIDE, LARGE];
        assert_eq!(
            left_alone(&records, &laid),
            Findings {
                lines: vec![alone(4)],
                failures: Vec::new(),
            }
        );
        // Back at a size it had: the frame laid out for it then is the
        // frame laid out for it now.
        let back = timed(&[
            (
                0,
                Happened::Opened {
                    size: SMALL,
                    refresh: None,
                },
            ),
            (10, Happened::Published(1)),
            (11, began(1, SMALL)),
            (20, PRESENTED),
            (30, Happened::Resized(WIDE)),
            (31, Happened::Published(2)),
            (32, began(2, WIDE)),
            (40, PRESENTED),
            (50, Happened::Resized(SMALL)),
            (51, Happened::Published(1)),
            (52, began(1, SMALL)),
            (60, PRESENTED),
            (3000, Happened::Told("Closing".to_owned())),
        ]);
        assert_eq!(left_alone(&back, &laid).lines, [alone(1)]);
        assert_eq!(left_alone(&back, &laid).failures, [] as [String; 0]);
    }

    #[test]
    fn the_examples_own_idle_second_neither_breaks_a_stretch_nor_makes_two_of_one() {
        // More than a second before the idle second begins, the second
        // itself, and less than one after it: one stretch, of the window's.
        let records = timed(&[
            (
                0,
                Happened::Opened {
                    size: SMALL,
                    refresh: None,
                },
            ),
            (10, Happened::Published(1)),
            (11, began(1, SMALL)),
            (20, PRESENTED),
            (1100, Happened::Idle(true)),
            (2100, Happened::Idle(false)),
            (2500, Happened::Told("Closing".to_owned())),
        ]);
        assert_eq!(left_alone(&records, &[SMALL]).lines, [alone(1)]);
        // Less than a second on either side of it, and more than one in
        // all.
        let records = timed(&[
            (
                0,
                Happened::Opened {
                    size: SMALL,
                    refresh: None,
                },
            ),
            (10, Happened::Published(1)),
            (11, began(1, SMALL)),
            (20, PRESENTED),
            (500, Happened::Idle(true)),
            (510, Happened::Idle(false)),
            (1200, Happened::Told("Closing".to_owned())),
        ]);
        assert_eq!(left_alone(&records, &[SMALL]).lines, [alone(1)]);
    }

    #[test]
    fn left_alone_a_window_that_shows_a_frame_laid_out_for_another_size_or_scale_fails_and_says_which()
     {
        let opened = [
            (
                0,
                Happened::Opened {
                    size: SMALL,
                    refresh: None,
                },
            ),
            (10, Happened::Published(1)),
            (11, began(1, SMALL)),
            (20, PRESENTED),
        ];
        let closing = (9000, Happened::Told("Closing".to_owned()));
        let laid = [SMALL, WIDE, LARGE];
        let found = |then: &[(u64, Happened)]| {
            let all: Vec<_> = opened
                .iter()
                .chain(then)
                .chain([&closing])
                .cloned()
                .collect();
            left_alone(&timed(&all), &laid)
        };

        // Another size: the frame shown is drawn on the new size, and the
        // frame laid out for it never comes.
        let stale = found(&[
            (1500, Happened::Resized(WIDE)),
            (1501, began(1, WIDE)),
            (1510, PRESENTED),
        ]);
        assert_eq!(
            stale,
            Findings {
                lines: vec![
                    "left alone 2 times, and 1 of them the window did not show what was laid out for it"
                        .to_owned()
                ],
                failures: vec![
                    "left alone from 1510.0 ms after it opened, the window showed frame 1, laid out for 400 by 300 at scale 1, on 800 by 600 at scale 1, when it had last said it is 800 by 600 at scale 1"
                        .to_owned()
                ],
            }
        );

        // Another scale: the frame laid out for the size at the old scale
        // is shown on the window at the new one.
        let unscaled = found(&[
            (1500, Happened::Resized(WIDE)),
            (1501, Happened::Published(2)),
            (1502, began(2, WIDE)),
            (1510, PRESENTED),
            (3000, Happened::Resized(LARGE)),
            (3001, began(2, LARGE)),
            (3010, PRESENTED),
        ]);
        assert_eq!(
            unscaled.failures,
            [
                "left alone from 3010.0 ms after it opened, the window showed frame 2, laid out for 800 by 600 at scale 1, on 800 by 600 at scale 2, when it had last said it is 800 by 600 at scale 2"
            ]
        );
        assert_eq!(
            unscaled.lines,
            ["left alone 3 times, and 1 of them the window did not show what was laid out for it"]
        );

        // The right frame, published, and never drawn where the window
        // now is: what is shown is the old frame on the old size.
        let undrawn = found(&[
            (1500, Happened::Resized(WIDE)),
            (1501, Happened::Published(2)),
        ]);
        assert_eq!(
            undrawn.failures,
            [
                "left alone from 1501.0 ms after it opened, the window showed frame 1, laid out for 400 by 300 at scale 1, on 400 by 300 at scale 1, when it had last said it is 800 by 600 at scale 1"
            ]
        );

        // A frame nobody published, and one the ledger was never told the
        // window of.
        let unknown = found(&[
            (
                1500,
                Happened::Began {
                    frame: None,
                    target: SMALL,
                },
            ),
            (1510, PRESENTED),
        ]);
        assert_eq!(
            unknown.failures,
            [
                "left alone from 1510.0 ms after it opened, the window showed a frame nobody published, on 400 by 300 at scale 1, when it had last said it is 400 by 300 at scale 1"
            ]
        );
        let untold = left_alone(
            &timed(&opened.iter().chain([&closing]).cloned().collect::<Vec<_>>()),
            &[],
        );
        assert_eq!(
            untold.failures,
            [
                "left alone from 20.0 ms after it opened, the window showed frame 1, laid out for nothing the ledger was told, on 400 by 300 at scale 1, when it had last said it is 400 by 300 at scale 1"
            ]
        );
    }

    #[test]
    fn a_window_that_is_hidden_or_never_left_alone_is_not_judged() {
        let never = "the window was never left alone for a second while it showed a frame, so what it shows when it is left alone was not judged";
        let unjudged = |happened: &[(u64, Happened)]| {
            assert_eq!(
                left_alone(&timed(happened), &[SMALL, WIDE]),
                Findings {
                    lines: vec![never.to_owned()],
                    failures: Vec::new(),
                }
            );
        };
        let opened = Happened::Opened {
            size: SMALL,
            refresh: None,
        };
        let closing = Happened::Told("Closing".to_owned());
        // Nothing happened, and a window that closed within the second.
        unjudged(&[]);
        unjudged(&[
            (0, opened.clone()),
            (10, Happened::Published(1)),
            (11, began(1, SMALL)),
            (20, PRESENTED),
            (1019, closing.clone()),
        ]);
        // Hidden: on another Space, a stale frame is nobody's to see. What
        // is stale here is put right as the window is shown again.
        unjudged(&[
            (0, opened.clone()),
            (10, Happened::Published(1)),
            (11, began(1, SMALL)),
            (20, PRESENTED),
            (30, Happened::Hidden(true)),
            (40, Happened::Resized(WIDE)),
            (3000, Happened::Hidden(false)),
            (3001, began(1, WIDE)),
            (3010, PRESENTED),
            (3011, Happened::Published(2)),
            (3012, began(2, WIDE)),
            (3020, PRESENTED),
            (3500, closing.clone()),
        ]);
        // Nothing was ever presented: a window that opened where nobody
        // can see it, and is not told so. That no frame was presented
        // fails the run by another check.
        unjudged(&[
            (0, opened.clone()),
            (10, Happened::Published(1)),
            (11, began(1, SMALL)),
            (
                20,
                Happened::Ended {
                    presented: false,
                    masks: None,
                },
            ),
            (5000, closing.clone()),
        ]);
        // A draw in progress for the whole of the stretch: the window is
        // not left alone while it is drawn on.
        unjudged(&[
            (0, opened.clone()),
            (10, Happened::Published(1)),
            (11, began(1, SMALL)),
            (20, PRESENTED),
            (30, Happened::Resized(WIDE)),
            (31, began(1, WIDE)),
            (2000, PRESENTED),
            (2001, Happened::Published(2)),
            (2002, began(2, WIDE)),
            (2010, PRESENTED),
            (2500, closing.clone()),
        ]);
        // Shown again and then left alone, it is judged.
        let shown = timed(&[
            (0, opened),
            (10, Happened::Published(1)),
            (11, began(1, SMALL)),
            (20, PRESENTED),
            (30, Happened::Hidden(true)),
            (3000, Happened::Hidden(false)),
            (4500, closing),
        ]);
        assert_eq!(left_alone(&shown, &[SMALL]).lines, [alone(1)]);
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
