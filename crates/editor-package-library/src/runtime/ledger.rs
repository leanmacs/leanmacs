//! The buffers a runtime lends, on its ledger: what makes "handed back
//! exactly once" checkable, and a second hand-back harmless.
//!
//! Every buffer a runtime lends a library (a pull's words and bytes, a
//! refused write's words, `buffer_lend`'s) is made by [`Ledger::lend`],
//! which records its address and length, and comes back through
//! [`Ledger::reclaim`], which frees it and answers true only while it is
//! outstanding. A second hand-back, or a pointer the ledger never lent,
//! answers false and frees nothing, so a library's mistake is refused
//! instead of corrupting the core's heap. The ledger is a multiset: two
//! lent buffers at one address and length (two empty ones) are counted
//! apart.
//!
//! **Its limit.** Once a buffer is freed the allocator may give its
//! address to a later buffer of the same length, so the ledger cannot
//! tell a stale hand-back of the first from a live hand-back of the
//! second. A library's rule stays "exactly once"; the ledger makes the
//! rule observable and a second hand-back of a buffer not yet reused
//! harmless.
//!
//! The real runtime lends through the process's [`LEDGER`]; the pure model
//! ([`super::model::ModelRuntime`]) through a ledger of its own.

use std::collections::BTreeMap;
use std::sync::{Mutex, MutexGuard, PoisonError};

use editor_package_runtime::RawBuffer;
use editor_service::buffer;

/// The buffers lent and not yet handed back, as a multiset of their
/// address and length.
#[derive(Debug, Default)]
pub struct Ledger {
    /// How many buffers are outstanding at each address and length.
    lent: Mutex<BTreeMap<(usize, usize), usize>>,
}

/// The process's ledger: every buffer the real runtime lends.
pub static LEDGER: Ledger = Ledger::new();

impl Ledger {
    /// A ledger with nothing lent.
    pub const fn new() -> Self {
        Self {
            lent: Mutex::new(BTreeMap::new()),
        }
    }

    /// Locks the counts. The lock is never held while other code runs.
    fn lent(&self) -> MutexGuard<'_, BTreeMap<(usize, usize), usize>> {
        self.lent.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Lends `bytes` as a buffer, recorded as outstanding.
    pub fn lend(&self, bytes: Vec<u8>) -> RawBuffer {
        let (bytes, len) = buffer::lend(bytes);
        *self.lent().entry((bytes.addr(), len)).or_default() += 1;
        RawBuffer { bytes, len }
    }

    /// Takes back the buffer at `bytes` of `len` bytes and frees it,
    /// answering true, when it is outstanding; otherwise answers false and
    /// frees nothing.
    #[expect(
        clippy::not_unsafe_ptr_arg_deref,
        reason = "safe to call with any pointer: only one this ledger lent and still holds as outstanding is freed, and any other is refused untouched"
    )]
    pub fn reclaim(&self, bytes: *mut u8, len: usize) -> bool {
        {
            let mut lent = self.lent();
            let key = (bytes.addr(), len);
            match lent.get_mut(&key) {
                None => return false,
                Some(1) => {
                    lent.remove(&key);
                }
                Some(count) => *count -= 1,
            }
        }
        #[expect(
            unsafe_code,
            reason = "frees a buffer this ledger lent and still holds as outstanding, which it has just struck off"
        )]
        // SAFETY: the ledger lent a buffer of this address and length with
        // `buffer::lend` and it was outstanding: struck off above, under
        // the lock, so it is freed this once.
        unsafe {
            buffer::reclaim(bytes, len);
        }
        true
    }

    /// How many buffers are outstanding.
    pub fn outstanding(&self) -> usize {
        self.lent().values().sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The bytes of a buffer `ledger` lent, read while it is outstanding.
    #[expect(
        unsafe_code,
        reason = "reads a buffer the ledger lent, as a library does, before it is handed back"
    )]
    fn read(lent: RawBuffer) -> Vec<u8> {
        // SAFETY: the buffer was lent and is not yet handed back.
        unsafe { buffer::borrow(lent.bytes, lent.len) }.to_vec()
    }

    #[test]
    fn a_lent_buffer_reads_back_and_is_reclaimed_once() {
        let ledger = Ledger::new();
        let lent = ledger.lend(b"abc".to_vec());

        assert_eq!(read(lent), b"abc");
        assert!(ledger.reclaim(lent.bytes, lent.len));
        assert!(!ledger.reclaim(lent.bytes, lent.len), "handed back already");
    }

    #[test]
    fn a_pointer_never_lent_is_refused_and_freed_never() {
        let ledger = Ledger::new();
        let mut own = *b"abc";

        assert!(!ledger.reclaim(own.as_mut_ptr(), own.len()));
        assert_eq!(&own, b"abc");
    }

    #[test]
    fn two_empty_buffers_are_counted_apart() {
        let ledger = Ledger::new();
        let first = ledger.lend(Vec::new());
        let second = ledger.lend(Vec::new());

        assert_eq!(ledger.outstanding(), 2);
        assert!(ledger.reclaim(first.bytes, first.len));
        assert!(ledger.reclaim(second.bytes, second.len));
        assert!(!ledger.reclaim(first.bytes, first.len));
    }

    #[test]
    fn outstanding_counts_what_is_lent_and_not_yet_handed_back() {
        let ledger = Ledger::new();
        let one = ledger.lend(b"one".to_vec());
        let two = ledger.lend(b"two!".to_vec());
        assert_eq!(ledger.outstanding(), 2);

        ledger.reclaim(one.bytes, one.len);
        assert_eq!(ledger.outstanding(), 1);
        ledger.reclaim(one.bytes, one.len);
        assert_eq!(ledger.outstanding(), 1, "a second hand-back counts nothing");
        ledger.reclaim(two.bytes, two.len);
        assert_eq!(ledger.outstanding(), 0);
    }
}
