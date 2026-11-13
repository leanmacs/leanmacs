//! The fake platform: a window that reports a script.
//!
//! [`ScriptedPlatform`] is public, not `cfg(test)`, so the tests of any crate
//! above the port, and the Lean test executable through `editor-ffi`, run on
//! it. It opens nothing and needs no display.

use std::sync::{Condvar, Mutex, MutexGuard, PoisonError};

use crate::{
    Button, CannotOpen, Composition, Input, Key, LogicalKey, Modifiers, PhysicalKey, Platform,
    Pointer, PointerAction, Report, Resize, WindowOptions,
};

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
pub struct ScriptedPlatform {
    /// What a run reports after [`Input::Opened`], or the reason no window
    /// can be opened.
    script: Result<Vec<Input>, String>,
    /// Whether a run is in progress and what it has been asked.
    state: Mutex<State>,
    /// Signalled when a close is asked of a run in progress.
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
}

impl ScriptedPlatform {
    /// The name this platform gives itself in [`Input::Opened`].
    pub const NAME: &'static str = "scripted";

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
            }),
            Input::CloseRequested,
        ]
    }

    /// The options of every run so far, oldest first.
    pub fn runs(&self) -> Vec<WindowOptions> {
        self.state().runs.clone()
    }

    /// Locks the state. The lock is never held while other code runs, so a
    /// poisoned lock still guards a consistent state.
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl Platform for ScriptedPlatform {
    fn run(&self, options: WindowOptions, report: Report) -> Result<(), CannotOpen> {
        self.state().runs.push(options);
        let script = self.script.as_ref().map_err(|reason| CannotOpen {
            reason: reason.clone(),
        })?;
        {
            let mut state = self.state();
            state.running = true;
            state.close_asked = false;
        }

        report(Input::Opened {
            platform: Self::NAME.into(),
        });
        for input in script {
            if options.composition || !matches!(input, Input::Composition(_)) {
                report(input.clone());
            }
        }

        let mut state = self.state();
        while !state.close_asked {
            state = self
                .changed
                .wait(state)
                .unwrap_or_else(PoisonError::into_inner);
        }
        state.running = false;
        Ok(())
    }

    fn close(&self) {
        let mut state = self.state();
        if state.running {
            state.close_asked = true;
            self.changed.notify_all();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
        let platform = Arc::clone(platform);
        thread::spawn(move || {
            let report: Report = Arc::new(move |input| {
                let _ = report.send(input);
            });
            let _ = finished.send(platform.run(options, report));
        });
        Running { inputs, done }
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
