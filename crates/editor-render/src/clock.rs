//! Time, as a port.
//!
//! The render loop stamps what it is asked to draw and when it drew it, and
//! paces its draws, by a [`Clock`]: nanoseconds since the clock began. This
//! crate has no real clock. For a latency to mean anything the journal must
//! read the clock that stamped the input, which is the window binding's
//! (`editor-ffi`), so the real adapter is written there. Every test here
//! runs on [`FakeClock`].

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

/// The port: tells the time.
pub trait Clock: Send + Sync {
    /// Nanoseconds since the clock began: never less than a reading before
    /// it, and never 0.
    fn now_ns(&self) -> u64;
}

impl<C: Clock + ?Sized> Clock for Arc<C> {
    fn now_ns(&self) -> u64 {
        (**self).now_ns()
    }
}

/// The published fake of [`Clock`]: a time a test sets.
///
/// It begins at 1 nanosecond and stays where it is put. A test moves it
/// ([`FakeClock::set`], [`FakeClock::advance`]), or has it move on by a step
/// at every reading ([`FakeClock::stepping`]), so that no two readings are
/// the same. A clone tells the same time: a test keeps one and hands the
/// other to what it tests.
#[derive(Debug, Clone)]
pub struct FakeClock {
    /// The time and the step, shared by every clone.
    shared: Arc<Shared>,
}

/// What the clones of a [`FakeClock`] share.
#[derive(Debug)]
struct Shared {
    /// The time now, in nanoseconds.
    now: AtomicU64,
    /// How far the time moves on at each reading.
    step: AtomicU64,
}

impl FakeClock {
    /// A clock at 1 nanosecond that stays there.
    pub fn new() -> Self {
        Self::stepping(0)
    }

    /// A clock at 1 nanosecond that moves on by `step` nanoseconds at every
    /// reading, before the reading is given: its first reading is
    /// `1 + step`.
    pub fn stepping(step: u64) -> Self {
        Self {
            shared: Arc::new(Shared {
                now: AtomicU64::new(1),
                step: AtomicU64::new(step),
            }),
        }
    }

    /// Puts the clock at `ns` nanoseconds, or leaves it where it is when
    /// that would move it back or to 0.
    pub fn set(&self, ns: u64) {
        self.shared.now.fetch_max(ns, Ordering::SeqCst);
    }

    /// Moves the clock on by `ns` nanoseconds.
    pub fn advance(&self, ns: u64) {
        self.shared.now.fetch_add(ns, Ordering::SeqCst);
    }

    /// The time, without moving a stepping clock.
    pub fn peek(&self) -> u64 {
        self.shared.now.load(Ordering::SeqCst)
    }
}

impl Default for FakeClock {
    fn default() -> Self {
        Self::new()
    }
}

impl Clock for FakeClock {
    fn now_ns(&self) -> u64 {
        let step = self.shared.step.load(Ordering::SeqCst);
        self.shared.now.fetch_add(step, Ordering::SeqCst) + step
    }
}

#[cfg(test)]
mod tests {
    use super::{Clock, FakeClock};

    #[test]
    fn a_fake_clock_begins_past_zero_and_stays_where_it_is_put() {
        let clock = FakeClock::new();
        assert_eq!(clock.now_ns(), 1);
        assert_eq!(clock.now_ns(), 1);
        clock.set(50);
        assert_eq!(clock.now_ns(), 50);
        clock.advance(25);
        assert_eq!(clock.now_ns(), 75);
    }

    #[test]
    fn a_fake_clock_never_goes_back() {
        let clock = FakeClock::new();
        clock.set(50);
        clock.set(20);
        assert_eq!(clock.now_ns(), 50);
        clock.set(0);
        assert_eq!(clock.now_ns(), 50);
    }

    #[test]
    fn a_stepping_clock_moves_on_at_every_reading() {
        let clock = FakeClock::stepping(10);
        assert_eq!(clock.now_ns(), 11);
        assert_eq!(clock.now_ns(), 21);
        // Looking at it without reading it moves nothing.
        assert_eq!(clock.peek(), 21);
        assert_eq!(clock.peek(), 21);
    }

    #[test]
    fn a_clone_tells_the_same_time() {
        let clock = FakeClock::new();
        let other = clock.clone();
        clock.advance(9);
        assert_eq!(other.now_ns(), 10);
    }
}
