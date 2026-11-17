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
//! The crate starts no thread: [`Worker::run`] is the loop, blocked with no
//! deadline while the queue is empty, and whoever wires the library
//! together runs it on a thread of its own, as `editor-ffi` does. Tests
//! step it on their own thread ([`Worker::step`]).

use std::collections::VecDeque;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError, Weak};

use editor_text::Revision;

use crate::port::Syntax;
use crate::session::{Outcome, Session};

/// The loop that parses, and its queue.
pub struct Worker<S: Syntax> {
    /// The implementation every round parses with.
    syntax: Arc<S>,
    /// The queue, shared with the handles.
    shared: Arc<Shared<S>>,
}

/// What a worker shares with its handles.
struct Shared<S: Syntax> {
    /// The queue.
    queue: Mutex<Queue<S>>,
    /// Woken when a session is queued or the worker is stopped.
    ready: Condvar,
}

/// The sessions waiting for a round, and whether the worker is stopped.
struct Queue<S: Syntax> {
    /// The sessions, in the order they were queued. Each is in it at most
    /// once.
    sessions: VecDeque<Weak<Session<S>>>,
    /// Whether the loop should end.
    stopped: bool,
}

/// What reaches a worker from anywhere: touching a session and stopping
/// the loop.
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
}

impl<S: Syntax> Worker<S> {
    /// A worker that parses with `syntax`, with nothing queued.
    pub fn new(syntax: Arc<S>) -> Self {
        Self {
            syntax,
            shared: Arc::new(Shared {
                queue: Mutex::new(Queue {
                    sessions: VecDeque::new(),
                    stopped: false,
                }),
                ready: Condvar::new(),
            }),
        }
    }

    /// A handle to touch sessions and stop the loop with.
    pub fn handle(&self) -> Handle<S> {
        Handle {
            shared: self.shared.clone(),
        }
    }

    /// Runs one round of the next queued session, and returns how it
    /// ended: [`Outcome::Gone`] too for a session nobody holds any more.
    /// `None` when nothing is queued.
    pub fn step(&self) -> Option<Outcome> {
        let next = self.shared.lock().sessions.pop_front()?;
        Some(self.round(&next))
    }

    /// One round of `next`, which was just taken out of the queue.
    fn round(&self, next: &Weak<Session<S>>) -> Outcome {
        let Some(session) = next.upgrade() else {
            return Outcome::Gone;
        };
        session.queued.store(false, Ordering::Release);
        let outcome = session.parse_once(&self.syntax);
        if let Outcome::Stale(_) = outcome {
            self.shared.queue(&session);
        }
        outcome
    }

    /// The loop: waits for a queued session, with no deadline, and runs
    /// its round, until the worker is stopped ([`Handle::stop`]).
    pub fn run(&self) {
        loop {
            let next = {
                let mut queue = self.shared.lock();
                loop {
                    if queue.stopped {
                        return;
                    }
                    if let Some(next) = queue.sessions.pop_front() {
                        break next;
                    }
                    queue = self
                        .shared
                        .ready
                        .wait(queue)
                        .unwrap_or_else(PoisonError::into_inner);
                }
            };
            self.round(&next);
        }
    }
}

impl<S: Syntax> Handle<S> {
    /// Tells `session` its text has reached `revision`
    /// ([`Session::touch`]) and queues it for a round, unless it is queued
    /// already.
    pub fn touch(&self, session: &Arc<Session<S>>, revision: Revision) {
        session.touch(revision);
        self.shared.queue(session);
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
    use crate::fake::{GRAMMAR, Parens};
    use crate::port::GrammarName;
    use crate::session::tests::{TextSource, replace};

    /// A text and a session of it on a worker over the fake.
    fn session_of(worker: &Worker<Parens>, text: &str) -> (Arc<Mutex<Text>>, Arc<Session<Parens>>) {
        let text = Arc::new(Mutex::new(Text::from(text)));
        let source = Box::new(TextSource(Arc::downgrade(&text)));
        let session = Session::new(&*worker.syntax, GrammarName::new(GRAMMAR), source).unwrap();
        (text, Arc::new(session))
    }

    #[test]
    fn a_worker_with_nothing_queued_runs_no_round() {
        let worker = Worker::new(Arc::new(Parens));

        assert_eq!(worker.step(), None);
    }

    #[test]
    fn a_session_touched_twice_is_queued_once_and_delivered_at_the_newest_revision() {
        let worker = Worker::new(Arc::new(Parens));
        let (text, session) = session_of(&worker, "(a)");
        let handle = worker.handle();
        handle.touch(&session, replace(&text, 0..0, "b "));
        handle.touch(&session, replace(&text, 0..0, "c "));

        assert_eq!(worker.step(), Some(Outcome::Delivered(Revision::new(2))));
        assert_eq!(worker.step(), None);
    }

    #[test]
    fn a_session_touched_again_after_its_round_is_queued_again() {
        let worker = Worker::new(Arc::new(Parens));
        let (text, session) = session_of(&worker, "(a)");
        let handle = worker.handle();
        handle.touch(&session, Revision::new(0));
        worker.step();
        handle.touch(&session, replace(&text, 0..0, "b "));

        assert_eq!(worker.step(), Some(Outcome::Delivered(Revision::new(1))));
    }

    #[test]
    fn a_stale_round_queues_its_session_again() {
        let worker = Worker::new(Arc::new(Parens));
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
        let worker = Worker::new(Arc::new(Parens));
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
    fn a_stopped_loop_returns() {
        let worker = Worker::new(Arc::new(Parens));
        let handle = worker.handle();

        thread::scope(|scope| {
            let running = scope.spawn(|| worker.run());
            handle.stop();
            running.join().unwrap();
        });
    }
}
