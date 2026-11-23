//! The C functions over the counter, the document, the event queues and
//! `find`, called the way the C glue calls them: with raw pointers, lengths
//! and tags.
//!
//! This is an integration test because the functions work on state the whole
//! process shares (the counts of live counters and of live documents, the two
//! queues), and an integration test is its own process. Each piece of that
//! state belongs to one test function, so the harness running them in
//! parallel cannot make one disturb another.

use std::mem::MaybeUninit;
use std::slice;
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use editor_wait::HangGuard;

use editor_ffi::counter::{
    Counter, editor_ffi_counter_free, editor_ffi_counter_increment, editor_ffi_counter_live,
    editor_ffi_counter_new,
};
use editor_ffi::document::{
    Document, RawText, ReplaceStatus, editor_ffi_document_free, editor_ffi_document_live,
    editor_ffi_document_new, editor_ffi_document_read, editor_ffi_document_replace,
};
use editor_ffi::events::{
    Event, EventKind, QueueId, RawEvent, Source, SourceKind, editor_ffi_events_await_waiting,
    editor_ffi_events_next, editor_ffi_events_post, editor_ffi_events_quit,
    editor_ffi_events_script_feed, editor_ffi_events_script_join, editor_ffi_events_waiting,
};
use editor_ffi::live::{COUNTERS, DOCUMENTS, editor_ffi_live_await};
use editor_ffi::text::{ByteRange, editor_ffi_text_find, editor_ffi_text_free};

/// hang guard: the event each wait here ends on; only a hang reaches the
/// bound, and the test then fails as a hang. How long a test waits for
/// something that should happen at once: only broken code takes this long.
const DEADLINE: HangGuard =
    HangGuard::on("the event each wait here ends on", Duration::from_secs(5));

/// hang guard: as [`DEADLINE`], in milliseconds, as the C functions take
/// it.
const DEADLINE_MS: u64 = 5000;

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
    post_bytes(queue, source_id, code, text.as_bytes())
}

/// [`post`] with text given as bytes, which need not be UTF-8.
fn post_bytes(queue: u8, source_id: u64, code: u64, text: &[u8]) -> bool {
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
    // SAFETY: the record's buffer of words is `words_len` bytes, owned by
    // this caller until it is handed back.
    let words = unsafe { slice::from_raw_parts(raw.words, raw.words_len) }.to_vec();
    // SAFETY: as for the text.
    unsafe { editor_ffi_text_free(raw.words, raw.words_len) };
    let (words, rest) = words.as_chunks::<8>();
    assert!(rest.is_empty(), "an event's words are whole words");
    Some(Event {
        source: Source {
            kind: SourceKind::from_tag(raw.source_kind).expect("a known source kind"),
            id: raw.source_id,
        },
        kind: EventKind::from_tag(raw.kind).expect("a known event kind"),
        code: raw.code,
        text: String::from_utf8(text).expect("an event's text is UTF-8"),
        words: words.iter().copied().map(u64::from_le_bytes).collect(),
        stamp: raw.stamp,
    })
}

/// What `call` returns, run on a detached thread so a call that never
/// returns fails the test at the deadline instead of hanging it.
fn within_deadline<T: Send + 'static>(what: &str, call: impl FnOnce() -> T + Send + 'static) -> T {
    let (done, result) = mpsc::channel();
    thread::spawn(move || {
        let _ = done.send(call());
    });
    editor_wait::recv(&result, DEADLINE)
        .unwrap_or_else(|_| panic!("{what} did not return: {DEADLINE}"))
}

/// One pull from the queue `queue`, bounded by the deadline.
fn next(queue: u8) -> Option<Event> {
    within_deadline("a pull", move || next_blocking(queue))
}

/// Waits until `pulls` pulls are parked on the queue `queue`, on the park
/// itself (`editor_ffi_events_await_waiting`); panics if they are not by the
/// deadline, a hang guard.
fn wait_for_parked(queue: u8, pulls: u64) {
    assert!(
        editor_ffi_events_await_waiting(queue, pulls, DEADLINE_MS),
        "{pulls} pulls were not parked on queue {queue}: {DEADLINE}"
    );
}

/// `editor_ffi_text_find` over string slices; `None` when it returns false.
fn find(haystack: &str, needle: &str, start: Option<usize>) -> Option<(u64, u64)> {
    find_bytes(haystack.as_bytes(), needle.as_bytes(), start)
}

/// [`find`] with both texts given as bytes, which need not be UTF-8.
fn find_bytes(haystack: &[u8], needle: &[u8], start: Option<usize>) -> Option<(u64, u64)> {
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

/// Runs `free`, which frees one handle of `kind`, on a thread of its own,
/// as a finaliser may, and waits on the free for the count of `kind` to
/// come down to `target` (`editor_ffi_live_await`).
fn freed_on_another_thread(kind: u8, target: u64, free: impl FnOnce() + Send + 'static) {
    let freeing = thread::spawn(free);
    assert!(
        editor_ffi_live_await(kind, target, DEADLINE_MS),
        "the count of kind {kind} did not come down to {target}: {DEADLINE}"
    );
    freeing.join().expect("the free's thread");
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

    // Freed on another thread, as a finaliser may free it. A pointer is
    // not `Send`, so it crosses as its address.
    let other = other as usize;
    freed_on_another_thread(COUNTERS, before, move || {
        // SAFETY: `other` came from `editor_ffi_counter_new`, and this is
        // the one time it is freed.
        unsafe { editor_ffi_counter_free(other as *mut Counter) };
    });
    assert_eq!(editor_ffi_counter_live(), before);
}

/// A new document holding `text`, given as bytes, which need not be UTF-8.
fn document_new(text: &[u8]) -> *mut Document {
    // SAFETY: the pointer and length are those of `text`, alive for the call.
    unsafe { editor_ffi_document_new(text.as_ptr(), text.len()) }
}

/// Replaces the bytes `start..end` of `document` with `text`, given as
/// bytes, which need not be UTF-8. Returns the status the library returned,
/// as its number.
///
/// # Safety
///
/// `document` came from [`document_new`] and has not been freed.
unsafe fn document_replace(
    document: *const Document,
    start: usize,
    end: usize,
    text: &[u8],
) -> u64 {
    // SAFETY: the caller guarantees `document`; the pointer and length are
    // those of `text`, alive for the call.
    unsafe { editor_ffi_document_replace(document, start, end, text.as_ptr(), text.len()) }
}

/// The text of `document`, read as the glue reads it: fill the record, copy
/// the text, hand the buffer back.
///
/// # Safety
///
/// `document` came from [`document_new`] and has not been freed.
unsafe fn document_read(document: *const Document) -> String {
    let mut raw = MaybeUninit::<RawText>::uninit();
    // SAFETY: the caller guarantees `document`, and `raw` is writable for
    // one record.
    unsafe { editor_ffi_document_read(document, raw.as_mut_ptr()) };
    // SAFETY: the call filled the record.
    let raw = unsafe { raw.assume_init() };
    // SAFETY: the record's buffer is `text_len` bytes, owned by this caller
    // until it is handed back.
    let text = unsafe { slice::from_raw_parts(raw.text, raw.text_len) }.to_vec();
    // SAFETY: the buffer came from the library in this record, and is handed
    // back once.
    unsafe { editor_ffi_text_free(raw.text, raw.text_len) };
    String::from_utf8(text).expect("a document's text is UTF-8")
}

#[test]
fn a_document_is_edited_and_read_through_c_and_is_live_from_new_until_free() {
    let before = editor_ffi_document_live();

    // "é" and "ö" are two bytes each, and the NUL is a byte of the text.
    let document = document_new("héllo\0wörld".as_bytes());
    assert_eq!(editor_ffi_document_live(), before + 1);
    // SAFETY: here and below, `document` came from `document_new` and is
    // not freed until the call that says so.
    unsafe {
        assert_eq!(document_read(document), "héllo\0wörld");

        // A replace changes the text at its byte offsets and returns true.
        assert_eq!(
            document_replace(document, 6, 7, b" "),
            ReplaceStatus::Done as u64
        );
        assert_eq!(document_read(document), "héllo wörld");
        assert_eq!(
            document_replace(document, 13, 13, "!".as_bytes()),
            ReplaceStatus::Done as u64
        );
        assert_eq!(
            document_replace(document, 0, 1, b""),
            ReplaceStatus::Done as u64
        );
        assert_eq!(document_read(document), "éllo wörld!");

        // A refused replace returns false and changes nothing: an offset
        // inside a character, a backwards range, an offset past the end.
        assert_eq!(
            document_replace(document, 1, 1, b"x"),
            ReplaceStatus::BadRange as u64
        );
        assert_eq!(
            document_replace(document, 4, 2, b"x"),
            ReplaceStatus::BadRange as u64
        );
        assert_eq!(
            document_replace(document, 0, usize::MAX, b""),
            ReplaceStatus::BadRange as u64
        );
        assert_eq!(document_read(document), "éllo wörld!");
    }

    // Text that is not UTF-8 is accepted, with U+FFFD for each invalid
    // sequence: there is no failure to report, and no panic. 0xFF is never
    // valid UTF-8.
    let other = document_new(&[b'a', 0xFF, b'b']);
    assert_eq!(editor_ffi_document_live(), before + 2);
    // SAFETY: here and below, `other` came from `document_new` and is not
    // freed until the call that says so.
    unsafe {
        assert_eq!(document_read(other), "a\u{FFFD}b");
        // Offsets are those of the text the document holds, where the
        // replacement character is three bytes long and "b" is at 4, not of
        // the bytes passed in, where it was at 2.
        assert_eq!(
            document_replace(other, 2, 3, b""),
            ReplaceStatus::BadRange as u64
        );
        assert_eq!(
            document_replace(other, 4, 5, &[0xFF, b'c']),
            ReplaceStatus::Done as u64
        );
        assert_eq!(document_read(other), "a\u{FFFD}\u{FFFD}c");
    }

    // SAFETY: `document` came from `document_new`, and this is the one time
    // it is freed.
    unsafe { editor_ffi_document_free(document) };
    assert_eq!(editor_ffi_document_live(), before + 1);
    // SAFETY: `other` is not freed yet.
    assert_eq!(unsafe { document_read(other) }, "a\u{FFFD}\u{FFFD}c");

    // Freed on another thread, as a finaliser may free it.
    let other = other as usize;
    freed_on_another_thread(DOCUMENTS, before, move || {
        // SAFETY: `other` came from `document_new`, and this is the one
        // time it is freed.
        unsafe { editor_ffi_document_free(other as *mut Document) };
    });
    assert_eq!(editor_ffi_document_live(), before);
}

#[test]
fn find_fills_the_range_it_found_and_reports_whether_it_found_one() {
    assert_eq!(find("héllo wörld, hello", "llo", None), Some((3, 6)));
    assert_eq!(find("héllo wörld, hello", "llo", Some(4)), Some((17, 20)));
    assert_eq!(find("héllo wörld, hello", "zzz", None), None);
    assert_eq!(find("héllo wörld, hello", "llo", Some(2)), None);
}

#[test]
fn find_searches_bytes_that_are_not_utf8_as_text_with_replacement_characters() {
    // 0xFF is never valid UTF-8. It is read as U+FFFD, which is three bytes
    // long, so the offsets are those of the text after the replacement and
    // not of the bytes passed in, where "bc" starts at 2.
    assert_eq!(
        find_bytes(&[b'a', 0xFF, b'b', b'c'], b"bc", None),
        Some((4, 6))
    );
    // A start offset counts in the replaced text too: 4 is where "bc"
    // starts, and 2 is inside the replacement character.
    assert_eq!(
        find_bytes(&[b'a', 0xFF, b'b', b'c'], b"bc", Some(4)),
        Some((4, 6))
    );
    assert_eq!(find_bytes(&[b'a', 0xFF, b'b', b'c'], b"bc", Some(2)), None);
    // A needle that is not UTF-8 is read the same way, so it matches a
    // replacement character in the haystack.
    assert_eq!(
        find_bytes("a\u{FFFD}b".as_bytes(), &[0xFF], None),
        Some((1, 4))
    );
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

    // Text that is not UTF-8 is accepted, with U+FFFD for each invalid
    // sequence: there is no failure to report, and no panic.
    assert!(post_bytes(EDITOR, 7, 43, &[b'a', 0xFF, b'b']));
    assert_eq!(
        next(EDITOR),
        Some(message(SourceKind::Lean, 7, 43, "a\u{FFFD}b"))
    );

    // An event crosses with the stamp its source gave it. One whose source
    // gave none reads 0, as every post above did: `message` makes an event
    // with no stamp.
    let stamped = message(SourceKind::Window, 1, 5, "stamped").stamped(u64::MAX - 1);
    assert!(QueueId::Editor.queue().push(stamped.clone()));
    assert_eq!(next(EDITOR), Some(stamped));

    // An event crosses with its words, in order, the largest among them;
    // one with none, as every event above, crosses with none.
    let worded = message(SourceKind::Window, 1, 5, "worded").with_words(vec![0, 1 << 40, u64::MAX]);
    assert!(QueueId::Editor.queue().push(worded.clone()));
    assert_eq!(next(EDITOR), Some(worded));

    // A pull parks on its own queue, and a post to that queue wakes it.
    let (done, parked) = mpsc::channel();
    thread::spawn(move || {
        let _ = done.send(next_blocking(COMPLETION));
    });
    wait_for_parked(COMPLETION, 1);
    assert_eq!(editor_ffi_events_waiting(EDITOR), 0);
    assert!(post(COMPLETION, 1, 2, "wake"));
    assert_eq!(
        editor_wait::recv(&parked, DEADLINE).expect("the parked pull returns"),
        Some(message(SourceKind::Lean, 1, 2, "wake"))
    );

    // A scripted feed arrives in order, from the script source asked for.
    let feed = editor_ffi_events_script_feed(COMPLETION, 9, 3);
    assert_ne!(feed, 0, "the feed starts");
    for code in 0..3 {
        let event = next(COMPLETION).expect("the completion queue exists");
        let source = Source {
            kind: SourceKind::Script,
            id: 9,
        };
        assert_eq!((event.source, event.kind), (source, EventKind::Message));
        assert_eq!(event.code, code);
        assert_eq!(event.words, [code, u64::MAX - code]);
    }
    // Its whole script fed, the feed ends, and is joined once.
    assert!(editor_ffi_events_script_join(feed, DEADLINE_MS));
    assert!(!editor_ffi_events_script_join(feed, DEADLINE_MS));

    // A tag that names no queue is refused, not acted on.
    assert!(!post(NO_QUEUE, 1, 1, "nowhere"));
    assert_eq!(next(NO_QUEUE), None);
    assert_eq!(editor_ffi_events_script_feed(NO_QUEUE, 1, 1), 0);
    assert!(!editor_ffi_events_script_join(0, DEADLINE_MS));
    assert_eq!(editor_ffi_events_waiting(NO_QUEUE), 0);
    assert!(!editor_ffi_events_await_waiting(NO_QUEUE, 0, DEADLINE_MS));

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
    // push, nothing is queued, and the feed ends.
    let feed = within_deadline("a feed of the longest script", || {
        editor_ffi_events_script_feed(COMPLETION, 9, u64::MAX)
    });
    assert_ne!(feed, 0, "the feed starts");
    assert!(editor_ffi_events_script_join(feed, DEADLINE_MS));
    assert_eq!(next(COMPLETION), Some(Event::quit()));
}
