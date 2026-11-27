use std::cell::{Cell, RefCell};
use std::collections::VecDeque;

use editor_package_runtime::TAKE_OVER_NO_SUCH_CHILD;

use super::*;

/// Words, as the little-endian bytes a pull carries them in.
fn words(words: &[u64]) -> Vec<u8> {
    words.iter().flat_map(|word| word.to_le_bytes()).collect()
}

/// A pull the test runtime answers: whether it delivered, its words and its
/// bytes.
type Canned = (bool, Vec<u8>, Vec<u8>);

thread_local! {
    /// The pulls the test runtime answers, oldest first: whether each
    /// delivered, its words and its bytes.
    static CANNED: RefCell<VecDeque<Canned>> = const { RefCell::new(VecDeque::new()) };
    /// Every buffer the test runtime lent: its address and length.
    static LENT: RefCell<Vec<(usize, usize)>> = const { RefCell::new(Vec::new()) };
    /// Every buffer handed back to it.
    static FREED: RefCell<Vec<(usize, usize)>> = const { RefCell::new(Vec::new()) };
    /// Every write it was handed.
    static WRITTEN: RefCell<Vec<Vec<u8>>> = const { RefCell::new(Vec::new()) };
    /// How many times a handle was released.
    static RELEASED: Cell<u32> = const { Cell::new(0) };
}

/// Lends `bytes` as the core does, recording it.
fn lent(bytes: Vec<u8>) -> (*mut u8, usize) {
    let (bytes, len) = buffer::lend(bytes);
    LENT.with_borrow_mut(|lent| lent.push((bytes.addr(), len)));
    (bytes, len)
}

/// The handle the test runtime hands out for the child 1.
const HANDLE: usize = 0x5eed;

extern "C" fn register_service(_: *const PackageRuntime, _: *const u8, _: usize) -> u64 {
    0
}

extern "C" fn complete(_: *const PackageRuntime, _: u64, _: u64) -> bool {
    false
}

extern "C" fn post_event(_: *const PackageRuntime, _: u64, _: u64, _: *const u8, _: usize) -> bool {
    false
}

unsafe extern "C" fn take_over(
    _: *const PackageRuntime,
    child: u64,
    handle: *mut *mut PackageChild,
) -> u32 {
    if child != 1 {
        return TAKE_OVER_NO_SUCH_CHILD;
    }
    // SAFETY: the caller hands a writable place.
    unsafe { handle.write(ptr::without_provenance_mut(HANDLE)) };
    0
}

unsafe extern "C" fn child_pull(_: *const PackageRuntime, _: *mut PackageChild, out: *mut RawPull) {
    let (delivered, words, bytes) =
        CANNED
            .with_borrow_mut(VecDeque::pop_front)
            .unwrap_or((false, Vec::new(), Vec::new()));
    let (words, words_len) = lent(words);
    let (bytes, bytes_len) = lent(bytes);
    // SAFETY: the caller hands a writable record.
    unsafe {
        out.write(RawPull {
            delivered,
            words,
            words_len,
            bytes,
            bytes_len,
        });
    }
}

unsafe extern "C" fn child_write(
    _: *const PackageRuntime,
    _: *mut PackageChild,
    bytes: *const u8,
    len: usize,
    refused: *mut RawBuffer,
) -> bool {
    // SAFETY: the caller lends `len` bytes for the call.
    let bytes = unsafe { buffer::borrow(bytes, len) }.to_vec();
    let closed = bytes == b"late\n";
    WRITTEN.with_borrow_mut(|written| written.push(bytes));
    if !closed {
        return true;
    }
    let (bytes, len) = lent(b"Broken pipe".to_vec());
    // SAFETY: the caller hands a writable record.
    unsafe { refused.write(RawBuffer { bytes, len }) };
    false
}

extern "C" fn child_release(_: *const PackageRuntime, _: *mut PackageChild) {
    RELEASED.set(RELEASED.get() + 1);
}

extern "C" fn buffer_lend(_: *const PackageRuntime, _: *const u8, _: usize, _: *mut RawBuffer) {}

unsafe extern "C" fn buffer_free(_: *const PackageRuntime, bytes: *mut u8, len: usize) -> bool {
    FREED.with_borrow_mut(|freed| freed.push((bytes.addr(), len)));
    // SAFETY: the buffer is one `lent` gave up, handed back once.
    unsafe { buffer::reclaim(bytes, len) };
    true
}

/// A runtime of test functions, its state each test thread's own.
static TEST_RUNTIME: PackageRuntime = PackageRuntime {
    size: REQUIRED,
    private_members: ptr::null_mut(),
    register_service,
    complete,
    post_event,
    take_over,
    child_pull,
    child_write,
    child_release,
    buffer_lend,
    buffer_free,
};

#[test]
fn a_pull_of_lines_and_an_exit_decodes_to_the_delivery() {
    let words = words(&[0, 2, 3, 3, 0, 1, 1, 1, (-2_i64).cast_unsigned(), 0, 0]);
    assert_eq!(
        decode(&words, b"onetwoe"),
        Delivery {
            out: Frames::Lines(vec![b"one".to_vec(), b"two".to_vec()]),
            err: Frames::Lines(vec![b"e".to_vec()]),
            ended: Some(Ended::Exited { code: -2 }),
        }
    );
}

#[test]
fn every_end_and_framing_decodes() {
    let frames = [1, 1, 2, 2, 1, 2];
    let decoded = |end: [u64; 4], bytes: &[u8]| {
        decode(&words(&[frames.as_slice(), end.as_slice()].concat()), bytes)
    };
    let with = |ended| Delivery {
        out: Frames::Bytes(b"xy".to_vec()),
        err: Frames::Messages(vec![b"{}".to_vec()]),
        ended,
    };
    assert_eq!(decoded([0, 0, 0, 0], b"xy{}"), with(None));
    assert_eq!(
        decoded([2, 15, 0, 0], b"xy{}"),
        with(Some(Ended::Signalled { signal: 15 }))
    );
    assert_eq!(
        decoded([3, 1, 64, 0], b"xy{}"),
        with(Some(Ended::LineTooLong))
    );
    assert_eq!(
        decoded([4, 0, 9, 0], b"xy{}"),
        with(Some(Ended::MessageTooLong))
    );
    assert_eq!(
        decoded([5, 0, 0, 3], b"xy{}bad"),
        with(Some(Ended::Failed("bad".to_owned())))
    );
}

#[test]
fn words_that_spell_no_delivery_deliver_a_failure() {
    let unreadable = Delivery {
        out: Frames::Lines(Vec::new()),
        err: Frames::Lines(Vec::new()),
        ended: Some(Ended::Failed(UNREADABLE.to_owned())),
    };
    let cases: [(&[u64], &[u8]); 5] = [
        (&[0, 1, 3, 0, 0, 0, 0, 0, 0], b"ab"),
        (&[9, 0, 0, 0, 0, 0, 0, 0], b""),
        (&[0, 0, 0, 0, 0, 0, 0, 0, 7], b""),
        (&[0, 0, 0, 0, 6, 0, 0, 0], b""),
        (&[0, 0, 0, 0, 0, 0, 0], b""),
    ];
    for (words_, bytes) in cases {
        assert_eq!(decode(&words(words_), bytes), unreadable, "{words_:?}");
    }
    assert_eq!(
        decode(&words(&[0, 0, 0, 0, 0, 0, 0, 0]), b"left over"),
        unreadable
    );
}

#[test]
fn a_pull_through_the_runtime_decodes_and_hands_both_buffers_back_once() {
    CANNED.with_borrow_mut(|canned| {
        canned.push_back((true, words(&[0, 1, 3, 0, 0, 1, 0, 0, 0]), b"one".to_vec()));
    });
    let child = RuntimeChild::take_over(&TEST_RUNTIME, 1).expect("taken over");

    let first = child.pull();
    let last = child.pull();

    assert_eq!(
        first,
        Pulled::Delivered(Delivery {
            out: Frames::Lines(vec![b"one".to_vec()]),
            err: Frames::Lines(Vec::new()),
            ended: Some(Ended::Exited { code: 0 }),
        })
    );
    assert_eq!(last, Pulled::Cancelled);
    assert_eq!(LENT.with_borrow(Vec::len), 4);
    assert_eq!(
        FREED.with_borrow(Clone::clone),
        LENT.with_borrow(Clone::clone)
    );
}

#[test]
fn a_write_through_the_runtime_crosses_and_a_refused_one_answers_its_words_handed_back() {
    let child = RuntimeChild::take_over(&TEST_RUNTIME, 1).expect("taken over");

    assert_eq!(child.write(b"pong\n".to_vec()), Ok(()));
    assert_eq!(
        child.write(b"late\n".to_vec()),
        Err(InputClosed("Broken pipe".to_owned()))
    );

    assert_eq!(
        WRITTEN.with_borrow(Clone::clone),
        [b"pong\n".to_vec(), b"late\n".to_vec()]
    );
    assert_eq!(
        FREED.with_borrow(Clone::clone),
        LENT.with_borrow(Clone::clone)
    );
}

#[test]
fn a_child_is_released_once_when_dropped_and_a_refused_take_over_gives_none() {
    assert!(RuntimeChild::take_over(&TEST_RUNTIME, 2).is_none());
    let child = RuntimeChild::take_over(&TEST_RUNTIME, 1).expect("taken over");
    assert_eq!(RELEASED.get(), 0);
    drop(child);
    assert_eq!(RELEASED.get(), 1);
}
