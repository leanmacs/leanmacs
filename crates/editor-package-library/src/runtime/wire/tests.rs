use super::*;

/// The words of `encoded`, read back as numbers.
fn words(encoded: &Encoded) -> Vec<u64> {
    encoded
        .words
        .chunks(8)
        .map(|word| u64::from_le_bytes(word.try_into().expect("whole words")))
        .collect()
}

/// Words as the little-endian bytes they cross as.
fn as_bytes(words: &[u64]) -> Vec<u8> {
    words.iter().flat_map(|word| word.to_le_bytes()).collect()
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

/// One of each way a child ends, and not yet. Written as a match over
/// every variant on purpose: a new way to end must be added to the
/// round trip below, or this stops compiling.
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
fn every_pull_decodes_to_itself() {
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
fn words_that_spell_no_pull_decode_to_none() {
    let delivered = |words: &[u64], bytes: &[u8]| Encoded {
        delivered: true,
        words: as_bytes(words),
        bytes: bytes.to_vec(),
    };
    let cases = [
        delivered(&[0, 1, 3, 0, 0, 0, 0, 0, 0], b"ab"),
        delivered(&[9, 0, 0, 0, 0, 0, 0, 0], b""),
        delivered(&[0, 0, 0, 0, 0, 0, 0, 0, 7], b""),
        delivered(&[0, 0, 0, 0, 6, 0, 0, 0], b""),
        delivered(&[0, 0, 0, 0, 0, 0, 0], b""),
        delivered(&[0, 0, 0, 0, 3, 2, 64, 0], b""),
        delivered(&[0, 0, 0, 0, 1, 1 << 40, 0, 0], b""),
        delivered(&[0, 0, 0, 0, 5, 0, 0, 2], b"\xff\xfe"),
        delivered(&[0, 0, 0, 0, 0, 0, 0, 0], b"left over"),
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
