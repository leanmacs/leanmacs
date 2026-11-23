//! The window port's real adapter: [`WinitPlatform`], a
//! [`Platform`] over winit.
//!
//! The port, its fake and its contract are `editor-platform`'s. This crate
//! is thin: it opens one window, translates what winit says of it into the
//! port's [`Input`] and [`Canvas`], and ends its loop when it is asked to
//! close. No winit or objc2 type is public, no other crate depends on
//! winit or on the objc2 crates it names (`deny.toml`), and AppKit is named
//! only in the modules `delegate`, `menu_bar`, `corner` and `background`,
//! on macOS.
//!
//! The translation is the module `translate`'s, with a key's names in
//! `names` and the window's native handles in `native`: every key with its
//! logical key, physical key and modifiers; the pointer's press, drag,
//! release and wheel; a resize with the size, the scale, whether the
//! window is in fullscreen, its corner clearance (the module `corner`
//! decides it) and its top inset (the module `title_bar` decides it); the
//! focus; a
//! composition; a request to close; and, for whatever draws in the window,
//! its native window, its size, its display's refresh rate, damage, and
//! whether it is hidden. Their docs say what is decided where winit and the
//! port differ.
//!
//! What it does beyond translating:
//!
//! - **It tells the drawer about the window around its loop.** The window
//!   opened, before it reports that to anyone; and the window is closing,
//!   once its loop has ended and before the window is dropped, so that
//!   whatever was made on the window is let go while it is still there.
//! - **It says how large the window is when it opens**: a
//!   [`Input::Resized`] with the window's size and scale straight after
//!   [`Input::Opened`], since nothing else in the port says so.
//! - **It leaves winit's loop waiting.** The loop's control flow is never
//!   set, so it is winit's default, a wait for the next event, and the
//!   adapter never asks winit for a redraw: a window nobody touches turns
//!   its loop not at all. What draws is woken by what the drawer is told,
//!   on a thread of its own, and never by this loop.
//! - **It refuses to run off the process's main thread**, with a reason,
//!   before it touches winit: winit panics there. Whether the calling thread
//!   is the main one is asked of a function the caller supplies, since the
//!   check belongs to whoever owns the main thread.
//! - **It opens the window as the options' title bar says**
//!   (`title_bar::attributes`): on macOS a themed window has a
//!   transparent title bar over a full-size content view, and a standard
//!   one winit's defaults. The choice is kept for the run.
//! - **It allows an input method to compose exactly when the options say
//!   so.** With composition not allowed, a dead key arrives as a key.
//! - **It asks for the keyboard focus once**, when the window opens. The
//!   system may decline: macOS gives focus only to an application the user
//!   has brought forward.
//! - **It builds the menu bar the editor asks for (macOS)**, and none of
//!   winit's: [`Request::Menu`] is the application's, not the window's, so
//!   the loop takes it out of the requests once the window has opened and
//!   hands the module `menu`'s plan of it to `menu_bar`, which builds it in
//!   AppKit. Every decision of what is built is `menu`'s. Elsewhere winit
//!   has no menu bar, and a menu changes nothing shown, as the port's
//!   request contract lets a platform with none.
//! - **It reports a command item chosen** as [`Input::Menu`]: the item's
//!   action is the one method of a target object of the crate's, which
//!   sends the command's name on a channel of the choices' own and wakes
//!   the loop, as the delegate hands files. The loop reports each name when
//!   it is woken; a close drops them with the requests.
//! - **It runs once in a process.** winit makes one event loop a process, so
//!   a second run fails with winit's reason.
//! - **It ends its loop on a close, and only then.** A close asks the loop
//!   to end (`Closing`) and then wakes it. winit may wake a loop nobody
//!   woke, and merges wake-ups, so a loop that wakes ends only once a close
//!   has been asked.
//! - **It carries out requests on the main thread, through a channel of
//!   its own.** [`Platform::request`] sends the request on a
//!   `std::sync::mpsc` channel and then wakes the loop, as a close asks
//!   before it wakes, so the loop that wakes finds it. The loop takes every
//!   request on the channel (`wake`): when a close has been asked they are
//!   dropped, since the window is going; otherwise each is carried out on
//!   the window, in order, by the module `asked`'s translation, and then
//!   the window's fullscreen, corners and title bar are read and a change
//!   of any reported as a resize. A request asked with no window running does nothing, and one
//!   that arrives before the window is made is dropped.
//! - **It fills what nothing drew with the background asked**
//!   ([`Request::Background`]): on macOS the `NSWindow`'s
//!   `backgroundColor` (the module `background`), which shows behind the
//!   content view during a live resize and before a first frame. Elsewhere
//!   winit has no setter, and it does nothing.
//! - **It receives the files the system asks the app to open (macOS)**,
//!   through an application delegate of its own (the module `delegate`),
//!   installed once winit's event loop is built and before it runs, since a
//!   cold start's files arrive before the window is made. winit 0.31
//!   guarantees it registers no delegate. The delegate sends each list on a
//!   channel of the files' own and wakes the loop, as a request is sent.
//! - **It holds those files until the window has opened.** They are taken
//!   off their channel when the loop is woken, as requests are, and when
//!   the window opens; the module `files` decides what is reported and
//!   when: after `Opened` and the `Resized` after it, each list as one
//!   [`Input::OpenFiles`], in the order they arrived. A close drops them
//!   with the requests.
//! - **It reports the system's quit and answers it (macOS).** The same
//!   delegate answers every `applicationShouldTerminate:` (Command-Q's
//!   `terminate:`, the Dock's Quit, a logout) with `NSTerminateLater`, so
//!   AppKit waits inside `terminate:`, and hands the ask on through a
//!   channel of its own and a wake of the loop. The module `terminate`
//!   decides what comes of it: the first ask is reported once as
//!   [`Input::QuitRequested`], after `Opened`, and not again while it is
//!   pending; [`Request::KeepRunning`] cancels a pending one
//!   (`replyToApplicationShouldTerminate:NO`) and is otherwise nothing; a
//!   close lets one pending, held or still waiting go ahead (`YES`), so that
//!   none is left unanswered, unless a keep running came with it, when it
//!   cancels them (`NO`) and the run returns; and a window that could not
//!   be opened cancels one held or waiting. Keep running is taken out of
//!   the requests the loop finds, and never reaches the window; on a close,
//!   `wake` says whether one was among the requests it drops. winit's loop
//!   handles its
//!   wake-ups and requests while AppKit waits, since winit runs them in the
//!   common modes, which include AppKit's modal-panel mode.
//! - **It does what follows the loop's end before it lets the system
//!   terminate (macOS).** AppKit waits inside `terminate:`, under winit's
//!   run, so with a terminate pending the run never returns, and once
//!   answered `YES` AppKit ends the process (`exit(0)`) there. So on such a
//!   close the drawer is told the window is closing, and the window goes,
//!   before the reply. Whatever the program must do before it ends, it
//!   does before it asks for the close: the window port's rule
//!   (`Platform::close`), which this adapter is why the port states.
//!
//! # Tests
//!
//! The gate (`mise run ci`) opens no window, so what it covers here is the
//! translation from winit's values to [`Input`] and [`Canvas`], what the
//! window asks of its input method (`ime_request`), that a close is asked
//! and a request sent before the loop is woken, what a wake-up comes to
//! (`wake`, over `Closing::ends_on_wake`), what each request does to the
//! window (`asked`, which runs the port's request contract), the files to
//! open (`files`: the translation of paths and the holding of them until
//! the window opened; and `Handing::hand`, which sends before it wakes),
//! the system's quit (`terminate`'s rules, `Handing::terminate`, which
//! sends before it wakes, and `wake`, which still counts the asks on a
//! close, so that the close answers them, and says whether a keep running
//! came with it), the menu bar (`menu`'s plan and its reading back, over
//! the model of what AppKit holds; `Handing::choose`, which sends before it
//! wakes; `wake`, which drops the choices on a close; and `asked`'s run of
//! the request contract with the menu bar routed as the handler routes
//! it), and the refusal off the main thread. The event
//! loop itself needs a display, and so do the lines here that only a real
//! window runs. They are few, and each is a reading of the window or a
//! call with no decision in it:
//!
//! - the handler's two arms that take apart a key and a change of scale. A
//!   change of scale cannot be built outside winit. winit 0.31's key event
//!   can be, and is still taken apart here, so that the key's translation
//!   keeps its parts (`KeyParts`);
//! - creating the window with the attributes `title_bar::attributes`
//!   gives, which are tested;
//! - the readings of the window as it opens: its size and scale, its raw
//!   handles (`native_window`), and its display's refresh rate
//!   (`refresh_rate`, which reads `current_monitor`, its
//!   `current_video_mode` and that mode's `refresh_rate_millihertz`);
//! - sending the window's request to its input method as it opens;
//! - that same reading of the refresh rate when the translation asks for
//!   it, after a move, a resize or a change of scale. Which events ask,
//!   and what is told of the answer, are the translation's, and tested;
//! - handing what an event comes to on: each `Canvas` to the drawer, then
//!   the `Input` to the report;
//! - ending the loop when it is woken and `wake` says it ends, and taking
//!   the requests and the files to open off their channels then. What a
//!   wake-up comes to is `wake`'s, and tested;
//! - reporting the files to open that `files` gives, when the loop is woken
//!   and when the window opens. What it gives is `files`'s, and tested;
//! - the five lines of `Control` for winit's window, which carry out a
//!   request: reading `fullscreen().is_some()`, and calling
//!   `set_fullscreen` with `Fullscreen::Borderless(None)` or `None`,
//!   `set_minimized(true)`, `set_title` and `set_theme`. Which is called,
//!   and when, is `asked`'s, and tested;
//! - the reading of the window's shape (`shape`) as the window opens and
//!   when the translation asks for it, after a resize, a change of scale, a
//!   move or an occlusion, and after requests are carried out: whether it
//!   is in fullscreen, on macOS the system's reading of its corners
//!   (`corner_reading`, over the view of `native_window`, and
//!   `corner::system`, one call into AppKit), and the reading of its title
//!   bar (`title_reading`, the top of winit's `safe_area` over the scale
//!   factor). When it is read and what is reported of it are the
//!   translation's, and what the readings come to is `corner::clearance`'s
//!   and `title_bar::top_inset`'s, and all are tested. `mise run
//!   window-contract` runs the readings and prints the clearance and the
//!   top inset each resize said;
//! - telling the drawer the window is closing once the loop has ended;
//! - on macOS, the application delegate's one method, which reads each
//!   URL's file path and hands the list to `Handing::hand`, and
//!   `delegate::install`, which registers `NSTreatUnknownArgumentsAsOpen`,
//!   makes the delegate and gives it to the application. No test can make
//!   AppKit send an open-documents event; Finder and the Dock are tried by
//!   hand (the roadmap `macos-app`, phase 6). Installing it in `run` is
//!   reached by any run on macOS, so `mise run window-contract` runs it;
//! - on macOS, the delegate's `applicationShouldTerminate:`, which hands
//!   the ask to `Handing::terminate` and answers `NSTerminateLater`, and
//!   `delegate::reply`, which makes the reply `terminate` gave; the loop's
//!   forwarding of each ask, each keep running, a close and a window that
//!   could not be opened to `terminate`, and of its reply to the delegate;
//!   and, on a close with a reply, telling the drawer the window is closing
//!   before it. What comes of them is `terminate`'s, and tested. The
//!   contract example asks them of a running window, sees a close with a
//!   keep running before it cancel a terminate pending and return, and
//!   sees a close with a terminate pending end the process by AppKit's
//!   terminate;
//! - on macOS, the menu bar's build (`MenuBar::show`, item for item from
//!   the plan) and its reading (`probe::read_menu_bar`), the target's one
//!   method, which hands `menu::chosen`'s name to `Handing::choose`, the
//!   loop's reporting of each choice, and `delegate::install`'s
//!   `NSFullScreenMenuItemEverywhere`. What is built and read is `menu`'s,
//!   and tested. The contract example asks a running window for a menu
//!   bar, reads it back from AppKit, performs each command item and the
//!   Quit item, and sees what each reports. It reads back once, after the
//!   loop has carried out every request sent to it
//!   (`probe::await_requests_handled`: a count of the requests sent and of
//!   those the loop carried out, `handled`, notified as the loop counts),
//!   never by a poll.
//!
//! They are held to the port's contract by `examples/contract/main.rs`, which
//! two opt-in tasks run: `mise run linux-window`, under Xvfb in a
//! container, and `mise run window-contract`, on the desktop it is started
//! from. Run the first after a change to this crate. Under Xvfb the
//! display says no refresh rate, so the reading is run there and what a
//! real display answers is not seen.
//!
//! The handler's two arms are run on winit's own events by `mise run
//! linux-window` too, in the window that draws (`editor-ffi`'s example
//! `window`): the key's by keys xdotool types, and the change of scale's
//! by a change of the display's settings while the window is open, which
//! the task requires to come off the queue as a resize at the size last
//! known and the new scale (`docs/dev-practices/on-demand-checks.md`, "The
//! window on Linux, on demand"). That is winit's X11 back end. What its
//! macOS back end sends when a window is moved between two displays has
//! not been seen.

mod asked;
mod background;
mod corner;
#[cfg(target_os = "macos")]
mod delegate;
mod files;
mod handled;
#[cfg(any(target_os = "macos", test))]
mod menu;
#[cfg(target_os = "macos")]
mod menu_bar;
mod names;
mod native;
mod terminate;
mod title_bar;
mod translate;

use std::num::NonZeroU32;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, mpsc};

use editor_platform::{
    CannotOpen, Canvas, Drawer, Input, NativeWindow, Platform, Report, Request, TitleBar,
    WindowOptions,
};
use winit::application::ApplicationHandler;
use winit::dpi::{LogicalPosition, LogicalSize};
use winit::event::WindowEvent;
use winit::event_loop::run_on_demand::EventLoopExtRunOnDemand;
use winit::event_loop::{ActiveEventLoop, EventLoop, EventLoopProxy};
use winit::raw_window_handle::{HasDisplayHandle, HasWindowHandle};
use winit::window::{
    ImeCapabilities, ImeEnableRequest, ImeHint, ImePurpose, ImeRequest, ImeRequestData, Window,
    WindowId,
};

use crate::asked::{Asked, Control};
use crate::corner::Shape;
use crate::files::Arrivals;
#[cfg(any(target_os = "macos", test))]
use crate::files::Handing;
use crate::handled::Handled;
use crate::terminate::{Reply, Terminate};
use crate::translate::{KeyParts, Seen, Told};

/// Readings of what the adapter did, for `examples/contract` alone: no
/// other crate calls them, and they name no objc2 type. On macOS, a reading
/// of the menu bar the adapter built; everywhere, a wait for the running
/// loop to have carried out every request sent to it.
#[doc(hidden)]
pub mod probe {
    #[cfg(target_os = "macos")]
    pub use crate::menu_bar::{Reading, read_menu_bar};

    /// Waits until the loop of `platform`'s running window has carried out
    /// every request sent to it, on the main thread, and says whether it
    /// had: false once `guard` has run out first, and at once when no window
    /// runs. A reading of the window or the menu bar made after it sees
    /// what the requests did. It is notified as the loop carries them out,
    /// never a poll.
    ///
    /// `guard` names the loop's count of what it carried out: only a loop
    /// that never carries a request out reaches it.
    #[expect(
        clippy::disallowed_methods,
        reason = "the readout forwards to the run's own count, `Handled::wait_all`"
    )]
    pub fn await_requests_handled(
        platform: &crate::WinitPlatform,
        guard: editor_wait::HangGuard,
    ) -> bool {
        let handled = platform
            .running()
            .as_ref()
            .map(|running| std::sync::Arc::clone(&running.handled));
        handled.is_some_and(|handled| handled.wait_all(guard))
    }
}

/// The window port over winit. It opens one window, on the process's main
/// thread, once in a process.
pub struct WinitPlatform {
    /// Whether the calling thread is the process's main thread.
    on_main_thread: fn() -> bool,
    /// The way to end the running window's loop, while one runs.
    running: Mutex<Option<Running>>,
}

/// The way to a running window's loop: ask it to close, or send it a
/// request, then wake it to see that.
struct Running {
    /// What wakes the loop.
    proxy: EventLoopProxy,
    /// Whether a close has been asked, which the loop reads when woken.
    closing: Closing,
    /// Where requests go, which the loop takes when woken.
    requests: mpsc::Sender<Request>,
    /// How many requests have been sent and carried out
    /// (`probe::await_requests_handled`).
    handled: Arc<Handled>,
}

impl WinitPlatform {
    /// The name this platform gives itself in [`Input::Opened`].
    pub const NAME: &'static str = "winit";

    /// The title the window opens with, until it is asked for another
    /// (`Request::Title`). The editor asks for its scene's title as soon as
    /// the window opens; the keyboard check (`editor window-check`) asks
    /// for none.
    const TITLE: &'static str = "editor: window check";

    /// A platform that runs no window yet. `on_main_thread` says whether the
    /// thread that calls it is the process's main thread;
    /// [`run`](Platform::run) asks it before it opens anything.
    pub const fn new(on_main_thread: fn() -> bool) -> Self {
        Self {
            on_main_thread,
            running: Mutex::new(None),
        }
    }

    /// Locks the way to the running loop. The lock is never held while the
    /// loop runs, so a poisoned lock still guards a consistent value.
    fn running(&self) -> MutexGuard<'_, Option<Running>> {
        self.running.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl Platform for WinitPlatform {
    fn run(
        &self,
        options: WindowOptions,
        report: Report,
        drawer: Drawer,
    ) -> Result<(), CannotOpen> {
        let cannot_open = |reason: String| CannotOpen { reason };
        if !(self.on_main_thread)() {
            return Err(cannot_open(
                "a window can only be run on the process's main thread".into(),
            ));
        }

        let mut event_loop = event_loop().map_err(cannot_open)?;
        let closing = Closing::default();
        let (requests, asked) = mpsc::channel();
        // Where the files the system asks the app to open are handed: by the
        // application delegate on macOS, installed now, after the event
        // loop is built and before it runs, since a cold start's files
        // arrive as the loop starts. Elsewhere nothing hands them, and the
        // channel stays empty.
        let (handing, files) = mpsc::channel();
        // The system's asks to terminate, handed the same way.
        let (terminating, terminations) = mpsc::channel();
        // The command items chosen in the menu bar, handed by its target,
        // which is made beside the delegate.
        let (choosing, choices) = mpsc::channel();
        #[cfg(target_os = "macos")]
        let handing = Handing {
            files: handing,
            terminations: terminating,
            menus: choosing,
            proxy: event_loop.create_proxy(),
        };
        #[cfg(target_os = "macos")]
        let menu_bar = menu_bar::MenuBar::install(handing.clone());
        #[cfg(target_os = "macos")]
        let installed = delegate::install(handing);
        #[cfg(not(target_os = "macos"))]
        drop((handing, terminating, choosing));
        let handled = Arc::new(Handled::default());
        *self.running() = Some(Running {
            proxy: event_loop.create_proxy(),
            closing: closing.clone(),
            requests,
            handled: Arc::clone(&handled),
        });
        let mut app = App {
            options,
            report,
            drawer,
            seen: Seen::default(),
            window: None,
            failure: None,
            closing,
            requests: asked,
            handled,
            asked: Asked::default(),
            files,
            arrivals: Arrivals::default(),
            terminations,
            terminate: Terminate::default(),
            choices,
            #[cfg(target_os = "macos")]
            menu_bar,
        };
        // What winit's `run_app` does on macOS and on Linux, with the
        // handler borrowed so that it is still here once the loop has ended.
        let ended = event_loop.run_app_on_demand(&mut app);
        *self.running() = None;
        if app.window.is_some() {
            // The loop has ended and the window is still there. Whatever was
            // made on it is let go first.
            (app.drawer)(Canvas::Closing);
        }
        let failure = app.failure.take();
        // The window goes before its loop, as in winit's `run_app`, and the
        // menu bar (in `app`) and then the application's delegate with it.
        drop(app);
        #[cfg(target_os = "macos")]
        drop(installed);
        drop(event_loop);

        match (failure, ended) {
            (Some(reason), _) => Err(cannot_open(reason)),
            (None, Err(error)) => Err(cannot_open(error.to_string())),
            (None, Ok(())) => Ok(()),
        }
    }

    fn close(&self) {
        if let Some(running) = self.running().as_ref() {
            // Asked first, so that the loop it wakes sees it. A loop that
            // has already ended is woken for nothing.
            running.closing.ask();
            running.proxy.wake_up();
        }
    }

    fn request(&self, request: Request) {
        if let Some(running) = self.running().as_ref() {
            // Sent first, as a close is asked first, so that the loop it
            // wakes finds it. A loop that has ended has dropped its end of
            // the channel, and the request goes nowhere. It is counted as
            // sent before it is, so the loop never counts more carried out.
            running.handled.sent();
            let _ = running.requests.send(request);
            running.proxy.wake_up();
        }
    }
}

/// Whether a close has been asked of the running window, shared between
/// [`WinitPlatform::close`] and the loop it wakes.
#[derive(Debug, Clone, Default)]
struct Closing(Arc<AtomicBool>);

impl Closing {
    /// Asks the loop to end when it is next woken.
    fn ask(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    /// Whether a close has been asked.
    fn asked(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }

    /// Whether a loop woken now ends. winit may wake the loop when nobody
    /// did, and merges wake-ups, so a wake-up ends it only once a close has
    /// been asked.
    fn ends_on_wake(&self) -> bool {
        self.asked()
    }
}

/// What a wake-up of the loop comes to: the requests to carry out, in the
/// order asked, the lists of files to open, in the order handed, how many
/// times the system asked to terminate, the command items chosen, and
/// whether the loop ends.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Woken {
    /// The requests to carry out, oldest first.
    carry: Vec<Request>,
    /// The lists of files to open, oldest first.
    files: Vec<Vec<PathBuf>>,
    /// How many asks to terminate arrived.
    terminations: usize,
    /// The names of the command items chosen, oldest first.
    chosen: Vec<String>,
    /// Whether a keep running came with the close, when the loop ends:
    /// the close then cancels the system's quit (`Terminate::close`).
    /// A loop that goes on carries keep running with the other requests.
    kept: bool,
    /// Whether the loop ends.
    ends: bool,
}

/// What a wake-up of the loop comes to, with `closing` as it is and
/// `requests`, `files`, `terminations` and `choices` taken off their
/// channels. A loop that ends drops the requests, the files to open and the
/// menu choices: the window is going.
/// It still counts the asks to terminate, since each is a `terminate:`
/// AppKit waits in until it is answered, and the close answers it
/// (`Terminate::close`), and it says whether a keep running was among the
/// requests, which the close's answer turns on: a keep running asked
/// before the close is found with it whenever the loop did not wake in
/// between. One that does not end takes every request, every list of
/// files, every ask and every choice, in order; with none it still goes
/// on, since winit may wake a loop nobody woke.
fn wake(
    closing: &Closing,
    mut requests: impl Iterator<Item = Request>,
    files: impl Iterator<Item = Vec<PathBuf>>,
    terminations: impl Iterator<Item = ()>,
    choices: impl Iterator<Item = String>,
) -> Woken {
    let ends = closing.ends_on_wake();
    if ends {
        let kept = requests.any(|request| request == Request::KeepRunning);
        return Woken {
            carry: Vec::new(),
            files: Vec::new(),
            terminations: terminations.count(),
            chosen: Vec::new(),
            kept,
            ends,
        };
    }
    Woken {
        carry: requests.collect(),
        files: files.collect(),
        terminations: terminations.count(),
        chosen: choices.collect(),
        kept: false,
        ends,
    }
}

/// Makes `reply` to the system: on macOS through the application delegate,
/// elsewhere nowhere, since nothing there asks.
fn answer(reply: Reply) {
    #[cfg(target_os = "macos")]
    delegate::reply(reply);
    #[cfg(not(target_os = "macos"))]
    let _ = reply;
}

/// The window and its loop's handler: what [`WinitPlatform::run`] hands to
/// winit.
struct App {
    /// How the window is opened.
    options: WindowOptions,
    /// Where what the window reports goes.
    report: Report,
    /// Where what the window tells whatever draws in it goes.
    drawer: Drawer,
    /// What winit has said of the window so far.
    seen: Seen,
    /// The window, once the loop has made it.
    window: Option<Box<dyn Window>>,
    /// Why the window could not be made, if it could not.
    failure: Option<String>,
    /// Whether a close has been asked of the window.
    closing: Closing,
    /// The requests sent to the window, taken when the loop is woken.
    requests: mpsc::Receiver<Request>,
    /// Where the loop counts the requests it has carried out.
    handled: Arc<Handled>,
    /// What the translation of requests remembers of the window.
    asked: Asked,
    /// The lists of files the system asks the app to open, taken when the
    /// loop is woken and when the window opens.
    files: mpsc::Receiver<Vec<PathBuf>>,
    /// The files to open that arrived, held until the window has opened.
    arrivals: Arrivals,
    /// The system's asks to terminate, taken when the loop is woken and
    /// when the window opens.
    terminations: mpsc::Receiver<()>,
    /// What is known of those asks, and of the answers to them.
    terminate: Terminate,
    /// The names of the command items chosen in the menu bar, taken when
    /// the loop is woken.
    choices: mpsc::Receiver<String>,
    /// The menu bar, which keeps its items' target alive for the run
    /// (macOS); `None` off the main thread.
    #[cfg(target_os = "macos")]
    menu_bar: Option<menu_bar::MenuBar>,
}

impl App {
    /// Shows `menu` as the application's menu bar, built from its plan, on
    /// macOS; elsewhere it is dropped, since winit builds no menu bar
    /// there and the request contract lets a platform with none show none.
    fn show(&self, menu: &editor_platform::Menu) {
        #[cfg(target_os = "macos")]
        if let Some(menu_bar) = &self.menu_bar {
            menu_bar.show(&menu::plan(menu));
        }
        #[cfg(not(target_os = "macos"))]
        let _ = menu;
    }

    /// Carries out a wake-up of the loop with `requests` taken off their
    /// channel, and the files, asks to terminate and choices still on
    /// theirs ([`wake`]).
    fn woken(&mut self, event_loop: &dyn ActiveEventLoop, requests: Vec<Request>) {
        let woken = wake(
            &self.closing,
            requests.into_iter(),
            self.files.try_iter(),
            self.terminations.try_iter(),
            self.choices.try_iter(),
        );
        if woken.ends {
            // What a close says to an ask still pending, held or waiting is
            // `terminate`'s to decide, with whether a keep running came with
            // it. A reply that goes ahead lets AppKit end the process inside
            // the run, which then never returns, so what follows the loop's
            // end is done first: the drawer is told the window is closing,
            // while the window is still there, and then it goes.
            if let Some(reply) = self.terminate.close(woken.terminations, woken.kept) {
                if let Some(window) = self.window.take() {
                    (self.drawer)(Canvas::Closing);
                    drop(window);
                }
                answer(reply);
            }
            event_loop.exit();
            return;
        }
        // Files need no window: they are held until it has opened.
        for paths in woken.files {
            if let Some(input) = self.arrivals.arrive(paths) {
                (self.report)(input);
            }
        }
        // Nor do the asks to terminate: they are held as files are.
        for _ in 0..woken.terminations {
            if let Some(input) = self.terminate.ask() {
                (self.report)(input);
            }
        }
        // A command item can only be chosen from a menu bar the editor
        // asked for, which is built only once the window has opened.
        for name in woken.chosen {
            (self.report)(Input::Menu(name));
        }
        // Keeping running answers the system, and is no request of the
        // window's; every other request is the window's.
        let (keep_running, carry): (Vec<_>, Vec<_>) = woken
            .carry
            .into_iter()
            .partition(|request| *request == Request::KeepRunning);
        for _ in keep_running {
            if let Some(reply) = self.terminate.keep_running() {
                answer(reply);
            }
        }
        // A request asked before the window was made is dropped.
        let Some(window) = self.window.as_deref() else {
            return;
        };
        for request in carry {
            match request {
                // The menu bar is the application's, not the window's: it
                // is built only once `Opened` has been reported.
                Request::Menu(menu) => self.show(&menu),
                request => asked::carry_out(&mut self.asked, window, request),
            }
        }
        // What carrying them out did to fullscreen and the corners, as the
        // drawer and the report hear of a window event's.
        let told = self.seen.reread(shape(window, self.options.title_bar));
        for canvas in told.canvas {
            (self.drawer)(canvas);
        }
        if let Some(input) = told.input {
            (self.report)(input);
        }
    }
}

impl ApplicationHandler for App {
    /// Opens the window. winit calls this once its loop has started, on
    /// every platform, and may call it again; a window already made, or
    /// one that could not be, is not made again.
    fn can_create_surfaces(&mut self, event_loop: &dyn ActiveEventLoop) {
        if self.window.is_some() || self.failure.is_some() {
            return;
        }
        match event_loop.create_window(title_bar::attributes(self.options)) {
            Ok(window) => {
                // What it comes to is seen in the events the window sends,
                // as with the call this replaces, which returned nothing.
                let _ = window.request_ime_update(ime_request(self.options.composition));
                window.focus_window();
                let (opened, size) = self.seen.opened(
                    window.surface_size(),
                    window.scale_factor(),
                    native_window(window.as_ref()),
                    refresh_rate(window.as_ref()),
                    shape(window.as_ref(), self.options.title_bar),
                );
                self.window = Some(window);
                // The drawer hears of the window before anyone else does.
                (self.drawer)(opened);
                (self.report)(Input::Opened {
                    platform: WinitPlatform::NAME.into(),
                });
                (self.report)(size);
                // The files that arrived before the window, and those still
                // waiting on the channel, after them.
                for input in self.arrivals.open(self.files.try_iter()) {
                    (self.report)(input);
                }
                // An ask to terminate that came before the window, or is
                // still waiting, after the files.
                if let Some(input) = self.terminate.open(self.terminations.try_iter().count()) {
                    (self.report)(input);
                }
            }
            Err(error) => {
                self.failure = Some(error.to_string());
                // An ask held, or waiting, keeps AppKit waiting inside
                // `terminate:`, and the run could not return with the
                // failure: what it is answered is `terminate`'s.
                if let Some(reply) = self.terminate.fail(self.terminations.try_iter().count()) {
                    answer(reply);
                }
                event_loop.exit();
            }
        }
    }

    fn proxy_wake_up(&mut self, event_loop: &dyn ActiveEventLoop) {
        // Each request taken now is counted once the wake-up has carried
        // it out, or dropped it, so the count says it is done.
        let requests: Vec<Request> = self.requests.try_iter().collect();
        let taken = requests.len();
        self.woken(event_loop, requests);
        self.handled.handled(taken);
    }

    fn window_event(&mut self, _: &dyn ActiveEventLoop, _: WindowId, event: WindowEvent) {
        // How often the window's display refreshes, read when the
        // translation asks: it decides after which events to.
        let window = self.window.as_deref();
        let display = || window.and_then(refresh_rate);
        // Whether it is in fullscreen, and how its corners and its title
        // bar read, when the translation asks.
        let title_bar = self.options.title_bar;
        let shape = || window.map_or(Shape::default(), |window| shape(window, title_bar));
        // A change of scale cannot be built in a test, and a key is
        // translated from its parts, so each is taken apart here. These two
        // arms are all this handler decides.
        let told = match &event {
            WindowEvent::KeyboardInput { event, .. } => Told {
                input: Some(self.seen.key(&KeyParts {
                    state: event.state,
                    repeat: event.repeat,
                    logical: &event.logical_key,
                    physical: event.physical_key,
                    text: event.text.as_deref(),
                })),
                canvas: Vec::new(),
            },
            WindowEvent::ScaleFactorChanged { scale_factor, .. } => {
                self.seen.scale(*scale_factor, &display, &shape)
            }
            other => self.seen.window_event(other, &display, &shape),
        };
        // The drawer first, as when the window opened: a size is known to
        // what draws before anyone is told to lay out for it.
        for canvas in told.canvas {
            (self.drawer)(canvas);
        }
        if let Some(input) = told.input {
            (self.report)(input);
        }
    }
}

/// The window as the system knows it, in the port's terms: `None` when
/// winit does not give its handles, or gives handles the port has no
/// variant for.
fn native_window(window: &dyn Window) -> Option<NativeWindow> {
    let handle = window.window_handle().ok()?.as_raw();
    let display = window.display_handle().ok()?.as_raw();
    native::native(handle, display)
}

/// What `window`, opened with `title_bar`, reads as, for its fullscreen
/// state, its corner clearance and its top inset: whether it is in
/// fullscreen, on macOS the system's reading of its corners over its
/// AppKit view, and the system's reading of how far down its title bar
/// covers it. Each is a reading with no decision in it; what they come to
/// is the modules `corner`'s and `title_bar`'s.
fn shape(window: &dyn Window, title_bar: TitleBar) -> Shape {
    Shape {
        fullscreen: window.in_fullscreen(),
        corner: corner_reading(window),
        top: title_reading(window),
        title_bar,
    }
}

/// The system's reading of how far down `window`'s title bar covers its
/// drawable area, in logical points: the top of winit's safe area, which
/// is in physical pixels, over the scale factor. winit reads 0 off macOS.
fn title_reading(window: &dyn Window) -> Option<f64> {
    Some(f64::from(window.safe_area().top) / window.scale_factor())
}

/// The system's reading of how far in `window`'s corners reach, in logical
/// points: on macOS, over the AppKit view its raw handle gives; nothing
/// elsewhere, or for a window with no such view.
fn corner_reading(window: &dyn Window) -> Option<f64> {
    #[cfg(target_os = "macos")]
    if let Some(NativeWindow::AppKit { view }) = native_window(window) {
        return corner::system(view);
    }
    #[cfg(not(target_os = "macos"))]
    let _ = window;
    None
}

/// How often the display the window is on refreshes, in thousandths of a
/// hertz, when winit says.
fn refresh_rate(window: &dyn Window) -> Option<u32> {
    window
        .current_monitor()?
        .current_video_mode()?
        .refresh_rate_millihertz()
        .map(NonZeroU32::get)
}

/// What the window asks of its input method: with `composition`, what
/// winit's deprecated `set_ime_allowed(true)` asks, which is a hint and a
/// purpose and a cursor area at the window's origin, without which the
/// candidate window has nowhere to be; without it, that it be disabled. It
/// never asks to read the text around the cursor, which the port has no
/// way to give.
fn ime_request(composition: bool) -> ImeRequest {
    if !composition {
        return ImeRequest::Disable;
    }
    let capabilities = ImeCapabilities::new()
        .with_hint_and_purpose()
        .with_cursor_area();
    let data = ImeRequestData::default()
        .with_hint_and_purpose(ImeHint::NONE, ImePurpose::Normal)
        .with_cursor_area(
            LogicalPosition::new(0, 0).into(),
            LogicalSize::new(0, 0).into(),
        );
    // winit refuses data for a capability not asked for, and there is none.
    ImeEnableRequest::new(capabilities, data).map_or(ImeRequest::Disable, ImeRequest::Enable)
}

/// Builds the event loop, without winit's default menu where it has one:
/// the menu bar is the editor's ([`Request::Menu`]).
fn event_loop() -> Result<EventLoop, String> {
    let mut builder = EventLoop::builder();
    #[cfg(target_os = "macos")]
    {
        use winit::platform::macos::EventLoopBuilderExtMacOS;
        builder.with_default_menu(false);
    }
    builder.build().map_err(|error| error.to_string())
}

#[cfg(test)]
#[expect(
    clippy::disallowed_methods,
    reason = "the adapter's own tests: `probe::await_requests_handled` is their subject"
)]
mod tests {
    use super::*;
    use editor_wait::HangGuard;
    use std::sync::atomic::AtomicUsize;
    use std::time::Duration;
    use winit::event_loop::EventLoopProxyProvider;

    #[test]
    fn off_the_main_thread_a_run_is_refused_with_a_reason_and_reports_and_tells_nothing() {
        // The platform is told this thread is not the main one, which is
        // true of a test's thread, so nothing is opened whatever it does.
        let platform = WinitPlatform::new(|| false);
        let reported = Arc::new(AtomicUsize::new(0));
        let report: Report = {
            let reported = Arc::clone(&reported);
            Arc::new(move |_| {
                reported.fetch_add(1, Ordering::SeqCst);
            })
        };
        let told = Arc::new(AtomicUsize::new(0));
        let drawer: Drawer = {
            let told = Arc::clone(&told);
            Arc::new(move |_| {
                told.fetch_add(1, Ordering::SeqCst);
            })
        };

        let result = platform.run(WindowOptions::default(), report, drawer);

        let reason = result.expect_err("the run is refused").reason;
        assert!(
            reason.contains("main thread"),
            "the reason says why: {reason}"
        );
        assert_eq!(reported.load(Ordering::SeqCst), 0);
        assert_eq!(told.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn a_close_with_no_window_running_does_nothing() {
        WinitPlatform::new(|| false).close();
    }

    /// A loop's waker that records each wake-up, and whether a close had
    /// been asked of `closing` by then.
    #[derive(Debug)]
    struct RecordingWaker {
        closing: Closing,
        woken: Mutex<Vec<bool>>,
    }

    impl EventLoopProxyProvider for RecordingWaker {
        fn wake_up(&self) {
            self.woken.lock().unwrap().push(self.closing.asked());
        }
    }

    #[test]
    fn a_close_while_a_window_runs_asks_its_loop_to_end_and_then_wakes_it() {
        let platform = WinitPlatform::new(|| false);
        let closing = Closing::default();
        let waker = Arc::new(RecordingWaker {
            closing: closing.clone(),
            woken: Mutex::new(Vec::new()),
        });
        *platform.running() = Some(Running {
            proxy: EventLoopProxy::new(waker.clone()),
            closing,
            requests: mpsc::channel().0,
            handled: Arc::default(),
        });

        platform.close();

        // Woken once, with the close already asked: the loop that wakes
        // sees it.
        assert_eq!(*waker.woken.lock().unwrap(), [true]);
    }

    /// A loop's waker that takes, at each wake-up, the requests already on
    /// the channel by then.
    #[derive(Debug)]
    struct RequestWaker {
        requests: Mutex<mpsc::Receiver<Request>>,
        woken: Mutex<Vec<Vec<Request>>>,
    }

    impl EventLoopProxyProvider for RequestWaker {
        fn wake_up(&self) {
            let found = self.requests.lock().unwrap().try_iter().collect();
            self.woken.lock().unwrap().push(found);
        }
    }

    #[test]
    fn a_request_while_a_window_runs_is_sent_before_its_loop_is_woken() {
        let platform = WinitPlatform::new(|| false);
        let (requests, asked) = mpsc::channel();
        let waker = Arc::new(RequestWaker {
            requests: Mutex::new(asked),
            woken: Mutex::new(Vec::new()),
        });
        let closing = Closing::default();
        let handled = Arc::new(Handled::default());
        *platform.running() = Some(Running {
            proxy: EventLoopProxy::new(waker.clone()),
            closing: closing.clone(),
            requests,
            handled: Arc::clone(&handled),
        });

        platform.request(Request::EnterFullscreen);
        platform.request(Request::Title("notes.txt".into()));

        // Each is counted as sent, so a wait for them runs out until the
        // loop has counted both carried out.
        let not_yet = HangGuard::held("the requests not yet carried out", Duration::ZERO);
        assert!(!probe::await_requests_handled(&platform, not_yet));
        handled.handled(1);
        assert!(!probe::await_requests_handled(&platform, not_yet));
        handled.handled(1);
        assert!(probe::await_requests_handled(&platform, not_yet));

        // Woken once for each, with it already on the channel: the loop
        // that wakes finds it. A request asks no close.
        assert_eq!(
            *waker.woken.lock().unwrap(),
            [
                vec![Request::EnterFullscreen],
                vec![Request::Title("notes.txt".into())]
            ]
        );
        assert!(!closing.asked());
    }

    #[test]
    fn a_request_with_no_window_running_does_nothing() {
        WinitPlatform::new(|| false).request(Request::Minimise);
    }

    #[test]
    fn with_no_window_running_a_wait_for_requests_carried_out_says_no_at_once() {
        let platform = WinitPlatform::new(|| false);
        platform.request(Request::Minimise);
        let no_bound = HangGuard::on("the requests carried out", Duration::MAX);
        assert!(!probe::await_requests_handled(&platform, no_bound));
    }

    /// A loop's waker that takes, at each wake-up, the lists of paths
    /// already on the channel by then.
    #[derive(Debug)]
    struct FilesWaker {
        files: Mutex<mpsc::Receiver<Vec<PathBuf>>>,
        woken: Mutex<Vec<Vec<Vec<PathBuf>>>>,
    }

    impl EventLoopProxyProvider for FilesWaker {
        fn wake_up(&self) {
            let found = self.files.lock().unwrap().try_iter().collect();
            self.woken.lock().unwrap().push(found);
        }
    }

    #[test]
    fn paths_handed_by_the_delegate_are_sent_before_the_loop_is_woken() {
        let (files, taken) = mpsc::channel();
        let waker = Arc::new(FilesWaker {
            files: Mutex::new(taken),
            woken: Mutex::new(Vec::new()),
        });
        let handing = Handing {
            files,
            terminations: mpsc::channel().0,
            menus: mpsc::channel().0,
            proxy: EventLoopProxy::new(waker.clone()),
        };
        let first = vec![PathBuf::from("/tmp/a"), PathBuf::from("/tmp/b")];
        let second = vec![PathBuf::from("/tmp/c")];

        handing.hand(first.clone());
        handing.hand(second.clone());

        // Woken once for each, with it already on the channel: the loop
        // that wakes finds it.
        assert_eq!(*waker.woken.lock().unwrap(), [vec![first], vec![second]]);
    }

    #[test]
    fn a_wake_up_with_requests_and_no_close_carries_them_out_in_order_and_goes_on() {
        let asked = [
            Request::EnterFullscreen,
            Request::Title("notes.txt".into()),
            Request::Minimise,
        ];
        assert_eq!(
            wake(
                &Closing::default(),
                asked.clone().into_iter(),
                std::iter::empty(),
                std::iter::empty(),
                std::iter::empty()
            ),
            Woken {
                carry: asked.to_vec(),
                files: Vec::new(),
                terminations: 0,
                chosen: Vec::new(),
                kept: false,
                ends: false,
            }
        );
    }

    #[test]
    fn a_wake_up_with_files_and_no_close_takes_every_list_in_order() {
        let lists = vec![
            vec![PathBuf::from("/tmp/a"), PathBuf::from("/tmp/b")],
            vec![PathBuf::from("/tmp/c")],
        ];
        assert_eq!(
            wake(
                &Closing::default(),
                std::iter::empty(),
                lists.clone().into_iter(),
                std::iter::empty(),
                std::iter::empty()
            ),
            Woken {
                carry: Vec::new(),
                files: lists,
                terminations: 0,
                chosen: Vec::new(),
                kept: false,
                ends: false,
            }
        );
    }

    #[test]
    fn a_wake_up_with_a_close_asked_ends_and_carries_out_nothing() {
        let closing = Closing::default();
        closing.ask();
        assert_eq!(
            wake(
                &closing,
                [Request::EnterFullscreen].into_iter(),
                std::iter::empty(),
                std::iter::empty(),
                std::iter::empty()
            ),
            Woken {
                carry: Vec::new(),
                files: Vec::new(),
                terminations: 0,
                chosen: Vec::new(),
                kept: false,
                ends: true,
            }
        );
    }

    #[test]
    fn a_wake_up_with_a_close_asked_drops_the_files_too() {
        let closing = Closing::default();
        closing.ask();
        assert_eq!(
            wake(
                &closing,
                std::iter::empty(),
                [vec![PathBuf::from("/tmp/a")]].into_iter(),
                std::iter::empty(),
                std::iter::empty()
            ),
            Woken {
                carry: Vec::new(),
                files: Vec::new(),
                terminations: 0,
                chosen: Vec::new(),
                kept: false,
                ends: true,
            }
        );
    }

    #[test]
    fn a_wake_up_with_terminations_and_no_close_takes_them_all() {
        assert_eq!(
            wake(
                &Closing::default(),
                std::iter::empty(),
                std::iter::empty(),
                [(), ()].into_iter(),
                std::iter::empty()
            ),
            Woken {
                carry: Vec::new(),
                files: Vec::new(),
                terminations: 2,
                chosen: Vec::new(),
                kept: false,
                ends: false,
            }
        );
    }

    #[test]
    fn a_wake_up_with_a_close_asked_still_takes_the_terminations_so_they_are_answered() {
        let closing = Closing::default();
        closing.ask();
        assert_eq!(
            wake(
                &closing,
                [Request::Minimise].into_iter(),
                [vec![PathBuf::from("/tmp/a")]].into_iter(),
                [(), ()].into_iter(),
                std::iter::empty()
            ),
            Woken {
                carry: Vec::new(),
                files: Vec::new(),
                terminations: 2,
                chosen: Vec::new(),
                kept: false,
                ends: true,
            }
        );
    }

    #[test]
    fn a_wake_up_with_a_close_asked_says_whether_keep_running_came_with_it_and_drops_the_rest() {
        let closing = Closing::default();
        closing.ask();
        assert_eq!(
            wake(
                &closing,
                [
                    Request::Minimise,
                    Request::KeepRunning,
                    Request::Title("notes.txt".into())
                ]
                .into_iter(),
                std::iter::empty(),
                [()].into_iter(),
                std::iter::empty()
            ),
            Woken {
                carry: Vec::new(),
                files: Vec::new(),
                terminations: 1,
                chosen: Vec::new(),
                kept: true,
                ends: true,
            }
        );
    }

    #[test]
    fn a_wake_up_with_keep_running_and_no_close_carries_it_with_the_other_requests() {
        let asked = [Request::KeepRunning, Request::Minimise];
        assert_eq!(
            wake(
                &Closing::default(),
                asked.clone().into_iter(),
                std::iter::empty(),
                std::iter::empty(),
                std::iter::empty()
            ),
            Woken {
                carry: asked.to_vec(),
                files: Vec::new(),
                terminations: 0,
                chosen: Vec::new(),
                kept: false,
                ends: false,
            }
        );
    }

    /// A loop's waker that counts, at each wake-up, the terminations already
    /// on the channel by then.
    #[derive(Debug)]
    struct TerminationsWaker {
        terminations: Mutex<mpsc::Receiver<()>>,
        woken: Mutex<Vec<usize>>,
    }

    impl EventLoopProxyProvider for TerminationsWaker {
        fn wake_up(&self) {
            let found = self.terminations.lock().unwrap().try_iter().count();
            self.woken.lock().unwrap().push(found);
        }
    }

    #[test]
    fn a_terminate_handed_by_the_delegate_is_sent_before_the_loop_is_woken() {
        let (terminations, taken) = mpsc::channel();
        let waker = Arc::new(TerminationsWaker {
            terminations: Mutex::new(taken),
            woken: Mutex::new(Vec::new()),
        });
        let handing = Handing {
            files: mpsc::channel().0,
            terminations,
            menus: mpsc::channel().0,
            proxy: EventLoopProxy::new(waker.clone()),
        };

        handing.terminate();
        handing.terminate();

        // Woken once for each, with it already on the channel: the loop
        // that wakes finds it.
        assert_eq!(*waker.woken.lock().unwrap(), [1, 1]);
    }

    /// A loop's waker that takes, at each wake-up, the menu choices
    /// already on the channel by then.
    #[derive(Debug)]
    struct ChoicesWaker {
        choices: Mutex<mpsc::Receiver<String>>,
        woken: Mutex<Vec<Vec<String>>>,
    }

    impl EventLoopProxyProvider for ChoicesWaker {
        fn wake_up(&self) {
            let found = self.choices.lock().unwrap().try_iter().collect();
            self.woken.lock().unwrap().push(found);
        }
    }

    #[test]
    fn a_choice_handed_by_the_target_is_sent_before_the_loop_is_woken() {
        let (menus, taken) = mpsc::channel();
        let waker = Arc::new(ChoicesWaker {
            choices: Mutex::new(taken),
            woken: Mutex::new(Vec::new()),
        });
        let handing = Handing {
            files: mpsc::channel().0,
            terminations: mpsc::channel().0,
            menus,
            proxy: EventLoopProxy::new(waker.clone()),
        };

        handing.choose("undo".into());
        handing.clone().choose("redo".into());

        // Woken once for each, with it already on the channel: the loop
        // that wakes finds it.
        assert_eq!(
            *waker.woken.lock().unwrap(),
            [vec!["undo".to_owned()], vec!["redo".to_owned()]]
        );
    }

    #[test]
    fn a_wake_up_with_choices_and_no_close_takes_them_in_order() {
        let chosen = vec!["undo".to_owned(), "redo".to_owned()];
        assert_eq!(
            wake(
                &Closing::default(),
                std::iter::empty(),
                std::iter::empty(),
                std::iter::empty(),
                chosen.clone().into_iter()
            ),
            Woken {
                carry: Vec::new(),
                files: Vec::new(),
                terminations: 0,
                chosen,
                kept: false,
                ends: false,
            }
        );
    }

    #[test]
    fn a_wake_up_with_a_close_asked_drops_the_choices() {
        let closing = Closing::default();
        closing.ask();
        assert_eq!(
            wake(
                &closing,
                std::iter::empty(),
                std::iter::empty(),
                std::iter::empty(),
                ["undo".to_owned()].into_iter()
            ),
            Woken {
                carry: Vec::new(),
                files: Vec::new(),
                terminations: 0,
                chosen: Vec::new(),
                kept: false,
                ends: true,
            }
        );
    }

    #[test]
    fn a_loop_woken_with_no_close_asked_goes_on() {
        // winit may wake a loop nobody woke.
        assert!(!Closing::default().ends_on_wake());
    }

    #[test]
    fn a_loop_woken_with_a_close_asked_through_any_clone_ends() {
        let closing = Closing::default();
        closing.clone().ask();
        assert!(closing.ends_on_wake());
    }

    #[test]
    fn with_composition_the_input_method_is_enabled_as_winit_enabled_it_and_without_it_is_disabled()
    {
        assert_eq!(ime_request(false), ImeRequest::Disable);
        // What winit's own `set_ime_allowed(true)` asks for: a hint and a
        // purpose, and a cursor area, without which the candidate window
        // has nowhere to be.
        let enable = ImeEnableRequest::new(
            ImeCapabilities::new()
                .with_hint_and_purpose()
                .with_cursor_area(),
            ImeRequestData::default()
                .with_hint_and_purpose(ImeHint::NONE, ImePurpose::Normal)
                .with_cursor_area(
                    LogicalPosition::new(0, 0).into(),
                    LogicalSize::new(0, 0).into(),
                ),
        )
        .expect("the data is the capabilities'");
        assert_eq!(ime_request(true), ImeRequest::Enable(enable));
    }
}
