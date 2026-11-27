use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use editor_package_runtime::RawPull;
use editor_wait::HangGuard;

use super::*;
use crate::fake::FakeRuntime;
use crate::frame::Frames;
use crate::service::completer_contract;
use crate::stream::contract::{Ground, Scenario, check};
use crate::stream::fake::{CLOSED, ScriptedChild, ScriptedSource};
use crate::stream::{ChildStreams, Delivery, Ended, InputClosed, Pulled, Refused, StreamSource};
use crate::wire::UNREADABLE;

/// A fake over `source`, leaked, and its runtime.
fn over(source: impl StreamSource + 'static) -> (&'static FakeRuntime, Runtime) {
    let fake = FakeRuntime::over(Box::leak(Box::new(source))).leak();
    (fake, fake.runtime())
}

/// A delivery of `lines` of standard output, and `ended`.
fn delivered(lines: &[&str], ended: Option<Ended>) -> Pulled {
    Pulled::Delivered(Delivery {
        out: Frames::Lines(lines.iter().map(|line| line.as_bytes().to_vec()).collect()),
        err: Frames::Lines(Vec::new()),
        ended,
    })
}

#[test]
fn a_service_registered_through_the_runtime_completes_and_posts_on_the_fake() {
    let fake = FakeRuntime::new().leak();
    let runtime = fake.runtime();

    let service = runtime.register("héllo");
    let other = runtime.register("other");

    assert_eq!((service.id(), other.id()), (1024, 1025));
    assert_eq!(
        fake.services(),
        [("héllo".to_owned(), 1024), ("other".to_owned(), 1025)]
    );
    assert!(service.complete(7));
    assert!(service.post(3, "words"));
    assert_eq!(fake.next_completion(), Some((1024, 7)));
    assert_eq!(fake.next_event(), Some((1024, 3, "words".to_owned())));
    assert_eq!(runtime.size(), fake.raw().size);
}

/// A source over a scripted one whose children count their drops: how a
/// test sees that a handle was released.
struct Counted {
    /// The scripted source.
    scripted: ScriptedSource,
    /// How many children taken over were dropped.
    dropped: Arc<AtomicUsize>,
}

/// A child of [`Counted`]'s.
struct CountedChild {
    /// The scripted child.
    streams: Box<dyn ChildStreams>,
    /// Counted up once, when it drops.
    dropped: Arc<AtomicUsize>,
}

impl StreamSource for Counted {
    fn take_over(&self, child: u64) -> Result<Box<dyn ChildStreams>, Refused> {
        let streams = self.scripted.take_over(child)?;
        Ok(Box::new(CountedChild {
            streams,
            dropped: Arc::clone(&self.dropped),
        }))
    }
}

impl ChildStreams for CountedChild {
    fn pull(&self) -> Pulled {
        self.streams.pull()
    }

    fn write(&self, bytes: Vec<u8>) -> Result<(), InputClosed> {
        self.streams.write(bytes)
    }
}

impl Drop for CountedChild {
    fn drop(&mut self) {
        self.dropped.fetch_add(1, Ordering::SeqCst);
    }
}

#[test]
fn a_taken_over_child_is_pulled_written_and_released_with_every_core_buffer_handed_back() {
    let scripted = ScriptedSource::new();
    let script = ScriptedChild::new(true)
        .delivers(&["one"], None)
        .delivers(&["two"], Some(Ended::Exited { code: 3 }));
    let number = scripted.add(script.clone());
    let dropped = Arc::new(AtomicUsize::new(0));
    let (fake, runtime) = over(Counted {
        scripted,
        dropped: Arc::clone(&dropped),
    });

    let child = runtime.take_over(number).expect("taken over");
    assert_eq!(child.pull(), delivered(&["one"], None));
    assert_eq!(child.write(b"pong\n".to_vec()), Ok(()));
    assert_eq!(
        child.pull(),
        delivered(&["two"], Some(Ended::Exited { code: 3 }))
    );
    assert_eq!(child.pull(), Pulled::Cancelled);
    assert_eq!(fake.outstanding(), 0, "each pull's buffers handed back");
    assert_eq!(dropped.load(Ordering::SeqCst), 0, "not yet released");
    drop(child);

    assert_eq!(dropped.load(Ordering::SeqCst), 1, "released once");
    assert_eq!(script.written(), [b"pong\n".to_vec()]);
}

/// A source that refuses every take-over as `0`.
struct Refusing(Refused);

impl StreamSource for Refusing {
    fn take_over(&self, _: u64) -> Result<Box<dyn ChildStreams>, Refused> {
        Err(self.0)
    }
}

#[test]
fn a_refused_take_over_crosses_as_its_refusal() {
    for refused in [
        Refused::NoService,
        Refused::NoSuchChild,
        Refused::ReadPending,
        Refused::Taken,
    ] {
        let (_, runtime) = over(Refusing(refused));
        assert_eq!(runtime.take_over(1).err(), Some(refused));
        assert_eq!(
            StreamSource::take_over(&runtime, 1).err(),
            Some(refused),
            "as a stream source"
        );
    }
    let fake = FakeRuntime::new().leak();
    let unknown = patched(fake, |runtime| runtime.take_over = unknown_take_over);
    assert_eq!(
        unknown.take_over(1).err(),
        Some(Refused::NoService),
        "a tag no refusal crosses as"
    );
}

#[test]
fn a_refused_write_reads_the_platform_s_words() {
    let scripted = ScriptedSource::new();
    let number = scripted.add(ScriptedChild::new(false).delivers(&["x"], None));
    let (fake, runtime) = over(scripted);

    let child = runtime.take_over(number).expect("taken over");

    assert_eq!(
        child.write(b"x\n".to_vec()),
        Err(InputClosed(CLOSED.to_owned()))
    );
    assert_eq!(fake.outstanding(), 0, "the words handed back");
}

/// A runtime of `fake`'s members with `patch` applied to a copy of them,
/// kept for the process: its state is still the fake's.
fn patched(fake: &'static FakeRuntime, patch: impl FnOnce(&mut PackageRuntime)) -> Runtime {
    let raw = fake.raw();
    let mut runtime = PackageRuntime {
        size: raw.size,
        private_members: raw.private_members,
        register_service: raw.register_service,
        complete: raw.complete,
        post_event: raw.post_event,
        take_over: raw.take_over,
        child_pull: raw.child_pull,
        child_write: raw.child_write,
        child_release: raw.child_release,
        buffer_lend: raw.buffer_lend,
        buffer_free: raw.buffer_free,
    };
    patch(&mut runtime);
    Runtime::over(Box::leak(Box::new(runtime)))
}

/// A `take_over` that answers a tag no refusal crosses as.
extern "C" fn unknown_take_over(
    _: *const PackageRuntime,
    _: u64,
    _: *mut *mut PackageChild,
) -> u32 {
    9
}

/// A `child_pull` that lends words no pull is encoded as: a framing with no
/// tag, through the runtime's own `buffer_lend`.
///
/// # Safety
///
/// `runtime` is a whole runtime that lives for the process, and `out`
/// points to a writable [`RawPull`].
#[expect(
    unsafe_code,
    reason = "a runtime's member as a broken core would write it: it lends words no pull is encoded as, into the library's record"
)]
unsafe extern "C" fn unreadable_pull(
    runtime: *const PackageRuntime,
    _: *mut PackageChild,
    out: *mut RawPull,
) {
    // SAFETY: the runtime is whole and lives for the process.
    let calls = Calls::over(unsafe { &*runtime });
    let words = calls.lend(&9_u64.to_le_bytes());
    let bytes = calls.lend(b"");
    let pull = RawPull {
        delivered: true,
        words: words.bytes,
        words_len: words.len,
        bytes: bytes.bytes,
        bytes_len: bytes.len,
    };
    // SAFETY: the caller hands a writable record.
    unsafe { out.write(pull) };
}

#[test]
fn an_unreadable_pull_delivers_a_failure() {
    let scripted = ScriptedSource::new();
    let number = scripted.add(ScriptedChild::new(false).delivers(&["x"], None));
    let fake = FakeRuntime::over(Box::leak(Box::new(scripted))).leak();
    let runtime = patched(fake, |runtime| runtime.child_pull = unreadable_pull);

    let child = runtime.take_over(number).expect("taken over");

    assert_eq!(
        child.pull(),
        Pulled::Delivered(Delivery {
            out: Frames::Lines(Vec::new()),
            err: Frames::Lines(Vec::new()),
            ended: Some(Ended::Failed(UNREADABLE.to_owned())),
        })
    );
    assert_eq!(fake.outstanding(), 0, "its words handed back all the same");
}

#[test]
fn a_lent_core_buffer_is_handed_back_on_drop() {
    let fake = FakeRuntime::new().leak();

    let lent = fake.runtime().lend("héllo".as_bytes());
    assert_eq!(lent.as_bytes(), "héllo".as_bytes());
    assert_eq!(fake.outstanding(), 1);
    drop(lent);

    assert_eq!(fake.outstanding(), 0);
}

/// The stream contract's ground over the scripted source, its source the
/// runtime over a fake over that scripted source: every take-over, pull
/// and write crosses the fake's C members and the wire.
struct OverRuntime {
    /// The scripted source the children are opened on.
    scripted: &'static ScriptedSource,
    /// The runtime they are taken over through.
    runtime: Runtime,
}

impl Ground for OverRuntime {
    fn source(&self) -> &dyn StreamSource {
        &self.runtime
    }

    fn open(&self, scenario: Scenario) -> Option<u64> {
        self.scripted.open(scenario)
    }

    fn cancel(&self, child: u64) {
        self.scripted.cancel(child);
    }

    #[expect(
        clippy::disallowed_methods,
        reason = "the stream contract's ground over the runtime over the fake: whether a reader is parked in a pull, on `ScriptedChild::wait_pulling`"
    )]
    fn wait_pulling(&self, child: u64) -> bool {
        self.scripted
            .child(child)
            .is_some_and(|scripted| scripted.wait_pulling(self.deadline()))
    }

    fn deadline(&self) -> HangGuard {
        self.scripted.deadline()
    }
}

#[test]
fn a_runtime_over_the_fake_keeps_the_stream_contract() {
    let scripted: &'static ScriptedSource = Box::leak(Box::new(ScriptedSource::new()));
    let fake = FakeRuntime::over(scripted).leak();

    assert_eq!(
        check(&OverRuntime {
            scripted,
            runtime: fake.runtime(),
        }),
        [""; 0]
    );
    assert_eq!(fake.outstanding(), 0, "every lent buffer handed back");
}

#[test]
fn a_service_over_the_fake_runtime_keeps_the_completer_contract() {
    let fake = FakeRuntime::new().leak();
    let service = fake.runtime().register("completing");

    let delivered = || {
        std::iter::from_fn(|| fake.next_completion())
            .filter(|&(id, _)| id == service.id())
            .map(|(_, request)| request)
            .collect()
    };
    assert_eq!(completer_contract(&service, delivered), [""; 0]);
}
