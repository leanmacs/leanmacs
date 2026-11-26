//! The stream port's contract (`editor_service::stream::contract`) held
//! against the process service over the `std::process` adapter, on real
//! processes: the same check the port's fake and the service over the
//! process port's fake pass. Each of the contract's scenarios is the
//! `/bin/sh -c` script `editor_process::stream_contract::scripts` gives,
//! run in a temporary directory this test makes, which is removed when the
//! test ends. The ground shuts the service down when it is dropped, so no
//! child outlives the test.

use std::fs;
use std::time::Duration;

use editor_process::stream_contract::ServiceGround;
use editor_process_std::StdProcesses;
use editor_service::stream::contract;
use editor_wait::HangGuard;

/// hang guard: each event the check waits for with it, a completion, a
/// pull's or a write's return or a reader's park, which must come; only a
/// hang reaches the bound, and the property then fails as a hang.
const DEADLINE: HangGuard = HangGuard::on(
    "a completion, a pull's or a write's return or a reader's park",
    Duration::from_secs(10),
);

#[test]
#[expect(
    clippy::disallowed_methods,
    reason = "the stream contract over the process service on real processes, its children run in a temporary directory the test owns"
)]
fn the_service_over_real_processes_keeps_the_stream_contract() {
    let directory = tempfile::tempdir().expect("a temporary directory can be made");
    let root = fs::canonicalize(directory.path()).expect("the directory's own path resolves");
    let ground = ServiceGround::new(StdProcesses::system(), &root, DEADLINE);

    let failures = contract::check(&ground);
    drop(ground);

    assert_eq!(failures, [""; 0]);
}
