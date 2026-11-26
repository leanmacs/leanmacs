//! The worker: one loop that runs sessions' rounds, off the editor thread.
//!
//! A [`Worker`] holds a queue of sessions, each in it at most once. A touch
//! ([`Handle::touch`]) tells a session of a revision and queues it; the
//! worker takes the next queued session and runs one round
//! ([`Session::parse_once`]). A session is taken out of the queue before
//! its round, so a touch during the round queues it again; and a round
//! that was [`Outcome::Stale`] queues it again too, since its text has
//! moved on. A session whose text is gone, or that nobody holds any more,
//! is dropped.
//!
//! # Idle refreshes
//!
//! An edit's round keeps the incremental reparse ([`crate::session`], step
//! 3), which while the text has an error may differ from a fresh parse. So
//! the worker also keeps a schedule of *refreshes*, each a session and a
//! deadline on a [`Clock`]:
//!
//! - **A touch with a revision newer than every one the session was told
//!   of** (an edit, [`Session::touch`]) sets the session's refresh to the
//!   clock's reading plus the interval, replacing any deadline before: an
//!   edit during the interval postpones the refresh. Every such touch takes
//!   the queue lock to do it, whether or not the session is queued already:
//!   one short lock on the editor thread, which never waits for a parse,
//!   since no round holds the queue lock while it parses.
//! - **A touch at a revision told already** (an attach, or a change of
//!   injections at the text's own revision) sets and moves no deadline.
//! - **A session whose grammar's policy is
//!   [`ReparsePolicy::Whole`]** is never
//!   scheduled: each of its rounds is a whole parse already.
//! - **What runs next.** A queued round runs first: edits before refreshes.
//!   Otherwise the first refresh whose deadline the clock has reached runs
//!   ([`Session::refresh_once`]), earliest deadline first, then the lower
//!   session id. A refresh whose session nobody holds, or whose text is
//!   gone, is dropped.
//! - **The interval** is set when the worker is made, and changed for every
//!   deadline set from then on by [`Handle::set_refresh_after`].
//!
//! The schedule itself is pure (`Refreshes`): which entry is due when, and
//! what a later deadline does to an earlier one, are tested with no thread
//! and no clock.
//!
//! The crate starts no thread: [`Worker::run`] is the loop, which parks
//! while nothing is queued, with no deadline when no refresh is scheduled
//! and until the earliest refresh's deadline otherwise, and whoever wires
//! the library together runs it on a thread of its own, as `editor-ffi`
//! does. A touch, a stop, and [`Handle::wake`] wake it; `wake` is for a
//! test that has moved a [`ManualClock`](crate::clock::ManualClock). Tests
//! step it on their own thread ([`Worker::step`]); `tests/worker.rs` runs
//! the loop on a thread, and on a clock that moves by itself shows a park
//! ended by its deadline alone, with nothing waking it.
//!
//! # Registrations
//!
//! The grammars the syntax can parse with are state of the process's
//! syntax service, so in production a registration ([`Syntax::register`])
//! reaches the syntax only as a request on this worker's queue
//! ([`Handle::register`]), in the order it was queued:
//!
//! - **Each step answers the registrations first.** Each step of the loop,
//!   and of [`Worker::step`], first takes every registration queued and
//!   answers each, in order, with no lock held, and only then runs the next
//!   round or refresh. A registration only changes which grammar a parser
//!   opened afterwards gets, so answering it ahead of the queued rounds
//!   means an attach made after its answer opens the registered grammar.
//! - **The answer is a callback**, called once on the loop's thread with the
//!   registered name or the refusal. A caller that must not block (the
//!   editor thread, through `editor-ffi`'s completion queue) keeps the
//!   answer and completes a wait with it.
//! - **A flush** ([`Handle::flush_registrations`]) is a barrier in the same
//!   order: its callback is called once every registration queued before it
//!   is answered.
//! - **No caller is left without an answer.** When the loop ends, by
//!   [`Handle::stop`] or by a panic in a round, every registration still
//!   queued is answered `None` and every flush is called; one queued on a
//!   stopped worker is answered `None` at once.

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError, Weak};
use std::time::Duration;

use editor_text::Revision;

use crate::clock::Clock;
use crate::port::{GrammarName, GrammarSource, RegistrationRefusal, ReparsePolicy, Syntax};
use crate::session::{Outcome, Session};

/// What a registration's callback is handed: the registered name or the
/// refusal, or `None` when the loop ended before it answered.
pub type Answer = Option<Result<GrammarName, RegistrationRefusal>>;

/// A registration's callback ([`Handle::register`]), called once with its
/// [`Answer`].
pub type Reply = Box<dyn FnOnce(Answer) + Send>;

/// What a registration queue holds: a registration, or a flush's barrier.
enum Request {
    /// Register the grammar of a source, and hand the answer to the reply.
    Register(GrammarSource, Reply),
    /// Call this once every request before it is answered.
    Barrier(Box<dyn FnOnce() + Send>),
}

impl Request {
    /// Ends the request with no answer: the loop ended before it.
    fn drop_unanswered(self) {
        match self {
            Self::Register(_, reply) => reply(None),
            Self::Barrier(done) => done(),
        }
    }
}

/// The longest the loop parks before it looks at the clock again. A
/// deadline may be as far away as a `u64` of milliseconds, which no
/// platform timeout holds, so a park is cut to this and the loop simply
/// parks again.
const LONGEST_PARK: Duration = Duration::from_secs(3600);

/// The refreshes not yet due: each an entry, of a session by its id, with a
/// deadline in milliseconds on some clock.
struct Refreshes<T> {
    /// Every refresh as `(deadline, id)`, so the first is the next due.
    by_due: BTreeSet<(u64, u64)>,
    /// The deadline and the entry of every refresh, by id.
    entries: BTreeMap<u64, (u64, T)>,
}

impl<T> Refreshes<T> {
    /// A schedule with nothing in it.
    const fn new() -> Self {
        Self {
            by_due: BTreeSet::new(),
            entries: BTreeMap::new(),
        }
    }

    /// Sets the refresh of `id` to `entry` at `due`, in place of any
    /// deadline it had.
    fn postpone(&mut self, id: u64, entry: T, due: u64) {
        if let Some((before, _)) = self.entries.insert(id, (due, entry)) {
            self.by_due.remove(&(before, id));
        }
        self.by_due.insert((due, id));
    }

    /// Takes out the refresh due first at `now`: the earliest deadline that
    /// is `now` or earlier, and of two with one deadline the lower id.
    /// `None` when none is due.
    fn take_due(&mut self, now: u64) -> Option<T> {
        let &(due, id) = self.by_due.first()?;
        if due > now {
            return None;
        }
        self.by_due.remove(&(due, id));
        self.entries.remove(&id).map(|(_, entry)| entry)
    }

    /// The earliest deadline, if anything is scheduled.
    fn next_due(&self) -> Option<u64> {
        self.by_due.first().map(|&(due, _)| due)
    }

    /// Removes the refresh of `id`, if it has one.
    fn forget(&mut self, id: u64) {
        if let Some((due, _)) = self.entries.remove(&id) {
            self.by_due.remove(&(due, id));
        }
    }
}

/// The loop that parses, and its queue.
pub struct Worker<S: Syntax> {
    /// The implementation every round parses with.
    syntax: Arc<S>,
    /// The queue, shared with the handles.
    shared: Arc<Shared<S>>,
}

/// What a worker shares with its handles.
struct Shared<S: Syntax> {
    /// The queue and the refreshes.
    queue: Mutex<Queue<S>>,
    /// Woken when a session is queued, a refresh is scheduled, a
    /// registration or a flush is queued, the worker is stopped, or
    /// [`Handle::wake`] is called.
    ready: Condvar,
    /// Where the time is read.
    clock: Arc<dyn Clock>,
    /// How long a text goes unchanged after an edit before it is refreshed,
    /// in milliseconds.
    refresh_after_ms: AtomicU64,
}

/// The sessions waiting for a round, the refreshes scheduled, and whether
/// the worker is stopped.
struct Queue<S: Syntax> {
    /// The sessions, in the order they were queued. Each is in it at most
    /// once.
    sessions: VecDeque<Weak<Session<S>>>,
    /// The refreshes, each a session's.
    refreshes: Refreshes<Weak<Session<S>>>,
    /// The registrations and flushes, in the order they were queued.
    registrations: VecDeque<Request>,
    /// Whether the loop should end.
    stopped: bool,
}

/// What reaches a worker from anywhere: touching a session, changing the
/// interval, waking and stopping the loop.
pub struct Handle<S: Syntax> {
    /// The queue.
    shared: Arc<Shared<S>>,
}

impl<S: Syntax> Clone for Handle<S> {
    fn clone(&self) -> Self {
        Self {
            shared: self.shared.clone(),
        }
    }
}

/// What the loop does next.
enum Next<S: Syntax> {
    /// Answer these registrations and flushes, in order.
    Requests(VecDeque<Request>),
    /// Run this job.
    Job(Job<S>),
}

/// Ends the loop's queue when the loop returns or unwinds: marks the worker
/// stopped, and ends every registration and flush still queued with no
/// answer, so no caller waits for ever.
struct Drain<'a, S: Syntax>(&'a Shared<S>);

impl<S: Syntax> Drop for Drain<'_, S> {
    fn drop(&mut self) {
        let requests = {
            let mut queue = self.0.lock();
            queue.stopped = true;
            std::mem::take(&mut queue.registrations)
        };
        for request in requests {
            request.drop_unanswered();
        }
    }
}

/// What a worker runs next.
enum Job<S: Syntax> {
    /// A queued session's round.
    Round(Weak<Session<S>>),
    /// A session's refresh, due.
    Refresh(Weak<Session<S>>),
}

impl<S: Syntax> Shared<S> {
    /// The queue, locked. A queue left by a panic is whole: a poisoned lock
    /// is used as it is.
    fn lock(&self) -> MutexGuard<'_, Queue<S>> {
        self.queue.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Queues `session` unless it is queued already.
    fn queue(&self, session: &Arc<Session<S>>) {
        if !session.queued.swap(true, Ordering::AcqRel) {
            self.lock().sessions.push_back(Arc::downgrade(session));
            self.ready.notify_one();
        }
    }

    /// The next job due at the clock's reading, taken out: a queued round
    /// first, then a refresh.
    fn next(&self, queue: &mut Queue<S>) -> Option<Job<S>> {
        if let Some(next) = queue.sessions.pop_front() {
            return Some(Job::Round(next));
        }
        let now = self.clock.now_ms();
        queue.refreshes.take_due(now).map(Job::Refresh)
    }
}

impl<S: Syntax> Worker<S> {
    /// A worker that parses with `syntax`, with nothing queued, which
    /// refreshes a text once it has gone `refresh_after` unchanged after an
    /// edit, as measured on `clock`.
    pub fn new(syntax: Arc<S>, clock: Arc<dyn Clock>, refresh_after: Duration) -> Self {
        Self {
            syntax,
            shared: Arc::new(Shared {
                queue: Mutex::new(Queue {
                    sessions: VecDeque::new(),
                    refreshes: Refreshes::new(),
                    registrations: VecDeque::new(),
                    stopped: false,
                }),
                ready: Condvar::new(),
                clock,
                refresh_after_ms: AtomicU64::new(millis(refresh_after)),
            }),
        }
    }

    /// A handle to touch sessions and stop the loop with.
    pub fn handle(&self) -> Handle<S> {
        Handle {
            shared: self.shared.clone(),
        }
    }

    /// Answers every registration and flush queued, in order, then runs
    /// one round of the next queued session or, with none queued, the
    /// first refresh due, and returns how that ended: [`Outcome::Gone`] too
    /// for a session nobody holds any more. `None` when no session is
    /// queued and no refresh is due.
    pub fn step(&self) -> Option<Outcome> {
        let requests = std::mem::take(&mut self.shared.lock().registrations);
        self.answer(requests);
        let job = self.shared.next(&mut self.shared.lock())?;
        Some(self.work(&job))
    }

    /// Answers each of `requests`, in order, with no lock held: a
    /// registration with the syntax's answer, a flush by calling it.
    fn answer(&self, requests: VecDeque<Request>) {
        for request in requests {
            match request {
                Request::Register(source, reply) => reply(Some(self.syntax.register(&source))),
                Request::Barrier(done) => done(),
            }
        }
    }

    /// Runs `job`, which was just taken out of the queue or the schedule.
    fn work(&self, job: &Job<S>) -> Outcome {
        let (Job::Round(next) | Job::Refresh(next)) = job;
        let Some(session) = next.upgrade() else {
            return Outcome::Gone;
        };
        let outcome = match job {
            Job::Round(_) => {
                session.queued.store(false, Ordering::Release);
                session.parse_once(&self.syntax)
            }
            Job::Refresh(_) => session.refresh_once(&self.syntax),
        };
        match outcome {
            Outcome::Stale(_) => self.shared.queue(&session),
            Outcome::Gone => self.shared.lock().refreshes.forget(session.id),
            Outcome::Delivered(_) | Outcome::UpToDate => {}
        }
        outcome
    }

    /// The loop: answers each registration and flush queued, runs each
    /// queued round and each refresh once it is due, and otherwise parks,
    /// with no deadline when no refresh is scheduled and until the earliest
    /// deadline otherwise, until the worker is stopped ([`Handle::stop`]).
    /// When it returns or unwinds, every registration still queued is
    /// answered `None` and every flush called (the module docs,
    /// "Registrations").
    pub fn run(&self) {
        let _drain = Drain(&self.shared);
        loop {
            let next = {
                let mut queue = self.shared.lock();
                loop {
                    if queue.stopped {
                        return;
                    }
                    if !queue.registrations.is_empty() {
                        break Next::Requests(std::mem::take(&mut queue.registrations));
                    }
                    if let Some(job) = self.shared.next(&mut queue) {
                        break Next::Job(job);
                    }
                    queue = match queue.refreshes.next_due() {
                        None => self
                            .shared
                            .ready
                            .wait(queue)
                            .unwrap_or_else(PoisonError::into_inner),
                        #[expect(
                            clippy::disallowed_methods,
                            reason = "production on the real clock: the worker's own park until its next refresh is due, not a test's bound"
                        )]
                        Some(due) => {
                            let now = self.shared.clock.now_ms();
                            let park =
                                Duration::from_millis(due.saturating_sub(now)).min(LONGEST_PARK);
                            self.shared
                                .ready
                                .wait_timeout(queue, park)
                                .unwrap_or_else(PoisonError::into_inner)
                                .0
                        }
                    };
                }
            };
            match next {
                Next::Requests(requests) => self.answer(requests),
                Next::Job(job) => {
                    self.work(&job);
                }
            }
        }
    }
}

/// `duration` in whole milliseconds, a `u64` of them at most.
fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

impl<S: Syntax> Handle<S> {
    /// Tells `session` its text has reached `revision`
    /// ([`Session::touch`]) and queues it for a round, unless it is queued
    /// already. A revision newer than every one the session was told of is
    /// an edit: the session's refresh is set to the clock's reading plus
    /// the interval, in place of any deadline before, unless its grammar is
    /// reparsed whole (the module docs, "Idle refreshes").
    pub fn touch(&self, session: &Arc<Session<S>>, revision: Revision) {
        let edit = session.touch(revision) && session.policy() == ReparsePolicy::Incremental;
        let queue_it = !session.queued.swap(true, Ordering::AcqRel);
        if !edit && !queue_it {
            return;
        }
        let due = edit.then(|| {
            self.shared
                .clock
                .now_ms()
                .saturating_add(self.shared.refresh_after_ms.load(Ordering::Relaxed))
        });
        let mut queue = self.shared.lock();
        if let Some(due) = due {
            queue
                .refreshes
                .postpone(session.id, Arc::downgrade(session), due);
        }
        if queue_it {
            queue.sessions.push_back(Arc::downgrade(session));
        }
        drop(queue);
        self.shared.ready.notify_one();
    }

    /// Refreshes a text once it has gone `refresh_after` unchanged after an
    /// edit, for every deadline set from now on.
    pub fn set_refresh_after(&self, refresh_after: Duration) {
        self.shared
            .refresh_after_ms
            .store(millis(refresh_after), Ordering::Relaxed);
    }

    /// Has the loop look at the clock again. A real clock needs no telling;
    /// this is for a [`ManualClock`](crate::clock::ManualClock) a test has
    /// moved.
    pub fn wake(&self) {
        // Under the lock, so the loop is either parked, and hears this, or
        // has yet to read the clock, and reads the new time.
        let _queue = self.shared.lock();
        self.shared.ready.notify_all();
    }

    /// Queues the registration of the grammar `source` names, answered on
    /// the loop's thread before its next round, in order with the other
    /// registrations; `reply` is called once with the answer (the module
    /// docs, "Registrations"). On a stopped worker it is answered `None` at
    /// once, on the caller's thread. It never waits.
    pub fn register(&self, source: GrammarSource, reply: Reply) {
        self.queue_request(Request::Register(source, reply));
    }

    /// Queues a flush: `done` is called once every registration queued
    /// before it is answered. On a stopped worker it is called at once, on
    /// the caller's thread. It never waits.
    pub fn flush_registrations(&self, done: Box<dyn FnOnce() + Send>) {
        self.queue_request(Request::Barrier(done));
    }

    /// Queues `request` and wakes the loop, or ends it with no answer on a
    /// stopped worker, outside the lock.
    fn queue_request(&self, request: Request) {
        let mut queue = self.shared.lock();
        if queue.stopped {
            drop(queue);
            request.drop_unanswered();
            return;
        }
        queue.registrations.push_back(request);
        drop(queue);
        self.shared.ready.notify_all();
    }

    /// Ends the loop: [`Worker::run`] returns before its next round.
    pub fn stop(&self) {
        self.shared.lock().stopped = true;
        self.shared.ready.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;
    use std::thread;

    use editor_text::Text;

    use super::*;
    use crate::clock::ManualClock;
    use crate::fake::libraries::{self, Libraries};
    use crate::fake::{GRAMMAR, Parens, ParensParser};
    use crate::port::{GrammarName, GrammarSource, RegistrationRefusal};
    use crate::session::tests::{Recording, Recovers, Revisions, TextSource, replace};

    /// The interval the tests refresh after.
    const INTERVAL: Duration = Duration::from_millis(500);

    /// A worker over `syntax` on `clock`, refreshing after [`INTERVAL`].
    fn worker_of<S: Syntax>(syntax: S, clock: &ManualClock) -> Worker<S> {
        Worker::new(Arc::new(syntax), Arc::new(clock.clone()), INTERVAL)
    }

    /// A worker over the fake on a clock of its own.
    fn worker() -> Worker<Parens> {
        worker_of(Parens, &ManualClock::new())
    }

    /// A text and a session of it on `worker`.
    fn session_of<S: Syntax>(
        worker: &Worker<S>,
        text: &str,
    ) -> (Arc<Mutex<Text>>, Arc<Session<S>>) {
        let text = Arc::new(Mutex::new(Text::from(text)));
        let source = Box::new(TextSource(Arc::downgrade(&text)));
        let session = Session::new(&*worker.syntax, GrammarName::new(GRAMMAR), source).unwrap();
        (text, Arc::new(session))
    }

    /// Whether the tree `session` delivered last is of `text` as it is now
    /// and equals a fresh parse of it.
    fn delivered_is_fresh<S: Syntax<Tree = crate::fake::ParensTree>>(
        text: &Mutex<Text>,
        session: &Session<S>,
    ) -> bool {
        let snapshot = text.lock().unwrap().snapshot();
        let fresh = Parens.parse(&mut ParensParser, &snapshot, None);
        session.parsed().is_some_and(|parsed| {
            parsed.revision == snapshot.revision()
                && Parens.nodes(&parsed.tree) == Parens.nodes(&fresh)
        })
    }

    /// How many whole parses `syntax` has made.
    fn whole_parses(syntax: &Recording) -> usize {
        syntax
            .olds
            .lock()
            .unwrap()
            .iter()
            .filter(|old| old.is_none())
            .count()
    }

    mod refreshes {
        use super::super::Refreshes;

        #[test]
        fn a_later_deadline_replaces_an_earlier_one_for_a_session() {
            let mut refreshes = Refreshes::new();
            refreshes.postpone(7, "seven", 100);
            refreshes.postpone(7, "seven again", 300);

            assert_eq!(refreshes.next_due(), Some(300));
            assert_eq!(refreshes.take_due(299), None);
            assert_eq!(refreshes.take_due(300), Some("seven again"));
            assert_eq!(refreshes.take_due(1_000), None);
            assert_eq!(refreshes.next_due(), None);
        }

        #[test]
        fn due_sessions_come_earliest_first_then_by_lower_id() {
            let mut refreshes = Refreshes::new();
            refreshes.postpone(3, "three", 200);
            refreshes.postpone(2, "two", 200);
            refreshes.postpone(9, "nine", 100);
            refreshes.postpone(1, "one", 400);

            assert_eq!(refreshes.next_due(), Some(100));
            assert_eq!(refreshes.take_due(250), Some("nine"));
            assert_eq!(refreshes.take_due(250), Some("two"));
            assert_eq!(refreshes.take_due(250), Some("three"));
            assert_eq!(refreshes.take_due(250), None);
            assert_eq!(refreshes.next_due(), Some(400));
        }

        #[test]
        fn a_forgotten_session_is_not_due() {
            let mut refreshes = Refreshes::new();
            refreshes.postpone(1, "one", 100);
            refreshes.postpone(2, "two", 200);
            refreshes.forget(1);
            refreshes.forget(5);

            assert_eq!(refreshes.next_due(), Some(200));
            assert_eq!(refreshes.take_due(1_000), Some("two"));
        }
    }

    #[test]
    fn a_worker_with_nothing_queued_runs_no_round() {
        let worker = worker();

        assert_eq!(worker.step(), None);
    }

    #[test]
    fn a_session_touched_twice_is_queued_once_and_delivered_at_the_newest_revision() {
        let worker = worker();
        let (text, session) = session_of(&worker, "(a)");
        let handle = worker.handle();
        handle.touch(&session, replace(&text, 0..0, "b "));
        handle.touch(&session, replace(&text, 0..0, "c "));

        assert_eq!(worker.step(), Some(Outcome::Delivered(Revision::new(2))));
        assert_eq!(worker.step(), None);
    }

    #[test]
    fn a_session_touched_again_after_its_round_is_queued_again() {
        let worker = worker();
        let (text, session) = session_of(&worker, "(a)");
        let handle = worker.handle();
        handle.touch(&session, Revision::new(0));
        worker.step();
        handle.touch(&session, replace(&text, 0..0, "b "));

        assert_eq!(worker.step(), Some(Outcome::Delivered(Revision::new(1))));
    }

    #[test]
    fn a_stale_round_queues_its_session_again() {
        let worker = worker();
        let (text, session) = session_of(&worker, "(a)");
        let handle = worker.handle();
        handle.touch(&session, Revision::new(0));
        // Told of a revision the text has not reached: every round is
        // stale until it reaches it.
        session.touch(Revision::new(1));

        assert_eq!(worker.step(), Some(Outcome::Stale(Revision::new(0))));
        replace(&text, 0..0, "b ");
        assert_eq!(worker.step(), Some(Outcome::Delivered(Revision::new(1))));
        assert_eq!(worker.step(), None);
    }

    #[test]
    fn a_session_whose_text_is_gone_or_that_nobody_holds_is_dropped() {
        let worker = worker();
        let handle = worker.handle();
        let (text, session) = session_of(&worker, "(a)");
        handle.touch(&session, Revision::new(0));
        drop(text);
        assert_eq!(worker.step(), Some(Outcome::Gone));
        assert_eq!(worker.step(), None);

        let (_text, session) = session_of(&worker, "(a)");
        handle.touch(&session, Revision::new(0));
        drop(session);
        assert_eq!(worker.step(), Some(Outcome::Gone));
        assert_eq!(worker.step(), None);
    }

    #[test]
    fn a_refresh_whose_session_is_dropped_or_whose_text_is_gone_is_dropped() {
        let clock = ManualClock::new();
        let worker = worker_of(Parens, &clock);
        let handle = worker.handle();
        let (text, session) = session_of(&worker, "(a)");
        handle.touch(&session, replace(&text, 0..0, "b "));
        worker.step();
        drop(text);
        clock.advance(500);
        assert_eq!(worker.step(), Some(Outcome::Gone));
        assert_eq!(worker.step(), None);

        let (text, session) = session_of(&worker, "(a)");
        handle.touch(&session, replace(&text, 0..0, "b "));
        worker.step();
        drop(session);
        clock.advance(500);
        assert_eq!(worker.step(), Some(Outcome::Gone));
        assert_eq!(worker.step(), None);
    }

    #[test]
    fn a_text_quiet_for_the_interval_after_an_edit_is_refreshed_to_a_fresh_parse() {
        let clock = ManualClock::new();
        let syntax = Recording {
            recovers: Recovers::Whole,
            ..Recording::default()
        };
        let worker = worker_of(syntax, &clock);
        let handle = worker.handle();
        let (text, session) = session_of(&worker, "(a b)");
        let delivered = Arc::new(Mutex::new(Vec::new()));
        session.subscribe(Box::new(Revisions(delivered.clone())));
        handle.touch(&session, Revision::new(0));
        worker.step();

        // An edit that leaves an error: the delivered tree is the
        // incremental one, not a fresh parse's.
        let revision = replace(&text, 0..0, "(");
        handle.touch(&session, revision);
        assert_eq!(worker.step(), Some(Outcome::Delivered(revision)));
        assert!(!delivered_is_fresh(&text, &session));

        clock.advance(499);
        assert_eq!(worker.step(), None);
        clock.advance(1);
        assert_eq!(worker.step(), Some(Outcome::Delivered(revision)));
        assert!(delivered_is_fresh(&text, &session));
        assert_eq!(
            *delivered.lock().unwrap(),
            [Revision::new(0), revision, revision]
        );
        assert_eq!(worker.step(), None);
    }

    #[test]
    fn an_edit_before_the_interval_ends_postpones_the_refresh() {
        let clock = ManualClock::new();
        let worker = worker_of(Recording::default(), &clock);
        let handle = worker.handle();
        let (text, session) = session_of(&worker, "(a b)");
        handle.touch(&session, Revision::new(0));
        worker.step();

        handle.touch(&session, replace(&text, 5..5, " c"));
        worker.step();
        clock.set(300);
        handle.touch(&session, replace(&text, 0..0, "d "));
        worker.step();
        let parses = whole_parses(&worker.syntax);

        clock.set(500);
        assert_eq!(worker.step(), None);
        clock.set(799);
        assert_eq!(worker.step(), None);
        assert_eq!(whole_parses(&worker.syntax), parses);
        clock.set(800);
        assert_eq!(worker.step(), Some(Outcome::UpToDate));
        assert_eq!(whole_parses(&worker.syntax), parses + 1);
    }

    #[test]
    fn two_edits_touched_before_a_step_are_refreshed_an_interval_after_the_later() {
        let clock = ManualClock::new();
        let worker = worker_of(Recording::default(), &clock);
        let handle = worker.handle();
        let (text, session) = session_of(&worker, "(a b)");
        handle.touch(&session, Revision::new(0));
        worker.step();

        // The second touch finds the session queued already, and still
        // postpones the refresh.
        handle.touch(&session, replace(&text, 5..5, " c"));
        clock.set(300);
        handle.touch(&session, replace(&text, 0..0, "d "));
        assert_eq!(worker.step(), Some(Outcome::Delivered(Revision::new(2))));
        let parses = whole_parses(&worker.syntax);

        clock.set(500);
        assert_eq!(worker.step(), None);
        clock.set(799);
        assert_eq!(worker.step(), None);
        clock.set(800);
        assert_eq!(worker.step(), Some(Outcome::UpToDate));
        assert_eq!(whole_parses(&worker.syntax), parses + 1);
    }

    #[test]
    fn a_touch_at_the_same_revision_neither_schedules_nor_postpones() {
        let clock = ManualClock::new();
        let worker = worker_of(Recording::default(), &clock);
        let handle = worker.handle();
        let (text, session) = session_of(&worker, "(a b)");
        // An attach at the text's own revision: no refresh.
        handle.touch(&session, Revision::new(0));
        worker.step();
        clock.set(10_000);
        assert_eq!(worker.step(), None);

        let revision = replace(&text, 5..5, " c");
        handle.touch(&session, revision);
        worker.step();
        // A change of injections at that revision, later: the refresh is
        // still due an interval after the edit.
        clock.set(10_400);
        handle.touch(&session, revision);
        assert_eq!(worker.step(), Some(Outcome::UpToDate));
        let parses = whole_parses(&worker.syntax);
        clock.set(10_500);
        assert_eq!(worker.step(), Some(Outcome::UpToDate));
        assert_eq!(whole_parses(&worker.syntax), parses + 1);
    }

    #[test]
    fn a_whole_grammars_session_is_never_scheduled() {
        let clock = ManualClock::new();
        let syntax = Recording {
            policy: Some(ReparsePolicy::Whole),
            ..Recording::default()
        };
        let worker = worker_of(syntax, &clock);
        let handle = worker.handle();
        let (text, session) = session_of(&worker, "(a b)");
        handle.touch(&session, Revision::new(0));
        worker.step();
        handle.touch(&session, replace(&text, 0..0, "("));
        worker.step();

        clock.set(10_000);
        assert_eq!(worker.step(), None);
    }

    #[test]
    fn a_queued_round_runs_before_a_refresh_that_is_due() {
        let clock = ManualClock::new();
        let worker = worker_of(Recording::default(), &clock);
        let handle = worker.handle();
        let (text, session) = session_of(&worker, "(a b)");
        let (other_text, other) = session_of(&worker, "(c)");
        handle.touch(&session, replace(&text, 5..5, " c"));
        worker.step();
        clock.set(500);
        handle.touch(&other, Revision::new(0));
        let _ = other_text;

        assert_eq!(worker.step(), Some(Outcome::Delivered(Revision::new(0))));
        assert_eq!(worker.step(), Some(Outcome::UpToDate));
        assert_eq!(worker.step(), None);
    }

    #[test]
    fn a_new_interval_is_used_for_every_deadline_set_after_it() {
        let clock = ManualClock::new();
        let worker = worker_of(Recording::default(), &clock);
        let handle = worker.handle();
        let (text, session) = session_of(&worker, "(a b)");
        handle.set_refresh_after(Duration::from_millis(50));
        handle.touch(&session, replace(&text, 5..5, " c"));
        worker.step();

        clock.set(49);
        assert_eq!(worker.step(), None);
        clock.set(50);
        assert_eq!(worker.step(), Some(Outcome::UpToDate));
    }

    /// The answers a registration's reply is handed, in order, and a reply
    /// that records into them.
    #[derive(Clone, Default)]
    struct Answers(Arc<Mutex<Vec<Answer>>>);

    impl Answers {
        /// A reply that records its answer.
        fn reply(&self) -> Reply {
            let answers = self.0.clone();
            Box::new(move |answer| answers.lock().unwrap().push(answer))
        }

        /// The answers recorded.
        fn all(&self) -> Vec<Answer> {
            self.0.lock().unwrap().clone()
        }
    }

    /// A worker over the fake with its table, on a clock of its own.
    fn libraries_worker() -> Worker<Libraries> {
        worker_of(Libraries::new(libraries::table()), &ManualClock::new())
    }

    /// A source of `symbol` in no library any test reads.
    fn source(symbol: &str) -> GrammarSource {
        GrammarSource {
            library: "/nowhere.so".into(),
            symbol: symbol.to_owned(),
            policy: None,
        }
    }

    #[test]
    fn a_registration_is_answered_by_the_next_step_and_lists_its_grammar() {
        let worker = libraries_worker();
        let answers = Answers::default();
        let brackets = GrammarName::new("brackets");
        worker
            .handle()
            .register(libraries::corpus().new, answers.reply());

        assert_eq!(answers.all(), []);
        assert!(!worker.syntax.grammars().contains(&brackets));
        assert_eq!(worker.step(), None);
        assert_eq!(answers.all(), [Some(Ok(brackets.clone()))]);
        assert!(worker.syntax.grammars().contains(&brackets));
    }

    #[test]
    fn a_step_answers_each_queued_registration_in_order_before_its_round() {
        let worker = worker_of(Recording::default(), &ManualClock::new());
        let (_text, session) = session_of(&worker, "(a)");
        let handle = worker.handle();
        let answers = Answers::default();
        handle.touch(&session, Revision::new(0));
        handle.register(source("tree_sitter_first"), answers.reply());
        handle.register(source("tree_sitter_second"), answers.reply());
        let before = worker.syntax.calls.lock().unwrap().len();

        let outcome = worker.step();

        assert_eq!(
            worker.syntax.calls.lock().unwrap()[before..],
            [
                "register tree_sitter_first",
                "register tree_sitter_second",
                "parse"
            ]
        );
        assert_eq!(outcome, Some(Outcome::Delivered(Revision::new(0))));
        assert_eq!(
            answers.all(),
            [
                Some(Err(RegistrationRefusal::Unsupported)),
                Some(Err(RegistrationRefusal::Unsupported))
            ]
        );
    }

    #[test]
    fn a_refused_registration_is_answered_with_its_refusal() {
        let worker = libraries_worker();
        let answers = Answers::default();
        worker
            .handle()
            .register(libraries::corpus().not_found, answers.reply());

        worker.step();

        assert_eq!(answers.all(), [Some(Err(RegistrationRefusal::NotFound))]);
    }

    #[test]
    fn a_flush_is_called_after_every_registration_queued_before_it() {
        let worker = libraries_worker();
        let handle = worker.handle();
        let order = Arc::new(Mutex::new(Vec::new()));
        let reply = |tag: &'static str| -> Reply {
            let order = order.clone();
            Box::new(move |_| order.lock().unwrap().push(tag))
        };
        handle.register(libraries::corpus().new, reply("first"));
        handle.flush_registrations(Box::new({
            let order = order.clone();
            move || order.lock().unwrap().push("flush")
        }));
        handle.register(libraries::corpus().overriding, reply("second"));

        assert_eq!(*order.lock().unwrap(), [""; 0]);
        worker.step();
        assert_eq!(*order.lock().unwrap(), ["first", "flush", "second"]);
    }

    #[test]
    fn a_registration_on_a_stopped_worker_is_answered_with_none() {
        let worker = libraries_worker();
        let handle = worker.handle();
        let answers = Answers::default();
        let flushed = Arc::new(Mutex::new(false));
        handle.stop();

        handle.register(libraries::corpus().new, answers.reply());
        handle.flush_registrations(Box::new({
            let flushed = flushed.clone();
            move || *flushed.lock().unwrap() = true
        }));

        assert_eq!(answers.all(), [None]);
        assert!(*flushed.lock().unwrap());
        assert_eq!(worker.step(), None);
        assert_eq!(answers.all(), [None]);
    }

    #[test]
    fn a_registration_queued_when_the_loop_returns_is_answered_with_none_and_a_flush_is_called() {
        let worker = libraries_worker();
        let handle = worker.handle();
        let answers = Answers::default();
        let flushed = Arc::new(Mutex::new(false));
        handle.register(libraries::corpus().new, answers.reply());
        handle.flush_registrations(Box::new({
            let flushed = flushed.clone();
            move || *flushed.lock().unwrap() = true
        }));
        handle.stop();

        worker.run();

        assert_eq!(answers.all(), [None]);
        assert!(*flushed.lock().unwrap());
        assert!(
            !worker
                .syntax
                .grammars()
                .contains(&GrammarName::new("brackets"))
        );
    }

    #[test]
    fn a_stopped_loop_returns() {
        let worker = worker();
        let handle = worker.handle();

        thread::scope(|scope| {
            let running = scope.spawn(|| worker.run());
            handle.stop();
            running.join().unwrap();
        });
    }
}
