//! A package's table functions declared with `editor_package::functions!`,
//! as a package's library declares them, with `#![deny(unsafe_code)]`:
//! each is an `extern "C" fn` over the wrapper's FFI-safe types, and its
//! body sees what each parameter lends borrowed for the call alone, a
//! [`Bytes`] as its `&[u8]` and an [`Out`] as a `Place` written once, so
//! nothing it was lent outlives the call (`editor_package::buffer`, "Lent
//! for the call alone").

#![deny(unsafe_code)]

use editor_package::buffer::{Bytes, Lent, Out};
use editor_package::functions;

/// A result as it crosses: `{ { uint8_t *bytes; size_t len; } text; uint32_t
/// count; }`.
#[repr(C)]
#[derive(Debug)]
struct Reply {
    /// The text, lent by the library.
    text: Lent,
    /// A count.
    count: u32,
}

functions! {
    /// The length of `text` plus `id`: a plain parameter is itself, and
    /// bytes are their slice.
    extern "C" fn length(id: u64, text: Bytes<'_>) -> u64 {
        id + text.len() as u64
    }

    /// Writes `text`, upper-cased, and its length to `out`, once.
    extern "C" fn shout(text: Bytes<'_>, out: Out<'_, Reply>) -> bool {
        let loud = text.to_ascii_uppercase();
        let count = u32::try_from(loud.len()).unwrap_or(u32::MAX);
        out.put(Reply {
            text: Lent::of(loud),
            count,
        });
        true
    }

    /// Writes nothing, and answers false.
    pub extern "C" fn decline(_out: Out<'_, Reply>) -> bool {
        false
    }
}

/// The table the functions above fill, as a package's own.
#[repr(C)]
struct Functions {
    /// [`length`].
    length: extern "C" fn(id: u64, text: Bytes<'_>) -> u64,
    /// [`shout`].
    shout: extern "C" fn(text: Bytes<'_>, out: Out<'_, Reply>) -> bool,
    /// [`decline`].
    decline: extern "C" fn(out: Out<'_, Reply>) -> bool,
}

/// The table.
const FUNCTIONS: Functions = Functions {
    length,
    shout,
    decline,
};

#[test]
fn a_declared_function_reads_its_bytes_as_a_slice_and_a_plain_parameter_as_itself() {
    assert_eq!((FUNCTIONS.length)(3, Bytes::of(b"four")), 7);
    assert_eq!((FUNCTIONS.length)(0, Bytes::of(b"")), 0);
}

#[test]
fn a_declared_function_writes_its_result_once_through_its_out_place() {
    let mut place = Reply {
        text: Lent::empty(),
        count: 0,
    };

    assert!((FUNCTIONS.shout)(Bytes::of(b"hey"), Out::of(&mut place)));

    assert_eq!(place.text.as_bytes(), b"HEY");
    assert_eq!(place.count, 3);
}

#[test]
fn a_declared_function_that_writes_nothing_leaves_its_place_alone() {
    let mut place = Reply {
        text: Lent::of(b"kept".to_vec()),
        count: 4,
    };

    assert!(!(FUNCTIONS.decline)(Out::of(&mut place)));

    assert_eq!(place.text.as_bytes(), b"kept");
    assert_eq!(place.count, 4);
}
