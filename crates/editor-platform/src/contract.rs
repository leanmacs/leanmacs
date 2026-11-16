//! The contract of the window port: the rules every [`Platform`] keeps, as a
//! check that runs one.
//!
//! The rules:
//!
//! - **`Opened` comes first, with a name.** The first thing a run reports is
//!   [`Input::Opened`], and the platform's name in it is not empty.
//! - **Files to open come after `Opened`.** This is the rule above, read
//!   for [`Input::OpenFiles`]: a platform told of files before its window
//!   opened holds them, and one that reports them first breaks it
//!   ([`Violation::FirstInputNotOpened`]).
//! - **A close ends the run.** Once [`Platform::close`] has been called, from
//!   a thread other than the one in [`Platform::run`], the run returns `Ok`
//!   within a bound.
//! - **Nothing is reported once the run has returned.**
//! - **A close with no run in progress is harmless**: before a run it does
//!   not end the run that follows, and after one it reports nothing.
//! - **A request with no run in progress is harmless**: one asked before a
//!   run is not reported first by the run that follows, and one asked after
//!   a run reports nothing. The check asks for a title, which is harmless
//!   on a real desktop, and to keep running ([`Request::KeepRunning`]),
//!   with no quit pending.
//! - **The drawer is told the window opened before anyone hears of it.**
//!   The first thing a run tells its [`Drawer`] is [`Canvas::Opened`], and it
//!   tells it before it reports its first input: whoever learns of the
//!   window from the report finds what draws in it already made.
//! - **The drawer is told the window is closing, once, last.** A run tells
//!   [`Canvas::Closing`] before it returns and tells nothing after it, so
//!   that whatever was made on the window is let go while the window is
//!   still there.
//! - **A platform that cannot open a window tells the drawer nothing.**
//!
//! What a window does with a request while it runs is the contract of
//! [`requests`], which needs no platform.
//!
//! A platform that cannot open a window does not pass: the contract is of a
//! window that opens.
//!
//! The check keeps which thing a platform told its drawer and never the
//! native window in it: the verdict is taken on another thread, and a
//! native window is the telling thread's.
//!
//! Whether a run ends by itself can only be seen by leaving it alone for a
//! while. The check asks a platform to close before its run, and then leaves
//! the run alone for a settling time ([`SETTLE`], or what
//! [`Check::settling_for`] says) after its first input. A run that returns
//! in that time returned with no close asked of it, which is
//! [`Violation::ReturnedBeforeClose`]. A check that holds therefore takes
//! the settling time.
//!
//! There are two ways to run the check, and they judge the same things.
//! [`check`] runs the platform on a new thread and is for a platform that
//! may run on any thread, as the fake may. A real platform has to run on the
//! process's main thread, so its caller runs [`Check::run`] there and takes
//! the [`Check::verdict`] on another thread. Neither waits for a platform
//! without a bound: a run that never returns is a verdict, not a hang.
//!
//! The crate docs say where the real adapter is held to this.

pub mod requests;

use std::fmt;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread;
use std::time::{Duration, Instant};

use crate::{CannotOpen, Canvas, Drawer, Input, Platform, Report, Request, WindowOptions};

/// A rule of the contract that a platform broke. It is `PartialEq` only, as
/// [`Input`] is.
#[derive(Debug, Clone, PartialEq)]
pub enum Violation {
    /// No window could be opened, for the reason given.
    CouldNotOpen(String),
    /// Nothing was reported within the bound of the run starting.
    NothingReported,
    /// The first input was this, and not [`Input::Opened`].
    FirstInputNotOpened(Input),
    /// The platform's name in [`Input::Opened`] was empty.
    EmptyName,
    /// The run returned `Ok` with no close asked of it while it ran: a
    /// close made before the run ended it, or it ended by itself.
    ReturnedBeforeClose,
    /// The run had not returned this long after it was asked to close.
    DidNotReturn(Duration),
    /// This was reported after the run had returned.
    ReportedAfterReturn(Input),
    /// The first thing the drawer was told was this, by its variant's name,
    /// and not [`Canvas::Opened`].
    FirstToldNotOpened(&'static str),
    /// The first input was reported before the drawer had been told
    /// [`Canvas::Opened`].
    ReportedBeforeTold,
    /// The run returned without the drawer having been told
    /// [`Canvas::Closing`].
    ClosingNotTold,
    /// The drawer was told this, by its variant's name, after it had been
    /// told [`Canvas::Closing`], or after the run had returned.
    ToldAfterClosing(&'static str),
    /// No window could be opened, and the drawer had been told this, by its
    /// variant's name, all the same.
    ToldThoughItCouldNotOpen(&'static str),
}

impl fmt::Display for Violation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::CouldNotOpen(reason) => write!(f, "no window could be opened: {reason}"),
            Self::NothingReported => f.write_str("the window reported nothing"),
            Self::FirstInputNotOpened(input) => {
                write!(f, "the first input was {input:?}, not `Opened`")
            }
            Self::EmptyName => f.write_str("the platform's name in `Opened` was empty"),
            Self::ReturnedBeforeClose => {
                f.write_str("the run returned before it was asked to close")
            }
            Self::DidNotReturn(bound) => {
                write!(f, "the run had not returned {bound:?} after the close")
            }
            Self::ReportedAfterReturn(input) => {
                write!(f, "{input:?} was reported after the run had returned")
            }
            Self::FirstToldNotOpened(told) => {
                write!(f, "the drawer was first told `{told}`, not `Opened`")
            }
            Self::ReportedBeforeTold => {
                f.write_str("an input was reported before the drawer was told `Opened`")
            }
            Self::ClosingNotTold => {
                f.write_str("the run returned without telling the drawer `Closing`")
            }
            Self::ToldAfterClosing(told) => {
                write!(f, "the drawer was told `{told}` after `Closing`")
            }
            Self::ToldThoughItCouldNotOpen(told) => {
                write!(
                    f,
                    "no window could be opened, and the drawer was told `{told}`"
                )
            }
        }
    }
}

/// The name of what `canvas` tells, for a [`Violation`] to say.
fn name(canvas: &Canvas) -> &'static str {
    match canvas {
        Canvas::Opened { .. } => "Opened",
        Canvas::Resized(_) => "Resized",
        Canvas::Refresh(_) => "Refresh",
        Canvas::Damaged => "Damaged",
        Canvas::Hidden(_) => "Hidden",
        Canvas::Closing => "Closing",
    }
}

/// How long a run is left alone after its first input, before it is asked to
/// close, unless [`Check::settling_for`] says otherwise. A run that a close
/// made before it would end returns in this time.
pub const SETTLE: Duration = Duration::from_millis(50);

/// The title the check asks for with no run in progress, before the run and
/// after it.
const STRAY_TITLE: &str = "editor: asked with no window running";

/// One run of a platform under the contract.
///
/// A clone is the same check: one thread runs it and another takes its
/// verdict.
#[derive(Clone)]
pub struct Check {
    /// How the window is opened.
    options: WindowOptions,
    /// How long the platform has to report [`Input::Opened`], and then to
    /// return once it is asked to close.
    bound: Duration,
    /// How long the run is left alone after its first input, before it is
    /// asked to close.
    settle: Duration,
    /// What the run has done so far.
    progress: Arc<Shared>,
}

/// A [`Progress`] that threads share and wait on.
#[derive(Default)]
struct Shared {
    /// What the run has done so far.
    progress: Mutex<Progress>,
    /// Signalled whenever the progress changes.
    changed: Condvar,
}

/// What a run under the check has done so far.
#[derive(Default)]
struct Progress {
    /// When the run began.
    started: Option<Instant>,
    /// The first input the run reported.
    first: Option<Input>,
    /// When the run was asked to close, from the other thread. It is set
    /// only while the run has not returned.
    close_asked: Option<Instant>,
    /// When the run returned, and what it returned.
    returned: Option<(Instant, Result<(), CannotOpen>)>,
    /// The first input reported after the run had returned.
    late: Option<Input>,
    /// The first thing the drawer was told, by its variant's name.
    first_told: Option<&'static str>,
    /// Whether the first input was reported before the drawer had been told
    /// anything.
    reported_untold: bool,
    /// Whether the drawer was told [`Canvas::Closing`] before the run
    /// returned.
    closing_told: bool,
    /// The first thing the drawer was told after [`Canvas::Closing`] or
    /// after the run had returned, by its variant's name.
    told_late: Option<&'static str>,
    /// Whether everything the check does to the platform is done.
    finished: bool,
}

impl Shared {
    /// Locks the progress. The lock is never held while a platform runs, so
    /// a poisoned lock still guards consistent progress.
    fn progress(&self) -> MutexGuard<'_, Progress> {
        self.progress.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Changes the progress and wakes whoever waits on it.
    fn update(&self, change: impl FnOnce(&mut Progress)) {
        change(&mut self.progress());
        self.changed.notify_all();
    }

    /// Takes one input from the platform: the first of the run, or one that
    /// arrived after the run had returned. The inputs between are the
    /// platform's own business.
    fn record(&self, input: Input) {
        self.update(|progress| {
            if progress.returned.is_some() {
                progress.late.get_or_insert(input);
            } else if progress.first.is_none() {
                progress.first = Some(input);
                progress.reported_untold = progress.first_told.is_none();
            }
        });
    }

    /// Takes one thing the platform told the drawer: which thing it was,
    /// and never the native window in it, which is not this thread's to
    /// keep.
    fn tell(&self, canvas: &Canvas) {
        let told = name(canvas);
        let closing = matches!(canvas, Canvas::Closing);
        self.update(|progress| {
            if progress.returned.is_some() || progress.closing_told {
                progress.told_late.get_or_insert(told);
                return;
            }
            progress.first_told.get_or_insert(told);
            progress.closing_told = closing;
        });
    }

    /// Parks the calling thread until `ready` holds of the progress or
    /// `limit` has passed, and returns the progress, locked.
    fn wait(&self, limit: Duration, ready: impl Fn(&Progress) -> bool) -> MutexGuard<'_, Progress> {
        let deadline = Instant::now() + limit;
        let mut progress = self.progress();
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if ready(&progress) || left.is_zero() {
                return progress;
            }
            progress = self
                .changed
                .wait_timeout(progress, left)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }
}

impl Check {
    /// A check that opens the window as `options` say, and gives the
    /// platform `bound` to report [`Input::Opened`] and `bound` again to
    /// return once it is asked to close. It leaves the run alone for
    /// [`SETTLE`] after its first input.
    pub fn new(options: WindowOptions, bound: Duration) -> Self {
        Self {
            options,
            bound,
            settle: SETTLE,
            progress: Arc::default(),
        }
    }

    /// The same check, leaving the run alone for `settle` after its first
    /// input, before it is asked to close. Give a platform that is slow to
    /// act on a close longer than [`SETTLE`].
    #[must_use]
    pub fn settling_for(mut self, settle: Duration) -> Self {
        self.settle = settle;
        self
    }

    /// Runs `platform` on the calling thread, under the check: asks it to
    /// close before the run, from another thread once it has reported its
    /// first input and been left alone for the settling time, and again
    /// after the run. It returns when the platform's run does, which for a
    /// platform that ignores the close is never: take the
    /// [`verdict`](Self::verdict) on another thread.
    ///
    /// A platform that has reported nothing by the bound is asked to close
    /// all the same, so that the run can end.
    pub fn run(&self, platform: &impl Platform) {
        // With no run in progress these must do nothing: were the close
        // remembered, the run below would end before the close that is
        // meant for it, which the settling time below is there to see; were
        // the request, the run would report it before `Opened`. A title is
        // asked because it is harmless on a real desktop; keeping running
        // is asked because it answers a quit, and none is pending.
        platform.close();
        platform.request(Request::Title(STRAY_TITLE.into()));
        platform.request(Request::KeepRunning);

        self.progress
            .update(|progress| progress.started = Some(Instant::now()));
        let report: Report = {
            let progress = Arc::clone(&self.progress);
            Arc::new(move |input| progress.record(input))
        };
        let drawer: Drawer = {
            let progress = Arc::clone(&self.progress);
            Arc::new(move |canvas| progress.tell(&canvas))
        };
        thread::scope(|scope| {
            scope.spawn(|| {
                if self.ask_to_close() {
                    platform.close();
                }
            });
            let result = platform.run(self.options, report, drawer);
            self.progress
                .update(|progress| progress.returned = Some((Instant::now(), result)));
        });

        // Anything these make the platform report is reported after its run.
        platform.close();
        platform.request(Request::Title(STRAY_TITLE.into()));
        platform.request(Request::KeepRunning);
        self.progress.update(|progress| progress.finished = true);
    }

    /// Waits until the run is due its close, and records that it is asked
    /// for: once the run has reported its first input and been left alone
    /// for the settling time, or at the bound if it has reported nothing.
    /// Returns whether the close is to be made; it is not when the run has
    /// returned already.
    fn ask_to_close(&self) -> bool {
        let returned = |progress: &Progress| progress.returned.is_some();
        let reported = self
            .progress
            .wait(self.bound, |progress| {
                progress.first.is_some() || returned(progress)
            })
            .first
            .is_some();
        let settle = if reported {
            self.settle
        } else {
            Duration::ZERO
        };
        // The lock is held from seeing that the run has not returned to
        // recording the close, so a close is recorded only of a run that
        // was still going.
        let mut progress = self.progress.wait(settle, returned);
        if returned(&progress) {
            return false;
        }
        progress.close_asked = Some(Instant::now());
        drop(progress);
        self.progress.changed.notify_all();
        true
    }

    /// What the check found. It waits for [`run`](Self::run) to start and
    /// then to finish, but for a run that has started no longer than the
    /// bound allows the platform: a run that has not returned by then is a
    /// [`Violation::DidNotReturn`].
    pub fn verdict(&self) -> Result<(), Violation> {
        // Each wait below is cut to the bound, so the loop looks again at how
        // long the platform still has.
        loop {
            let progress = self.progress.wait(self.bound, |progress| progress.finished);
            if progress.finished || progress.returned.is_some() {
                return self.judge(&progress);
            }
            // The platform has the bound to report, and then the bound to
            // return once it has been asked to close, which is the settling
            // time after it reported.
            let allowed_until = match (progress.close_asked, progress.started) {
                (Some(asked), _) => asked + self.bound,
                (None, Some(started)) => started + self.bound + self.settle + self.bound,
                (None, None) => continue,
            };
            if Instant::now() >= allowed_until {
                return Err(Violation::DidNotReturn(self.bound));
            }
        }
    }

    /// The rules, held against a run that has returned.
    fn judge(&self, progress: &Progress) -> Result<(), Violation> {
        let Some((returned_at, result)) = &progress.returned else {
            return Err(Violation::DidNotReturn(self.bound));
        };
        if let Err(cannot_open) = result {
            return Err(match progress.first_told {
                Some(told) => Violation::ToldThoughItCouldNotOpen(told),
                None => Violation::CouldNotOpen(cannot_open.reason.clone()),
            });
        }
        match &progress.first {
            None => return Err(Violation::NothingReported),
            Some(Input::Opened { platform }) if platform.is_empty() => {
                return Err(Violation::EmptyName);
            }
            Some(Input::Opened { .. }) => {}
            Some(other) => return Err(Violation::FirstInputNotOpened(other.clone())),
        }
        match progress.first_told {
            Some("Opened") => {}
            Some(other) => return Err(Violation::FirstToldNotOpened(other)),
            None => return Err(Violation::ReportedBeforeTold),
        }
        if progress.reported_untold {
            return Err(Violation::ReportedBeforeTold);
        }
        let Some(asked) = progress.close_asked else {
            return Err(Violation::ReturnedBeforeClose);
        };
        if returned_at.saturating_duration_since(asked) > self.bound {
            return Err(Violation::DidNotReturn(self.bound));
        }
        if let Some(late) = &progress.late {
            return Err(Violation::ReportedAfterReturn(late.clone()));
        }
        if !progress.closing_told {
            return Err(Violation::ClosingNotTold);
        }
        if let Some(told) = progress.told_late {
            return Err(Violation::ToldAfterClosing(told));
        }
        Ok(())
    }
}

/// Runs `platform` under the contract on a new thread, opening the window as
/// `options` say, and returns what the check found.
///
/// `bound` is how long the platform has to report [`Input::Opened`], and
/// then to return once it is asked to close. A platform that never returns
/// fails at the bound, and the thread it was run on is left behind.
pub fn check<P>(platform: Arc<P>, options: WindowOptions, bound: Duration) -> Result<(), Violation>
where
    P: Platform + Send + 'static,
{
    let check = Check::new(options, bound);
    let runner = check.clone();
    thread::spawn(move || runner.run(&*platform));
    check.verdict()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ScriptedPlatform;

    /// A bound no platform that keeps the contract comes near: a check that
    /// holds returns long before it, and one that fails for another reason
    /// does not wait for it.
    const GENEROUS: Duration = Duration::from_secs(5);

    /// A bound short enough to wait out, for a platform that is expected to
    /// miss it.
    const SHORT: Duration = Duration::from_millis(50);

    /// Something a thread waits for and another opens, once.
    #[derive(Default)]
    struct Gate {
        /// Whether the gate is open.
        open: Mutex<bool>,
        /// Signalled when it opens.
        opened: Condvar,
    }

    impl Gate {
        /// Opens the gate, for good.
        fn open(&self) {
            *self.open.lock().unwrap_or_else(PoisonError::into_inner) = true;
            self.opened.notify_all();
        }

        /// Parks the calling thread until the gate is open.
        fn wait(&self) {
            let mut open = self.open.lock().unwrap_or_else(PoisonError::into_inner);
            while !*open {
                open = self
                    .opened
                    .wait(open)
                    .unwrap_or_else(PoisonError::into_inner);
            }
        }
    }

    /// [`Input::Opened`] from a platform called `name`.
    fn opened(name: &str) -> Input {
        Input::Opened {
            platform: name.into(),
        }
    }

    /// What a platform that keeps the contract tells the drawer first: the
    /// window is open, with no native window.
    fn told_opened() -> Canvas {
        Canvas::Opened {
            window: None,
            size: ScriptedPlatform::SIZE,
            refresh_millihertz: None,
        }
    }

    /// What a platform does wrong in telling the drawer. In everything else
    /// it keeps the contract.
    #[derive(Clone, Copy)]
    enum Telling {
        /// It tells the drawer nothing at all.
        Nothing,
        /// It tells `Opened` only after it has reported `Opened`.
        OpenedAfterReporting,
        /// It tells that the window is damaged before it tells `Opened`.
        DamagedFirst,
        /// It never tells `Closing`.
        NoClosing,
        /// It tells that the window is damaged after `Closing`.
        DamagedAfterClosing,
        /// It tells `Closing` twice.
        ClosingTwice,
        /// It tells `Closing` only when it is asked to close after its run
        /// has returned.
        ClosingAfterReturn,
    }

    /// A platform that reports `Opened`, waits for a close asked during its
    /// run, and tells the drawer wrongly in one way.
    struct Tells {
        /// What it does wrong.
        how: Telling,
        /// The close the run waits for.
        closing: Closing,
        /// What the last run was given to tell with, once it has returned.
        kept: Mutex<Option<Drawer>>,
    }

    impl Tells {
        fn new(how: Telling) -> Arc<Self> {
            Arc::new(Self {
                how,
                closing: Closing::default(),
                kept: Mutex::new(None),
            })
        }
    }

    impl Platform for Tells {
        fn run(
            &self,
            _options: WindowOptions,
            report: Report,
            drawer: Drawer,
        ) -> Result<(), CannotOpen> {
            self.closing.begin();
            match self.how {
                Telling::Nothing => report(opened("tells")),
                Telling::OpenedAfterReporting => {
                    report(opened("tells"));
                    drawer(told_opened());
                }
                Telling::DamagedFirst => {
                    drawer(Canvas::Damaged);
                    drawer(told_opened());
                    report(opened("tells"));
                }
                _ => {
                    drawer(told_opened());
                    report(opened("tells"));
                }
            }
            self.closing.wait();
            match self.how {
                Telling::Nothing | Telling::NoClosing => {}
                Telling::DamagedAfterClosing => {
                    drawer(Canvas::Closing);
                    drawer(Canvas::Damaged);
                }
                Telling::ClosingTwice => {
                    drawer(Canvas::Closing);
                    drawer(Canvas::Closing);
                }
                Telling::ClosingAfterReturn => {
                    *self.kept.lock().unwrap_or_else(PoisonError::into_inner) = Some(drawer);
                }
                _ => drawer(Canvas::Closing),
            }
            Ok(())
        }

        fn close(&self) {
            self.closing.ask();
            let kept = self.kept.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(drawer) = kept.as_ref() {
                drawer(Canvas::Closing);
            }
        }

        fn request(&self, _: Request) {}
    }

    /// A platform that tells the drawer its window is open and then cannot
    /// open one.
    struct FailsHavingTold;

    impl Platform for FailsHavingTold {
        fn run(
            &self,
            _options: WindowOptions,
            _report: Report,
            drawer: Drawer,
        ) -> Result<(), CannotOpen> {
            drawer(told_opened());
            Err(CannotOpen {
                reason: "no display".into(),
            })
        }

        fn close(&self) {}

        fn request(&self, _: Request) {}
    }

    #[test]
    fn a_platform_that_reports_before_it_tells_the_drawer_it_opened_is_refused() {
        for how in [Telling::Nothing, Telling::OpenedAfterReporting] {
            assert_eq!(
                check(Tells::new(how), WindowOptions::default(), GENEROUS),
                Err(Violation::ReportedBeforeTold)
            );
        }
    }

    #[test]
    fn a_platform_that_tells_the_drawer_something_before_it_opened_is_refused() {
        assert_eq!(
            check(
                Tells::new(Telling::DamagedFirst),
                WindowOptions::default(),
                GENEROUS
            ),
            Err(Violation::FirstToldNotOpened("Damaged"))
        );
    }

    #[test]
    fn a_platform_that_returns_without_telling_the_drawer_it_is_closing_is_refused() {
        for how in [Telling::NoClosing, Telling::ClosingAfterReturn] {
            assert_eq!(
                check(Tells::new(how), WindowOptions::default(), GENEROUS),
                Err(Violation::ClosingNotTold)
            );
        }
    }

    #[test]
    fn a_platform_that_tells_the_drawer_anything_after_closing_is_refused() {
        assert_eq!(
            check(
                Tells::new(Telling::DamagedAfterClosing),
                WindowOptions::default(),
                GENEROUS
            ),
            Err(Violation::ToldAfterClosing("Damaged"))
        );
        assert_eq!(
            check(
                Tells::new(Telling::ClosingTwice),
                WindowOptions::default(),
                GENEROUS
            ),
            Err(Violation::ToldAfterClosing("Closing"))
        );
    }

    #[test]
    fn a_platform_that_cannot_open_and_told_the_drawer_all_the_same_is_refused() {
        assert_eq!(
            check(
                Arc::new(FailsHavingTold),
                WindowOptions::default(),
                GENEROUS
            ),
            Err(Violation::ToldThoughItCouldNotOpen("Opened"))
        );
    }

    #[test]
    fn each_thing_a_window_tells_has_its_name() {
        let size = ScriptedPlatform::SIZE;
        for (canvas, named) in [
            (told_opened(), "Opened"),
            (Canvas::Resized(size), "Resized"),
            (Canvas::Refresh(Some(60_000)), "Refresh"),
            (Canvas::Damaged, "Damaged"),
            (Canvas::Hidden(true), "Hidden"),
            (Canvas::Closing, "Closing"),
        ] {
            assert_eq!(name(&canvas), named);
        }
    }

    /// The close a run waits for, which only a close asked while the run is
    /// in progress is: one asked before the run, or after it, is forgotten.
    #[derive(Default)]
    struct Closing {
        /// Whether a run is in progress, and whether it has been asked to
        /// close.
        run: Mutex<InProgress>,
        /// Signalled when the run in progress is asked to close.
        asked: Condvar,
    }

    /// What [`Closing::run`] guards.
    #[derive(Default)]
    struct InProgress {
        /// Whether a run is in progress.
        running: bool,
        /// Whether that run has been asked to close.
        asked: bool,
    }

    impl Closing {
        fn run(&self) -> MutexGuard<'_, InProgress> {
            self.run.lock().unwrap_or_else(PoisonError::into_inner)
        }

        /// A run begins, with no close asked of it.
        fn begin(&self) {
            *self.run() = InProgress {
                running: true,
                asked: false,
            };
        }

        /// Asks the run in progress to close, if there is one.
        fn ask(&self) {
            let mut run = self.run();
            if run.running {
                run.asked = true;
                self.asked.notify_all();
            }
        }

        /// Parks the calling thread until the run that began has been asked
        /// to close, and ends that run.
        fn wait(&self) {
            let mut run = self.run();
            while !run.asked {
                run = self.asked.wait(run).unwrap_or_else(PoisonError::into_inner);
            }
            run.running = false;
        }
    }

    /// A platform that reports `inputs` and then waits for a close asked
    /// during its run: the shape of a platform that keeps the contract, for
    /// the broken ones below to differ from in one thing each.
    struct Reports {
        /// What a run reports, in order.
        inputs: Vec<Input>,
        /// The close the run waits for.
        closing: Closing,
    }

    impl Reports {
        fn new(inputs: Vec<Input>) -> Arc<Self> {
            Arc::new(Self {
                inputs,
                closing: Closing::default(),
            })
        }
    }

    impl Platform for Reports {
        fn run(
            &self,
            _options: WindowOptions,
            report: Report,
            drawer: Drawer,
        ) -> Result<(), CannotOpen> {
            self.closing.begin();
            drawer(told_opened());
            for input in &self.inputs {
                report(input.clone());
            }
            self.closing.wait();
            drawer(Canvas::Closing);
            Ok(())
        }

        fn close(&self) {
            self.closing.ask();
        }

        fn request(&self, _: Request) {}
    }

    /// A platform that reports `Opened` and ignores every close. Its run
    /// returns only when the test releases it, so no thread outlives the
    /// test.
    #[derive(Default)]
    struct Deaf {
        /// Opened by the test when it is done.
        released: Gate,
    }

    impl Platform for Deaf {
        fn run(
            &self,
            _options: WindowOptions,
            report: Report,
            drawer: Drawer,
        ) -> Result<(), CannotOpen> {
            drawer(told_opened());
            report(opened("deaf"));
            self.released.wait();
            drawer(Canvas::Closing);
            Ok(())
        }

        fn close(&self) {}

        fn request(&self, _: Request) {}
    }

    /// A platform that keeps what it was given to report with, and reports
    /// through it when it is asked to close after its run has returned.
    #[derive(Default)]
    struct Lingering {
        /// The close the run waits for.
        closing: Closing,
        /// What the last run was given to report with, once it has returned.
        kept: Mutex<Option<Report>>,
    }

    impl Platform for Lingering {
        fn run(
            &self,
            _options: WindowOptions,
            report: Report,
            drawer: Drawer,
        ) -> Result<(), CannotOpen> {
            self.closing.begin();
            drawer(told_opened());
            report(opened("lingering"));
            self.closing.wait();
            drawer(Canvas::Closing);
            *self.kept.lock().unwrap_or_else(PoisonError::into_inner) = Some(report);
            Ok(())
        }

        fn close(&self) {
            self.closing.ask();
            let kept = self.kept.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(report) = kept.as_ref() {
                report(Input::Focus(false));
            }
        }

        fn request(&self, _: Request) {}
    }

    /// A platform that remembers a close made before its run: the run
    /// reports `Opened` and returns a moment later, with no close asked of
    /// it, as an event loop does that finds a stale close in its queue.
    #[derive(Default)]
    struct Remembers {
        /// Opened by any close, for good, whether a run is in progress or
        /// not.
        closed: Gate,
    }

    impl Platform for Remembers {
        fn run(
            &self,
            _options: WindowOptions,
            report: Report,
            drawer: Drawer,
        ) -> Result<(), CannotOpen> {
            drawer(told_opened());
            report(opened("remembers"));
            self.closed.wait();
            thread::sleep(Duration::from_millis(10));
            drawer(Canvas::Closing);
            Ok(())
        }

        fn close(&self) {
            self.closed.open();
        }

        fn request(&self, _: Request) {}
    }

    #[test]
    fn a_platform_that_remembers_a_close_made_before_its_run_is_refused() {
        let platform = Arc::new(Remembers::default());
        // The settling time is one this run cannot outlast, however slowly
        // its thread is scheduled; the check ends when the run returns.
        let check = Check::new(WindowOptions::default(), GENEROUS).settling_for(GENEROUS);

        let runner = check.clone();
        thread::spawn(move || runner.run(&*platform));

        assert_eq!(check.verdict(), Err(Violation::ReturnedBeforeClose));
    }

    /// A platform that remembers a request made with no run in progress,
    /// and reports it, as a resize, first when its next run begins: as an
    /// adapter would whose channel outlives its window.
    #[derive(Default)]
    struct RemembersRequests {
        /// The close the run waits for.
        closing: Closing,
        /// The requests asked so far, whether a run was in progress or not.
        remembered: Mutex<Vec<Request>>,
    }

    impl Platform for RemembersRequests {
        fn run(
            &self,
            _options: WindowOptions,
            report: Report,
            drawer: Drawer,
        ) -> Result<(), CannotOpen> {
            self.closing.begin();
            drawer(told_opened());
            let remembered = std::mem::take(
                &mut *self
                    .remembered
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner),
            );
            if !remembered.is_empty() {
                report(Input::Resized(ScriptedPlatform::SIZE));
            }
            report(opened("remembers requests"));
            self.closing.wait();
            drawer(Canvas::Closing);
            Ok(())
        }

        fn close(&self) {
            self.closing.ask();
        }

        fn request(&self, request: Request) {
            self.remembered
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(request);
        }
    }

    #[test]
    fn a_platform_that_remembers_a_request_made_before_its_run_is_refused() {
        assert_eq!(
            check(
                Arc::new(RemembersRequests::default()),
                WindowOptions::default(),
                GENEROUS
            ),
            Err(Violation::FirstInputNotOpened(Input::Resized(
                ScriptedPlatform::SIZE
            )))
        );
    }

    /// A platform that remembers only a [`Request::KeepRunning`] made with
    /// no run in progress, as an adapter would whose pending quit outlives
    /// its window, and reports it as [`RemembersRequests`] does.
    #[derive(Default)]
    struct RemembersKeepRunning(RemembersRequests);

    impl Platform for RemembersKeepRunning {
        fn run(
            &self,
            options: WindowOptions,
            report: Report,
            drawer: Drawer,
        ) -> Result<(), CannotOpen> {
            self.0.run(options, report, drawer)
        }

        fn close(&self) {
            self.0.close();
        }

        fn request(&self, request: Request) {
            if request == Request::KeepRunning {
                self.0.request(request);
            }
        }
    }

    #[test]
    fn a_platform_that_remembers_a_keep_running_asked_before_its_run_is_refused() {
        assert_eq!(
            check(
                Arc::new(RemembersKeepRunning::default()),
                WindowOptions::default(),
                GENEROUS
            ),
            Err(Violation::FirstInputNotOpened(Input::Resized(
                ScriptedPlatform::SIZE
            )))
        );
    }

    #[test]
    fn a_check_that_holds_leaves_the_run_alone_for_the_settling_time() {
        let platform = Arc::new(ScriptedPlatform::sample());
        let settle = Duration::from_millis(30);
        let check = Check::new(WindowOptions::default(), GENEROUS).settling_for(settle);
        let began = Instant::now();

        let runner = check.clone();
        thread::spawn(move || runner.run(&*platform));

        assert_eq!(check.verdict(), Ok(()));
        let took = began.elapsed();
        assert!(took >= settle, "the run was left alone: {took:?}");
    }

    #[test]
    fn the_contract_holds_of_the_scripted_platform_with_composition_allowed_and_not() {
        for composition in [true, false] {
            let platform = Arc::new(ScriptedPlatform::sample());

            let verdict = check(
                Arc::clone(&platform),
                WindowOptions { composition },
                GENEROUS,
            );

            assert_eq!(verdict, Ok(()));
            assert_eq!(platform.runs(), [WindowOptions { composition }]);
        }
    }

    #[test]
    fn the_contract_holds_of_a_platform_that_reports_only_that_it_opened() {
        let platform = Arc::new(ScriptedPlatform::new(Vec::new()));

        assert_eq!(check(platform, WindowOptions::default(), GENEROUS), Ok(()));
    }

    #[test]
    fn a_platform_that_cannot_open_a_window_is_refused_with_its_reason() {
        let platform = Arc::new(ScriptedPlatform::failing("no display"));

        assert_eq!(
            check(platform, WindowOptions::default(), GENEROUS),
            Err(Violation::CouldNotOpen("no display".into()))
        );
    }

    #[test]
    fn a_platform_that_reports_an_input_before_opened_is_refused() {
        let platform = Reports::new(vec![Input::Focus(true), opened("early")]);

        assert_eq!(
            check(platform, WindowOptions::default(), GENEROUS),
            Err(Violation::FirstInputNotOpened(Input::Focus(true)))
        );
    }

    #[test]
    fn a_platform_that_reports_files_to_open_before_opened_is_refused() {
        // As an adapter would that reported the files of a cold start as
        // they arrived, before its window had opened.
        let files = Input::OpenFiles(vec!["/Users/me/notes.txt".into()]);
        let platform = Reports::new(vec![files.clone(), opened("eager")]);

        assert_eq!(
            check(platform, WindowOptions::default(), GENEROUS),
            Err(Violation::FirstInputNotOpened(files))
        );
    }

    #[test]
    fn a_platform_whose_opened_has_an_empty_name_is_refused() {
        let platform = Reports::new(vec![opened("")]);

        assert_eq!(
            check(platform, WindowOptions::default(), GENEROUS),
            Err(Violation::EmptyName)
        );
    }

    #[test]
    fn a_platform_that_ignores_a_close_is_refused_at_the_bound_and_the_check_does_not_hang() {
        let platform = Arc::new(Deaf::default());
        let began = Instant::now();

        let verdict = check(Arc::clone(&platform), WindowOptions::default(), SHORT);

        let took = began.elapsed();
        platform.released.open();
        assert_eq!(verdict, Err(Violation::DidNotReturn(SHORT)));
        assert!(took >= SHORT, "the platform had its whole bound: {took:?}");
        assert!(took < GENEROUS, "the check ended at the bound: {took:?}");
    }

    #[test]
    fn a_platform_that_reports_nothing_is_refused_at_the_bound() {
        let platform = Reports::new(Vec::new());

        assert_eq!(
            check(platform, WindowOptions::default(), SHORT),
            Err(Violation::NothingReported)
        );
    }

    #[test]
    fn a_platform_that_reports_after_its_run_has_returned_is_refused() {
        let platform = Arc::new(Lingering::default());

        assert_eq!(
            check(platform, WindowOptions::default(), GENEROUS),
            Err(Violation::ReportedAfterReturn(Input::Focus(false)))
        );
    }

    #[test]
    fn a_check_run_on_the_calling_thread_gives_its_verdict_to_another() {
        let platform = ScriptedPlatform::sample();
        let check = Check::new(WindowOptions::default(), GENEROUS);

        let verdict = std::thread::scope(|scope| {
            let judge = scope.spawn(|| check.verdict());
            check.run(&platform);
            judge.join().expect("the verdict is given")
        });

        assert_eq!(verdict, Ok(()));
        assert_eq!(platform.runs(), [WindowOptions::default()]);
    }
}
