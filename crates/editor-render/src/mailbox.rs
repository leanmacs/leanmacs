//! The mailbox: one slot, in which a newer value replaces one not yet
//! taken.
//!
//! Whoever publishes frames posts each with a stamp, the time of the input
//! it answers; the render thread takes what is there when it draws. A frame
//! nobody took before the next arrived is never drawn. The stamp kept is
//! then the older one: what is drawn answers the earlier input too, and a
//! latency measured from the newer stamp would flatter the loop.

use std::sync::{Mutex, MutexGuard, PoisonError};

/// One slot for a value and its stamp, shared between the thread that posts
/// and the thread that takes.
#[derive(Debug)]
pub struct Mailbox<T> {
    /// What was posted and not yet taken.
    slot: Mutex<Option<(T, u64)>>,
}

impl<T> Default for Mailbox<T> {
    fn default() -> Self {
        Self {
            slot: Mutex::new(None),
        }
    }
}

impl<T> Mailbox<T> {
    /// An empty mailbox.
    pub fn new() -> Self {
        Self::default()
    }

    /// The slot, locked. A poisoned lock is used as it is: the slot is
    /// only ever replaced whole.
    fn slot(&self) -> MutexGuard<'_, Option<(T, u64)>> {
        self.slot.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Puts `value` in the slot with `stamp`, and says whether it replaced
    /// a value nobody had taken. When it did, the stamp kept is the older
    /// of the two.
    pub fn post(&self, value: T, stamp: u64) -> bool {
        let mut slot = self.slot();
        let waiting = slot.take().map(|(_, older)| older);
        *slot = Some((value, waiting.map_or(stamp, |older| older.min(stamp))));
        waiting.is_some()
    }

    /// Takes what is in the slot, with its stamp, and leaves it empty.
    pub fn take(&self) -> Option<(T, u64)> {
        self.slot().take()
    }
}

#[cfg(test)]
mod tests {
    use super::Mailbox;

    #[test]
    fn what_is_posted_is_taken_once() {
        let mailbox = Mailbox::new();
        assert_eq!(mailbox.take(), None);
        assert!(!mailbox.post("first", 5));
        assert_eq!(mailbox.take(), Some(("first", 5)));
        assert_eq!(mailbox.take(), None);
    }

    #[test]
    fn a_newer_frame_replaces_one_not_yet_taken() {
        let mailbox = Mailbox::new();
        assert!(!mailbox.post("first", 5));
        assert!(mailbox.post("second", 9));
        assert!(mailbox.post("third", 12));
        assert_eq!(mailbox.take().map(|(value, _)| value), Some("third"));
        assert_eq!(mailbox.take(), None);
        // Once it is taken, the next post replaces nothing.
        assert!(!mailbox.post("fourth", 20));
    }

    #[test]
    fn the_stamp_kept_is_the_older() {
        let mailbox = Mailbox::new();
        mailbox.post("first", 5);
        mailbox.post("second", 9);
        assert_eq!(mailbox.take(), Some(("second", 5)));
        // A stamp is the older by its value, whichever was posted first.
        mailbox.post("third", 30);
        mailbox.post("fourth", 20);
        assert_eq!(mailbox.take(), Some(("fourth", 20)));
        // And what was taken leaves no stamp behind.
        mailbox.post("fifth", 40);
        assert_eq!(mailbox.take(), Some(("fifth", 40)));
    }

    #[test]
    fn it_is_posted_to_from_one_thread_and_taken_from_another() {
        let mailbox = Mailbox::new();
        std::thread::scope(|scope| {
            scope.spawn(|| {
                for stamp in 1..=100 {
                    mailbox.post(stamp, stamp);
                }
            });
        });
        assert_eq!(mailbox.take(), Some((100, 1)));
    }
}
