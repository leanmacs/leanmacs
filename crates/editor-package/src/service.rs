//! A package's service, registered through the runtime, and the port a
//! service reports through: the same names as `editor-service`'s
//! `service` module ([`Completer`], [`RecordingCompleter`],
//! [`completer_contract`]), so a crate's logic ports by its imports.
//!
//! A [`Service`] is made from the [`Runtime`](crate::Runtime) a package's
//! init is handed ([`crate::Runtime::register`]) and held in the package's
//! state; unlike `editor-service`'s it is not a `static`, and the wrapper
//! keeps no process-wide state of its own. Its id is the runtime's, at or
//! above the first package id; a completion posts through the runtime's
//! `complete` ([`Service::complete`]), an event through its `post_event`
//! ([`Service::post`]).
//!
//! A service's logic is tested over the port with no runtime:
//! [`RecordingCompleter`] is its published fake, and [`completer_contract`]
//! is what the fake and the real completer, a [`Service`] over a runtime,
//! are both held to. A test waits for its own request's report
//! ([`RecordingCompleter::wait_reported`]), never on how many reports
//! there are: `editor-service`'s count wait is not mirrored.

use std::sync::{Condvar, Mutex, PoisonError};

use editor_wait::HangGuard;

use crate::runtime::Calls;

/// A package's service, registered through the runtime: its id and the
/// runtime its completions and events post through. Cheap to copy, and
/// held in the package's state.
#[derive(Debug, Clone, Copy)]
pub struct Service {
    /// The runtime it was registered through.
    calls: Calls,
    /// Its id, the runtime's.
    id: u64,
}

impl Service {
    /// The service the runtime of `calls` registered as `id`.
    pub(crate) const fn registered(calls: Calls, id: u64) -> Self {
        Self { calls, id }
    }

    /// Its id: what its completions and events carry.
    pub const fn id(self) -> u64 {
        self.id
    }

    /// Posts the completion of `request` through the runtime's `complete`,
    /// and answers whether it was accepted: a queue that was quit drops it.
    pub fn complete(self, request: u64) -> bool {
        self.calls.complete(self.id, request)
    }

    /// Posts a message of `code` and `text` through the runtime's
    /// `post_event`, and answers whether it was accepted.
    pub fn post(self, code: u64, text: &str) -> bool {
        self.calls.post(self.id, code, text.as_bytes())
    }
}

/// The real completer: a service reports through the runtime.
impl Completer for Service {
    fn complete(&self, request: u64) -> bool {
        Self::complete(*self, request)
    }
}

/// The port a service reports through: that the request it was asked for
/// has finished.
pub trait Completer: Send + Sync {
    /// Reports that the request `request` has finished, and returns whether
    /// the report was accepted. One that is refused is dropped: the queue
    /// it would go to has been quit.
    fn complete(&self, request: u64) -> bool;
}

impl<C: Completer + ?Sized> Completer for &C {
    fn complete(&self, request: u64) -> bool {
        (**self).complete(request)
    }
}

/// The fake completer: it accepts every report and records it, in order.
#[derive(Debug, Default)]
pub struct RecordingCompleter {
    /// The requests reported and not yet taken.
    requests: Mutex<Vec<u64>>,
    /// Signalled, under the requests' lock, at each report.
    reported: Condvar,
}

impl RecordingCompleter {
    /// A completer that has recorded nothing.
    pub fn new() -> Self {
        Self::default()
    }

    /// The requests reported since the last take, in order, and forgets
    /// them.
    pub fn take(&self) -> Vec<u64> {
        std::mem::take(&mut *self.requests.lock().unwrap_or_else(PoisonError::into_inner))
    }

    /// Waits until the request `request` has been reported, since the last
    /// take, and says whether it was: false only once `guard` has run out
    /// first. The request's own signal: a report made by another request
    /// cannot answer it.
    ///
    /// `guard` names the report: only a report that never comes reaches it.
    pub fn wait_reported(&self, request: u64, guard: HangGuard) -> bool {
        let requests = self.requests.lock().unwrap_or_else(PoisonError::into_inner);
        let (_requests, reported) =
            editor_wait::wait_while(&self.reported, requests, guard, |requests| {
                !requests.contains(&request)
            });
        reported
    }
}

impl Completer for RecordingCompleter {
    fn complete(&self, request: u64) -> bool {
        self.requests
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(request);
        self.reported.notify_all();
        true
    }
}

/// Every report is accepted while what it reports to is open.
pub const ACCEPTED: &str = "a report is accepted";
/// Each report is delivered once, in the order made.
pub const ONCE_IN_ORDER: &str = "each report is delivered once, in the order made";
/// A request id crosses whole: 0 and the largest word among them.
pub const WHOLE_IDS: &str = "a request id is delivered whole, 0 and the largest among them";
/// Each request accepted is reported on its own: delivered before the next
/// is made, so a test waits on its own request's report.
pub const EACH_REPORTED: &str =
    "each request accepted is reported on its own, before the next is made";

/// Every property of [`completer_contract`], by name.
pub const PROPERTIES: [&str; 4] = [ACCEPTED, ONCE_IN_ORDER, WHOLE_IDS, EACH_REPORTED];

/// Holds `completer` to the contract, and returns the names of the
/// properties that fail: none when it keeps them all. `delivered` answers
/// the requests the completer delivered since it was last asked, in the
/// order they arrived, and forgets them.
pub fn completer_contract(
    completer: &impl Completer,
    mut delivered: impl FnMut() -> Vec<u64>,
) -> Vec<&'static str> {
    let _ = delivered();
    let mut failed = Vec::new();
    let requests = [7, 3, 7_000, 3];
    let accepted = requests.iter().all(|&request| completer.complete(request));
    if !accepted {
        failed.push(ACCEPTED);
    }
    if delivered() != requests {
        failed.push(ONCE_IN_ORDER);
    }
    let whole = [0, u64::MAX, 1 << 63];
    let all = whole.iter().all(|&request| completer.complete(request));
    if !all || delivered() != whole {
        failed.push(WHOLE_IDS);
    }
    let each = [5, 6, 5, 8].iter().all(|&request| {
        let accepted = completer.complete(request);
        accepted && delivered() == [request]
    });
    if !each {
        failed.push(EACH_REPORTED);
    }
    failed
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::thread;
    use std::time::Duration;

    use super::*;

    /// hang guard: the report each wait ends on; only a hang reaches the
    /// bound, and the test then fails as a hang.
    const REPORTED: HangGuard = HangGuard::on("a report", Duration::from_secs(10));

    /// A guard run out on purpose: the report waited for is never made.
    const NEVER: HangGuard = HangGuard::held("a report never made", Duration::ZERO);

    #[test]
    fn the_recording_completer_keeps_the_completer_contract() {
        let completer = RecordingCompleter::new();
        assert_eq!(completer_contract(&completer, || completer.take()), [""; 0]);
    }

    /// A completer that refuses every report.
    struct Refusing;

    impl Completer for Refusing {
        fn complete(&self, _: u64) -> bool {
            false
        }
    }

    /// A completer that keeps only the low 32 bits of each request.
    struct Truncating(RecordingCompleter);

    impl Completer for Truncating {
        fn complete(&self, request: u64) -> bool {
            self.0.complete(request & u64::from(u32::MAX))
        }
    }

    #[test]
    fn the_contract_fails_a_completer_that_breaks_it() {
        assert_eq!(completer_contract(&Refusing, Vec::new), PROPERTIES);
        let truncating = Truncating(RecordingCompleter::new());
        assert_eq!(
            completer_contract(&truncating, || truncating.0.take()),
            [WHOLE_IDS]
        );
    }

    #[test]
    fn a_wait_for_a_request_answers_once_that_request_is_reported_on_another_thread() {
        let completer = Arc::new(RecordingCompleter::new());
        assert!(completer.complete(4), "another request's report");
        let reporter = {
            let completer = Arc::clone(&completer);
            thread::spawn(move || completer.complete(9))
        };
        assert!(completer.wait_reported(9, REPORTED));
        assert!(reporter.join().expect("the report's thread"));
        assert!(!completer.wait_reported(8, NEVER), "another request's");
        assert_eq!(completer.take(), [4, 9]);
    }
}
