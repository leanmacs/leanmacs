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
//! | `Opened` | Makes the renderer, on the calling thread, with the native window and the size; makes the loop over it; starts the render thread, which runs the loop until it is stopped. Then leaves word of the size and of the refresh rate. A session made `asking` hands its asker to the presenter (`Presenter::open_window`), whether or not a renderer could be made |
//! | `Resized` | `RenderHandle::resize`, with the size as a target |
//! | `Refresh` | `RenderHandle::set_refresh`, with the rate as an interval; nothing when the display does not say |
//! | `Damaged` | `RenderHandle::mark_dirty` |
//! | `Hidden` | `RenderHandle::set_hidden` |
//! | `Closing` | `RenderHandle::stop`; then joins the render thread and drops the renderer, on the calling thread. The presenter lets the window go (`Presenter::close_window`) |
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
//! # What reaches the loop: the presenter
//!
//! Lean publishes scenes to a display handle and never sees a render loop.
//! A display bound to a [`Presenter`] (`Display::present_to`) presents
//! each frame it lays out: the frame is submitted to the presenter's
//! target, the handle of the session that runs now, stamped with the
//! oldest window input taken off the editor queue since the last frame
//! (`events::take` notes it; [`Answering`]). So the journal measures from
//! a key's arrival in Rust to the frame that answers it. A display that is
//! not bound presents nothing, and a presenter with no target lets the
//! frame go and spends the stamp.
//!
//! # What reaches the window: the title, the menu and the background
//!
//! The scene's title is the window's ([`crate::display::WireScene`]'s
//! `title`): a display bound to a presenter hands it the title of each
//! scene it publishes ([`Presenter::name`]). The presenter keeps the title
//! named last and sends it to the open window as a
//! `editor_platform::Request::Title`, through the asker the session was
//! made with ([`Session::asking`], [`Asker`]), only when it is not the
//! title last sent there: a publish per key does not wake the window's
//! loop per key. A window that opens is sent the title named so far
//! ([`Presenter::open_window`]); the scene is published before the window
//! opens, and the platform counts its window as running before it tells
//! `Opened`, so the first title is never dropped. Once the window closes
//! ([`Presenter::close_window`]) a title named is kept for the next one.
//!
//! The scene's menu bar (`WireScene`'s `menu`) goes the same way, as a
//! `editor_platform::Request::Menu` ([`Presenter::menu`]), with one
//! difference: a scene that names no menu bar, as a scene no command loop
//! made names none, changes nothing, so the menu bar named last stays. A
//! window that opens is sent the title, then the menu bar.
//!
//! The ground of each frame presented (`Frame::ground`, the theme's
//! paper) goes the same way as the window's background, a
//! `editor_platform::Request::Background` ([`Presenter::present`]), with
//! the title's rule: sent only when it is not the background last sent,
//! and kept for the next window when none is open. A window that opens is
//! sent the title, the menu bar, then the background. So what the window
//! shows where nothing drew, behind the drawable area during a resize and
//! before a first frame, is the paper the renderer clears to. It does not
//! come from Lean: the presenter has every frame, and the scene, its wire
//! and Lean's requests are unchanged.
//!
//! These rules are pinned here on a recording asker; that a published
//! title, menu bar and paper reach the scripted window is wiring, in
//! `tests/render_session.rs`. What the scripted window was asked crosses
//! back to Lean's tests as words (`crate::window::asked_words`, a
//! background as the tag 8 and its three bytes), and the window-host
//! check reads the built-in theme's paper there.
//!
//! The presenter is a value, handed explicitly to whatever uses it, and
//! every test makes its own. The process has one, [`PRESENTER`], reached
//! only from the C functions and from the run of the process's window.
//!
//! # The headless session
//!
//! [`headless`] runs a loop with no window on a thread of its own, as the
//! presenter's target: before each frame is submitted the target is
//! resized to the frame's scene's size, at scale 1 ([`Follows::Scene`]).
//! The headless mode runs it over the CPU renderer
//! ([`editor_ffi_render_headless_start`]), which needs no GPU, so the
//! gate draws what Lean publishes. The journal, the counters and whether
//! the loop is at rest are read through the presenter's last session's
//! handle, which outlives the session ([`editor_ffi_render_journal`],
//! [`editor_ffi_render_counters`], [`editor_ffi_render_resting`], and
//! the wait for that rest, [`editor_ffi_render_await_rest`]).
//! Dropping a session ends it as [`Headless::stop`] does, once: it leaves
//! its presenter's target, stops its loop and joins its render thread, so
//! a session a failing test drops leaves no loop running.
//!
//! A render thread that cannot be started is a reason, as it is for a
//! window ([`Session::failure`]): [`headless`] answers it and starts
//! nothing, and [`editor_ffi_render_headless_start`] returns it with its
//! refusal's tag ([`HeadlessRefusal`]). No C function here panics. The
//! thread is started by a spawner the session is handed
//! ([`headless_with`]), so a test hands one that fails: no hermetic test
//! can make the system refuse a thread.
//!
//! # A renderer that cannot be made
//!
//! The factory may fail: no adapter, no device. The window then runs as it
//! would with nothing drawing in it, every input still reaches the queue,
//! and [`Session::failure`] says why. Nothing is retried. The run of the
//! window reads it once the window has closed and hands it to its caller
//! (`crate::window::Ran`), so Lean can say why nothing drew.
//!
//! # Where a test goes
//!
//! Which call each thing told becomes, and the two conversions, are pinned
//! here on a loop stepped by hand over `editor-render`'s published fakes;
//! so are the presenter's rules: the stamp answered, where a frame goes
//! with and without a target, and the headless target following the
//! scene. That the thread starts, draws and ends is wiring, in
//! `tests/render_session.rs`, over the scripted platform, and in
//! `tests/headless_render.rs` for the headless session. None states a
//! decision of the scheduler: what a call on the handle leads to is
//! `editor-render`'s, and is read here only by doing the same to two loops.

use std::io;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use editor_layout::frame::Frame;
use editor_platform::{Canvas, Drawer, Menu, NativeWindow, Request, Resize, Rgb};
use editor_render::clock::Clock;
use editor_render::journal::Entry;
use editor_render::port::{Renderer, Target};
use editor_render::render_loop::{CondvarPark, RenderHandle, RenderLoop};
use editor_render_wgpu::{HeadlessRenderer, Settings};

use crate::document::RawText;
use crate::log::RawWords;
use crate::text;
use crate::window::{CountingClock, InputClock, Monotonic, ProcessClock};
use crate::words::Writer;

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

impl Clock for ProcessClock {
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

/// The oldest stamp of an input taken off the editor queue and not yet
/// answered by a frame: what the next frame presented answers.
///
/// It is one word, 0 for none: [`Answering::note`] keeps the older of the
/// stamp held and the one noted, and [`Answering::take`] answers it and
/// leaves none. A stamp of 0 is no stamp.
#[derive(Debug, Default)]
pub struct Answering(AtomicU64);

impl Answering {
    /// Notes that an input stamped `stamp` waits for a frame.
    pub fn note(&self, stamp: u64) {
        if stamp == 0 {
            return;
        }
        // The closure always gives a value, so the update cannot fail.
        let _ = self
            .0
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |held| {
                Some(if held == 0 { stamp } else { held.min(stamp) })
            });
    }

    /// The oldest stamp noted since the last take, leaving none.
    pub fn take(&self) -> Option<u64> {
        Some(self.0.swap(0, Ordering::SeqCst)).filter(|stamp| *stamp != 0)
    }
}

/// Whose size a render target follows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Follows {
    /// A window's: the window says its size and scale ([`leave_word`]),
    /// and a frame presented is submitted as it is.
    Window,
    /// Each scene's: a headless target has no window, so before each frame
    /// is submitted the target is resized to its scene's size, at scale 1.
    Scene,
}

/// Where the presenter sends a request to the open window: the platform's
/// [`Platform::request`](editor_platform::Platform::request), in the
/// process. It never calls back into the presenter.
pub type Asker = Arc<dyn Fn(Request) + Send + Sync>;

/// Where the frames bound displays publish go, and what the window said
/// of its scale: one value, handed explicitly to everything that uses it.
///
/// - **The target**: the handle that takes submits now. A session puts
///   its handle here when its loop is made ([`Presenter::start`]) and takes
///   it out when it ends ([`Presenter::end`]). With no target, a frame
///   presented reaches nothing.
/// - **The last**: the handle of the latest session to start. It is not
///   cleared when the session ends, so the journal and the counters of a
///   window that has closed can still be read; a later session replaces
///   it.
/// - **The scale** the window last said, which a bound display lays out
///   at ([`crate::display::Display::present_to`]); 1 until told.
/// - **The stamp answered** ([`Answering`]): the oldest window input taken
///   off the editor queue since the last frame presented.
///
/// Each part is behind its own lock or atomic. The process has one, at the
/// C edge only ([`PRESENTER`]); every test makes its own.
pub struct Presenter {
    /// The handle that takes submits, and whose size it follows.
    target: Mutex<Option<(RenderHandle, Follows)>>,
    /// The handle of the latest session to start.
    last: Mutex<Option<RenderHandle>>,
    /// The bits of the scale, an `f32`.
    scale: AtomicU32,
    /// The stamp the next frame answers.
    answering: Answering,
    /// The title and the menu bar the scenes name, and the open window
    /// they go to.
    named: Mutex<Named>,
}

/// What [`Presenter::named`] guards.
#[derive(Default)]
struct Named {
    /// The title the last scene published names, if one has been.
    title: Option<String>,
    /// The menu bar the last scene that named one named, if one has.
    menu: Option<Menu>,
    /// The ground of the frame last presented, as the window's background,
    /// if one has been.
    background: Option<Rgb>,
    /// The open window, and what was last sent to it.
    window: Option<(Asker, Sent)>,
}

/// What was last sent to the open window.
#[derive(Default)]
struct Sent {
    /// The title, if one has been.
    title: Option<String>,
    /// The menu bar, if one has been.
    menu: Option<Menu>,
    /// The background, if one has been.
    background: Option<Rgb>,
}

impl Named {
    /// Sends the title named to the open window, when there is one and it
    /// is not the title last sent there; then the same of the menu bar, and
    /// then of the background.
    fn send(&mut self) {
        let Some((asker, sent)) = &mut self.window else {
            return;
        };
        if let Some(title) = &self.title
            && sent.title.as_ref() != Some(title)
        {
            sent.title = Some(title.clone());
            asker(Request::Title(title.clone()));
        }
        if let Some(menu) = &self.menu
            && sent.menu.as_ref() != Some(menu)
        {
            sent.menu = Some(menu.clone());
            asker(Request::Menu(menu.clone()));
        }
        if let Some(background) = self.background
            && sent.background != Some(background)
        {
            sent.background = Some(background);
            asker(Request::Background(background));
        }
    }
}

impl Presenter {
    /// A presenter with no target, no last session, at scale 1 and with no
    /// stamp to answer.
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            target: Mutex::new(None),
            last: Mutex::new(None),
            scale: AtomicU32::new(1.0_f32.to_bits()),
            answering: Answering::default(),
            named: Mutex::default(),
        })
    }

    /// Makes `handle` the target, whose size follows `follows`, and the
    /// last session's.
    pub fn start(&self, handle: RenderHandle, follows: Follows) {
        *locked(&self.last) = Some(handle.clone());
        *locked(&self.target) = Some((handle, follows));
    }

    /// Takes the target out: frames presented from now on reach nothing.
    /// The last session's handle stays.
    pub fn end(&self) {
        *locked(&self.target) = None;
    }

    /// The handle that takes submits, if there is one.
    pub fn target(&self) -> Option<RenderHandle> {
        locked(&self.target)
            .as_ref()
            .map(|(handle, _)| handle.clone())
    }

    /// The handle of the latest session to start, ended or not.
    pub fn last(&self) -> Option<RenderHandle> {
        locked(&self.last).clone()
    }

    /// The scale the window last said; 1 until told.
    pub fn scale(&self) -> f32 {
        f32::from_bits(self.scale.load(Ordering::SeqCst))
    }

    /// Holds `scale` as the scale the window says.
    pub fn set_scale(&self, scale: f32) {
        self.scale.store(scale.to_bits(), Ordering::SeqCst);
    }

    /// The stamp the next frame presented answers.
    pub fn answering(&self) -> &Answering {
        &self.answering
    }

    /// Keeps `title` as the one the scenes name, and sends it to the open
    /// window when it is not the title last sent there: a publish per key
    /// does not ask the window per key. The asker is called under the
    /// lock, so titles reach the window in the order they were named.
    pub fn name(&self, title: &str) {
        let mut named = locked(&self.named);
        named.title = Some(title.to_owned());
        named.send();
    }

    /// Keeps `menu` as the menu bar the scenes name, and sends it to the
    /// open window when it is not the menu bar last sent there, as
    /// [`name`](Self::name) does a title.
    pub fn menu(&self, menu: &Menu) {
        let mut named = locked(&self.named);
        named.menu = Some(menu.clone());
        named.send();
    }

    /// Makes `asker` the open window's, and sends it the title named so
    /// far, then the menu bar, then the background, if each has been: a
    /// window opens with the platform's own title, no menu bar of the
    /// editor's and the system's background.
    pub fn open_window(&self, asker: Asker) {
        let mut named = locked(&self.named);
        named.window = Some((asker, Sent::default()));
        named.send();
    }

    /// Lets the open window go: a title or a menu bar named from now on is
    /// kept, and goes to the next window that opens.
    pub fn close_window(&self) {
        locked(&self.named).window = None;
    }

    /// Presents `frame`, laid out from a scene `size` across and down: the
    /// stamp answered is taken, and the frame is submitted to the target
    /// with it, after the target is resized to `size` at scale 1 when it
    /// follows the scene. With no target the stamp is spent all the same,
    /// so an input that led to no frame shown is never counted against a
    /// later one.
    ///
    /// The frame's ground is kept as the window's background, and sent to
    /// the open window when it is not the background last sent there, as
    /// [`name`](Self::name) does a title; with no window open it is kept
    /// for the next.
    pub fn present(&self, frame: Arc<Frame>, size: (u32, u32)) {
        {
            let [red, green, blue, _] = frame.ground.0.to_be_bytes();
            let mut named = locked(&self.named);
            named.background = Some(Rgb { red, green, blue });
            named.send();
        }
        let stamp = self.answering.take();
        let Some((handle, follows)) = locked(&self.target).clone() else {
            return;
        };
        if follows == Follows::Scene {
            handle.resize(Target {
                width: size.0,
                height: size.1,
                scale: 1.0,
            });
        }
        handle.submit(frame, stamp);
    }
}

/// `mutex`, locked. A poisoned lock is used as it is: what these locks
/// guard is replaced whole.
fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The process's presenter. It is reached only from the C functions and
/// from the main-thread service's run of the process's window
/// (`crate::window::run_on_this_thread`); every test makes its own.
pub static PRESENTER: LazyLock<Arc<Presenter>> = LazyLock::new(Presenter::new);

/// A render loop with no window, on a thread of its own, drawing what bound
/// displays publish on a target the size of each scene, at scale 1: the
/// headless mode's renderer ([`headless`]).
pub struct Headless<R> {
    /// The way to the loop.
    handle: RenderHandle,
    /// The render thread, which gives the renderer back.
    thread: Option<JoinHandle<R>>,
    /// The presenter it is the target of.
    presenter: Arc<Presenter>,
}

/// Starts a headless render session: a loop over the renderer `make`
/// makes, on the calling thread, telling the time by `clock`, run on a
/// thread of its own named `render`; and makes it `presenter`'s target,
/// following each scene's size, and its last session's. When the thread
/// cannot be started it answers why, and starts nothing: the renderer is
/// dropped and the presenter is left as it was.
pub fn headless<R: Renderer + Send + 'static>(
    make: impl FnOnce() -> R,
    clock: Arc<dyn Clock>,
    presenter: Arc<Presenter>,
) -> Result<Headless<R>, String> {
    headless_with(make, clock, presenter, |run| {
        thread::Builder::new().name("render".into()).spawn(run)
    })
}

/// [`headless`], with the render thread started by `spawn`, which is
/// handed the loop's run and answers its thread, or the system's reason
/// there is none: the decision a test reaches with a spawner that fails.
pub fn headless_with<R: Renderer + Send + 'static>(
    make: impl FnOnce() -> R,
    clock: Arc<dyn Clock>,
    presenter: Arc<Presenter>,
    spawn: impl FnOnce(Box<dyn FnOnce() -> R + Send>) -> io::Result<JoinHandle<R>>,
) -> Result<Headless<R>, String> {
    let park = Arc::new(CondvarPark::new(Arc::clone(&clock)));
    // A target of no size until the first scene says one.
    let begin = Target {
        width: 1,
        height: 1,
        scale: 1.0,
    };
    let (render_loop, handle) = RenderLoop::new(make(), clock, park, begin);
    let thread = spawn(Box::new(move || render_loop.run()))
        .map_err(|error| format!("the render thread could not be started: {error}"))?;
    presenter.start(handle.clone(), Follows::Scene);
    Ok(Headless {
        handle,
        thread: Some(thread),
        presenter,
    })
}

/// Why a headless render session was not started into a slot
/// ([`start_into`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HeadlessRefusal {
    /// The slot holds a session that runs.
    Running,
    /// The render thread could not be started: why ([`headless`]).
    NoThread(String),
}

impl HeadlessRefusal {
    /// Its tag as it crosses the boundary: 1 and 2, a session started
    /// being 0 ([`editor_ffi_render_headless_start`]).
    pub fn tag(&self) -> u8 {
        match self {
            Self::Running => 1,
            Self::NoThread(_) => 2,
        }
    }

    /// What it says.
    pub fn reason(&self) -> String {
        match self {
            Self::Running => "a headless render session runs already".to_owned(),
            Self::NoThread(reason) => reason.clone(),
        }
    }
}

/// Starts a session with `start` into `slot` when it holds none, and
/// keeps it there. Refused, with the slot as it was, when it holds one,
/// and then `start` is not called; or when `start` answers that the
/// session's render thread could not be started.
pub fn start_into<R>(
    slot: &Mutex<Option<Headless<R>>>,
    start: impl FnOnce() -> Result<Headless<R>, String>,
) -> Result<(), HeadlessRefusal> {
    let mut running = locked(slot);
    if running.is_some() {
        return Err(HeadlessRefusal::Running);
    }
    *running = Some(start().map_err(HeadlessRefusal::NoThread)?);
    Ok(())
}

impl<R> Headless<R> {
    /// The way to the loop.
    pub fn handle(&self) -> RenderHandle {
        self.handle.clone()
    }

    /// Takes the session out of its presenter's target, stops the loop and
    /// waits for its thread to end. The presenter's last session's handle
    /// stays, for the journal and the counters. Dropping the session does
    /// the same, so a session a failing test drops still ends its loop.
    pub fn stop(mut self) {
        self.end();
    }

    /// What [`stop`](Self::stop) and the drop do, once: a session already
    /// ended does nothing, so it never ends a later session's target.
    fn end(&mut self) {
        let Some(thread) = self.thread.take() else {
            return;
        };
        self.presenter.end();
        self.handle.stop();
        // A thread that panicked has nothing to give back.
        let _ = thread.join();
    }
}

impl<R> Drop for Headless<R> {
    /// Ends the session as [`Headless::stop`] does, if it has not ended.
    fn drop(&mut self) {
        self.end();
    }
}

/// The process's headless render session, while one runs.
static HEADLESS: Mutex<Option<Headless<HeadlessRenderer>>> = Mutex::new(None);

/// Starts the process's headless render session: the CPU renderer, on the
/// process's clock, as the process's presenter's target. Returns how it
/// went, and fills `out` with what it says ([`start_into`]):
///
/// - 0 when it started; `out` is empty.
/// - 1 ([`HeadlessRefusal::Running`]) when one runs already, and nothing
///   is started; `out` says so.
/// - 2 ([`HeadlessRefusal::NoThread`]) when its render thread could not
///   be started, and nothing is started; `out` says why, in the system's
///   words.
///
/// It never panics: a thread the system refuses is the refusal 2.
///
/// # Safety
///
/// `out` points to a writable [`RawText`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_render_headless_start(out: *mut RawText) -> u8 {
    let started = start_into(&HEADLESS, || {
        headless(
            || HeadlessRenderer::new(Settings::default()),
            Arc::new(ProcessClock),
            Arc::clone(&PRESENTER),
        )
    });
    let (tag, reason) = match started {
        Ok(()) => (0, String::new()),
        Err(refusal) => (refusal.tag(), refusal.reason()),
    };
    let (text, text_len) = text::lend(reason);
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(RawText { text, text_len }) };
    tag
}

/// Stops the process's headless render session and waits for its thread.
/// Returns false when none runs.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_render_headless_stop() -> bool {
    let session = locked(&HEADLESS).take();
    session.map(Headless::stop).is_some()
}

/// The handle of the process's latest render session, ended or not.
fn last_session() -> Option<RenderHandle> {
    PRESENTER.last()
}

/// Fills `out` with the journal entries of the process's latest render
/// session whose serial is above `after`: their count, then six words for
/// each, oldest first: its serial, `input_ns`, `draw_ns`, `present_ns`,
/// the rows rebuilt and the rows reused. The status is 1, with no words,
/// when no session has started.
///
/// # Safety
///
/// `out` points to a writable [`RawWords`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_render_journal(after: u64, out: *mut RawWords) {
    let raw = match last_session() {
        None => RawWords::with_status(1, Vec::new()),
        Some(handle) => {
            let entries: Vec<Entry> = handle
                .journal()
                .into_iter()
                .filter(|entry| entry.serial > after)
                .collect();
            let mut writer = Writer::with_capacity(1 + 6 * entries.len());
            writer.size(entries.len());
            for entry in entries {
                for word in [
                    entry.serial,
                    entry.input_ns,
                    entry.draw_ns,
                    entry.present_ns,
                    entry.rows_rebuilt,
                    entry.rows_reused,
                ] {
                    writer.word(word);
                }
            }
            RawWords::with_status(0, writer.finish())
        }
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
}

/// Fills `out` with the counters of the process's latest render session,
/// twelve words in the order of `editor_render::journal::Counters`' fields:
/// draws, draws failed, frames submitted, frames replaced, rows rebuilt,
/// rows reused, glyphs rasterised, reused, evicted and skipped, atlas
/// bytes, journal entries dropped. The status is 1, with no words, when no
/// session has started.
///
/// # Safety
///
/// `out` points to a writable [`RawWords`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_render_counters(out: *mut RawWords) {
    let raw = match last_session() {
        None => RawWords::with_status(1, Vec::new()),
        Some(handle) => {
            let counters = handle.counters();
            let mut writer = Writer::with_capacity(12);
            for word in [
                counters.draws,
                counters.draws_failed,
                counters.frames_submitted,
                counters.frames_replaced,
                counters.rows_rebuilt,
                counters.rows_reused,
                counters.glyphs_rasterised,
                counters.glyphs_reused,
                counters.glyphs_evicted,
                counters.glyphs_skipped,
                counters.atlas_bytes,
                counters.journal_dropped,
            ] {
                writer.word(word);
            }
            RawWords::with_status(0, writer.finish())
        }
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
}

/// Whether the process's latest render session's loop is at rest
/// (`RenderHandle::resting`): 2 when it is, 1 when it is not, and 0 when
/// no session has started.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_render_resting() -> u8 {
    match last_session() {
        None => 0,
        Some(handle) if handle.resting() => 2,
        Some(_) => 1,
    }
}

/// Waits until the process's latest render session's loop is at rest
/// (`RenderHandle::wait_resting`), and says how it ended, in
/// [`editor_ffi_render_resting`]'s words: 2 once it is at rest, 1 when
/// `bound_ms` milliseconds passed first, and 0 at once when no session has
/// started. A readout for tests, which use it to know that what they asked
/// of the loop has been drawn: it returns on the step that records rest,
/// never by a poll.
///
/// `bound_ms` is a hang guard: only a loop that never comes to rest
/// reaches it.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_render_await_rest(bound_ms: u64) -> u8 {
    await_rest(last_session(), Duration::from_millis(bound_ms))
}

/// What [`editor_ffi_render_await_rest`] answers for the session `last`.
fn await_rest(last: Option<RenderHandle>, bound: Duration) -> u8 {
    match last {
        None => 0,
        Some(handle) if handle.wait_resting(bound) => 2,
        Some(_) => 1,
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
    /// Where bound displays' frames go while the window is open.
    presenter: Arc<Presenter>,
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
    /// Where requests to the window go, which the presenter is handed when
    /// the window opens; none for a session that asks the window nothing.
    asker: Option<Asker>,
}

impl<R: Renderer + Send + 'static> Session<R> {
    /// A session that has made nothing yet. `make` is asked for a renderer
    /// when the window opens, on the thread that tells so, and the loop
    /// tells the time by `clock`. The session's loop is `presenter`'s
    /// target from when the window opens until it closes, and its last
    /// session's from then on; and the presenter holds the scale the window
    /// last said.
    pub fn new(
        clock: Arc<dyn Clock>,
        make: impl Fn(Option<&NativeWindow>, Target) -> Result<R, String> + Send + Sync + 'static,
        presenter: Arc<Presenter>,
    ) -> Self {
        Self {
            shared: Arc::new(Shared {
                make: Box::new(make),
                clock,
                presenter,
                state: Mutex::new(State {
                    handle: None,
                    thread: None,
                    failure: None,
                    asker: None,
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

    /// The same session, which hands `asker` to its presenter when the
    /// window opens ([`Presenter::open_window`]), so that the title the
    /// scenes name reaches the window, and lets it go when the window is
    /// closing.
    #[must_use]
    pub fn asking(self, asker: Asker) -> Self {
        self.state().asker = Some(asker);
        self
    }

    /// Takes one thing the window tells: the table in the module docs, and
    /// the presenter's part of it.
    fn tell(&self, canvas: &Canvas) {
        let presenter = &self.shared.presenter;
        match canvas {
            Canvas::Opened { window, size, .. } => {
                presenter.set_scale(size.scale as f32);
                if let Some(handle) = self.open(window.as_ref(), target(*size)) {
                    presenter.start(handle, Follows::Window);
                }
                // A window nothing draws in still has a title.
                let asker = self.state().asker.clone();
                if let Some(asker) = asker {
                    presenter.open_window(asker);
                }
            }
            Canvas::Resized(size) => presenter.set_scale(size.scale as f32),
            // Nothing takes submits from here on, before the loop stops,
            // and no title goes to the window.
            Canvas::Closing => {
                presenter.end();
                presenter.close_window();
            }
            _ => {}
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
    /// runs the loop until it is stopped and gives the renderer back. It
    /// answers the new loop's handle. A session whose thread runs is left
    /// as it is, and answers none.
    fn open(&self, window: Option<&NativeWindow>, target: Target) -> Option<RenderHandle> {
        if self.state().thread.is_some() {
            return None;
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
                state.handle = Some(handle.clone());
                state.thread = Some(thread);
                state.failure = None;
                Some(handle)
            }
            Err(reason) => {
                state.failure = Some(reason);
                None
            }
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
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Duration;

    use editor_layout::Layout;
    use editor_layout::frame::Frame;
    use editor_layout::scene::{Rect, Scene};
    use editor_layout::shaper::fake::CellShaper;
    use editor_platform::{Canvas, Resize};
    use editor_render::clock::{Clock, FakeClock};
    use editor_render::fake::RecordingRenderer;
    use editor_render::port::Target;
    use editor_render::render_loop::{RecordingPark, RenderHandle, RenderLoop, Step};

    use editor_layout::face::Color;
    use editor_platform::{Request, Rgb};

    use super::{
        Answering, Asker, Follows, Presenter, Session, await_rest, leave_word, refresh_ns, target,
    };
    use crate::window::{CountingClock, InputClock, Monotonic};

    /// The size the loops begin at, and the target it is.
    const SIZE: Resize = Resize {
        width: 400,
        height: 300,
        scale: 1.0,
        fullscreen: false,
        corner_clearance: 0,
        top_inset: 0,
    };

    /// Another size.
    const LARGER: Resize = Resize {
        width: 800,
        height: 600,
        scale: 2.0,
        fullscreen: false,
        corner_clearance: 0,
        top_inset: 0,
    };

    /// A long time on the loop's clock: longer than any refresh interval a
    /// test sets or the loop begins with.
    const LONG: u64 = 10_000_000_000;

    /// A session that a test drops without `stop`, as a failing test does,
    /// has stopped its loop and joined its render thread once the drop
    /// returns, and is no longer its presenter's target. The thread says
    /// it has ended as its loop returns; no sleep is used.
    #[test]
    fn a_headless_session_dropped_without_stop_ends_its_render_thread() {
        let presenter = Presenter::new();
        let ended = Arc::new(AtomicBool::new(false));
        let session = super::headless_with(
            RecordingRenderer::new,
            Arc::new(FakeClock::new()),
            Arc::clone(&presenter),
            {
                let ended = Arc::clone(&ended);
                move |run| {
                    std::thread::Builder::new()
                        .name("render-test".into())
                        .spawn(move || {
                            let renderer = run();
                            ended.store(true, Ordering::SeqCst);
                            renderer
                        })
                }
            },
        )
        .expect("the render thread starts");
        let handle = session.handle();

        drop(session);
        let ended_at_drop = ended.load(Ordering::SeqCst);
        // On a session with no drop, the loop still runs: stop it, so the
        // stray thread ends.
        handle.stop();

        assert!(
            ended_at_drop,
            "the drop returned with the render thread running"
        );
        assert!(presenter.target().is_none());
        assert!(presenter.last().is_some_and(|last| last.same(&handle)));
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

    /// The codes of `editor_ffi_render_await_rest`: 0 with no session, 2
    /// for a loop at rest, 1 for one the bound passed on first.
    #[test]
    fn a_wait_for_rest_says_whether_there_is_a_session_and_whether_it_rested() {
        assert_eq!(await_rest(None, Duration::ZERO), 0);
        let (mut render, handle) = RenderLoop::new(
            RecordingRenderer::new(),
            Arc::new(FakeClock::new()),
            Arc::new(RecordingPark::new()),
            target(SIZE),
        );
        assert_eq!(await_rest(Some(handle.clone()), Duration::ZERO), 1);
        assert_eq!(render.step(), Step::Wait(None));
        assert_eq!(await_rest(Some(handle), Duration::ZERO), 2);
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
                fullscreen: false,
                corner_clearance: 0,
                top_inset: 0,
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
            fullscreen: false,
            corner_clearance: 0,
            top_inset: 0,
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
    fn the_stamp_answered_is_the_oldest_noted_and_taking_it_leaves_none() {
        let answering = Answering::default();
        assert_eq!(answering.take(), None);
        answering.note(30);
        answering.note(10);
        answering.note(20);
        assert_eq!(answering.take(), Some(10));
        assert_eq!(answering.take(), None);
        // A stamp of 0 is no stamp.
        answering.note(0);
        assert_eq!(answering.take(), None);
    }

    /// A loop stepped by hand over the recording renderer on `clock`,
    /// beginning on `begin`.
    fn stepped(clock: &FakeClock, begin: Target) -> (RenderLoop<RecordingRenderer>, RenderHandle) {
        RenderLoop::new(
            RecordingRenderer::new(),
            Arc::new(clock.clone()),
            Arc::new(RecordingPark::new()),
            begin,
        )
    }

    #[test]
    fn a_frame_presented_reaches_the_target_with_the_stamp_it_answers() {
        let clock = FakeClock::new();
        let (mut render, handle) = stepped(&clock, target(SIZE));
        let presenter = Presenter::new();
        presenter.start(handle.clone(), Follows::Window);
        assert!(presenter.target().is_some());
        assert!(presenter.last().is_some());
        presenter.answering().note(77);
        presenter.present(frame_of("one"), (400, 300));
        assert_eq!(handle.counters().frames_submitted, 1);
        assert_eq!(presenter.answering().take(), None);
        let Step::Drew(entry) = render.step() else {
            panic!("the frame is drawn");
        };
        assert_eq!(entry.input_ns, 77);
        // A window's target is the window's: a frame does not resize it.
        assert_eq!(render.renderer().requests()[0].target, target(SIZE));
    }

    #[test]
    fn with_no_target_a_frame_presented_reaches_nothing_and_the_stamp_is_spent() {
        let clock = FakeClock::new();
        let (_render, handle) = stepped(&clock, target(SIZE));
        let presenter = Presenter::new();
        assert!(presenter.target().is_none() && presenter.last().is_none());
        presenter.answering().note(5);
        presenter.present(frame_of("one"), (400, 300));
        assert_eq!(presenter.answering().take(), None);
        // Ended: the target is gone, and the last session's handle stays.
        presenter.start(handle.clone(), Follows::Window);
        presenter.end();
        assert!(presenter.target().is_none());
        presenter.present(frame_of("two"), (400, 300));
        assert_eq!(handle.counters().frames_submitted, 0);
        let last = presenter.last().expect("the last session's handle");
        assert_eq!(last.counters(), handle.counters());
    }

    #[test]
    fn a_headless_target_is_resized_to_the_scene_at_scale_one_before_the_frame_is_submitted() {
        let clock = FakeClock::new();
        let (mut render, handle) = stepped(
            &clock,
            Target {
                width: 1,
                height: 1,
                scale: 1.0,
            },
        );
        let presenter = Presenter::new();
        presenter.start(handle, Follows::Scene);
        presenter.present(frame_of("one"), (640, 480));
        assert!(matches!(render.step(), Step::Drew(_)));
        assert_eq!(
            render.renderer().requests()[0].target,
            Target {
                width: 640,
                height: 480,
                scale: 1.0,
            }
        );
    }

    #[test]
    fn a_presenter_holds_the_scale_last_said_and_is_at_one_until_told() {
        let presenter = Presenter::new();
        assert_eq!(presenter.scale(), 1.0);
        presenter.set_scale(2.0);
        assert_eq!(presenter.scale(), 2.0);
        presenter.set_scale(1.25);
        assert_eq!(presenter.scale(), 1.25);
    }

    /// An asker that records what it is asked, and what it recorded.
    fn recording_asker() -> (Asker, Arc<std::sync::Mutex<Vec<Request>>>) {
        let asked = Arc::new(std::sync::Mutex::new(Vec::new()));
        let asker: Asker = {
            let asked = Arc::clone(&asked);
            Arc::new(move |request| {
                asked
                    .lock()
                    .expect("nothing panics holding it")
                    .push(request)
            })
        };
        (asker, asked)
    }

    /// The request for the title `text`.
    fn title(text: &str) -> Request {
        Request::Title(text.to_owned())
    }

    /// What `asked` holds.
    fn held(asked: &std::sync::Mutex<Vec<Request>>) -> Vec<Request> {
        asked.lock().expect("nothing panics holding it").clone()
    }

    #[test]
    fn a_title_named_before_the_window_opens_is_sent_when_it_opens() {
        let presenter = Presenter::new();
        let (asker, asked) = recording_asker();
        presenter.name("scratch");
        presenter.name("notes.txt");

        presenter.open_window(asker);

        assert_eq!(held(&asked), [title("notes.txt")]);
    }

    #[test]
    fn a_window_that_opens_before_any_title_is_named_is_sent_none() {
        let presenter = Presenter::new();
        let (asker, asked) = recording_asker();
        presenter.open_window(asker);
        assert_eq!(held(&asked), []);
        presenter.name("scratch");
        assert_eq!(held(&asked), [title("scratch")]);
    }

    #[test]
    fn a_title_is_sent_to_the_open_window_only_when_it_changes() {
        let presenter = Presenter::new();
        let (asker, asked) = recording_asker();
        presenter.open_window(asker);

        for named in [
            "notes.txt",
            "notes.txt",
            "todo.txt",
            "todo.txt",
            "notes.txt",
        ] {
            presenter.name(named);
        }

        assert_eq!(
            held(&asked),
            [title("notes.txt"), title("todo.txt"), title("notes.txt")]
        );
    }

    #[test]
    fn once_the_window_closes_a_title_goes_nowhere_and_is_kept() {
        let presenter = Presenter::new();
        let (asker, asked) = recording_asker();
        presenter.open_window(asker);
        presenter.name("notes.txt");
        presenter.close_window();

        presenter.name("todo.txt");

        assert_eq!(held(&asked), [title("notes.txt")]);
        let (again, asked_again) = recording_asker();
        presenter.open_window(again);
        assert_eq!(held(&asked_again), [title("todo.txt")]);
    }

    #[test]
    fn a_window_that_opens_after_another_closed_is_sent_the_title_named_last() {
        let presenter = Presenter::new();
        let (first, _) = recording_asker();
        presenter.open_window(first);
        presenter.name("notes.txt");
        presenter.close_window();

        // The title it names is the one the first window was sent: the new
        // window shows its own until it is told.
        let (second, asked) = recording_asker();
        presenter.open_window(second);
        assert_eq!(held(&asked), [title("notes.txt")]);
        presenter.name("notes.txt");
        assert_eq!(held(&asked), [title("notes.txt")]);
    }

    /// The window opened, with no native window, at [`SIZE`].
    fn opened() -> Canvas {
        Canvas::Opened {
            window: None,
            size: SIZE,
            refresh_millihertz: None,
        }
    }

    #[test]
    fn a_window_nothing_can_draw_in_is_still_sent_its_title() {
        let presenter = Presenter::new();
        let (asker, asked) = recording_asker();
        let session: Session<RecordingRenderer> = Session::new(
            Arc::new(FakeClock::new()),
            |_, _| Err("no adapter".to_owned()),
            Arc::clone(&presenter),
        )
        .asking(asker);
        presenter.name("scratch");
        let drawer = session.drawer();

        drawer(opened());
        assert_eq!(session.failure().as_deref(), Some("no adapter"));
        assert_eq!(held(&asked), [title("scratch")]);
        presenter.name("notes.txt");
        drawer(Canvas::Closing);
        presenter.name("todo.txt");

        assert_eq!(held(&asked), [title("scratch"), title("notes.txt")]);
    }

    /// A menu bar of one empty menu titled `title`.
    fn menu_titled(title: &str) -> editor_platform::Menu {
        editor_platform::Menu {
            menus: vec![editor_platform::menu::Submenu {
                title: title.to_owned(),
                role: None,
                items: vec![],
            }],
        }
    }

    /// The request for the menu bar [`menu_titled`] `title`.
    fn menu(title: &str) -> Request {
        Request::Menu(menu_titled(title))
    }

    #[test]
    fn a_menu_named_before_the_window_opens_is_sent_when_it_opens_after_the_title() {
        let presenter = Presenter::new();
        let (asker, asked) = recording_asker();
        presenter.menu(&menu_titled("A"));
        presenter.name("scratch");
        presenter.menu(&menu_titled("B"));

        presenter.open_window(asker);

        assert_eq!(held(&asked), [title("scratch"), menu("B")]);
    }

    #[test]
    fn a_menu_is_sent_to_the_open_window_only_when_it_changes() {
        let presenter = Presenter::new();
        let (asker, asked) = recording_asker();
        presenter.open_window(asker);

        for named in ["A", "A", "B", "B", "A"] {
            presenter.menu(&menu_titled(named));
        }
        presenter.name("scratch");
        presenter.menu(&menu_titled("A"));

        assert_eq!(
            held(&asked),
            [menu("A"), menu("B"), menu("A"), title("scratch")]
        );
    }

    #[test]
    fn once_the_window_closes_a_menu_goes_nowhere_and_is_kept_for_the_next() {
        let presenter = Presenter::new();
        let (asker, asked) = recording_asker();
        presenter.open_window(asker);
        presenter.menu(&menu_titled("A"));
        presenter.close_window();

        presenter.menu(&menu_titled("B"));

        assert_eq!(held(&asked), [menu("A")]);
        let (again, asked_again) = recording_asker();
        presenter.open_window(again);
        assert_eq!(held(&asked_again), [menu("B")]);
    }

    #[test]
    fn a_window_nothing_can_draw_in_is_still_sent_its_menu() {
        let presenter = Presenter::new();
        let (asker, asked) = recording_asker();
        let session: Session<RecordingRenderer> = Session::new(
            Arc::new(FakeClock::new()),
            |_, _| Err("no adapter".to_owned()),
            Arc::clone(&presenter),
        )
        .asking(asker);
        presenter.menu(&menu_titled("A"));
        let drawer = session.drawer();

        drawer(opened());
        assert_eq!(session.failure().as_deref(), Some("no adapter"));
        presenter.menu(&menu_titled("B"));
        drawer(Canvas::Closing);
        presenter.menu(&menu_titled("C"));

        assert_eq!(held(&asked), [menu("A"), menu("B")]);
    }

    /// A frame made by hand, of no view, on the ground `ground`.
    fn grounded(ground: Color) -> Arc<Frame> {
        Arc::new(Frame {
            ground,
            ..Frame::default()
        })
    }

    /// The request for the background of `ground`.
    fn background(ground: Color) -> Request {
        let [red, green, blue, _] = ground.0.to_be_bytes();
        Request::Background(Rgb { red, green, blue })
    }

    /// Two papers.
    const PAPER: Color = Color::rgb(0x2e, 0x34, 0x40);
    const LIGHT: Color = Color::rgb(0xec, 0xef, 0xf4);

    #[test]
    fn the_ground_of_a_presented_frame_is_asked_of_the_window_only_when_it_changes() {
        let presenter = Presenter::new();
        let (asker, asked) = recording_asker();
        presenter.open_window(asker);
        for ground in [PAPER, PAPER, LIGHT, LIGHT, PAPER] {
            presenter.present(grounded(ground), (400, 300));
        }
        assert_eq!(
            held(&asked),
            [background(PAPER), background(LIGHT), background(PAPER)]
        );
    }

    #[test]
    fn a_window_that_opens_is_sent_the_title_the_menu_bar_and_then_the_background() {
        let presenter = Presenter::new();
        let (asker, asked) = recording_asker();
        presenter.present(grounded(PAPER), (400, 300));
        presenter.name("scratch");
        presenter.menu(&menu_titled("A"));

        presenter.open_window(asker);

        assert_eq!(
            held(&asked),
            [title("scratch"), menu("A"), background(PAPER)]
        );
    }

    #[test]
    fn with_no_window_the_ground_is_kept_for_the_next() {
        let presenter = Presenter::new();
        let (first, asked_first) = recording_asker();
        presenter.open_window(first);
        presenter.present(grounded(PAPER), (400, 300));
        presenter.close_window();
        presenter.present(grounded(LIGHT), (400, 300));
        assert_eq!(held(&asked_first), [background(PAPER)]);

        let (second, asked_second) = recording_asker();
        presenter.open_window(second);
        assert_eq!(held(&asked_second), [background(LIGHT)]);
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
