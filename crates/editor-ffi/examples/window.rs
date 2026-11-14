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
//! 3. **Nothing is drawn that nothing asked for.** Over a second in which
//!    it publishes nothing, no more frames are drawn than the window asked
//!    for by being resized or damaged, which is none when the window is
//!    left alone; and over the whole run no more than were asked for. A
//!    window that asks again and again in that second, more than a system
//!    uncovering it would, fails too: that is a timer by another name.
//! 4. **Input arrived on the queue**: at least one key or pointer event.
//!
//! It prints `window: ready for input` once the idle second is over: that
//! is when to type, click, drag, scroll and resize. Each input is printed
//! on a line beginning `input:`.
//!
//! What it makes of what it saw is tested in the gate, by the unit tests
//! at the foot of this file, which open no window: how the command line
//! is read, and what is made of each thing found of a picture
//! (`cargo test` runs them: the manifest says `test = true` of this
//! example).

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

/// What the example's threads share.
#[derive(Default)]
struct Shared {
    /// The adapter's name and back end, once a renderer is made.
    adapter: Mutex<Option<String>>,
    /// What each presented frame's picture was found to be, in order.
    pictures: Mutex<Vec<Picture>>,
    /// Why a draw was not presented, for each that was not.
    refusals: Mutex<Vec<String>>,
    /// How many things asked for a draw: a frame published, and the window
    /// saying it was resized or damaged.
    asked: AtomicU64,
    /// How many events of the window came off the queue.
    inputs: AtomicU64,
    /// How many of them were keys or the pointer.
    touched: AtomicU64,
    /// What the idle second showed: the frames drawn over it and the
    /// things that asked for one.
    idle: Mutex<Option<(u64, u64)>>,
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
fn edit(queue: &Queue, session: &Session<Checked>, shared: &Shared) -> Result<(), String> {
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
                    shared.asked.fetch_add(1, Ordering::SeqCst);
                    handle.submit(frame, Some(event.stamp));
                }
            }
            Input::CloseRequested => PLATFORM.close(),
            _ => {}
        }
    }
}

/// Watches the window from a thread of its own: waits for the first frame,
/// then leaves the window alone for [`IDLE`] and records what was drawn
/// over it, says the window is ready for input, and closes the window
/// `stay` later if nobody has.
fn watch(session: &Session<Checked>, shared: &Shared, stay: Duration) {
    let began = Instant::now();
    let presented = || session.handle().map_or(0, |handle| handle.counters().draws);
    while presented() == 0 && began.elapsed() < FIRST_FRAME {
        thread::sleep(Duration::from_millis(10));
    }
    if presented() > 0 {
        let before = (presented(), shared.asked.load(Ordering::SeqCst));
        thread::sleep(IDLE);
        let after = (presented(), shared.asked.load(Ordering::SeqCst));
        *locked(&shared.idle) = Some((after.0 - before.0, after.1 - before.1));
    }
    println!("window: ready for input");
    thread::sleep(stay);
    PLATFORM.close();
}

/// The session's drawer, counting what the window asks to be drawn.
fn counting(session: &Session<Checked>, shared: &Arc<Shared>) -> Drawer {
    let drawer = session.drawer();
    let shared = Arc::clone(shared);
    Arc::new(move |canvas| {
        if matches!(canvas, Canvas::Resized(_) | Canvas::Damaged) {
            shared.asked.fetch_add(1, Ordering::SeqCst);
        }
        drawer(canvas);
    })
}

/// What was found, printed; and why the check fails, when it does, in a
/// run that requires every frame's picture to be compared when
/// `require_picture` says so.
fn report(session: &Session<Checked>, shared: &Shared, require_picture: bool) -> Vec<String> {
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
    match *locked(&shared.idle) {
        Some((drawn, asked)) => {
            println!(
                "window: idle: over {} s in which nothing was published, {drawn} frames were drawn and the window asked for {asked}",
                IDLE.as_secs()
            );
            if drawn > asked {
                failures.push(format!(
                    "{drawn} frames were drawn while idle and {asked} were asked for"
                ));
            }
            if asked > IDLE_ASKS {
                failures.push(format!(
                    "the window asked to be drawn {asked} times while idle: more than {IDLE_ASKS} is a timer"
                ));
            }
        }
        None => failures.push("the window was never seen idle: no frame was presented".to_owned()),
    }
    let asked = shared.asked.load(Ordering::SeqCst);
    let drawn = counters.draws + counters.draws_failed;
    println!("window: over the whole run, {drawn} draws for {asked} things that asked for one");
    if drawn > asked {
        failures.push(format!(
            "{drawn} draws were made and {asked} were asked for"
        ));
    }

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
    let shared = Arc::new(Shared::default());
    // One clock stamps the input and times the frames: the journal's time
    // from an input to its frame is a subtraction on it.
    let clock = Arc::new(Monotonic::new());
    let queue = Arc::new(Queue::new());
    let session = {
        let shared = Arc::clone(&shared);
        Session::new(clock.clone(), move |window, _| renderer(window, &shared))
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

    let drawer = counting(&session, &shared);
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
    use std::time::Duration;

    use super::{Options, Picture, TOLERANCE, Verdict, judged, options, uncompared};

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
