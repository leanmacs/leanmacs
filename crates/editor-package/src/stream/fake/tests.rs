use std::thread;
use std::time::Duration;

use super::*;
use crate::frame::Frames;
use crate::stream::contract::{UNUSED, check};

/// hang guard: the park each wait ends on, which a pull reaches at once;
/// only a hang reaches the bound, and the test then fails as a hang.
const PARKS: HangGuard = HangGuard::on("a scripted pull's park", Duration::from_secs(10));

/// [`ScriptedChild::wait_pulling`], the readout these tests are of: the one
/// place they call it.
fn parked(child: &ScriptedChild) -> bool {
    #[expect(
        clippy::disallowed_methods,
        reason = "waits for a reader parked in a scripted pull, on `ScriptedChild::wait_pulling`, the readout these tests are of"
    )]
    child.wait_pulling(PARKS)
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
fn a_scripted_child_delivers_its_script_then_cancelled_and_records_its_writes() {
    let child = ScriptedChild::new(true)
        .delivers(&["one"], None)
        .delivers(&["two"], Some(Ended::Exited { code: 2 }));

    assert_eq!(child.pull(), delivered(&["one"], None));
    assert_eq!(child.write(b"ping\n".to_vec()), Ok(()));
    assert_eq!(
        child.pull(),
        delivered(&["two"], Some(Ended::Exited { code: 2 }))
    );
    assert_eq!(child.pull(), Pulled::Cancelled, "its last delivery pulled");
    assert_eq!(
        child.write(b"late\n".to_vec()),
        Err(InputClosed(CLOSED.to_owned())),
        "after its last delivery"
    );
    assert_eq!(child.written(), [b"ping\n".to_vec(), b"late\n".to_vec()]);
}

#[test]
fn a_scripted_child_answers_a_write_with_the_delivery_scripted_for_it() {
    let child = ScriptedChild::new(true).answers(b"go\n", &["go"], Some(Ended::Exited { code: 0 }));

    assert_eq!(child.write(b"other\n".to_vec()), Ok(()));
    assert_eq!(child.write(b"go\n".to_vec()), Ok(()));
    assert_eq!(
        child.pull(),
        delivered(&["go"], Some(Ended::Exited { code: 0 }))
    );
}

#[test]
fn a_scripted_child_without_input_refuses_a_write_with_closed() {
    let child = ScriptedChild::new(false).delivers(&["one"], Some(Ended::Exited { code: 0 }));

    assert_eq!(
        child.write(b"x\n".to_vec()),
        Err(InputClosed(CLOSED.to_owned()))
    );
    assert_eq!(child.written(), [b"x\n".to_vec()], "recorded all the same");
    assert_eq!(
        child.pull(),
        delivered(&["one"], Some(Ended::Exited { code: 0 }))
    );
}

#[test]
fn a_scripted_pull_with_nothing_scripted_parks_until_a_delivery_or_a_cancel() {
    let child = ScriptedChild::new(false);
    thread::scope(|scope| {
        let pulling = scope.spawn(|| child.pull());
        assert!(parked(&child), "the pull parks with nothing scripted");
        child.delivers(&["late"], None);
        assert_eq!(
            pulling.join().expect("the pull's thread"),
            delivered(&["late"], None)
        );

        let pulling = scope.spawn(|| child.pull());
        assert!(parked(&child), "and parks again");
        child.cancel();
        assert_eq!(
            pulling.join().expect("the pull's thread"),
            Pulled::Cancelled
        );
    });
    assert_eq!(child.pull(), Pulled::Cancelled, "and every pull after");
}

#[test]
fn a_scripted_source_refuses_an_unknown_child_an_ended_one_and_a_second_take_over() {
    let source = ScriptedSource::new();
    let ending =
        source.add(ScriptedChild::new(false).delivers(&["x"], Some(Ended::Exited { code: 0 })));
    let gone = ScriptedChild::new(true);
    gone.cancel();
    let cancelled = source.add(gone);

    assert_eq!(source.take_over(UNUSED).err(), Some(Refused::NoSuchChild));
    let streams = source.take_over(ending).expect("taken over");
    assert_eq!(source.take_over(ending).err(), Some(Refused::Taken));
    assert_eq!(
        streams.pull(),
        delivered(&["x"], Some(Ended::Exited { code: 0 }))
    );
    assert_eq!(
        source.take_over(ending).err(),
        Some(Refused::NoSuchChild),
        "its last delivery pulled"
    );
    assert_eq!(
        source.take_over(cancelled).err(),
        Some(Refused::NoSuchChild),
        "cancelled"
    );
    assert_ne!(ending, cancelled, "each child has a number of its own");
}

#[test]
fn the_scripted_source_keeps_the_stream_contract() {
    assert_eq!(check(&ScriptedSource::new()), [""; 0]);
}
