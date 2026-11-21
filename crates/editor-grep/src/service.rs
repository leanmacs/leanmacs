//! The service above the rule: searches owned from start to cancel, each
//! on a thread of its own, their matches delivered a read at a time.
//!
//! [`Service`] is what the editor asks for a search. A search is started
//! with an id the caller chose ([`Service::start`]) and the call returns at
//! once; the search's thread makes its port and its engine with the
//! factory the service was made with, refuses what the rule refuses before
//! any walk, keeps [`Reply::Started`] or the refusal under the id, and
//! calls the `complete` closure the service was made with. The caller
//! takes the reply once ([`Service::take`]). From then on the id names the
//! search.
//!
//! # Delivery
//!
//! - **A read** ([`Service::next`]) is a pull, under a wait id of its own.
//!   A search has at most one pending; a second is refused. It is
//!   completed at once if anything is there to deliver, and otherwise by
//!   the search's thread when it finds the next file or ends.
//! - **A delivery** ([`Delivery`]) is every file found and not yet taken,
//!   in the walk's order, up to `bound` matches: a file whose matches do
//!   not fit waits for the next read, and a file with more than `bound`
//!   matches on its own is cut into several deliveries, each of `bound`
//!   matches at most, under the same path. **The end comes last**: the
//!   summary, or the root's refusal, is in the delivery that takes the last
//!   file, and once it is taken the search is gone and its id free.
//! - **The delivery is drained when it is taken**, not when its read was
//!   completed: files found between the completion and the take are in it.
//! - **Back-pressure**: a search waits, before it keeps another file, while
//!   `bound` matches or more are kept and not taken. So what a search keeps
//!   is bounded, and a slow reader slows its search.
//!
//! # The rules
//!
//! - **An id in use is refused**: a search held, or a wait not answered or
//!   not taken, a start's own among them. [`Service::start`] then returns
//!   false and starts nothing, as it does when the system refuses the
//!   start its thread. A bound of 0 is refused as
//!   [`RefusalKind::Failed`].
//! - **Cancelling** ([`Service::cancel`]) takes a search's id or a wait's.
//!   Cancelling a search makes its `stopped` true, so it reads nothing
//!   more, and drops what it kept and its pending read, none of them
//!   completed; it completes nothing more. Cancelling a wait drops that
//!   wait alone. It is safe for an unknown or a finished id.
//! - **Shutdown** ([`Service::shutdown`]) refuses every later start, which
//!   comes to [`RefusalKind::ShutDown`] and is completed at once; cancels
//!   every search; waits for every search's thread to return; and then
//!   completes the flushes left. It is
//!   idempotent, and dropping the last handle of a service does it.
//! - **Locks**: the closure is never called while the service's lock is
//!   held.
//! - **A flush is a barrier** ([`Service::flush`]): a wait of the caller's,
//!   completed once the thread of every search started before it has
//!   returned, a cancelled search's among them, whose bookkeeping goes at
//!   its cancel while its thread may still be in a read. So a caller that
//!   cancelled its searches and then sees the flush completed knows no
//!   search still walks their directories. It is completed at once, on the
//!   caller's thread, when no search's thread runs, keeps no reply, its id
//!   is in use while it waits, and a cancel withdraws it. Shutdown, which
//!   waits for every thread, completes those that are left.
//! - **[`Service::pending`]** counts the searches held and the waits not
//!   answered or not taken, flushes among them, and [`Service::held_back`]
//!   the searches waiting for their reader: readouts for tests.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread;
use std::time::Duration;

use editor_search::Engine;

use crate::{Files, Found, Refusal, RefusalKind, Request, Search, Summary};

/// What a wait comes to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reply {
    /// The start's: the search runs, and its id names it.
    Started,
    /// The start's: it was refused before any walk, and there is no
    /// search.
    Refused(Refusal),
    /// A read's.
    Delivery(Delivery),
}

/// What a read delivers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Delivery {
    /// The files found and not yet taken, in the walk's order.
    pub found: Vec<Found>,
    /// How the search ended, in its last delivery: its summary, or the
    /// root's refusal. None while it goes on.
    pub end: Option<Result<Summary, Refusal>>,
}

/// A search, as the service holds it.
struct Held {
    /// What its `stopped` reads.
    cancelled: Arc<AtomicBool>,
    /// How many matches a delivery holds at most.
    bound: usize,
    /// The files found and not yet taken.
    queue: VecDeque<Found>,
    /// How many matches `queue` holds.
    queued: usize,
    /// How it ended, once it has.
    end: Option<Result<Summary, Refusal>>,
    /// Its pending read, and whether that read's completion was queued.
    read: Option<(u64, bool)>,
}

impl Held {
    /// Whether a read can be answered now.
    fn deliverable(&self) -> bool {
        !self.queue.is_empty() || self.end.is_some()
    }

    /// The next delivery, drained: the module docs' "Delivery".
    fn drain(&mut self) -> Delivery {
        let mut found = Vec::new();
        let mut room = self.bound;
        while let Some(front) = self.queue.front_mut() {
            let count = front.matches.len();
            if count <= room {
                room -= count;
                self.queued -= count;
                found.extend(self.queue.pop_front());
            } else if found.is_empty() {
                // A file with more matches than a delivery holds is cut.
                let rest = front.matches.split_off(room);
                let head = Found {
                    path: front.path.clone(),
                    source: front.source,
                    matches: std::mem::replace(&mut front.matches, rest),
                };
                self.queued -= head.matches.len();
                found.push(head);
                break;
            } else {
                break;
            }
        }
        let end = if self.queue.is_empty() {
            self.end.take()
        } else {
            None
        };
        Delivery { found, end }
    }
}

/// A wait: answered and kept, or pending.
enum Wait {
    /// A read of this search.
    Reading(u64),
    /// This reply, kept.
    Kept(Reply),
    /// A flush: completed once the searches' threads it waits for have
    /// returned.
    Flush {
        /// How many flushes were asked before it.
        order: u64,
        /// The tickets of the searches' threads it still waits for.
        awaited: HashSet<u64>,
    },
}

/// What the service holds.
#[derive(Default)]
struct State {
    /// Whether it has shut down.
    shut: bool,
    /// Each search, by its id.
    searches: HashMap<u64, Held>,
    /// Each wait, by its id, a start's among them.
    waits: HashMap<u64, Wait>,
    /// How many searches' threads have not returned.
    active: usize,
    /// The ticket of each search's thread that has not returned. A ticket,
    /// not the search's id, since the id of a cancelled search is free
    /// again before its thread returns.
    running: HashSet<u64>,
    /// The next search's ticket.
    tickets: u64,
    /// How many flushes have been asked.
    flushes: u64,
    /// How many searches wait for their reader.
    held_back: usize,
}

impl State {
    /// Whether `id` names a search or a wait.
    fn in_use(&self, id: u64) -> bool {
        self.searches.contains_key(&id) || self.waits.contains_key(&id)
    }

    /// Settles the thread `ticket`, which has returned, and takes out each
    /// flush that waited for nothing else, in the order they were asked.
    fn settle(&mut self, ticket: u64) -> Vec<u64> {
        self.running.remove(&ticket);
        self.take_flushes(|awaited| {
            awaited.remove(&ticket);
            awaited.is_empty()
        })
    }

    /// Takes out each flush `done` says is done, in the order they were
    /// asked.
    fn take_flushes(&mut self, mut done: impl FnMut(&mut HashSet<u64>) -> bool) -> Vec<u64> {
        let mut flushed: Vec<(u64, u64)> = self
            .waits
            .iter_mut()
            .filter_map(|(&id, wait)| match wait {
                Wait::Flush { order, awaited } => done(awaited).then_some((*order, id)),
                _ => None,
            })
            .collect();
        flushed.sort_unstable();
        for (_, id) in &flushed {
            self.waits.remove(id);
        }
        flushed.into_iter().map(|(_, id)| id).collect()
    }

    /// The search `id`, if it is held and not cancelled.
    fn wanted(&mut self, id: u64) -> Option<&mut Held> {
        self.searches
            .get_mut(&id)
            .filter(|held| !held.cancelled.load(Ordering::SeqCst))
    }
}

/// What makes a search's port and engine, on its thread.
type Factory<F, E> = dyn Fn() -> (F, E) + Send + Sync;

/// What a service's handles and its threads share.
struct Inner<F, E> {
    /// What makes each search's port and engine.
    make: Box<Factory<F, E>>,
    /// The text's word class, for `\<` and `\>`.
    word: Box<dyn Fn(char) -> bool + Send + Sync>,
    /// What is called with a wait's id when its reply can be taken.
    complete: Box<dyn Fn(u64) + Send + Sync>,
    /// The state. The lock is never held while the closure is called.
    state: Mutex<State>,
    /// Told when a delivery is taken, a search cancelled or the service
    /// shut, so a search held back looks again; and when a search is held
    /// back, so a test waiting on the readout looks again.
    room: Condvar,
    /// Told whenever a search's thread returns.
    finished: Condvar,
    /// Called, in a test, each time shutdown goes on waiting for a search's
    /// thread that has not returned, with the state locked: the sign a
    /// test lets the thread go on.
    #[cfg(test)]
    unfinished: std::sync::OnceLock<Box<dyn Fn() + Send + Sync>>,
}

/// The search service, over the port `F` and the engine `E` its factory
/// makes for each search. A cheap handle: clones share one service, which
/// shuts down when the last is dropped.
pub struct Service<F, E> {
    /// The handle its clones share.
    handle: Arc<Handle<F, E>>,
}

impl<F, E> Clone for Service<F, E> {
    fn clone(&self) -> Self {
        Self {
            handle: Arc::clone(&self.handle),
        }
    }
}

/// What a service's clones share; its drop shuts the service down.
struct Handle<F, E> {
    /// The service.
    inner: Arc<Inner<F, E>>,
}

impl<F, E> Drop for Handle<F, E> {
    fn drop(&mut self) {
        self.inner.shutdown();
    }
}

impl<F, E> Service<F, E>
where
    F: Files + 'static,
    E: Engine + 'static,
{
    /// A service whose searches each run over the port and the engine
    /// `make` makes on the search's thread, with `word` the text's word
    /// class, and that calls `complete` with a wait's id when its reply can
    /// be taken: a start's id, or a read's wait id.
    pub fn new(
        make: impl Fn() -> (F, E) + Send + Sync + 'static,
        word: impl Fn(char) -> bool + Send + Sync + 'static,
        complete: impl Fn(u64) + Send + Sync + 'static,
    ) -> Self {
        let inner = Arc::new(Inner {
            make: Box::new(make),
            word: Box::new(word),
            complete: Box::new(complete),
            state: Mutex::new(State::default()),
            room: Condvar::new(),
            finished: Condvar::new(),
            #[cfg(test)]
            unfinished: std::sync::OnceLock::new(),
        });
        Self {
            handle: Arc::new(Handle { inner }),
        }
    }

    /// Has `told` called each time shutdown goes on waiting for a search's
    /// thread that has not returned. Set once, by a test.
    #[cfg(test)]
    pub(crate) fn when_shutdown_waits(&self, told: impl Fn() + Send + Sync + 'static) {
        assert!(
            self.inner().unfinished.set(Box::new(told)).is_ok(),
            "set once"
        );
    }

    /// The service.
    fn inner(&self) -> &Arc<Inner<F, E>> {
        &self.handle.inner
    }

    /// Starts the search `id` of `request`, its deliveries holding `bound`
    /// matches at most, and returns at once. False, starting nothing, for
    /// an id in use, or when the system refuses the start its thread. After
    /// shutdown, and for a bound of 0, the start is accepted, refused and
    /// completed at once.
    pub fn start(&self, id: u64, request: Request, bound: usize) -> bool {
        let inner = self.inner();
        let mut state = inner.state();
        if state.in_use(id) {
            return false;
        }
        let refusal = if state.shut {
            Some(Refusal::new(
                RefusalKind::ShutDown,
                format!(
                    "cannot search {}: the search service has shut down",
                    request.root.display()
                ),
            ))
        } else if bound == 0 {
            Some(Refusal::new(
                RefusalKind::Failed,
                format!(
                    "cannot search {}: a bound of 0 delivers nothing",
                    request.root.display()
                ),
            ))
        } else {
            None
        };
        if let Some(refusal) = refusal {
            state.waits.insert(id, Wait::Kept(Reply::Refused(refusal)));
            drop(state);
            (inner.complete)(id);
            return true;
        }
        let cancelled = Arc::new(AtomicBool::new(false));
        state.searches.insert(
            id,
            Held {
                cancelled: Arc::clone(&cancelled),
                bound,
                queue: VecDeque::new(),
                queued: 0,
                end: None,
                read: None,
            },
        );
        state.active += 1;
        let ticket = state.tickets;
        state.tickets += 1;
        state.running.insert(ticket);
        drop(state);
        let searching = Arc::clone(inner);
        let started = thread::Builder::new()
            .name("editor-grep-search".into())
            .spawn(move || searching.search(id, ticket, &request, &cancelled))
            .is_ok();
        if !started {
            let mut state = inner.state();
            state.searches.remove(&id);
            state.active -= 1;
            let flushed = state.settle(ticket);
            drop(state);
            inner.finished.notify_all();
            inner.complete_all(flushed);
        }
        started
    }

    /// Asks for the next delivery of the search `id`, under the wait id
    /// `wait`. False for a search that is not held, one with a read pending
    /// already, or a wait id in use.
    pub fn next(&self, id: u64, wait: u64) -> bool {
        let inner = self.inner();
        let mut state = inner.state();
        if state.in_use(wait) {
            return false;
        }
        let Some(held) = state.searches.get_mut(&id) else {
            return false;
        };
        if held.read.is_some() {
            return false;
        }
        let now = held.deliverable();
        held.read = Some((wait, now));
        state.waits.insert(wait, Wait::Reading(id));
        drop(state);
        if now {
            (inner.complete)(wait);
        }
        true
    }

    /// The reply of the wait `wait`, once: `None` while it is pending, once
    /// it was taken, and for a wait the service does not know. A read's
    /// delivery is drained here.
    pub fn take(&self, wait: u64) -> Option<Reply> {
        let inner = self.inner();
        let mut state = inner.state();
        let id = match state.waits.get(&wait)? {
            Wait::Kept(_) => {
                return match state.waits.remove(&wait) {
                    Some(Wait::Kept(reply)) => Some(reply),
                    _ => None,
                };
            }
            // A flush keeps no reply.
            Wait::Flush { .. } => return None,
            &Wait::Reading(id) => id,
        };
        let held = state.searches.get_mut(&id)?;
        if held.read != Some((wait, true)) {
            return None;
        }
        held.read = None;
        let delivery = held.drain();
        if delivery.end.is_some() {
            state.searches.remove(&id);
        }
        state.waits.remove(&wait);
        drop(state);
        inner.room.notify_all();
        Some(Reply::Delivery(delivery))
    }

    /// Cancels the search or the wait `id`, and says whether there was
    /// anything to cancel.
    pub fn cancel(&self, id: u64) -> bool {
        let inner = self.inner();
        let mut state = inner.state();
        if let Some(held) = state.searches.remove(&id) {
            held.cancelled.store(true, Ordering::SeqCst);
            if let Some((wait, _)) = held.read {
                state.waits.remove(&wait);
            }
            state.waits.remove(&id);
            drop(state);
            inner.room.notify_all();
            return true;
        }
        match state.waits.remove(&id) {
            Some(Wait::Reading(search)) => {
                if let Some(held) = state.searches.get_mut(&search) {
                    held.read = None;
                }
                true
            }
            Some(Wait::Kept(_) | Wait::Flush { .. }) => true,
            None => false,
        }
    }

    /// Asks for the wait `id` to be completed once every search started
    /// before this call has ended: its thread has returned, whether the
    /// search ran to its end, was refused or was cancelled. A cancelled
    /// search's bookkeeping goes at its cancel, but its thread may still be
    /// in a read; the flush waits for that thread. It returns at once and
    /// keeps no reply. An id in use is refused; with no search's thread
    /// running it is completed at once, on the caller's thread. It is
    /// counted in [`pending`](Self::pending) while it waits, and a cancel
    /// withdraws it.
    pub fn flush(&self, id: u64) -> bool {
        let inner = self.inner();
        let mut state = inner.state();
        if state.in_use(id) {
            return false;
        }
        if state.running.is_empty() {
            drop(state);
            (inner.complete)(id);
            return true;
        }
        let order = state.flushes;
        state.flushes += 1;
        let awaited = state.running.clone();
        state.waits.insert(id, Wait::Flush { order, awaited });
        true
    }

    /// Refuses every later start, cancels every search, waits for every
    /// search's thread to return, and then completes the flushes left, with
    /// no lock held. Safe to call again.
    pub fn shutdown(&self) {
        self.inner().shutdown();
    }

    /// The searches held and the waits not answered or not taken: a
    /// readout for tests.
    pub fn pending(&self) -> usize {
        let state = self.inner().state();
        state.searches.len() + state.waits.len()
    }

    /// The searches waiting for their reader to take a delivery: a readout
    /// for tests.
    pub fn held_back(&self) -> usize {
        self.inner().state().held_back
    }

    /// Waits up to `timeout` for [`Service::held_back`] to be `count`, and
    /// says whether it came to be: how a test sees a search held back
    /// without sleeping.
    pub fn until_held_back(&self, count: usize, timeout: Duration) -> bool {
        let inner = self.inner();
        let state = inner.state();
        let (state, _) = inner
            .room
            .wait_timeout_while(state, timeout, |state| state.held_back != count)
            .unwrap_or_else(PoisonError::into_inner);
        state.held_back == count
    }
}

impl<F, E> Inner<F, E> {
    /// Locks the state.
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Ends the service: the module docs' "Shutdown".
    fn shutdown(&self) {
        let mut state = self.state();
        state.shut = true;
        // A flush is kept: it is completed once every search's thread has
        // returned.
        state
            .waits
            .retain(|_, wait| matches!(wait, Wait::Flush { .. }));
        for (_, held) in state.searches.drain() {
            held.cancelled.store(true, Ordering::SeqCst);
        }
        self.room.notify_all();
        let mut state = self
            .finished
            .wait_while(state, |state| self.unfinished(state))
            .unwrap_or_else(PoisonError::into_inner);
        let flushed = state.take_flushes(|_| true);
        drop(state);
        self.complete_all(flushed);
    }

    /// Whether a search's thread has not returned; in a test, says so to
    /// the hook first.
    fn unfinished(&self, state: &State) -> bool {
        let waiting = state.active > 0;
        #[cfg(test)]
        if waiting && let Some(told) = self.unfinished.get() {
            told();
        }
        waiting
    }

    /// Completes each of `waits`, in order, with no lock held.
    fn complete_all(&self, waits: Vec<u64>) {
        for wait in waits {
            (self.complete)(wait);
        }
    }

    /// Keeps `reply` under the start `id` if the search is still wanted,
    /// and says whether to complete it; a refused search is forgotten.
    fn answer_start(&self, id: u64, reply: Reply) -> bool {
        let mut state = self.state();
        if state.wanted(id).is_none() {
            return false;
        }
        if matches!(reply, Reply::Refused(_)) {
            state.searches.remove(&id);
        }
        state.waits.insert(id, Wait::Kept(reply));
        true
    }

    /// Keeps `found` for the search `id`, once there is room for it, and
    /// gives back the read to complete. False, keeping nothing, when the
    /// search is no longer wanted.
    fn keep(&self, id: u64, found: Found) -> Result<Option<u64>, ()> {
        let mut state = self.state();
        let mut counted = false;
        loop {
            let Some(held) = state.wanted(id) else {
                if counted {
                    state.held_back -= 1;
                    self.room.notify_all();
                }
                return Err(());
            };
            if held.queued < held.bound {
                break;
            }
            if !counted {
                state.held_back += 1;
                counted = true;
                // A test waiting on the readout looks again.
                self.room.notify_all();
            }
            state = self
                .room
                .wait(state)
                .unwrap_or_else(PoisonError::into_inner);
        }
        if counted {
            state.held_back -= 1;
            self.room.notify_all();
        }
        let Some(held) = state.wanted(id) else {
            return Err(());
        };
        held.queued += found.matches.len();
        held.queue.push_back(found);
        Ok(complete_read(held))
    }

    /// Keeps how the search `id` ended, and gives back the read to
    /// complete.
    fn end(&self, id: u64, end: Result<Summary, Refusal>) -> Option<u64> {
        let mut state = self.state();
        let held = state.wanted(id)?;
        held.end = Some(end);
        complete_read(held)
    }
}

/// The wait of `held`'s pending read, marked completed, if it is pending
/// and not yet completed.
fn complete_read(held: &mut Held) -> Option<u64> {
    match held.read {
        Some((wait, false)) => {
            held.read = Some((wait, true));
            Some(wait)
        }
        _ => None,
    }
}

impl<F, E> Inner<F, E>
where
    F: Files,
    E: Engine,
{
    /// A search's thread: prepares the search, keeps the start's reply,
    /// runs it, keeping each file found, and keeps how it ended.
    fn search(self: Arc<Self>, id: u64, ticket: u64, request: &Request, cancelled: &AtomicBool) {
        let (files, mut engine) = (self.make)();
        match Search::prepare(&mut engine, request) {
            Err(refusal) => {
                if self.answer_start(id, Reply::Refused(refusal)) {
                    (self.complete)(id);
                }
            }
            Ok(mut search) => {
                if self.answer_start(id, Reply::Started) {
                    (self.complete)(id);
                }
                let stopped = || cancelled.load(Ordering::SeqCst);
                let ended = search.run(&files, &*self.word, request, &stopped, &mut |found| {
                    match self.keep(id, found) {
                        Ok(Some(wait)) => (self.complete)(wait),
                        Ok(None) => {}
                        // Not wanted: `stopped` now says so, and the
                        // search reads nothing more.
                        Err(()) => cancelled.store(true, Ordering::SeqCst),
                    }
                });
                if let Some(wait) = self.end(id, ended) {
                    (self.complete)(wait);
                }
            }
        }
        let mut state = self.state();
        state.active -= 1;
        let flushed = state.settle(ticket);
        drop(state);
        self.finished.notify_all();
        self.complete_all(flushed);
    }
}

#[cfg(test)]
mod tests;
