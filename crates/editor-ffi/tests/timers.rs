//! The C functions over the process's timer service, called the way the C
//! glue calls them, with its completions pulled from the process's
//! completion queue.
//!
//! This is an integration test of its own, not part of `tests/c_api.rs`,
//! because the timer service and the completion queue are process-wide and
//! that test quits the queues. It is one test function, so nothing else in
//! this process touches either.

use std::mem::MaybeUninit;
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use editor_wait::HangGuard;

use editor_ffi::events::{
    EventKind, QueueId, RawEvent, SourceKind, editor_ffi_events_next, editor_ffi_events_waiting,
};
use editor_ffi::text::editor_ffi_text_free;
use editor_ffi::timers::{
    SERVICE, editor_ffi_timers_cancel, editor_ffi_timers_flush, editor_ffi_timers_now,
    editor_ffi_timers_pending, editor_ffi_timers_start,
};

/// hang guard: the next completion; only a hang reaches the bound, and the test then fails as a hang. Each
/// wait on it is for something that should happen at once.
const DEADLINE: HangGuard = HangGuard::on("the next completion", Duration::from_secs(5));

/// The tag of the completion queue.
const COMPLETION: u8 = QueueId::Completion.tag();

/// An hour, in milliseconds: a deadline the test never reaches.
const HOUR: u64 = 3_600_000;

/// What one event of the completion queue says, as the glue would read it:
/// its source's kind and id, its kind, its code, and whether it has no text.
type Seen = (Option<SourceKind>, u64, Option<EventKind>, u64, bool);

/// One pull from the completion queue, bounded by the deadline: the pull
/// runs on a detached thread, so one that never returns fails the test
/// instead of hanging it.
fn next_completion() -> Seen {
    let (done, result) = mpsc::channel();
    thread::spawn(move || {
        let mut raw = MaybeUninit::<RawEvent>::uninit();
        // SAFETY: `raw` is writable for one record.
        assert!(unsafe { editor_ffi_events_next(COMPLETION, raw.as_mut_ptr()) });
        // SAFETY: the call returned true, so it filled the record.
        let raw = unsafe { raw.assume_init() };
        // SAFETY: the buffer came from the library in this record, and is
        // handed back once.
        unsafe { editor_ffi_text_free(raw.text, raw.text_len) };
        let _ = done.send((
            SourceKind::from_tag(raw.source_kind),
            raw.source_id,
            EventKind::from_tag(raw.kind),
            raw.code,
            raw.text_len == 0,
        ));
    });
    editor_wait::recv(&result, DEADLINE)
        .unwrap_or_else(|_| panic!("no event reached the completion queue: {DEADLINE}"))
}

/// The completion of the timer request `id`, as it should arrive.
fn completion_of(id: u64) -> Seen {
    (
        Some(SourceKind::Library),
        SERVICE,
        Some(EventKind::Completion),
        id,
        true,
    )
}

/// The whole life of the process's timer service, in order.
#[test]
fn the_process_wide_timers_complete_a_wait_on_the_completion_queue_unless_it_is_cancelled() {
    assert_eq!(editor_ffi_timers_pending(), 0);

    // A wait that is due arrives as a completion whose code is its id.
    assert!(editor_ffi_timers_start(7, editor_ffi_timers_now()));
    assert_eq!(next_completion(), completion_of(7));
    assert_eq!(editor_ffi_timers_pending(), 0);

    // A wait an hour away waits, and an id that is waiting is refused.
    let later = editor_ffi_timers_now() + HOUR;
    assert!(editor_ffi_timers_start(8, later));
    assert!(!editor_ffi_timers_start(8, 0));
    assert_eq!(editor_ffi_timers_pending(), 1);

    // Cancelling it takes it out of the schedule, once.
    assert!(editor_ffi_timers_cancel(8));
    assert_eq!(editor_ffi_timers_pending(), 0);
    assert!(!editor_ffi_timers_cancel(8));

    // An id that is unknown, and one that has completed, are not waiting.
    assert!(!editor_ffi_timers_cancel(99));
    assert!(!editor_ffi_timers_cancel(7));

    // A wait whose deadline has passed is completed too, and it is the next
    // event on the queue: nothing arrived for the cancelled wait or for the
    // start that was refused.
    assert!(editor_ffi_timers_start(9, 0));
    assert_eq!(next_completion(), completion_of(9));
    assert_eq!(editor_ffi_events_waiting(COMPLETION), 0);

    // A flush asked behind a wait due now is completed after it, and one
    // asked beside a wait an hour away does not wait for it.
    assert!(editor_ffi_timers_start(10, editor_ffi_timers_now()));
    assert!(editor_ffi_timers_start(11, editor_ffi_timers_now() + HOUR));
    assert!(editor_ffi_timers_flush(12));
    assert_eq!(next_completion(), completion_of(10));
    assert_eq!(next_completion(), completion_of(12));
    assert_eq!(editor_ffi_timers_pending(), 1);
    assert!(editor_ffi_timers_cancel(11));
    assert_eq!(editor_ffi_events_waiting(COMPLETION), 0);

    // The clock does not go back.
    let first = editor_ffi_timers_now();
    assert!(first <= editor_ffi_timers_now());
}
