//! A close with the system's quit pending, on macOS: AppKit ends the
//! process, with status 0, and only after the verdict was recorded.
//!
//! A close with a terminate pending ends the process inside the run, so the
//! run never returns and the check (`editor_platform::contract::Check`)
//! could not judge it. It is run in a process of its own: the contract
//! example starts itself again with [`ARGUMENT`], and [`judge`] takes what
//! that process came to. In it, with each wait bounded:
//!
//! 1. The window is run, with nothing around it, and a thread waits until it
//!    has said it opened and how large it is.
//! 2. `terminate:` is asked as the main scenario asks it, and is reported
//!    once: it is pending.
//! 3. The verdict is recorded, as the editor's host shuts down before it
//!    asks for the close, and then the close is asked.
//! 4. AppKit ends the process inside the run. The exit handler holds that
//!    the verdict was recorded before, that the drawer was told the window
//!    is closing, and that the run had not returned, so the end was
//!    AppKit's terminate and not `main`'s; it then prints [`LINE`].
//!    [`judge`] requires status 0 and that line.
//!
//! Any other end is status 1 with the reason: an exit before the verdict
//! (the exit handler), a run that returns (AppKit did not carry the
//! terminate through), a window that could not be opened, or a step that
//! did not see what it should. A process that never ends is killed at the
//! bound and fails.

use std::io::Read;
use std::process::{Command, Stdio, exit};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError, mpsc};
use std::thread;

use editor_platform::{Canvas, Drawer, Platform, Report, WindowOptions};

use editor_wait::HangGuard;

use crate::{BOUND, PLATFORM, Record, guard_exit, terminate};

/// The argument the contract example is started again with, to run this.
pub const ARGUMENT: &str = "--close-with-a-terminate-pending";

/// What the process prints when AppKit ended it as it should.
const LINE: &str =
    "window-contract: a close with the system's quit pending let AppKit end the process";

/// The verdict was recorded and the close asked: AppKit is to end the
/// process from here on.
static RECORDED: AtomicBool = AtomicBool::new(false);

/// The drawer was told the window is closing.
static CLOSING_TOLD: AtomicBool = AtomicBool::new(false);

/// The window's run returned.
static RETURNED: AtomicBool = AtomicBool::new(false);

/// A failure is ending the process.
static FAILED: AtomicBool = AtomicBool::new(false);

/// Prints why the process fails and ends it with status 1.
#[expect(
    clippy::disallowed_methods,
    reason = "the contract example ends the process with its verdict"
)]
fn fail(reason: &str) -> ! {
    FAILED.store(true, Ordering::SeqCst);
    println!("window-contract: FAILED: {reason}");
    exit(1);
}

/// Holds an end made by anything but [`fail`] to the rules in the module
/// docs: status 1 with the reason when it breaks one, otherwise [`LINE`],
/// with the status the end was made with.
extern "C" fn at_exit() {
    unsafe extern "C" {
        fn _exit(status: std::ffi::c_int) -> !;
    }
    if FAILED.load(Ordering::SeqCst) {
        return;
    }
    let broken = if !RECORDED.load(Ordering::SeqCst) {
        Some("the process was ended before the verdict was recorded")
    } else if RETURNED.load(Ordering::SeqCst) {
        Some("the process was ended after the run returned, not by AppKit's terminate")
    } else if !CLOSING_TOLD.load(Ordering::SeqCst) {
        Some("the process was ended before the drawer was told the window is closing")
    } else {
        None
    };
    match broken {
        Some(reason) => {
            println!("window-contract: FAILED: {reason}");
            // SAFETY: `_exit` ends the process at once, which is what is
            // meant, from inside `exit`'s handlers.
            unsafe { _exit(1) };
        }
        None => println!("{LINE}"),
    }
}

/// The process started with [`ARGUMENT`]: runs the window and the steps in
/// the module docs, and never returns.
pub fn main() -> ! {
    guard_exit(at_exit);
    let record = Arc::new(Record::default());
    let report: Report = {
        let record = Arc::clone(&record);
        Arc::new(move |input| record.push(input))
    };
    let drawer: Drawer = Arc::new(|canvas| {
        if matches!(canvas, Canvas::Closing) {
            CLOSING_TOLD.store(true, Ordering::SeqCst);
        }
    });
    thread::spawn(move || {
        if let Err(reason) = steps(&PLATFORM, &record) {
            fail(&reason);
        }
    });
    let ran = PLATFORM.run(WindowOptions::default(), report, drawer);
    RETURNED.store(true, Ordering::SeqCst);
    fail(&match ran {
        Ok(()) => "the run returned with the system's quit pending: AppKit did not end the process"
            .to_owned(),
        Err(cannot_open) => format!("no window could be opened: {}", cannot_open.reason),
    });
}

/// Steps 1 to 3, on `platform`, whose report is `record`.
fn steps(platform: &impl Platform, record: &Record) -> Result<(), String> {
    terminate::opened(record)?;
    terminate::terminate();
    terminate::reported(record, 1, "after `terminate:`")?;
    // The verdict, recorded before the close, as the editor's host shuts
    // down before it asks for one.
    RECORDED.store(true, Ordering::SeqCst);
    platform.close();
    Ok(())
}

/// Runs this in a process of its own and takes what it came to: status 0
/// and [`LINE`], within the bound.
///
/// A thread of its own reads what the process says to the end, which comes
/// when the process ends, then reaps it and sends both: the end is waited
/// for on that event, and a process that never ends is killed at the
/// bound. The child is shared under a lock the reader takes only once the
/// output has ended, so the kill finds it free.
#[expect(
    clippy::disallowed_methods,
    reason = "the example judges a run of itself, a real child process it starts"
)]
pub fn judge() -> Result<(), String> {
    let program = std::env::current_exe()
        .map_err(|error| format!("the example's own path could not be read: {error}"))?;
    let mut child = Command::new(program)
        .arg(ARGUMENT)
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|error| {
            format!("the process with a terminate pending was not started: {error}")
        })?;
    let stdout = child.stdout.take();
    let child = Arc::new(Mutex::new(child));
    let (ended, end) = mpsc::channel();
    {
        let child = Arc::clone(&child);
        thread::spawn(move || {
            let mut said = String::new();
            if let Some(mut stdout) = stdout {
                let _ = stdout.read_to_string(&mut said);
            }
            let status = child.lock().unwrap_or_else(PoisonError::into_inner).wait();
            let _ = ended.send((status, said));
        });
    }
    // hang guard: the process's end, which closes its output and is then
    // reaped; only a hang reaches the bound, and the check then fails as a
    // hang.
    let guard = HangGuard::on(
        "the end of the process with a terminate pending",
        BOUND.bound() + BOUND.bound(),
    );
    let Ok((status, said)) = editor_wait::recv(&end, guard) else {
        let mut child = child.lock().unwrap_or_else(PoisonError::into_inner);
        let _ = child.kill();
        let _ = child.wait();
        return Err(guard.hang());
    };
    let status =
        status.map_err(|error| format!("the process with a terminate pending: {error}"))?;
    if status.code() == Some(0) && said.lines().any(|line| line == LINE) {
        Ok(())
    } else {
        Err(format!(
            "the process with a terminate pending ended with {status} and said {:?}",
            said.trim()
        ))
    }
}
