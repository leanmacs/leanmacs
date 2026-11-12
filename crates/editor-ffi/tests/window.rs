//! The C functions over the process's window, called the way the C glue
//! calls them, with what the window reports pulled from the process's editor
//! queue.
//!
//! This is an integration test of its own, not part of `tests/c_api.rs`,
//! because the window reports on the process-wide editor queue and that test
//! quits the queues. It is one test function, so nothing else in this
//! process touches the queue or the window.
//!
//! Every window here is the scripted platform's: nothing opens and no
//! display is needed. No thread serves the main-thread service in this
//! process, so a run is answered on the thread that asks for it.

use std::mem::MaybeUninit;
use std::slice;
use std::sync::mpsc::{self, Receiver};
use std::thread;
use std::time::Duration;

use editor_ffi::events::{Event, QueueId, RawEvent, editor_ffi_events_next};
use editor_ffi::text::editor_ffi_text_free;
use editor_ffi::window::{
    self, PlatformId, RawRefusal, SCRIPTED_FAILURE, editor_ffi_input_clock_now,
    editor_ffi_window_close, editor_ffi_window_run,
};
use editor_platform::{Input, ScriptedPlatform};

/// How long the test waits for something that should happen at once. Only
/// broken code takes this long, and the test then fails instead of hanging.
const DEADLINE: Duration = Duration::from_secs(5);

/// How long the test waits to see that something does not happen.
const SETTLE: Duration = Duration::from_millis(20);

/// The tag of the editor queue.
const EDITOR: u8 = QueueId::Editor.tag();

/// The tag of the scripted platform.
const SCRIPTED: u8 = PlatformId::Scripted.tag();

/// The tag of the scripted platform that cannot open a window.
const SCRIPTED_FAILING: u8 = PlatformId::ScriptedFailing.tag();

/// A tag that names no platform.
const NO_PLATFORM: u8 = u8::MAX;

/// One event of the editor queue as the glue would read it: its source's
/// kind and id, its kind, its code, its text and its stamp, the kinds still
/// the library's numbers.
#[derive(Debug, PartialEq, Eq)]
struct Seen {
    source_kind: u64,
    source_id: u64,
    kind: u64,
    code: u64,
    text: String,
    stamp: u64,
}

/// One pull from the editor queue, bounded by the deadline: the pull runs on
/// a detached thread, so one that never returns fails the test instead of
/// hanging it.
fn next_event() -> Seen {
    let (done, result) = mpsc::channel();
    thread::spawn(move || {
        let mut raw = MaybeUninit::<RawEvent>::uninit();
        // SAFETY: `raw` is writable for one record.
        assert!(unsafe { editor_ffi_events_next(EDITOR, raw.as_mut_ptr()) });
        // SAFETY: the call returned true, so it filled the record.
        let raw = unsafe { raw.assume_init() };
        // SAFETY: the record's buffer is `text_len` bytes, owned by this
        // caller until it is handed back.
        let text = unsafe { slice::from_raw_parts(raw.text, raw.text_len) }.to_vec();
        // SAFETY: the buffer came from the library in this record, and is
        // handed back once.
        unsafe { editor_ffi_text_free(raw.text, raw.text_len) };
        let _ = done.send(Seen {
            source_kind: raw.source_kind,
            source_id: raw.source_id,
            kind: raw.kind,
            code: raw.code,
            text: String::from_utf8(text).expect("an event's text is UTF-8"),
            stamp: raw.stamp,
        });
    });
    result
        .recv_timeout(DEADLINE)
        .unwrap_or_else(|_| panic!("no event reached the editor queue within {DEADLINE:?}"))
}

/// Runs the window on the platform `platform` as the glue does: `Ok` when it
/// ran and closed, and otherwise the reason, copied out of the record and
/// the buffer handed back.
fn run_blocking(platform: u8, composition: bool) -> Result<(), String> {
    let mut refusal = MaybeUninit::<RawRefusal>::uninit();
    // SAFETY: `refusal` is writable for one record.
    if unsafe { editor_ffi_window_run(platform, composition, refusal.as_mut_ptr()) } {
        return Ok(());
    }
    // SAFETY: the call returned false, so it filled the record.
    let refusal = unsafe { refusal.assume_init() };
    // SAFETY: the record's buffer is `reason_len` bytes, owned by this caller
    // until it is handed back.
    let reason = unsafe { slice::from_raw_parts(refusal.reason, refusal.reason_len) }.to_vec();
    // SAFETY: the buffer came from the library in this record, and is handed
    // back once.
    unsafe { editor_ffi_text_free(refusal.reason, refusal.reason_len) };
    Err(String::from_utf8(reason).expect("a reason is UTF-8"))
}

/// Starts [`run_blocking`] on a detached thread and returns where its result
/// arrives.
fn run(platform: u8, composition: bool) -> Receiver<Result<(), String>> {
    let (finished, done) = mpsc::channel();
    thread::spawn(move || {
        let _ = finished.send(run_blocking(platform, composition));
    });
    done
}

/// What the scripted platform's window reports with composition allowed or
/// not, as the events the library makes of it, without their stamps.
fn sample(composition: bool) -> Vec<Seen> {
    let opened = Input::Opened {
        platform: ScriptedPlatform::NAME.into(),
    };
    std::iter::once(opened)
        .chain(ScriptedPlatform::sample_script())
        .filter(|input| composition || !matches!(input, Input::Composition(_)))
        .map(|input| {
            let Event {
                source,
                kind,
                code,
                text,
                ..
            } = window::event(input, 0);
            Seen {
                source_kind: source.kind.tag(),
                source_id: source.id,
                kind: kind.tag(),
                code,
                text,
                stamp: 0,
            }
        })
        .collect()
}

/// Pulls as many events as `expected` has and checks that they are those,
/// in order, each with a stamp that is set, not before the one before it and
/// not after the clock's reading once it was pulled.
fn assert_arrives(expected: Vec<Seen>) {
    let mut last = 0;
    for expected in expected {
        let seen = next_event();
        let pulled_at = editor_ffi_input_clock_now();
        assert!(seen.stamp > 0, "{seen:?} has a stamp");
        assert!(last <= seen.stamp, "{seen:?} is stamped after {last}");
        assert!(
            seen.stamp <= pulled_at,
            "{seen:?} was stamped before it was pulled at {pulled_at}"
        );
        last = seen.stamp;
        assert_eq!(Seen { stamp: 0, ..seen }, expected);
    }
}

/// The whole life of the process's window, in order.
#[test]
fn the_process_wide_window_reports_on_the_editor_queue_until_it_is_closed() {
    // A tag that names no platform is refused with a reason, at once.
    let refused = run(NO_PLATFORM, true)
        .recv_timeout(DEADLINE)
        .expect("a refused run returns at once");
    assert!(refused.is_err_and(|reason| !reason.is_empty()));
    assert!(!editor_ffi_window_close(NO_PLATFORM));

    // A close with no window running does nothing: the run below still
    // waits for a close of its own.
    assert!(editor_ffi_window_close(SCRIPTED));

    // The scripted platform's sample arrives on the editor queue, in order,
    // and the run returns only after the close.
    let done = run(SCRIPTED, true);
    assert_arrives(sample(true));
    assert!(
        done.recv_timeout(SETTLE).is_err(),
        "the run goes on until the window is closed"
    );
    assert!(editor_ffi_window_close(SCRIPTED));
    assert_eq!(done.recv_timeout(DEADLINE), Ok(Ok(())));

    // Run with composition not allowed, no composition event arrives: the
    // flag reaches the platform.
    let done = run(SCRIPTED, false);
    let without = sample(false);
    assert!(without.len() < sample(true).len());
    assert_arrives(without);
    assert!(editor_ffi_window_close(SCRIPTED));
    assert_eq!(done.recv_timeout(DEADLINE), Ok(Ok(())));

    // The scripted platform that cannot open a window is refused with its
    // reason, at once and on every run, and a close of it does nothing.
    for _ in 0..2 {
        let refused = run(SCRIPTED_FAILING, true)
            .recv_timeout(DEADLINE)
            .expect("a run that cannot open returns at once");
        assert_eq!(refused, Err(SCRIPTED_FAILURE.to_owned()));
        assert!(editor_ffi_window_close(SCRIPTED_FAILING));
    }

    // The failed runs queued nothing: a window that runs next reports its
    // own sample first.
    let done = run(SCRIPTED, true);
    assert_arrives(sample(true));
    assert!(editor_ffi_window_close(SCRIPTED));
    assert_eq!(done.recv_timeout(DEADLINE), Ok(Ok(())));

    // The input clock does not go back.
    let first = editor_ffi_input_clock_now();
    assert!(first <= editor_ffi_input_clock_now());
}
