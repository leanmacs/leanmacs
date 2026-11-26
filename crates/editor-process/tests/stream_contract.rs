//! The stream port's contract (`editor_service::stream::contract`) held
//! against the process service over the process port's fake: the service
//! is the stream source, and each of the contract's scenarios is the
//! fake's script [`stream_contract::scripts`] gives it.
//!
//! The directory is made up: nothing here is a real process or a real
//! file. `editor-process-std`'s `tests/stream_contract.rs` runs the same
//! check on real processes.

use std::path::Path;
use std::time::Duration;

use editor_process::fake::FakeProcesses;
use editor_process::stream_contract::{self, ServiceGround};
use editor_service::stream::contract;
use editor_wait::HangGuard;

/// The made-up directory the contract runs in.
const DIR: &str = "/fake/stream-contract";

/// hang guard: each event the check waits for with it, a completion, a
/// pull's or a write's return or a reader's park, which must come; only a
/// hang reaches the bound, and the property then fails as a hang.
const DEADLINE: HangGuard = HangGuard::on(
    "a completion, a pull's or a write's return or a reader's park",
    Duration::from_secs(5),
);

#[test]
fn the_service_over_the_fake_keeps_the_stream_contract() {
    let fake = FakeProcesses::new();
    for (command, script) in stream_contract::scripts(Path::new(DIR)) {
        fake.script(command, Ok(script));
    }
    let ground = ServiceGround::new(fake.clone(), Path::new(DIR), DEADLINE);

    let failures = contract::check(&ground);
    drop(ground);

    assert_eq!(failures, [""; 0]);
    assert_eq!(
        fake.record().spawned.len(),
        contract::PROPERTIES.len(),
        "a child for each property"
    );
    assert!(fake.record().spawned.iter().all(|&(id, _)| !fake.alive(id)));
}
