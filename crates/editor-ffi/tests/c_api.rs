//! The C functions over the counter, the event queues and `find`, called the
//! way the C glue calls them: with raw pointers, lengths and tags.
//!
//! This is an integration test because the functions work on state the whole
//! process shares (the count of live counters, the two queues), and an
//! integration test is its own process. Each piece of that state belongs to
//! one test function, so the harness running them in parallel cannot make one
//! disturb another.

use std::mem::MaybeUninit;
use std::slice;
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use editor_ffi::counter::{
    editor_ffi_counter_free, editor_ffi_counter_increment, editor_ffi_counter_live,
    editor_ffi_counter_new,
};
use editor_ffi::events::{
    Event, EventKind, QueueId, RawEvent, Source, SourceKind, editor_ffi_events_next,
    editor_ffi_events_post, editor_ffi_events_quit, editor_ffi_events_script_feed,
    editor_ffi_events_waiting,
};
use editor_ffi::text::{ByteRange, editor_ffi_text_find, editor_ffi_text_free};

/// How long a test waits for something that should happen at once. Only
/// broken code takes this long, and the test then fails instead of hanging.
const DEADLINE: Duration = Duration::from_secs(5);

/// The tag of the editor queue.
const EDITOR: u8 = QueueId::Editor.tag();

/// The tag of the completion queue.
const COMPLETION: u8 = QueueId::Completion.tag();

/// A tag that names no queue.
const NO_QUEUE: u8 = 2;

/// A message event from the source `kind`/`id`, as it should arrive.
fn message(kind: SourceKind, id: u64, code: u64, text: &str) -> Event {
    Event::message(Source { kind, id }, code, text)
}

/// Posts a message to the queue `queue` and returns whether it was accepted.
fn post(queue: u8, source_id: u64, code: u64, text: &str) -> bool {
    // SAFETY: the pointer and length are those of `text`, alive for the call.
    unsafe { editor_ffi_events_post(queue, source_id, code, text.as_ptr(), text.len()) }
}

/// One blocking pull from the queue `queue`, as the glue does it: fill the
/// record, copy the text, hand the buffer back, decode the tags. `None` if
/// the library refused the queue tag.
fn next_blocking(queue: u8) -> Option<Event> {
    let mut raw = MaybeUninit::<RawEvent>::uninit();
    // SAFETY: `raw` is writable for one record.
    if !unsafe { editor_ffi_events_next(queue, raw.as_mut_ptr()) } {
        return None;
    }
    // SAFETY: the call returned true, so it filled the record.
    let raw = unsafe { raw.assume_init() };
    // SAFETY: the record's buffer is `text_len` bytes, owned by this caller
    // until it is handed back.
    let text = unsafe { slice::from_raw_parts(raw.text, raw.text_len) }.to_vec();
    // SAFETY: the buffer came from the library in this record, and is handed
    // back once.
    unsafe { editor_ffi_text_free(raw.text, raw.text_len) };
    Some(Event {
        source: Source {
            kind: SourceKind::from_tag(raw.source_kind).expect("a known source kind"),
            id: raw.source_id,
        },
        kind: EventKind::from_tag(raw.kind).expect("a known event kind"),
        code: raw.code,
        text: String::from_utf8(text).expect("an event's text is UTF-8"),
    })
}

/// What `call` returns, run on a detached thread so a call that never
/// returns fails the test at the deadline instead of hanging it.
fn within_deadline<T: Send + 'static>(what: &str, call: impl FnOnce() -> T + Send + 'static) -> T {
    let (done, result) = mpsc::channel();
    thread::spawn(move || {
        let _ = done.send(call());
    });
    result
        .recv_timeout(DEADLINE)
        .unwrap_or_else(|_| panic!("{what} did not return within {DEADLINE:?}"))
}

/// One pull from the queue `queue`, bounded by the deadline.
fn next(queue: u8) -> Option<Event> {
    within_deadline("a pull", move || next_blocking(queue))
}

/// Waits until `pulls` pulls are parked on the queue `queue`; panics if they
/// are not by the deadline.
fn wait_for_parked(queue: u8, pulls: u64) {
    let deadline = Instant::now() + DEADLINE;
    while editor_ffi_events_waiting(queue) != pulls {
        assert!(
            Instant::now() < deadline,
            "{pulls} pulls were not parked on queue {queue} after {DEADLINE:?}"
        );
        thread::sleep(Duration::from_millis(1));
    }
}

/// `editor_ffi_text_find` over string slices; `None` when it returns false.
fn find(haystack: &str, needle: &str, start: Option<usize>) -> Option<(u64, u64)> {
    let mut range = MaybeUninit::<ByteRange>::uninit();
    // SAFETY: the pointers and lengths are those of the two slices, and
    // `range` is writable for one record.
    let found = unsafe {
        editor_ffi_text_find(
            haystack.as_ptr(),
            haystack.len(),
            needle.as_ptr(),
            needle.len(),
            start.is_some(),
            start.unwrap_or(usize::MAX),
            range.as_mut_ptr(),
        )
    };
    // SAFETY: the call returned true, so it filled the record.
    found
        .then(|| unsafe { range.assume_init() })
        .map(|range| (range.start, range.end))
}

#[test]
fn a_counter_is_live_from_new_until_free() {
    let before = editor_ffi_counter_live();

    let counter = editor_ffi_counter_new(40);
    assert_eq!(editor_ffi_counter_live(), before + 1);
    // SAFETY: `counter` came from `editor_ffi_counter_new` and is not freed.
    assert_eq!(unsafe { editor_ffi_counter_increment(counter) }, 41);
    // SAFETY: as above.
    assert_eq!(unsafe { editor_ffi_counter_increment(counter) }, 42);

    let other = editor_ffi_counter_new(0);
    assert_eq!(editor_ffi_counter_live(), before + 2);

    // SAFETY: `counter` came from `editor_ffi_counter_new`, and this is the
    // one time it is freed.
    unsafe { editor_ffi_counter_free(counter) };
    assert_eq!(editor_ffi_counter_live(), before + 1);
    // SAFETY: `other` came from `editor_ffi_counter_new` and is not freed.
    assert_eq!(unsafe { editor_ffi_counter_increment(other) }, 1);

    // SAFETY: `other` came from `editor_ffi_counter_new`, and this is the
    // one time it is freed.
    unsafe { editor_ffi_counter_free(other) };
    assert_eq!(editor_ffi_counter_live(), before);
}

#[test]
fn find_fills_the_range_it_found_and_reports_whether_it_found_one() {
    assert_eq!(find("héllo wörld, hello", "llo", None), Some((3, 6)));
    assert_eq!(find("héllo wörld, hello", "llo", Some(4)), Some((17, 20)));
    assert_eq!(find("héllo wörld, hello", "zzz", None), None);
    assert_eq!(find("héllo wörld, hello", "llo", Some(2)), None);
}

/// The whole life of the two process-wide queues, in order, because quit is
/// for good.
#[test]
fn the_process_wide_queues_carry_events_until_they_are_quit() {
    // A post is pulled back from the queue it went to, whole.
    assert!(post(EDITOR, 7, 42, "héllo\0wörld"));
    assert!(post(EDITOR, 8, u64::MAX, ""));
    assert_eq!(
        next(EDITOR),
        Some(message(SourceKind::Lean, 7, 42, "héllo\0wörld"))
    );
    assert_eq!(
        next(EDITOR),
        Some(message(SourceKind::Lean, 8, u64::MAX, ""))
    );

    // A pull parks on its own queue, and a post to that queue wakes it.
    let (done, parked) = mpsc::channel();
    thread::spawn(move || {
        let _ = done.send(next_blocking(COMPLETION));
    });
    wait_for_parked(COMPLETION, 1);
    assert_eq!(editor_ffi_events_waiting(EDITOR), 0);
    assert!(post(COMPLETION, 1, 2, "wake"));
    assert_eq!(
        parked
            .recv_timeout(DEADLINE)
            .expect("the parked pull returns"),
        Some(message(SourceKind::Lean, 1, 2, "wake"))
    );

    // A scripted feed arrives in order, from the script source asked for.
    assert!(editor_ffi_events_script_feed(COMPLETION, 9, 3));
    for code in 0..3 {
        let event = next(COMPLETION).expect("the completion queue exists");
        let source = Source {
            kind: SourceKind::Script,
            id: 9,
        };
        assert_eq!((event.source, event.kind), (source, EventKind::Message));
        assert_eq!(event.code, code);
    }

    // A tag that names no queue is refused, not acted on.
    assert!(!post(NO_QUEUE, 1, 1, "nowhere"));
    assert_eq!(next(NO_QUEUE), None);
    assert!(!editor_ffi_events_script_feed(NO_QUEUE, 1, 1));
    assert_eq!(editor_ffi_events_waiting(NO_QUEUE), 0);

    // Quit reaches both queues, after what was already queued.
    assert!(post(EDITOR, 7, 1, "before quit"));
    editor_ffi_events_quit();
    assert_eq!(
        next(EDITOR),
        Some(message(SourceKind::Lean, 7, 1, "before quit"))
    );
    assert_eq!(next(EDITOR), Some(Event::quit()));
    assert_eq!(next(COMPLETION), Some(Event::quit()));
    assert_eq!(next(COMPLETION), Some(Event::quit()));
    assert!(!post(EDITOR, 7, 2, "after quit"));

    // A feed of any length returns at once: the script is not built before
    // the thread starts. The queue is quit, so the feeder stops at its first
    // push and nothing is queued.
    assert!(within_deadline("a feed of the longest script", || {
        editor_ffi_events_script_feed(COMPLETION, 9, u64::MAX)
    }));
    assert_eq!(next(COMPLETION), Some(Event::quit()));
}
