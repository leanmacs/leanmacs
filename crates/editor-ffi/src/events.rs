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
//! [`ScriptedSource`] is the fake event source. It is public, not
//! `cfg(test)`, so the tests of any crate can feed a queue a script of
//! events.
//!
//! The queue lives in `editor-ffi` because no other crate may depend on this
//! one. A service crate defines its own port for reporting, and `editor-ffi`
//! adapts that port to a queue.

use std::collections::VecDeque;
use std::ops::Deref;
use std::sync::{Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};

/// What an [`Event`] says happened.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventKind {
    /// The queue has been quit: the task pulling from it must return.
    Quit = 0,
    /// A message with no meaning to the library: its `code` and `text` are
    /// whatever the source chose.
    Message = 1,
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
        }
    }

    /// A [`EventKind::Message`] from `source`.
    pub fn message(source: Source, code: u64, text: impl Into<String>) -> Self {
        Self {
            source,
            kind: EventKind::Message,
            code,
            text: text.into(),
        }
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
    /// The events to feed, first to last.
    script: Vec<Event>,
}

impl ScriptedSource {
    /// A source that will feed `script`.
    pub const fn new(script: Vec<Event>) -> Self {
        Self { script }
    }

    /// Feeds the script to `queue` on the calling thread.
    pub fn feed(self, queue: &Queue) {
        for event in self.script {
            queue.push(event);
        }
    }

    /// Feeds the script to `queue` from a new thread.
    pub fn feed_from_thread<Q>(self, queue: Q) -> JoinHandle<()>
    where
        Q: Deref<Target = Queue> + Send + 'static,
    {
        thread::spawn(move || self.feed(&queue))
    }
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
            ScriptedSource::new(script(id, EVENTS)).feed_from_thread(Arc::clone(&queue));
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

        let feeder = ScriptedSource::new(script(7, 3)).feed_from_thread(Arc::clone(&queue));

        let pulled: Vec<Event> = (0..3).map(|_| pull(&queue)).collect();
        assert_eq!(pulled, script(7, 3));
        assert_ne!(feeder.thread().id(), caller);
    }

    #[test]
    fn every_event_kind_converts_from_its_tag() {
        assert_eq!(EventKind::from_tag(0), Some(EventKind::Quit));
        assert_eq!(EventKind::from_tag(1), Some(EventKind::Message));
        assert_eq!(EventKind::Quit.tag(), 0);
        assert_eq!(EventKind::Message.tag(), 1);
    }

    #[test]
    fn an_unknown_event_kind_tag_is_refused() {
        assert_eq!(EventKind::from_tag(2), None);
        assert_eq!(EventKind::from_tag(u64::MAX), None);
    }

    #[test]
    fn every_source_kind_converts_from_its_tag() {
        assert_eq!(SourceKind::from_tag(0), Some(SourceKind::Library));
        assert_eq!(SourceKind::from_tag(1), Some(SourceKind::Lean));
        assert_eq!(SourceKind::from_tag(2), Some(SourceKind::Script));
        assert_eq!(SourceKind::Library.tag(), 0);
        assert_eq!(SourceKind::Lean.tag(), 1);
        assert_eq!(SourceKind::Script.tag(), 2);
    }

    #[test]
    fn an_unknown_source_kind_tag_is_refused() {
        assert_eq!(SourceKind::from_tag(3), None);
        assert_eq!(SourceKind::from_tag(u64::MAX), None);
    }
}
