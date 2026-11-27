//! A package declared with the wrapper's macro, loaded through the core's
//! load (`editor_package_library::load::load`) on the process's real
//! runtime (`RUNTIME`), as `editor-ffi`'s C function loads a package's
//! library for its glue: the init answers the package's table, its state's
//! service is registered on the process's counter, and its `Runtime` there
//! keeps the completer contract over the process's completion queue, takes
//! a child of the process's stream source over with every lent buffer
//! handed back to the process's ledger, and keeps the wrapper's own stream
//! contract. A runtime too small is refused through the load.
//!
//! The process's stream source is `editor-service`'s `FakeSource`, provided
//! once, behind a test-local gate ([`Observed`]): `FakeSource` never
//! blocks, and panics on a pull with nothing to deliver, which inside the
//! runtime's `child_pull`, a C function, would abort the process. So the
//! gate parks a pull of a child that has nothing stepped (the stream
//! contract's `AwaitsLine` and `Silent`) until the write or the cancel that
//! makes it deliverable or gone, and the contract's parked interleavings
//! are forced through the real runtime's members every time. That the
//! process service parks its own pulls is `editor-service`'s stream
//! contract's to pin, on `editor-process`.
//!
//! An integration test of its own, and one test, because the queues, the
//! service counter, the ledger and the stream source (`stream::provide`,
//! one per process) are process-wide, and the package's state is too. The
//! fakes are leaked, memory only: none starts a thread.

use std::collections::{HashMap, HashSet};
use std::ffi::c_void;
use std::path::Path;
use std::ptr;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use editor_package::fake::FakeRuntime;
use editor_package::stream::contract::{self as stream_contract, Ground, Scenario};
use editor_package::stream::{ChildStreams as _, StreamSource as WrapperSource, contract::UNUSED};
use editor_package::wait::HangGuard;
use editor_package::{Package, REQUIRED, Runtime, Service, completer_contract, package};
use editor_package_library::fake::FakeLibraries;
use editor_package_library::load::{INIT_SYMBOL, LoadRefusal, load};
use editor_package_library::runtime::RUNTIME;
use editor_package_library::runtime::ledger::LEDGER;
use editor_service::FIRST_PACKAGE_ID;
use editor_service::frame::Framing;
use editor_service::queue::COMPLETION;
use editor_service::stream::contract::ROOMY;
use editor_service::stream::fake::{FakeChild, FakeSource};
use editor_service::stream::{self, ChildStreams, InputClosed, Pulled, Refused, StreamSource};

/// hang guard: each event the stream contract waits for over the real
/// runtime (a pull's or a write's return, a reader parked at the gate), and
/// the gate's wait for its write or cancel; only a hang reaches the bound.
const DEADLINE: HangGuard = HangGuard::on(
    "a pull's or a write's return through the runtime, or a reader parked at the gate",
    Duration::from_secs(10),
);

/// The checked package's state: the runtime it was loaded on, and its
/// service.
#[derive(Debug)]
struct Checked {
    /// The runtime the core handed it.
    runtime: Runtime,
    /// Its service, registered as `checked`.
    service: Service,
}

impl Checked {
    /// The package's init.
    fn new(runtime: Runtime) -> Self {
        Self {
            runtime,
            service: runtime.register("checked"),
        }
    }
}

/// The checked package's own table.
#[repr(C)]
#[derive(Debug)]
struct Functions {
    /// Its service's id, or 0 before a load.
    service: extern "C" fn() -> u64,
}

/// [`Functions::service`].
extern "C" fn service() -> u64 {
    PACKAGE.state().map_or(0, |checked| checked.service.id())
}

package! {
    interface 1;

    /// The checked package.
    static PACKAGE: Package<Checked, Functions> = Package::new(Checked::new, Functions { service });
}

/// Locks `mutex`. No lock here is held while other code runs.
fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The gates of [`Observed`]'s children.
#[derive(Debug, Default)]
struct Gates {
    /// The children whose gate is closed.
    closed: HashSet<u64>,
    /// The children whose reader is parked at its gate.
    parked: HashSet<u64>,
}

/// What [`Observed`] and its children share.
#[derive(Debug, Default)]
struct Gated {
    /// The gates.
    gates: Mutex<Gates>,
    /// Signalled at each change: a gate opened, a reader parked.
    changed: Condvar,
}

impl Gated {
    /// Opens the gate of `child`.
    fn open(&self, child: u64) {
        locked(&self.gates).closed.remove(&child);
        self.changed.notify_all();
    }
}

/// The process's stream source: `editor-service`'s `FakeSource`, with a
/// gate in front of each child's pull. A child's gate is open unless the
/// ground closed it; a pull at a closed gate parks until a write or the
/// ground's cancel opens it, so `FakeSource` is never pulled with nothing
/// to deliver.
#[derive(Debug, Default)]
struct Observed {
    /// The fake source.
    fake: FakeSource,
    /// The gates.
    gated: Arc<Gated>,
}

impl Observed {
    /// Waits until the reader of `child` is parked at its gate, and says
    /// whether it is: false only once `guard` has run out first.
    fn wait_parked(&self, child: u64, guard: HangGuard) -> bool {
        let gates = locked(&self.gated.gates);
        let (_gates, parked) =
            editor_package::wait::wait_while(&self.gated.changed, gates, guard, |gates| {
                !gates.parked.contains(&child)
            });
        parked
    }
}

impl StreamSource for Observed {
    fn take_over(&self, child: u64) -> Result<Box<dyn ChildStreams>, Refused> {
        let streams = self.fake.take_over(child)?;
        Ok(Box::new(AtGate {
            child,
            streams,
            gated: Arc::clone(&self.gated),
        }))
    }
}

/// A child of [`Observed`]'s.
struct AtGate {
    /// Its number.
    child: u64,
    /// The fake's child.
    streams: Box<dyn ChildStreams>,
    /// The gates.
    gated: Arc<Gated>,
}

impl ChildStreams for AtGate {
    fn pull(&self) -> Pulled {
        let mut gates = locked(&self.gated.gates);
        if gates.closed.contains(&self.child) {
            gates.parked.insert(self.child);
            self.gated.changed.notify_all();
            let (mut opened, answered) =
                editor_package::wait::wait_while(&self.gated.changed, gates, DEADLINE, |gates| {
                    gates.closed.contains(&self.child)
                });
            opened.parked.remove(&self.child);
            if !answered {
                // Never a panic inside the runtime's C member: the property
                // fails instead.
                return Pulled::Cancelled;
            }
            gates = opened;
        }
        drop(gates);
        self.streams.pull()
    }

    fn write(&self, bytes: Vec<u8>) -> Result<(), InputClosed> {
        let written = self.streams.write(bytes);
        self.gated.open(self.child);
        written
    }
}

/// The wrapper's stream contract's ground over the process's real runtime:
/// its source is the package's `Runtime`, over `RUNTIME`, whose
/// `take_over` reaches [`Observed`] through `editor_service::stream`.
struct RealGround {
    /// The runtime the package was loaded on.
    runtime: Runtime,
    /// The process's stream source.
    observed: &'static Observed,
    /// Each child opened, by its number.
    children: Mutex<HashMap<u64, FakeChild>>,
}

impl Ground for RealGround {
    fn source(&self) -> &dyn WrapperSource {
        &self.runtime
    }

    fn open(&self, scenario: Scenario) -> Option<u64> {
        let fake = &self.observed.fake;
        let lines = |input| fake.child(Framing::Lines, Framing::Lines, ROOMY, input);
        let (child, gated) = match scenario {
            Scenario::TwoLines => {
                let child = lines(false);
                child.out("one\ntwo\n").exit(2);
                (child, false)
            }
            Scenario::OneLine => {
                let child = lines(false);
                child.out("taken\n").exit(0);
                (child, false)
            }
            Scenario::AwaitsLine => {
                let child = lines(true);
                child.on_line("go\n", "go\n").exit(0);
                (child, true)
            }
            Scenario::Silent => (lines(true), true),
        };
        let id = child.id();
        if gated {
            locked(&self.observed.gated.gates).closed.insert(id);
        }
        locked(&self.children).insert(id, child);
        Some(id)
    }

    fn cancel(&self, child: u64) {
        if let Some(fake) = locked(&self.children).get(&child) {
            fake.cancel();
        }
        self.observed.gated.open(child);
    }

    fn wait_pulling(&self, child: u64) -> bool {
        self.observed.wait_parked(child, DEADLINE)
    }

    fn deadline(&self) -> HangGuard {
        DEADLINE
    }
}

/// The path the fake libraries hold the package at.
const PATH: &str = "/checked/libchecked.dylib";

/// The path the fake libraries hold the package at for a runtime too small.
const SMALL_PATH: &str = "/checked/small/libchecked.dylib";

#[test]
fn a_package_declared_with_the_wrapper_loads_through_the_core_s_load_and_runs_on_the_process_s_runtime()
 {
    let observed: &'static Observed = Box::leak(Box::default());
    assert!(stream::provide(observed), "the first source provided");
    let libraries = FakeLibraries::new()
        .library(PATH, &[(INIT_SYMBOL, editor_package_init)])
        .library(SMALL_PATH, &[(INIT_SYMBOL, editor_package_init)]);

    // The load.
    let table = load(&libraries, Path::new(PATH), &RUNTIME).expect("loaded");
    let declared: *const c_void = ptr::from_ref(PACKAGE.table()).cast();
    assert_eq!(table.as_ptr(), declared);

    // The state's service, on the process's counter.
    let checked = PACKAGE.state().expect("the state made by the load");
    let id = checked.service.id();
    assert!(id >= FIRST_PACKAGE_ID);
    assert_eq!((PACKAGE.table().functions().service)(), id);
    assert!(editor_service::registered().contains(&("checked", id)));

    // The completer contract, over the process's completion queue.
    let delivered = || {
        let mut requests = Vec::new();
        while COMPLETION.queued() > 0 {
            let event = COMPLETION.next();
            if event.source.id == id {
                requests.push(event.code);
            }
        }
        requests
    };
    assert_eq!(completer_contract(&checked.service, delivered), [""; 0]);

    // A child of the process's stream source, through the runtime.
    let fake_child = observed
        .fake
        .child(Framing::Lines, Framing::Lines, ROOMY, true);
    fake_child.out("one\n");
    let child = checked
        .runtime
        .take_over(fake_child.id())
        .expect("taken over");
    assert_eq!(
        child.pull(),
        editor_package::stream::Pulled::Delivered(editor_package::stream::Delivery {
            out: editor_package::frame::Frames::Lines(vec![b"one".to_vec()]),
            err: editor_package::frame::Frames::Lines(Vec::new()),
            ended: None,
        })
    );
    assert_eq!(child.write(b"x\n".to_vec()), Ok(()));
    drop(child);
    assert_eq!(
        checked.runtime.take_over(UNUSED).err(),
        Some(editor_package::stream::Refused::NoSuchChild)
    );
    assert_eq!(LEDGER.outstanding(), 0, "every lent buffer handed back");

    // The wrapper's stream contract, over the real runtime.
    let ground = RealGround {
        runtime: checked.runtime,
        observed,
        children: Mutex::new(HashMap::new()),
    };
    assert_eq!(stream_contract::check(&ground), [""; 0]);
    assert_eq!(LEDGER.outstanding(), 0, "every lent buffer handed back");

    // A runtime too small, refused through the load.
    let small = FakeRuntime::new().sized(REQUIRED - 8).leak();
    assert_eq!(
        load(&libraries, Path::new(SMALL_PATH), small.raw()).err(),
        Some(LoadRefusal::RuntimeTooSmall)
    );
}
