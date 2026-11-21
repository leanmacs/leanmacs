//! A counter: the example of a Rust object that Lean holds by a handle.

use std::sync::atomic::{AtomicU64, Ordering};

use crate::live::Live;

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

/// How many counters [`editor_ffi_counter_new`] has handed out that
/// [`editor_ffi_counter_free`] has not taken back.
pub(crate) static LIVE: Live = Live::new();

/// A new counter starting at `start`, owned by the caller, who must hand it
/// to [`editor_ffi_counter_free`] exactly once.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_counter_new(start: u64) -> *mut Counter {
    LIVE.add();
    Box::into_raw(Box::new(Counter::new(start)))
}

/// Adds one to `counter` and returns the new value.
///
/// # Safety
///
/// `counter` came from [`editor_ffi_counter_new`] and has not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_counter_increment(counter: *const Counter) -> u64 {
    // SAFETY: the caller guarantees `counter` points to a live counter.
    unsafe { &*counter }.increment()
}

/// Frees `counter`.
///
/// # Safety
///
/// `counter` came from [`editor_ffi_counter_new`], has not been freed, and
/// is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_counter_free(counter: *mut Counter) {
    // SAFETY: the caller guarantees `counter` is a box
    // `editor_ffi_counter_new` gave up, taken back this once.
    drop(unsafe { Box::from_raw(counter) });
    LIVE.free();
}

/// How many counters [`editor_ffi_counter_new`] has made that have not been
/// freed. This is what makes a handle's finaliser observable to a test,
/// which waits for it to come down with
/// [`editor_ffi_live_await`](crate::live::editor_ffi_live_await).
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_counter_live() -> u64 {
    LIVE.count()
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
