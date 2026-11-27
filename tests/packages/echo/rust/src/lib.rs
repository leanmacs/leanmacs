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
//! - **A flush is reported behind the work it covers** ([`Echo::flush`]):
//!   once every echo request started before it has been reported or
//!   cancelled. An attached request, whose child may live as long as its
//!   job, is not waited for, as the process service's flush does not wait
//!   for a live streaming child.
//! - **Plain data only.** The reply is taken by the request's id once the
//!   completion has arrived ([`Echo::take`]).
//!
//! The logic is here, over echo's own ports ([`port`]), and tested on
//! hand-written fakes of them. The crate is a library of its own, loaded
//! by the core when the editor starts (docs/design/packages.md, "A library
//! loaded when the editor runs, as built"): its one export is its init,
//! [`ffi::editor_package_init`], which is handed the core's package runtime
//! ([`runtime`]), registers the service `echo` through it, and answers the
//! table of C functions the glue forwards echo's `@[extern]` calls through
//! ([`ffi::EchoTable`]). `tests/init.rs` runs the init and the table over
//! a runtime of test functions, and `tests/later_runtime.rs` over one from
//! a newer core, larger than the one echo was built for.
//!
//! A request may also read a streaming child the core's process service
//! opened, taken over through the runtime ([`attach`], [`Echo::attach`]):
//! its answer is what it read ([`Echo::take_read`]).
//!
//! The crate depends on nothing of the editor's but the runtime's C
//! definitions (`editor-package-runtime`, which has no static): it reaches
//! the core only through the runtime, so it holds no copy of the core's
//! statics.

pub mod attach;
pub mod buffer;
#[cfg(test)]
mod fakes;
pub mod ffi;
pub mod port;
pub mod runtime;
pub mod zlib;

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};

use crate::port::{ChildStreams, Completer};

/// The name echo's service registers under, through the runtime.
pub const SERVICE_NAME: &str = "echo";

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
    /// Whether it reads a child taken over ([`Echo::attach`]), which a
    /// flush does not wait for.
    attached: bool,
    /// Its answer, once it is ready.
    reply: Option<Answer>,
    /// Whether its report has been made: set only once the completer has
    /// taken it, so a flush made between the reply and its report still
    /// waits for it, and is reported behind it.
    reported: bool,
}

/// What a request answers, once it is ready.
#[derive(Debug)]
enum Answer {
    /// A started request's reply ([`Echo::start`]).
    Echoed(Reply),
    /// What an attached request read of its child ([`Echo::attach`]).
    Read(attach::Read),
}

/// What the service holds.
#[derive(Debug, Default)]
struct State {
    /// The requests in use, by id.
    requests: HashMap<u64, Request>,
    /// How many starts there have been.
    starts: u64,
    /// The flushes not yet reported, oldest first: each with the starts of
    /// the echo requests it still waits for.
    flushes: Vec<Flush>,
}

/// A flush not yet reported ([`Echo::flush`]).
#[derive(Debug)]
struct Flush {
    /// The flush's id, reported once it waits for nothing.
    id: u64,
    /// The starts of the requests it waits for, not yet reported or
    /// cancelled.
    waiting: Vec<u64>,
}

impl State {
    /// Takes `start` out of every flush's wait, and takes out and returns
    /// the ids of the flushes that then wait for nothing, oldest first.
    fn settled(&mut self, start: u64) -> Vec<u64> {
        for flush in &mut self.flushes {
            flush.waiting.retain(|&waited| waited != start);
        }
        let (ready, waiting): (Vec<_>, Vec<_>) = self
            .flushes
            .drain(..)
            .partition(|flush| flush.waiting.is_empty());
        self.flushes = waiting;
        ready.into_iter().map(|flush| flush.id).collect()
    }
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
        let text = text.to_owned();
        self.begin(id, false, move || Answer::Echoed(Reply::to(&text)))
    }

    /// Reads the streaming child `streams`, taken over, as the request `id`
    /// ([`attach::consume`]) on a worker of its own, as [`Echo::start`]
    /// does, and returns whether it started: it does not while `id` is in
    /// use, or when the system refuses a thread. The request is reported
    /// once the child has ended or was cancelled; what it read is taken
    /// with [`Echo::take_read`].
    pub fn attach(&self, id: u64, streams: Box<dyn ChildStreams>) -> bool {
        self.begin(id, true, move || Answer::Read(attach::consume(&*streams)))
    }

    /// Reports `id` once every echo request started before this call has
    /// been reported or cancelled, behind their reports: at once when none
    /// is in flight. An attached request is not waited for. It returns at
    /// once, and keeps no reply.
    pub fn flush(&self, id: u64) {
        {
            let mut state = self.shared.state();
            let waiting: Vec<u64> = state
                .requests
                .values()
                .filter(|request| !request.attached && !request.reported)
                .map(|request| request.start)
                .collect();
            if !waiting.is_empty() {
                state.flushes.push(Flush { id, waiting });
                return;
            }
        }
        self.shared.completer.complete(id);
    }

    /// Starts the request `id`, attached or not, whose answer `work` makes
    /// on a worker of its own.
    fn begin(
        &self,
        id: u64,
        attached: bool,
        work: impl FnOnce() -> Answer + Send + 'static,
    ) -> bool {
        let start = {
            let mut state = self.shared.state();
            if state.requests.contains_key(&id) {
                return false;
            }
            state.starts += 1;
            let start = state.starts;
            state.requests.insert(
                id,
                Request {
                    start,
                    attached,
                    reply: None,
                    reported: false,
                },
            );
            start
        };
        let shared = Arc::clone(&self.shared);
        let worker = thread::Builder::new()
            .name("echo".into())
            .spawn(move || shared.finish(id, start, work()));
        let Ok(worker) = worker else {
            self.cancel(id);
            return false;
        };
        let mut workers = self.workers();
        #[expect(
            clippy::disallowed_methods,
            reason = "reaps the workers that have ended, so the list stays short; it never waits and decides nothing a test sees"
        )]
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
    /// made before the cancel may still arrive, and the caller ignores it. A
    /// flush that waited only for it is reported.
    pub fn cancel(&self, id: u64) -> bool {
        let (cancelled, ready) = {
            let mut state = self.shared.state();
            match state.requests.remove(&id) {
                Some(request) => (true, state.settled(request.start)),
                None => (false, Vec::new()),
            }
        };
        for flush in ready {
            self.shared.completer.complete(flush);
        }
        cancelled
    }

    /// The reply to the request `id`, once it is ready, and the request is no
    /// longer in use; `None`, changing nothing, for a request whose reply is
    /// not ready and for an id not in use.
    pub fn take(&self, id: u64) -> Option<Reply> {
        let mut state = self.shared.state();
        let Some(Answer::Echoed(_)) = state.requests.get(&id)?.reply else {
            return None;
        };
        match state.requests.remove(&id)?.reply? {
            Answer::Echoed(reply) => Some(reply),
            Answer::Read(_) => None,
        }
    }

    /// What the attached request `id` read, once it has read to its
    /// child's end, and the request is no longer in use; `None`, changing
    /// nothing, before then and for an id not in use or not attached.
    pub fn take_read(&self, id: u64) -> Option<attach::Read> {
        let mut state = self.shared.state();
        let Some(Answer::Read(_)) = state.requests.get(&id)?.reply else {
            return None;
        };
        match state.requests.remove(&id)?.reply? {
            Answer::Read(read) => Some(read),
            Answer::Echoed(_) => None,
        }
    }
}

impl<C: Completer> Shared<C> {
    /// Holds `reply` as the answer of the request `id` of the start
    /// `start`, and reports it, unless that request was cancelled; then,
    /// once the report is made, marks it reported and reports each flush
    /// that waited only for it, behind it. A flush made between the reply
    /// and its report still waits for it, as the request is not yet
    /// marked reported.
    fn finish(&self, id: u64, start: u64, reply: Answer) {
        {
            let mut state = self.state();
            match state.requests.get_mut(&id) {
                Some(request) if request.start == start => request.reply = Some(reply),
                _ => return,
            }
        }
        self.completer.complete(id);
        let ready = {
            let mut state = self.state();
            if let Some(request) = state.requests.get_mut(&id)
                && request.start == start
            {
                request.reported = true;
            }
            state.settled(start)
        };
        for flush in ready {
            self.completer.complete(flush);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fakes::{RecordingCompleter, ScriptedChild};
    use crate::port::Ended;
    use editor_wait::HangGuard;
    use std::time::Duration;

    /// hang guard: the reports each wait ends on; only a hang reaches the
    /// bound, and the test then fails as a hang. How long a test waits for
    /// something that should happen at once.
    const DEADLINE: HangGuard = HangGuard::on("the service's reports", Duration::from_secs(5));

    /// A service over a recording completer of its own, which lives as long
    /// as the test's process, as the service's workers may.
    fn echo() -> Echo<&'static RecordingCompleter> {
        Echo::new(Box::leak(Box::new(RecordingCompleter::new())))
    }

    /// The requests reported, in the order they were, once each of
    /// `requests` has been, each waited for on its own id
    /// ([`RecordingCompleter::wait_reported`]); panics if one is not by the
    /// deadline.
    fn reported(echo: &Echo<&'static RecordingCompleter>, requests: &[u64]) -> Vec<u64> {
        let completer = echo.shared.completer;
        for &request in requests {
            assert!(
                completer.wait_reported(request, DEADLINE),
                "{request} was not reported: {DEADLINE}"
            );
        }
        completer.take()
    }

    #[test]
    fn a_started_request_completes_and_its_take_answers_its_text() {
        let echo = echo();
        assert!(echo.start(3, "123456789"));
        assert_eq!(reported(&echo, &[3]), [3]);
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
        reported(&echo, &[3]);
        assert_eq!(echo.take(3), Some(Reply::to("once")));
        assert_eq!(echo.take(3), None);
    }

    #[test]
    fn text_that_is_not_ascii_crosses_intact() {
        let echo = echo();
        let text = "héllo, wörld: 日本語 \u{1F600}\0";
        assert!(echo.start(1, text));
        reported(&echo, &[1]);
        assert_eq!(echo.take(1), Some(Reply::to(text)));
    }

    #[test]
    fn an_id_is_in_use_from_its_start_until_it_is_taken_or_cancelled() {
        let echo = echo();
        assert!(echo.start(5, "first"));
        assert!(!echo.start(5, "second"), "a second start is refused");
        reported(&echo, &[5]);
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
                attached: false,
                reply: None,
                reported: false,
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
                attached: false,
                reply: None,
                reported: false,
            },
        );
        echo.shared.finish(2, 1, Answer::Echoed(Reply::to("stale")));
        assert_eq!(echo.take(2), None);
    }

    #[test]
    fn an_attached_request_reads_its_child_on_a_worker_and_is_taken_once_as_a_read() {
        let echo = echo();
        let child = ScriptedChild::new(false).delivers(&["one"], Some(Ended::Exited { code: 0 }));

        assert!(echo.attach(6, Box::new(child)));
        assert_eq!(reported(&echo, &[6]), [6]);

        assert_eq!(echo.take(6), None, "not a reply");
        let read = echo.take_read(6).expect("a read");
        assert_eq!(read.text(), "one\n<exited 0>");
        assert_eq!(echo.take_read(6), None, "taken once");
        assert!(echo.start(6, "free again"));
    }

    #[test]
    fn a_flush_with_nothing_in_flight_is_reported_at_once() {
        let echo = echo();
        echo.flush(20);
        assert_eq!(echo.shared.completer.take(), [20]);
    }

    #[test]
    fn a_flush_is_reported_after_every_earlier_echo_request_and_an_attached_request_does_not_hold_it()
     {
        let echo = echo();
        // A request still being worked, and an attached one, whose child
        // lives: they are inserted as `begin` leaves them, so nothing
        // finishes them until the test does.
        {
            let mut state = echo.shared.state();
            state.requests.insert(
                8,
                Request {
                    start: 1,
                    attached: false,
                    reply: None,
                    reported: false,
                },
            );
            state.requests.insert(
                9,
                Request {
                    start: 2,
                    attached: true,
                    reply: None,
                    reported: false,
                },
            );
            state.starts = 2;
        }
        echo.flush(20);
        assert!(
            echo.shared.completer.take().is_empty(),
            "the flush is held by the request still worked"
        );
        echo.shared.finish(8, 1, Answer::Echoed(Reply::to("late")));
        assert_eq!(
            echo.shared.completer.take(),
            [8, 20],
            "the flush is reported after the request it covers"
        );
    }

    #[test]
    fn a_flush_made_while_a_request_s_report_is_held_is_reported_behind_it() {
        use editor_wait::recv;
        use std::sync::mpsc::{Receiver, Sender, channel};

        /// A recording completer whose first report of `held` is held: it
        /// says it is reporting, and records the report only once the test
        /// lets it, so the test flushes after the worker has worked the
        /// reply and before its report lands, every run.
        struct Gated {
            completer: RecordingCompleter,
            held: u64,
            reporting: Mutex<Option<Sender<()>>>,
            release: Mutex<Receiver<()>>,
        }

        impl Completer for Gated {
            fn complete(&self, request: u64) -> bool {
                if request == self.held
                    && let Some(reporting) = self.reporting.lock().expect("unpoisoned").take()
                {
                    reporting.send(()).expect("the test waits for the report");
                    let release = self.release.lock().expect("unpoisoned");
                    recv(&release, DEADLINE).expect("the test lets the report go");
                }
                self.completer.complete(request)
            }
        }

        let (reporting, reported) = channel();
        let (release, released) = channel();
        let gated: &'static Gated = Box::leak(Box::new(Gated {
            completer: RecordingCompleter::new(),
            held: 8,
            reporting: Mutex::new(Some(reporting)),
            release: Mutex::new(released),
        }));
        let echo = Echo::new(gated);

        assert!(echo.start(8, "held"));
        recv(&reported, DEADLINE).expect("the worker reports");
        // The reply is worked and its report not yet made: the flush covers
        // the request all the same.
        echo.flush(20);
        release.send(()).expect("the worker is held in its report");
        echo.join_workers();

        assert_eq!(
            gated.completer.take(),
            [8, 20],
            "the flush is reported after the request it covers"
        );
    }

    #[test]
    fn a_flush_held_by_a_request_is_reported_once_that_request_is_cancelled() {
        let echo = echo();
        echo.shared.state().requests.insert(
            8,
            Request {
                start: 1,
                attached: false,
                reply: None,
                reported: false,
            },
        );
        echo.flush(20);
        assert!(echo.shared.completer.take().is_empty());
        assert!(echo.cancel(8));
        assert_eq!(echo.shared.completer.take(), [20]);
    }

    #[test]
    fn an_attached_request_cancelled_while_its_consumer_is_blocked_in_a_pull_gets_no_completion_once_its_child_is_cancelled()
     {
        use crate::port::{InputClosed, Pulled};
        use editor_wait::recv;
        use std::sync::mpsc::{Receiver, Sender, channel};

        /// The fake's streams, with the consumer's first pull held: it says
        /// it is pulling, and goes on only once the test lets it, so the
        /// test acts while the consumer is blocked in its pull, every run.
        struct Held {
            streams: Box<dyn ChildStreams>,
            pulling: Mutex<Option<Sender<()>>>,
            release: Mutex<Receiver<()>>,
        }

        impl ChildStreams for Held {
            fn pull(&self) -> Pulled {
                if let Some(pulling) = self.pulling.lock().expect("unpoisoned").take() {
                    pulling.send(()).expect("the test waits for the pull");
                    let release = self.release.lock().expect("unpoisoned");
                    recv(&release, DEADLINE).expect("the test lets the pull go");
                }
                self.streams.pull()
            }

            fn write(&self, bytes: Vec<u8>) -> Result<(), InputClosed> {
                self.streams.write(bytes)
            }
        }

        let echo = echo();
        // A child with nothing scripted: once let go, its pull answers
        // cancelled, as the process service's does for a child cancelled
        // while its consumer was blocked in a pull.
        let streams: Box<dyn ChildStreams> = Box::new(ScriptedChild::new(false));
        let (pulling, pulled) = channel();
        let (release, released) = channel();
        let held = Held {
            streams,
            pulling: Mutex::new(Some(pulling)),
            release: Mutex::new(released),
        };

        assert!(echo.attach(6, Box::new(held)));
        recv(&pulled, DEADLINE).expect("the consumer pulls");
        // The job's cancel: its wait withdrawn first, then its child ended.
        assert!(echo.cancel(6));
        release.send(()).expect("the consumer is held in its pull");
        echo.join_workers();

        assert!(
            echo.shared.completer.take().is_empty(),
            "a request cancelled first is reported to nobody"
        );
        assert!(
            echo.shared.state().requests.is_empty(),
            "and the service keeps nothing of it"
        );
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
        let mut ids = reported(&echo, &(0..16).collect::<Vec<_>>());
        ids.sort_unstable();
        assert_eq!(ids, (0..16).collect::<Vec<_>>());
        for id in 0..16 {
            assert_eq!(echo.take(id), Some(Reply::to(&format!("request {id}"))));
        }
    }
}
