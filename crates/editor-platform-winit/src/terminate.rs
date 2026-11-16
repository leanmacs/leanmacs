//! The system's quit: the pure rules of what is reported when the system
//! asks the app to terminate, and when the system is answered.
//!
//! On macOS the application delegate (`delegate.rs`) answers every
//! `applicationShouldTerminate:` with `NSTerminateLater`, so AppKit waits
//! for a reply, and hands the ask on through `Handing::terminate`: onto a
//! channel, then a wake-up of the loop. The loop passes each ask, and each
//! [`Request::KeepRunning`](editor_platform::Request::KeepRunning) the
//! editor sends, through [`Terminate`], and forwards the [`Reply`] it gives
//! to `delegate::reply`. Every decision is here:
//!
//! - **The first ask once the window has opened is reported once**, as
//!   [`Input::QuitRequested`], and is then pending.
//! - **An ask while one is pending is not reported again.** The editor is
//!   already deciding.
//! - **An ask before the window has opened is held**, and reported once
//!   the window opens, after `Opened`, the `Resized` and the files to open,
//!   so that `Opened` still comes first. A logout during launch must not be
//!   reported before the window exists.
//! - **Keeping running with one pending cancels it, once** ([`Reply::Cancel`],
//!   `replyToApplicationShouldTerminate:NO`), which also cancels a logout,
//!   as TextEdit's unsaved document does. A later ask is reported again.
//! - **Keeping running with none pending does nothing.**
//! - **A close with one pending cancels it, once**, and a close with none
//!   makes no reply. The process then ends by the editor's own path: the
//!   step says stop, the window is closed, the run returns and `main`
//!   returns. This is the phase's fallback, not its first design, which
//!   made no reply: with a terminate pending AppKit waits inside
//!   `terminate:`, under winit's run, and the contract example showed the
//!   run then never returns. Replying `YES` instead would have AppKit end
//!   the process itself (`exit`), before the editor's own path ran. So a
//!   logout the editor goes along with is cancelled all the same, and the
//!   user is told the app cancelled it: a known limit, tracked as the rdm
//!   task `macos-terminate-close-cancels-logout`.
//!
//! A further fact of AppKit's, seen in the contract example: it lets an
//! answered `terminate:` go a few milliseconds after the reply, and a
//! second ask in between is taken for the terminate it is finishing, not
//! asked of the delegate. A person cannot ask that fast.

use editor_platform::Input;

/// What the system is answered: the one reply this adapter makes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Reply {
    /// The quit is cancelled: `replyToApplicationShouldTerminate:NO`.
    Cancel,
}

/// What is known of the system's asks to terminate.
#[derive(Debug, Default)]
pub(crate) struct Terminate {
    /// Whether the window has opened.
    opened: bool,
    /// Whether an ask arrived before the window had opened.
    held: bool,
    /// Whether an ask has been reported and not yet answered.
    pending: bool,
}

impl Terminate {
    /// The system asked to terminate: the input to report now, if any.
    /// Before the window has opened the ask is held; while one is pending
    /// it is not reported again.
    pub(crate) fn ask(&mut self) -> Option<Input> {
        if !self.opened {
            self.held = true;
            return None;
        }
        self.report()
    }

    /// The window opened, with `waiting` asks still on the channel: the
    /// input to report after `Opened`, the `Resized` and the files, if any.
    /// What was held and what was waiting are one ask.
    pub(crate) fn open(&mut self, waiting: usize) -> Option<Input> {
        self.opened = true;
        let asked = std::mem::take(&mut self.held) || waiting > 0;
        if asked { self.report() } else { None }
    }

    /// The editor asked to keep running: with one pending, the reply that
    /// cancels it, once; with none, nothing.
    pub(crate) fn keep_running(&mut self) -> Option<Reply> {
        std::mem::take(&mut self.pending).then_some(Reply::Cancel)
    }

    /// The window is closing: with one pending, the reply that cancels it,
    /// once; with none, nothing.
    ///
    /// The close is the editor quitting by its own path, so the process
    /// ends whatever the reply. But AppKit waits inside `terminate:` until
    /// it is answered, and the loop's run cannot return through that wait:
    /// with no reply the run never returns (seen in the contract example).
    /// Going ahead (`YES`) would have AppKit end the process itself, before
    /// the editor's own path ran. So the one reply left is to cancel, which
    /// also cancels a logout the editor went along with: a known limit.
    pub(crate) fn close(&mut self) -> Option<Reply> {
        self.keep_running()
    }

    /// An ask to report now, once the window has opened: reported unless
    /// one is pending, and then pending.
    fn report(&mut self) -> Option<Input> {
        if self.pending {
            return None;
        }
        self.pending = true;
        Some(Input::QuitRequested)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A terminate whose window has opened, with nothing asked.
    fn opened() -> Terminate {
        let mut terminate = Terminate::default();
        assert_eq!(terminate.open(0), None);
        terminate
    }

    #[test]
    fn the_first_terminate_asked_once_the_window_has_opened_is_reported_once() {
        let mut terminate = opened();

        assert_eq!(terminate.ask(), Some(Input::QuitRequested));
    }

    #[test]
    fn a_terminate_asked_while_one_is_pending_is_not_reported_again() {
        let mut terminate = opened();
        assert_eq!(terminate.ask(), Some(Input::QuitRequested));

        assert_eq!(terminate.ask(), None);
        assert_eq!(terminate.ask(), None);
    }

    #[test]
    fn keep_running_with_one_pending_cancels_it_once_and_clears_it() {
        let mut terminate = opened();
        assert_eq!(terminate.ask(), Some(Input::QuitRequested));

        assert_eq!(terminate.keep_running(), Some(Reply::Cancel));
        assert_eq!(terminate.keep_running(), None, "it is answered once");
        assert_eq!(
            terminate.ask(),
            Some(Input::QuitRequested),
            "a later ask is reported again"
        );
    }

    #[test]
    fn keep_running_with_none_pending_does_nothing() {
        assert_eq!(Terminate::default().keep_running(), None);
        assert_eq!(opened().keep_running(), None);
    }

    #[test]
    fn a_close_with_one_pending_cancels_it_once() {
        let mut terminate = opened();
        assert_eq!(terminate.ask(), Some(Input::QuitRequested));

        assert_eq!(terminate.close(), Some(Reply::Cancel));
        assert_eq!(terminate.close(), None, "it is answered once");
        assert_eq!(terminate.keep_running(), None, "and is no longer pending");
    }

    #[test]
    fn a_close_with_none_pending_makes_no_reply() {
        assert_eq!(Terminate::default().close(), None);
        assert_eq!(opened().close(), None);
        let mut held = Terminate::default();
        assert_eq!(held.ask(), None);
        assert_eq!(held.close(), None, "an ask never reported is not pending");
    }

    #[test]
    fn a_terminate_asked_before_the_window_opened_is_held_and_reported_when_it_opens() {
        let mut terminate = Terminate::default();
        assert_eq!(terminate.ask(), None);
        assert_eq!(terminate.ask(), None);

        assert_eq!(terminate.open(0), Some(Input::QuitRequested));
        assert_eq!(terminate.ask(), None, "it is pending once reported");
        assert_eq!(terminate.keep_running(), Some(Reply::Cancel));
    }

    #[test]
    fn asks_still_waiting_when_the_window_opens_are_reported_once() {
        assert_eq!(Terminate::default().open(2), Some(Input::QuitRequested));
        let mut terminate = Terminate::default();
        assert_eq!(terminate.ask(), None);
        assert_eq!(terminate.open(1), Some(Input::QuitRequested));
    }

    #[test]
    fn opening_twice_reports_nothing_more() {
        let mut terminate = Terminate::default();
        assert_eq!(terminate.ask(), None);
        assert_eq!(terminate.open(0), Some(Input::QuitRequested));

        assert_eq!(terminate.open(0), None);
    }
}
