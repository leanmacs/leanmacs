//! The winit platform held to the window port's contract
//! (`editor_platform::contract`), on a real display.
//!
//! This opens a window, so it is an example and not a test: the gate builds
//! it and never runs it. Two opt-in tasks run it: `mise run linux-window`,
//! under Xvfb in a container, and `mise run window-contract`, on the desktop
//! it is started from. The window opens and closes again in about a second.
//!
//! On macOS it also asks the running window for a menu bar, reads it back
//! from AppKit and performs its items (the module `menu`), and then asks
//! the window to quit as the system does (the module `terminate`), while
//! the check runs it: the window is run under the check through [`Probed`],
//! which records what it reports and holds the check's close until those
//! scenarios have finished, then asks the window to keep running just
//! before the close, so that the terminate the second scenario leaves
//! pending is cancelled and the run returns. On Linux a menu bar changes
//! nothing shown, and nothing more is run. Once the check
//! holds, it starts itself again, to see a close with the system's quit
//! pending end the process by AppKit's terminate (the module `pending`),
//! which a run that must return cannot show.
//!
//! It prints the verdict on one line, and then each resize the window
//! reported, in order, one line apiece: its size, scale, whether it was in
//! fullscreen, its corner clearance and its top inset (`window-contract:
//! resized 1600x1200 scale 2 fullscreen false corner 16 top 28`). That is
//! how what a real window says of its corners and its title bar is seen.
//! The window opens with the options' default, the themed title bar. Its
//! exit status is the result: 0 when the platform keeps the contract, 1
//! when it does not, which includes a window that could not be opened, a
//! scenario that did not see what it should, and, on macOS, the process
//! ending by any way but the verdict, as AppKit ends it when a terminate
//! goes ahead.

#[cfg(target_os = "macos")]
mod menu;
#[cfg(target_os = "macos")]
mod pending;
#[cfg(target_os = "macos")]
mod terminate;

use std::process::exit;
#[cfg(target_os = "macos")]
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread;
use std::time::Duration;

use editor_wait::{self as wait, HangGuard};

use editor_platform::contract::Check;
#[cfg(target_os = "macos")]
use editor_platform::{CannotOpen, Drawer, Platform, Report, Request};
use editor_platform::{Input, Resize, WindowOptions};
use editor_platform_winit::WinitPlatform;

/// hang guard: the window's opening, and then its return once it is asked
/// to close; only a hang reaches the bound, and the check then fails as a
/// hang. The contract judges a return later than it on elapsed time, which
/// load can stretch: follow-up `platform-contract-settle-window-on-time`.
pub const BOUND: HangGuard = HangGuard::on(
    "the window's opening, then its return once asked to close",
    Duration::from_secs(20),
);

/// hang guard, run out on purpose: the open window left alone, which a loop
/// that keeps the contract does not end; the check pins the hang. A loop
/// that an earlier close would end has turned many times by then. Deciding
/// that by a window and not by the loop's idle notification is follow-up
/// `platform-contract-settle-window-on-time`.
const SETTLE: HangGuard = HangGuard::held(
    "the open window left alone, which a loop that keeps the contract does not end",
    Duration::from_millis(500),
);

/// hang guard: the scenarios finishing, which the check's close waits for;
/// only a hang reaches the bound, and the check then fails as a hang. It is
/// well within the bound the platform then has to return.
#[cfg(target_os = "macos")]
const SCENARIO: HangGuard = HangGuard::on("the scenarios finishing", Duration::from_secs(15));

/// `main` runs on the process's main thread, and the platform is run from
/// `main`.
fn on_main_thread() -> bool {
    true
}

/// The platform under the check: one in a process, as winit allows.
pub static PLATFORM: WinitPlatform = WinitPlatform::new(on_main_thread);

/// Whether the verdict is ending the process. Any other end is a failure.
static JUDGED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Prints `line`, then each of `resizes` on a line of its own, and ends the
/// process with `status`, as the verdict.
#[expect(
    clippy::disallowed_methods,
    reason = "the contract example ends the process with its verdict"
)]
fn verdict(line: &str, status: i32, resizes: &[Resize]) -> ! {
    JUDGED.store(true, Ordering::SeqCst);
    println!("{line}");
    for size in resizes {
        println!(
            "window-contract: resized {}x{} scale {} fullscreen {} corner {} top {}",
            size.width,
            size.height,
            size.scale,
            size.fullscreen,
            size.corner_clearance,
            size.top_inset
        );
    }
    exit(status);
}

/// Everything a run has reported, in order, which threads share and wait
/// on.
#[derive(Default)]
pub struct Record {
    /// What has been reported.
    inputs: Mutex<Vec<Input>>,
    /// Signalled when something more is.
    changed: Condvar,
}

impl Record {
    /// Locks what has been reported. Nothing runs under the lock, so a
    /// poisoned one still guards a consistent record.
    fn locked(&self) -> MutexGuard<'_, Vec<Input>> {
        self.inputs.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Takes one input.
    pub fn push(&self, input: Input) {
        self.locked().push(input);
        self.changed.notify_all();
    }

    /// Everything reported so far.
    pub fn inputs(&self) -> Vec<Input> {
        self.locked().clone()
    }

    /// Waits until `ready` holds of what has been reported, which each push
    /// notifies, or `guard` has run out, and returns what has been.
    pub fn wait(&self, guard: HangGuard, ready: impl Fn(&[Input]) -> bool) -> Vec<Input> {
        let (inputs, _) =
            wait::wait_while(&self.changed, self.locked(), guard, |inputs| !ready(inputs));
        inputs.clone()
    }
}

/// How many times something has happened, which threads share and wait on.
#[cfg(target_os = "macos")]
#[derive(Default)]
pub struct Count {
    /// The count.
    count: Mutex<usize>,
    /// Signalled when it grows.
    changed: Condvar,
}

#[cfg(target_os = "macos")]
impl Count {
    /// None yet.
    pub const fn new() -> Self {
        Self {
            count: Mutex::new(0),
            changed: Condvar::new(),
        }
    }

    /// Locks the count. Nothing runs under the lock.
    fn locked(&self) -> MutexGuard<'_, usize> {
        self.count.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Counts one more.
    pub fn add(&self) {
        *self.locked() += 1;
        self.changed.notify_all();
    }

    /// The count now.
    pub fn get(&self) -> usize {
        *self.locked()
    }

    /// Waits until the count is at least `count`, which each `add`
    /// notifies, or `guard` has run out, and returns it.
    pub fn wait(&self, count: usize, guard: HangGuard) -> usize {
        let (now, _) = wait::wait_while(&self.changed, self.locked(), guard, |now| *now < count);
        *now
    }
}

/// What a scenario run beside the check came to, once it has.
#[derive(Default)]
struct Outcome {
    /// `None` until it has finished, then its result.
    result: Mutex<Option<Result<(), String>>>,
    /// Signalled when it finishes.
    finished: Condvar,
}

impl Outcome {
    /// Locks the result. Nothing runs under the lock.
    fn locked(&self) -> MutexGuard<'_, Option<Result<(), String>>> {
        self.result.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Takes the scenario's result.
    #[cfg_attr(not(target_os = "macos"), expect(dead_code, reason = "macOS only"))]
    fn finish(&self, result: Result<(), String>) {
        *self.locked() = Some(result);
        self.finished.notify_all();
    }

    /// Waits until the scenario has finished, which notifies `finished`,
    /// or `guard` has run out.
    #[cfg_attr(not(target_os = "macos"), expect(dead_code, reason = "macOS only"))]
    fn wait(&self, guard: HangGuard) {
        let _ = wait::wait_while(&self.finished, self.locked(), guard, |result| {
            result.is_none()
        });
    }

    /// The scenario's result: a failure if it has not finished.
    fn result(&self) -> Result<(), String> {
        self.locked()
            .clone()
            .unwrap_or_else(|| Err("the scenario did not finish".into()))
    }
}

/// The platform as the check runs it on macOS: each run records what it
/// reports and starts the scenario beside it, and a close waits, bounded,
/// for a scenario that has started to finish before it is passed on.
#[cfg(target_os = "macos")]
struct Probed {
    /// The platform run.
    platform: &'static WinitPlatform,
    /// What the run reported.
    record: Arc<Record>,
    /// What the scenario came to.
    outcome: Arc<Outcome>,
    /// Whether the scenario has been started.
    started: AtomicBool,
}

#[cfg(target_os = "macos")]
impl Platform for Probed {
    fn run(
        &self,
        options: WindowOptions,
        report: Report,
        drawer: Drawer,
    ) -> Result<(), CannotOpen> {
        let tee: Report = {
            let record = Arc::clone(&self.record);
            Arc::new(move |input: Input| {
                record.push(input.clone());
                report(input);
            })
        };
        let (platform, record, outcome) = (
            self.platform,
            Arc::clone(&self.record),
            Arc::clone(&self.outcome),
        );
        self.started.store(true, Ordering::SeqCst);
        // The menu bar's Quit item leaves one quit reported, which the
        // terminate scenario counts from.
        thread::spawn(move || {
            outcome.finish(
                menu::scenario(platform, &record)
                    .and_then(|()| terminate::scenario(platform, &record, 1)),
            );
        });
        self.platform.run(options, tee, drawer)
    }

    /// Waits for the scenarios, the last of which leaves a terminate
    /// pending, then asks
    /// the window to keep running and, straight after, to close: the
    /// window port's way to refuse the system's quit as the window closes,
    /// so that the run returns.
    fn close(&self) {
        if self.started.load(Ordering::SeqCst) {
            self.outcome.wait(SCENARIO);
        }
        self.platform.request(Request::KeepRunning);
        self.platform.close();
    }

    fn request(&self, request: Request) {
        self.platform.request(request);
    }
}

/// Ends the process with status 1 unless the verdict is ending it: AppKit
/// ends the process itself (`exit(0)`) when a terminate goes ahead, and
/// that must not pass.
#[cfg(target_os = "macos")]
extern "C" fn unjudged_exit() {
    unsafe extern "C" {
        fn _exit(status: std::ffi::c_int) -> !;
    }
    if !JUDGED.load(Ordering::SeqCst) {
        println!(
            "window-contract: FAILED: the process was ended by something other than the verdict"
        );
        // SAFETY: `_exit` ends the process at once, which is what is
        // meant, from inside `exit`'s handlers.
        unsafe { _exit(1) };
    }
}

/// Registers `handler` to run when the process exits: [`unjudged_exit`]
/// here, and `pending`'s own in the process it runs in.
#[cfg(target_os = "macos")]
pub fn guard_exit(handler: extern "C" fn()) {
    unsafe extern "C" {
        fn atexit(handler: extern "C" fn()) -> std::ffi::c_int;
    }
    // SAFETY: the handler is a plain function that lives as long as the
    // process.
    if unsafe { atexit(handler) } != 0 {
        verdict(
            "window-contract: FAILED: the exit guard could not be registered",
            1,
            &[],
        );
    }
}

fn main() {
    #[cfg(target_os = "macos")]
    #[expect(
        clippy::disallowed_methods,
        reason = "an example's entry reads its own command line"
    )]
    if std::env::args().nth(1).as_deref() == Some(pending::ARGUMENT) {
        pending::main();
    }

    let check = Check::new(WindowOptions::default(), BOUND).settling_for(SETTLE);
    let outcome = Arc::new(Outcome::default());

    #[cfg(target_os = "macos")]
    guard_exit(unjudged_exit);

    // The verdict is taken on a second thread, which ends the process with
    // it: a window that ignored the close would keep this thread for good.
    let judge = check.clone();
    let scenario = Arc::clone(&outcome);
    thread::spawn(move || {
        let held = judge.verdict();
        // The verdict's line, then each resize the run reported.
        let verdict = |line: &str, status: i32| -> ! { verdict(line, status, &judge.resizes()) };
        if cfg!(target_os = "macos")
            && let Err(failure) = scenario.result()
        {
            verdict(&format!("window-contract: FAILED: {failure}"), 1);
        }
        #[cfg(target_os = "macos")]
        if let Err(failure) = terminate::all_answered() {
            verdict(&format!("window-contract: FAILED: {failure}"), 1);
        }
        if let Err(violation) = held {
            verdict(&format!("window-contract: FAILED: {violation}"), 1);
        }
        #[cfg(target_os = "macos")]
        if let Err(failure) = pending::judge() {
            verdict(&format!("window-contract: FAILED: {failure}"), 1);
        }
        verdict(
            "window-contract: the winit platform keeps the window port's contract",
            0,
        );
    });

    #[cfg(target_os = "macos")]
    check.run(&Probed {
        platform: &PLATFORM,
        record: Arc::default(),
        outcome,
        started: AtomicBool::new(false),
    });
    #[cfg(not(target_os = "macos"))]
    {
        drop(outcome);
        check.run(&PLATFORM);
    }
    // The run is over and the verdict is on its way.
    loop {
        thread::park();
    }
}
