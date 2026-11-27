//! The runtime's contract (`editor_package_library::runtime::contract`),
//! which the core's pure model and the process's real runtime keep, on the
//! package wrapper's fake (`editor_package::fake::FakeRuntime`): through
//! the same C members a package's library calls, as the current runtime and
//! as a later, larger one.
//!
//! The contract's ground is the stream port's fake, `editor-service`'s
//! `FakeSource`. The wrapper's fake takes its children from a wrapper
//! `StreamSource`, so a test-local adapter ([`Adapted`]) stands between
//! them, converting each value to the wrapper's mirror; so
//! [`CHILD_FRAMED`](editor_package_library::runtime::contract::CHILD_FRAMED)
//! runs the whole stream contract through the fake's members and the
//! wrapper's encoder, read back by the core's decoder. The fakes are
//! leaked, memory only: neither starts a thread.

mod support;

use editor_package::fake::FakeRuntime;
use editor_package::stream as wrapper;
use editor_package_library::runtime::PackageRuntime;
use editor_package_library::runtime::contract::{Rig, check};
use editor_service::stream::contract::Ground;
use editor_service::stream::fake::FakeSource;
use editor_service::stream::{ChildStreams, InputClosed, Refused, StreamSource};

/// `refused`, as the wrapper's. It matches every variant on purpose: a new
/// refusal must be mirrored in the wrapper.
const fn refused(refused: Refused) -> wrapper::Refused {
    match refused {
        Refused::NoService => wrapper::Refused::NoService,
        Refused::NoSuchChild => wrapper::Refused::NoSuchChild,
        Refused::ReadPending => wrapper::Refused::ReadPending,
        Refused::Taken => wrapper::Refused::Taken,
    }
}

/// `editor-service`'s fake source, as a source of the wrapper's.
struct Adapted(&'static FakeSource);

/// A child of [`Adapted`]'s.
struct AdaptedChild(Box<dyn ChildStreams>);

impl wrapper::StreamSource for Adapted {
    fn take_over(&self, child: u64) -> Result<Box<dyn wrapper::ChildStreams>, wrapper::Refused> {
        StreamSource::take_over(self.0, child)
            .map(|streams| Box::new(AdaptedChild(streams)) as Box<dyn wrapper::ChildStreams>)
            .map_err(refused)
    }
}

impl wrapper::ChildStreams for AdaptedChild {
    fn pull(&self) -> wrapper::Pulled {
        support::pulled(self.0.pull())
    }

    fn write(&self, bytes: Vec<u8>) -> Result<(), wrapper::InputClosed> {
        self.0
            .write(bytes)
            .map_err(|InputClosed(words)| wrapper::InputClosed(words))
    }
}

/// The wrapper's fake, as the contract's rig.
struct FakeRig {
    /// The fake.
    fake: &'static FakeRuntime,
    /// The ground its children come from, through [`Adapted`].
    ground: &'static FakeSource,
}

impl FakeRig {
    /// A rig over a fake of the current runtime, or a later one if `later`.
    fn new(later: bool) -> Self {
        let ground: &'static FakeSource = Box::leak(Box::new(FakeSource::new()));
        let fake = FakeRuntime::over(Box::leak(Box::new(Adapted(ground))));
        let fake = if later { fake.later() } else { fake };
        Self {
            fake: fake.leak(),
            ground,
        }
    }
}

impl Rig for FakeRig {
    fn runtime(&self) -> &'static PackageRuntime {
        self.fake.raw()
    }

    fn next_completion(&self) -> Option<(u64, u64)> {
        self.fake.next_completion()
    }

    fn next_event(&self) -> Option<(u64, u64, String)> {
        self.fake.next_event()
    }

    fn outstanding(&self) -> usize {
        self.fake.outstanding()
    }

    fn ground(&self) -> &impl Ground {
        self.ground
    }
}

#[test]
fn the_package_wrapper_s_fake_keeps_the_runtime_s_contract() {
    let rig = FakeRig::new(false);
    assert_eq!(check(&rig), [""; 0]);
    assert_eq!(rig.fake.outstanding(), 0, "every lent buffer handed back");
}

#[test]
fn a_later_package_wrapper_fake_keeps_the_runtime_s_contract() {
    let rig = FakeRig::new(true);
    assert!(rig.fake.raw().size > size_of::<PackageRuntime>());
    assert_eq!(check(&rig), [""; 0]);
}
