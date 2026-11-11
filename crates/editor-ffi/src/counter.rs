//! A counter: the example of a Rust object that Lean holds by a handle.

use std::sync::atomic::{AtomicU64, Ordering};

/// A number that only goes up. Lean shares a handle between threads, so
/// every method takes `&self` and the type is `Send + Sync`.
pub struct Counter {
    /// The last value handed out, or the start value.
    value: AtomicU64,
}

impl Counter {
    /// A counter whose first [`increment`](Self::increment) returns
    /// `start + 1`.
    pub const fn new(start: u64) -> Self {
        Self {
            value: AtomicU64::new(start),
        }
    }

    /// Adds one and returns the new value, wrapping on overflow.
    pub fn increment(&self) -> u64 {
        self.value.fetch_add(1, Ordering::Relaxed).wrapping_add(1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    #[test]
    fn a_counter_counts_up_from_its_start_value() {
        let counter = Counter::new(40);

        assert_eq!(counter.increment(), 41);
        assert_eq!(counter.increment(), 42);
    }

    #[test]
    fn a_counter_counts_every_increment_made_from_several_threads() {
        const THREADS: u64 = 4;
        const INCREMENTS: u64 = 250;
        let counter = Counter::new(0);

        thread::scope(|scope| {
            for _ in 0..THREADS {
                scope.spawn(|| {
                    for _ in 0..INCREMENTS {
                        counter.increment();
                    }
                });
            }
        });

        assert_eq!(counter.increment(), THREADS * INCREMENTS + 1);
    }

    #[test]
    fn a_counter_wraps_instead_of_overflowing() {
        let counter = Counter::new(u64::MAX);

        assert_eq!(counter.increment(), 0);
    }
}
