//! The window port's real adapter: [`WinitPlatform`], a
//! [`Platform`] over winit.
//!
//! The port, its fake and its contract are `editor-platform`'s. This crate
//! is thin: it opens one window, translates what winit reports about it into
//! the port's [`Input`], and ends its loop when it is asked to close. No
//! winit type is public, and no other crate depends on winit (`deny.toml`).
//!
//! What it does beyond translating:
//!
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
//! translation from winit's values to [`Input`] and the refusal off the main
//! thread. The event loop itself needs a display. It is held to the port's
//! contract by `examples/contract.rs`, which two opt-in tasks run:
//! `mise run linux-window`, under Xvfb in a container, and
//! `mise run window-contract`, on the desktop it is started from. Run the
//! first after a change to this crate.

use std::sync::{Mutex, MutexGuard, PoisonError};

use editor_platform::{
    CannotOpen, Composition, Input, Key, LogicalKey, Modifiers, Platform, Pointer, PointerAction,
    Report, WindowOptions,
};
use winit::application::ApplicationHandler;
use winit::event::{ElementState, Ime, WindowEvent};
use winit::event_loop::{ActiveEventLoop, EventLoop, EventLoopProxy};
use winit::keyboard;
use winit::window::{Window, WindowId};

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
    fn run(&self, options: WindowOptions, report: Report) -> Result<(), CannotOpen> {
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
            window: None,
            failure: None,
        };
        let ended = event_loop.run_app(&mut app);
        *self.running() = None;

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

/// The key event winit reports with these parts, as the port's input. It
/// takes the parts and not winit's whole key event, which cannot be built
/// outside winit.
///
/// The mapping is minimal: a dead key is a dead logical key, with its
/// character, and every other key is unidentified, with no physical key
/// and no modifiers. Giving a key its full identity, and a pointer its
/// position, button and modifiers, and reporting a resize, are the display
/// pipeline's (its phase 5).
fn key(
    state: ElementState,
    repeat: bool,
    logical_key: &keyboard::Key,
    text: Option<&str>,
) -> Input {
    let logical = match logical_key {
        keyboard::Key::Dead(character) => LogicalKey::Dead(*character),
        _ => LogicalKey::Unidentified,
    };
    Input::Key(Key {
        pressed: state == ElementState::Pressed,
        repeat,
        logical,
        text: text.unwrap_or_default().to_owned(),
        ..Key::unidentified()
    })
}

/// What the port reports for `event`, if it reports anything for it. A key
/// event goes through [`key`]. A pressed button is a press at the origin
/// with no button and no modifiers, and a resize is not reported: the
/// minimal mapping [`key`] describes.
fn translate(event: &WindowEvent) -> Option<Input> {
    match event {
        WindowEvent::Focused(gained) => Some(Input::Focus(*gained)),
        WindowEvent::Ime(step) => Some(Input::Composition(match step {
            Ime::Enabled => Composition::Enabled,
            Ime::Preedit(text, _) => Composition::Preedit(text.clone()),
            Ime::Commit(text) => Composition::Commit(text.clone()),
            Ime::Disabled => Composition::Disabled,
        })),
        WindowEvent::MouseInput {
            state: ElementState::Pressed,
            ..
        } => Some(Input::Pointer(Pointer {
            action: PointerAction::Press,
            x: 0.0,
            y: 0.0,
            button: None,
            modifiers: Modifiers::default(),
        })),
        WindowEvent::CloseRequested => Some(Input::CloseRequested),
        _ => None,
    }
}

/// The window and its loop's handler: what [`WinitPlatform::run`] hands to
/// winit.
struct App {
    /// How the window is opened.
    options: WindowOptions,
    /// Where what the window reports goes.
    report: Report,
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
                self.window = Some(window);
                (self.report)(Input::Opened {
                    platform: WinitPlatform::NAME.into(),
                });
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
        let input = match &event {
            WindowEvent::KeyboardInput { event, .. } => Some(key(
                event.state,
                event.repeat,
                &event.logical_key,
                event.text.as_deref(),
            )),
            other => translate(other),
        };
        if let Some(input) = input {
            (self.report)(input);
        }
    }
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
    use winit::dpi::PhysicalSize;
    use winit::event::{DeviceId, MouseButton};
    use winit::keyboard::{Key as WinitKey, NamedKey};

    /// A key event of the port, with no identity but whether it is dead.
    fn input_key(pressed: bool, repeat: bool, logical: LogicalKey, text: &str) -> Input {
        Input::Key(Key {
            pressed,
            repeat,
            logical,
            text: text.into(),
            ..Key::unidentified()
        })
    }

    /// The logical key for the character `text`.
    fn character(text: &str) -> WinitKey {
        WinitKey::Character(text.into())
    }

    #[test]
    fn a_pressed_key_carries_the_text_it_produced() {
        assert_eq!(
            key(ElementState::Pressed, false, &character("a"), Some("a")),
            input_key(true, false, LogicalKey::Unidentified, "a")
        );
        assert_eq!(
            key(ElementState::Pressed, false, &character("é"), Some("é")),
            input_key(true, false, LogicalKey::Unidentified, "é")
        );
    }

    #[test]
    fn a_key_that_produced_no_text_has_empty_text() {
        assert_eq!(
            key(
                ElementState::Pressed,
                false,
                &WinitKey::Named(NamedKey::Shift),
                None
            ),
            input_key(true, false, LogicalKey::Unidentified, "")
        );
    }

    #[test]
    fn a_released_key_is_not_pressed() {
        assert_eq!(
            key(ElementState::Released, false, &character("a"), None),
            input_key(false, false, LogicalKey::Unidentified, "")
        );
    }

    #[test]
    fn a_repeated_press_is_marked_a_repeat() {
        assert_eq!(
            key(ElementState::Pressed, true, &character("a"), Some("a")),
            input_key(true, true, LogicalKey::Unidentified, "a")
        );
    }

    #[test]
    fn a_dead_key_is_a_dead_logical_key_with_its_character_and_has_no_text() {
        assert_eq!(
            key(
                ElementState::Pressed,
                false,
                &WinitKey::Dead(Some('´')),
                None
            ),
            input_key(true, false, LogicalKey::Dead(Some('´')), "")
        );
        assert_eq!(
            key(ElementState::Released, false, &WinitKey::Dead(None), None),
            input_key(false, false, LogicalKey::Dead(None), "")
        );
    }

    #[test]
    fn each_step_of_a_composition_is_reported() {
        let step = |ime| translate(&WindowEvent::Ime(ime));

        assert_eq!(
            step(Ime::Enabled),
            Some(Input::Composition(Composition::Enabled))
        );
        assert_eq!(
            step(Ime::Preedit("´".into(), Some((0, 2)))),
            Some(Input::Composition(Composition::Preedit("´".into())))
        );
        assert_eq!(
            step(Ime::Preedit(String::new(), None)),
            Some(Input::Composition(Composition::Preedit(String::new())))
        );
        assert_eq!(
            step(Ime::Commit("é".into())),
            Some(Input::Composition(Composition::Commit("é".into())))
        );
        assert_eq!(
            step(Ime::Disabled),
            Some(Input::Composition(Composition::Disabled))
        );
    }

    #[test]
    fn focus_gained_and_lost_are_reported() {
        assert_eq!(
            translate(&WindowEvent::Focused(true)),
            Some(Input::Focus(true))
        );
        assert_eq!(
            translate(&WindowEvent::Focused(false)),
            Some(Input::Focus(false))
        );
    }

    #[test]
    fn a_pressed_pointer_button_is_reported_as_a_press_at_the_origin_with_no_button_and_its_release_is_not()
     {
        let button = |state| WindowEvent::MouseInput {
            device_id: DeviceId::dummy(),
            state,
            button: MouseButton::Left,
        };

        assert_eq!(
            translate(&button(ElementState::Pressed)),
            Some(Input::Pointer(Pointer {
                action: PointerAction::Press,
                x: 0.0,
                y: 0.0,
                button: None,
                modifiers: Modifiers::default(),
            }))
        );
        assert_eq!(translate(&button(ElementState::Released)), None);
    }

    #[test]
    fn a_request_to_close_is_reported() {
        assert_eq!(
            translate(&WindowEvent::CloseRequested),
            Some(Input::CloseRequested)
        );
    }

    #[test]
    fn an_event_the_port_has_no_input_for_is_not_reported() {
        assert_eq!(
            translate(&WindowEvent::Resized(PhysicalSize::new(800, 600))),
            None
        );
        assert_eq!(translate(&WindowEvent::Destroyed), None);
    }

    #[test]
    fn off_the_main_thread_a_run_is_refused_with_a_reason_and_reports_nothing() {
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

        let result = platform.run(WindowOptions::default(), report);

        let reason = result.expect_err("the run is refused").reason;
        assert!(
            reason.contains("main thread"),
            "the reason says why: {reason}"
        );
        assert_eq!(reported.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn a_close_with_no_window_running_does_nothing() {
        WinitPlatform::new(|| false).close();
    }
}
