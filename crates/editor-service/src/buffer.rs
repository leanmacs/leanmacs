//! Buffers of bytes as they cross the boundary: plain data, a pointer and a
//! length.
//!
//! What Lean lends for the length of a call is read with [`borrow`]. What
//! the library hands out in a result record is given up with [`lend`], and
//! comes back, once, to [`reclaim`]: `editor-ffi`'s `editor_ffi_text_free`
//! for the core's buffers, and a package's own `<package>_ffi_free` for its
//! crate's, each a C function that forwards here.

use std::{ptr, slice};

/// Gives `bytes` up as a buffer for a result record: its pointer and its
/// length. The caller hands both back to [`reclaim`].
pub fn lend(bytes: Vec<u8>) -> (*mut u8, usize) {
    let bytes = bytes.into_boxed_slice();
    let len = bytes.len();
    (Box::into_raw(bytes).cast(), len)
}

/// The `len` bytes at `bytes`, lent for the length of a call. No bytes at
/// all may be lent with any pointer, a null one included: a length of zero
/// borrows as the empty slice without the pointer being looked at.
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
    // lifetime, and a slice of bytes has no alignment to keep.
    unsafe { slice::from_raw_parts(bytes, len) }
}

/// Takes back a buffer [`lend`] gave up, and frees it.
///
/// # Safety
///
/// `bytes` and `len` are the pointer and length of a buffer [`lend`] gave
/// up, which has not been handed back and is not used again.
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
        let (bytes, len) = lend("héllo\0".as_bytes().to_vec());
        assert_eq!(len, 7);
        // SAFETY: `lend` gave the buffer up; it is read, then taken back once.
        unsafe {
            assert_eq!(borrow(bytes, len), "héllo\0".as_bytes());
            reclaim(bytes, len);
        }
    }

    #[test]
    fn an_empty_buffer_is_lent_and_reclaimed() {
        let (bytes, len) = lend(Vec::new());
        assert_eq!(len, 0);
        // SAFETY: as above.
        unsafe {
            assert_eq!(borrow(bytes, len), b"");
            reclaim(bytes, len);
        }
    }

    #[test]
    fn no_bytes_lent_with_a_null_pointer_borrow_as_empty() {
        // SAFETY: no bytes are lent, which any pointer may do.
        assert_eq!(unsafe { borrow(ptr::null(), 0) }, b"");
    }
}
