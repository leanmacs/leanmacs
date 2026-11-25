//! The event queues: how anything the Rust library has to tell Lean gets
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
//! ([`EDITOR`]: input and events for the editor thread) and the completion
//! queue ([`COMPLETION`]: results of service requests, pulled by a dedicated
//! Lean task). `editor-ffi`'s C functions forward to those two instances.
//!
//! [`ScriptedSource`] is the fake event source. It is public, not
//! `cfg(test)`, so the tests of any crate, and the Lean test executable
//! through `editor-ffi`'s `editor_ffi_events_script_feed`, can feed a queue
//! a script of events.
//!
//! A service reports that a request has finished with an
//! [`EventKind::Completion`] on the completion queue, whose code is the id
//! the request was made with and whose source is the service: [`complete`]
//! for a service of the core, with its fixed id, and
//! [`Service`](crate::Service) for a service of a package's crate.
//!
//! The queues live in this crate, which `editor-ffi` and the crate of every
//! package depend on, and all of the editor is linked from one Rust
//! archive, so the process holds one of each.

use std::collections::VecDeque;
use std::io;
use std::ops::Deref;
use std::sync::{Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};

use editor_wait::{self as wait, HangGuard};

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
    /// This and the kinds after it come from a window (`editor-ffi`'s
    /// `window`), whose module docs say what each `code` means.
    WindowOpened = 3,
    /// The window gained the keyboard focus (`code` 1) or lost it (0).
    WindowFocus = 4,
    /// A key was pressed or released: the bits of its `code` say which, its
    /// `text` is what the key produced, and its words are which key it was
    /// and the modifiers held.
    Key = 5,
    /// A step of an input method's composition: its `code` says which, and
    /// its `text` is the text being composed or committed.
    Composition = 6,
    /// The pointer did something in the window: its `code` says what, and its
    /// words where, with which button and with which modifiers held.
    Pointer = 7,
    /// The user asked for the window to be closed.
    CloseRequested = 8,
    /// The window's drawable area changed size, or its scale factor did: its
    /// words are the new size and scale.
    Resize = 9,
    /// The system asked for files to be opened: its words are the paths.
    OpenFiles = 10,
    /// The system asked the program to quit (Command-Q, the Dock's Quit, a
    /// logout): no code, text or words.
    QuitRequested = 11,
    /// A command item of the menu bar was chosen: its `text` is the
    /// command's name, with no code or words.
    Menu = 12,
    /// A parse of a document whose text is highlighted was delivered: the
    /// next scene draws with it. From the library's syntax service
    /// (`editor-ffi`'s `syntax`), with no code, text or words.
    Parsed = 13,
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
            7 => Some(Self::Pointer),
            8 => Some(Self::CloseRequested),
            9 => Some(Self::Resize),
            10 => Some(Self::OpenFiles),
            11 => Some(Self::QuitRequested),
            12 => Some(Self::Menu),
            13 => Some(Self::Parsed),
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
    /// The event's detail, as words whose meaning the kind sets; empty for a
    /// kind that has none. They cross as words do (`editor-ffi`'s
    /// `words.rs`).
    pub words: Vec<u64>,
    /// The instant the source says the event happened, in nanoseconds on
    /// the library's input clock (`editor-ffi`'s `window::InputClock`), or 0
    /// when the source does not say. Only a window says.
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
            words: Vec::new(),
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
            words: Vec::new(),
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
            words: Vec::new(),
            stamp: 0,
        }
    }

    /// The [`EventKind::Parsed`] of the service `service`.
    pub const fn parsed(service: Source) -> Self {
        Self {
            source: service,
            kind: EventKind::Parsed,
            code: 0,
            text: String::new(),
            words: Vec::new(),
            stamp: 0,
        }
    }

    /// This event, said to have happened at `stamp`.
    pub fn stamped(self, stamp: u64) -> Self {
        Self { stamp, ..self }
    }

    /// This event, with `words` as its detail.
    pub fn with_words(self, words: Vec<u64>) -> Self {
        Self { words, ..self }
    }
}

/// A queue of events that any thread pushes to and a Lean task pulls from.
pub struct Queue {
    /// The events and the pulls waiting for them.
    state: Mutex<State>,
    /// Signalled when an event joins the queue or the queue is quit.
    changed: Condvar,
    /// Signalled when a pull parks: what [`await_waiting`](Self::await_waiting)
    /// waits on. A Condvar of its own, so a push's `notify_one` on `changed`
    /// always reaches a parked pull and never a test's wait.
    parked: Condvar,
    /// Called on a pull's thread, with the state unlocked, each time a pull
    /// is about to park. Set once, by a test.
    #[cfg(test)]
    before_park: std::sync::OnceLock<Box<dyn Fn() + Send + Sync>>,
    /// Called each time [`await_waiting`](Self::await_waiting) reads the
    /// count, with the count, under the lock. Set once, by a test.
    #[cfg(test)]
    awaited: std::sync::OnceLock<Box<dyn Fn(usize) + Send + Sync>>,
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
            parked: Condvar::new(),
            #[cfg(test)]
            before_park: std::sync::OnceLock::new(),
            #[cfg(test)]
            awaited: std::sync::OnceLock::new(),
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
            #[cfg(test)]
            if let Some(hook) = self.before_park.get() {
                drop(state);
                hook();
                state = self.state();
                // What was pushed or quit while unlocked is seen first.
                if let Some(event) = state.events.pop_front() {
                    return event;
                }
                if state.quit {
                    return Event::quit();
                }
            }
            state.waiting += 1;
            self.parked.notify_all();
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

    /// Waits until at least `pulls` pulls are parked on the queue, and says
    /// whether they were: false only once `guard` has run out first. A
    /// readout for tests, which use it to know a pull is parked before they
    /// push, on an event and never a poll: a pull notifies it as it parks,
    /// under the lock its wait then releases, so once this has seen the
    /// count the pull is in its wait and a push reaches it. It waits on a
    /// Condvar of its own, so it never takes a push's wake-up from a pull.
    ///
    /// `guard` names the pull's park: only a pull that never parks reaches
    /// it. A bound past what the clock can count is no bound.
    pub fn await_waiting(&self, pulls: usize, guard: HangGuard) -> bool {
        let (_state, parked) = wait::wait_while(&self.parked, self.state(), guard, |state| {
            #[cfg(test)]
            if let Some(hook) = self.awaited.get() {
                hook(state.waiting);
            }
            state.waiting < pulls
        });
        parked
    }

    /// How many events the queue holds that have not been pulled.
    pub fn queued(&self) -> usize {
        self.state().events.len()
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
    /// `source_id`, with the codes 0, 1, 2 and so on. Each carries two words,
    /// its code and the largest word less its code, so a test sees words
    /// cross, the largest among them.
    pub fn numbered(source_id: u64, count: u64) -> Self {
        let source = Source {
            kind: SourceKind::Script,
            id: source_id,
        };
        Self {
            script: Box::new((0..count).map(move |code| {
                Event::message(source, code, format!("scripted {code}"))
                    .with_words(vec![code, u64::MAX - code])
            })),
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
pub static EDITOR: Queue = Queue::new();

/// The process's completion queue.
pub static COMPLETION: Queue = Queue::new();

/// Queues the completion of the request `request` on the process's
/// completion queue, from the library's service `service`, and returns
/// whether it was accepted: a queue that has been quit drops it.
///
/// This is how a service of the core reports that a request has finished,
/// with its fixed id; a service of a package's crate reports through its
/// [`Service`](crate::Service).
pub fn complete(service: u64, request: u64) -> bool {
    let source = Source {
        kind: SourceKind::Library,
        id: service,
    };
    COMPLETION.push(Event::completion(source, request))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::mpsc::{self, Receiver, TryRecvError};
    use std::thread;
    use std::time::Duration;

    /// hang guard: the return, the park or the reading each wait ends on;
    /// only a hang reaches the bound, and the test then fails as a hang.
    /// How long a test waits for something that should happen at once:
    /// only a broken queue takes this long.
    const DEADLINE: HangGuard = HangGuard::on(
        "a call's return, a pull's park or a reading",
        Duration::from_secs(5),
    );

    /// [`Queue::await_waiting`], the readout these tests are of: the one
    /// place they call it.
    fn await_waiting(queue: &Queue, pulls: usize, guard: HangGuard) -> bool {
        #[expect(
            clippy::disallowed_methods,
            reason = "waits for `pulls` pulls to park on the queue, on `Queue::await_waiting`, the readout these tests are of"
        )]
        queue.await_waiting(pulls, guard)
    }

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
        wait::recv(result, DEADLINE)
            .unwrap_or_else(|missed| panic!("{what} did not return: {missed}"))
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

    /// Waits until `pulls` pulls are parked on `queue`, on the park itself
    /// ([`Queue::await_waiting`]); panics if they are not by the deadline.
    fn wait_for_parked(queue: &Queue, pulls: usize) {
        assert!(
            await_waiting(queue, pulls, DEADLINE),
            "{} pulls were parked, not {pulls}: {DEADLINE}",
            queue.waiting()
        );
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
    fn a_queue_counts_the_events_it_holds_until_they_are_pulled() {
        let queue = Arc::new(Queue::new());
        assert_eq!(queue.queued(), 0);
        for event in script(1, 2) {
            queue.push(event);
        }
        assert_eq!(queue.queued(), 2);
        pull(&queue);
        assert_eq!(queue.queued(), 1);
        queue.quit();
        pull(&queue);
        // A quit queue holds nothing more: every pull is the quit.
        assert_eq!(queue.queued(), 0);
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

    /// Has `queue` call `held` each time a pull is about to park, on the
    /// pull's thread.
    fn before_park(queue: &Queue, held: impl Fn() + Send + Sync + 'static) {
        assert!(queue.before_park.set(Box::new(held)).is_ok(), "set once");
    }

    /// Where each count [`Queue::await_waiting`] reads on `queue` arrives.
    fn counts_awaited(queue: &Queue) -> Receiver<usize> {
        let (read, counts) = mpsc::channel();
        let read = Mutex::new(read);
        let hook = move |count| {
            let _ = read
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .send(count);
        };
        assert!(queue.awaited.set(Box::new(hook)).is_ok(), "set once");
        counts
    }

    #[test]
    fn await_waiting_returns_only_once_a_pull_held_before_its_park_has_parked() {
        let queue = Arc::new(Queue::new());
        // The pull is held on its way to the park until the test lets it go.
        let (holding, held) = mpsc::channel();
        let (release, released) = mpsc::channel::<()>();
        let hold = Mutex::new((holding, released));
        before_park(&queue, move || {
            let hold = hold.lock().unwrap_or_else(PoisonError::into_inner);
            let _ = hold.0.send(());
            let _ = hold.1.recv();
        });
        let counts = counts_awaited(&queue);

        let pulled = start_pull(&queue);
        wait::recv(&held, DEADLINE).expect("the pull reaches its park");
        let awaited = {
            let queue = Arc::clone(&queue);
            start(move || await_waiting(&queue, 1, DEADLINE))
        };
        assert_eq!(
            wait::recv(&counts, DEADLINE),
            Ok(0),
            "the wait reads no parked pull while the pull is held"
        );
        release.send(()).expect("the pull is held");

        // A wait that returned at the first reading never reads the park.
        assert_eq!(
            wait::recv(&counts, DEADLINE),
            Ok(1),
            "the wait reads the count again once the pull has parked"
        );
        assert!(finish(&awaited, "the wait for the park"));
        queue.push(message(1, 0));
        assert_eq!(finish(&pulled, "the parked pull"), message(1, 0));
    }

    #[test]
    fn a_push_reaches_the_parked_pull_while_a_wait_for_more_pulls_is_parked() {
        let queue = Arc::new(Queue::new());
        let counts = counts_awaited(&queue);
        let first = start_pull(&queue);
        assert!(await_waiting(&queue, 1, DEADLINE));
        // What that wait read, drained: the last reading was the park.
        assert_eq!(counts.try_iter().last(), Some(1));
        let awaited = {
            let queue = Arc::clone(&queue);
            start(move || await_waiting(&queue, 2, DEADLINE))
        };
        // The wait for two has read one and is parked, under the lock it
        // read the count with.
        assert_eq!(wait::recv(&counts, DEADLINE), Ok(1));

        queue.push(message(1, 0));

        // On one Condvar the push's one wake-up could go to the wait.
        assert_eq!(finish(&first, "the parked pull"), message(1, 0));
        let second = start_pull(&queue);
        let third = start_pull(&queue);
        assert!(finish(&awaited, "the wait for two pulls"));
        queue.quit();
        assert_eq!(finish(&second, "a parked pull"), Event::quit());
        assert_eq!(finish(&third, "a parked pull"), Event::quit());
    }

    #[test]
    fn await_waiting_says_no_once_its_bound_has_passed_with_no_pull_parked() {
        let queue = Queue::new();
        const NONE: HangGuard = HangGuard::held("a pull, which none makes", Duration::ZERO);
        assert!(!await_waiting(&queue, 1, NONE));
        assert!(await_waiting(&queue, 0, NONE));
    }

    #[test]
    fn await_waiting_takes_a_bound_past_what_the_clock_can_count_as_no_bound() {
        let queue = Queue::new();
        assert!(await_waiting(&queue, 0, DEADLINE.with_bound(Duration::MAX)));
        assert!(await_waiting(
            &queue,
            0,
            DEADLINE.with_bound(Duration::from_millis(u64::MAX))
        ));
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
            assert_eq!(event.words, [code, u64::MAX - code]);
        }
    }

    #[test]
    fn an_event_has_no_words_until_it_is_given_some() {
        let source = Source {
            kind: SourceKind::Lean,
            id: 1,
        };

        assert!(Event::quit().words.is_empty());
        assert!(Event::message(source, 1, "").words.is_empty());
        assert!(Event::completion(source, 1).words.is_empty());
        assert_eq!(
            Event::message(source, 1, "a").with_words(vec![3, 4]).words,
            [3, 4]
        );
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
        // The feeder stops at the push the quit queue refuses: its thread
        // ends, and is joined.
        let joined = finish(
            &start(move || feeder.join()),
            "the source feeding a quit queue",
        );
        joined.expect("the feeder's thread");
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
            (7, EventKind::Pointer),
            (8, EventKind::CloseRequested),
            (9, EventKind::Resize),
            (10, EventKind::OpenFiles),
            (11, EventKind::QuitRequested),
            (12, EventKind::Menu),
        ];
        for (tag, kind) in kinds {
            assert_eq!(EventKind::from_tag(tag), Some(kind));
            assert_eq!(kind.tag(), tag);
        }
    }

    #[test]
    fn a_parse_delivered_is_its_own_kind() {
        assert_eq!(EventKind::from_tag(13), Some(EventKind::Parsed));
        assert_eq!(EventKind::Parsed.tag(), 13);
        let service = Source {
            kind: SourceKind::Library,
            id: 5,
        };
        assert_eq!(
            Event::parsed(service),
            Event {
                source: service,
                kind: EventKind::Parsed,
                code: 0,
                text: String::new(),
                words: Vec::new(),
                stamp: 0,
            }
        );
    }

    #[test]
    fn an_unknown_event_kind_tag_is_refused() {
        assert_eq!(EventKind::from_tag(14), None);
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
                words: Vec::new(),
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
                words: Vec::new(),
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
