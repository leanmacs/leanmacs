//! The service of the fixture package `echo`: it answers each request with
//! the request's text and the text's CRC-32, which it takes from the
//! system's zlib ([`zlib`]), worked on a thread of its own, and reports that the
//! request has finished through the [`Completer`] port.
//!
//! It keeps the rules every service keeps (`editor-ffi`'s crate docs,
//! "Services and completions"):
//!
//! - **The caller names the request.** [`Echo::start`] takes an id the
//!   caller chose, returns at once, and refuses an id already in use.
//! - **One completion for each request.** When its reply is ready, the
//!   service reports the request once through its completer. A request
//!   cancelled first gets none.
//! - **`cancel` stops the work** and is safe for an id that is unknown.
//! - **Plain data only.** The reply is taken by the request's id once the
//!   completion has arrived ([`Echo::take`]).
//!
//! The logic is here, over the port, and tested on `editor-service`'s
//! fake, [`editor_service::RecordingCompleter`]. The process's instance,
//! over the real completer, the service [`SERVICE`], and the C functions
//! Lean's glue calls are in [`ffi`], and `tests/wiring.rs` runs them over
//! the process's completion queue.

pub mod ffi;
pub mod zlib;

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};

use editor_service::{Completer, Service};

/// The service, as the completion queue names it.
pub static SERVICE: Service = Service::named("echo");

/// What a request answers: its text, back, and the text's checksum.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reply {
    /// The request's text.
    pub text: String,
    /// The CRC-32 of the text's UTF-8 bytes, from the system's zlib
    /// ([`zlib::checksum`]).
    pub checksum: u32,
}

impl Reply {
    /// The reply to a request of `text`.
    pub fn to(text: &str) -> Self {
        Self {
            text: text.to_owned(),
            checksum: zlib::checksum(text.as_bytes()),
        }
    }
}

/// A request in use: started and not yet taken or cancelled.
#[derive(Debug)]
struct Request {
    /// Which start of the id this is, so a reply worked for a request that
    /// was cancelled cannot fill a later one with the same id.
    start: u64,
    /// The reply, once it is ready.
    reply: Option<Reply>,
}

/// What the service holds.
#[derive(Debug, Default)]
struct State {
    /// The requests in use, by id.
    requests: HashMap<u64, Request>,
    /// How many starts there have been.
    starts: u64,
}

/// The echo service, reporting through `C`.
pub struct Echo<C> {
    /// What the service and its workers share.
    shared: Arc<Shared<C>>,
    /// The workers started and not yet joined: one that has ended is
    /// joined at the next start, so no worker is left detached.
    workers: Mutex<Vec<JoinHandle<()>>>,
}

/// What [`Echo`] and its workers share.
struct Shared<C> {
    /// What reports that a request has finished.
    completer: C,
    /// The requests.
    state: Mutex<State>,
}

impl<C> Shared<C> {
    /// Locks the state. The lock is never held while other code runs, so a
    /// poisoned lock still guards a consistent state.
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl<C: Completer + 'static> Echo<C> {
    /// A service that reports through `completer`, with no request.
    pub fn new(completer: C) -> Self {
        Self {
            shared: Arc::new(Shared {
                completer,
                state: Mutex::new(State::default()),
            }),
            workers: Mutex::new(Vec::new()),
        }
    }

    /// The workers, locked. A poisoned lock still guards a list of handles.
    fn workers(&self) -> MutexGuard<'_, Vec<JoinHandle<()>>> {
        self.workers.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Starts the request `id` of `text`, and returns whether it started: it
    /// does not while `id` is in use, from its start until it is taken or
    /// cancelled, or when the system refuses a thread. It returns at once:
    /// the reply is worked on a thread of its own.
    pub fn start(&self, id: u64, text: &str) -> bool {
        let start = {
            let mut state = self.shared.state();
            if state.requests.contains_key(&id) {
                return false;
            }
            state.starts += 1;
            let start = state.starts;
            state.requests.insert(id, Request { start, reply: None });
            start
        };
        let shared = Arc::clone(&self.shared);
        let text = text.to_owned();
        let worker = thread::Builder::new()
            .name("echo".into())
            .spawn(move || shared.finish(id, start, Reply::to(&text)));
        let Ok(worker) = worker else {
            self.shared.state().requests.remove(&id);
            return false;
        };
        let mut workers = self.workers();
        let (ended, running): (Vec<_>, Vec<_>) =
            workers.drain(..).partition(JoinHandle::is_finished);
        for ended in ended {
            let _ = ended.join();
        }
        *workers = running;
        workers.push(worker);
        true
    }

    /// Joins every worker started so far: once it returns, each request
    /// started has been worked, and reported unless it was cancelled
    /// first. For tests, which use it to know a worker is done.
    #[cfg(test)]
    fn join_workers(&self) {
        let workers = std::mem::take(&mut *self.workers());
        for worker in workers {
            worker.join().expect("an echo worker");
        }
    }

    /// Cancels the request `id`, and returns whether it was in use. Its reply
    /// is dropped, and it is reported to nobody if it was not yet; a report
    /// made before the cancel may still arrive, and the caller ignores it.
    pub fn cancel(&self, id: u64) -> bool {
        self.shared.state().requests.remove(&id).is_some()
    }

    /// The reply to the request `id`, once it is ready, and the request is no
    /// longer in use; `None`, changing nothing, for a request whose reply is
    /// not ready and for an id not in use.
    pub fn take(&self, id: u64) -> Option<Reply> {
        let mut state = self.shared.state();
        state.requests.get(&id)?.reply.as_ref()?;
        state.requests.remove(&id).and_then(|request| request.reply)
    }
}

impl<C: Completer> Shared<C> {
    /// Holds `reply` as the reply of the request `id` of the start `start`,
    /// and reports it, unless that request was cancelled.
    fn finish(&self, id: u64, start: u64, reply: Reply) {
        {
            let mut state = self.state();
            match state.requests.get_mut(&id) {
                Some(request) if request.start == start => request.reply = Some(reply),
                _ => return,
            }
        }
        self.completer.complete(id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use editor_service::RecordingCompleter;
    use std::time::Duration;

    /// hang guard: the reports each wait ends on; only a hang reaches the
    /// bound, and the test then fails as a hang. How long a test waits for
    /// something that should happen at once.
    const DEADLINE: Duration = Duration::from_secs(5);

    /// A service over a recording completer of its own, which lives as long
    /// as the test's process, as the service's workers may.
    fn echo() -> Echo<&'static RecordingCompleter> {
        Echo::new(Box::leak(Box::new(RecordingCompleter::new())))
    }

    /// The requests reported, once `count` of them have been, in the order
    /// they were, waited for on each report
    /// ([`RecordingCompleter::wait_for`]); panics if they are not by the
    /// deadline.
    fn reported(echo: &Echo<&'static RecordingCompleter>, count: usize) -> Vec<u64> {
        let completer = echo.shared.completer;
        assert!(
            completer.wait_for(count, DEADLINE),
            "fewer than {count} were reported after {DEADLINE:?}"
        );
        completer.take()
    }

    #[test]
    fn a_started_request_completes_and_its_take_answers_its_text() {
        let echo = echo();
        assert!(echo.start(3, "123456789"));
        assert_eq!(reported(&echo, 1), [3]);
        let reply = echo.take(3).expect("a reply");
        assert_eq!(
            (reply.text.as_str(), reply.checksum),
            ("123456789", 0xCBF4_3926)
        );
    }

    #[test]
    fn a_take_answers_once() {
        let echo = echo();
        assert!(echo.start(3, "once"));
        reported(&echo, 1);
        assert_eq!(echo.take(3), Some(Reply::to("once")));
        assert_eq!(echo.take(3), None);
    }

    #[test]
    fn text_that_is_not_ascii_crosses_intact() {
        let echo = echo();
        let text = "héllo, wörld: 日本語 \u{1F600}\0";
        assert!(echo.start(1, text));
        reported(&echo, 1);
        assert_eq!(echo.take(1), Some(Reply::to(text)));
    }

    #[test]
    fn an_id_is_in_use_from_its_start_until_it_is_taken_or_cancelled() {
        let echo = echo();
        assert!(echo.start(5, "first"));
        assert!(!echo.start(5, "second"), "a second start is refused");
        reported(&echo, 1);
        assert!(!echo.start(5, "third"), "a reply not taken holds the id");
        assert_eq!(echo.take(5), Some(Reply::to("first")));
        assert!(echo.start(5, "fourth"), "a taken id is free");
        assert!(echo.cancel(5));
        assert!(echo.start(5, "fifth"), "a cancelled id is free");
    }

    #[test]
    fn a_take_before_the_reply_is_ready_answers_none_and_keeps_the_request() {
        let echo = echo();
        echo.shared.state().requests.insert(
            8,
            Request {
                start: 0,
                reply: None,
            },
        );
        assert_eq!(echo.take(8), None);
        assert!(!echo.start(8, "again"), "the request is still in use");
    }

    #[test]
    fn a_cancelled_request_answers_none_and_its_reply_fills_nothing() {
        let echo = echo();
        assert!(echo.start(2, "late"));
        assert!(echo.cancel(2));
        assert_eq!(echo.take(2), None);
        // Once its worker has worked the reply, the reply is held for
        // nobody.
        echo.join_workers();
        assert_eq!(echo.take(2), None);
        // A reply worked for the cancelled start cannot fill a later one.
        echo.shared.state().requests.insert(
            2,
            Request {
                start: 99,
                reply: None,
            },
        );
        echo.shared.finish(2, 1, Reply::to("stale"));
        assert_eq!(echo.take(2), None);
    }

    #[test]
    fn cancel_and_take_of_an_unknown_id_are_safe_and_answer_none() {
        let echo = echo();
        assert!(!echo.cancel(404));
        assert_eq!(echo.take(404), None);
    }

    #[test]
    fn sixteen_requests_in_flight_each_take_their_own_text() {
        let echo = echo();
        for id in 0..16 {
            assert!(echo.start(id, &format!("request {id}")));
        }
        let mut ids = reported(&echo, 16);
        ids.sort_unstable();
        assert_eq!(ids, (0..16).collect::<Vec<_>>());
        for id in 0..16 {
            assert_eq!(echo.take(id), Some(Reply::to(&format!("request {id}"))));
        }
    }
}
