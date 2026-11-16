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
//! - **A close with one pending lets the system terminate, once**
//!   ([`Reply::Now`], `replyToApplicationShouldTerminate:YES`), and so does
//!   a close with an ask held before the window opened or still waiting on
//!   the channel: nothing is left unanswered. A close with none makes no
//!   reply. With a terminate pending, AppKit waits inside `terminate:`,
//!   under winit's run, and the contract example showed the run then never
//!   returns; once answered `YES`, AppKit ends the process (`exit(0)`)
//!   without returning either. So the editor's own path runs before the
//!   close is asked: the step says stop, the host shuts down (its children
//!   killed and reaped, its watches ended, its queues quit), and asks for
//!   the close; the loop then tells the drawer the window is closing, and
//!   only then replies. A logout the editor goes along with goes on. This
//!   is the window port's rule (`Platform::close`): a close with a quit
//!   pending may end the process inside the run.
//! - **A close with a keep running asked before it cancels instead**
//!   ([`Reply::Cancel`]): one pending, one held and those waiting, once,
//!   so that the run returns. The editor's host asks it when its loop
//!   ended with an error, so that the error is said and a logout is not
//!   carried out over a crash.
//! - **A window that could not be opened cancels an ask held or waiting**
//!   ([`Reply::Cancel`]), so that the run returns and the host can say why.
//!
//! A further fact of AppKit's, seen in the contract example: it lets an
//! answered `terminate:` go a few milliseconds after the reply, and a
//! second ask in between is taken for the terminate it is finishing, not
//! asked of the delegate. A person cannot ask that fast.

use editor_platform::Input;

/// What the system is answered.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Reply {
    /// The quit is cancelled: `replyToApplicationShouldTerminate:NO`.
    Cancel,
    /// The quit goes ahead: `replyToApplicationShouldTerminate:YES`, after
    /// which AppKit ends the process.
    Now,
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

    /// The window is closing, with `waiting` asks still on the channel, and
    /// `kept` whether a keep running came with the close: with one pending,
    /// one held or one waiting, the reply once, which lets the system
    /// terminate, or cancels it when `kept`; with none, nothing.
    ///
    /// The close is the editor quitting by its own path, and the host has
    /// shut down before it asked for the close. AppKit waits inside
    /// `terminate:` until it is answered, and the loop's run cannot return
    /// through that wait (seen in the contract example), so an ask is never
    /// left unanswered here: going ahead lets AppKit end the process
    /// (`exit(0)`), and a logout the editor went along with goes on. An ask
    /// the editor never heard of, held or still waiting, is answered the
    /// same way: the editor was leaving anyway.
    ///
    /// A keep running asked before the close, and found with it, is the
    /// editor refusing the quit as it closes, as its host does when its loop
    /// failed: then every ask is cancelled, the run returns, and the host
    /// can say why. A logout is not carried out over a crash.
    pub(crate) fn close(&mut self, waiting: usize, kept: bool) -> Option<Reply> {
        let reply = if kept { Reply::Cancel } else { Reply::Now };
        self.take(waiting).then_some(reply)
    }

    /// The window could not be opened, with `waiting` asks still on the
    /// channel: with one held or waiting, the reply that cancels it, once;
    /// with none, nothing. The failure is the host's to report, which it
    /// can only do once the run has returned, and the run cannot return
    /// through AppKit's wait.
    pub(crate) fn fail(&mut self, waiting: usize) -> Option<Reply> {
        self.take(waiting).then_some(Reply::Cancel)
    }

    /// Whether an ask is pending, held or waiting, which is then answered.
    fn take(&mut self, waiting: usize) -> bool {
        let pending = std::mem::take(&mut self.pending);
        let held = std::mem::take(&mut self.held);
        pending || held || waiting > 0
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
    fn a_close_with_one_pending_lets_the_system_terminate_once() {
        let mut terminate = opened();
        assert_eq!(terminate.ask(), Some(Input::QuitRequested));

        assert_eq!(terminate.close(0, false), Some(Reply::Now));
        assert_eq!(terminate.close(0, false), None, "it is answered once");
        assert_eq!(terminate.keep_running(), None, "and is no longer pending");
    }

    #[test]
    fn a_close_with_an_ask_held_before_the_window_opened_lets_the_system_terminate() {
        let mut held = Terminate::default();
        assert_eq!(held.ask(), None);

        assert_eq!(held.close(0, false), Some(Reply::Now));
        assert_eq!(held.close(0, false), None, "it is answered once");
    }

    #[test]
    fn a_close_with_asks_still_waiting_on_the_channel_lets_the_system_terminate() {
        assert_eq!(opened().close(2, false), Some(Reply::Now));
        assert_eq!(Terminate::default().close(1, false), Some(Reply::Now));
        let mut terminate = opened();
        assert_eq!(terminate.ask(), Some(Input::QuitRequested));
        assert_eq!(
            terminate.close(1, false),
            Some(Reply::Now),
            "one pending and one waiting are one reply"
        );
    }

    #[test]
    fn a_close_with_none_asked_makes_no_reply() {
        assert_eq!(Terminate::default().close(0, false), None);
        assert_eq!(opened().close(0, false), None);
        let mut answered = opened();
        assert_eq!(answered.ask(), Some(Input::QuitRequested));
        assert_eq!(answered.keep_running(), Some(Reply::Cancel));
        assert_eq!(
            answered.close(0, false),
            None,
            "an ask answered is not pending"
        );
    }

    #[test]
    fn a_close_with_keep_running_asked_with_it_cancels_one_pending_held_or_waiting_once() {
        let mut pending = opened();
        assert_eq!(pending.ask(), Some(Input::QuitRequested));
        assert_eq!(pending.close(0, true), Some(Reply::Cancel));
        assert_eq!(pending.close(0, true), None, "it is answered once");
        assert_eq!(pending.close(0, false), None, "and is no longer pending");

        let mut held = Terminate::default();
        assert_eq!(held.ask(), None);
        assert_eq!(held.close(0, true), Some(Reply::Cancel));

        assert_eq!(opened().close(1, true), Some(Reply::Cancel));
        let mut both = opened();
        assert_eq!(both.ask(), Some(Input::QuitRequested));
        assert_eq!(
            both.close(2, true),
            Some(Reply::Cancel),
            "one pending and some waiting are one reply"
        );
    }

    #[test]
    fn a_close_with_keep_running_asked_with_it_and_none_asked_makes_no_reply() {
        assert_eq!(Terminate::default().close(0, true), None);
        assert_eq!(opened().close(0, true), None);
    }

    #[test]
    fn a_window_that_could_not_open_cancels_an_ask_held_or_waiting() {
        let mut held = Terminate::default();
        assert_eq!(held.ask(), None);
        assert_eq!(held.fail(0), Some(Reply::Cancel));
        assert_eq!(held.fail(0), None, "it is answered once");

        assert_eq!(Terminate::default().fail(1), Some(Reply::Cancel));
        assert_eq!(Terminate::default().fail(0), None);
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
