//! The service above the port: watches on files and directories, owned
//! from start to cancel, their changes coalesced and delivered a read at a
//! time.
//!
//! [`Service`] is what the editor asks for a watch. A watch is started with
//! an id the caller chose ([`Service::start`]) and the call returns at
//! once; a short-lived thread registers it through the port, keeps
//! [`WatchReply::Started`] or the refusal under the id, and calls the
//! `complete` closure the service was made with. The caller takes the
//! reply once ([`Service::take`]). From then on the id names the watch.
//!
//! # A watch
//!
//! - **A target** ([`Target`]) is a file or a directory. A directory is
//!   watched to a [`Depth`]: its entries, or its whole tree. **A file is
//!   watched through the directory it is in**, registered to
//!   [`Depth::Entries`], and only the changes that name the file are kept.
//!   So a write, a rename over the file and a remove followed by a new file
//!   are each seen under the file's name; a watch on the file's own inode
//!   would lose track at the first rename over it. A file that is not
//!   there yet can be watched, and its creation is told. Its directory
//!   must be there: a file with none, `/`, is [`RefusalKind::NotFound`].
//! - **What is refused**, before the port is asked: a path that is not
//!   absolute, or has a `..` component ([`refusal_before_watch`]), and a
//!   bound of 0 ([`RefusalKind::Failed`]). Then whatever the port refuses.
//! - **Registration is off the caller's thread**, because a recursive
//!   inotify watch walks the whole tree. A start whose id is cancelled
//!   while its port call is in flight drops the registration when the call
//!   returns, and is never completed.
//! - **Watches share a registration**: every watch whose directory and
//!   depth are the same is served by one registration, so N files followed
//!   in one directory cost one platform watch. Cancelling a watch drops
//!   the registration once no other watch uses it.
//!
//! # Coalescing and delivery
//!
//! Each watch has a [`Batch`], whose rule is in [`crate::batch`]: one change
//! per path, a fixed window from the batch's first notice, and a bound of
//! distinct paths past which the batch collapses to [`Kind::Missed`] on the
//! watch's own path. The window and the bound are the caller's
//! ([`Coalescing`]), with no default.
//!
//! - **A read** ([`Service::next`]) is a pull. A watch has at most one
//!   pending; a second is refused. It is completed at once if the batch
//!   can be delivered; otherwise by whoever first makes it deliverable: the
//!   notice itself when the window is 0, or the service's timer thread at
//!   the batch's deadline. A completion is queued once for each read.
//! - **The delivery is drained when it is taken**, not when it was
//!   completed: notices that arrive between the completion and the take
//!   are in it. That is the stream read's rule in `editor-process`.
//! - **The router**: each registration's sink carries its serial. A notice
//!   whose serial is no longer live is dropped, so a late notice reaches no
//!   one. A live serial's notice goes to each watch on that registration: a
//!   file watch keeps the file's path, an entries watch its directory and
//!   what is directly inside it, a tree watch everything under its
//!   directory. A [`Kind::Missed`] notice, the platform's overflow, reaches
//!   every watch on the registration, and collapses its batch.
//! - **Time** is the service's [`Clock`]. The timer thread parks until the
//!   earliest deadline of a batch with a pending read, or until it is woken
//!   ([`Service::wake`]); a test on a
//!   [`ManualClock`](crate::clock::ManualClock) advances the clock and
//!   wakes the service.
//!
//! # The rules
//!
//! - **An id in use is refused**: a watch starting or live, and a wait not
//!   answered or not taken, the start's own among them. [`Service::start`]
//!   then returns false and starts nothing, as it does when the system
//!   refuses the start its thread.
//! - **Cancelling** ([`Service::cancel`]) takes a watch's id or a wait's.
//!   Cancelling a watch drops its batch, its pending read and its kept
//!   reply, none of them completed, and drops its registration once no
//!   other watch shares it. Cancelling a wait drops that wait alone.
//! - **Shutdown** ([`Service::shutdown`]) refuses every later start, which
//!   comes to [`RefusalKind::ShutDown`] and is completed at once; cancels
//!   every watch and every start in flight, and drops every registration,
//!   in one step, so a start held in the port does not keep the live
//!   watches' registrations; then waits for every start's thread to
//!   finish, each dropping what it registered and completing the flushes
//!   it was the last thing for. It is idempotent, and dropping the last
//!   handle of a service does it.
//! - **Locks**: a registration is never dropped, and the closure never
//!   called, while the service's lock is held. A registration is taken out
//!   under the lock and dropped after it is released: an adapter's drop may
//!   join a thread that is in the sink, waiting for that lock.
//! - **Threads**: one timer thread for the service, a short-lived one for
//!   each start, and the adapter's for each registration.
//! - **A flush is a barrier** ([`Service::flush`]): a wait of the
//!   caller's, completed once every start asked before it is done:
//!   registered or refused and its completion queued, or cancelled and
//!   what it registered dropped. A start leaves `Starting` before then, so
//!   the flush waits on a ticket each start holds until it is done, not on
//!   the watch. It is completed at once, on the caller's thread, when no
//!   start holds a ticket. A start's
//!   thread, after its own completion, completes each flush it was the
//!   last thing for, in the order they were asked; shutdown, which waits
//!   for every start's thread, completes the rest.
//!   A pending read is not covered: it waits on the disk, not on the
//!   service. A flush keeps no reply, its id is in use while it waits, and
//!   a cancel withdraws it.
//! - **[`Service::pending`]** counts the watches starting or live and the
//!   waits not answered or not taken, flushes among them: a readout for
//!   tests.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError, Weak};
use std::thread;
use std::time::Duration;

use crate::batch::{Batch, Change};
use crate::clock::Clock;
use crate::{Depth, Kind, Notice, Refusal, RefusalKind, Sink, Watch, refusal_before_watch};

/// What a watch is on.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Target {
    /// A file, which need not be there yet; its directory must be.
    File(PathBuf),
    /// A directory, to a depth.
    Directory(PathBuf, Depth),
}

impl Target {
    /// The path the watch is of: the file's or the directory's.
    fn path(&self) -> &Path {
        match self {
            Self::File(path) | Self::Directory(path, _) => path,
        }
    }

    /// Whether the watch keeps a notice at `path`.
    fn keeps(&self, path: &Path) -> bool {
        match self {
            Self::File(file) => path == file,
            Self::Directory(dir, Depth::Entries) => path == dir || path.parent() == Some(dir),
            Self::Directory(dir, Depth::Tree) => path.starts_with(dir),
        }
    }
}

/// How a watch's changes are coalesced. Both are the caller's policy, with
/// no default.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Coalescing {
    /// How long after a batch's first notice it can be delivered, in
    /// milliseconds of the service's clock.
    pub window_ms: u64,
    /// How many distinct paths a batch may hold. 0 is refused.
    pub bound: usize,
}

/// What a wait comes to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WatchReply {
    /// The start's: the watch is live, and its id names it.
    Started,
    /// A read's: every change noticed and not yet taken, at most one a
    /// path, in the order of each path's first notice.
    Changes(Vec<Change>),
    /// The start's: it was refused, and there is no watch.
    Refused(Refusal),
}

/// What a registration is keyed by: its directory and its depth.
type Key = (PathBuf, Depth);

/// A watch, as the service holds it.
enum Held {
    /// Its start's thread has yet to come back from the port.
    Starting {
        /// Whether it was cancelled meanwhile.
        cancelled: bool,
    },
    /// It is registered.
    Live(Live),
}

/// A live watch.
struct Live {
    /// What it is on.
    target: Target,
    /// Its registration's key.
    key: Key,
    /// What it noticed and has not yet delivered.
    batch: Batch,
    /// Its pending read, and whether that read's completion was queued.
    read: Option<(u64, bool)>,
}

/// A wait: answered and kept, or pending.
enum Wait {
    /// A read of this watch.
    Reading(u64),
    /// This reply, kept.
    Kept(WatchReply),
    /// A flush ([`Service::flush`]), the `order`th asked, waiting for the
    /// starts whose tickets are `awaited` to be done.
    Flush {
        /// How many flushes were asked before it.
        order: u64,
        /// The tickets of the starts it still waits for.
        awaited: HashSet<u64>,
    },
}

/// A registration, shared by the watches with its key.
struct Shared<R> {
    /// Its serial, which its sink carries.
    serial: u64,
    /// The port's registration; dropped once no watch uses it.
    registration: R,
    /// How many watches use it.
    users: usize,
}

/// What the service holds.
struct State<R> {
    /// Whether it has shut down.
    shut: bool,
    /// Whether its timer thread is to end.
    stopped: bool,
    /// Each watch, by its id.
    watches: HashMap<u64, Held>,
    /// Each wait, by its id, a start's among them.
    waits: HashMap<u64, Wait>,
    /// Each registration, by its key.
    registrations: HashMap<Key, Shared<R>>,
    /// The next registration's serial.
    serial: u64,
    /// The ticket of each start not yet done: it has yet to come back from
    /// the port, drop what it registered if it was cancelled, and queue its
    /// completion if it was not. A start leaves `watches` before then, so a
    /// flush waits on these.
    starts: HashSet<u64>,
    /// How many starts' threads have not finished: done, and each flush
    /// they were the last thing for completed. Shutdown waits for none.
    active: usize,
    /// The next start's ticket. A ticket, not the start's id, since the id
    /// of a cancelled start is free again before its thread is done.
    tickets: u64,
    /// How many flushes have been asked: the next one's order.
    flushes: u64,
}

impl<R> State<R> {
    /// Whether `id` names a watch or a wait.
    fn in_use(&self, id: u64) -> bool {
        self.watches.contains_key(&id) || self.waits.contains_key(&id)
    }

    /// Marks the start whose ticket is `ticket` done for every flush, and
    /// removes and returns the flushes it was the last thing for, in the
    /// order they were asked: for the caller to complete with no lock held.
    fn settle(&mut self, ticket: u64) -> Vec<u64> {
        self.starts.remove(&ticket);
        let mut done = Vec::new();
        for (&wait, kept) in &mut self.waits {
            if let Wait::Flush { order, awaited } = kept
                && awaited.remove(&ticket)
                && awaited.is_empty()
            {
                done.push((*order, wait));
            }
        }
        self.take_flushes(done)
    }

    /// Removes the flushes `done`, each with its order, and returns their
    /// ids in that order.
    fn take_flushes(&mut self, mut done: Vec<(u64, u64)>) -> Vec<u64> {
        done.sort_unstable();
        done.into_iter()
            .map(|(_, wait)| {
                self.waits.remove(&wait);
                wait
            })
            .collect()
    }

    /// Removes and returns every flush waiting, in the order asked.
    fn take_every_flush(&mut self) -> Vec<u64> {
        let every = self
            .waits
            .iter()
            .filter_map(|(&wait, kept)| match kept {
                Wait::Flush { order, .. } => Some((*order, wait)),
                Wait::Reading(_) | Wait::Kept(_) => None,
            })
            .collect();
        self.take_flushes(every)
    }

    /// The key of the live registration whose serial is `serial`.
    fn key_of(&self, serial: u64) -> Option<Key> {
        self.registrations
            .iter()
            .find(|(_, shared)| shared.serial == serial)
            .map(|(key, _)| key.clone())
    }

    /// Lets go of one use of the registration `key`, and gives it back once
    /// no watch uses it, for its caller to drop after the lock.
    fn release(&mut self, key: &Key) -> Option<R> {
        let shared = self.registrations.get_mut(key)?;
        shared.users -= 1;
        if shared.users > 0 {
            return None;
        }
        self.registrations
            .remove(key)
            .map(|shared| shared.registration)
    }
}

/// What a service's handles, its threads and its sinks share.
struct Inner<W: Watch, C: Clock> {
    /// What registers directories.
    watch: W,
    /// The clock the windows are measured on.
    clock: C,
    /// What is called with a wait's id when its reply is kept, or its read
    /// can be taken.
    complete: Box<dyn Fn(u64) + Send + Sync>,
    /// The state. The lock is never held while the closure is called or a
    /// registration dropped.
    state: Mutex<State<W::Registration>>,
    /// Told when the timer thread has something new to look at.
    timer: Condvar,
    /// Told whenever a start's thread finishes.
    finished: Condvar,
}

/// The watch service over `W` on the clock `C`. A cheap handle: clones
/// share one service, which shuts down when the last is dropped.
pub struct Service<W: Watch, C: Clock> {
    /// The handle its clones share.
    handle: Arc<Handle<W, C>>,
}

impl<W: Watch, C: Clock> Clone for Service<W, C> {
    fn clone(&self) -> Self {
        Self {
            handle: Arc::clone(&self.handle),
        }
    }
}

/// What a service's clones share; its drop shuts the service down.
struct Handle<W: Watch, C: Clock> {
    /// The service.
    inner: Arc<Inner<W, C>>,
}

impl<W: Watch, C: Clock> Drop for Handle<W, C> {
    fn drop(&mut self) {
        self.inner.shutdown();
        self.inner.state().stopped = true;
        self.inner.timer.notify_all();
    }
}

impl<W: Watch, C: Clock> Service<W, C> {
    /// A service that registers with `watch`, measures windows on `clock`,
    /// and calls `complete` with a wait's id when its reply can be taken: a
    /// start's id, or a read's wait id.
    pub fn new(watch: W, clock: C, complete: impl Fn(u64) + Send + Sync + 'static) -> Self {
        let inner = Arc::new(Inner {
            watch,
            clock,
            complete: Box::new(complete),
            state: Mutex::new(State {
                shut: false,
                stopped: false,
                watches: HashMap::new(),
                waits: HashMap::new(),
                registrations: HashMap::new(),
                serial: 0,
                starts: HashSet::new(),
                active: 0,
                tickets: 0,
                flushes: 0,
            }),
            timer: Condvar::new(),
            finished: Condvar::new(),
        });
        let timer = Arc::clone(&inner);
        // Without its timer thread a window above 0 is never delivered; a
        // window of 0 still is, from the notice.
        thread::Builder::new()
            .name("editor-watch-timer".into())
            .spawn(move || timer.time())
            .ok();
        Self {
            handle: Arc::new(Handle { inner }),
        }
    }

    /// The service.
    fn inner(&self) -> &Arc<Inner<W, C>> {
        &self.handle.inner
    }

    /// What registers directories.
    pub fn watcher(&self) -> &W {
        &self.inner().watch
    }

    /// Starts the watch `id` on `target`, coalesced as `coalescing` says,
    /// and returns at once. False, starting nothing, for an id in use, or
    /// when the system refuses the start its thread. After shutdown the
    /// start is accepted, comes to [`RefusalKind::ShutDown`] and is
    /// completed at once.
    pub fn start(&self, id: u64, target: Target, coalescing: Coalescing) -> bool {
        let inner = self.inner();
        let mut state = inner.state();
        if state.in_use(id) {
            return false;
        }
        if state.shut {
            let refusal = Refusal::new(
                RefusalKind::ShutDown,
                format!(
                    "cannot watch {}: the watch service has shut down",
                    target.path().display()
                ),
            );
            state
                .waits
                .insert(id, Wait::Kept(WatchReply::Refused(refusal)));
            drop(state);
            (inner.complete)(id);
            return true;
        }
        state
            .watches
            .insert(id, Held::Starting { cancelled: false });
        let ticket = state.tickets;
        state.tickets += 1;
        state.starts.insert(ticket);
        state.active += 1;
        drop(state);
        let starting = Arc::clone(inner);
        let started = thread::Builder::new()
            .name("editor-watch-start".into())
            .spawn(move || starting.start(id, ticket, target, coalescing))
            .is_ok();
        if !started {
            let mut state = inner.state();
            state.watches.remove(&id);
            state.active -= 1;
            let flushed = state.settle(ticket);
            drop(state);
            inner.finished.notify_all();
            inner.complete_all(flushed);
        }
        started
    }

    /// Asks for the next delivery of the watch `watch`, under the wait id
    /// `wait`. False for a watch that is not live, a watch with a read
    /// pending already, or a wait id in use.
    pub fn next(&self, watch: u64, wait: u64) -> bool {
        let inner = self.inner();
        let mut state = inner.state();
        if state.in_use(wait) {
            return false;
        }
        let now = inner.clock.now_ms();
        let Some(Held::Live(live)) = state.watches.get_mut(&watch) else {
            return false;
        };
        if live.read.is_some() {
            return false;
        }
        let now_deliverable = live.batch.deliverable(now);
        live.read = Some((wait, now_deliverable));
        state.waits.insert(wait, Wait::Reading(watch));
        drop(state);
        if now_deliverable {
            (inner.complete)(wait);
        } else {
            inner.timer.notify_all();
        }
        true
    }

    /// The reply of the wait `wait`, once: `None` while it is pending, once
    /// it was taken, and for a wait the service does not know. A read's
    /// delivery is drained here, so it holds every change noticed up to
    /// the take.
    pub fn take(&self, wait: u64) -> Option<WatchReply> {
        let mut state = self.inner().state();
        match state.waits.get(&wait)? {
            Wait::Kept(_) => match state.waits.remove(&wait) {
                Some(Wait::Kept(reply)) => Some(reply),
                _ => None,
            },
            Wait::Flush { .. } => None,
            &Wait::Reading(watch) => {
                let Some(Held::Live(live)) = state.watches.get_mut(&watch) else {
                    return None;
                };
                if live.read != Some((wait, true)) {
                    return None;
                }
                live.read = None;
                let changes = live.batch.take();
                state.waits.remove(&wait);
                Some(WatchReply::Changes(changes))
            }
        }
    }

    /// Cancels the watch or the wait `id`, and says whether there was
    /// anything to cancel.
    pub fn cancel(&self, id: u64) -> bool {
        let mut state = self.inner().state();
        let dropped = match state.watches.get_mut(&id) {
            Some(Held::Starting { cancelled }) => {
                *cancelled = true;
                state.waits.remove(&id);
                return true;
            }
            Some(Held::Live(_)) => {
                let Some(Held::Live(live)) = state.watches.remove(&id) else {
                    return false;
                };
                if let Some((wait, _)) = live.read {
                    state.waits.remove(&wait);
                }
                state.waits.remove(&id);
                state.release(&live.key)
            }
            None => {
                return match state.waits.remove(&id) {
                    Some(Wait::Reading(watch)) => {
                        if let Some(Held::Live(live)) = state.watches.get_mut(&watch) {
                            live.read = None;
                        }
                        true
                    }
                    Some(Wait::Kept(_) | Wait::Flush { .. }) => true,
                    None => false,
                };
            }
        };
        drop(state);
        drop(dropped);
        true
    }

    /// Refuses every later start, cancels every watch and every start in
    /// flight, drops every registration, and then waits for the thread of
    /// every start in flight to finish. Safe to call again.
    pub fn shutdown(&self) {
        self.inner().shutdown();
    }

    /// Wakes the timer thread, so that it reads the clock again: a test
    /// that moves a [`ManualClock`](crate::clock::ManualClock) calls it.
    pub fn wake(&self) {
        let _state = self.inner().state();
        self.inner().timer.notify_all();
    }

    /// Asks for the wait `id` to be completed once every start asked before
    /// this call is done: registered and completed, refused and completed,
    /// or cancelled and what it registered dropped. Its completion is
    /// queued after theirs. A pending read is not waited for:
    /// it waits on the disk, not on the service. It returns at once and
    /// keeps no reply. An id in use is refused; one with no start in
    /// flight is completed at once, on the caller's thread. It is counted
    /// in [`pending`](Self::pending) while it waits, and a cancel
    /// withdraws it.
    pub fn flush(&self, id: u64) -> bool {
        let inner = self.inner();
        let mut state = inner.state();
        if state.in_use(id) {
            return false;
        }
        let awaited = state.starts.clone();
        if awaited.is_empty() {
            drop(state);
            (inner.complete)(id);
            return true;
        }
        let order = state.flushes;
        state.flushes += 1;
        state.waits.insert(id, Wait::Flush { order, awaited });
        true
    }

    /// The watches starting or live, and the waits not answered or not
    /// taken: a readout for tests.
    pub fn pending(&self) -> usize {
        let state = self.inner().state();
        state.watches.len() + state.waits.len()
    }
}

impl<W: Watch, C: Clock> Inner<W, C> {
    /// Locks the state.
    fn state(&self) -> MutexGuard<'_, State<W::Registration>> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// A start's thread: refuses what the core refuses, registers through
    /// the port or shares a registration, and keeps the reply; or, if the
    /// start was cancelled meanwhile, drops what it registered and keeps
    /// nothing. Only then, once its completion is queued, is the start
    /// `ticket` done for the flushes waiting on it.
    fn start(self: Arc<Self>, id: u64, ticket: u64, target: Target, coalescing: Coalescing) {
        let (dropped, completed) = match Self::key(&target, coalescing) {
            Err(refusal) => {
                let mut state = self.state();
                (None, Self::refused(&mut state, id, refusal))
            }
            Ok(key) => self.register(id, target, coalescing, key),
        };
        drop(dropped);
        if completed {
            (self.complete)(id);
        }
        let flushed = self.state().settle(ticket);
        self.complete_all(flushed);
        // Only now, so shutdown returns with every flush it covers
        // completed.
        self.state().active -= 1;
        self.finished.notify_all();
    }

    /// Completes each of `waits`, in order, with no lock held.
    fn complete_all(&self, waits: Vec<u64>) {
        for wait in waits {
            (self.complete)(wait);
        }
    }

    /// The key of the registration `target` needs, or why it may not be
    /// watched at all.
    fn key(target: &Target, coalescing: Coalescing) -> Result<Key, Refusal> {
        let path = target.path();
        if let Some(refusal) = refusal_before_watch(path) {
            return Err(refusal);
        }
        if coalescing.bound == 0 {
            return Err(Refusal::new(
                RefusalKind::Failed,
                format!(
                    "cannot watch {}: a bound of 0 holds nothing",
                    path.display()
                ),
            ));
        }
        match target {
            Target::Directory(dir, depth) => Ok((dir.clone(), *depth)),
            Target::File(file) => file
                .parent()
                .map(|dir| (dir.to_path_buf(), Depth::Entries))
                .ok_or_else(|| {
                    Refusal::new(
                        RefusalKind::NotFound,
                        format!("cannot watch {}: it has no directory", file.display()),
                    )
                }),
        }
    }

    /// Whether the start `id` is still wanted: not cancelled, and the
    /// service not shut. One that is not is forgotten.
    fn wanted(state: &mut State<W::Registration>, id: u64) -> bool {
        let wanted = !state.shut
            && matches!(
                state.watches.get(&id),
                Some(Held::Starting { cancelled: false })
            );
        if !wanted {
            state.watches.remove(&id);
        }
        wanted
    }

    /// Keeps the refusal of the start `id`, unless it is no longer wanted,
    /// and says whether to complete it.
    fn refused(state: &mut State<W::Registration>, id: u64, refusal: Refusal) -> bool {
        if !Self::wanted(state, id) {
            return false;
        }
        state.watches.remove(&id);
        state
            .waits
            .insert(id, Wait::Kept(WatchReply::Refused(refusal)));
        true
    }

    /// Registers `key` for the start `id`, or shares its registration. It
    /// gives back a registration to drop after the lock, and whether to
    /// complete the start.
    fn register(
        self: &Arc<Self>,
        id: u64,
        target: Target,
        coalescing: Coalescing,
        key: Key,
    ) -> (Option<W::Registration>, bool) {
        let mut state = self.state();
        if !Self::wanted(&mut state, id) {
            return (None, false);
        }
        if let Some(shared) = state.registrations.get_mut(&key) {
            shared.users += 1;
            Self::live(&mut state, id, target, coalescing, key);
            return (None, true);
        }
        state.serial += 1;
        let serial = state.serial;
        drop(state);
        let router = Arc::downgrade(self);
        let sink: Sink = Arc::new(move |notice| route(&router, serial, notice));
        let registered = self.watch.watch(&key.0, key.1, sink);
        let mut state = self.state();
        match registered {
            Err(refusal) => (None, Self::refused(&mut state, id, refusal)),
            Ok(registration) => {
                if !Self::wanted(&mut state, id) {
                    return (Some(registration), false);
                }
                let extra = if let Some(shared) = state.registrations.get_mut(&key) {
                    // Another start registered the key while this one was
                    // in the port: this one is the extra, and its serial is
                    // never live.
                    shared.users += 1;
                    Some(registration)
                } else {
                    state.registrations.insert(
                        key.clone(),
                        Shared {
                            serial,
                            registration,
                            users: 1,
                        },
                    );
                    None
                };
                Self::live(&mut state, id, target, coalescing, key);
                (extra, true)
            }
        }
    }

    /// Makes the start `id` a live watch, and keeps its reply.
    fn live(
        state: &mut State<W::Registration>,
        id: u64,
        target: Target,
        coalescing: Coalescing,
        key: Key,
    ) {
        let batch = Batch::new(target.path(), coalescing.window_ms, coalescing.bound);
        state.watches.insert(
            id,
            Held::Live(Live {
                target,
                key,
                batch,
                read: None,
            }),
        );
        state.waits.insert(id, Wait::Kept(WatchReply::Started));
    }

    /// Records `notice`, from the registration `serial`, in the batch of
    /// each watch it is for: the module docs' "The router".
    fn route(&self, serial: u64, notice: &Notice) {
        let mut state = self.state();
        let Some(key) = state.key_of(serial) else {
            return;
        };
        let now = self.clock.now_ms();
        let mut due = Vec::new();
        let mut wake = false;
        for held in state.watches.values_mut() {
            let Held::Live(live) = held else { continue };
            if live.key != key || !(notice.kind == Kind::Missed || live.target.keeps(&notice.path))
            {
                continue;
            }
            live.batch.record(notice.clone(), now);
            if let Some((wait, false)) = live.read {
                if live.batch.deliverable(now) {
                    live.read = Some((wait, true));
                    due.push(wait);
                } else {
                    wake = true;
                }
            }
        }
        drop(state);
        for wait in due {
            (self.complete)(wait);
        }
        if wake {
            self.timer.notify_all();
        }
    }

    /// Ends the service: the module docs' "Shutdown".
    fn shutdown(&self) {
        let mut state = self.state();
        state.shut = true;
        // A flush is kept: it is completed once every start has returned.
        state
            .waits
            .retain(|_, kept| matches!(kept, Wait::Flush { .. }));
        state.watches.retain(|_, held| match held {
            Held::Starting { cancelled } => {
                *cancelled = true;
                true
            }
            Held::Live(_) => false,
        });
        // Every registration was a live watch's, and none is made from
        // now on, so each is dropped now, not after the slowest start.
        let ended: Vec<_> = state.registrations.drain().collect();
        drop(state);
        drop(ended);
        // A start in flight sees it is no longer wanted when it returns
        // from the port, and drops what it registered itself.
        let mut state = self
            .finished
            .wait_while(self.state(), |state| state.active > 0)
            .unwrap_or_else(PoisonError::into_inner);
        let flushed = state.take_every_flush();
        drop(state);
        self.complete_all(flushed);
    }

    /// The timer thread: completes each pending read whose batch has come
    /// to its deadline, and parks until the next deadline or until it is
    /// woken. It ends once the service's last handle is dropped.
    fn time(&self) {
        let mut state = self.state();
        loop {
            if state.stopped {
                return;
            }
            let now = self.clock.now_ms();
            let mut due = Vec::new();
            let mut next: Option<u64> = None;
            for held in state.watches.values_mut() {
                let Held::Live(live) = held else { continue };
                let (Some((wait, false)), Some(deadline)) = (live.read, live.batch.deadline())
                else {
                    continue;
                };
                if deadline <= now {
                    live.read = Some((wait, true));
                    due.push(wait);
                } else {
                    next = Some(next.map_or(deadline, |next| next.min(deadline)));
                }
            }
            if !due.is_empty() {
                drop(state);
                for wait in due {
                    (self.complete)(wait);
                }
                state = self.state();
                continue;
            }
            state = match next {
                Some(deadline) => {
                    self.timer
                        .wait_timeout(state, Duration::from_millis(deadline - now))
                        .unwrap_or_else(PoisonError::into_inner)
                        .0
                }
                None => self
                    .timer
                    .wait(state)
                    .unwrap_or_else(PoisonError::into_inner),
            };
        }
    }
}

/// A registration's sink: hands `notice` to the service, if it is still
/// there.
fn route<W: Watch, C: Clock>(service: &Weak<Inner<W, C>>, serial: u64, notice: Notice) {
    if let Some(service) = service.upgrade() {
        service.route(serial, &notice);
    }
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};
    use std::sync::mpsc::{self, Receiver, Sender};
    use std::sync::{Mutex, PoisonError};
    use std::thread;
    use std::time::Duration;

    use std::sync::Arc;

    use super::{Coalescing, Service, Target, WatchReply};
    use crate::batch::{Change, Kinds};
    use crate::clock::ManualClock;
    use crate::fake::{FakeGround, FakeWatch, Flaws};
    use crate::{Depth, Kind, Refusal, RefusalKind, Sink, Watch};

    /// How long a test waits for something that should happen at once.
    /// Only a broken service takes this long, and the test then fails
    /// instead of hanging.
    const DEADLINE: Duration = Duration::from_secs(5);

    /// No window, and room for every test's paths.
    const AT_ONCE: Coalescing = Coalescing {
        window_ms: 0,
        bound: 100,
    };

    type Fake = Service<FakeWatch, ManualClock>;

    /// A fake whose file system has `/w/sub/deep`, its ground, and a clock
    /// at 0.
    fn fake_with(flaws: Flaws) -> (FakeWatch, FakeGround, ManualClock) {
        let fake = FakeWatch::flawed(flaws);
        let ground = fake.ground();
        for dir in ["/w", "/w/sub", "/w/sub/deep"] {
            ground.make_dir(Path::new(dir));
        }
        (fake, ground, ManualClock::new())
    }

    fn fake() -> (FakeWatch, FakeGround, ManualClock) {
        fake_with(Flaws::default())
    }

    /// A service over `fake` on `clock`, and the ids it completes, in
    /// order.
    fn service(fake: &FakeWatch, clock: &ManualClock) -> (Fake, Receiver<u64>) {
        let (sender, completed) = mpsc::channel();
        let sender = Mutex::new(sender);
        let service = Service::new(fake.clone(), clock.clone(), move |id| {
            sender
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .send(id)
                .ok();
        });
        (service, completed)
    }

    fn file(path: &str) -> Target {
        Target::File(PathBuf::from(path))
    }

    fn directory(path: &str, depth: Depth) -> Target {
        Target::Directory(PathBuf::from(path), depth)
    }

    /// Starts the watch `id` and waits for it to be live.
    fn started(
        service: &Fake,
        completed: &Receiver<u64>,
        id: u64,
        target: Target,
        coalescing: Coalescing,
    ) {
        assert!(service.start(id, target, coalescing), "accepted");
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(id));
        assert_eq!(service.take(id), Some(WatchReply::Started));
    }

    fn change(path: &str, kinds: &[Kind]) -> Change {
        Change {
            path: PathBuf::from(path),
            kinds: kinds
                .iter()
                .fold(Kinds::default(), |set, &kind| set.with(kind)),
        }
    }

    fn changes(of: &[(&str, &[Kind])]) -> Option<WatchReply> {
        Some(WatchReply::Changes(
            of.iter().map(|(path, kinds)| change(path, kinds)).collect(),
        ))
    }

    fn refusal(reply: Option<WatchReply>) -> Option<RefusalKind> {
        match reply {
            Some(WatchReply::Refused(refusal)) => Some(refusal.kind),
            _ => None,
        }
    }

    /// The delivery of the wait `wait`, once its completion has come.
    fn delivered(service: &Fake, completed: &Receiver<u64>, wait: u64) -> Option<WatchReply> {
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(wait));
        service.take(wait)
    }

    #[test]
    fn a_file_watch_is_told_when_the_file_is_written() {
        let (fake, ground, clock) = fake();
        ground.write(Path::new("/w/f"), b"x");
        let (service, completed) = service(&fake, &clock);
        started(&service, &completed, 1, file("/w/f"), AT_ONCE);

        assert!(service.next(1, 2));
        ground.write(Path::new("/w/f"), b"y");

        assert_eq!(
            delivered(&service, &completed, 2),
            changes(&[("/w/f", &[Kind::Written])])
        );
    }

    #[test]
    fn a_file_watch_is_told_when_the_file_is_renamed_over() {
        let (fake, ground, clock) = fake();
        ground.write(Path::new("/w/f"), b"x");
        ground.write(Path::new("/w/g"), b"y");
        let (service, completed) = service(&fake, &clock);
        started(&service, &completed, 1, file("/w/f"), AT_ONCE);

        assert!(service.next(1, 2));
        ground.rename(Path::new("/w/g"), Path::new("/w/f"));

        assert_eq!(
            delivered(&service, &completed, 2),
            changes(&[("/w/f", &[Kind::Renamed])])
        );
    }

    #[test]
    fn a_file_watch_is_told_when_the_file_is_removed() {
        let (fake, ground, clock) = fake();
        ground.write(Path::new("/w/f"), b"x");
        let (service, completed) = service(&fake, &clock);
        started(&service, &completed, 1, file("/w/f"), AT_ONCE);

        assert!(service.next(1, 2));
        ground.remove(Path::new("/w/f"));

        assert_eq!(
            delivered(&service, &completed, 2),
            changes(&[("/w/f", &[Kind::Removed])])
        );
    }

    #[test]
    fn a_file_watch_is_told_when_the_file_is_made() {
        let (fake, ground, clock) = fake();
        let (service, completed) = service(&fake, &clock);
        started(&service, &completed, 1, file("/w/f"), AT_ONCE);

        assert!(service.next(1, 2));
        ground.write(Path::new("/w/f"), b"x");

        assert_eq!(
            delivered(&service, &completed, 2),
            changes(&[("/w/f", &[Kind::Created, Kind::Written])])
        );
        assert_eq!(fake.live(), [(PathBuf::from("/w"), Depth::Entries)]);
    }

    #[test]
    fn a_file_watch_drops_its_siblings() {
        let (fake, ground, clock) = fake();
        let (service, completed) = service(&fake, &clock);
        started(&service, &completed, 1, file("/w/f"), AT_ONCE);

        assert!(service.next(1, 2));
        ground.write(Path::new("/w/g"), b"x");
        assert!(completed.try_recv().is_err(), "a sibling completes nothing");
        ground.write(Path::new("/w/f"), b"x");

        assert_eq!(
            delivered(&service, &completed, 2),
            changes(&[("/w/f", &[Kind::Created, Kind::Written])])
        );
    }

    #[test]
    fn a_directory_watch_is_told_each_entry_directly_inside_and_nothing_deeper() {
        let (fake, ground, clock) = fake();
        fake.notice_whole_trees();
        ground.write(Path::new("/w/a"), b"a");
        ground.write(Path::new("/w/r"), b"r");
        let (service, completed) = service(&fake, &clock);
        started(
            &service,
            &completed,
            1,
            directory("/w", Depth::Entries),
            AT_ONCE,
        );

        assert!(service.next(1, 2));
        ground.write(Path::new("/w/sub/deep/x"), b"x");
        assert!(
            completed.try_recv().is_err(),
            "a deeper path completes nothing"
        );
        ground.write(Path::new("/w/n"), b"n");
        ground.write(Path::new("/w/a"), b"aa");
        ground.rename(Path::new("/w/a"), Path::new("/w/b"));
        ground.remove(Path::new("/w/r"));

        assert_eq!(
            delivered(&service, &completed, 2),
            changes(&[
                ("/w/n", &[Kind::Created, Kind::Written]),
                ("/w/a", &[Kind::Written, Kind::Renamed]),
                ("/w/b", &[Kind::Renamed]),
                ("/w/r", &[Kind::Removed]),
            ])
        );
    }

    #[test]
    fn a_tree_watch_is_told_of_a_change_in_any_subdirectory() {
        let (fake, ground, clock) = fake();
        let (service, completed) = service(&fake, &clock);
        started(
            &service,
            &completed,
            1,
            directory("/w", Depth::Tree),
            AT_ONCE,
        );

        assert!(service.next(1, 2));
        ground.write(Path::new("/w/sub/deep/x"), b"x");

        assert_eq!(
            delivered(&service, &completed, 2),
            changes(&[("/w/sub/deep/x", &[Kind::Created, Kind::Written])])
        );
        assert_eq!(fake.live(), [(PathBuf::from("/w"), Depth::Tree)]);
    }

    #[test]
    fn writes_within_the_window_arrive_as_one_change() {
        let (fake, ground, clock) = fake();
        let (service, completed) = service(&fake, &clock);
        let window = Coalescing {
            window_ms: 300,
            bound: 10,
        };
        started(&service, &completed, 1, file("/w/f"), window);

        assert!(service.next(1, 2));
        ground.write_times(Path::new("/w/f"), 5);
        service.wake();
        assert!(completed.try_recv().is_err(), "the window has not passed");
        clock.advance(300);
        service.wake();

        assert_eq!(
            delivered(&service, &completed, 2),
            changes(&[("/w/f", &[Kind::Created, Kind::Written])])
        );
        assert!(completed.try_recv().is_err(), "one completion");
    }

    #[test]
    fn a_read_waits_for_the_window_from_the_first_notice() {
        let (fake, ground, clock) = fake();
        let (service, completed) = service(&fake, &clock);
        let window = Coalescing {
            window_ms: 300,
            bound: 10,
        };
        started(&service, &completed, 1, file("/w/f"), window);

        clock.set(100);
        ground.write(Path::new("/w/f"), b"x");
        clock.set(350);
        ground.write(Path::new("/w/f"), b"y");
        assert!(service.next(1, 2));
        clock.set(399);
        service.wake();
        assert!(completed.try_recv().is_err(), "the window has not passed");
        clock.set(400);
        service.wake();

        assert_eq!(
            delivered(&service, &completed, 2),
            changes(&[("/w/f", &[Kind::Created, Kind::Written])])
        );
    }

    #[test]
    fn a_read_asked_once_the_window_has_passed_is_completed_at_once() {
        let (fake, ground, clock) = fake();
        let (service, completed) = service(&fake, &clock);
        let window = Coalescing {
            window_ms: 300,
            bound: 10,
        };
        started(&service, &completed, 1, file("/w/f"), window);

        ground.write(Path::new("/w/f"), b"x");
        clock.advance(300);
        assert!(service.next(1, 2));

        assert_eq!(
            delivered(&service, &completed, 2),
            changes(&[("/w/f", &[Kind::Created, Kind::Written])])
        );
    }

    #[test]
    fn a_continuous_writer_is_delivered_once_a_window() {
        let (fake, ground, clock) = fake();
        ground.write(Path::new("/w/f"), b"x");
        let (service, completed) = service(&fake, &clock);
        let window = Coalescing {
            window_ms: 100,
            bound: 10,
        };
        started(&service, &completed, 1, file("/w/f"), window);
        let mut wait = 2;
        assert!(service.next(1, wait));

        // A write every 50 ms, with a read always pending: the batch opens
        // at the first write after each take, and is delivered a window
        // later, though the writes never pause.
        let mut delivered_at = Vec::new();
        for at in (0..=500).step_by(50) {
            clock.set(at);
            ground.write(Path::new("/w/f"), b"x");
            service.wake();
            if [100, 250, 400].contains(&at) {
                assert_eq!(completed.recv_timeout(DEADLINE), Ok(wait), "at {at}");
                assert_eq!(service.take(wait), changes(&[("/w/f", &[Kind::Written])]));
                delivered_at.push(at);
                wait += 1;
                assert!(service.next(1, wait));
            } else {
                assert!(completed.try_recv().is_err(), "nothing due at {at}");
            }
        }

        assert_eq!(delivered_at, [100, 250, 400]);
    }

    #[test]
    fn the_delivery_is_drained_at_the_take() {
        let (fake, ground, clock) = fake();
        let (service, completed) = service(&fake, &clock);
        started(
            &service,
            &completed,
            1,
            directory("/w", Depth::Entries),
            AT_ONCE,
        );

        assert!(service.next(1, 2));
        ground.write(Path::new("/w/a"), b"x");
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(2));
        ground.remove(Path::new("/w/a"));
        ground.write(Path::new("/w/b"), b"x");

        assert_eq!(
            service.take(2),
            changes(&[
                ("/w/a", &[Kind::Created, Kind::Written, Kind::Removed]),
                ("/w/b", &[Kind::Created, Kind::Written]),
            ])
        );
        assert!(completed.try_recv().is_err(), "one completion");
        assert_eq!(service.take(2), None, "taken once");
    }

    #[test]
    fn a_second_read_while_one_is_pending_is_refused() {
        let (fake, _ground, clock) = fake();
        let (service, completed) = service(&fake, &clock);
        started(&service, &completed, 1, file("/w/f"), AT_ONCE);

        assert!(service.next(1, 2));
        assert!(!service.next(1, 3), "one pending read");
        assert!(!service.next(9, 4), "no such watch");
        assert!(!service.next(1, 2), "a wait in use");
        assert_eq!(service.take(2), None, "pending");
        assert!(service.cancel(2));
        assert!(service.next(1, 3), "the cancelled read is gone");
    }

    #[test]
    fn watches_of_one_directory_share_a_registration_and_cancelling_one_keeps_it() {
        let (fake, ground, clock) = fake();
        let (service, completed) = service(&fake, &clock);
        started(&service, &completed, 1, file("/w/f"), AT_ONCE);
        started(&service, &completed, 2, file("/w/g"), AT_ONCE);
        started(
            &service,
            &completed,
            3,
            directory("/w", Depth::Tree),
            AT_ONCE,
        );

        assert_eq!(
            fake.live(),
            [
                (PathBuf::from("/w"), Depth::Entries),
                (PathBuf::from("/w"), Depth::Tree)
            ]
        );
        assert!(service.cancel(1));
        assert_eq!(fake.live().len(), 2);
        assert!(service.next(2, 4));
        ground.write(Path::new("/w/g"), b"x");
        assert_eq!(
            delivered(&service, &completed, 4),
            changes(&[("/w/g", &[Kind::Created, Kind::Written])])
        );
        assert!(service.cancel(2));

        assert_eq!(fake.live(), [(PathBuf::from("/w"), Depth::Tree)]);
        assert_eq!(fake.record().watched.len(), 2);
    }

    #[test]
    fn a_cancelled_watch_delivers_nothing_and_drops_its_registration() {
        let (fake, ground, clock) = fake();
        let (service, completed) = service(&fake, &clock);
        started(&service, &completed, 1, file("/w/f"), AT_ONCE);

        assert!(service.next(1, 2));
        assert!(service.cancel(1));
        ground.write(Path::new("/w/f"), b"x");

        assert_eq!(fake.live(), []);
        assert!(completed.try_recv().is_err(), "never completed");
        assert_eq!(service.take(2), None);
        assert!(!service.next(1, 3), "the watch is gone");
        assert!(!service.cancel(1), "nothing more to cancel");
        assert_eq!(service.pending(), 0);
    }

    #[test]
    fn a_notice_after_the_registration_is_dropped_reaches_no_one() {
        let (fake, ground, clock) = fake_with(Flaws {
            late_after_drop: true,
            ..Flaws::default()
        });
        fake.call_sinks_on_drop();
        let (service, completed) = service(&fake, &clock);
        started(&service, &completed, 1, file("/w/f"), AT_ONCE);
        started(
            &service,
            &completed,
            2,
            directory("/w", Depth::Tree),
            AT_ONCE,
        );

        assert!(service.cancel(1));
        assert!(service.next(2, 3));
        ground.write(Path::new("/w/g"), b"x");

        assert_eq!(
            delivered(&service, &completed, 3),
            changes(&[("/w/g", &[Kind::Created, Kind::Written])])
        );
    }

    #[test]
    fn a_missed_notice_on_the_directory_reaches_a_file_watch_as_missed_on_the_file() {
        let (fake, _ground, clock) = fake();
        let (service, completed) = service(&fake, &clock);
        started(&service, &completed, 1, file("/w/f"), AT_ONCE);

        assert!(service.next(1, 2));
        fake.notice("/w", Kind::Missed);

        assert_eq!(
            delivered(&service, &completed, 2),
            changes(&[("/w/f", &[Kind::Missed])])
        );
    }

    #[test]
    fn a_batch_past_its_bound_is_delivered_as_missed_on_the_watched_directory() {
        let (fake, ground, clock) = fake();
        let (service, completed) = service(&fake, &clock);
        let bound = Coalescing {
            window_ms: 0,
            bound: 2,
        };
        started(
            &service,
            &completed,
            1,
            directory("/w", Depth::Entries),
            bound,
        );

        for name in ["/w/a", "/w/b", "/w/c"] {
            ground.write(Path::new(name), b"x");
        }
        assert!(service.next(1, 2));

        assert_eq!(
            delivered(&service, &completed, 2),
            changes(&[("/w", &[Kind::Missed])])
        );
    }

    #[test]
    fn a_start_is_refused_for_a_relative_path_a_bound_of_zero_or_by_the_port() {
        let (fake, ground, clock) = fake();
        ground.write(Path::new("/w/file"), b"x");
        let (service, completed) = service(&fake, &clock);
        let refused = |id, target, coalescing| {
            assert!(service.start(id, target, coalescing));
            assert_eq!(completed.recv_timeout(DEADLINE), Ok(id));
            refusal(service.take(id))
        };

        assert_eq!(
            refused(1, file("w/f"), AT_ONCE),
            Some(RefusalKind::NotAbsolute)
        );
        assert_eq!(
            refused(2, directory("/w/../w", Depth::Tree), AT_ONCE),
            Some(RefusalKind::NotAbsolute)
        );
        let zero = Coalescing {
            window_ms: 0,
            bound: 0,
        };
        assert_eq!(refused(3, file("/w/f"), zero), Some(RefusalKind::Failed));
        assert_eq!(
            refused(4, directory("/nowhere", Depth::Entries), AT_ONCE),
            Some(RefusalKind::NotFound)
        );
        assert_eq!(
            refused(5, file("/nowhere/f"), AT_ONCE),
            Some(RefusalKind::NotFound)
        );
        assert_eq!(
            refused(6, directory("/w/file", Depth::Entries), AT_ONCE),
            Some(RefusalKind::NotADirectory)
        );

        assert_eq!(
            fake.record().watched,
            [
                (PathBuf::from("/nowhere"), Depth::Entries),
                (PathBuf::from("/nowhere"), Depth::Entries),
                (PathBuf::from("/w/file"), Depth::Entries)
            ],
            "the core's refusals ask the port nothing"
        );
        assert!(!service.next(4, 7), "a refused start is no watch");
        assert_eq!(service.pending(), 0);
    }

    #[test]
    fn two_starts_of_one_directory_in_the_port_at_once_share_one_registration_and_drop_the_extra() {
        let (fake, ground, clock) = fake();
        let (service, completed) = service(&fake, &clock);
        fake.hold_watches();

        assert!(service.start(1, file("/w/f"), AT_ONCE));
        assert!(service.start(2, file("/w/g"), AT_ONCE));
        assert!(fake.until(DEADLINE, |record| record.parked == 2));
        fake.release_watches();
        let mut started = [
            completed.recv_timeout(DEADLINE).ok(),
            completed.recv_timeout(DEADLINE).ok(),
        ];
        started.sort();

        assert_eq!(started, [Some(1), Some(2)]);
        assert_eq!(service.take(1), Some(WatchReply::Started));
        assert_eq!(service.take(2), Some(WatchReply::Started));
        assert_eq!(fake.live(), [(PathBuf::from("/w"), Depth::Entries)]);
        assert_eq!(fake.record().dropped.len(), 1, "the extra is dropped");
        assert!(service.next(2, 3));
        ground.write(Path::new("/w/g"), b"x");
        assert_eq!(
            delivered(&service, &completed, 3),
            changes(&[("/w/g", &[Kind::Created, Kind::Written])])
        );

        assert!(service.cancel(1));
        assert!(service.next(2, 4));
        ground.write(Path::new("/w/g"), b"y");
        assert_eq!(
            delivered(&service, &completed, 4),
            changes(&[("/w/g", &[Kind::Written])])
        );
        assert!(service.cancel(2));
        assert_eq!(fake.live(), []);
    }

    #[test]
    fn a_file_watch_of_the_root_is_refused_as_not_found_since_it_has_no_directory() {
        let (fake, _ground, clock) = fake();
        let (service, completed) = service(&fake, &clock);

        assert!(service.start(1, file("/"), AT_ONCE));
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(1));

        match service.take(1) {
            Some(WatchReply::Refused(refusal)) => {
                assert_eq!(refusal.kind, RefusalKind::NotFound);
                assert!(
                    refusal.detail.contains("has no directory"),
                    "{}",
                    refusal.detail
                );
            }
            other => panic!("not refused: {other:?}"),
        }
        assert_eq!(fake.record().watched, [], "the port is not asked");
    }

    /// The port's `watch` is held, so the start cannot return from it until
    /// the test lets go: a flush completed at its call, or ahead of the
    /// start, is seen every time.
    #[test]
    fn a_flush_waits_for_a_start_held_in_the_port_and_completes_after_it() {
        let (fake, _ground, clock) = fake();
        let (service, completed) = service(&fake, &clock);
        fake.hold_watches();
        assert!(service.start(1, file("/w/f"), AT_ONCE));

        // Read while the start is held, and checked once it is let go: a
        // check that fails while it is held would leave the service's drop
        // waiting for it.
        let asked = service.flush(2);
        let in_use = !service.flush(2) && !service.start(2, file("/w/g"), AT_ONCE);
        let pending = service.pending();
        let nothing = completed.try_recv().is_err();
        fake.release_watches();
        assert!(asked && in_use, "accepted once, then its id is in use");
        assert_eq!(pending, 2);
        assert!(nothing, "nothing is completed while the start is held");

        assert_eq!(completed.recv_timeout(DEADLINE), Ok(1));
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(2));
        // It keeps no reply.
        assert_eq!(service.take(2), None);
        assert_eq!(service.take(1), Some(WatchReply::Started));
        assert_eq!(service.pending(), 1, "the live watch");
    }

    /// A service over `fake` on `clock` whose completion of `held` tells
    /// the first receiver it has begun and then waits for the sender to be
    /// told or dropped. The second receiver has the ids whose completions
    /// have returned, in order.
    fn holding(
        fake: &FakeWatch,
        clock: &ManualClock,
        held: u64,
    ) -> (Fake, Receiver<u64>, Receiver<()>, Sender<()>) {
        let (sender, completed) = mpsc::channel();
        let (began, entered) = mpsc::channel();
        let (release, gate) = mpsc::channel::<()>();
        let sender = Mutex::new(sender);
        let began = Mutex::new(began);
        let gate = Mutex::new(gate);
        let service = Service::new(fake.clone(), clock.clone(), move |id| {
            if id == held {
                began
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .send(())
                    .ok();
                gate.lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .recv()
                    .ok();
            }
            sender
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .send(id)
                .ok();
        });
        (service, completed, entered, release)
    }

    /// Asks for the flush `flush` while the completion of the start `start`
    /// is held, then lets it go, and gives back whether nothing was
    /// completed while it was held and every completion after, in order.
    fn flush_behind_a_held_completion(
        service: &Fake,
        completed: &Receiver<u64>,
        entered: &Receiver<()>,
        release: Sender<()>,
        flush: u64,
    ) -> (bool, Vec<u64>) {
        assert_eq!(
            entered.recv_timeout(DEADLINE),
            Ok(()),
            "the start completes"
        );
        let asked = service.flush(flush);
        // Read while the completion is held, and checked once it is let
        // go: a check that fails while it is held would leave the
        // service's drop waiting for it.
        let nothing = completed.try_recv().is_err();
        drop(release);
        assert!(asked);
        let after = [
            completed.recv_timeout(DEADLINE),
            completed.recv_timeout(DEADLINE),
        ]
        .into_iter()
        .map_while(Result::ok)
        .collect();
        (nothing, after)
    }

    /// The start has registered and left `Starting`, and its thread is in
    /// its completion, held there: a flush asked now is one the start was
    /// asked before, so it waits, and is completed after it.
    #[test]
    fn a_flush_asked_while_a_live_start_is_being_completed_is_completed_after_it() {
        let (fake, _ground, clock) = fake();
        let (service, completed, entered, release) = holding(&fake, &clock, 1);
        assert!(service.start(1, file("/w/f"), AT_ONCE));

        let (nothing, after) =
            flush_behind_a_held_completion(&service, &completed, &entered, release, 2);

        assert!(nothing, "the flush waits for the start's completion");
        assert_eq!(after, [1, 2]);
        assert_eq!(service.take(1), Some(WatchReply::Started));
    }

    /// As above, for a start refused: its refusal is kept, and its thread
    /// is in its completion.
    #[test]
    fn a_flush_asked_while_a_refused_start_is_being_completed_is_completed_after_it() {
        let (fake, _ground, clock) = fake();
        let (service, completed, entered, release) = holding(&fake, &clock, 1);
        assert!(service.start(1, file("relative"), AT_ONCE));

        let (nothing, after) =
            flush_behind_a_held_completion(&service, &completed, &entered, release, 2);

        assert!(nothing, "the flush waits for the start's completion");
        assert_eq!(after, [1, 2]);
        assert_eq!(refusal(service.take(1)), Some(RefusalKind::NotAbsolute));
    }

    /// A watch port over the fake whose registrations, as each is dropped,
    /// tell the first receiver of [`gated_drops`] and wait for its sender to
    /// be told or dropped, before the fake's registration is dropped.
    struct GatedDrops {
        /// The fake it registers with.
        fake: FakeWatch,
        /// Told as a drop begins.
        began: Arc<Mutex<Sender<()>>>,
        /// Waited on before a drop goes on.
        gate: Arc<Mutex<Receiver<()>>>,
    }

    /// A registration of [`GatedDrops`].
    struct GatedRegistration {
        /// The fake's registration, dropped once the gate is passed.
        _inner: <FakeWatch as Watch>::Registration,
        /// Told as the drop begins.
        began: Arc<Mutex<Sender<()>>>,
        /// Waited on before the drop goes on.
        gate: Arc<Mutex<Receiver<()>>>,
    }

    impl Drop for GatedRegistration {
        fn drop(&mut self) {
            self.began
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .send(())
                .ok();
            self.gate
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .recv()
                .ok();
        }
    }

    impl Watch for GatedDrops {
        type Registration = GatedRegistration;

        fn watch(
            &self,
            directory: &Path,
            depth: Depth,
            sink: Sink,
        ) -> Result<GatedRegistration, Refusal> {
            Ok(GatedRegistration {
                _inner: self.fake.watch(directory, depth, sink)?,
                began: Arc::clone(&self.began),
                gate: Arc::clone(&self.gate),
            })
        }
    }

    /// A port over `fake` whose drops are gated, the receiver told as each
    /// begins, and the sender that lets them go.
    fn gated_drops(fake: &FakeWatch) -> (GatedDrops, Receiver<()>, Sender<()>) {
        let (began, dropping) = mpsc::channel();
        let (release, gate) = mpsc::channel();
        let gated = GatedDrops {
            fake: fake.clone(),
            began: Arc::new(Mutex::new(began)),
            gate: Arc::new(Mutex::new(gate)),
        };
        (gated, dropping, release)
    }

    /// Start 1 is cancelled while it is in the port, and its thread, back
    /// from the port, is held inside the drop of what it registered: a
    /// flush asked now waits for that drop. Shutdown waits for the start's
    /// thread to finish, after the drop, so it too returns only once a
    /// cancelled start has dropped what it registered.
    #[test]
    fn a_flush_asked_while_a_cancelled_start_drops_its_registration_is_completed_after_the_drop() {
        let (fake, _ground, clock) = fake();
        let (gated, dropping, release) = gated_drops(&fake);
        let (sender, completed) = mpsc::channel();
        let sender = Mutex::new(sender);
        let service = Service::new(gated, clock.clone(), move |id| {
            sender
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .send(id)
                .ok();
        });
        fake.hold_watches();
        assert!(service.start(1, directory("/w", Depth::Tree), AT_ONCE));
        assert!(fake.until(DEADLINE, |record| record.parked == 1));
        assert!(service.cancel(1));
        fake.release_watches();
        assert_eq!(dropping.recv_timeout(DEADLINE), Ok(()), "the drop begins");

        let asked = service.flush(2);
        // Read while the drop is held, and checked once it is let go.
        let nothing = completed.try_recv().is_err();
        let live = fake.live();
        drop(release);
        assert!(asked);
        assert!(nothing, "the flush waits for the cancelled start's drop");
        assert_eq!(
            live,
            [(PathBuf::from("/w"), Depth::Tree)],
            "held in its drop"
        );
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(2));
        assert_eq!(fake.live(), [], "dropped before the flush was completed");
        service.shutdown();
        assert!(
            completed.try_recv().is_err(),
            "the start is never completed"
        );
    }

    #[test]
    fn a_flush_with_no_start_in_flight_is_completed_at_once_whatever_is_live() {
        let (fake, _ground, clock) = fake();
        let (service, completed) = service(&fake, &clock);
        started(&service, &completed, 1, file("/w/f"), AT_ONCE);
        assert!(service.next(1, 2), "a pending read is not waited for");

        assert!(service.flush(3));

        assert_eq!(completed.try_recv(), Ok(3));
    }

    /// Shutdown runs on a thread of its own while start 1 is held in the
    /// port, and the start is let go only once shutdown has withdrawn it.
    /// The sign is the live watch 4's registration being dropped, which
    /// shutdown does in the same step as it withdraws every start, before
    /// it waits for them. A start let go any earlier comes back wanted and
    /// is completed, which is the interleaving this test rules out.
    #[test]
    fn a_cancelled_flush_is_never_completed_and_shutdown_completes_one_waiting() {
        let (fake, _ground, clock) = fake();
        let (service, completed) = service(&fake, &clock);
        // On a registration of its own, apart from start 1's.
        started(
            &service,
            &completed,
            4,
            directory("/w/sub", Depth::Entries),
            AT_ONCE,
        );
        fake.hold_watches();
        assert!(service.start(1, file("/w/f"), AT_ONCE));
        assert!(fake.until(DEADLINE, |record| record.parked == 1));
        // Checked once the start is let go, as above.
        let asked = service.flush(2) && service.flush(3);
        let withdrawn = service.cancel(2) && !service.cancel(2);

        let shutting = {
            let service = service.clone();
            thread::spawn(move || service.shutdown())
        };
        let shut = fake.until(DEADLINE, |record| record.dropped.len() == 1);
        fake.release_watches();
        shutting.join().expect("shutdown returns");
        assert!(asked && withdrawn);
        assert!(shut, "shutdown ends the live watch while the start is held");

        // The cancelled start is never completed, nor the cancelled flush.
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(3));
        assert!(completed.try_recv().is_err());
        assert_eq!(service.pending(), 0);
        // The start dropped what it registered before the flush it was the
        // last thing for was completed.
        assert_eq!(fake.live(), []);
    }

    #[test]
    fn a_cancel_while_the_watch_call_is_held_drops_the_registration() {
        let (fake, _ground, clock) = fake();
        let (service, completed) = service(&fake, &clock);
        fake.hold_watches();

        assert!(service.start(1, file("/w/f"), AT_ONCE));
        assert!(fake.until(DEADLINE, |record| record.parked == 1));
        assert!(service.cancel(1));
        fake.release_watches();

        assert!(fake.until(DEADLINE, |record| record.dropped.len() == 1));
        assert_eq!(fake.live(), []);
        assert!(completed.try_recv().is_err(), "never completed");
        assert_eq!(service.take(1), None);
        assert_eq!(service.pending(), 0);
    }

    #[test]
    fn a_registration_is_never_dropped_under_the_lock() {
        let (fake, _ground, clock) = fake();
        fake.call_sinks_on_drop();
        let (service, completed) = service(&fake, &clock);
        started(&service, &completed, 1, file("/w/f"), AT_ONCE);
        started(&service, &completed, 2, file("/x"), AT_ONCE);
        fake.hold_watches();
        assert!(service.start(3, directory("/w", Depth::Tree), AT_ONCE));
        assert!(fake.until(DEADLINE, |record| record.parked == 1));
        assert!(service.cancel(3));

        let (done, finished) = mpsc::channel();
        let ended = service.clone();
        thread::spawn(move || {
            ended.cancel(1);
            done.send("cancel").ok();
            ended.shutdown();
            done.send("shutdown").ok();
        });
        assert_eq!(finished.recv_timeout(DEADLINE), Ok("cancel"));
        fake.release_watches();
        assert_eq!(finished.recv_timeout(DEADLINE), Ok("shutdown"));

        assert_eq!(fake.live(), []);
        assert_eq!(fake.record().dropped.len(), 3);
    }

    #[test]
    fn shutdown_refuses_later_starts_and_ends_every_watch() {
        let (fake, ground, clock) = fake();
        let (service, completed) = service(&fake, &clock);
        started(&service, &completed, 1, file("/w/f"), AT_ONCE);
        started(
            &service,
            &completed,
            2,
            directory("/w", Depth::Tree),
            AT_ONCE,
        );
        assert!(service.next(1, 3));

        service.shutdown();
        ground.write(Path::new("/w/f"), b"x");

        assert_eq!(fake.live(), []);
        assert_eq!(service.pending(), 0);
        assert!(completed.try_recv().is_err(), "the pending read is dropped");
        assert!(service.start(4, file("/w/f"), AT_ONCE));
        assert_eq!(completed.try_recv(), Ok(4), "completed at once");
        assert_eq!(refusal(service.take(4)), Some(RefusalKind::ShutDown));
        service.shutdown();
        assert_eq!(fake.record().watched.len(), 2);
    }

    #[test]
    fn an_id_in_use_is_refused() {
        let (fake, _ground, clock) = fake();
        let (service, completed) = service(&fake, &clock);
        fake.hold_watches();

        assert!(service.start(1, file("/w/f"), AT_ONCE));
        assert!(!service.start(1, file("/w/g"), AT_ONCE), "starting");
        fake.release_watches();
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(1));
        assert!(!service.start(1, file("/w/g"), AT_ONCE), "not taken");
        assert_eq!(service.take(1), Some(WatchReply::Started));
        assert!(!service.start(1, file("/w/g"), AT_ONCE), "a live watch");
        assert!(!service.next(1, 1), "the watch's own id");
        assert!(service.next(1, 2));
        assert!(!service.start(2, file("/w/g"), AT_ONCE), "a pending wait");

        assert!(service.cancel(1));
        assert!(service.start(1, file("/w/g"), AT_ONCE), "free again");
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(1));
    }
}
