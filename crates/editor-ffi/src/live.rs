//! The live counts of the handles this library hands out, and the wait for
//! one to come down.
//!
//! Each kind of handle a test counts keeps a `Live`: the count of the
//! handles handed out and not yet freed, which its module adds to in the
//! one place it hands one out and takes from in its free. Its `_live`
//! function reads it ([`crate::counter::editor_ffi_counter_live`],
//! [`crate::document::editor_ffi_document_live`],
//! [`crate::snapshot::editor_ffi_snapshot_live`]).
//!
//! A test whose handle is freed on another thread, as a finaliser frees
//! one, waits for the count to come down with [`editor_ffi_live_await`],
//! a readout for tests: each free signals a waiting test, so the wait ends
//! on the free and never by a poll. A free with no test waiting takes no
//! lock.
//!
//! | `kind` | The handles |
//! |---|---|
//! | 1 ([`SNAPSHOTS`]) | Snapshots |
//! | 2 ([`DOCUMENTS`]) | Documents |
//! | 3 ([`COUNTERS`]) | Counters |
//!
//! Any other kind, 0 among them, names none.

use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Condvar, Mutex, PoisonError};
use std::time::Duration;

use editor_wait::HangGuard;

/// The `kind` of [`editor_ffi_live_await`] that names snapshots.
pub const SNAPSHOTS: u8 = 1;

/// The `kind` of [`editor_ffi_live_await`] that names documents.
pub const DOCUMENTS: u8 = 2;

/// The `kind` of [`editor_ffi_live_await`] that names counters.
pub const COUNTERS: u8 = 3;

/// How many handles of one kind are live, and what a wait for that count
/// to come down waits on.
pub(crate) struct Live {
    /// The handles handed out and not freed.
    count: AtomicU64,
    /// How many waits ([`Live::await_at_most`]) are under way: a free
    /// signals only while one is.
    waits: AtomicUsize,
    /// What a free takes to signal [`Live::freed`], and what a wait reads
    /// the count under.
    lock: Mutex<()>,
    /// Signalled, under [`Live::lock`], at each free while a wait is under
    /// way.
    freed: Condvar,
    /// Called each time [`Live::await_at_most`] reads the count, with the
    /// count, under [`Live::lock`]. Set once, by a test.
    #[cfg(test)]
    read: std::sync::OnceLock<Box<dyn Fn(u64) + Send + Sync>>,
}

impl Live {
    /// No handle live.
    pub(crate) const fn new() -> Self {
        Self {
            count: AtomicU64::new(0),
            waits: AtomicUsize::new(0),
            lock: Mutex::new(()),
            freed: Condvar::new(),
            #[cfg(test)]
            read: std::sync::OnceLock::new(),
        }
    }

    /// Counts a handle handed out.
    pub(crate) fn add(&self) {
        self.count.fetch_add(1, Ordering::Relaxed);
    }

    /// Counts a handle freed, and wakes the waits under way.
    pub(crate) fn free(&self) {
        // The count goes down before the waits are read, and a wait counts
        // itself before it reads the count, so either this sees the wait
        // or the wait sees the count this left.
        self.count.fetch_sub(1, Ordering::SeqCst);
        if self.waits.load(Ordering::SeqCst) > 0 {
            // Under the lock a wait reads the count under, so a wait that
            // read the count before it came down is in its wait by now.
            let _lock = self.lock.lock().unwrap_or_else(PoisonError::into_inner);
            self.freed.notify_all();
        }
    }

    /// How many handles are live.
    pub(crate) fn count(&self) -> u64 {
        self.count.load(Ordering::SeqCst)
    }

    /// Waits until at most `target` handles are live, and says whether
    /// they were: false only once `guard` has run out first.
    ///
    /// `guard` names the free of a handle, which notifies `freed`: only a
    /// handle that is never freed reaches it.
    pub(crate) fn await_at_most(&self, target: u64, guard: HangGuard) -> bool {
        let lock = self.lock.lock().unwrap_or_else(PoisonError::into_inner);
        self.waits.fetch_add(1, Ordering::SeqCst);
        let (lock, freed) = editor_wait::wait_while(&self.freed, lock, guard, |_| {
            let count = self.count();
            #[cfg(test)]
            if let Some(read) = self.read.get() {
                read(count);
            }
            count > target
        });
        self.waits.fetch_sub(1, Ordering::SeqCst);
        drop(lock);
        freed
    }
}

/// The count of the handles of `kind` (the module docs' table).
fn of(kind: u8) -> Option<&'static Live> {
    match kind {
        SNAPSHOTS => Some(&crate::snapshot::LIVE),
        DOCUMENTS => Some(&crate::document::LIVE),
        COUNTERS => Some(&crate::counter::LIVE),
        _ => None,
    }
}

/// Waits until at most `target` handles of `kind` are live (the module
/// docs' table: 1 snapshots, 2 documents, 3 counters), and says whether
/// they were: false once `bound_ms` milliseconds have passed first, and at
/// once for a `kind` that names none. A readout for tests, which use it to
/// know that a handle freed on another thread, as by a finaliser, has been
/// freed: it returns on the free, never by a poll.
///
/// `bound_ms` is a hang guard: only a handle that is never freed reaches
/// it.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_live_await(kind: u8, target: u64, bound_ms: u64) -> bool {
    let guard = HangGuard::on(
        "the free of a handle, under a Lean caller's guard",
        Duration::from_millis(bound_ms),
    );
    of(kind).is_some_and(|live| live.await_at_most(target, guard))
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc::{Receiver, channel};
    use std::sync::{Arc, Mutex, PoisonError};
    use std::thread;
    use std::time::Duration;

    use editor_wait::HangGuard;

    use super::{COUNTERS, DOCUMENTS, Live, SNAPSHOTS, editor_ffi_live_await};

    /// hang guard: the free, or the reading, each wait ends on; only a hang
    /// reaches the bound, and the test then fails as a hang.
    const BOUND: HangGuard = HangGuard::on(
        "the free, or the reading, each wait ends on",
        Duration::from_secs(10),
    );

    /// A guard run out on purpose, at once: the handles not yet freed.
    const NOT_FREED: HangGuard = HangGuard::held("the handles not yet freed", Duration::ZERO);

    /// Where each count [`Live::await_at_most`] reads on `live` arrives.
    fn readings(live: &Live) -> Receiver<u64> {
        let (read, readings) = channel();
        let read = Mutex::new(read);
        let hook = move |count| {
            let _ = read
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .send(count);
        };
        assert!(live.read.set(Box::new(hook)).is_ok(), "set once");
        readings
    }

    #[test]
    fn a_wait_answers_only_once_a_handle_freed_on_another_thread_after_it_began_is_freed() {
        let live = Arc::new(Live::new());
        live.add();
        live.add();
        let readings = readings(&live);
        let waited = {
            let live = Arc::clone(&live);
            thread::spawn(move || live.await_at_most(1, BOUND))
        };
        assert_eq!(
            editor_wait::recv(&readings, BOUND),
            Ok(2),
            "the wait begins with the count above its target"
        );

        let freed = {
            let live = Arc::clone(&live);
            thread::spawn(move || live.free())
        };
        freed.join().expect("the free's thread");

        // A wait that answered at its first reading never reads the free.
        assert_eq!(
            editor_wait::recv(&readings, BOUND),
            Ok(1),
            "the wait reads the count again once the handle is freed"
        );
        assert!(waited.join().expect("the wait's thread"));
        assert_eq!(live.count(), 1);
    }

    #[test]
    fn a_wait_says_no_once_its_bound_has_passed_with_the_count_above_its_target() {
        let live = Live::new();
        live.add();
        assert!(!live.await_at_most(0, NOT_FREED));
        assert!(live.await_at_most(1, NOT_FREED));
        live.free();
        assert!(live.await_at_most(0, NOT_FREED));
    }

    #[test]
    fn a_kind_that_names_no_handles_is_refused_at_once() {
        for kind in [0, COUNTERS + 1, u8::MAX] {
            assert!(!editor_ffi_live_await(kind, u64::MAX, 0), "kind {kind}");
        }
        // Every count is at most the largest there is.
        for kind in [SNAPSHOTS, DOCUMENTS, COUNTERS] {
            assert!(editor_ffi_live_await(kind, u64::MAX, 0), "kind {kind}");
        }
    }
}
