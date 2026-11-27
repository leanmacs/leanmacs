use std::ptr;

use super::*;

#[test]
fn bytes_borrow_a_slice_whole_and_nothing_with_a_null_pointer() {
    let text = "héllo\0".as_bytes();
    let bytes = Bytes::of(text);
    assert_eq!(bytes.as_slice(), text);
    assert_eq!(bytes.to_string_lossy(), "héllo\0");
    assert_eq!(Bytes::of(b"\xffok").to_string_lossy(), "\u{FFFD}ok");

    let nothing = Bytes {
        bytes: ptr::null(),
        len: 0,
        borrowed: PhantomData,
    };
    assert_eq!(nothing.as_slice(), b"", "no bytes, whatever the pointer");
    assert_eq!(Bytes::of(&[]).as_slice(), b"");
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

#[test]
fn an_out_place_is_written_once_and_a_null_one_is_left_alone() {
    let mut place = Lent::empty();
    Out::of(&mut place).put(Lent::of(b"put".to_vec()));
    assert_eq!(place.as_bytes(), b"put");

    let mut number = 7_u32;
    Out::of(&mut number).put(9);
    assert_eq!(number, 9);

    let nowhere: Out<'_, Lent> = Out {
        place: ptr::null_mut(),
        placed: PhantomData,
    };
    nowhere.put(Lent::of(b"dropped, not written".to_vec()));
}
