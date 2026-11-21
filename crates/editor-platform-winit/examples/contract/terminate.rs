//! The system's quit, asked of the running window on macOS as the system
//! asks it: `terminate:` on the application, as Command-Q's menu item
//! calls it, and the quit Apple Event (`kCoreEventClass`,
//! `kAEQuitApplication`), as the Dock and loginwindow send it.
//!
//! The scenario runs on a thread of its own once the window has said it
//! opened and how large it is, after the module `menu`'s, whose Quit item
//! left one `QuitRequested` reported: the counts below are of those
//! reported since. Each wait is bounded, and a scenario that does not see
//! what it should is a failure, with the reason:
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
//! 5. The scenario ends with that `terminate:` pending. The check's close
//!    comes with a `KeepRunning` asked just before it (`Probed::close`), as
//!    the editor's host asks one when its loop failed, so the close cancels
//!    the terminate instead of letting it go: the run returns, and the
//!    `terminate:` does too (`all_answered`, which the verdict waits on).
//!    A close with a terminate pending and no keep running ends the
//!    process instead, so it is the module `pending`'s, in a process of its
//!    own.
//!
//! Each step asks again only once the last ask has come back. AppKit lets
//! an answered `terminate:` go a few milliseconds after the reply, and an
//! ask made in between is taken for the terminate it is finishing: a quit
//! Apple Event is answered and dropped, and a `terminate:` ends the
//! process (both seen while this example was written).

use std::time::Duration;

use editor_platform::{Input, Platform, Request};
use editor_platform_winit::WinitPlatform;
use editor_platform_winit::probe;
use objc2::rc::Retained;
use objc2::runtime::{AnyClass, AnyObject, NSObject, Sel};
use objc2::{MainThreadMarker, MainThreadOnly, define_class, msg_send, sel};
use objc2_app_kit::NSApplication;
use objc2_foundation::{
    NSAppleEventDescriptor, NSAppleEventSendOptions, NSObjectNSThreadPerformAdditions,
};

use crate::{Count, Record};

/// hang guard: what each step waits for (a report, the loop carrying a
/// request out, an ask coming back); only a hang reaches the bound, and the
/// scenario then fails as a hang.
const STEP: Duration = Duration::from_secs(3);

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
static RETURNED: Count = Count::new();

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
            RETURNED.add();
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
                    RETURNED.add();
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
    let back = RETURNED.wait(count, STEP);
    if back < count {
        return Err(format!(
            "{after}: {back} of the system's asks came back, not {count}: no reply was made"
        ));
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

/// Waits until `count` quits have been reported, and then that no more
/// has been once the main queue has turned: a duplicate made in the turn
/// that reported the last is reported before that round trip returns.
pub fn reported(record: &Record, count: usize, after: &str) -> Result<(), String> {
    let seen = record.wait(STEP, |inputs| quits(inputs) >= count);
    if quits(&seen) < count {
        return Err(format!(
            "{after}: {} `QuitRequested` reported, not {count}",
            quits(&seen)
        ));
    }
    // A barrier, not a window: the main queue's round trip. A duplicate
    // AppKit asks of its own later still cannot be ruled out by any
    // barrier; that needs the loop's idle notification, follow-up
    // `platform-contract-settle-window-on-time`.
    dispatch2::run_on_main(|_| ());
    let seen = quits(&record.inputs());
    if seen != count {
        return Err(format!(
            "{after}: {seen} `QuitRequested` reported, not exactly {count}"
        ));
    }
    Ok(())
}

/// Asks for `text` as the window's title, waits until the loop has carried
/// out every request asked of it (`probe::await_requests_handled`), and
/// reads the title once: the loop handled the wake-up and the request.
fn titled(platform: &WinitPlatform, text: &str, after: &str) -> Result<(), String> {
    platform.request(Request::Title(text.into()));
    if !probe::await_requests_handled(platform, STEP) {
        return Err(format!(
            "{after}: the loop had not carried the title's request out {STEP:?} after it was asked"
        ));
    }
    let shown = title();
    if shown.as_deref() == Some(text) {
        return Ok(());
    }
    Err(format!(
        "{after}: the window's title is {shown:?}, not {text:?}: the loop did not carry the request out"
    ))
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

/// Runs the scenario on `platform`, whose report is `record`, which has
/// reported `base` quits already (the module `menu`'s).
pub fn scenario(platform: &WinitPlatform, record: &Record, base: usize) -> Result<(), String> {
    opened(record)?;

    terminate();
    reported(record, base + 1, "after `terminate:`")?;
    titled(
        platform,
        "window-contract: terminate pending",
        "with `terminate:` pending",
    )?;

    if RETURNED.get() != 0 {
        return Err("`terminate:` returned with no reply made".into());
    }

    platform.request(Request::KeepRunning);
    answered(1, "after keeping running")?;

    send_quit_event();
    reported(record, base + 2, "after the quit Apple Event")?;
    titled(
        platform,
        "window-contract: quit event pending",
        "with the quit Apple Event pending",
    )?;

    platform.request(Request::KeepRunning);
    answered(2, "after keeping running again")?;
    terminate();
    reported(record, base + 3, "after a third `terminate:`")?;

    if RETURNED.get() != 2 {
        return Err("the third `terminate:` returned with no reply made".into());
    }
    Ok(())
}

/// Once the run has returned: the third `terminate:`, left pending for the
/// check's close, has come back, so the close that came with a keep
/// running answered it, and cancelled it, since the process is still here.
pub fn all_answered() -> Result<(), String> {
    answered(3, "after the close with a keep running before it")
}
