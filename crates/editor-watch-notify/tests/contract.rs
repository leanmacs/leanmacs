//! The port's contract, the service's properties among them, held against
//! the adapter on real files, in a temporary directory the test owns.
//!
//! The directory is deliberately not canonicalized: on macOS the
//! temporary directory is reached through `/var`, a link to `/private/var`,
//! and FSEvents reports the canonical spelling, so every property there
//! shows that a notice names its path as the directory was spelled.

use std::path::Path;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use editor_wait::HangGuard;

use editor_watch::clock::Clock;
use editor_watch::contract::{self, Ground};
use editor_watch_notify::NotifyWatch;

/// hang guard: the notice or completion each wait of the contract ends
/// on; only a hang reaches the bound, and the check then fails as a hang.
/// How long the contract waits for what should happen at once: only an
/// adapter that breaks a rule takes this long.
const DEADLINE: HangGuard = HangGuard::on(
    "the notice or completion each wait of the contract ends on",
    Duration::from_secs(10),
);

/// The real clock: monotonic, beginning the first time it is read. The
/// watch crate has no real clock of its own, and its `clippy.toml` forbids
/// one; this test needs one so that the service's window passes in real
/// time.
#[derive(Debug, Default, Clone)]
struct Monotonic {
    /// When the clock was first read.
    began: std::sync::Arc<OnceLock<Instant>>,
}

impl Clock for Monotonic {
    fn now_ms(&self) -> u64 {
        // real time under test: the service's coalescing window, which
        // passes on this clock.
        let elapsed = self.began.get_or_init(Instant::now).elapsed();
        u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX)
    }
}

/// The ground: `std::fs`, asked directly.
struct System;

impl Ground for System {
    fn write(&self, path: &Path, bytes: &[u8]) {
        std::fs::write(path, bytes).expect("the check's directory is written");
    }

    fn write_times(&self, path: &Path, times: usize) {
        use std::io::Write as _;
        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .create(true)
            .open(path)
            .expect("the check's file is opened");
        for _ in 0..times {
            file.write_all(b"x").expect("the check's file is written");
            file.flush().expect("the check's file is flushed");
        }
    }

    fn make_dir(&self, path: &Path) {
        std::fs::create_dir(path).expect("the check's directory is made");
    }

    fn rename(&self, from: &Path, to: &Path) {
        std::fs::rename(from, to).expect("the check's file is renamed");
    }

    fn remove(&self, path: &Path) {
        std::fs::remove_file(path).expect("the check's file is removed");
    }

    fn link(&self, link: &Path, to: &Path) {
        std::os::unix::fs::symlink(to, link).expect("the check's link is made");
    }

    fn let_pass(&self, _ms: u64) {}

    fn deadline(&self) -> HangGuard {
        DEADLINE
    }
}

#[test]
fn the_adapter_keeps_the_watch_ports_contract_on_real_files_in_a_temporary_directory() {
    let dir = tempfile::tempdir().expect("a temporary directory");

    let failures = contract::check(
        NotifyWatch::system(),
        Monotonic::default(),
        &System,
        dir.path(),
    );

    assert_eq!(failures, [""; 0]);
}
