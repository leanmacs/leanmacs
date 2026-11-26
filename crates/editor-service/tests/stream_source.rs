//! The process's one stream source ([`stream::provide`],
//! [`stream::take_over`]): refused until one is provided, provided once,
//! and then the one every take-over reaches.
//!
//! An integration test of its own, because the source is process-wide: no
//! other test of this crate provides one, so the order below is this
//! test's alone. The rules of a source itself are the contract's, run on
//! the fake in the crate's unit tests.

use editor_service::frame::{Frames, Framing};
use editor_service::stream::fake::FakeSource;
use editor_service::stream::{self, Delivery, Ended, Pulled, Refused};

#[test]
fn a_take_over_is_refused_until_a_source_is_provided_once_and_then_reaches_it() {
    let before = stream::take_over(1).err();

    let fake: &'static FakeSource = Box::leak(Box::new(FakeSource::new()));
    let child = fake.child(Framing::Lines, Framing::Lines, 64, false);
    child.out(b"one\n").exit(0);
    let first = stream::provide(fake);
    let second = stream::provide(Box::leak(Box::new(FakeSource::new())));
    let taken = stream::take_over(child.id()).map(|streams| streams.pull());

    assert_eq!(before, Some(Refused::NoService));
    assert!(first, "the first source is provided");
    assert!(!second, "a second changes nothing");
    assert_eq!(
        taken,
        Ok(Pulled::Delivered(Delivery {
            out: Frames::Lines(vec![b"one".to_vec()]),
            err: Frames::Lines(Vec::new()),
            ended: Some(Ended::Exited { code: 0 }),
        })),
        "the take-over reached the first source's child"
    );
    assert_eq!(fake.record().taken, [child.id()]);
}
