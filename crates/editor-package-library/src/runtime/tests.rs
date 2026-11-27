use std::cell::RefCell;
use std::mem::MaybeUninit;
use std::ptr;

use editor_service::frame::Framing;
use editor_service::stream::StreamSource;
use editor_service::stream::fake::FakeSource;

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
fn taken(fake: &FakeSource) -> (editor_service::stream::fake::FakeChild, Box<TakenChild>) {
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
fn an_event_from_a_package_s_id_is_posted_and_one_from_a_core_service_s_is_refused_unposted() {
    let posted = RefCell::new(Vec::new());
    let post = |service, code, text| {
        posted.borrow_mut().push((service, code, text));
        true
    };
    assert!(post_event_with(
        FIRST_PACKAGE_ID,
        7,
        "héllo".to_owned(),
        post
    ));
    assert!(!post_event_with(3, 8, "core".to_owned(), post));
    assert!(!post_event_with(
        FIRST_PACKAGE_ID - 1,
        9,
        "core".to_owned(),
        post
    ));
    assert_eq!(
        posted.into_inner(),
        [(FIRST_PACKAGE_ID, 7, "héllo".to_owned())]
    );
}

#[test]
fn an_event_the_queue_refuses_answers_false() {
    assert!(!post_event_with(
        FIRST_PACKAGE_ID + 5,
        1,
        String::new(),
        |_, _, _| false
    ));
}

#[test]
fn each_tag_reads_back_as_its_refusal_and_no_other_tag_as_any() {
    for refused in [
        Refused::NoService,
        Refused::NoSuchChild,
        Refused::ReadPending,
        Refused::Taken,
    ] {
        assert_eq!(refused_of_tag(refusal_tag(refused)), Some(refused));
    }
    assert_eq!(refused_of_tag(0), None);
    assert_eq!(refused_of_tag(5), None);
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
    let runtime = &raw const RUNTIME;
    let mut raw = MaybeUninit::<RawPull>::uninit();
    // SAFETY: the handle is live and the record writable; the record is
    // read once filled, and each buffer is handed back once after it is
    // copied.
    unsafe {
        (RUNTIME.child_pull)(runtime, handle, raw.as_mut_ptr());
        let raw = raw.assume_init();
        let words = buffer::borrow(raw.words, raw.words_len).to_vec();
        let bytes = buffer::borrow(raw.bytes, raw.bytes_len).to_vec();
        assert!((RUNTIME.buffer_free)(runtime, raw.words, raw.words_len));
        assert!((RUNTIME.buffer_free)(runtime, raw.bytes, raw.bytes_len));
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
        let runtime = &raw const RUNTIME;
        if (RUNTIME.child_write)(runtime, handle, bytes.as_ptr(), bytes.len(), &mut refused) {
            return Ok(());
        }
        let words = buffer::borrow(refused.bytes, refused.len).to_vec();
        assert!((RUNTIME.buffer_free)(runtime, refused.bytes, refused.len));
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
    unsafe { (RUNTIME.child_release)(&raw const RUNTIME, handle) };
}

#[test]
fn through_the_c_members_a_pull_and_a_write_cross_and_every_lent_buffer_is_handed_back_once() {
    let fake = FakeSource::new();
    let (child, handle) = taken(&fake);
    child.out(b"ping-me\n");
    let handle = Box::into_raw(handle).cast::<PackageChild>();

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
fn the_runtime_says_its_own_size_and_keeps_no_private_members() {
    assert_eq!(RUNTIME.size, size_of::<PackageRuntime>());
    assert!(RUNTIME.private_members.is_null());
}

/// Lends `bytes` through the runtime's C member, and reads the buffer back.
#[expect(
    unsafe_code,
    reason = "drives the runtime's C member as a library does: bytes lent for the call, a record filled and read"
)]
fn lent_through_c(bytes: &[u8]) -> (RawBuffer, Vec<u8>) {
    let mut out = RawBuffer {
        bytes: ptr::null_mut(),
        len: 0,
    };
    // SAFETY: the bytes are the slice's for the call, the record writable,
    // and the buffer read while it is lent.
    unsafe {
        (RUNTIME.buffer_lend)(&raw const RUNTIME, bytes.as_ptr(), bytes.len(), &mut out);
        (out, buffer::borrow(out.bytes, out.len).to_vec())
    }
}

/// Hands `lent` back through the runtime's C member.
#[expect(
    unsafe_code,
    reason = "drives the runtime's C member as a library does: a buffer the core lent, handed back"
)]
fn freed_through_c(lent: RawBuffer) -> bool {
    // SAFETY: the buffer is one the runtime lent, handed back this once.
    unsafe { (RUNTIME.buffer_free)(&raw const RUNTIME, lent.bytes, lent.len) }
}

// The tests of this binary run in parallel and share the process's ledger,
// so none hands a buffer back twice here: an address freed by one test may
// be lent again to another before the second hand-back. A second hand-back
// is pinned on a ledger of its own (`ledger`'s tests) and by the contract
// (`tests/contract.rs`, alone in its binary).
#[test]
fn a_buffer_lent_through_the_c_member_reads_back_and_is_handed_back() {
    let (lent, read) = lent_through_c("héllo".as_bytes());
    assert_eq!(read, "héllo".as_bytes());
    assert!(freed_through_c(lent));
}

#[test]
fn a_pointer_the_runtime_never_lent_is_refused() {
    let mut own = *b"never lent";
    assert!(!freed_through_c(RawBuffer {
        bytes: own.as_mut_ptr(),
        len: own.len(),
    }));
    assert_eq!(&own, b"never lent");
}

#[test]
fn a_source_with_no_child_refuses_through_the_process_s_source_too() {
    // The process's source is `editor-service`'s static: no library has
    // provided one in this test binary, so it refuses as no service.
    assert_eq!(Provided.take_over(1).map(|_| ()), Err(Refused::NoService));
}
