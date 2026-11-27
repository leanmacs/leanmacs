use super::*;

/// Words as the little-endian bytes they cross as.
fn as_bytes(words: &[u64]) -> Vec<u8> {
    words.iter().flat_map(|word| word.to_le_bytes()).collect()
}

/// One of each way a child ends, and not yet. Written as a match over
/// every variant on purpose: a new way to end must be added to the round
/// trip below, or this stops compiling.
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

#[test]
fn every_pull_reads_back_as_it_was_encoded() {
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
    for pull in pulls {
        assert_eq!(
            decode(&encode(pull.clone())),
            Some(pull.clone()),
            "{pull:?}"
        );
    }
}

#[test]
fn each_tag_crosses_as_the_definitions_number_it() {
    let encoded = encode(Pulled::Delivered(Delivery {
        out: Frames::Bytes(b"xy".to_vec()),
        err: Frames::Messages(vec![b"{}".to_vec()]),
        ended: Some(Ended::LineTooLong {
            stream: Stream::Err,
            bound: 64,
        }),
    }));
    assert!(encoded.delivered);
    assert_eq!(
        encoded.words,
        as_bytes(&[
            FRAMING_BYTES,
            1,
            2,
            FRAMING_MESSAGES,
            1,
            2,
            END_LINE_TOO_LONG,
            STREAM_ERR,
            64,
            0
        ])
    );
    assert_eq!(encoded.bytes, b"xy{}");
    assert_eq!(encode(Pulled::Cancelled), Encoded::default());
}

#[test]
fn words_that_cannot_be_read_are_none() {
    let delivered = |words: &[u64], bytes: &[u8]| Encoded {
        delivered: true,
        words: as_bytes(words),
        bytes: bytes.to_vec(),
    };
    let cases = [
        // A frame longer than the bytes there are.
        delivered(&[0, 1, 3, 0, 0, 0, 0, 0, 0], b"ab"),
        // A framing with no tag.
        delivered(&[9, 0, 0, 0, 0, 0, 0, 0], b""),
        // A word left over.
        delivered(&[0, 0, 0, 0, 0, 0, 0, 0, 7], b""),
        // An end with no tag.
        delivered(&[0, 0, 0, 0, 6, 0, 0, 0], b""),
        // A word short.
        delivered(&[0, 0, 0, 0, 0, 0, 0], b""),
        // A stream with no tag.
        delivered(&[0, 0, 0, 0, 3, 2, 64, 0], b""),
        // A status that is no `i32`.
        delivered(&[0, 0, 0, 0, 1, 1 << 40, 0, 0], b""),
        // Failed words that are no UTF-8.
        delivered(&[0, 0, 0, 0, 5, 0, 0, 2], b"\xff\xfe"),
        // Bytes left over.
        delivered(&[0, 0, 0, 0, 0, 0, 0, 0], b"left over"),
        // A count of frames past the words there are.
        delivered(&[0, u64::MAX, 0, 0, 0, 0, 0, 0], b""),
        // Not delivered, yet carrying words.
        Encoded {
            delivered: false,
            words: as_bytes(&[0]),
            bytes: Vec::new(),
        },
    ];
    for case in cases {
        assert_eq!(decode(&case), None, "{case:?}");
    }
}
