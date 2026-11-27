use editor_service::frame::{Frames, Framing};
use editor_service::stream::Pulled;

use super::*;
use crate::runtime::contract::{Calls, check};
use crate::runtime::wire::{Encoded, decode};

#[test]
fn a_model_s_ids_start_at_the_first_package_id_and_two_models_count_apart() {
    let one = ModelRuntime::new();
    let other = ModelRuntime::new();
    let (one_calls, other_calls) = (Calls(one.runtime()), Calls(other.runtime()));

    assert_eq!(one_calls.register("a"), FIRST_PACKAGE_ID);
    assert_eq!(one_calls.register("a"), FIRST_PACKAGE_ID + 1);
    assert_eq!(other_calls.register("b"), FIRST_PACKAGE_ID);
}

#[test]
fn a_completion_is_queued_once_and_a_core_service_s_is_refused() {
    let model = ModelRuntime::new();
    let calls = Calls(model.runtime());

    assert!(calls.complete(FIRST_PACKAGE_ID, 7));
    assert!(!calls.complete(3, 8));

    assert_eq!(model.next_completion(), Some((FIRST_PACKAGE_ID, 7)));
    assert_eq!(model.next_completion(), None);
}

#[test]
fn an_event_is_queued_once_whole_and_a_core_service_s_is_refused() {
    let model = ModelRuntime::new();
    let calls = Calls(model.runtime());

    assert!(calls.post(FIRST_PACKAGE_ID + 2, 9, "héllo"));
    assert!(!calls.post(FIRST_PACKAGE_ID - 1, 9, "spoofed"));

    assert_eq!(
        model.next_event(),
        Some((FIRST_PACKAGE_ID + 2, 9, "héllo".to_owned()))
    );
    assert_eq!(model.next_event(), None);
}

#[test]
fn a_child_of_the_model_s_source_is_taken_over_pulled_and_written_through_the_members() {
    let model = ModelRuntime::new();
    let calls = Calls(model.runtime());
    let child = model
        .source()
        .child(Framing::Lines, Framing::Lines, 64, true);
    child.out(b"one\n");

    let handle = calls.take_over(child.id()).expect("taken over");
    assert_eq!(calls.take_over(child.id()), Err(4), "taken already");
    assert_eq!(calls.take_over(99), Err(2), "no such child");
    let pulled = calls.pull(handle);
    assert_eq!(model.outstanding(), 2, "its words and bytes, lent");
    let encoded = Encoded {
        delivered: pulled.delivered,
        words: calls.read(pulled.words, pulled.words_len),
        bytes: calls.read(pulled.bytes, pulled.bytes_len),
    };
    assert!(calls.free(pulled.words, pulled.words_len));
    assert!(calls.free(pulled.bytes, pulled.bytes_len));
    assert_eq!(calls.write(handle, b"pong\n").map_err(|_| ()), Ok(()));
    calls.release(handle);

    let Some(Pulled::Delivered(delivery)) = decode(&encoded) else {
        panic!("a delivery: {encoded:?}");
    };
    assert_eq!(delivery.out, Frames::Lines(vec![b"one".to_vec()]));
    assert_eq!(
        model.source().record().written,
        [(child.id(), b"pong\n".to_vec())]
    );
    assert_eq!(model.outstanding(), 0);
}

#[test]
fn a_buffer_the_model_lends_is_reclaimed_once() {
    let model = ModelRuntime::new();
    let calls = Calls(model.runtime());

    let lent = calls.lend(b"abc");
    assert_eq!(calls.read(lent.bytes, lent.len), b"abc");
    assert_eq!(model.outstanding(), 1);
    assert!(calls.free(lent.bytes, lent.len));
    assert!(!calls.free(lent.bytes, lent.len));
    assert_eq!(model.outstanding(), 0);
}

#[test]
fn a_later_model_is_larger_with_the_same_members_where_they_were() {
    let current = ModelRuntime::new();
    let later = ModelRuntime::later();

    assert_eq!(current.runtime().size, size_of::<PackageRuntime>());
    assert!(later.runtime().size > size_of::<PackageRuntime>());
    assert_eq!(Calls(later.runtime()).register("x"), FIRST_PACKAGE_ID);
}

#[test]
fn the_model_keeps_the_runtime_s_contract() {
    assert_eq!(check(&ModelRig::new()), [""; 0]);
}

#[test]
fn a_later_model_keeps_the_runtime_s_contract() {
    assert_eq!(check(&ModelRig::later()), [""; 0]);
}
