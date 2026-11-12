//! The event queue: how anything the Rust library has to tell Lean gets
//! there.
//!
//! Rust never calls Lean. A thread with something to report pushes an
//! [`Event`] onto a [`Queue`], and a Lean task pulls it with a blocking
//! [`Queue::next`]. An event is plain data tagged with its [`Source`].
//!
//! The vocabulary grows by variants: a new thing to report is an
//! [`EventKind`], a new origin a [`SourceKind`]. Each has a number that
//! stands for it across the boundary, converted back with a checked
//! function that refuses a number it does not know.
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
//! crosses as one [`RawEvent`], filled in a single call.
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
//! ([`crate::timers`]) is the first.
//!
//! The queue lives in `editor-ffi`, which no other crate depends on. A
//! service crate therefore defines its own port for reporting, and
//! `editor-ffi` adapts that port to a queue.

use std::collections::VecDeque;
use std::io;
use std::ops::Deref;
use std::sync::{Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};

use crate::text;

/// What an [`Event`] says happened.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventKind {
    /// The queue has been quit: the task pulling from it must return.
    Quit = 0,
    /// A message with no meaning to the library: its `code` and `text` are
    /// whatever the source chose.
    Message = 1,
    /// A service request has finished: its `code` is the id the request was
    /// made with, and its source is the service that completed it.
    Completion = 2,
    /// A window is open: its `text` is the name the platform gives itself.
    /// This and the kinds after it come from a window ([`crate::window`]),
    /// whose module docs say what each `code` means.
    WindowOpened = 3,
    /// The window gained the keyboard focus (`code` 1) or lost it (0).
    WindowFocus = 4,
    /// A key was pressed or released: the bits of its `code` say which, and
    /// its `text` is what the key produced.
    Key = 5,
    /// A step of an input method's composition: its `code` says which, and
    /// its `text` is the text being composed or committed.
    Composition = 6,
    /// A pointer button was pressed in the window.
    PointerPressed = 7,
    /// The user asked for the window to be closed.
    CloseRequested = 8,
}

impl EventKind {
    /// The number that stands for this kind across the boundary.
    pub const fn tag(self) -> u64 {
        self as u64
    }

    /// The kind `tag` stands for, if it is one.
    pub const fn from_tag(tag: u64) -> Option<Self> {
        match tag {
            0 => Some(Self::Quit),
            1 => Some(Self::Message),
            2 => Some(Self::Completion),
            3 => Some(Self::WindowOpened),
            4 => Some(Self::WindowFocus),
            5 => Some(Self::Key),
            6 => Some(Self::Composition),
            7 => Some(Self::PointerPressed),
            8 => Some(Self::CloseRequested),
            _ => None,
        }
    }
}

/// What kind of thing an [`Event`] came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceKind {
    /// The library itself.
    Library = 0,
    /// Lean code, posting through the bindings.
    Lean = 1,
    /// A [`ScriptedSource`].
    Script = 2,
    /// A window: its id is the window's number.
    Window = 3,
}

impl SourceKind {
    /// The number that stands for this kind across the boundary.
    pub const fn tag(self) -> u64 {
        self as u64
    }

    /// The kind `tag` stands for, if it is one.
    pub const fn from_tag(tag: u64) -> Option<Self> {
        match tag {
            0 => Some(Self::Library),
            1 => Some(Self::Lean),
            2 => Some(Self::Script),
            3 => Some(Self::Window),
            _ => None,
        }
    }
}

/// Where an [`Event`] came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Source {
    /// The kind of source.
    pub kind: SourceKind,
    /// Which source of that kind, in numbers the source chose.
    pub id: u64,
}

/// One thing the library tells Lean: plain data, tagged with its source.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Event {
    /// Where the event came from.
    pub source: Source,
    /// What happened.
    pub kind: EventKind,
    /// A number whose meaning the kind sets.
    pub code: u64,
    /// Text whose meaning the kind sets.
    pub text: String,
    /// The instant the source says the event happened, in nanoseconds on
    /// the library's input clock ([`crate::window::InputClock`]), or 0 when
    /// the source does not say. Only a window says.
    pub stamp: u64,
}

impl Event {
    /// The event every pull on a queue returns once the queue has been quit.
    pub const fn quit() -> Self {
        Self {
            source: Source {
                kind: SourceKind::Library,
                id: 0,
            },
            kind: EventKind::Quit,
            code: 0,
            text: String::new(),
            stamp: 0,
        }
    }

    /// A [`EventKind::Message`] from `source`.
    pub fn message(source: Source, code: u64, text: impl Into<String>) -> Self {
        Self {
            source,
            kind: EventKind::Message,
            code,
            text: text.into(),
            stamp: 0,
        }
    }

    /// The [`EventKind::Completion`] of the request `request`, from the
    /// service `service`.
    pub const fn completion(service: Source, request: u64) -> Self {
        Self {
            source: service,
            kind: EventKind::Completion,
            code: request,
            text: String::new(),
            stamp: 0,
        }
    }

    /// This event, said to have happened at `stamp`.
    pub fn stamped(self, stamp: u64) -> Self {
        Self { stamp, ..self }
    }
}

/// A queue of events that any thread pushes to and a Lean task pulls from.
pub struct Queue {
    /// The events and the pulls waiting for them.
    state: Mutex<State>,
    /// Signalled when an event joins the queue or the queue is quit.
    changed: Condvar,
}

/// What [`Queue::state`] guards.
struct State {
    /// Events not yet pulled, oldest first.
    events: VecDeque<Event>,
    /// Whether the queue has been quit.
    quit: bool,
    /// How many pulls are parked.
    waiting: usize,
}

impl Queue {
    /// An empty queue.
    pub const fn new() -> Self {
        Self {
            state: Mutex::new(State {
                events: VecDeque::new(),
                quit: false,
                waiting: 0,
            }),
            changed: Condvar::new(),
        }
    }

    /// Adds `event` to the queue and returns whether it was accepted.
    ///
    /// A queue that has been quit accepts nothing: the event is dropped.
    pub fn push(&self, event: Event) -> bool {
        {
            let mut state = self.state();
            if state.quit {
                return false;
            }
            state.events.push_back(event);
        }
        self.changed.notify_one();
        true
    }

    /// Takes the oldest event, parking the calling thread until there is one.
    ///
    /// Once the queue has been quit and the events queued before the quit
    /// have been taken, this returns [`Event::quit`] at once, every time.
    pub fn next(&self) -> Event {
        let mut state = self.state();
        loop {
            if let Some(event) = state.events.pop_front() {
                return event;
            }
            if state.quit {
                return Event::quit();
            }
            state.waiting += 1;
            state = self
                .changed
                .wait(state)
                .unwrap_or_else(PoisonError::into_inner);
            state.waiting -= 1;
        }
    }

    /// Quits the queue, for good: wakes every parked pull, and makes every
    /// pull from now on return [`Event::quit`] once the events already
    /// queued have been taken.
    pub fn quit(&self) {
        self.state().quit = true;
        self.changed.notify_all();
    }

    /// How many pulls are parked on the queue.
    pub fn waiting(&self) -> usize {
        self.state().waiting
    }

    /// Locks the state. The lock is never held while other code runs, so a
    /// poisoned lock still guards a consistent state.
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl Default for Queue {
    fn default() -> Self {
        Self::new()
    }
}

/// A fake event source: feeds a script of events to a queue, in order.
pub struct ScriptedSource {
    /// The events to feed, first to last. Each is made as it is fed, so a
    /// script costs nothing until then, however long it is.
    script: Box<dyn Iterator<Item = Event> + Send>,
}

impl ScriptedSource {
    /// A source that will feed `script`.
    pub fn new(script: Vec<Event>) -> Self {
        Self {
            script: Box::new(script.into_iter()),
        }
    }

    /// Feeds the script to `queue` on the calling thread, making each event
    /// as it is pushed.
    ///
    /// Feeding stops at the first event the queue refuses, which is once the
    /// queue has been quit. That event and the rest of the script are
    /// dropped, and nothing reports it: a script fed to a queue that has
    /// already been quit delivers nothing.
    pub fn feed(self, queue: &Queue) {
        for event in self.script {
            if !queue.push(event) {
                break;
            }
        }
    }

    /// A source that will feed `count` messages from the script source
    /// `source_id`, with the codes 0, 1, 2 and so on.
    pub fn numbered(source_id: u64, count: u64) -> Self {
        let source = Source {
            kind: SourceKind::Script,
            id: source_id,
        };
        Self {
            script: Box::new(
                (0..count)
                    .map(move |code| Event::message(source, code, format!("scripted {code}"))),
            ),
        }
    }

    /// Feeds the script to `queue` from a new thread. Fails only if the
    /// operating system refuses the thread.
    pub fn feed_from_thread<Q>(self, queue: Q) -> io::Result<JoinHandle<()>>
    where
        Q: Deref<Target = Queue> + Send + 'static,
    {
        thread::Builder::new().spawn(move || self.feed(&queue))
    }
}

/// Which of the process's two queues a C function works on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QueueId {
    /// The editor queue: input and events for the editor thread.
    Editor = 0,
    /// The completion queue: results of service requests, pulled by a
    /// dedicated Lean task.
    Completion = 1,
}

impl QueueId {
    /// The number that stands for this queue across the boundary.
    pub const fn tag(self) -> u8 {
        self as u8
    }

    /// The queue `tag` stands for, if it is one.
    pub const fn from_tag(tag: u8) -> Option<Self> {
        match tag {
            0 => Some(Self::Editor),
            1 => Some(Self::Completion),
            _ => None,
        }
    }

    /// The process-wide queue this names.
    pub const fn queue(self) -> &'static Queue {
        match self {
            Self::Editor => &EDITOR,
            Self::Completion => &COMPLETION,
        }
    }
}

/// The process's editor queue.
static EDITOR: Queue = Queue::new();

/// The process's completion queue.
static COMPLETION: Queue = Queue::new();

/// The process-wide queue the tag `queue` names, if it names one.
fn queue(queue: u8) -> Option<&'static Queue> {
    QueueId::from_tag(queue).map(QueueId::queue)
}

/// Queues the completion of the request `request` on the process's
/// completion queue, from the library's service `service`, and returns
/// whether it was accepted: a queue that has been quit drops it.
///
/// This is how a service in this crate reports that a request has finished.
pub(crate) fn complete(service: u64, request: u64) -> bool {
    let source = Source {
        kind: SourceKind::Library,
        id: service,
    };
    COMPLETION.push(Event::completion(source, request))
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
    let Some(queue) = self::queue(queue) else {
        return false;
    };
    let event = queue.next();
    let (text, text_len) = text::lend(event.text);
    let raw = RawEvent {
        source_kind: event.source.kind.tag(),
        source_id: event.source.id,
        kind: event.kind.tag(),
        code: event.code,
        stamp: event.stamp,
        text,
        text_len,
    };
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
    use std::sync::Arc;
    use std::sync::mpsc::{self, Receiver, TryRecvError};
    use std::thread;
    use std::time::{Duration, Instant};

    /// How long a test waits for something that should happen at once. Only
    /// a broken queue takes this long, and the test then fails instead of
    /// hanging.
    const DEADLINE: Duration = Duration::from_secs(5);

    /// Starts `blocking` on a detached thread and returns where its result
    /// arrives. The thread is detached, not scoped, so a call that never
    /// returns cannot keep the test from ending.
    fn start<T: Send + 'static>(blocking: impl FnOnce() -> T + Send + 'static) -> Receiver<T> {
        let (done, result) = mpsc::channel();
        thread::spawn(move || {
            let _ = done.send(blocking());
        });
        result
    }

    /// The result of a call begun with [`start`]; panics if it has not
    /// arrived by the deadline.
    fn finish<T>(result: &Receiver<T>, what: &str) -> T {
        result
            .recv_timeout(DEADLINE)
            .unwrap_or_else(|_| panic!("{what} did not return within {DEADLINE:?}"))
    }

    /// Starts a pull on a detached thread.
    fn start_pull(queue: &Arc<Queue>) -> Receiver<Event> {
        let queue = Arc::clone(queue);
        start(move || queue.next())
    }

    /// One event pulled from `queue`; panics if none arrives by the deadline.
    fn pull(queue: &Arc<Queue>) -> Event {
        finish(&start_pull(queue), "a pull")
    }

    /// Waits until `pulls` pulls are parked on `queue`; panics if they are
    /// not by the deadline.
    fn wait_for_parked(queue: &Queue, pulls: usize) {
        let deadline = Instant::now() + DEADLINE;
        while queue.waiting() != pulls {
            assert!(
                Instant::now() < deadline,
                "{} pulls were parked after {DEADLINE:?}, not {pulls}",
                queue.waiting()
            );
            thread::sleep(Duration::from_millis(1));
        }
    }

    /// A message event from the scripted source `id`.
    fn message(id: u64, code: u64) -> Event {
        let source = Source {
            kind: SourceKind::Script,
            id,
        };
        Event::message(source, code, format!("{id}/{code}"))
    }

    /// The script of the source `id`: `len` messages numbered from 0.
    fn script(id: u64, len: u64) -> Vec<Event> {
        (0..len).map(|code| message(id, code)).collect()
    }

    #[test]
    fn events_are_pulled_in_the_order_they_were_pushed() {
        let queue = Arc::new(Queue::new());

        for event in script(1, 3) {
            assert!(queue.push(event), "an open queue accepts an event");
        }

        let pulled: Vec<Event> = (0..3).map(|_| pull(&queue)).collect();
        assert_eq!(pulled, script(1, 3));
    }

    #[test]
    fn each_sources_events_keep_their_order_when_several_threads_feed_one_queue() {
        const SOURCES: u64 = 4;
        const EVENTS: u64 = 50;
        let queue = Arc::new(Queue::new());

        for id in 0..SOURCES {
            ScriptedSource::new(script(id, EVENTS))
                .feed_from_thread(Arc::clone(&queue))
                .expect("a thread starts");
        }

        let pulled: Vec<Event> = (0..SOURCES * EVENTS).map(|_| pull(&queue)).collect();
        for id in 0..SOURCES {
            let from_source: Vec<Event> = pulled
                .iter()
                .filter(|event| event.source.id == id)
                .cloned()
                .collect();
            assert_eq!(from_source, script(id, EVENTS));
        }
    }

    #[test]
    fn a_pull_parks_until_an_event_is_pushed() {
        let queue = Arc::new(Queue::new());

        let pulled = start_pull(&queue);
        wait_for_parked(&queue, 1);
        assert_eq!(pulled.try_recv(), Err(TryRecvError::Empty));

        queue.push(message(1, 0));

        assert_eq!(finish(&pulled, "the parked pull"), message(1, 0));
        assert_eq!(queue.waiting(), 0);
    }

    #[test]
    fn quit_wakes_every_parked_pull_with_a_quit_event() {
        const PULLS: usize = 3;
        let queue = Arc::new(Queue::new());

        let pulls: Vec<_> = (0..PULLS).map(|_| start_pull(&queue)).collect();
        wait_for_parked(&queue, PULLS);

        queue.quit();

        for pulled in &pulls {
            assert_eq!(finish(pulled, "a parked pull"), Event::quit());
        }
    }

    #[test]
    fn after_quit_every_pull_returns_quit_at_once() {
        let queue = Arc::new(Queue::new());

        queue.quit();

        assert_eq!(pull(&queue), Event::quit());
        assert_eq!(pull(&queue), Event::quit());
    }

    #[test]
    fn events_queued_before_quit_are_delivered_before_it() {
        let queue = Arc::new(Queue::new());
        queue.push(message(1, 0));
        queue.push(message(1, 1));

        queue.quit();

        assert_eq!(pull(&queue), message(1, 0));
        assert_eq!(pull(&queue), message(1, 1));
        assert_eq!(pull(&queue), Event::quit());
    }

    #[test]
    fn a_push_after_quit_is_refused() {
        let queue = Arc::new(Queue::new());
        queue.quit();

        assert!(!queue.push(message(1, 0)));

        assert_eq!(pull(&queue), Event::quit());
    }

    #[test]
    fn a_scripted_source_feeds_its_script_in_order_on_the_calling_thread() {
        let queue = Arc::new(Queue::new());

        ScriptedSource::new(script(7, 3)).feed(&queue);

        let pulled: Vec<Event> = (0..3).map(|_| pull(&queue)).collect();
        assert_eq!(pulled, script(7, 3));
    }

    #[test]
    fn a_scripted_source_feeds_its_script_in_order_on_its_own_thread() {
        let queue = Arc::new(Queue::new());
        let caller = thread::current().id();

        let feeder = ScriptedSource::new(script(7, 3))
            .feed_from_thread(Arc::clone(&queue))
            .expect("a thread starts");

        let pulled: Vec<Event> = (0..3).map(|_| pull(&queue)).collect();
        assert_eq!(pulled, script(7, 3));
        assert_ne!(feeder.thread().id(), caller);
    }

    #[test]
    fn a_numbered_script_is_messages_from_one_script_source_numbered_from_zero() {
        let queue = Arc::new(Queue::new());
        let source = Source {
            kind: SourceKind::Script,
            id: 9,
        };

        ScriptedSource::numbered(9, 3).feed(&queue);

        for code in 0..3 {
            let event = pull(&queue);
            assert_eq!((event.source, event.kind), (source, EventKind::Message));
            assert_eq!(event.code, code);
        }
    }

    #[test]
    fn a_script_too_long_to_build_delivers_its_first_events_and_stops_when_the_queue_quits() {
        let queue = Arc::new(Queue::new());

        // The longest script there is. Built before it is fed, it could not
        // be allocated; fed to its end, it would never finish.
        let feeder = ScriptedSource::numbered(9, u64::MAX)
            .feed_from_thread(Arc::clone(&queue))
            .expect("a thread starts");
        let codes: Vec<u64> = (0..3).map(|_| pull(&queue).code).collect();
        queue.quit();

        assert_eq!(codes, [0, 1, 2]);
        let deadline = Instant::now() + DEADLINE;
        while !feeder.is_finished() {
            assert!(
                Instant::now() < deadline,
                "the source was still feeding a quit queue after {DEADLINE:?}"
            );
            thread::sleep(Duration::from_millis(1));
        }
    }

    #[test]
    fn every_queue_converts_from_its_tag() {
        assert_eq!(QueueId::from_tag(0), Some(QueueId::Editor));
        assert_eq!(QueueId::from_tag(1), Some(QueueId::Completion));
        assert_eq!(QueueId::Editor.tag(), 0);
        assert_eq!(QueueId::Completion.tag(), 1);
    }

    #[test]
    fn an_unknown_queue_tag_is_refused() {
        assert_eq!(QueueId::from_tag(2), None);
        assert_eq!(QueueId::from_tag(u8::MAX), None);
    }

    #[test]
    fn every_event_kind_converts_from_its_tag() {
        assert_eq!(EventKind::from_tag(0), Some(EventKind::Quit));
        assert_eq!(EventKind::from_tag(1), Some(EventKind::Message));
        assert_eq!(EventKind::from_tag(2), Some(EventKind::Completion));
        assert_eq!(EventKind::Quit.tag(), 0);
        assert_eq!(EventKind::Message.tag(), 1);
        assert_eq!(EventKind::Completion.tag(), 2);
    }

    #[test]
    fn every_kind_of_window_event_converts_from_its_tag() {
        let kinds = [
            (3, EventKind::WindowOpened),
            (4, EventKind::WindowFocus),
            (5, EventKind::Key),
            (6, EventKind::Composition),
            (7, EventKind::PointerPressed),
            (8, EventKind::CloseRequested),
        ];
        for (tag, kind) in kinds {
            assert_eq!(EventKind::from_tag(tag), Some(kind));
            assert_eq!(kind.tag(), tag);
        }
    }

    #[test]
    fn an_unknown_event_kind_tag_is_refused() {
        assert_eq!(EventKind::from_tag(9), None);
        assert_eq!(EventKind::from_tag(u64::MAX), None);
    }

    #[test]
    fn an_event_has_no_stamp_until_it_is_given_one() {
        let source = Source {
            kind: SourceKind::Window,
            id: 1,
        };

        assert_eq!(Event::quit().stamp, 0);
        assert_eq!(Event::message(source, 1, "").stamp, 0);
        assert_eq!(Event::completion(source, 1).stamp, 0);
        assert_eq!(
            Event::message(source, 1, "a").stamped(77),
            Event {
                source,
                kind: EventKind::Message,
                code: 1,
                text: "a".into(),
                stamp: 77,
            }
        );
    }

    #[test]
    fn a_completion_is_from_its_service_and_carries_the_request_id_as_its_code() {
        let service = Source {
            kind: SourceKind::Library,
            id: 4,
        };

        let event = Event::completion(service, 17);

        assert_eq!(
            event,
            Event {
                source: service,
                kind: EventKind::Completion,
                code: 17,
                text: String::new(),
                stamp: 0,
            }
        );
    }

    #[test]
    fn every_source_kind_converts_from_its_tag() {
        assert_eq!(SourceKind::from_tag(0), Some(SourceKind::Library));
        assert_eq!(SourceKind::from_tag(1), Some(SourceKind::Lean));
        assert_eq!(SourceKind::from_tag(2), Some(SourceKind::Script));
        assert_eq!(SourceKind::from_tag(3), Some(SourceKind::Window));
        assert_eq!(SourceKind::Library.tag(), 0);
        assert_eq!(SourceKind::Lean.tag(), 1);
        assert_eq!(SourceKind::Script.tag(), 2);
        assert_eq!(SourceKind::Window.tag(), 3);
    }

    #[test]
    fn an_unknown_source_kind_tag_is_refused() {
        assert_eq!(SourceKind::from_tag(4), None);
        assert_eq!(SourceKind::from_tag(u64::MAX), None);
    }
}
