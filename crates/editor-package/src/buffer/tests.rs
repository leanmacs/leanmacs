use std::ptr;

use super::*;

/// What `bytes` lends, entered as a declared function's body sees it.
fn entered(mut bytes: Bytes<'_>) -> Vec<u8> {
    #[expect(
        unsafe_code,
        reason = "enters bytes within the call they were lent for, as `functions!`' expansion does"
    )]
    // SAFETY: the bytes were made by `Bytes::of` from a slice that outlives
    // this call, and the slice is copied before it returns.
    unsafe { Param::enter(&mut bytes) }.to_vec()
}

#[test]
fn bytes_enter_as_their_slice_whole_and_as_nothing_with_a_null_pointer() {
    let text = "héllo\0".as_bytes();
    assert_eq!(entered(Bytes::of(text)), text);

    let nothing = Bytes {
        bytes: ptr::null(),
        len: 0,
        borrowed: PhantomData,
    };
    assert_eq!(entered(nothing), b"", "no bytes, whatever the pointer");
    assert_eq!(entered(Bytes::of(&[])), b"");
}

#[test]
fn a_lent_buffer_reads_back_whole_and_is_freed_once_handed_to_free() {
    let lent = Lent::of("héllo".as_bytes().to_vec());
    assert_eq!(lent.as_bytes(), "héllo".as_bytes());
    assert_eq!(lent.len, 6);
    free(lent);

    let empty = Lent::empty();
    assert_eq!(empty.as_bytes(), b"");
    free(empty);
}

/// Writes `value` through `out`, entered as a declared function's body
/// sees it.
fn put<T>(mut out: Out<'_, T>, value: T) {
    #[expect(
        unsafe_code,
        reason = "enters a place within the call it was handed for, as `functions!`' expansion does"
    )]
    // SAFETY: the place was made by `Out::of` from a reference that
    // outlives this call, or is null, and is written before it returns.
    unsafe { Param::enter(&mut out) }.put(value);
}

#[test]
fn an_out_place_is_written_once_and_a_null_one_is_left_alone() {
    let mut place = Lent::empty();
    put(Out::of(&mut place), Lent::of(b"put".to_vec()));
    assert_eq!(place.as_bytes(), b"put");

    let mut number = 7_u32;
    put(Out::of(&mut number), 9);
    assert_eq!(number, 9);

    let nowhere: Out<'_, Lent> = Out {
        place: ptr::null_mut(),
        placed: PhantomData,
    };
    put(nowhere, Lent::of(b"dropped, not written".to_vec()));
}

#[test]
fn a_plain_parameter_enters_as_itself() {
    let mut id = 41_u64;
    #[expect(
        unsafe_code,
        reason = "enters a plain value, as `functions!`' expansion does"
    )]
    // SAFETY: a plain value lends nothing.
    let entered = unsafe { Param::enter(&mut id) };
    assert_eq!(entered, 41);
}
