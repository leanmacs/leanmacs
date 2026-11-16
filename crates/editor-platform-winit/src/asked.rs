//! What a request asked of the window does to it: the pure translation from
//! the port's [`Request`] to an [`Act`] on the window.
//!
//! The handler (`App::proxy_wake_up` in `lib.rs`) takes each request off
//! the channel, on the main thread, asks [`Asked::act`] what it comes to,
//! and [`apply`]s that to the window through [`Control`], a window as far
//! as requests go. The one implementation of [`Control`] that touches
//! winit, for its `dyn Window`, is a reading or a call with no decision in
//! it; every decision is here:
//!
//! - **Entering fullscreen is done only to a window that reads as not in
//!   it, and leaving only to one that reads as in it.** The decision uses
//!   the window's own reading, not a state remembered here, so it is right
//!   after the green button too. The fullscreen asked is
//!   `Fullscreen::Borderless(None)`: the system's fullscreen on the
//!   window's display, a Space of its own on macOS, which is what the green
//!   button gives.
//! - **A minimise is asked whatever the window reads.** What a system does
//!   with a minimise of a window in fullscreen is its own: macOS does not
//!   minimise one.
//! - **A title is set only when it is not the title the window shows**,
//!   which starts as [`WinitPlatform::TITLE`], so the window is never told
//!   what it already shows.
//! - **Keeping running is nothing done to the window.** It answers the
//!   system's quit, which is the module `terminate`'s.
//!
//! The adapter's run of `editor_platform::contract::requests` is this
//! module's: the translation, over a window that records what it is told
//! and models what winit documents of `set_fullscreen`, `set_minimized`
//! and `set_title`.

use editor_platform::Request;
use winit::monitor::Fullscreen;
use winit::window::Window;

use crate::WinitPlatform;

/// What a request comes to on the window: one call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Act {
    /// Put the window in the system's fullscreen (`true`), or take it out.
    Fullscreen(bool),
    /// Minimise the window.
    Minimise,
    /// Show this title.
    Title(String),
}

/// What the translation remembers of the window: the title it shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Asked {
    /// The title the window shows.
    title: String,
}

impl Default for Asked {
    /// A window that has just opened, with the title it opens with.
    fn default() -> Self {
        Self {
            title: WinitPlatform::TITLE.to_owned(),
        }
    }
}

impl Asked {
    /// What `request` comes to on a window that reads as in fullscreen or
    /// not (`in_fullscreen`); nothing when it would change nothing.
    pub(crate) fn act(&mut self, request: Request, in_fullscreen: bool) -> Option<Act> {
        match request {
            Request::EnterFullscreen => (!in_fullscreen).then_some(Act::Fullscreen(true)),
            Request::LeaveFullscreen => in_fullscreen.then_some(Act::Fullscreen(false)),
            Request::Minimise => Some(Act::Minimise),
            Request::Title(title) if title == self.title => None,
            Request::Title(title) => {
                self.title.clone_from(&title);
                Some(Act::Title(title))
            }
            // Not the window's: it answers the system's quit, which
            // `terminate.rs` decides. The handler never sends it here.
            Request::KeepRunning => None,
            // Not the window's: the menu bar is the application's. The
            // handler never sends it here.
            Request::Menu(_) => None,
        }
    }
}

/// A window as far as requests go: what an [`Act`] is applied to.
pub(crate) trait Control {
    /// Whether the window is in the system's fullscreen.
    fn in_fullscreen(&self) -> bool;
    /// Puts the window in the system's fullscreen, or takes it out.
    fn set_fullscreen(&self, on: bool);
    /// Minimises the window.
    fn minimise(&self);
    /// Shows `title` as the window's title.
    fn set_title(&self, title: &str);
}

/// Does `act` to `window`: one call.
pub(crate) fn apply(window: &(impl Control + ?Sized), act: Act) {
    match act {
        Act::Fullscreen(on) => window.set_fullscreen(on),
        Act::Minimise => window.minimise(),
        Act::Title(title) => window.set_title(&title),
    }
}

/// Carries `request` out on `window`, as [`Asked::act`] says.
pub(crate) fn carry_out(asked: &mut Asked, window: &(impl Control + ?Sized), request: Request) {
    if let Some(act) = asked.act(request, window.in_fullscreen()) {
        apply(window, act);
    }
}

/// winit's window. Each line is a reading of the window or a call with no
/// decision in it, and only a real window runs it.
impl Control for dyn Window {
    fn in_fullscreen(&self) -> bool {
        self.fullscreen().is_some()
    }

    fn set_fullscreen(&self, on: bool) {
        Window::set_fullscreen(self, on.then_some(Fullscreen::Borderless(None)));
    }

    fn minimise(&self) {
        self.set_minimized(true);
    }

    fn set_title(&self, title: &str) {
        Window::set_title(self, title);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use editor_platform::contract::requests::{self, Carries};
    use editor_platform::scripted::Shown;
    use std::cell::RefCell;

    #[test]
    fn entering_fullscreen_sets_it_on_a_window_not_in_it_and_does_nothing_on_one_in_it() {
        let mut asked = Asked::default();
        assert_eq!(
            asked.act(Request::EnterFullscreen, false),
            Some(Act::Fullscreen(true))
        );
        assert_eq!(asked.act(Request::EnterFullscreen, true), None);
    }

    #[test]
    fn leaving_fullscreen_is_the_mirror() {
        let mut asked = Asked::default();
        assert_eq!(
            asked.act(Request::LeaveFullscreen, true),
            Some(Act::Fullscreen(false))
        );
        assert_eq!(asked.act(Request::LeaveFullscreen, false), None);
    }

    #[test]
    fn minimise_minimises() {
        let mut asked = Asked::default();
        for in_fullscreen in [false, true] {
            assert_eq!(
                asked.act(Request::Minimise, in_fullscreen),
                Some(Act::Minimise)
            );
        }
    }

    #[test]
    fn a_title_is_set_only_when_it_is_not_the_one_the_window_shows() {
        let mut asked = Asked::default();
        let title = |text: &str| Request::Title(text.into());
        // The window opens with the platform's title.
        assert_eq!(asked.act(title(WinitPlatform::TITLE), false), None);
        assert_eq!(
            asked.act(title("notes.txt"), false),
            Some(Act::Title("notes.txt".into()))
        );
        assert_eq!(asked.act(title("notes.txt"), true), None);
        assert_eq!(
            asked.act(title(WinitPlatform::TITLE), false),
            Some(Act::Title(WinitPlatform::TITLE.into()))
        );
    }

    /// A call made on a [`RecordingWindow`].
    #[derive(Debug, Clone, PartialEq, Eq)]
    enum Call {
        SetFullscreen(bool),
        Minimise,
        SetTitle(String),
    }

    /// A window that records each call made on it and models what winit
    /// documents of it: `set_fullscreen` puts the window in fullscreen or
    /// takes it out, `set_minimized(true)` minimises it, and `set_title`
    /// shows the title.
    #[derive(Default)]
    struct RecordingWindow {
        shown: RefCell<Shown>,
        calls: RefCell<Vec<Call>>,
    }

    impl Control for RecordingWindow {
        fn in_fullscreen(&self) -> bool {
            self.shown.borrow().fullscreen
        }

        fn set_fullscreen(&self, on: bool) {
            self.calls.borrow_mut().push(Call::SetFullscreen(on));
            self.shown.borrow_mut().fullscreen = on;
        }

        fn minimise(&self) {
            self.calls.borrow_mut().push(Call::Minimise);
            self.shown.borrow_mut().minimised = true;
        }

        fn set_title(&self, title: &str) {
            self.calls.borrow_mut().push(Call::SetTitle(title.into()));
            self.shown.borrow_mut().title = Some(title.into());
        }
    }

    /// The translation over a recording window: what the adapter does on
    /// the main thread with each request it takes off its channel.
    #[derive(Default)]
    struct Carried {
        asked: Asked,
        window: RecordingWindow,
    }

    impl Carries for Carried {
        /// The window alone has no menu bar: the menu is the application's.
        const MENU_BAR: bool = false;

        fn carry_out(&mut self, request: Request) {
            carry_out(&mut self.asked, &self.window, request);
        }

        fn shown(&self) -> Shown {
            self.window.shown.borrow().clone()
        }
    }

    #[test]
    fn the_request_contract_holds_of_the_translation_over_a_recording_window() {
        assert_eq!(requests::check(Carried::default), Ok(()));
    }

    #[test]
    fn each_request_that_changes_the_window_is_one_call_on_it_and_one_that_does_not_is_none() {
        let mut carried = Carried::default();
        for request in [
            Request::LeaveFullscreen,
            Request::EnterFullscreen,
            Request::EnterFullscreen,
            Request::Title("notes.txt".into()),
            Request::Title("notes.txt".into()),
            Request::KeepRunning,
            Request::Menu(editor_platform::Menu::default()),
            Request::LeaveFullscreen,
            Request::Minimise,
        ] {
            carried.carry_out(request);
        }
        assert_eq!(
            *carried.window.calls.borrow(),
            [
                Call::SetFullscreen(true),
                Call::SetTitle("notes.txt".into()),
                Call::SetFullscreen(false),
                Call::Minimise,
            ]
        );
    }
}
