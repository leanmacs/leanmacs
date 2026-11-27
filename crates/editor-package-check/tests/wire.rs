//! The wrapper's wire against the core's: a pull the core's runtime
//! encodes (`editor_package_library::runtime::wire::encode`) reads back
//! through the wrapper's decoder (`editor_package::wire::decode`), which
//! is the wrapper's real path, and one the wrapper's fake encodes reads
//! back through the core's decoder, for every way to frame and to end.

mod support;

use editor_package::wire as wrapper_wire;
use editor_package_library::runtime::wire as core_wire;
use editor_service::frame::{Frames, Stream};
use editor_service::stream::{Delivery, Ended, Pulled};

/// One of each way a child ends, and not yet. A match over every variant
/// on purpose: a new way to end must be added here, or this stops
/// compiling.
fn every_end() -> Vec<Option<Ended>> {
    let ends = [
        Ended::Exited { code: -2 },
        Ended::Signalled { signal: 9 },
        Ended::LineTooLong {
            stream: Stream::Out,
            bound: 64,
        },
        Ended::MessageTooLong {
            stream: Stream::Err,
            bound: u64::MAX,
        },
        Ended::Failed("héllo".to_owned()),
    ];
    for end in &ends {
        match end {
            Ended::Exited { .. }
            | Ended::Signalled { .. }
            | Ended::LineTooLong { .. }
            | Ended::MessageTooLong { .. }
            | Ended::Failed(_) => {}
        }
    }
    std::iter::once(None).chain(ends.map(Some)).collect()
}

/// One of each framing, with frames, and empty. A match over every variant
/// on purpose, as [`every_end`].
fn every_framing() -> Vec<Frames> {
    let frames = vec![
        Frames::Lines(vec![b"one".to_vec(), Vec::new(), b"three".to_vec()]),
        Frames::Lines(Vec::new()),
        Frames::Bytes(b"\0raw\xff".to_vec()),
        Frames::Bytes(Vec::new()),
        Frames::Messages(vec![b"{}".to_vec(), b"hello".to_vec()]),
        Frames::Messages(Vec::new()),
    ];
    for framing in &frames {
        match framing {
            Frames::Lines(_) | Frames::Bytes(_) | Frames::Messages(_) => {}
        }
    }
    frames
}

/// Every pull: cancelled, and a delivery of each framing on each stream
/// with each end.
fn every_pull() -> Vec<Pulled> {
    let mut pulls = vec![Pulled::Cancelled];
    for out in every_framing() {
        for err in every_framing() {
            for ended in every_end() {
                pulls.push(Pulled::Delivered(Delivery {
                    out: out.clone(),
                    err: err.clone(),
                    ended,
                }));
            }
        }
    }
    pulls
}

#[test]
fn the_wrapper_reads_every_pull_the_core_encodes() {
    for pull in every_pull() {
        let encoded = core_wire::encode(pull.clone());
        let crossed = wrapper_wire::Encoded {
            delivered: encoded.delivered,
            words: encoded.words,
            bytes: encoded.bytes,
        };
        assert_eq!(
            wrapper_wire::decode(&crossed),
            Some(support::pulled(pull.clone())),
            "{pull:?}"
        );
    }
}

#[test]
fn the_core_reads_every_pull_the_wrapper_encodes() {
    for pull in every_pull() {
        let encoded = wrapper_wire::encode(support::pulled(pull.clone()));
        let crossed = core_wire::Encoded {
            delivered: encoded.delivered,
            words: encoded.words,
            bytes: encoded.bytes,
        };
        assert_eq!(core_wire::decode(&crossed), Some(pull.clone()), "{pull:?}");
    }
}
