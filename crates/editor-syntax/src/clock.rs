//! How time reaches the crate: a clock of its own, and a manual one.
//!
//! The worker measures how long a text has been quiet on a [`Clock`]
//! ([`crate::worker`], "Idle refreshes"). It is a trait of this crate's,
//! because the crate depends on `editor-text` alone: it cannot depend on
//! `editor-ffi`, where the job clock lives, and depending on another
//! service's crate for a trait would couple two unrelated services.
//! `editor-ffi` implements it for its monotonic clock, so the interval is
//! measured on the job clock.
//!
//! [`ManualClock`] is published, not test-only, as the timer service's fake
//! clock is: tests of this crate and of its users set it and advance it. A
//! worker parked on the old reading does not notice by itself; a test tells
//! it with `Handle::wake`, and then waits for
//! what it expects with a bound. No test sleeps for a fixed time.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

/// A clock in milliseconds.
pub trait Clock: Send + Sync + 'static {
    /// The time, in milliseconds since the clock began. It never goes back.
    fn now_ms(&self) -> u64;
}

impl<C: Clock> Clock for Arc<C> {
    fn now_ms(&self) -> u64 {
        (**self).now_ms()
    }
}

/// A clock that moves only when it is told to. Its clones share one
/// reading.
#[derive(Debug, Clone, Default)]
pub struct ManualClock {
    /// The reading.
    now: Arc<AtomicU64>,
}

impl ManualClock {
    /// A clock that reads 0.
    pub fn new() -> Self {
        Self::default()
    }

    /// Sets the reading to `ms`.
    pub fn set(&self, ms: u64) {
        self.now.store(ms, Ordering::SeqCst);
    }

    /// Moves the reading on by `ms`.
    pub fn advance(&self, ms: u64) {
        self.now.fetch_add(ms, Ordering::SeqCst);
    }
}

impl Clock for ManualClock {
    fn now_ms(&self) -> u64 {
        self.now.load(Ordering::SeqCst)
    }
}

#[cfg(test)]
mod tests {
    use super::{Clock, ManualClock};

    #[test]
    fn a_manual_clock_reads_zero_until_it_is_set_or_advanced() {
        let clock = ManualClock::new();
        assert_eq!(clock.now_ms(), 0);

        clock.set(100);
        assert_eq!(clock.now_ms(), 100);
        clock.advance(250);
        assert_eq!(clock.now_ms(), 350);
    }

    #[test]
    fn a_manual_clocks_clones_share_its_reading() {
        let clock = ManualClock::new();
        let clone = clock.clone();

        clone.advance(5);

        assert_eq!(clock.now_ms(), 5);
        assert_eq!(std::sync::Arc::new(clone).now_ms(), 5);
    }
}
