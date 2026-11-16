//! The fake platform: a window that reports a script.
//!
//! [`ScriptedPlatform`] is public, not `cfg(test)`, so the tests of any crate
//! above the port, and the Lean test executable through `editor-ffi`, run on
//! it. It opens nothing and needs no display.

use std::collections::VecDeque;
use std::sync::{Condvar, Mutex, MutexGuard, PoisonError};

use crate::{
    Button, CannotOpen, Canvas, Composition, Drawer, Input, Key, LogicalKey, Menu, Modifiers,
    PhysicalKey, Platform, Pointer, PointerAction, Report, Request, Resize, WindowOptions,
};

/// What a window shows, as far as requests go: the pure model that
/// [`contract::requests`](crate::contract::requests) is held against.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Shown {
    /// Whether the window is in the system's fullscreen.
    pub fullscreen: bool,
    /// Whether the window has been minimised.
    pub minimised: bool,
    /// The title asked last; `None` until one is.
    pub title: Option<String>,
    /// The menu bar asked last; `None` until one is.
    pub menu: Option<Menu>,
}

impl Shown {
    /// Carries out `request` on the window.
    ///
    /// Entering and leaving fullscreen set it, and are not toggles; a
    /// minimise minimises; a title replaces the title, and a menu the menu
    /// bar; keeping running changes nothing shown.
    ///
    /// The match is exhaustive: this is the model every request is held
    /// to, so a new request must say here what it does.
    pub fn carry_out(&mut self, request: &Request) {
        match request {
            Request::EnterFullscreen => self.fullscreen = true,
            Request::LeaveFullscreen => self.fullscreen = false,
            Request::Minimise => self.minimised = true,
            Request::Title(title) => self.title = Some(title.clone()),
            Request::KeepRunning => {}
            Request::Menu(menu) => self.menu = Some(menu.clone()),
        }
    }
}

/// A platform whose window reports [`Input::Opened`], then a script of
/// inputs in order, and then waits for [`close`](Platform::close).
///
/// The whole script is reported on every run, whenever the close is asked
/// for, so what a run reports does not depend on timing. Run with
/// composition not allowed, it leaves the [`Input::Composition`] steps out
/// of what it reports, as a real window delivers none.
///
/// It records the options of every run. It can be run again once a run has
/// returned; it is not meant to be run from two threads at once.
///
/// It models the system's quit as far as a close goes: a
/// [`Input::QuitRequested`] it reports is pending until it is asked
/// [`Request::KeepRunning`], and a close with one pending is a close that
/// lets the quit go ahead ([`quit_let_go`](Self::quit_let_go)), which a real
/// platform may carry out by ending the process inside its run. It returns
/// all the same: a test cannot end its own process.
///
/// It records what each run is asked ([`asked`](Self::asked)), while the
/// run is in progress only, and carries each request out on its model,
/// [`Shown`], which it shows ([`shown`](Self::shown)). It has a menu bar:
/// a menu asked is the menu it shows. A request that takes the window into fullscreen or out of it
/// is told to the drawer and reported as a [`Input::Resized`] at the size
/// the run last reported (its [`SIZE`](Self::SIZE), or the script's last
/// resize) carrying the new state, on the run's thread and before the
/// window closes. Any other request reports nothing.
pub struct ScriptedPlatform {
    /// What a run reports after [`Input::Opened`], or the reason no window
    /// can be opened.
    script: Result<Vec<Input>, String>,
    /// Whether a run is in progress and what it has been asked.
    state: Mutex<State>,
    /// Signalled when a close is asked of a run in progress, or a request
    /// gives it something to report.
    changed: Condvar,
}

/// What [`ScriptedPlatform::state`] guards.
#[derive(Default)]
struct State {
    /// Whether a run is in progress.
    running: bool,
    /// Whether the run in progress has been asked to close.
    close_asked: bool,
    /// The options of every run so far, oldest first.
    runs: Vec<WindowOptions>,
    /// What the latest run has been asked, oldest first.
    asked: Vec<Request>,
    /// What the running window shows, as requests have left it.
    shown: Shown,
    /// The size the run last reported, with the fullscreen state it said;
    /// `None` before a run has said one, when it is [`ScriptedPlatform::SIZE`].
    size: Option<Resize>,
    /// What requests have given the run to report, oldest first.
    to_report: VecDeque<Resize>,
    /// Whether the run has reported [`Input::QuitRequested`] and not been
    /// asked [`Request::KeepRunning`] since.
    quit_pending: bool,
    /// Whether the latest run closed with a quit pending.
    quit_let_go: bool,
}

impl ScriptedPlatform {
    /// The name this platform gives itself in [`Input::Opened`].
    pub const NAME: &'static str = "scripted";

    /// The size and scale it tells the drawer its window opened at: it has
    /// no window, so the size is this one, whatever the script.
    pub const SIZE: Resize = Resize {
        width: 640,
        height: 480,
        scale: 1.0,
        fullscreen: false,
    };

    /// A platform whose window reports `script` after [`Input::Opened`].
    pub fn new(script: Vec<Input>) -> Self {
        Self {
            script: Ok(script),
            state: Mutex::default(),
            changed: Condvar::new(),
        }
    }

    /// A platform that cannot open a window, for `reason`.
    pub fn failing(reason: impl Into<String>) -> Self {
        Self {
            script: Err(reason.into()),
            state: Mutex::default(),
            changed: Condvar::new(),
        }
    }

    /// The platform that reports [`sample_script`](Self::sample_script).
    pub fn sample() -> Self {
        Self::new(Self::sample_script())
    }

    /// One fixed script with each thing a window reports in it, which tests
    /// on both sides of the Lean boundary run: the focus gained; `a` pressed,
    /// as the key `KeyA` with shift and control held, and released (a
    /// release produces no text); a dead key `´` pressed, which produces none
    /// either; `é` pressed; a composition enabled, its preedit `´` and its
    /// commit `é`; the secondary button pressed at (12.5, 40) with alt held;
    /// the window resized to 800 by 600 at scale 2; and a request to close. The keys but the first two carry no physical
    /// key and no modifiers.
    ///
    /// It leaves out files to open ([`Input::OpenFiles`]): the sample drives
    /// the Lean window-host scenarios, where files to open would start
    /// loads. It leaves out a quit the system asked
    /// ([`Input::QuitRequested`]) for the same reason: there it would stop
    /// the loop. A script that needs either says it itself.
    pub fn sample_script() -> Vec<Input> {
        vec![
            Input::Focus(true),
            Input::Key(Key {
                pressed: true,
                repeat: false,
                logical: LogicalKey::Character("a".into()),
                physical: PhysicalKey::Code("KeyA".into()),
                modifiers: Modifiers {
                    shift: true,
                    control: true,
                    ..Modifiers::default()
                },
                text: "a".into(),
            }),
            Input::Key(Key::unidentified()),
            Input::Key(Key {
                pressed: true,
                logical: LogicalKey::Dead(Some('´')),
                ..Key::unidentified()
            }),
            Input::Key(Key {
                pressed: true,
                text: "é".into(),
                ..Key::unidentified()
            }),
            Input::Composition(Composition::Enabled),
            Input::Composition(Composition::Preedit("´".into())),
            Input::Composition(Composition::Commit("é".into())),
            Input::Pointer(Pointer {
                action: PointerAction::Press,
                x: 12.5,
                y: 40.0,
                button: Some(Button::Secondary),
                modifiers: Modifiers {
                    alt: true,
                    ..Modifiers::default()
                },
            }),
            Input::Resized(Resize {
                width: 800,
                height: 600,
                scale: 2.0,
                fullscreen: false,
            }),
            Input::CloseRequested,
        ]
    }

    /// The options of every run so far, oldest first.
    pub fn runs(&self) -> Vec<WindowOptions> {
        self.state().runs.clone()
    }

    /// What the latest run was asked while it was in progress, oldest
    /// first; nothing before any run. A run begins with nothing asked.
    pub fn asked(&self) -> Vec<Request> {
        self.state().asked.clone()
    }

    /// What its window shows now, as the requests of the run in progress
    /// have left it ([`Shown`]); once the run has returned, what that
    /// run's window last showed. Nothing before any run: a request asked
    /// with no run in progress changes nothing shown.
    pub fn shown(&self) -> Shown {
        self.state().shown.clone()
    }

    /// Whether the latest run's close came with the system's quit pending:
    /// the run reported [`Input::QuitRequested`] and was not asked
    /// [`Request::KeepRunning`] after it. A real platform may end the
    /// process inside [`run`](Platform::run) then ([`Platform::close`]);
    /// this one returns, and says so here. `false` before any run, and
    /// while a run is in progress.
    pub fn quit_let_go(&self) -> bool {
        self.state().quit_let_go
    }

    /// Locks the state. The lock is never held while other code runs, so a
    /// poisoned lock still guards a consistent state.
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl Platform for ScriptedPlatform {
    fn run(
        &self,
        options: WindowOptions,
        report: Report,
        drawer: Drawer,
    ) -> Result<(), CannotOpen> {
        self.state().runs.push(options);
        let script = self.script.as_ref().map_err(|reason| CannotOpen {
            reason: reason.clone(),
        })?;
        {
            let mut state = self.state();
            state.running = true;
            state.close_asked = false;
            state.asked.clear();
            state.shown = Shown::default();
            state.size = None;
            state.to_report.clear();
            state.quit_pending = false;
            state.quit_let_go = false;
        }

        drawer(Canvas::Opened {
            window: None,
            size: Self::SIZE,
            refresh_millihertz: None,
        });
        report(Input::Opened {
            platform: Self::NAME.into(),
        });
        for input in script {
            if options.composition || !matches!(input, Input::Composition(_)) {
                if let Input::Resized(size) = input {
                    {
                        let mut state = self.state();
                        state.size = Some(*size);
                        state.shown.fullscreen = size.fullscreen;
                    }
                    drawer(Canvas::Resized(*size));
                }
                // Pending before it is reported, so that a keep running
                // sent in answer to the report finds it.
                if *input == Input::QuitRequested {
                    self.state().quit_pending = true;
                }
                report(input.clone());
            }
        }

        // Until a close is asked, and then until nothing is left to
        // report: what a request gave it to report is reported before the
        // window closes, and the lock is not held while it is.
        loop {
            let next = {
                let mut state = self.state();
                while !state.close_asked && state.to_report.is_empty() {
                    state = self
                        .changed
                        .wait(state)
                        .unwrap_or_else(PoisonError::into_inner);
                }
                state.to_report.pop_front()
            };
            let Some(size) = next else { break };
            drawer(Canvas::Resized(size));
            report(Input::Resized(size));
        }
        // The close takes effect here: a quit still pending is let go, as a
        // real platform may end the process with it.
        {
            let mut state = self.state();
            state.quit_let_go = state.quit_pending;
        }
        // The run is still in progress while the drawer lets go of what it
        // made: a drawer may take its time over that, and the lock is not
        // held across it.
        drawer(Canvas::Closing);
        self.state().running = false;
        Ok(())
    }

    fn close(&self) {
        let mut state = self.state();
        if state.running {
            state.close_asked = true;
            self.changed.notify_all();
        }
    }

    fn request(&self, request: Request) {
        let mut state = self.state();
        if !state.running {
            return;
        }
        if request == Request::KeepRunning {
            state.quit_pending = false;
        }
        let was = state.shown.fullscreen;
        state.shown.carry_out(&request);
        state.asked.push(request);
        let fullscreen = state.shown.fullscreen;
        if fullscreen != was {
            let size = Resize {
                fullscreen,
                ..state.size.unwrap_or(Self::SIZE)
            };
            state.size = Some(size);
            state.to_report.push_back(size);
            self.changed.notify_all();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::menu::{Action, Item, Menu, Submenu};
    use std::sync::Arc;
    use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
    use std::thread;
    use std::time::Duration;

    /// How long a test waits for something that should happen at once. Only
    /// a broken platform takes this long, and the test then fails instead of
    /// hanging.
    const DEADLINE: Duration = Duration::from_secs(5);

    /// How long a test waits to see that something does not happen.
    const SETTLE: Duration = Duration::from_millis(20);

    /// A run in progress on a thread of its own.
    struct Running {
        /// What the run has reported, in order.
        inputs: Receiver<Input>,
        /// The run's result, once it has returned.
        done: Receiver<Result<(), CannotOpen>>,
        /// Everything the run has said to either listener, in the order it
        /// said it, and that it returned.
        said: Receiver<Said>,
    }

    /// One thing a run did, as a value another thread can be sent: a
    /// [`Canvas`] cannot be.
    #[derive(Debug, Clone, PartialEq)]
    enum Said {
        /// It reported this.
        Reported(Input),
        /// It told the drawer the window opened, with a native window or
        /// not, at this size and with this refresh rate.
        Opened(bool, Resize, Option<u32>),
        /// It told the drawer this new size.
        Resized(Resize),
        /// It told the drawer something else, named.
        Other(&'static str),
        /// It told the drawer the window is closing.
        Closing,
        /// Its run returned.
        Returned,
    }

    impl Said {
        /// What telling the drawer `canvas` is.
        fn told(canvas: &Canvas) -> Self {
            match canvas {
                Canvas::Opened {
                    window,
                    size,
                    refresh_millihertz,
                } => Self::Opened(window.is_some(), *size, *refresh_millihertz),
                Canvas::Resized(size) => Self::Resized(*size),
                Canvas::Refresh(_) => Self::Other("refresh"),
                Canvas::Damaged => Self::Other("damaged"),
                Canvas::Hidden(_) => Self::Other("hidden"),
                Canvas::Closing => Self::Closing,
            }
        }
    }

    impl Running {
        /// The next `count` inputs the run reports; panics if they do not
        /// arrive by the deadline.
        fn next(&self, count: usize) -> Vec<Input> {
            (0..count)
                .map(|_| {
                    self.inputs
                        .recv_timeout(DEADLINE)
                        .expect("the platform reports its next input")
                })
                .collect()
        }

        /// Whether the run has neither reported anything more nor returned,
        /// a moment from now.
        fn is_waiting(&self) -> bool {
            self.inputs.recv_timeout(SETTLE) == Err(RecvTimeoutError::Timeout)
                && self.done.try_recv().is_err()
        }

        /// The run's result; panics if it has not returned by the deadline.
        fn result(&self) -> Result<(), CannotOpen> {
            self.done
                .recv_timeout(DEADLINE)
                .expect("the run returns once it is asked to close")
        }
    }

    /// Starts a run of `platform` on a thread of its own. The thread is
    /// detached, so a run that never returns cannot keep the test from
    /// ending.
    fn start(platform: &Arc<ScriptedPlatform>, options: WindowOptions) -> Running {
        let (report, inputs) = mpsc::channel();
        let (finished, done) = mpsc::channel();
        let (say, said) = mpsc::channel();
        let platform = Arc::clone(platform);
        thread::spawn(move || {
            let report: Report = {
                let say = say.clone();
                Arc::new(move |input: Input| {
                    let _ = say.send(Said::Reported(input.clone()));
                    let _ = report.send(input);
                })
            };
            let drawer: Drawer = {
                let say = say.clone();
                Arc::new(move |canvas| {
                    let _ = say.send(Said::told(&canvas));
                })
            };
            let result = platform.run(options, report, drawer);
            let _ = say.send(Said::Returned);
            let _ = finished.send(result);
        });
        Running { inputs, done, said }
    }

    impl Running {
        /// Everything the run said to either listener, in order, up to and
        /// with its return; panics if it has not returned by the deadline.
        fn all_said(&self) -> Vec<Said> {
            let mut all = Vec::new();
            loop {
                let next = self
                    .said
                    .recv_timeout(DEADLINE)
                    .expect("the run says its next thing, or returns");
                let returned = next == Said::Returned;
                all.push(next);
                if returned {
                    return all;
                }
            }
        }
    }

    /// The drawer was told the window opened as the scripted platform tells
    /// it: no native window, its fixed size, no refresh rate.
    fn told_opened() -> Said {
        Said::Opened(false, ScriptedPlatform::SIZE, None)
    }

    #[test]
    fn it_tells_the_drawer_the_window_opened_before_it_reports_it_and_that_it_is_closing_last() {
        let script = vec![Input::Focus(true), press("a")];
        let platform = Arc::new(ScriptedPlatform::new(script));

        let run = start(&platform, COMPOSING);
        assert_eq!(run.next(3).len(), 3);
        platform.close();

        assert_eq!(
            run.all_said(),
            [
                told_opened(),
                Said::Reported(opened()),
                Said::Reported(Input::Focus(true)),
                Said::Reported(press("a")),
                Said::Closing,
                Said::Returned,
            ]
        );
        assert_eq!(
            ScriptedPlatform::SIZE,
            Resize {
                width: 640,
                height: 480,
                scale: 1.0,
                fullscreen: false,
            }
        );
    }

    #[test]
    fn it_tells_the_drawer_each_scripted_resize_before_it_reports_it() {
        let small = Resize {
            width: 300,
            height: 120,
            scale: 1.0,
            fullscreen: false,
        };
        let large = Resize {
            width: 800,
            height: 600,
            scale: 2.0,
            fullscreen: false,
        };
        let script = vec![Input::Resized(small), press("a"), Input::Resized(large)];
        let platform = Arc::new(ScriptedPlatform::new(script));

        let run = start(&platform, COMPOSING);
        assert_eq!(run.next(4).len(), 4);
        platform.close();

        assert_eq!(
            run.all_said(),
            [
                told_opened(),
                Said::Reported(opened()),
                Said::Resized(small),
                Said::Reported(Input::Resized(small)),
                Said::Reported(press("a")),
                Said::Resized(large),
                Said::Reported(Input::Resized(large)),
                Said::Closing,
                Said::Returned,
            ]
        );
    }

    #[test]
    fn a_platform_that_cannot_open_tells_the_drawer_nothing() {
        let platform = Arc::new(ScriptedPlatform::failing("no display"));

        let run = start(&platform, COMPOSING);

        assert_eq!(run.all_said(), [Said::Returned]);
        assert!(run.result().is_err());
    }

    /// A key press that produced `text`.
    fn press(text: &str) -> Input {
        Input::Key(Key {
            pressed: true,
            text: text.into(),
            ..Key::unidentified()
        })
    }

    /// [`Input::Opened`] as the scripted platform reports it.
    fn opened() -> Input {
        Input::Opened {
            platform: "scripted".into(),
        }
    }

    /// Composition allowed, and not.
    const COMPOSING: WindowOptions = WindowOptions { composition: true };
    const NOT_COMPOSING: WindowOptions = WindowOptions { composition: false };

    #[test]
    fn it_reports_opened_with_its_name_then_its_script_and_returns_only_once_it_is_closed() {
        let script = vec![Input::Focus(true), press("a"), Input::CloseRequested];
        let platform = Arc::new(ScriptedPlatform::new(script.clone()));

        let run = start(&platform, COMPOSING);

        assert_eq!(run.next(1), [opened()]);
        assert_eq!(run.next(3), script);
        assert!(run.is_waiting(), "the run waits for a close");

        platform.close();

        assert_eq!(run.result(), Ok(()));
        assert!(run.inputs.try_recv().is_err(), "nothing more was reported");
    }

    #[test]
    fn files_to_open_in_a_script_are_reported_after_opened_in_order() {
        let first = Input::OpenFiles(vec!["/Users/me/notes.txt".into()]);
        let second = Input::OpenFiles(vec!["/tmp/a.lean".into(), "/tmp/b.lean".into()]);
        let platform = Arc::new(ScriptedPlatform::new(vec![first.clone(), second.clone()]));

        let run = start(&platform, COMPOSING);

        assert_eq!(run.next(3), [opened(), first, second]);
        platform.close();
        assert_eq!(run.result(), Ok(()));
    }

    #[test]
    fn a_quit_asked_by_the_system_in_a_script_is_reported_after_opened_in_order() {
        let script = vec![press("a"), Input::QuitRequested, Input::Focus(false)];
        let platform = Arc::new(ScriptedPlatform::new(script.clone()));

        let run = start(&platform, COMPOSING);

        assert_eq!(run.next(1), [opened()]);
        assert_eq!(run.next(3), script);
        assert!(run.is_waiting(), "a quit asked ends nothing by itself");
        platform.close();
        assert_eq!(run.result(), Ok(()));
    }

    #[test]
    fn a_close_with_a_quit_reported_and_not_answered_lets_the_quit_go() {
        let platform = Arc::new(ScriptedPlatform::new(vec![Input::QuitRequested]));
        assert!(!platform.quit_let_go(), "nothing before any run");

        let run = start(&platform, COMPOSING);
        assert_eq!(run.next(2), [opened(), Input::QuitRequested]);
        platform.close();

        assert_eq!(run.result(), Ok(()), "the fake returns all the same");
        assert!(platform.quit_let_go());
    }

    #[test]
    fn keep_running_asked_before_the_close_refuses_the_quit_so_it_is_not_let_go() {
        let platform = Arc::new(ScriptedPlatform::new(vec![Input::QuitRequested]));

        let run = start(&platform, COMPOSING);
        assert_eq!(run.next(2), [opened(), Input::QuitRequested]);
        platform.request(Request::KeepRunning);
        platform.close();

        assert_eq!(run.result(), Ok(()));
        assert!(!platform.quit_let_go());
    }

    #[test]
    fn a_close_with_no_quit_reported_lets_none_go_and_each_run_begins_with_none() {
        let platform = Arc::new(ScriptedPlatform::new(vec![press("a")]));
        let run = start(&platform, COMPOSING);
        assert_eq!(run.next(2), [opened(), press("a")]);
        platform.close();
        assert_eq!(run.result(), Ok(()));
        assert!(!platform.quit_let_go());

        let quitting = Arc::new(ScriptedPlatform::new(vec![Input::QuitRequested]));
        let first = start(&quitting, COMPOSING);
        assert_eq!(first.next(2), [opened(), Input::QuitRequested]);
        quitting.close();
        assert_eq!(first.result(), Ok(()));
        assert!(quitting.quit_let_go());
        let second = start(&quitting, COMPOSING);
        assert_eq!(second.next(2), [opened(), Input::QuitRequested]);
        assert!(
            !quitting.quit_let_go(),
            "a run in progress has let nothing go"
        );
        quitting.request(Request::KeepRunning);
        quitting.close();
        assert_eq!(second.result(), Ok(()));
        assert!(!quitting.quit_let_go());
    }

    #[test]
    fn a_close_with_no_run_in_progress_does_nothing() {
        let platform = Arc::new(ScriptedPlatform::new(vec![press("a")]));

        platform.close();
        let run = start(&platform, COMPOSING);

        assert_eq!(run.next(2), [opened(), press("a")]);
        assert!(
            run.is_waiting(),
            "an earlier close does not end a later run"
        );
        platform.close();
        assert_eq!(run.result(), Ok(()));
    }

    #[test]
    fn a_close_asked_before_the_script_ends_still_lets_the_whole_script_be_reported() {
        let script: Vec<Input> = (0..100).map(|n| press(&n.to_string())).collect();
        let platform = Arc::new(ScriptedPlatform::new(script.clone()));

        let run = start(&platform, COMPOSING);
        assert_eq!(run.next(1), [opened()]);
        platform.close();

        assert_eq!(run.next(100), script);
        assert_eq!(run.result(), Ok(()));
    }

    #[test]
    fn it_can_be_run_again_once_a_run_has_returned() {
        let platform = Arc::new(ScriptedPlatform::new(vec![press("a")]));

        for _ in 0..2 {
            let run = start(&platform, COMPOSING);
            assert_eq!(run.next(2), [opened(), press("a")]);
            assert!(run.is_waiting(), "each run waits for a close of its own");
            platform.close();
            assert_eq!(run.result(), Ok(()));
        }
    }

    #[test]
    fn a_platform_that_cannot_open_returns_its_reason_and_reports_nothing() {
        let platform = Arc::new(ScriptedPlatform::failing("no display"));

        let run = start(&platform, COMPOSING);

        assert_eq!(
            run.result(),
            Err(CannotOpen {
                reason: "no display".into()
            })
        );
        assert!(run.inputs.try_recv().is_err(), "nothing was reported");
    }

    #[test]
    fn it_records_the_options_of_every_run() {
        let platform = Arc::new(ScriptedPlatform::new(Vec::new()));
        assert_eq!(platform.runs(), []);

        for options in [NOT_COMPOSING, COMPOSING] {
            let run = start(&platform, options);
            assert_eq!(run.next(1), [opened()]);
            platform.close();
            assert_eq!(run.result(), Ok(()));
        }

        assert_eq!(platform.runs(), [NOT_COMPOSING, COMPOSING]);
    }

    #[test]
    fn a_failed_run_is_recorded_with_its_options_too() {
        let platform = Arc::new(ScriptedPlatform::failing("no display"));

        assert!(start(&platform, NOT_COMPOSING).result().is_err());

        assert_eq!(platform.runs(), [NOT_COMPOSING]);
    }

    #[test]
    fn run_with_composition_not_allowed_it_leaves_the_composition_steps_out() {
        let script = vec![
            press("a"),
            Input::Composition(Composition::Enabled),
            Input::Composition(Composition::Preedit("´".into())),
            Input::Composition(Composition::Commit("é".into())),
            Input::Composition(Composition::Disabled),
            Input::CloseRequested,
        ];
        let platform = Arc::new(ScriptedPlatform::new(script.clone()));

        let composing = start(&platform, COMPOSING);
        assert_eq!(composing.next(1), [opened()]);
        assert_eq!(composing.next(6), script);
        platform.close();
        assert_eq!(composing.result(), Ok(()));

        let plain = start(&platform, NOT_COMPOSING);
        assert_eq!(plain.next(3), [opened(), press("a"), Input::CloseRequested]);
        assert!(plain.is_waiting(), "nothing else is reported");
        platform.close();
        assert_eq!(plain.result(), Ok(()));
    }

    #[test]
    fn the_sample_script_has_each_thing_a_window_reports() {
        let unidentified = |pressed, text: &str| {
            Input::Key(Key {
                pressed,
                text: text.into(),
                ..Key::unidentified()
            })
        };

        assert_eq!(
            ScriptedPlatform::sample_script(),
            [
                Input::Focus(true),
                Input::Key(Key {
                    pressed: true,
                    repeat: false,
                    logical: LogicalKey::Character("a".into()),
                    physical: PhysicalKey::Code("KeyA".into()),
                    modifiers: Modifiers {
                        shift: true,
                        control: true,
                        ..Modifiers::default()
                    },
                    text: "a".into(),
                }),
                unidentified(false, ""),
                Input::Key(Key {
                    pressed: true,
                    logical: LogicalKey::Dead(Some('´')),
                    ..Key::unidentified()
                }),
                unidentified(true, "é"),
                Input::Composition(Composition::Enabled),
                Input::Composition(Composition::Preedit("´".into())),
                Input::Composition(Composition::Commit("é".into())),
                Input::Pointer(Pointer {
                    action: PointerAction::Press,
                    x: 12.5,
                    y: 40.0,
                    button: Some(Button::Secondary),
                    modifiers: Modifiers {
                        alt: true,
                        ..Modifiers::default()
                    },
                }),
                Input::Resized(Resize {
                    width: 800,
                    height: 600,
                    scale: 2.0,
                    fullscreen: false,
                }),
                Input::CloseRequested,
            ]
        );
    }

    #[test]
    fn an_unidentified_key_is_a_release_with_no_identity_no_modifiers_and_no_text() {
        assert_eq!(
            Key::unidentified(),
            Key {
                pressed: false,
                repeat: false,
                logical: LogicalKey::Unidentified,
                physical: PhysicalKey::Unidentified,
                modifiers: Modifiers {
                    shift: false,
                    control: false,
                    alt: false,
                    super_key: false,
                },
                text: String::new(),
            }
        );
    }

    /// The size the scripted platform opens at, in fullscreen or not.
    fn opened_size(fullscreen: bool) -> Resize {
        Resize {
            fullscreen,
            ..ScriptedPlatform::SIZE
        }
    }

    #[test]
    fn requests_asked_while_a_window_runs_are_recorded_in_the_order_they_were_sent() {
        let platform = Arc::new(ScriptedPlatform::new(Vec::new()));
        let run = start(&platform, COMPOSING);
        assert_eq!(run.next(1), [opened()]);

        let asked = [
            Request::EnterFullscreen,
            Request::Minimise,
            Request::LeaveFullscreen,
            Request::KeepRunning,
            Request::Title("notes.txt".into()),
        ];
        for request in asked.clone() {
            platform.request(request);
        }

        assert_eq!(platform.asked(), asked);
        platform.close();
        assert_eq!(run.result(), Ok(()));
    }

    #[test]
    fn a_request_with_no_run_in_progress_is_not_recorded_and_ends_no_later_run() {
        let platform = Arc::new(ScriptedPlatform::new(Vec::new()));

        platform.request(Request::EnterFullscreen);
        platform.request(Request::Title("before".into()));
        platform.request(Request::KeepRunning);
        let run = start(&platform, COMPOSING);

        assert_eq!(run.next(1), [opened()]);
        assert!(
            run.is_waiting(),
            "an earlier request reports nothing and ends nothing"
        );
        assert_eq!(platform.asked(), []);
        platform.request(Request::Minimise);
        platform.close();
        assert_eq!(run.result(), Ok(()));

        // Nor is one asked once the run has returned.
        platform.request(Request::Title("after".into()));
        platform.request(Request::KeepRunning);
        assert_eq!(platform.asked(), [Request::Minimise]);
    }

    #[test]
    fn the_record_of_requests_is_the_latest_runs() {
        let platform = Arc::new(ScriptedPlatform::new(Vec::new()));

        let first = start(&platform, COMPOSING);
        assert_eq!(first.next(1), [opened()]);
        platform.request(Request::Minimise);
        platform.close();
        assert_eq!(first.result(), Ok(()));
        assert_eq!(platform.asked(), [Request::Minimise]);

        let second = start(&platform, COMPOSING);
        assert_eq!(second.next(1), [opened()]);
        assert_eq!(platform.asked(), [], "a run begins with nothing asked");
        platform.request(Request::Title("todo.txt".into()));
        platform.close();
        assert_eq!(second.result(), Ok(()));
        assert_eq!(platform.asked(), [Request::Title("todo.txt".into())]);
    }

    #[test]
    fn a_fullscreen_request_that_changes_the_window_is_told_and_reported_as_a_resize_at_its_last_size_carrying_the_new_state()
     {
        let large = Resize {
            width: 800,
            height: 600,
            scale: 2.0,
            fullscreen: false,
        };
        let platform = Arc::new(ScriptedPlatform::new(vec![Input::Resized(large)]));
        let run = start(&platform, COMPOSING);
        assert_eq!(run.next(2), [opened(), Input::Resized(large)]);

        let entered = Resize {
            fullscreen: true,
            ..large
        };
        platform.request(Request::EnterFullscreen);
        assert_eq!(run.next(1), [Input::Resized(entered)]);
        platform.request(Request::LeaveFullscreen);
        assert_eq!(run.next(1), [Input::Resized(large)]);
        platform.close();

        assert_eq!(
            run.all_said(),
            [
                told_opened(),
                Said::Reported(opened()),
                Said::Resized(large),
                Said::Reported(Input::Resized(large)),
                Said::Resized(entered),
                Said::Reported(Input::Resized(entered)),
                Said::Resized(large),
                Said::Reported(Input::Resized(large)),
                Said::Closing,
                Said::Returned,
            ]
        );
    }

    #[test]
    fn a_fullscreen_request_that_changes_nothing_a_minimise_a_title_keep_running_and_a_menu_report_nothing()
     {
        let platform = Arc::new(ScriptedPlatform::new(Vec::new()));
        let run = start(&platform, COMPOSING);
        assert_eq!(run.next(1), [opened()]);

        platform.request(Request::LeaveFullscreen);
        platform.request(Request::Minimise);
        platform.request(Request::Title("notes.txt".into()));
        platform.request(Request::KeepRunning);
        platform.request(Request::Menu(Menu::default()));
        assert!(run.is_waiting(), "none of these changes fullscreen");

        platform.request(Request::EnterFullscreen);
        assert_eq!(run.next(1), [Input::Resized(opened_size(true))]);
        platform.request(Request::EnterFullscreen);
        assert!(run.is_waiting(), "a window in fullscreen stays there");

        platform.close();
        assert_eq!(run.result(), Ok(()));
    }

    /// A menu bar of one menu, titled `title`, with one command item.
    fn menu(title: &str) -> Menu {
        Menu {
            menus: vec![Submenu {
                title: title.into(),
                role: None,
                items: vec![Item::Entry {
                    title: "Undo".into(),
                    key: None,
                    action: Action::Command("undo".into()),
                }],
            }],
        }
    }

    #[test]
    fn a_menu_asked_while_a_window_runs_is_the_menu_it_shows_and_the_last_wins() {
        let platform = Arc::new(ScriptedPlatform::new(Vec::new()));
        let run = start(&platform, COMPOSING);
        assert_eq!(run.next(1), [opened()]);

        platform.request(Request::Menu(menu("File")));
        platform.request(Request::Menu(menu("Edit")));

        assert_eq!(platform.shown().menu, Some(menu("Edit")));
        assert_eq!(
            platform.asked(),
            [Request::Menu(menu("File")), Request::Menu(menu("Edit"))]
        );
        assert!(run.is_waiting(), "a menu reports nothing");
        platform.close();
        assert_eq!(run.result(), Ok(()));
        assert_eq!(
            platform.shown().menu,
            Some(menu("Edit")),
            "what the latest run's window last showed"
        );
    }

    #[test]
    fn a_menu_asked_with_no_window_running_is_not_remembered() {
        let platform = Arc::new(ScriptedPlatform::new(Vec::new()));
        platform.request(Request::Menu(menu("before")));
        assert_eq!(platform.shown(), Shown::default(), "nothing before any run");

        let run = start(&platform, COMPOSING);
        assert_eq!(run.next(1), [opened()]);
        assert_eq!(platform.shown().menu, None);
        assert_eq!(platform.asked(), []);
        platform.close();
        assert_eq!(run.result(), Ok(()));

        platform.request(Request::Menu(menu("after")));
        assert_eq!(platform.shown().menu, None);
        assert_eq!(platform.asked(), []);
    }

    #[test]
    fn the_model_carries_out_each_request() {
        let mut shown = Shown::default();
        assert_eq!(
            shown,
            Shown {
                fullscreen: false,
                minimised: false,
                title: None,
                menu: None,
            }
        );
        shown.carry_out(&Request::Menu(menu("File")));
        shown.carry_out(&Request::Menu(menu("Edit")));
        assert_eq!(shown.menu, Some(menu("Edit")), "the last menu wins");
        shown.menu = None;

        shown.carry_out(&Request::EnterFullscreen);
        shown.carry_out(&Request::EnterFullscreen);
        assert!(shown.fullscreen, "entering is not a toggle");
        shown.carry_out(&Request::Title("a".into()));
        shown.carry_out(&Request::Title("b".into()));
        assert_eq!(shown.title.as_deref(), Some("b"));
        shown.carry_out(&Request::LeaveFullscreen);
        shown.carry_out(&Request::LeaveFullscreen);
        shown.carry_out(&Request::Minimise);
        let before = shown.clone();
        shown.carry_out(&Request::KeepRunning);
        assert_eq!(shown, before, "keeping running changes nothing shown");
        assert_eq!(
            shown,
            Shown {
                fullscreen: false,
                minimised: true,
                title: Some("b".into()),
                menu: None,
            }
        );
    }

    #[test]
    fn the_sample_platform_reports_the_sample_script() {
        let platform = Arc::new(ScriptedPlatform::sample());
        let script = ScriptedPlatform::sample_script();

        let run = start(&platform, COMPOSING);

        assert_eq!(run.next(1), [opened()]);
        assert_eq!(run.next(script.len()), script);
        platform.close();
        assert_eq!(run.result(), Ok(()));
    }
}
