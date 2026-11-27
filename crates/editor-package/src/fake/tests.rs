use std::ffi::c_void;
use std::mem::size_of;
use std::ptr;
use std::sync::atomic::{AtomicPtr, Ordering};
use std::thread;
use std::time::Duration;

use editor_package_runtime::{
    INIT_LOADED, PackageRuntime, TAKE_OVER_NO_SUCH_CHILD, TAKE_OVER_TAKEN,
};

use super::*;
use crate::buffer::CoreBuffer;
use crate::frame::Frames;
use crate::runtime::{Calls, REQUIRED};
use crate::stream::fake::ScriptedChild;
use crate::stream::{Delivery, Ended, Pulled};
use crate::wire::{Encoded, decode};

/// hang guard: the completion each wait ends on, posted from another
/// thread; only a hang reaches the bound, and the test then fails as one.
const COMPLETED: HangGuard = HangGuard::on("a completion posted", Duration::from_secs(10));

/// A guard run out on purpose: a completion of another request is held,
/// and the one waited for never comes.
const NEVER: HangGuard = HangGuard::held("a completion never posted", Duration::ZERO);

/// The members of a fresh fake's runtime, and the fake.
fn fake() -> (&'static FakeRuntime, Calls) {
    let fake = FakeRuntime::new().leak();
    (fake, Calls::over(fake.raw()))
}

/// The bytes of a buffer the runtime of `calls` lent, read and handed back.
fn taken(calls: Calls, bytes: *mut u8, len: usize) -> Vec<u8> {
    CoreBuffer::lent(calls, bytes, len).as_bytes().to_vec()
}

#[test]
fn a_fake_s_ids_start_at_the_first_package_id_and_two_fakes_count_apart() {
    let (one, one_calls) = fake();
    let (other, other_calls) = fake();

    assert_eq!(one_calls.register(b"a"), 1024);
    assert_eq!(one_calls.register("é".as_bytes()), 1025);
    assert_eq!(other_calls.register(b"b"), 1024);
    assert_eq!(
        one.services(),
        [("a".to_owned(), 1024), ("é".to_owned(), 1025)]
    );
    assert_eq!(other.services(), [("b".to_owned(), 1024)]);
}

#[test]
fn a_completion_or_event_is_queued_once_and_a_core_service_s_is_refused() {
    let (fake, calls) = fake();

    assert!(calls.complete(1024, 7));
    assert!(!calls.complete(1023, 8), "a core service's id");
    assert!(calls.post(1030, 9, "héllo".as_bytes()));
    assert!(!calls.post(3, 9, b"spoofed"));

    assert_eq!(fake.next_completion(), Some((1024, 7)));
    assert_eq!(fake.next_completion(), None);
    assert_eq!(fake.next_event(), Some((1030, 9, "héllo".to_owned())));
    assert_eq!(fake.next_event(), None);
}

#[test]
fn a_wait_for_a_completion_answers_once_it_is_posted_on_another_thread() {
    let (fake, calls) = fake();
    assert!(calls.complete(1024, 4), "another request's");
    let posting = thread::spawn(move || calls.complete(1024, 9));

    assert!(fake.wait_completed(1024, 9, COMPLETED));
    assert!(posting.join().expect("the posting thread"));
    assert!(!fake.wait_completed(1025, 9, NEVER), "another service's");
    assert_eq!(fake.next_completion(), Some((1024, 4)));
    assert_eq!(fake.next_completion(), Some((1024, 9)));
}

#[test]
fn a_lent_buffer_is_reclaimed_once_and_a_pointer_never_lent_is_refused() {
    let (fake, calls) = fake();

    let lent = calls.lend(b"abc");
    let empty = calls.lend(b"");
    assert_eq!(fake.outstanding(), 2);
    assert!(calls.free(lent.bytes, lent.len));
    assert!(!calls.free(lent.bytes, lent.len), "handed back already");
    let mut own = *b"own";
    assert!(!calls.free(own.as_mut_ptr(), own.len()), "never lent");
    assert_eq!(&own, b"own");
    assert_eq!(fake.outstanding(), 1);
    assert_eq!(taken(calls, empty.bytes, empty.len), b"");
    assert_eq!(fake.outstanding(), 0);
}

#[test]
fn a_child_is_taken_over_pulled_written_and_released_through_the_members() {
    let source = ScriptedSource::new();
    let scripted = ScriptedChild::new(true)
        .delivers(&["one"], None)
        .delivers(&["two"], Some(Ended::Exited { code: 3 }));
    let child = source.add(scripted.clone());
    let fake = FakeRuntime::over(Box::leak(Box::new(source))).leak();
    let calls = Calls::over(fake.raw());

    let handle = calls.take_over(child).expect("taken over");
    assert_eq!(calls.take_over(child), Err(TAKE_OVER_TAKEN));
    assert_eq!(calls.take_over(99), Err(TAKE_OVER_NO_SUCH_CHILD));

    let pull = || {
        let raw = calls.pull(handle);
        let encoded = Encoded {
            delivered: raw.delivered,
            words: taken(calls, raw.words, raw.words_len),
            bytes: taken(calls, raw.bytes, raw.bytes_len),
        };
        decode(&encoded)
    };
    let line = |line: &str, ended| {
        Some(Pulled::Delivered(Delivery {
            out: Frames::Lines(vec![line.as_bytes().to_vec()]),
            err: Frames::Lines(Vec::new()),
            ended,
        }))
    };
    assert_eq!(pull(), line("one", None));
    assert!(calls.write(handle, b"pong\n").is_ok());
    assert_eq!(pull(), line("two", Some(Ended::Exited { code: 3 })));
    let refused = calls.write(handle, b"late\n").expect_err("ended");
    assert_eq!(
        taken(calls, refused.bytes, refused.len),
        crate::stream::fake::CLOSED.as_bytes()
    );
    assert_eq!(pull(), Some(Pulled::Cancelled));
    calls.release(handle);

    assert_eq!(scripted.written(), [b"pong\n".to_vec(), b"late\n".to_vec()]);
    assert_eq!(fake.outstanding(), 0, "every lent buffer handed back");
}

#[test]
fn a_later_fake_is_larger_and_a_sized_fake_says_its_size() {
    let current = FakeRuntime::new().leak();
    let later = FakeRuntime::new().later().leak();
    let small = FakeRuntime::new().sized(REQUIRED - 8).leak();

    assert_eq!(current.raw().size, size_of::<PackageRuntime>());
    assert!(later.raw().size > size_of::<PackageRuntime>());
    assert_eq!(small.raw().size, REQUIRED - 8);
    assert_eq!(Calls::over(later.raw()).register(b"x"), 1024);
}

/// The runtime the init below was handed.
static HANDED: AtomicPtr<PackageRuntime> = AtomicPtr::new(ptr::null_mut());

/// A table the init below writes.
static TABLE: u64 = 7;

/// An init written as a library's is: it keeps the runtime it is handed
/// and writes its table.
///
/// # Safety
///
/// `table` points to a writable pointer.
#[expect(
    unsafe_code,
    reason = "an init as a library writes one: it writes its table where the caller says"
)]
unsafe extern "C" fn init(runtime: *const PackageRuntime, table: *mut *const c_void) -> u32 {
    HANDED.store(runtime.cast_mut(), Ordering::SeqCst);
    // SAFETY: the caller hands a writable place.
    unsafe { table.write(ptr::from_ref(&TABLE).cast()) };
    INIT_LOADED
}

#[test]
fn an_init_is_handed_the_fake_and_a_writable_place() {
    let fake = FakeRuntime::new().leak();

    let (status, table) = fake.init(init);

    assert_eq!(status, INIT_LOADED);
    assert_eq!(table, ptr::from_ref(&TABLE).cast());
    assert_eq!(
        HANDED.load(Ordering::SeqCst).cast_const(),
        ptr::from_ref(fake.raw())
    );
}
