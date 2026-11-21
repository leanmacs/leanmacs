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

use editor_ffi::events::{Event, EventKind, QueueId, RawEvent, editor_ffi_events_next};
use editor_ffi::log::RawWords;
use editor_ffi::text::editor_ffi_text_free;
use editor_ffi::window::{
    self, PlatformId, RawRefusal, SCRIPTED_FAILURE, SCRIPTED_NO_RENDERER, WINDOW_RAN,
    WINDOW_REFUSED, WINDOW_UNDRAWN, editor_ffi_input_clock_now, editor_ffi_window_asked,
    editor_ffi_window_await_parked, editor_ffi_window_close, editor_ffi_window_opened_with,
    editor_ffi_window_post_input, editor_ffi_window_request, editor_ffi_window_run,
};
use editor_platform::{Input, Key, LogicalKey, Modifiers, PhysicalKey, ScriptedPlatform};

/// hang guard: the next event on the editor queue, or the run's return;
/// only a hang reaches the bound, and the test then fails as a hang. Each wait on it is for something that should
/// happen at once.
const DEADLINE: Duration = Duration::from_secs(5);

/// hang guard: the scripted run parks to wait for its close
/// (`editor_ffi_window_await_parked`), in milliseconds; only a hang reaches the bound, and the test then fails as a hang.
const PARKS_MS: u64 = 5_000;

/// The tag of the editor queue.
const EDITOR: u8 = QueueId::Editor.tag();

/// The tag of the scripted platform.
const SCRIPTED: u8 = PlatformId::Scripted.tag();

/// The tag of the scripted platform that cannot open a window.
const SCRIPTED_FAILING: u8 = PlatformId::ScriptedFailing.tag();

/// The tag of the scripted platform whose window nothing can draw in.
const SCRIPTED_UNDRAWN: u8 = PlatformId::ScriptedUndrawn.tag();

/// A tag that names no platform.
const NO_PLATFORM: u8 = u8::MAX;

/// One event of the editor queue as the glue would read it: its source's
/// kind and id, its kind, its code, its text, its words and its stamp, the
/// kinds still the library's numbers.
#[derive(Debug, PartialEq, Eq)]
struct Seen {
    source_kind: u64,
    source_id: u64,
    kind: u64,
    code: u64,
    text: String,
    words: Vec<u64>,
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
        // SAFETY: as for the text, with the buffer of words.
        let words = unsafe { slice::from_raw_parts(raw.words, raw.words_len) }.to_vec();
        // SAFETY: as for the text.
        unsafe { editor_ffi_text_free(raw.words, raw.words_len) };
        let (words, rest) = words.as_chunks::<8>();
        assert!(rest.is_empty(), "an event's words are whole words");
        let _ = done.send(Seen {
            source_kind: raw.source_kind,
            source_id: raw.source_id,
            kind: raw.kind,
            code: raw.code,
            text: String::from_utf8(text).expect("an event's text is UTF-8"),
            words: words.iter().copied().map(u64::from_le_bytes).collect(),
            stamp: raw.stamp,
        });
    });
    result
        .recv_timeout(DEADLINE)
        .unwrap_or_else(|_| panic!("no event reached the editor queue within {DEADLINE:?}"))
}

/// Runs the window on the platform `platform` as the glue does: `Ok` when it
/// ran and closed, with why nothing drew in it when nothing did, and `Err`
/// with the reason when it did not run; each reason copied out of the
/// record and the buffer handed back.
fn run_blocking(platform: u8, composition: bool, title_bar: u8) -> Result<Option<String>, String> {
    let mut refusal = MaybeUninit::<RawRefusal>::uninit();
    // SAFETY: `refusal` is writable for one record. No present mode or
    // frame latency is asked for (0 and 0).
    let status = unsafe {
        editor_ffi_window_run(platform, composition, title_bar, 0, 0, refusal.as_mut_ptr())
    };
    if status == WINDOW_RAN {
        return Ok(None);
    }
    assert!(
        status == WINDOW_REFUSED || status == WINDOW_UNDRAWN,
        "{status} is no status of a run"
    );
    // SAFETY: the call did not return `WINDOW_RAN`, so it filled the record.
    let refusal = unsafe { refusal.assume_init() };
    // SAFETY: the record's buffer is `reason_len` bytes, owned by this caller
    // until it is handed back.
    let reason = unsafe { slice::from_raw_parts(refusal.reason, refusal.reason_len) }.to_vec();
    // SAFETY: the buffer came from the library in this record, and is handed
    // back once.
    unsafe { editor_ffi_text_free(refusal.reason, refusal.reason_len) };
    let reason = String::from_utf8(reason).expect("a reason is UTF-8");
    if status == WINDOW_UNDRAWN {
        Ok(Some(reason))
    } else {
        Err(reason)
    }
}

/// Starts [`run_blocking`] on a detached thread, with the themed title
/// bar, and returns where its result arrives.
fn run(platform: u8, composition: bool) -> Receiver<Result<Option<String>, String>> {
    run_with(platform, composition, THEMED)
}

/// Starts [`run_blocking`] on a detached thread, with the title bar tagged
/// `title_bar`, and returns where its result arrives.
fn run_with(
    platform: u8,
    composition: bool,
    title_bar: u8,
) -> Receiver<Result<Option<String>, String>> {
    let (finished, done) = mpsc::channel();
    thread::spawn(move || {
        let _ = finished.send(run_blocking(platform, composition, title_bar));
    });
    done
}

/// The tags of the themed and the standard title bar.
const THEMED: u8 = 0;
const STANDARD: u8 = 1;

/// What `editor_ffi_window_opened_with` writes for the platform tagged
/// `platform`: its status and its words.
fn opened_with(platform: u8) -> (u64, Vec<u64>) {
    // SAFETY: `out` is writable for one record.
    words_written(|out| unsafe { editor_ffi_window_opened_with(platform, out) })
}

/// What `editor_ffi_window_asked` writes for the platform tagged
/// `platform`: its status and its words.
fn asked(platform: u8) -> (u64, Vec<u64>) {
    // SAFETY: `out` is writable for one record.
    words_written(|out| unsafe { editor_ffi_window_asked(platform, out) })
}

/// The status and the words `write` writes into a record it is handed,
/// the buffer handed back.
fn words_written(write: impl FnOnce(*mut RawWords)) -> (u64, Vec<u64>) {
    let mut raw = MaybeUninit::<RawWords>::uninit();
    write(raw.as_mut_ptr());
    // SAFETY: `write` filled it.
    let raw = unsafe { raw.assume_init() };
    // SAFETY: the buffer is `len` bytes, owned here until handed back.
    let bytes = unsafe { slice::from_raw_parts(raw.words, raw.len) }.to_vec();
    // SAFETY: the buffer came from the library, and is handed back once.
    unsafe { editor_ffi_text_free(raw.words, raw.len) };
    let (words, rest) = bytes.as_chunks::<8>();
    assert!(rest.is_empty(), "whole words");
    (
        raw.status,
        words.iter().copied().map(u64::from_le_bytes).collect(),
    )
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
                words,
                ..
            } = window::event(input, 0);
            Seen {
                source_kind: source.kind.tag(),
                source_id: source.id,
                kind: kind.tag(),
                code,
                text,
                words,
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
        editor_ffi_window_await_parked(SCRIPTED, PARKS_MS),
        "the run goes on, waiting until the window is closed"
    );
    // What it was asked crosses with the close in its place: a minimise
    // asked before the close comes before it.
    assert!(editor_ffi_window_request(SCRIPTED, 2));
    assert!(editor_ffi_window_close(SCRIPTED));
    // The recording renderer drew in it: there is no reason to give.
    assert_eq!(done.recv_timeout(DEADLINE), Ok(Ok(None)));
    assert_eq!(asked(SCRIPTED), (0, vec![2, 8]));
    // Nothing runs now: a wait for a park can only run out.
    assert!(!editor_ffi_window_await_parked(SCRIPTED, 0));
    // A tag that names no scripted platform has no run to park, nor has
    // the one that cannot open a window: each says so at once.
    for platform in [NO_PLATFORM, PlatformId::Winit.tag(), SCRIPTED_FAILING] {
        assert!(!editor_ffi_window_await_parked(platform, PARKS_MS));
    }

    // Run with composition not allowed, no composition event arrives: the
    // flag reaches the platform.
    let done = run(SCRIPTED, false);
    let without = sample(false);
    assert!(without.len() < sample(true).len());
    assert_arrives(without);
    assert!(editor_ffi_window_close(SCRIPTED));
    assert_eq!(done.recv_timeout(DEADLINE), Ok(Ok(None)));

    // The scripted platform whose window nothing can draw in runs, reports
    // its sample and waits for its close all the same, and then says why
    // nothing drew.
    let done = run(SCRIPTED_UNDRAWN, true);
    assert_arrives(sample(true));
    assert!(editor_ffi_window_close(SCRIPTED_UNDRAWN));
    assert_eq!(
        done.recv_timeout(DEADLINE),
        Ok(Ok(Some(SCRIPTED_NO_RENDERER.to_owned())))
    );

    // The title bar asked reaches the platform: the scripted platform says
    // what its latest run was opened with, composition and the title
    // bar's tag. A tag that names no title bar is refused, and runs
    // nothing.
    assert_eq!(opened_with(SCRIPTED), (0, vec![0, THEMED.into()]));
    let done = run_with(SCRIPTED, true, STANDARD);
    assert_arrives(sample(true));
    assert_eq!(opened_with(SCRIPTED), (0, vec![1, STANDARD.into()]));
    assert!(editor_ffi_window_close(SCRIPTED));
    assert_eq!(done.recv_timeout(DEADLINE), Ok(Ok(None)));
    let refused = run_with(SCRIPTED, true, 2)
        .recv_timeout(DEADLINE)
        .expect("a refused run returns at once");
    assert!(refused.is_err_and(|reason| !reason.is_empty()));
    assert_eq!(opened_with(SCRIPTED), (0, vec![1, STANDARD.into()]));
    // The real platform records nothing, and a tag that names none is no
    // platform.
    assert_eq!(opened_with(PlatformId::Winit.tag()).0, 1);
    assert_eq!(opened_with(NO_PLATFORM).0, 1);

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
    assert_eq!(done.recv_timeout(DEADLINE), Ok(Ok(None)));

    // An input posted as a window would report it arrives on the editor
    // queue as the window's event, stamped on the input clock; malformed
    // words are refused and queue nothing.
    let key = Input::Key(Key {
        pressed: true,
        repeat: false,
        logical: LogicalKey::Named("Escape".into()),
        physical: PhysicalKey::Code("Escape".into()),
        modifiers: Modifiers {
            shift: true,
            ..Modifiers::default()
        },
        text: String::new(),
    });
    let posted = window::event(key, 0);
    let bytes: Vec<u8> = posted.words.iter().flat_map(|w| w.to_le_bytes()).collect();
    assert!(!post_input(EventKind::Key, posted.code, "", &bytes[..8]));
    assert!(!post_input(EventKind::Message, 0, "", &[]));
    assert!(post_input(EventKind::Key, posted.code, "", &bytes));
    assert_arrives(vec![Seen {
        source_kind: posted.source.kind.tag(),
        source_id: posted.source.id,
        kind: posted.kind.tag(),
        code: posted.code,
        text: String::new(),
        words: posted.words,
        stamp: 0,
    }]);

    // The input clock does not go back.
    let first = editor_ffi_input_clock_now();
    assert!(first <= editor_ffi_input_clock_now());
}

/// Posts an input to the editor queue through the C function, as the glue
/// does.
fn post_input(kind: EventKind, code: u64, text: &str, words: &[u8]) -> bool {
    // SAFETY: the pointers and lengths are those of `text` and `words`,
    // alive for the call.
    unsafe {
        editor_ffi_window_post_input(
            kind.tag() as u8,
            code,
            text.as_ptr(),
            text.len(),
            words.as_ptr(),
            words.len(),
        )
    }
}
