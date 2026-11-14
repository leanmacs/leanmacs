//! The window port's real adapter: [`WinitPlatform`], a
//! [`Platform`] over winit.
//!
//! The port, its fake and its contract are `editor-platform`'s. This crate
//! is thin: it opens one window, translates what winit says of it into the
//! port's [`Input`] and [`Canvas`], and ends its loop when it is asked to
//! close. No winit type is public, and no other crate depends on winit
//! (`deny.toml`).
//!
//! The translation is the module `translate`'s, with a key's names in
//! `names` and the window's native handles in `native`: every key with its
//! logical key, physical key and modifiers; the pointer's press, drag,
//! release and wheel; a resize with the size and the scale; the focus; a
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
//! - **It allows an input method to compose exactly when the options say
//!   so.** With composition not allowed, a dead key arrives as a key.
//! - **It asks for the keyboard focus once**, when the window opens. The
//!   system may decline: macOS gives focus only to an application the user
//!   has brought forward.
//! - **It builds no default menu** on macOS, so Command-Q is a key that
//!   reaches the window and not a menu item that ends the process.
//! - **It runs once in a process.** winit makes one event loop a process, so
//!   a second run fails with winit's reason.
//!
//! # Tests
//!
//! The gate (`mise run ci`) opens no window, so what it covers here is the
//! translation from winit's values to [`Input`] and [`Canvas`] and the
//! refusal off the main thread. The event loop itself needs a display, and
//! so do the lines here that only a real window runs. They are few, and
//! each is a reading of the window or a call with no decision in it:
//!
//! - the handler's two arms that take apart the events no test can build,
//!   a key and a change of scale;
//! - the readings of the window as it opens: its size and scale, its raw
//!   handles (`native_window`), and its display's refresh rate
//!   (`refresh_rate`, which reads `current_monitor` and its
//!   `refresh_rate_millihertz`);
//! - that same reading of the refresh rate when the translation asks for
//!   it, after a move, a resize or a change of scale. Which events ask,
//!   and what is told of the answer, are the translation's, and tested;
//! - handing what an event comes to on: each `Canvas` to the drawer, then
//!   the `Input` to the report;
//! - telling the drawer the window is closing once the loop has ended.
//!
//! They are held to the port's contract by `examples/contract.rs`, which
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

mod names;
mod native;
mod translate;

use std::sync::{Mutex, MutexGuard, PoisonError};

use editor_platform::{
    CannotOpen, Canvas, Drawer, Input, NativeWindow, Platform, Report, WindowOptions,
};
use winit::application::ApplicationHandler;
use winit::event::WindowEvent;
use winit::event_loop::{ActiveEventLoop, EventLoop, EventLoopProxy};
use winit::raw_window_handle::{HasDisplayHandle, HasWindowHandle};
use winit::window::{Window, WindowId};

use crate::translate::{KeyParts, Seen, Told};

/// The window port over winit. It opens one window, on the process's main
/// thread, once in a process.
pub struct WinitPlatform {
    /// Whether the calling thread is the process's main thread.
    on_main_thread: fn() -> bool,
    /// The way to wake the running window's loop, while one runs.
    running: Mutex<Option<EventLoopProxy<()>>>,
}

impl WinitPlatform {
    /// The name this platform gives itself in [`Input::Opened`].
    pub const NAME: &'static str = "winit";

    /// The title of the window. The only window today is the keyboard
    /// check's (`editor window-check`).
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
    fn running(&self) -> MutexGuard<'_, Option<EventLoopProxy<()>>> {
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

        let event_loop = event_loop().map_err(cannot_open)?;
        *self.running() = Some(event_loop.create_proxy());
        let mut app = App {
            options,
            report,
            drawer,
            seen: Seen::default(),
            window: None,
            failure: None,
        };
        let ended = event_loop.run_app(&mut app);
        *self.running() = None;
        if app.window.is_some() {
            // The loop has ended and the window is still there: it is
            // dropped when this function returns. Whatever was made on it
            // is let go first.
            (app.drawer)(Canvas::Closing);
        }

        match (app.failure, ended) {
            (Some(reason), _) => Err(cannot_open(reason)),
            (None, Err(error)) => Err(cannot_open(error.to_string())),
            (None, Ok(())) => Ok(()),
        }
    }

    fn close(&self) {
        if let Some(proxy) = self.running().as_ref() {
            // The loop has ended if this fails, and then there is nothing
            // to close.
            let _ = proxy.send_event(());
        }
    }
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
    window: Option<Window>,
    /// Why the window could not be made, if it could not.
    failure: Option<String>,
}

impl ApplicationHandler for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.window.is_some() || self.failure.is_some() {
            return;
        }
        let attributes = Window::default_attributes().with_title(WinitPlatform::TITLE);
        match event_loop.create_window(attributes) {
            Ok(window) => {
                window.set_ime_allowed(self.options.composition);
                window.focus_window();
                let (opened, size) = self.seen.opened(
                    window.inner_size(),
                    window.scale_factor(),
                    native_window(&window),
                    refresh_rate(&window),
                );
                self.window = Some(window);
                // The drawer hears of the window before anyone else does.
                (self.drawer)(opened);
                (self.report)(Input::Opened {
                    platform: WinitPlatform::NAME.into(),
                });
                (self.report)(size);
            }
            Err(error) => {
                self.failure = Some(error.to_string());
                event_loop.exit();
            }
        }
    }

    fn user_event(&mut self, event_loop: &ActiveEventLoop, (): ()) {
        event_loop.exit();
    }

    fn window_event(&mut self, _: &ActiveEventLoop, _: WindowId, event: WindowEvent) {
        // How often the window's display refreshes, read when the
        // translation asks: it decides after which events to.
        let window = self.window.as_ref();
        let display = || window.and_then(refresh_rate);
        // Two of winit's events cannot be built in a test, a key and a change
        // of scale, so each is taken apart here and translated from its
        // parts. These two arms are all this handler decides.
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
                self.seen.scale(*scale_factor, &display)
            }
            other => self.seen.window_event(other, &display),
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
fn native_window(window: &Window) -> Option<NativeWindow> {
    let handle = window.window_handle().ok()?.as_raw();
    let display = window.display_handle().ok()?.as_raw();
    native::native(handle, display)
}

/// How often the display the window is on refreshes, in thousandths of a
/// hertz, when winit says.
fn refresh_rate(window: &Window) -> Option<u32> {
    window.current_monitor()?.refresh_rate_millihertz()
}

/// Builds the event loop, without winit's default menu where it has one.
fn event_loop() -> Result<EventLoop<()>, String> {
    let mut builder = EventLoop::with_user_event();
    #[cfg(target_os = "macos")]
    {
        use winit::platform::macos::EventLoopBuilderExtMacOS;
        builder.with_default_menu(false);
    }
    builder.build().map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

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
}
