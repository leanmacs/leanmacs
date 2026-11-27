//! The runtime's contract on the process's real runtime
//! ([`RUNTIME`], `editor_package_library::runtime::contract::check`): the
//! same properties the pure model keeps (`src/runtime/model/tests.rs`),
//! through the same C members a package's library calls, over the
//! process's real completion and editor queues, its service counter and its
//! ledger of lent buffers.
//!
//! The process's stream source is the stream port's published fake,
//! provided once, as `editor-ffi` provides the process service when the
//! library starts. That fake is held to the same stream contract as the
//! real process service (`editor-process`'s `tests/stream_contract.rs`), so
//! a child that keeps the stream contract through this runtime keeps it as
//! the process service frames it; over real processes, the fixture package
//! echo's linked attach checks run this runtime against the core's real
//! process service. The fake is leaked, memory only: it starts no thread.
//!
//! An integration test of its own, and its one test, because the queues,
//! the service counter, the ledger and the stream source are process-wide.

use editor_package_library::runtime::contract::{Rig, check};
use editor_package_library::runtime::ledger::LEDGER;
use editor_package_library::runtime::{PackageRuntime, RUNTIME};
use editor_service::queue::{COMPLETION, EDITOR, Queue};
use editor_service::stream::contract::Ground;
use editor_service::stream::{self, fake::FakeSource};

/// The real runtime, read through the process's statics.
struct RealRig {
    /// The process's stream source, as provided.
    ground: &'static FakeSource,
}

/// The next event on `queue`, as its source's id, its code and its text;
/// none when the queue is idle. It reads only what is queued, so it never
/// parks.
fn next(queue: &Queue) -> Option<(u64, u64, String)> {
    (queue.queued() > 0).then(|| {
        let event = queue.next();
        (event.source.id, event.code, event.text)
    })
}

impl Rig for RealRig {
    fn runtime(&self) -> &'static PackageRuntime {
        &RUNTIME
    }

    fn next_completion(&self) -> Option<(u64, u64)> {
        next(&COMPLETION).map(|(service, request, _)| (service, request))
    }

    fn next_event(&self) -> Option<(u64, u64, String)> {
        next(&EDITOR)
    }

    fn outstanding(&self) -> usize {
        LEDGER.outstanding()
    }

    fn ground(&self) -> &impl Ground {
        self.ground
    }
}

#[test]
fn the_process_s_runtime_keeps_the_runtime_s_contract() {
    let ground: &'static FakeSource = Box::leak(Box::new(FakeSource::new()));
    assert!(stream::provide(ground), "the first source provided");

    assert_eq!(check(&RealRig { ground }), [""; 0]);
    assert_eq!(LEDGER.outstanding(), 0, "every lent buffer handed back");
}
