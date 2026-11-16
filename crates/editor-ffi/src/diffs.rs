//! The diff service: a line diff of two snapshots, worked on a thread of
//! its own and completed through the completion queue.
//!
//! This is the fifth service behind the completion queue, in the file
//! service's shape (the crate docs, "Services and completions"). A job in
//! Lean asks for the diff of two snapshots with an id: the snapshot a
//! reload's command took of a buffer, and the one the job's load holds.
//! [`Diffs::start`] returns at once; the service's thread works the oldest
//! request with no lock held, keeps the edit script under the request's id
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
//! # The C functions
//!
//! | Function | Does |
//! |---|---|
//! | [`editor_ffi_diffs_start`] | Starts the diff of two snapshot handles under a line limit. False, starting nothing, for an id in use, or when the service has no thread |
//! | [`editor_ffi_diffs_take`] | Fills a [`RawWords`] and returns true, or returns false when the service keeps no script for the id |
//! | [`editor_ffi_diffs_cancel`] | Cancels, and says whether there was anything to cancel |
//! | [`editor_ffi_diffs_pending`] | Requests waiting or being worked, and scripts not taken |

use std::collections::BTreeMap;
use std::marker::PhantomData;
use std::sync::{Condvar, Mutex, MutexGuard, OnceLock, PoisonError};
use std::thread;

use editor_diff::{LineDiff, Step};
use editor_diff_imara::ImaraDiff;

use crate::events;
use crate::files::Requests;
use crate::log::RawWords;
use crate::snapshot::Snapshot;
use crate::words::Writer;

/// What is asked of the diff service.
pub struct Request {
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
    /// The scripts not yet taken, by request id.
    scripts: BTreeMap<u64, Vec<Step>>,
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
                scripts: BTreeMap::new(),
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
        let mut state = self.state();
        let in_use = state.scripts.contains_key(&id)
            || state.working.is_some_and(|(working, _)| working == id);
        let started = !in_use && state.requests.start(id, Request { old, new, limit });
        drop(state);
        self.changed.notify_all();
        started
    }

    /// Hands over the script of the request `id`, once. `None` when the
    /// service keeps none for it.
    pub fn take(&self, id: u64) -> Option<Vec<Step>> {
        self.state().scripts.remove(&id)
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
        state.scripts.remove(&id).is_some()
    }

    /// How many requests are waiting or being worked, and how many scripts
    /// have not been taken, together.
    pub fn pending(&self) -> usize {
        let state = self.state();
        state.requests.pending() + usize::from(state.working.is_some()) + state.scripts.len()
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
            let Some((id, request)) = state.requests.take_next() else {
                state = self
                    .changed
                    .wait(state)
                    .unwrap_or_else(PoisonError::into_inner);
                continue;
            };
            state.working = Some((id, false));
            drop(state);
            let steps = work(&mut E::default(), &request);
            state = self.state();
            let cancelled = state.working.take().is_some_and(|(_, cancelled)| cancelled);
            if cancelled {
                continue;
            }
            state.scripts.insert(id, steps);
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

/// The script of `request`, over `engine`.
fn work(engine: &mut impl LineDiff, request: &Request) -> Vec<Step> {
    editor_diff::script(
        engine,
        &whole(&request.old),
        &whole(&request.new),
        request.limit,
    )
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

/// Cancels the diff request `id`, and returns whether there was anything
/// to cancel. It is safe for an id that is unknown.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_diffs_cancel(id: u64) -> bool {
    DIFFS.cancel(id)
}

/// How many diff requests are waiting or being worked, and how many
/// scripts have not been taken, together. A readout for tests.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_diffs_pending() -> u64 {
    DIFFS.pending() as u64
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::mpsc;

    use editor_diff::fake::Lcs;
    use editor_text::Text;

    use super::*;
    use crate::words::tests::words_of;

    fn snapshot(text: &str) -> editor_text::Snapshot {
        Text::from(text).snapshot()
    }

    #[test]
    fn requests_are_worked_in_order_and_each_script_is_taken_once() {
        let diffs = Arc::new(Diffs::<Lcs>::new());
        assert!(diffs.start(1, snapshot("a\nb\n"), snapshot("a\nc\n"), 100));
        assert!(diffs.start(2, snapshot("x"), snapshot("x"), 100));
        let (sent, completed) = mpsc::channel();
        let service = Arc::clone(&diffs);
        let thread = thread::spawn(move || {
            service.run(move |id| {
                sent.send(id).unwrap();
            });
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
        diffs.stop();
        thread.join().unwrap();
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
        let (id, request) = diffs.state().requests.take_next().unwrap();
        assert_eq!(id, 1);
        assert_eq!(
            work(&mut Lcs, &request),
            editor_diff::script(&mut Lcs, "h\na\nk\nb\nt\n", "h\nA\nk\nB\nt\n", 2)
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
        let service = Arc::clone(&diffs);
        let thread = thread::spawn(move || service.run(move |id| sent.send(id).unwrap()));
        assert_eq!(completed.recv().unwrap(), 3);
        assert!(diffs.cancel(3));
        assert_eq!(diffs.take(3), None);
        diffs.stop();
        thread.join().unwrap();
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
