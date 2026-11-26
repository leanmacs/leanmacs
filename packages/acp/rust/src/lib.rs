//! The service of the package `acp`: a client of the Agent Client Protocol
//! over the SDK `agent-client-protocol`, on a streaming child the core's
//! process service opened and a Lean job handed over, posting plain events
//! and completing each request on the completion queue
//! (`docs/design/agent-hosting.md`, "ACP").
//!
//! It is `agents-api`'s service `agents`, which `acp`'s Lean library binds
//! (`Acp/Real.lean`): `open` hands it a child, `load` hands it a child and
//! the id of a session the agent stored, `next` waits for a session's
//! events, and an order (`prompt`, `cancel`, `set mode`, `answer`) goes to a
//! session from any job.
//!
//! It keeps the rules every service keeps (`editor-ffi`'s crate docs,
//! "Services and completions"):
//!
//! - **The caller names the request**, which a start refuses while its id
//!   is in use.
//! - **One completion for each request**, through the [`Completer`] port; a
//!   request withdrawn first ([`Acp::cancel`]) gets none.
//! - **A flush is reported behind the work it covers** ([`Acp::flush`]):
//!   every `open` and order started before it and not yet reported. A
//!   pending `next` is a long poll, which a flush does not wait for, as the
//!   process service's flush does not wait for a live streaming child.
//! - **Plain data only**: a reply is taken by its request's id
//!   ([`Acp::take`]), as the text `event.rs` defines.
//!
//! And the session's:
//!
//! - **A `next` completes** at once when the session holds events, or once
//!   it posts one, with every event it holds; a second `next` of a session
//!   while one is pending is refused at its start; a `next` after the
//!   session's last event is answered refused.
//! - **An answer** goes straight to the parked request from the caller's
//!   thread ([`session::Link::answer`]), and completes at once.
//! - **A session's state is freed** once its last event is taken, or once
//!   it has ended after its job withdrew a `next` of it or its `open`, or
//!   before it opened, which refuses its `open`. A withdrawn `open` ends the
//!   session too, as no job knows its number: its link is dropped
//!   ([`Acp::cancel`]).
//! - **Events before the open are queued**: a load (`session/load`) posts
//!   the session's history before it opens, and the first `next` takes it.
//!
//! The logic is here and in the modules below, over two ports: the
//! [`Completer`] and the [`Connector`], which starts a session on a child.
//! Its tests run on `editor-service`'s `RecordingCompleter` and a connector
//! whose sessions run on a `LocalPool` the test steps over a scripted
//! transport. The real connector ([`Threads`]) takes the child over
//! (`editor_service::stream::take_over`) and runs the session on one thread
//! and its pull on another. The process's instance and the C functions
//! Lean's glue calls are in [`ffi`], and `tests/wiring.rs` runs one over the
//! process's completion queue.
//!
//! No SDK type leaves the crate: the C functions and the plain events are
//! the crate's own, and the root `deny.toml` lets no other crate depend on
//! the SDK.

pub mod event;
pub mod ffi;
pub mod filter;
pub mod merge;
pub mod session;
pub mod stream;
pub mod tickets;

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};

use editor_service::Completer;
use editor_service::stream::ChildStreams;

use crate::event::{Event, Reply};
use crate::session::{Link, Order, Outbox, Output, Setup};

/// What starts a session on a child: the real one takes it over and runs it
/// on threads ([`Threads`]); a test's runs it on a pool it steps.
pub trait Connector {
    /// Starts a session on the streaming child `child`, opened with `setup`,
    /// posting to `outbox`, and gives its link.
    ///
    /// # Errors
    ///
    /// Why it could not: the take-over was refused, or no thread was given.
    fn connect(&self, child: u64, setup: Setup, outbox: Outbox) -> Result<Link, String>;
}

/// The real connector: takes the child over through `editor-service`'s
/// stream source, and runs the session on one thread, blocked on its
/// future, and the pull of the child's output on another
/// (`docs/design/rust-library.md`, "Threads"). Every write goes straight
/// from the session's thread through the child's streams, so it has one
/// writer.
#[derive(Debug, Default)]
pub struct Threads {
    /// The threads started and not yet joined: those that have ended are
    /// joined at the next start, so none is left detached.
    workers: Mutex<Vec<JoinHandle<()>>>,
}

impl Threads {
    /// A connector that has started nothing.
    pub fn new() -> Self {
        Self::default()
    }

    /// Runs the session over the taken-over child `streams`.
    fn run(
        &self,
        streams: Box<dyn ChildStreams>,
        setup: Setup,
        outbox: Outbox,
    ) -> Result<Link, String> {
        let (transport, pump) = stream::transport(Arc::from(streams));
        let (link, future) = session::session(transport, setup, outbox);
        let session = thread::Builder::new()
            .name("acp-session".into())
            .spawn(move || futures::executor::block_on(future))
            .map_err(|error| format!("no thread for the session: {error}"))?;
        let pull = thread::Builder::new()
            .name("acp-pull".into())
            .spawn(move || while pump.step() {})
            .map_err(|error| format!("no thread for the pull: {error}"))?;
        let mut workers = self.workers.lock().unwrap_or_else(PoisonError::into_inner);
        #[expect(
            clippy::disallowed_methods,
            reason = "reaps the threads that have ended, so the list stays short; it never waits and decides nothing a test sees"
        )]
        let (ended, running): (Vec<_>, Vec<_>) =
            workers.drain(..).partition(JoinHandle::is_finished);
        for ended in ended {
            let _ = ended.join();
        }
        *workers = running;
        workers.push(session);
        workers.push(pull);
        Ok(link)
    }
}

impl Connector for Threads {
    fn connect(&self, child: u64, setup: Setup, outbox: Outbox) -> Result<Link, String> {
        let streams = editor_service::stream::take_over(child)
            .map_err(|refused| format!("the take-over was refused: {refused:?}"))?;
        self.run(streams, setup, outbox)
    }
}

/// What a request is of.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    /// An `open` of the session.
    Open,
    /// A `next` of the session.
    Next,
    /// An order to the session.
    Send,
}

/// A request in use: started and not yet taken or withdrawn.
#[derive(Debug)]
struct Request {
    /// What it is of.
    kind: Kind,
    /// The session it names.
    session: u64,
    /// Its reply, once it is ready; a `next`'s is made when it is taken.
    reply: Option<Reply>,
    /// Whether it is ready to be taken.
    ready: bool,
    /// Whether its report has been made, so a flush need not wait for it.
    reported: bool,
}

/// A session the service holds.
#[derive(Debug, Default)]
struct Held {
    /// How to reach it, once the connector has started it.
    link: Option<Link>,
    /// Its events not yet taken, oldest first.
    queue: Vec<Event>,
    /// The `next` waiting for its events.
    waiting: Option<u64>,
    /// The `open` waiting for it to open.
    opening: Option<u64>,
    /// Whether its last event has been posted.
    ended: bool,
    /// Whether its job has gone: a `next` of it was withdrawn, or its `open`
    /// was, or its `open` was refused because it ended first, so that no job
    /// knows its number.
    abandoned: bool,
}

/// A flush not yet reported.
#[derive(Debug)]
struct Flush {
    /// Its id.
    id: u64,
    /// The requests it waits for.
    waiting: Vec<u64>,
}

/// What the service holds.
#[derive(Debug, Default)]
struct State {
    /// The requests in use, by id.
    requests: HashMap<u64, Request>,
    /// The sessions, by number.
    sessions: HashMap<u64, Held>,
    /// The last session's number.
    numbered: u64,
    /// The flushes not yet reported, oldest first.
    flushes: Vec<Flush>,
}

impl State {
    /// Takes `id` out of every flush's wait, and gives the flushes that then
    /// wait for nothing, oldest first.
    fn settled(&mut self, id: u64) -> Vec<u64> {
        for flush in &mut self.flushes {
            flush.waiting.retain(|&waited| waited != id);
        }
        let (ready, waiting): (Vec<_>, Vec<_>) = self
            .flushes
            .drain(..)
            .partition(|flush| flush.waiting.is_empty());
        self.flushes = waiting;
        ready.into_iter().map(|flush| flush.id).collect()
    }

    /// Readies `id` with `reply`, if it is still in use: whether to report
    /// it.
    fn ready(&mut self, id: u64, reply: Option<Reply>) -> bool {
        match self.requests.get_mut(&id) {
            Some(request) => {
                request.reply = reply;
                request.ready = true;
                true
            }
            None => false,
        }
    }

    /// Starts the request `id` of `kind` on the session `session`, if `id`
    /// is free: whether it started.
    fn begin(&mut self, id: u64, kind: Kind, session: u64) -> bool {
        if self.requests.contains_key(&id) {
            return false;
        }
        self.requests.insert(
            id,
            Request {
                kind,
                session,
                reply: None,
                ready: false,
                reported: false,
            },
        );
        true
    }

    /// Frees the session `number` once nothing of it is left to take: its
    /// last event posted and taken, or posted after its job withdrew.
    fn free_if_done(&mut self, number: u64) {
        let done = self.sessions.get(&number).is_some_and(|held| {
            held.ended
                && held.waiting.is_none()
                && held.opening.is_none()
                && (held.queue.is_empty() || held.abandoned)
        });
        let referenced = self
            .requests
            .values()
            .any(|request| request.session == number && request.kind == Kind::Next);
        if done && !referenced {
            self.sessions.remove(&number);
        }
    }
}

/// The service, reporting through `C` and starting sessions through `K`.
pub struct Acp<C, K> {
    /// What the service and its sessions' outboxes share.
    shared: Arc<Shared<C>>,
    /// What starts a session.
    connector: K,
}

/// What [`Acp`] and its sessions' outboxes share.
struct Shared<C> {
    /// What reports that a request has finished.
    completer: C,
    /// The requests and the sessions.
    state: Mutex<State>,
}

impl<C> Shared<C> {
    /// Locks the state. The lock is never held while a session's code or
    /// the completer runs, so a poisoned lock still guards a consistent
    /// state.
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl<C: Completer> Shared<C> {
    /// Reports each of `ids`, then marks it reported and reports each flush
    /// that waited only for it, behind it.
    fn report(&self, ids: Vec<u64>) {
        for id in ids {
            self.completer.complete(id);
            let ready = {
                let mut state = self.state();
                if let Some(request) = state.requests.get_mut(&id) {
                    request.reported = true;
                }
                state.settled(id)
            };
            for flush in ready {
                self.completer.complete(flush);
            }
        }
    }

    /// The requests to report for the event `event` the session `number`
    /// posted: its waiting `next`, and its `open` if it ended first.
    ///
    /// An event posted before the session opened is queued like any other:
    /// a load's history comes before its `Opened`, and is the first `next`'s.
    /// An `open` refused because its session ended first marks the session
    /// abandoned, as no job will know its number: its queue is freed, never
    /// held for a `next` that cannot come.
    fn queued(state: &mut State, number: u64, event: Event) -> Vec<u64> {
        let ended = matches!(event, Event::Ended(_));
        let Some(held) = state.sessions.get_mut(&number) else {
            return Vec::new();
        };
        let refusal = ended.then(|| {
            Reply::Refused(format!(
                "the session ended before it opened: {}",
                event.encode()
            ))
        });
        held.queue.push(event);
        held.ended |= ended;
        let waiting = held.waiting.take();
        let opening = if ended { held.opening.take() } else { None };
        held.abandoned |= opening.is_some();
        let mut report = Vec::new();
        if let Some(id) = waiting
            && state.ready(id, None)
        {
            report.push(id);
        }
        if let Some(id) = opening
            && state.ready(id, refusal)
        {
            report.push(id);
        }
        if ended {
            state.free_if_done(number);
        }
        report
    }

    /// What the session `number` posted.
    fn posted(&self, number: u64, output: Output) {
        let report = {
            let mut state = self.state();
            match output {
                Output::Opened(mut opened) => {
                    opened.session = number;
                    let opening = state
                        .sessions
                        .get_mut(&number)
                        .and_then(|held| held.opening.take());
                    match opening {
                        Some(id) if state.ready(id, Some(Reply::Opened(opened))) => vec![id],
                        _ => Vec::new(),
                    }
                }
                Output::Sent(id, sent) => {
                    let reply = match sent {
                        Ok(turn) => Reply::Sent(turn),
                        Err(reason) => Reply::Refused(reason),
                    };
                    if state.ready(id, Some(reply)) {
                        vec![id]
                    } else {
                        Vec::new()
                    }
                }
                Output::Event(event) => Self::queued(&mut state, number, event),
            }
        };
        self.report(report);
    }
}

impl<C: Completer + Send + Sync + 'static, K: Connector> Acp<C, K> {
    /// A service that reports through `completer` and starts sessions
    /// through `connector`, with no request.
    pub fn new(completer: C, connector: K) -> Self {
        Self {
            shared: Arc::new(Shared {
                completer,
                state: Mutex::new(State::default()),
            }),
            connector,
        }
    }

    /// Opens a session on the streaming child `child`, as the request `id`:
    /// a new one, or the one `setup` loads ([`Setup::load`]). It completes
    /// once the agent has the session, or refused if the session ends
    /// first. Whether it started: not while `id` is in use, nor
    /// when the child could not be taken over.
    pub fn open(&self, id: u64, child: u64, setup: Setup) -> bool {
        let number = {
            let mut state = self.shared.state();
            if !state.begin(id, Kind::Open, 0) {
                return false;
            }
            state.numbered += 1;
            let number = state.numbered;
            if let Some(request) = state.requests.get_mut(&id) {
                request.session = number;
            }
            // Held before the connector runs, so nothing it posts is lost.
            state.sessions.insert(
                number,
                Held {
                    opening: Some(id),
                    ..Held::default()
                },
            );
            number
        };
        let shared = Arc::clone(&self.shared);
        let outbox: Outbox = Arc::new(move |output| shared.posted(number, output));
        match self.connector.connect(child, setup, outbox) {
            Ok(link) => {
                let mut state = self.shared.state();
                match state.sessions.get_mut(&number) {
                    // Withdrawn while the connector ran: dropped, as the
                    // cancel drops a link it finds, and the session ends.
                    Some(held) if !held.abandoned => held.link = Some(link),
                    _ => {
                        drop(state);
                        drop(link);
                    }
                }
                true
            }
            Err(_) => {
                let mut state = self.shared.state();
                state.sessions.remove(&number);
                state.requests.remove(&id);
                false
            }
        }
    }

    /// Waits for the session's next events, as the request `id`, which
    /// completes once the session holds one. Whether it started: not while
    /// `id` is in use, for a session not held, nor while another `next` of
    /// it is pending.
    pub fn next(&self, id: u64, session: u64) -> bool {
        let report = {
            let mut state = self.shared.state();
            if state.requests.contains_key(&id) {
                return false;
            }
            let Some(held) = state.sessions.get_mut(&session) else {
                return false;
            };
            if held.waiting.is_some() {
                return false;
            }
            let now = !held.queue.is_empty() || held.ended;
            if !now {
                held.waiting = Some(id);
            }
            state.requests.insert(
                id,
                Request {
                    kind: Kind::Next,
                    session,
                    reply: None,
                    ready: now,
                    reported: false,
                },
            );
            now
        };
        if report {
            self.shared.report(vec![id]);
        }
        true
    }

    /// The link of the session `session`, if it is held, started and has
    /// not ended.
    fn link(&self, session: u64) -> Option<Link> {
        let state = self.shared.state();
        state
            .sessions
            .get(&session)
            .filter(|held| !held.ended)
            .and_then(|held| held.link.clone())
    }

    /// Readies the request `id` with `reply` and reports it.
    fn answer_now(&self, id: u64, reply: Reply) {
        let ready = self.shared.state().ready(id, Some(reply));
        if ready {
            self.shared.report(vec![id]);
        }
    }

    /// Hands the session `order`, as the request `id`, which completes once
    /// the order is on its way, or refused when the session is not held or
    /// has ended. Whether it started: not while `id` is in use.
    pub fn send(&self, id: u64, session: u64, order: Order) -> bool {
        if !self.shared.state().begin(id, Kind::Send, session) {
            return false;
        }
        match self.link(session) {
            Some(link) if link.order(id, order) => {}
            _ => self.answer_now(
                id,
                Reply::Refused(format!("the session {session} has ended")),
            ),
        }
        true
    }

    /// Answers the session's parked permission request `ticket` with
    /// `option`, as the request `id`, which completes at once: sent, or
    /// refused when the ticket is not parked. Whether it started: not while
    /// `id` is in use.
    pub fn answer(&self, id: u64, session: u64, ticket: u64, option: &str) -> bool {
        if !self.shared.state().begin(id, Kind::Send, session) {
            return false;
        }
        let reply = match self.link(session) {
            Some(link) => match link.answer(ticket, option) {
                Ok(()) => Reply::Sent(None),
                Err(reason) => Reply::Refused(reason),
            },
            None => Reply::Refused(format!("the session {session} has ended")),
        };
        self.answer_now(id, reply);
        true
    }

    /// The reply to the request `id`, once it is ready, after which `id` is
    /// free; `None`, changing nothing, before then and for an id not in use.
    /// A `next`'s reply is every event its session holds, or refused once
    /// the session has ended and none is left.
    pub fn take(&self, id: u64) -> Option<Reply> {
        let mut state = self.shared.state();
        if !state.requests.get(&id)?.ready {
            return None;
        }
        let request = state.requests.remove(&id)?;
        let reply = match request.kind {
            Kind::Next => {
                let events = state
                    .sessions
                    .get_mut(&request.session)
                    .map(|held| std::mem::take(&mut held.queue))
                    .unwrap_or_default();
                if events.is_empty() {
                    Reply::Refused(format!("the session {} has ended", request.session))
                } else {
                    Reply::Batch(events)
                }
            }
            Kind::Open | Kind::Send => request
                .reply
                .unwrap_or_else(|| Reply::Refused("no reply".to_owned())),
        };
        state.free_if_done(request.session);
        Some(reply)
    }

    /// Withdraws the request `id`, and says whether it was in use: it is
    /// reported to nobody if it was not yet. A `next` withdrawn leaves its
    /// session's events for the next one. An `open` withdrawn, before it
    /// completes or once it is ready and not taken, ends its session: no
    /// job knows the session's number, so no order or `next` can reach it,
    /// and its link is dropped, which ends the session once it is open (or
    /// at once, if its child ends first); its state is freed at that end. A
    /// flush that waited only for it is reported.
    pub fn cancel(&self, id: u64) -> bool {
        let (cancelled, ready, link) = {
            let mut state = self.shared.state();
            match state.requests.remove(&id) {
                Some(request) => {
                    let mut link: Option<Link> = None;
                    if let Some(held) = state.sessions.get_mut(&request.session) {
                        if held.waiting == Some(id) {
                            held.waiting = None;
                        }
                        if held.opening == Some(id) {
                            held.opening = None;
                        }
                        match request.kind {
                            Kind::Next => held.abandoned = true,
                            Kind::Open => {
                                held.abandoned = true;
                                link = held.link.take();
                            }
                            Kind::Send => {}
                        }
                    }
                    state.free_if_done(request.session);
                    (true, state.settled(id), link)
                }
                None => (false, Vec::new(), None),
            }
        };
        // Dropped outside the lock: the session it ends posts through it.
        drop(link);
        for flush in ready {
            self.shared.completer.complete(flush);
        }
        cancelled
    }

    /// Reports `id` once every `open` and order started before this call
    /// has been reported or withdrawn, behind their reports: at once when
    /// none is in flight. A pending `next` is not waited for.
    pub fn flush(&self, id: u64) {
        {
            let mut state = self.shared.state();
            let waiting: Vec<u64> = state
                .requests
                .iter()
                .filter(|(_, request)| request.kind != Kind::Next && !request.reported)
                .map(|(&waited, _)| waited)
                .collect();
            if !waiting.is_empty() {
                state.flushes.push(Flush { id, waiting });
                return;
            }
        }
        self.shared.completer.complete(id);
    }

    /// How many sessions the service holds.
    pub fn sessions(&self) -> usize {
        self.shared.state().sessions.len()
    }
}

#[cfg(test)]
mod tests;
