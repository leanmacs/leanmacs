//! Buffers of bytes as they cross to the glue: what echo lends in a reply
//! ([`lend`]) comes back once, to its own table's `free` ([`reclaim`]),
//! freed by the allocator that made it, which is this library's: it
//! carries its own Rust standard library. What the glue lends for a call
//! is read with [`borrow`].

use std::{ptr, slice};

/// Gives `bytes` up as a buffer: its pointer and length, handed back to
/// [`reclaim`].
pub fn lend(bytes: Vec<u8>) -> (*mut u8, usize) {
    let bytes = bytes.into_boxed_slice();
    let len = bytes.len();
    (Box::into_raw(bytes).cast(), len)
}

/// The `len` bytes at `bytes`, lent for a call; no bytes, with any pointer,
/// borrow as the empty slice.
///
/// # Safety
///
/// When `len` is not zero, `bytes` points to `len` readable bytes that stay
/// unchanged for `'a`.
pub unsafe fn borrow<'a>(bytes: *const u8, len: usize) -> &'a [u8] {
    if len == 0 {
        return &[];
    }
    // SAFETY: the caller guarantees the pointer, the length and the
    // lifetime.
    unsafe { slice::from_raw_parts(bytes, len) }
}

/// Takes back a buffer [`lend`] gave up, and frees it.
///
/// # Safety
///
/// `bytes` and `len` are a buffer [`lend`] gave up, handed back this once.
pub unsafe fn reclaim(bytes: *mut u8, len: usize) {
    // SAFETY: the caller guarantees these are the parts of a boxed slice
    // `lend` gave up, taken back this once.
    drop(unsafe { Box::from_raw(ptr::slice_from_raw_parts_mut(bytes, len)) });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_lent_buffer_reads_back_whole_and_is_reclaimed() {
        let (bytes, len) = lend("héllo".as_bytes().to_vec());
        // SAFETY: lent above, read, then handed back once.
        unsafe {
            assert_eq!(borrow(bytes, len), "héllo".as_bytes());
            reclaim(bytes, len);
        }
    }

    #[test]
    fn no_bytes_with_a_null_pointer_borrow_as_empty() {
        // SAFETY: no bytes are lent.
        assert_eq!(unsafe { borrow(ptr::null(), 0) }, b"");
    }
}
