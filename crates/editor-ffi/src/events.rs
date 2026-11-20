//! The event queue: how anything the Rust library has to tell Lean gets
//! there, at the boundary.
//!
//! The queues themselves, the events they carry and the fake source that
//! feeds them a script are `editor-service`'s
//! ([`editor_service::queue`]), re-exported here, so that a package's
//! crate, which depends on that crate and on nothing else of the editor's,
//! posts to the same two queues: all of the editor is linked from one Rust
//! archive, so the process holds one of each. Rust never calls Lean. A
//! thread with something to report pushes an [`Event`] onto a [`Queue`],
//! and a Lean task pulls it with a blocking [`Queue::next`].
//!
//! [`Queue::quit`] is how a task parked in a pull is told to return. It is
//! ordered and it sticks: events queued before it are still delivered, then
//! every pull, parked or later, returns [`Event::quit`] at once, and a push
//! is dropped.
//!
//! The process has two queues, named by [`QueueId`]: the editor queue
//! (input and events for the editor thread) and the completion queue
//! (results of service requests, pulled by a dedicated Lean task). The C
//! functions at the bottom only forward to those two instances; an event
//! crosses as one [`RawEvent`], filled in a single call. What is left here
//! is what the boundary needs: [`RawEvent`], [`take`], which notes a
//! window's stamp with the render loop's presenter, and the C functions.
//!
//! [`ScriptedSource`] is the fake event source. It is public, not
//! `cfg(test)`, so the tests of any crate, and the Lean test executable
//! through [`editor_ffi_events_script_feed`], can feed a queue a script of
//! events.
//!
//! A service reports that a request has finished with an
//! [`EventKind::Completion`] on the completion queue, whose code is the id
//! the request was made with and whose source is the service (the crate
//! docs, "Services and completions"). The timer service in this crate
//! ([`crate::timers`]) is the first. A service of this crate reports with
//! `complete` and its fixed id; a service of a package's crate with
//! its [`editor_service::Service`], whose id is taken at or above
//! [`editor_service::FIRST_PACKAGE_ID`].
//!
//! The syntax service ([`crate::syntax`]) reports each delivery of a
//! highlighted document's parse with an [`EventKind::Parsed`] on the editor
//! queue, from the library's source with the service's id, so Lean
//! publishes a scene laid out with the new tree.
//!
//! The queue lives in `editor-service`, which a service crate of the core
//! does not depend on. Such a crate therefore defines its own port for
//! reporting, and `editor-ffi` adapts that port to a queue.

pub use editor_service::queue::{
    Event, EventKind, Queue, QueueId, ScriptedSource, Source, SourceKind,
};

use editor_service::queue::{COMPLETION, EDITOR};

use crate::render::{PRESENTER, Presenter};
use crate::text;
use crate::words::{self, Writer};

/// The process-wide queue the tag `queue` names, if it names one.
fn queue(queue: u8) -> Option<&'static Queue> {
    QueueId::from_tag(queue).map(QueueId::queue)
}

/// The oldest event of `queue`, parking the calling thread until there is
/// one ([`Queue::next`]), handed back as it was; when it came from a
/// window, its stamp is noted with `presenter` as one the next frame
/// presented answers ([`Presenter::answering`]).
pub fn take(queue: &Queue, presenter: &Presenter) -> Event {
    let event = queue.next();
    if event.source.kind == SourceKind::Window {
        presenter.answering().note(event.stamp);
    }
    event
}

/// Queues the completion of the request `request` on the process's
/// completion queue, from the library's service `service`, and returns
/// whether it was accepted: a queue that has been quit drops it
/// ([`editor_service::queue::complete`]).
///
/// This is how a service in this crate reports that a request has finished.
pub(crate) fn complete(service: u64, request: u64) -> bool {
    editor_service::queue::complete(service, request)
}

/// An [`Event`] as it crosses the boundary: one record, filled in one call.
#[repr(C)]
pub struct RawEvent {
    /// The [`SourceKind`]'s tag.
    pub source_kind: u64,
    /// The source's id.
    pub source_id: u64,
    /// The [`EventKind`]'s tag.
    pub kind: u64,
    /// The event's code.
    pub code: u64,
    /// The event's stamp.
    pub stamp: u64,
    /// The event's text: a buffer of `text_len` bytes of UTF-8, owned by the
    /// caller until it is handed back.
    pub text: *mut u8,
    /// The length of `text` in bytes.
    pub text_len: usize,
    /// The event's words (`words.rs`): a buffer of `words_len` bytes,
    /// owned by the caller until it is handed back, as the text is.
    pub words: *mut u8,
    /// The length of `words` in bytes: eight a word.
    pub words_len: usize,
}

impl RawEvent {
    /// `event` as it crosses: its tags and numbers, with its text and its
    /// words lent to the caller, who hands each back with
    /// [`editor_ffi_text_free`](crate::text::editor_ffi_text_free).
    pub(crate) fn lend(event: Event) -> Self {
        let (text, text_len) = text::lend(event.text);
        let mut writer = Writer::with_capacity(event.words.len());
        for word in event.words {
            writer.word(word);
        }
        let (words, words_len) = words::lend(writer.finish());
        Self {
            source_kind: event.source.kind.tag(),
            source_id: event.source.id,
            kind: event.kind.tag(),
            code: event.code,
            stamp: event.stamp,
            text,
            text_len,
            words,
            words_len,
        }
    }
}

/// Posts a message from the Lean source `source_id` to the queue `queue`,
/// and returns whether it was accepted.
///
/// Returns false, queueing nothing, if `queue` names no queue or if the
/// queue has been quit.
///
/// `text` is expected to be UTF-8, as a Lean string is. Text that is not is
/// still accepted: the event's text has U+FFFD in place of each invalid
/// sequence.
///
/// # Safety
///
/// `text` points to `text_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_events_post(
    queue: u8,
    source_id: u64,
    code: u64,
    text: *const u8,
    text_len: usize,
) -> bool {
    let Some(queue) = self::queue(queue) else {
        return false;
    };
    let source = Source {
        kind: SourceKind::Lean,
        id: source_id,
    };
    // SAFETY: the caller guarantees the pointer and the length.
    let text = unsafe { text::borrow(text, text_len) };
    queue.push(Event::message(source, code, text))
}

/// Takes the oldest event of the queue `queue`, parking the calling thread
/// until there is one, and fills `out` with it. Returns false, leaving `out`
/// alone, if `queue` names no queue.
///
/// # Safety
///
/// `out` points to a writable [`RawEvent`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_events_next(queue: u8, out: *mut RawEvent) -> bool {
    let Some(taken) = self::queue(queue) else {
        return false;
    };
    // An input taken off the editor queue waits for the frame that answers
    // it; the completion queue's events are no input.
    let event = if QueueId::from_tag(queue) == Some(QueueId::Editor) {
        take(taken, &PRESENTER)
    } else {
        taken.next()
    };
    let raw = RawEvent::lend(event);
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
    true
}

/// Quits both queues.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_events_quit() {
    EDITOR.quit();
    COMPLETION.quit();
}

/// How many pulls are parked on the queue `queue`; 0 if it names no queue.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_events_waiting(queue: u8) -> u64 {
    self::queue(queue).map_or(0, |queue| queue.waiting() as u64)
}

/// How many events the queue `queue` holds that have not been pulled; 0 if
/// it names no queue. A readout for tests, which drain a queue with it
/// without parking a pull on an empty one.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_events_queued(queue: u8) -> u64 {
    self::queue(queue).map_or(0, |queue| queue.queued() as u64)
}

/// Feeds the queue `queue` the script [`ScriptedSource::numbered`] makes of
/// `source_id` and `count`, from a new Rust thread.
///
/// Returns false, feeding nothing, if `queue` names no queue or if the
/// operating system refuses the thread. Otherwise it returns true as soon as
/// the thread has started. The events are made on that thread as they are
/// pushed, so no `count` is too large and the caller never waits for the
/// script.
///
/// True says only that the thread started, not that anything was delivered.
/// The thread stops at the first event the queue refuses
/// ([`ScriptedSource::feed`]), so a feed to a queue that has been quit
/// delivers nothing, and one that is quit part-way delivers only what was
/// queued before the quit.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_events_script_feed(queue: u8, source_id: u64, count: u64) -> bool {
    let Some(queue) = self::queue(queue) else {
        return false;
    };
    ScriptedSource::numbered(source_id, count)
        .feed_from_thread(queue)
        .is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_raw_event_lends_its_text_and_its_words_as_buffers_that_read_back_whole() {
        let source = Source {
            kind: SourceKind::Window,
            id: 1,
        };
        let event = Event::message(source, 6, "é")
            .with_words(vec![u64::MAX, 0, 7])
            .stamped(9);

        let raw = RawEvent::lend(event);

        assert_eq!(
            (
                raw.source_kind,
                raw.source_id,
                raw.kind,
                raw.code,
                raw.stamp
            ),
            (3, 1, 1, 6, 9)
        );
        // SAFETY: `lend` gave these buffers up, and each is taken back once.
        let (text, words) = unsafe {
            (
                Box::from_raw(std::ptr::slice_from_raw_parts_mut(raw.text, raw.text_len)),
                Box::from_raw(std::ptr::slice_from_raw_parts_mut(raw.words, raw.words_len)),
            )
        };
        assert_eq!(*text, *"é".as_bytes());
        assert_eq!(crate::words::tests::words_of(&words), [u64::MAX, 0, 7]);
    }

    #[test]
    fn taking_an_event_from_a_window_notes_its_stamp_as_one_a_frame_answers() {
        let queue = Queue::new();
        let presenter = crate::render::Presenter::new();
        let window = Source {
            kind: SourceKind::Window,
            id: 1,
        };
        let lean = Source {
            kind: SourceKind::Lean,
            id: 1,
        };
        let from_lean = Event::message(lean, 1, "posted").stamped(5);
        let from_window = Event::message(window, 2, "typed").stamped(9);
        assert!(queue.push(from_lean.clone()));
        assert!(queue.push(from_window.clone()));
        // Each is handed back as it was; only the window's is noted.
        assert_eq!(take(&queue, &presenter), from_lean);
        assert_eq!(presenter.answering().take(), None);
        assert_eq!(take(&queue, &presenter), from_window);
        assert_eq!(presenter.answering().take(), Some(9));
    }
}
