//! The system's quit, asked of the running window on macOS as the system
//! asks it: `terminate:` on the application, as Command-Q's menu item
//! calls it, and the quit Apple Event (`kCoreEventClass`,
//! `kAEQuitApplication`), as the Dock and loginwindow send it.
//!
//! The scenario runs on a thread of its own once the window has said it
//! opened and how large it is. Each wait is bounded, and a scenario that
//! does not see what it should is a failure, with the reason:
//!
//! 1. `terminate:`, performed on the main thread from a run-loop source,
//!    not from a main-queue block: a run loop nested inside a main-queue
//!    block keeps the main queue from draining, and the title is read back
//!    through that queue. The report then has exactly one `QuitRequested`,
//!    and a title asked is carried out, read back from the window: the loop
//!    still handles a wake-up and a request while AppKit waits inside
//!    `terminate:` for the reply. `terminate:` has not returned, and the
//!    process is still running, since this thread is in it.
//! 2. `KeepRunning`, then `terminate:` returns: the reply was made.
//! 3. The quit Apple Event, sent to this process, from the main thread as
//!    step 1's `terminate:` is: the Apple Event Manager hands an event sent
//!    to its own process straight to the handler on the sending thread, and
//!    AppKit's handler calls `terminate:`. Exactly one more
//!    `QuitRequested`, and a title read back.
//! 4. `KeepRunning`, then the send returns; then a third `terminate:`,
//!    which is reported again: a terminate still pending would not be.
//! 5. `KeepRunning`, then that `terminate:` returns. The scenario ends with
//!    nothing pending, and the check's close then ends the run, which
//!    returns. A close with a terminate pending ends the process instead,
//!    so it is the module `pending`'s, in a process of its own.
//!
//! Each step asks again only once the last ask has come back. AppKit lets
//! an answered `terminate:` go a few milliseconds after the reply, and an
//! ask made in between is taken for the terminate it is finishing: a quit
//! Apple Event is answered and dropped, and a `terminate:` ends the
//! process (both seen while this example was written).

use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use editor_platform::{Input, Platform, Request};
use objc2::rc::Retained;
use objc2::runtime::{AnyClass, AnyObject, NSObject, Sel};
use objc2::{MainThreadMarker, MainThreadOnly, define_class, msg_send, sel};
use objc2_app_kit::NSApplication;
use objc2_foundation::{
    NSAppleEventDescriptor, NSAppleEventSendOptions, NSObjectNSThreadPerformAdditions,
};

use crate::Record;

/// How long each step waits for what it should see.
const STEP: Duration = Duration::from_secs(3);

/// How long a step waits to see that nothing more is reported.
const SETTLE: Duration = Duration::from_millis(200);

/// `kCoreEventClass`, `'aevt'`.
const CORE_EVENT_CLASS: u32 = u32::from_be_bytes(*b"aevt");

/// `kAEQuitApplication`, `'quit'`.
const QUIT_APPLICATION: u32 = u32::from_be_bytes(*b"quit");

/// `kAutoGenerateReturnID`.
const AUTO_GENERATE_RETURN_ID: i16 = -1;

/// `kAnyTransactionID`.
const ANY_TRANSACTION_ID: i32 = 0;

/// How many of the system's asks have come back: each `terminate:` the
/// scenario made has returned, and so has each quit Apple Event it sent.
/// AppKit waits in `terminate:` until the reply, so this counts the asks
/// that were answered and let go.
static RETURNED: AtomicUsize = AtomicUsize::new(0);

define_class!(
    /// What asks the application to quit as the system does, on the main
    /// thread, and counts each ask that comes back ([`RETURNED`]).
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "EditorPlatformWinitContractAsker"]
    struct Asker;

    impl Asker {
        /// `terminate:` on the application, as the Quit menu item calls it.
        #[unsafe(method(terminate:))]
        fn terminate(&self, _: Option<&AnyObject>) {
            NSApplication::sharedApplication(self.mtm()).terminate(None);
            RETURNED.fetch_add(1, Ordering::SeqCst);
        }

        /// Sends this process the quit Apple Event, with no reply asked.
        /// The Apple Event Manager hands an event sent to its own process
        /// to the handler at once, so this returns once AppKit's handler
        /// has, which is once the `terminate:` it makes has.
        #[unsafe(method(sendQuit:))]
        fn send_quit(&self, _: Option<&AnyObject>) {
            let class = AnyClass::get(c"NSAppleEventDescriptor")
                .expect("Foundation defines NSAppleEventDescriptor");
            let pid = i32::try_from(std::process::id()).expect("a pid is a pid_t");
            // SAFETY: `descriptorWithProcessIdentifier:` takes a `pid_t`
            // (an `i32`) and returns a descriptor, autoreleased. The typed
            // binding needs the crate's `libc` feature, which would add an
            // edge to the graph.
            let target: Retained<NSAppleEventDescriptor> =
                unsafe { msg_send![class, descriptorWithProcessIdentifier: pid] };
            // SAFETY: the selector is `NSAppleEventDescriptor`'s class
            // method, whose arguments are `AEEventClass` and `AEEventID`
            // (`FourCharCode`, a `u32`), a descriptor, `AEReturnID` (an
            // `i16`) and `AETransactionID` (an `i32`); it returns a
            // descriptor, autoreleased. The typed binding needs the crate's
            // `objc2-core-services` feature, for those four types.
            let event: Retained<NSAppleEventDescriptor> = unsafe {
                msg_send![
                    class,
                    appleEventWithEventClass: CORE_EVENT_CLASS,
                    eventID: QUIT_APPLICATION,
                    targetDescriptor: &*target,
                    returnID: AUTO_GENERATE_RETURN_ID,
                    transactionID: ANY_TRANSACTION_ID
                ]
            };
            match event.sendEventWithOptions_timeout_error(NSAppleEventSendOptions::NoReply, 30.0) {
                Ok(_) => {
                    RETURNED.fetch_add(1, Ordering::SeqCst);
                }
                Err(error) => {
                    eprintln!("window-contract: the quit Apple Event was not sent: {error}");
                }
            }
        }
    }
);

/// Performs `selector` of a new [`Asker`] on the main thread, from the
/// run loop, and returns at once.
fn ask(selector: Sel) {
    dispatch2::run_on_main(|mtm| {
        let this = Asker::alloc(mtm).set_ivars(());
        // SAFETY: `init` is `NSObject`'s initialiser, called once on the
        // allocation.
        let asker: Retained<Asker> = unsafe { msg_send![super(this), init] };
        // SAFETY: each of the asker's selectors takes one object argument,
        // which may be nil. The target is retained until it is performed.
        unsafe {
            asker.performSelectorOnMainThread_withObject_waitUntilDone(selector, None, false)
        };
    });
}

/// `terminate:`, from the run loop.
pub fn terminate() {
    ask(sel!(terminate:));
}

/// The quit Apple Event, from the run loop.
fn send_quit_event() {
    ask(sel!(sendQuit:));
}

/// Waits until `count` asks have come back: the reply was made, and AppKit
/// has let the ask go. A step asks the next only after that: an ask made
/// in the few milliseconds between the reply and AppKit's letting go is
/// taken for the terminate it is finishing.
fn answered(count: usize, after: &str) -> Result<(), String> {
    let deadline = Instant::now() + STEP;
    while RETURNED.load(Ordering::SeqCst) < count {
        if Instant::now() >= deadline {
            return Err(format!(
                "{after}: {} of the system's asks came back, not {count}: no reply was made",
                RETURNED.load(Ordering::SeqCst)
            ));
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    Ok(())
}

/// The title of the application's first window, read on the main thread.
fn title() -> Option<String> {
    dispatch2::run_on_main(|mtm: MainThreadMarker| {
        NSApplication::sharedApplication(mtm)
            .windows()
            .firstObject()
            .map(|window| window.title().to_string())
    })
}

/// How many times the system's quit has been reported.
fn quits(inputs: &[Input]) -> usize {
    inputs
        .iter()
        .filter(|input| **input == Input::QuitRequested)
        .count()
}

/// Waits until exactly `count` quits have been reported, and no more a
/// moment later.
pub fn reported(record: &Record, count: usize, after: &str) -> Result<(), String> {
    let seen = record.wait(STEP, |inputs| quits(inputs) >= count);
    if quits(&seen) < count {
        return Err(format!(
            "{after}: {} `QuitRequested` reported, not {count}",
            quits(&seen)
        ));
    }
    std::thread::sleep(SETTLE);
    let seen = quits(&record.inputs());
    if seen != count {
        return Err(format!(
            "{after}: {seen} `QuitRequested` reported, not exactly {count}"
        ));
    }
    Ok(())
}

/// Asks for `text` as the window's title and waits until the window shows
/// it: the loop handled the wake-up and the request.
fn titled(platform: &impl Platform, text: &str, after: &str) -> Result<(), String> {
    platform.request(Request::Title(text.into()));
    let deadline = Instant::now() + STEP;
    loop {
        let shown = title();
        if shown.as_deref() == Some(text) {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "{after}: the window's title is {shown:?}, not {text:?}: the loop did not carry the request out"
            ));
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Waits until the window has said it opened and how large it is.
pub fn opened(record: &Record) -> Result<(), String> {
    let ready = |inputs: &[Input]| {
        matches!(inputs.first(), Some(Input::Opened { .. }))
            && inputs
                .iter()
                .any(|input| matches!(input, Input::Resized(_)))
    };
    if ready(&record.wait(STEP, ready)) {
        Ok(())
    } else {
        Err("the window did not say it opened and how large it is".into())
    }
}

/// Runs the scenario on `platform`, whose report is `record`.
pub fn scenario(platform: &impl Platform, record: &Record) -> Result<(), String> {
    opened(record)?;

    terminate();
    reported(record, 1, "after `terminate:`")?;
    titled(
        platform,
        "window-contract: terminate pending",
        "with `terminate:` pending",
    )?;

    if RETURNED.load(Ordering::SeqCst) != 0 {
        return Err("`terminate:` returned with no reply made".into());
    }

    platform.request(Request::KeepRunning);
    answered(1, "after keeping running")?;

    send_quit_event();
    reported(record, 2, "after the quit Apple Event")?;
    titled(
        platform,
        "window-contract: quit event pending",
        "with the quit Apple Event pending",
    )?;

    platform.request(Request::KeepRunning);
    answered(2, "after keeping running again")?;
    terminate();
    reported(record, 3, "after a third `terminate:`")?;

    platform.request(Request::KeepRunning);
    answered(3, "after keeping running a third time")
}
