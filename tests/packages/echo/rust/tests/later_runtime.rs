//! echo's library, built for today's package runtime, on a runtime from a
//! newer core: the wrapper's fake embedded in a larger struct, with a
//! member past today's, whose `size` says so
//! (`editor_package::fake::FakeRuntime::later`). The init loads, registers
//! its service once, and a request started through the table completes
//! through that runtime: a library runs on any runtime at least as large as
//! the one it was built for (the runtime's append-only rule).
//!
//! An integration test of its own, and one test, because the library's
//! state is process-wide: once loaded, it stays loaded.

#![deny(unsafe_code)]

use std::mem::size_of;
use std::time::Duration;

use echo_service::ffi::{PACKAGE, editor_package_init};
use editor_package::buffer::Bytes;
use editor_package::fake::FakeRuntime;
use editor_package::raw::{INIT_LOADED, PackageRuntime};
use editor_package::wait::HangGuard;

/// hang guard: the completion the wait ends on, posted from echo's worker.
const COMPLETION: HangGuard = HangGuard::on("the request's completion", Duration::from_secs(10));

#[test]
fn echo_built_for_today_s_runtime_runs_on_a_larger_one() {
    let fake = FakeRuntime::new().later().leak();
    assert!(fake.raw().size > size_of::<PackageRuntime>());

    let (status, table) = fake.init(editor_package_init);

    assert_eq!(status, INIT_LOADED);
    assert!(!table.is_null());
    let services = fake.services();
    assert_eq!(services.len(), 1, "registered once");
    assert!((PACKAGE.table().functions().start)(
        41,
        Bytes::of("héllo".as_bytes())
    ));
    assert!(
        fake.wait_completed(services[0].1, 41, COMPLETION),
        "{COMPLETION}"
    );
}
