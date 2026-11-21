//! The diff service: a line diff of two snapshots, worked on a thread of
//! its own and completed through the completion queue.
//!
//! This is the fifth service behind the completion queue, in the file
//! service's shape (the crate docs, "Services and completions"). A job in
//! Lean asks for the diff of two snapshots with an id: the snapshot a
//! reload's command took of a buffer, and the one the job's load holds.
//! [`Diffs::start`] returns at once; the service's thread works the oldest
//! request with no lock held, keeps the edit script (or, for a request
//! [`Diffs::start_hunks`] made, the hunks) under the request's id
//! and completes the request: for the process's instance, by queueing an
//! [`EventKind::Completion`](crate::events::EventKind::Completion) whose
//! code is the id. The caller then takes the script ([`Diffs::take`]),
//! once. Rust never calls Lean.
//!
//! What a script is (the common head and tail, the line limit, the trim to
//! a character boundary) is `editor-diff`'s ([`editor_diff::script`]),
//! pinned there on the port's fake and by the contract on the real
//! engine. This module decides only what a *service* decides: which
//! request is worked when, what cancelling means, and how a script
//! crosses.
//!
//! The rules:
//!
//! - **A thread of its own.** A long diff never holds up a load or a save,
//!   which are worked on the file service's thread, and the editor thread
//!   never diffs: it only applies a script
//!   ([`transaction`](crate::transaction), `editor_ffi_document_apply_script`).
//! - **In order, one at a time**, as the file service's requests are. A
//!   start never reads a text.
//! - **An id in use is refused**: one that is waiting, being worked, or
//!   whose script has not been taken.
//! - **Cancelling.** A request still waiting is never worked and never
//!   completed. One being worked is worked to its end, and its script is
//!   dropped and not completed. A script already kept is dropped.
//! - **A flush is a barrier** ([`Diffs::flush`]), the file service's
//!   marker on the shared queue ([`Requests`]): completed when the worker
//!   reaches it, behind the completions of every diff started before it.
//!   It keeps no answer, and a cancel withdraws it while it waits.
//! - **What it is given**: the two snapshots, cloned from the caller's
//!   handles, which copies none of their text; and nothing it could write
//!   editor state with.
//!
//! The process has one instance, over the real engine
//! ([`editor_diff_imara::ImaraDiff`]), a `const`-initialised static like
//! the file service's. Its thread, `editor-diffs`, starts with the first
//! request.
//!
//! # How a script crosses
//!
//! [`editor_ffi_diffs_take`] fills a [`RawWords`] whose status is 0 and
//! whose words are the count of steps, then three words for each: its
//! kind (0 a retain, 1 a delete, 2 an insert) and two numbers, a retain's
//! and a delete's count and 0, or an insert's start in the new text and
//! its count.
//!
//! # How hunks cross
//!
//! [`editor_ffi_diffs_take_hunks`] fills a [`RawWords`] whose status is 0
//! and whose words are the count of hunks, then four for each: its old
//! range's start and stop, and its new range's start and stop, in bytes.
//! A take of the other kind's answer takes nothing, returns false, and
//! leaves the answer kept: a request is taken by the take of its kind.
//!
//! # The C functions
//!
//! | Function | Does |
//! |---|---|
//! | [`editor_ffi_diffs_start`] | Starts the diff of two snapshot handles under a line limit. False, starting nothing, for an id in use, or when the service has no thread |
//! | [`editor_ffi_diffs_take`] | Fills a [`RawWords`] and returns true, or returns false when the service keeps no script for the id |
//! | [`editor_ffi_diffs_start_hunks`] | As `start`, for the hunks of the two texts |
//! | [`editor_ffi_diffs_take_hunks`] | Fills a [`RawWords`] with the hunks and returns true, or returns false when the service keeps no hunks for the id |
//! | [`editor_ffi_diffs_flush`] | Asks for an id to be completed once every diff started before it is worked; keeps no answer. False, starting nothing, as for a start |
//! | [`editor_ffi_diffs_cancel`] | Cancels, and says whether there was anything to cancel |
//! | [`editor_ffi_diffs_pending`] | Requests waiting or being worked, and answers (scripts or hunks) not yet taken |

use std::collections::BTreeMap;
use std::marker::PhantomData;
use std::sync::{Condvar, Mutex, MutexGuard, OnceLock, PoisonError};
use std::thread;

use editor_diff::{ByteHunk, LineDiff, Step};
use editor_diff_imara::ImaraDiff;

use crate::events;
use crate::files::{Queued, Requests};
use crate::log::RawWords;
use crate::snapshot::Snapshot;
use crate::words::Writer;

/// Which answer a request asks for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// An edit script ([`editor_diff::script`]).
    Script,
    /// Hunks of whole lines ([`editor_diff::hunks`]).
    Hunks,
}

/// A worked request's answer, of the kind it asked for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Answer {
    /// An edit script.
    Script(Vec<Step>),
    /// Hunks of whole lines.
    Hunks(Vec<ByteHunk>),
}

/// What is asked of the diff service.
pub struct Request {
    /// Which answer is asked for.
    kind: Kind,
    /// The old text.
    old: editor_text::Snapshot,
    /// The new text.
    new: editor_text::Snapshot,
    /// The most lines a side of the middle the engine is asked about.
    limit: usize,
}

/// The diff service over the engine `E`, a fresh one of which works each
/// request: diffs that [`run`](Self::run) works one at a time, in the
/// order they were started.
pub struct Diffs<E> {
    /// The requests, the scripts, and whether the service has been stopped.
    state: Mutex<State>,
    /// Signalled when a request is added or the service is stopped.
    changed: Condvar,
    /// The engine, made for each request.
    engine: PhantomData<fn() -> E>,
}

/// What [`Diffs::state`] guards.
struct State {
    /// The requests not yet worked.
    requests: Requests<Request>,
    /// The id of the request being worked, if one is, and whether it has
    /// been cancelled since it was taken up.
    working: Option<(u64, bool)>,
    /// The answers not yet taken, by request id.
    answers: BTreeMap<u64, Answer>,
    /// Whether [`Diffs::stop`] has been called.
    stopped: bool,
}

impl<E: LineDiff + Default> Diffs<E> {
    /// A service with no requests, whose loop is not running.
    pub const fn new() -> Self {
        Self {
            state: Mutex::new(State {
                requests: Requests::new(),
                working: None,
                answers: BTreeMap::new(),
                stopped: false,
            }),
            changed: Condvar::new(),
            engine: PhantomData,
        }
    }

    /// Asks for the diff of `old` and `new` under the line limit `limit`,
    /// as the request `id`, and returns whether it was accepted. It returns
    /// at once and reads no text. An id in use is refused.
    pub fn start(
        &self,
        id: u64,
        old: editor_text::Snapshot,
        new: editor_text::Snapshot,
        limit: usize,
    ) -> bool {
        self.start_kind(id, Kind::Script, old, new, limit)
    }

    /// As [`start`](Self::start), for the hunks of `old` and `new` in
    /// place of a script.
    pub fn start_hunks(
        &self,
        id: u64,
        old: editor_text::Snapshot,
        new: editor_text::Snapshot,
        limit: usize,
    ) -> bool {
        self.start_kind(id, Kind::Hunks, old, new, limit)
    }

    /// Asks for the answer `kind` of `old` and `new` as the request `id`.
    fn start_kind(
        &self,
        id: u64,
        kind: Kind,
        old: editor_text::Snapshot,
        new: editor_text::Snapshot,
        limit: usize,
    ) -> bool {
        let mut state = self.state();
        let in_use = state.answers.contains_key(&id)
            || state.working.is_some_and(|(working, _)| working == id);
        let request = Request {
            kind,
            old,
            new,
            limit,
        };
        let started = !in_use && state.requests.start(id, request);
        drop(state);
        self.changed.notify_all();
        started
    }

    /// Asks for the request `id` to be completed once every diff started
    /// before this call has been worked, and returns whether it was
    /// accepted. It returns at once. An id in use is refused. It keeps no
    /// answer: its completion is the whole answer. Cancelling it while it
    /// waits withdraws it.
    pub fn flush(&self, id: u64) -> bool {
        let mut state = self.state();
        let in_use = state.answers.contains_key(&id)
            || state.working.is_some_and(|(working, _)| working == id);
        let started = !in_use && state.requests.start_flush(id);
        drop(state);
        self.changed.notify_all();
        started
    }

    /// Hands over the script of the request `id`, once. `None` when the
    /// service keeps no script for it: a request for hunks keeps its
    /// answer.
    pub fn take(&self, id: u64) -> Option<Vec<Step>> {
        let mut state = self.state();
        match state.answers.remove(&id)? {
            Answer::Script(steps) => Some(steps),
            other => {
                state.answers.insert(id, other);
                None
            }
        }
    }

    /// Hands over the hunks of the request `id`, once. `None` when the
    /// service keeps no hunks for it: a request for a script keeps its
    /// answer.
    pub fn take_hunks(&self, id: u64) -> Option<Vec<ByteHunk>> {
        let mut state = self.state();
        match state.answers.remove(&id)? {
            Answer::Hunks(hunks) => Some(hunks),
            other => {
                state.answers.insert(id, other);
                None
            }
        }
    }

    /// Cancels the request `id`, and returns whether there was anything to
    /// cancel. It is safe for an id that is unknown.
    pub fn cancel(&self, id: u64) -> bool {
        let mut state = self.state();
        if state.requests.cancel(id) {
            return true;
        }
        if let Some((working, cancelled)) = &mut state.working
            && *working == id
        {
            return !std::mem::replace(cancelled, true);
        }
        state.answers.remove(&id).is_some()
    }

    /// How many requests are waiting or being worked, and how many answers
    /// (scripts or hunks) have not yet been taken, together.
    pub fn pending(&self) -> usize {
        let state = self.state();
        state.requests.pending() + usize::from(state.working.is_some()) + state.answers.len()
    }

    /// Ends [`run`](Self::run), for good, once the request it is working is
    /// done.
    pub fn stop(&self) {
        self.state().stopped = true;
        self.changed.notify_all();
    }

    /// The service loop: works each request in the order they were
    /// started, keeps its script, and calls `complete` with its id; and
    /// otherwise parks the calling thread until a request is started. It
    /// returns after [`stop`](Self::stop). The engine is asked, and
    /// `complete` called, with no lock held.
    pub fn run(&self, complete: impl Fn(u64)) {
        let mut state = self.state();
        loop {
            if state.stopped {
                return;
            }
            let Some((id, queued)) = state.requests.take_next() else {
                state = self
                    .changed
                    .wait(state)
                    .unwrap_or_else(PoisonError::into_inner);
                continue;
            };
            // The diff service starts no unobserved request: each has an id.
            let Some(id) = id else {
                continue;
            };
            let request = match queued {
                Queued::Work(request) => request,
                // Every diff started before it has been worked: it is
                // completed now, and keeps no answer.
                Queued::Flush => {
                    drop(state);
                    complete(id);
                    state = self.state();
                    continue;
                }
            };
            state.working = Some((id, false));
            drop(state);
            let answer = work(&mut E::default(), &request);
            state = self.state();
            let cancelled = state.working.take().is_some_and(|(_, cancelled)| cancelled);
            if cancelled {
                continue;
            }
            state.answers.insert(id, answer);
            drop(state);
            complete(id);
            state = self.state();
        }
    }

    /// Locks the state. The lock is never held while other code runs, so a
    /// poisoned lock still guards a consistent state.
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl<E: LineDiff + Default> Default for Diffs<E> {
    fn default() -> Self {
        Self::new()
    }
}

/// The whole of `snapshot`'s text, as one string.
fn whole(snapshot: &editor_text::Snapshot) -> String {
    let mut text = String::with_capacity(snapshot.len());
    for chunk in snapshot.chunks() {
        text.push_str(chunk);
    }
    text
}

/// The answer `request` asks for, over `engine`.
fn work(engine: &mut impl LineDiff, request: &Request) -> Answer {
    let (old, new) = (whole(&request.old), whole(&request.new));
    match request.kind {
        Kind::Script => Answer::Script(editor_diff::script(engine, &old, &new, request.limit)),
        Kind::Hunks => Answer::Hunks(editor_diff::hunks(engine, &old, &new, request.limit)),
    }
}

/// The words of `steps`, in the layout the module docs give.
pub fn script_words(steps: &[Step]) -> Vec<u8> {
    let mut writer = Writer::with_capacity(1 + 3 * steps.len());
    writer.size(steps.len());
    for step in steps {
        let (kind, first, second) = match *step {
            Step::Retain(count) => (0, count, 0),
            Step::Delete(count) => (1, count, 0),
            Step::Insert { start, count } => (2, start, count),
        };
        writer.word(kind);
        writer.size(first);
        writer.size(second);
    }
    writer.finish()
}

/// The words of `hunks`, in the layout the module docs give.
pub fn hunk_words(hunks: &[ByteHunk]) -> Vec<u8> {
    let mut writer = Writer::with_capacity(1 + 4 * hunks.len());
    writer.size(hunks.len());
    for hunk in hunks {
        writer.size(hunk.old.start);
        writer.size(hunk.old.end);
        writer.size(hunk.new.start);
        writer.size(hunk.new.end);
    }
    writer.finish()
}

/// The id of the diff service as an event's source.
pub const SERVICE: u64 = 5;

/// The process's diff service, over the real engine.
static DIFFS: Diffs<ImaraDiff> = Diffs::new();

/// Whether the thread that runs the process's service loop was started:
/// set once, by the first request.
static STARTED: OnceLock<bool> = OnceLock::new();

/// Starts the thread that runs the process's service loop, if no earlier
/// call has, and returns whether there is one. It never ends: nothing in
/// this crate joins a thread.
fn service_started() -> bool {
    *STARTED.get_or_init(|| {
        thread::Builder::new()
            .name("editor-diffs".into())
            .spawn(|| {
                DIFFS.run(|id| {
                    events::complete(SERVICE, id);
                });
            })
            .is_ok()
    })
}

/// Asks the process's diff service for the diff of what `old` and `new`
/// hold, with the engine asked about at most `limit` lines a side, as the
/// request `id`, and returns whether it was accepted. It returns at once
/// and never blocks. Both snapshots are cloned, which copies none of their
/// text: the handles are still the caller's.
///
/// The completion is one completion event on the completion queue, from
/// the library source [`SERVICE`], whose code is `id`; there is none if the
/// request is cancelled first. The script is then taken with
/// [`editor_ffi_diffs_take`]. A limit no `usize` holds is the largest.
///
/// # Safety
///
/// `old` and `new` are snapshot handles this library handed out and has
/// not taken back.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_diffs_start(
    id: u64,
    old: *const Snapshot,
    new: *const Snapshot,
    limit: u64,
) -> bool {
    // SAFETY: the caller guarantees both point to live snapshots.
    let (old, new) = unsafe { ((*old).text().clone(), (*new).text().clone()) };
    let limit = usize::try_from(limit).unwrap_or(usize::MAX);
    service_started() && DIFFS.start(id, old, new, limit)
}

/// Hands over the script of the diff request `id`, once: fills `out` and
/// returns true, or returns false, with `out` untouched, when the service
/// keeps no script for `id`.
///
/// # Safety
///
/// `out` points to a writable [`RawWords`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_diffs_take(id: u64, out: *mut RawWords) -> bool {
    let Some(steps) = DIFFS.take(id) else {
        return false;
    };
    let raw = RawWords::with_status(0, script_words(&steps));
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
    true
}

/// As [`editor_ffi_diffs_start`], for the hunks of the two texts in place
/// of a script, which are taken with [`editor_ffi_diffs_take_hunks`].
///
/// # Safety
///
/// `old` and `new` are snapshot handles this library handed out and has
/// not taken back.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_diffs_start_hunks(
    id: u64,
    old: *const Snapshot,
    new: *const Snapshot,
    limit: u64,
) -> bool {
    // SAFETY: the caller guarantees both point to live snapshots.
    let (old, new) = unsafe { ((*old).text().clone(), (*new).text().clone()) };
    let limit = usize::try_from(limit).unwrap_or(usize::MAX);
    service_started() && DIFFS.start_hunks(id, old, new, limit)
}

/// Hands over the hunks of the diff request `id`, once: fills `out` and
/// returns true, or returns false, with `out` untouched, when the service
/// keeps no hunks for `id`.
///
/// # Safety
///
/// `out` points to a writable [`RawWords`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_diffs_take_hunks(id: u64, out: *mut RawWords) -> bool {
    let Some(hunks) = DIFFS.take_hunks(id) else {
        return false;
    };
    let raw = RawWords::with_status(0, hunk_words(&hunks));
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
    true
}

/// Asks the process's diff service for the request `id` to be completed
/// once every diff started before this call has been worked, and returns
/// whether it was accepted. It returns at once and never blocks. Its
/// completion is queued from [`SERVICE`] behind those of the diffs it
/// waited for, and it keeps no answer. Cancelling it while it waits
/// withdraws it.
///
/// Returns false, starting nothing, if `id` is in use, or if the operating
/// system refused the service its thread.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_diffs_flush(id: u64) -> bool {
    service_started() && DIFFS.flush(id)
}

/// Cancels the diff request `id`, and returns whether there was anything
/// to cancel. It is safe for an id that is unknown.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_diffs_cancel(id: u64) -> bool {
    DIFFS.cancel(id)
}

/// How many diff requests are waiting or being worked, and how many
/// answers (scripts or hunks) have not yet been taken, together. A readout
/// for tests.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_diffs_pending() -> u64 {
    DIFFS.pending() as u64
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::mpsc;
    use std::time::Duration;

    use editor_diff::fake::Lcs;
    use editor_service::Worker;
    use editor_text::Text;

    use super::*;
    use crate::words::tests::words_of;

    /// How long a test waits for a completion that should come at once:
    /// a guard against a hang, never a result.
    const DEADLINE: Duration = Duration::from_secs(5);

    fn snapshot(text: &str) -> editor_text::Snapshot {
        Text::from(text).snapshot()
    }

    /// Runs the loop of `diffs` on a thread a worker owns, calling
    /// `complete` with each id it completes: the loop is stopped and its
    /// thread joined when the worker is dropped, a panicking test's
    /// included.
    fn serve(diffs: &Arc<Diffs<Lcs>>, complete: impl Fn(u64) + Send + 'static) -> Worker {
        Worker::spawn(
            "editor-diffs-test",
            {
                let diffs = Arc::clone(diffs);
                move || diffs.stop()
            },
            {
                let diffs = Arc::clone(diffs);
                move || diffs.run(complete)
            },
        )
        .expect("the service's thread starts")
    }

    #[test]
    fn requests_are_worked_in_order_and_each_script_is_taken_once() {
        let diffs = Arc::new(Diffs::<Lcs>::new());
        assert!(diffs.start(1, snapshot("a\nb\n"), snapshot("a\nc\n"), 100));
        assert!(diffs.start(2, snapshot("x"), snapshot("x"), 100));
        let (sent, completed) = mpsc::channel();
        let service = serve(&diffs, move |id| {
            sent.send(id).unwrap();
        });
        assert_eq!(completed.recv().unwrap(), 1);
        assert_eq!(completed.recv().unwrap(), 2);
        assert_eq!(
            diffs.take(1),
            Some(editor_diff::script(&mut Lcs, "a\nb\n", "a\nc\n", 100))
        );
        assert_eq!(diffs.take(1), None);
        assert_eq!(diffs.take(2), Some(vec![Step::Retain(1)]));
        assert_eq!(diffs.pending(), 0);
        service.join().unwrap();
    }

    /// The service's thread is held inside the completion of diff 1 while
    /// diff 2 and the flush are started: it is the only completer, so a
    /// flush completed at its call, or ahead of diff 2, is seen every time.
    #[test]
    fn a_flush_is_completed_after_every_diff_started_before_it() {
        let diffs = Arc::new(Diffs::<Lcs>::new());
        let (sent, completed) = mpsc::channel();
        let (release, released) = mpsc::channel::<()>();
        // A guard against a hang: a test that fails while the loop is held
        // here drops its worker first, which joins the loop.
        let service = serve(&diffs, move |id| {
            sent.send(id).unwrap();
            if id == 1 {
                let _ = released.recv_timeout(DEADLINE);
            }
        });
        assert!(diffs.start(1, snapshot("a\n"), snapshot("b\n"), 10));
        assert_eq!(completed.recv_timeout(DEADLINE).unwrap(), 1);
        assert!(diffs.start(2, snapshot("a\n"), snapshot("a\n"), 10));
        assert!(diffs.flush(3));
        // Its id is in use while it waits.
        assert!(!diffs.flush(3));
        assert!(!diffs.start(3, snapshot(""), snapshot(""), 1));

        assert!(completed.try_recv().is_err());
        release.send(()).unwrap();

        assert_eq!(
            [
                completed.recv_timeout(DEADLINE).unwrap(),
                completed.recv_timeout(DEADLINE).unwrap()
            ],
            [2, 3]
        );
        // It keeps no answer.
        assert_eq!(diffs.take(3), None);
        assert_eq!(diffs.take_hunks(3), None);
        assert!(diffs.take(1).is_some());
        assert!(diffs.take(2).is_some());
        assert_eq!(diffs.pending(), 0);
        service.join().unwrap();
    }

    #[test]
    fn a_flush_cancelled_while_it_waits_is_never_completed() {
        let diffs = Diffs::<Lcs>::new();
        assert!(diffs.flush(4));
        assert_eq!(diffs.pending(), 1);
        assert!(diffs.cancel(4));
        assert!(!diffs.cancel(4));
        assert_eq!(diffs.pending(), 0);
    }

    #[test]
    fn the_limit_reaches_the_script() {
        let diffs = Diffs::<Lcs>::new();
        diffs.start(
            1,
            snapshot("h\na\nk\nb\nt\n"),
            snapshot("h\nA\nk\nB\nt\n"),
            2,
        );
        diffs.stop();
        let (id, queued) = diffs.state().requests.take_next().unwrap();
        assert_eq!(id, Some(1));
        let Queued::Work(request) = queued else {
            panic!("a diff came out of the requests as a flush");
        };
        assert_eq!(
            work(&mut Lcs, &request),
            Answer::Script(editor_diff::script(
                &mut Lcs,
                "h\na\nk\nb\nt\n",
                "h\nA\nk\nB\nt\n",
                2
            ))
        );
    }

    #[test]
    fn an_id_in_use_is_refused_and_a_cancelled_request_is_never_worked() {
        let diffs = Diffs::<Lcs>::new();
        assert!(diffs.start(7, snapshot(""), snapshot(""), 1));
        assert!(!diffs.start(7, snapshot(""), snapshot(""), 1));
        assert!(diffs.cancel(7));
        assert!(!diffs.cancel(7));
        assert_eq!(diffs.pending(), 0);
    }

    #[test]
    fn a_kept_script_is_dropped_by_a_cancel() {
        let diffs = Arc::new(Diffs::<Lcs>::new());
        diffs.start(3, snapshot("a"), snapshot("b"), 10);
        let (sent, completed) = mpsc::channel();
        let service = serve(&diffs, move |id| sent.send(id).unwrap());
        assert_eq!(completed.recv().unwrap(), 3);
        assert!(diffs.cancel(3));
        assert_eq!(diffs.take(3), None);
        service.join().unwrap();
    }

    #[test]
    fn a_hunks_request_is_answered_as_words_of_four() {
        let diffs = Arc::new(Diffs::<Lcs>::new());
        assert!(diffs.start_hunks(4, snapshot("a\nb\nc\n"), snapshot("a\nB\nc\nd\n"), 100));
        let (sent, completed) = mpsc::channel();
        let service = serve(&diffs, move |id| sent.send(id).unwrap());
        assert_eq!(completed.recv().unwrap(), 4);
        let found = diffs.take_hunks(4).unwrap();
        assert_eq!(
            found,
            editor_diff::hunks(&mut Lcs, "a\nb\nc\n", "a\nB\nc\nd\n", 100)
        );
        assert_eq!(diffs.take_hunks(4), None);
        assert_eq!(words_of(&hunk_words(&found)), [2, 2, 4, 2, 4, 6, 6, 6, 8]);
        service.join().unwrap();
    }

    #[test]
    fn a_take_of_the_other_kind_takes_nothing() {
        let diffs = Arc::new(Diffs::<Lcs>::new());
        diffs.start_hunks(1, snapshot("a\n"), snapshot("b\n"), 10);
        diffs.start(2, snapshot("a\n"), snapshot("b\n"), 10);
        let (sent, completed) = mpsc::channel();
        let service = serve(&diffs, move |id| sent.send(id).unwrap());
        assert_eq!(completed.recv().unwrap(), 1);
        assert_eq!(completed.recv().unwrap(), 2);
        assert_eq!(diffs.take(1), None);
        assert_eq!(diffs.take_hunks(2), None);
        assert_eq!(diffs.pending(), 2);
        assert!(diffs.take_hunks(1).is_some());
        assert!(diffs.take(2).is_some());
        service.join().unwrap();
    }

    #[test]
    fn cancelling_a_hunks_request_drops_it() {
        let diffs = Diffs::<Lcs>::new();
        assert!(diffs.start_hunks(9, snapshot("a"), snapshot("b"), 1));
        assert!(!diffs.start(9, snapshot("a"), snapshot("b"), 1));
        assert!(diffs.cancel(9));
        assert_eq!(diffs.pending(), 0);
    }

    #[test]
    fn a_script_crosses_as_a_count_and_three_words_a_step() {
        assert_eq!(
            words_of(&script_words(&[
                Step::Retain(4),
                Step::Delete(2),
                Step::Insert { start: 4, count: 3 }
            ])),
            [3, 0, 4, 0, 1, 2, 0, 2, 4, 3]
        );
    }
}
