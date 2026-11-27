//! Safe types for what crosses a package's own table and the runtime: bytes
//! lent for a call ([`Bytes`]), a buffer the library lends ([`Lent`],
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
//! # Lent for the call alone
//!
//! What a C caller lends a table function, the bytes of a [`Bytes`] and
//! the place of an [`Out`], lives only for the call, while the lifetime a
//! package writes in its function's signature is its own to choose:
//! `Bytes<'static>` is a type like any other, and a value of it can be kept
//! in a thread-local or leaked. So neither type reads or writes in safe
//! code. A table function is declared with [`functions!`](crate::functions),
//! whose expansion hands its body each parameter *entered* ([`Param`]): a
//! [`Bytes`] as the `&[u8]` it lends and an [`Out`] as a [`Place`], each
//! borrowed from a local of the function, so no lifetime the signature
//! names lets it outlive the call. A plain value (an integer, a float, a
//! `bool`) is itself.
//!
//! ```
//! # #![deny(unsafe_code)]
//! use editor_package::buffer::{Bytes, Out};
//!
//! editor_package::functions! {
//!     /// The length of `text`, written to `out`.
//!     extern "C" fn length(text: Bytes<'_>, out: Out<'_, u64>) -> bool {
//!         // `text` is a `&[u8]` here, and `out` a `Place<'_, u64>`.
//!         out.put(text.len() as u64);
//!         true
//!     }
//! }
//!
//! let mut place = 0_u64;
//! assert!(length(Bytes::of(b"four"), Out::of(&mut place)));
//! assert_eq!(place, 4);
//! ```
//!
//! A lent value kept past its call cannot be read: a [`Bytes`] has no
//! reader outside a declared function,
//!
//! ```compile_fail
//! # #![deny(unsafe_code)]
//! use editor_package::buffer::Bytes;
//!
//! extern "C" fn keep(text: Bytes<'static>) -> &'static [u8] {
//!     text.as_slice()
//! }
//! ```
//!
//! entering one is `unsafe`, which a package's `#![deny(unsafe_code)]`
//! refuses,
//!
//! ```compile_fail
//! # #![deny(unsafe_code)]
//! use editor_package::buffer::{Bytes, Param};
//!
//! extern "C" fn keep(mut text: Bytes<'static>) -> usize {
//!     unsafe { Param::enter(&mut text) }.len()
//! }
//! ```
//!
//! and inside a declared function, a signature that names `'static` keeps
//! nothing, since what the body sees is borrowed from the function's
//! local:
//!
//! ```compile_fail
//! # #![deny(unsafe_code)]
//! use std::cell::Cell;
//! use editor_package::buffer::Bytes;
//!
//! thread_local! {
//!     static KEPT: Cell<&'static [u8]> = const { Cell::new(&[]) };
//! }
//!
//! editor_package::functions! {
//!     extern "C" fn keep(text: Bytes<'static>) -> bool {
//!         KEPT.with(|kept| kept.set(text));
//!         true
//!     }
//! }
//! ```
//!
//! The `unsafe` is here, each site marked with its reason: entering a
//! [`Bytes`] and an [`Out`] ([`Param::enter`]), writing through a
//! [`Place`], making, reading, freeing and sending a [`Lent`], and reading
//! and handing back a [`CoreBuffer`]; and in [`functions!`](crate::functions)'
//! expansion, which enters each parameter and which rustc's `unsafe_code`
//! lint does not reach in a package's crate.

use std::marker::PhantomData;
use std::{ptr, slice};

use crate::runtime::Calls;

/// Bytes lent for a call: the C shape `{ const uint8_t *bytes; size_t
/// len; }`, passed by value. Made in Rust only by [`Bytes::of`]; from C, a
/// caller lends `len` readable bytes at `bytes` for the call, or `len` 0
/// with any pointer, a null one included. Read only inside a function
/// declared with [`functions!`](crate::functions), as a `&[u8]` borrowed
/// for the call ("Lent for the call alone", above).
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
}

/// What a table function's parameter is inside the function's body, as
/// [`functions!`](crate::functions) hands it: a value lent for the call,
/// borrowed for `'s`, a local's borrow that ends before the function
/// returns. A new type that crosses a package's table implements it.
pub trait Param {
    /// The parameter as the body sees it.
    type Inside<'s>
    where
        Self: 's;

    /// The parameter, entered for the body.
    ///
    /// # Safety
    ///
    /// `self` was handed to the table function now running, by its C caller
    /// for this call or by Rust code that made it soundly, and `'s` ends
    /// before that function returns: what a C caller lends lives only for
    /// the call, whatever lifetime the function's signature names.
    #[expect(
        unsafe_code,
        reason = "entering a lent parameter is sound only within the call it was lent for, which only `functions!`' expansion can promise"
    )]
    unsafe fn enter<'s>(&'s mut self) -> Self::Inside<'s>;
}

/// A plain value crosses as itself.
macro_rules! plain_params {
    ($($plain:ty),* $(,)?) => {
        $(
            impl Param for $plain {
                type Inside<'s> = Self;

                #[expect(
                    unsafe_code,
                    reason = "the trait's method is `unsafe`; a plain value is copied, and nothing is read through a pointer"
                )]
                unsafe fn enter(&mut self) -> Self {
                    *self
                }
            }
        )*
    };
}

plain_params!(
    bool, u8, u16, u32, u64, usize, i8, i16, i32, i64, isize, f32, f64
);

impl<'a> Param for Bytes<'a> {
    type Inside<'s>
        = &'s [u8]
    where
        Self: 's;

    /// The bytes, as a slice borrowed as long as `self` is: no bytes,
    /// whatever the pointer, when the length is 0.
    #[expect(
        unsafe_code,
        reason = "the trait's method is `unsafe`: the slice is sound only for the call the bytes were lent for"
    )]
    unsafe fn enter(&mut self) -> &[u8] {
        if self.len == 0 {
            return &[];
        }
        #[expect(
            unsafe_code,
            reason = "reads bytes lent for a call, for no longer than the call: made in Rust only from a slice, and from C by a caller that lends `len` readable bytes"
        )]
        // SAFETY: `Bytes::of` made it from a slice that lives for `'a`,
        // which outlives this borrow of `self`; or a C caller lent `len`
        // readable bytes at the pointer for the call, which the borrow does
        // not outlive (`enter`'s caller's promise); a slice of bytes has no
        // alignment to keep.
        unsafe {
            slice::from_raw_parts(self.bytes, self.len)
        }
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
/// Rust only by [`Out::of`]; from C, a caller hands a writable place for
/// the call, or a null pointer, which is written nothing. Written only
/// inside a function declared with [`functions!`](crate::functions), as a
/// [`Place`] borrowed for the call ("Lent for the call alone", above).
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
}

impl<'a, T> Param for Out<'a, T> {
    type Inside<'s>
        = Place<'s, T>
    where
        Self: 's;

    #[expect(
        unsafe_code,
        reason = "the trait's method is `unsafe`: the place is writable only for the call it was handed for"
    )]
    unsafe fn enter(&mut self) -> Place<'_, T> {
        Place {
            place: self.place,
            placed: PhantomData,
        }
    }
}

/// The place of an [`Out`], entered for a declared function's body and
/// borrowed for `'s`, no longer than the call: written once
/// ([`Place::put`]).
#[derive(Debug)]
pub struct Place<'s, T> {
    /// The place, writable for the call, or null.
    place: *mut T,
    /// Borrowed, writable, for `'s`.
    placed: PhantomData<&'s mut T>,
}

impl<T> Place<'_, T> {
    /// Writes `value` to the place, once, without dropping what was there;
    /// writes nothing to a null place, and drops `value` there.
    pub fn put(self, value: T) {
        if self.place.is_null() {
            return;
        }
        #[expect(
            unsafe_code,
            reason = "writes a result where the caller says, within the call: made in Rust only from a reference, and from C by a caller that hands a writable place for the call"
        )]
        // SAFETY: the `Out` it was entered from was made by `Out::of` from
        // a reference that outlives this place, or handed by a C caller as
        // a place writable for the call, which this place does not outlive
        // (`Param::enter`); `put` takes the `Place`, and an `Out` is
        // entered once, so the place is written once.
        unsafe {
            self.place.write(value);
        }
    }
}

/// Declares a package's table functions: each an `extern "C" fn` over the
/// wrapper's FFI-safe types, written with the signature its table names,
/// whose body sees each parameter entered ([`Param`]): a [`Bytes`] as the
/// `&[u8]` it lends and an [`Out`] as a [`Place`], borrowed from a local
/// of the function, so nothing the caller lent outlives the call; a plain
/// value as itself. Every parameter's type implements [`Param`].
///
/// ```
/// # #![deny(unsafe_code)]
/// use editor_package::buffer::Bytes;
///
/// editor_package::functions! {
///     /// Whether `text` is `ping`.
///     pub extern "C" fn is_ping(text: Bytes<'_>) -> bool {
///         text == b"ping"
///     }
/// }
///
/// assert!(is_ping(Bytes::of(b"ping")));
/// ```
///
/// The entering is the wrapper's `unsafe`, written here once; rustc's
/// `unsafe_code` lint does not fire on an external macro's expansion, so a
/// package keeps `#![deny(unsafe_code)]`.
#[macro_export]
macro_rules! functions {
    ($(
        $(#[$meta:meta])*
        $vis:vis extern "C" fn $name:ident ( $($param:ident : $ty:ty),* $(,)? ) $(-> $ret:ty)? $body:block
    )*) => {
        $(
            $(#[$meta])*
            $vis extern "C" fn $name($($param: $ty),*) $(-> $ret)? {
                $(
                    let mut $param = $param;
                    // SAFETY: the parameter was handed to this function for
                    // this call, and what the body sees is borrowed from
                    // this local, which ends before the function returns.
                    let $param = unsafe { $crate::buffer::Param::enter(&mut $param) };
                )*
                $body
            }
        )*
    };
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
