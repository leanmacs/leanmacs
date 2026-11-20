//! Registering a service, and the port a service reports through.
//!
//! A service is made once, as a `static`, with [`Service::named`]. Its id,
//! the number its completions carry as their source, is taken from a
//! process-wide counter the first time it is asked for ([`Service::id`]),
//! so two crates that never heard of each other cannot pick the same one.
//! The counter starts at [`FIRST_PACKAGE_ID`]: the ids below it are the
//! core's, whose services in `editor-ffi` keep the fixed ids they had (the
//! timers 1, the files 2 and so on), so Lean and the tests see the same
//! sources as before. [`registered`] lists the services that have an id.
//!
//! A service reports that a request has finished through the port
//! [`Completer`], so its logic is tested with no queue: [`RecordingCompleter`]
//! is the published fake, and [`completer_contract`] is what the fake and
//! the real completer, a [`Service`], which posts to the process's
//! completion queue ([`crate::queue::COMPLETION`]), are both held to.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock, PoisonError};

use crate::queue;

/// The first id a [`Service`] is given. The ids from 1 to one less than
/// this are the core's services', fixed in `editor-ffi`.
pub const FIRST_PACKAGE_ID: u64 = 1024;

/// The next id a service is given.
static NEXT: AtomicU64 = AtomicU64::new(FIRST_PACKAGE_ID);

/// The services that have been given an id, in the order they were.
static REGISTERED: Mutex<Vec<(&'static str, u64)>> = Mutex::new(Vec::new());

/// A service of a package's crate, made in a `static` with
/// [`Service::named`].
#[derive(Debug)]
pub struct Service {
    /// The name, for diagnostics and tests.
    name: &'static str,
    /// The id, once it has been asked for.
    id: OnceLock<u64>,
}

impl Service {
    /// The service called `name`. It has no id until one is asked for.
    pub const fn named(name: &'static str) -> Self {
        Self {
            name,
            id: OnceLock::new(),
        }
    }

    /// The service's name.
    pub const fn name(&self) -> &'static str {
        self.name
    }

    /// The service's id: taken from the process-wide counter the first time
    /// it is asked for, from any thread, and the same every time after.
    pub fn id(&self) -> u64 {
        *self.id.get_or_init(|| {
            let id = NEXT.fetch_add(1, Ordering::Relaxed);
            REGISTERED
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push((self.name, id));
            id
        })
    }

    /// Queues the completion of the request `request` on the process's
    /// completion queue, from the library's source with this service's id
    /// ([`queue::complete`]), and returns whether it was accepted: a queue
    /// that has been quit drops it.
    pub fn complete(&self, request: u64) -> bool {
        queue::complete(self.id(), request)
    }
}

/// The real completer: a service reports to the completion queue.
impl Completer for Service {
    fn complete(&self, request: u64) -> bool {
        Self::complete(self, request)
    }
}

/// The services that have been given an id, with their ids, in the order
/// they were given them.
pub fn registered() -> Vec<(&'static str, u64)> {
    REGISTERED
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone()
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
}

impl RecordingCompleter {
    /// A completer that has recorded nothing.
    pub fn new() -> Self {
        Self::default()
    }

    /// The requests reported since the last take, in order, and forgets them.
    pub fn take(&self) -> Vec<u64> {
        std::mem::take(&mut *self.requests.lock().unwrap_or_else(PoisonError::into_inner))
    }
}

impl Completer for RecordingCompleter {
    fn complete(&self, request: u64) -> bool {
        self.requests
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(request);
        true
    }
}

/// Every report is accepted while what it reports to is open.
pub const ACCEPTED: &str = "a report is accepted";
/// Each report is delivered once, in the order made.
pub const ONCE_IN_ORDER: &str = "each report is delivered once, in the order made";
/// A request id crosses whole: 0 and the largest word among them.
pub const WHOLE_IDS: &str = "a request id is delivered whole, 0 and the largest among them";

/// Every property of [`completer_contract`], by name.
pub const PROPERTIES: [&str; 3] = [ACCEPTED, ONCE_IN_ORDER, WHOLE_IDS];

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
    failed
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Barrier;
    use std::thread;

    static FIRST: Service = Service::named("first");
    static SECOND: Service = Service::named("second");

    #[test]
    fn two_services_get_distinct_ids_at_or_above_the_first_package_id() {
        let (first, second) = (FIRST.id(), SECOND.id());
        assert_ne!(first, second);
        assert!(first >= FIRST_PACKAGE_ID && second >= FIRST_PACKAGE_ID);
        assert_eq!(FIRST.id(), first, "the id is the same every time");
    }

    #[test]
    fn eight_threads_asking_first_give_one_id_per_service() {
        static RACED: Service = Service::named("raced");
        let barrier = Barrier::new(8);
        let ids: Vec<u64> = thread::scope(|scope| {
            let handles: Vec<_> = (0..8)
                .map(|_| {
                    scope.spawn(|| {
                        barrier.wait();
                        RACED.id()
                    })
                })
                .collect();
            handles
                .into_iter()
                .map(|handle| handle.join().expect("a thread asks"))
                .collect()
        });
        assert!(ids.iter().all(|&id| id == ids[0]));
        let named: Vec<_> = registered()
            .into_iter()
            .filter(|&(name, _)| name == "raced")
            .collect();
        assert_eq!(named, [("raced", ids[0])], "it is registered once");
    }

    #[test]
    fn registered_names_each_service_with_its_id() {
        static NAMED: Service = Service::named("named");
        let id = NAMED.id();
        assert_eq!(NAMED.name(), "named");
        assert!(registered().contains(&("named", id)));
    }

    #[test]
    fn a_service_with_no_id_asked_for_is_not_registered() {
        static UNASKED: Service = Service::named("unasked");
        assert_eq!(UNASKED.name(), "unasked");
        assert!(registered().iter().all(|&(name, _)| name != "unasked"));
    }

    #[test]
    fn the_recording_completer_records_each_request_once_in_order() {
        let completer = RecordingCompleter::new();
        assert!(completer.complete(4));
        assert!(completer.complete(9));
        assert_eq!(completer.take(), [4, 9]);
        assert_eq!(completer.take(), [] as [u64; 0]);
    }

    #[test]
    fn the_contract_holds_on_the_fake() {
        let completer = RecordingCompleter::new();
        assert_eq!(
            completer_contract(&completer, || completer.take()),
            [] as [&str; 0]
        );
    }

    /// A completer that drops every other report, saying it accepted it.
    struct Dropping(RecordingCompleter, Mutex<bool>);

    impl Completer for Dropping {
        fn complete(&self, request: u64) -> bool {
            let mut skip = self.1.lock().unwrap_or_else(PoisonError::into_inner);
            *skip = !*skip;
            if !*skip {
                self.0.complete(request);
            }
            true
        }
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
        let dropping = Dropping(RecordingCompleter::new(), Mutex::new(false));
        assert!(completer_contract(&dropping, || dropping.0.take()).contains(&ONCE_IN_ORDER));
        assert_eq!(completer_contract(&Refusing, Vec::new), PROPERTIES);
        let truncating = Truncating(RecordingCompleter::new());
        assert_eq!(
            completer_contract(&truncating, || truncating.0.take()),
            [WHOLE_IDS]
        );
    }
}
