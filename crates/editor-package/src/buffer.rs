//! Safe types for what crosses a package's own table and the runtime: bytes
//! borrowed for a call ([`Bytes`]), a buffer the library lends ([`Lent`],
//! handed back through [`free`]), a place for one result ([`Out`]), and a
//! buffer the core lent ([`CoreBuffer`]).
//!
//! Each type's fields are private, and Rust code can make one only soundly,
//! so a package's `extern "C" fn`s that take and give them need no `unsafe`
//! of their own, and its tests call them as plain Rust. From C, each has
//! the shape its docs give, which the package's glue declares member for
//! member; the glue keeps the type's rule (lend the bytes for the call,
//! hand a lent buffer back once).
//!
//! The `unsafe` is here, each site marked with its reason: reading
//! [`Bytes`], making, reading, freeing and sending a [`Lent`], writing
//! through an [`Out`], and reading and handing back a [`CoreBuffer`].

use std::marker::PhantomData;
use std::{ptr, slice};

use crate::runtime::Calls;

/// Bytes borrowed for a call: the C shape `{ const uint8_t *bytes; size_t
/// len; }`, passed by value. Made in Rust only by [`Bytes::of`]; from C, a
/// caller lends `len` readable bytes at `bytes` for the call, or `len` 0
/// with any pointer, a null one included.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct Bytes<'a> {
    /// The first byte.
    bytes: *const u8,
    /// How many.
    len: usize,
    /// Borrowed for `'a`.
    borrowed: PhantomData<&'a [u8]>,
}

impl<'a> Bytes<'a> {
    /// The bytes of `bytes`, borrowed.
    pub const fn of(bytes: &'a [u8]) -> Self {
        Self {
            bytes: bytes.as_ptr(),
            len: bytes.len(),
            borrowed: PhantomData,
        }
    }

    /// The bytes, as a slice: no bytes, whatever the pointer, when the
    /// length is 0.
    pub fn as_slice(&self) -> &'a [u8] {
        if self.len == 0 {
            return &[];
        }
        #[expect(
            unsafe_code,
            reason = "reads bytes lent for a call: made in Rust only from a slice, and from C by a caller that lends `len` readable bytes"
        )]
        // SAFETY: `Bytes::of` made it from a slice that lives for `'a`, or a
        // C caller lent `len` readable bytes at the pointer for the call,
        // which `'a` does not outlive; a slice of bytes has no alignment to
        // keep.
        unsafe {
            slice::from_raw_parts(self.bytes, self.len)
        }
    }

    /// The bytes read as UTF-8, with U+FFFD in place of each invalid
    /// sequence.
    pub fn to_string_lossy(&self) -> String {
        String::from_utf8_lossy(self.as_slice()).into_owned()
    }
}

/// A buffer the library lends and owns: the C shape `{ uint8_t *bytes;
/// size_t len; }`. It is freed by the library's own allocator when it is
/// dropped, so a caller in C hands it back, once, through the library's
/// table's `free` ([`free`]), passing it by value. Neither `Copy` nor
/// `Clone`: a buffer is freed once.
#[repr(C)]
#[derive(Debug)]
pub struct Lent {
    /// The first byte, of a boxed slice given up.
    bytes: *mut u8,
    /// How many.
    len: usize,
}

impl Lent {
    /// Lends `bytes`.
    pub fn of(bytes: Vec<u8>) -> Self {
        let bytes = bytes.into_boxed_slice();
        let len = bytes.len();
        Self {
            bytes: Box::into_raw(bytes).cast(),
            len,
        }
    }

    /// Lends no bytes.
    pub fn empty() -> Self {
        Self::of(Vec::new())
    }

    /// The bytes lent.
    #[expect(
        unsafe_code,
        reason = "reads the boxed slice this buffer gave up, which it still owns"
    )]
    pub fn as_bytes(&self) -> &[u8] {
        // SAFETY: the parts are a boxed slice `Lent::of` gave up, owned by
        // this buffer until it drops.
        unsafe { slice::from_raw_parts(self.bytes, self.len) }
    }
}

impl Drop for Lent {
    #[expect(
        unsafe_code,
        reason = "frees the boxed slice this buffer gave up, once, as it drops"
    )]
    fn drop(&mut self) {
        // SAFETY: the parts are a boxed slice `Lent::of` gave up; a `Lent`
        // is neither `Copy` nor `Clone`, so it is taken back this once.
        drop(unsafe { Box::from_raw(ptr::slice_from_raw_parts_mut(self.bytes, self.len)) });
    }
}

// SAFETY: a `Lent` owns its boxed slice outright, as a `Box<[u8]>` does,
// which is `Send`.
#[expect(
    unsafe_code,
    reason = "a lent buffer owns its bytes as a boxed slice does, so it moves between threads as one"
)]
unsafe impl Send for Lent {}

// SAFETY: as for `Send`: shared, it is only read.
#[expect(
    unsafe_code,
    reason = "a lent buffer owns its bytes as a boxed slice does, and is only read when shared"
)]
unsafe impl Sync for Lent {}

/// Hands back a buffer the library lent, freed by the library's own
/// allocator: the `free` member a package's table names, which the glue
/// calls once for each buffer it was handed.
pub extern "C" fn free(lent: Lent) {
    drop(lent);
}

/// A place the caller hands for one result: the C shape `T *`. Made in
/// Rust only by [`Out::of`]; from C, a caller hands a writable place, or a
/// null pointer, which is written nothing.
#[repr(transparent)]
#[derive(Debug)]
pub struct Out<'a, T> {
    /// The place.
    place: *mut T,
    /// Borrowed, writable, for `'a`.
    placed: PhantomData<&'a mut T>,
}

impl<'a, T> Out<'a, T> {
    /// The place `place`. What it holds is not dropped when it is written:
    /// from C a place is uninitialised. Hand one that owns nothing to free,
    /// such as [`Lent::empty`], or a plain value.
    pub const fn of(place: &'a mut T) -> Self {
        Self {
            place,
            placed: PhantomData,
        }
    }

    /// Writes `value` to the place, once, without dropping what was there;
    /// writes nothing to a null place, and drops `value` there.
    pub fn put(self, value: T) {
        if self.place.is_null() {
            return;
        }
        #[expect(
            unsafe_code,
            reason = "writes a result where the caller says: made in Rust only from a reference, and from C by a caller that hands a writable place"
        )]
        // SAFETY: `Out::of` made it from a reference live for `'a`, or a C
        // caller handed a writable place; `put` takes the `Out`, so the
        // place is written once.
        unsafe {
            self.place.write(value);
        }
    }
}

/// A buffer the core lent: a pull's words and bytes, a refused write's
/// words, or [`crate::Runtime::lend`]'s. It is the library's to read until
/// it drops, which hands it back to the core through the runtime's
/// `buffer_free`, exactly once, by construction.
#[derive(Debug)]
pub struct CoreBuffer {
    /// The runtime that lent it.
    calls: Calls,
    /// The first byte.
    bytes: *mut u8,
    /// How many.
    len: usize,
}

impl CoreBuffer {
    /// The buffer at `bytes` of `len` bytes, which the runtime of `calls`
    /// has just lent and the caller hands to no one else.
    pub(crate) const fn lent(calls: Calls, bytes: *mut u8, len: usize) -> Self {
        Self { calls, bytes, len }
    }

    /// The bytes lent.
    pub fn as_bytes(&self) -> &[u8] {
        if self.len == 0 {
            return &[];
        }
        #[expect(
            unsafe_code,
            reason = "reads a buffer the core lent, which it keeps until this buffer hands it back on drop"
        )]
        // SAFETY: the runtime lent `len` readable bytes at the pointer,
        // which stay the library's until `drop` hands them back.
        unsafe {
            slice::from_raw_parts(self.bytes, self.len)
        }
    }
}

impl Drop for CoreBuffer {
    fn drop(&mut self) {
        // A buffer is handed back once, here, so the runtime never refuses
        // it: what it answers is not needed.
        let _ = self.calls.free(self.bytes, self.len);
    }
}

#[cfg(test)]
mod tests;
