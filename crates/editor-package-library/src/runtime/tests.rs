use std::cell::RefCell;
use std::mem::MaybeUninit;
use std::ptr;

use editor_service::frame::Framing;
use editor_service::stream::fake::FakeSource;
use editor_service::stream::{Delivery, StreamSource};

use super::*;

/// The words of `encoded`, read back as numbers.
fn words(encoded: &Encoded) -> Vec<u64> {
    encoded
        .words
        .chunks(8)
        .map(|word| u64::from_le_bytes(word.try_into().expect("whole words")))
        .collect()
}

/// A fake child of lines on both streams, bound 64, with an input,
/// taken over as the core's handle.
fn taken(fake: &FakeSource) -> (editor_service::stream::fake::FakeChild, Box<PackageChild>) {
    let child = fake.child(Framing::Lines, Framing::Lines, 64, true);
    let handle = take_over_from(fake, child.id()).expect("taken over");
    (child, handle)
}

#[test]
fn two_registrations_answer_two_distinct_ids_at_or_above_the_first_package_id() {
    let first = register_named(b"one library's");
    let second = register_named(b"one library's");
    assert_ne!(first, second);
    assert!(first >= FIRST_PACKAGE_ID && second >= FIRST_PACKAGE_ID);
    assert!(service::registered().contains(&("one library's", first)));
}

#[test]
fn a_completion_from_a_package_s_id_is_posted_and_one_from_a_core_service_s_is_refused_unposted() {
    let posted = RefCell::new(Vec::new());
    let post = |service, request| {
        posted.borrow_mut().push((service, request));
        true
    };
    assert!(complete_with(FIRST_PACKAGE_ID, 7, post));
    assert!(!complete_with(3, 8, post), "the process service's id");
    assert!(!complete_with(FIRST_PACKAGE_ID - 1, 9, post));
    assert_eq!(posted.into_inner(), [(FIRST_PACKAGE_ID, 7)]);
}

#[test]
fn a_completion_the_queue_refuses_answers_false() {
    assert!(!complete_with(FIRST_PACKAGE_ID + 5, 1, |_, _| false));
}

#[test]
fn a_take_over_answers_a_handle_and_a_second_answers_taken_s_tag() {
    let fake = FakeSource::new();
    let (child, _handle) = taken(&fake);
    assert_eq!(
        take_over_from(&fake, child.id()).map(|_| ()),
        Err(refusal_tag(Refused::Taken))
    );
    assert_eq!(fake.record().taken, [child.id()]);
}

#[test]
fn each_refusal_crosses_as_a_tag_of_its_own() {
    let tags = [
        Refused::NoService,
        Refused::NoSuchChild,
        Refused::ReadPending,
        Refused::Taken,
    ]
    .map(refusal_tag);
    assert_eq!(tags, [1, 2, 3, 4]);
    let fake = FakeSource::new();
    assert_eq!(
        take_over_from(&fake, 99).map(|_| ()),
        Err(refusal_tag(Refused::NoSuchChild))
    );
}

#[test]
fn a_pull_of_lines_and_an_exit_encodes_to_the_documented_words_and_bytes() {
    let fake = FakeSource::new();
    let (child, handle) = taken(&fake);
    child.out(b"one\ntwo\n").err(b"e\n").exit(-2);

    let encoded = pull_from(&handle);

    assert!(encoded.delivered);
    assert_eq!(
        words(&encoded),
        [0, 2, 3, 3, 0, 1, 1, 1, (-2_i64).cast_unsigned(), 0, 0]
    );
    assert_eq!(encoded.bytes, b"onetwoe");
}

#[test]
fn every_end_encodes_its_tag_values_and_words() {
    let ended = |ended| {
        let encoded = encode(Pulled::Delivered(Delivery {
            out: Frames::Bytes(b"xy".to_vec()),
            err: Frames::Messages(vec![b"{}".to_vec()]),
            ended,
        }));
        (words(&encoded), encoded.bytes)
    };
    let frames = [1, 1, 2, 2, 1, 2];
    let with = |end: [u64; 4]| [frames.as_slice(), end.as_slice()].concat();

    assert_eq!(ended(None), (with([0, 0, 0, 0]), b"xy{}".to_vec()));
    assert_eq!(
        ended(Some(Ended::Signalled { signal: 15 })),
        (with([2, 15, 0, 0]), b"xy{}".to_vec())
    );
    assert_eq!(
        ended(Some(Ended::LineTooLong {
            stream: Stream::Err,
            bound: 64
        })),
        (with([3, 1, 64, 0]), b"xy{}".to_vec())
    );
    assert_eq!(
        ended(Some(Ended::MessageTooLong {
            stream: Stream::Out,
            bound: 9
        })),
        (with([4, 0, 9, 0]), b"xy{}".to_vec())
    );
    assert_eq!(
        ended(Some(Ended::Failed("bad".to_owned()))),
        (with([5, 0, 0, 3]), b"xy{}bad".to_vec())
    );
}

#[test]
fn a_pull_of_a_cancelled_child_is_not_delivered_and_lends_nothing() {
    let fake = FakeSource::new();
    let (child, handle) = taken(&fake);
    child.cancel();

    assert_eq!(pull_from(&handle), Encoded::default());
}

#[test]
fn a_write_reaches_the_child_and_a_refused_one_answers_the_words() {
    let fake = FakeSource::new();
    let (child, handle) = taken(&fake);

    assert_eq!(write_to(&handle, b"pong\n"), Ok(()));
    assert_eq!(fake.record().written, [(child.id(), b"pong\n".to_vec())]);

    let closed = fake.child(Framing::Lines, Framing::Lines, 64, false);
    let closed = take_over_from(&fake, closed.id()).expect("taken over");
    let refused = write_to(&closed, b"x").expect_err("no input");
    assert!(!refused.is_empty(), "the platform's words");
}

/// Pulls `handle` through the runtime's C members, reads the record back
/// and hands both buffers back through `buffer_free`.
#[expect(
    unsafe_code,
    reason = "drives the runtime's C members as a library does: a handle, a record filled, and buffers handed back"
)]
fn pulled_through_c(handle: *mut PackageChild) -> Encoded {
    let mut raw = MaybeUninit::<RawPull>::uninit();
    // SAFETY: the handle is live and the record writable; the record is
    // read once filled, and each buffer is handed back once after it is
    // copied.
    unsafe {
        (RUNTIME.child_pull)(handle, raw.as_mut_ptr());
        let raw = raw.assume_init();
        let words = buffer::borrow(raw.words, raw.words_len).to_vec();
        let bytes = buffer::borrow(raw.bytes, raw.bytes_len).to_vec();
        (RUNTIME.buffer_free)(raw.words, raw.words_len);
        (RUNTIME.buffer_free)(raw.bytes, raw.bytes_len);
        Encoded {
            delivered: raw.delivered,
            words,
            bytes,
        }
    }
}

/// Writes `bytes` to `handle` through the runtime's C member: the words
/// of a refusal, read back and handed back once.
#[expect(
    unsafe_code,
    reason = "drives the runtime's C member as a library does: bytes lent, a record filled and handed back"
)]
fn written_through_c(handle: *mut PackageChild, bytes: &[u8]) -> Result<(), Vec<u8>> {
    let mut refused = RawBuffer {
        bytes: ptr::null_mut(),
        len: 0,
    };
    // SAFETY: the handle is live, the bytes are the slice's and the record
    // is writable; a refusal's buffer is copied, then handed back once.
    unsafe {
        if (RUNTIME.child_write)(handle, bytes.as_ptr(), bytes.len(), &mut refused) {
            return Ok(());
        }
        let words = buffer::borrow(refused.bytes, refused.len).to_vec();
        (RUNTIME.buffer_free)(refused.bytes, refused.len);
        Err(words)
    }
}

/// Releases `handle` through the runtime's C member.
#[expect(
    unsafe_code,
    reason = "drives the runtime's C member as a library does: the handle released once"
)]
fn released_through_c(handle: *mut PackageChild) {
    // SAFETY: the handle is live and released this once.
    unsafe { (RUNTIME.child_release)(handle) };
}

#[test]
fn through_the_c_members_a_pull_and_a_write_cross_and_every_lent_buffer_is_handed_back_once() {
    let fake = FakeSource::new();
    let (child, handle) = taken(&fake);
    child.out(b"ping-me\n");
    let handle = Box::into_raw(handle);

    let first = pulled_through_c(handle);
    let written = written_through_c(handle, b"pong\n");
    child.exit(0);
    let ended = pulled_through_c(handle);
    let last = pulled_through_c(handle);
    let after = written_through_c(handle, b"late\n");
    released_through_c(handle);

    assert_eq!(
        (first.delivered, words(&first), first.bytes.as_slice()),
        (true, vec![0, 1, 7, 0, 0, 0, 0, 0, 0], b"ping-me".as_slice())
    );
    assert_eq!(written, Ok(()));
    assert_eq!(
        (ended.delivered, words(&ended), ended.bytes.as_slice()),
        (true, vec![0, 0, 0, 0, 1, 0, 0, 0], b"".as_slice())
    );
    assert_eq!(last, Encoded::default(), "the last delivery was pulled");
    assert!(after.is_err_and(|words| !words.is_empty()));
    assert_eq!(
        fake.record().written,
        [
            (child.id(), b"pong\n".to_vec()),
            (child.id(), b"late\n".to_vec())
        ],
        "both writes reached the child, the second refused"
    );
}

#[test]
fn the_runtime_says_its_own_size() {
    assert_eq!(RUNTIME.size, size_of::<PackageRuntime>());
}

#[test]
fn a_source_with_no_child_refuses_through_the_process_s_source_too() {
    // The process's source is `editor-service`'s static: no library has
    // provided one in this test binary, so it refuses as no service.
    assert_eq!(Provided.take_over(1).map(|_| ()), Err(Refused::NoService));
}
