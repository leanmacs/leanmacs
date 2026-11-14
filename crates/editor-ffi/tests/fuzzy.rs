//! The C function that ranks candidates, called the way the C glue calls
//! it: with raw pointers and an out-record.
//!
//! What matches and in what order are `editor-fuzzy`'s rules over the
//! scorer `editor-fuzzy-nucleo` adapts. So an answer here is compared with
//! what `editor_fuzzy::rank` answers over that scorer for the same pattern
//! and candidates, written as words by this crate's own encoder: what is
//! pinned is that the candidates and the ranking cross. The one case is
//! one both crates' rules fix, whatever the library's scores: of `wq`,
//! `edit` and `w`, the pattern `w` matches the first and the third, and
//! the third is the pattern.

use std::mem::MaybeUninit;
use std::slice;

use editor_ffi::fuzzy::{self, FuzzyStatus, editor_ffi_fuzzy_rank};
use editor_ffi::log::RawWords;
use editor_ffi::text::editor_ffi_text_free;
use editor_fuzzy_nucleo::NucleoScorer;

/// The buffer that holds `words`: each as eight bytes, least significant
/// first.
fn buffer(words: &[u64]) -> Vec<u8> {
    words.iter().flat_map(|word| word.to_le_bytes()).collect()
}

/// What the C function answers for `pattern`, `words` and `strings`: the
/// status, and the bytes of the words, copied out and handed back as the
/// glue does.
fn rank_through_c(pattern: &str, words: &[u8], strings: &[u8]) -> (u64, Vec<u8>) {
    let mut raw = MaybeUninit::<RawWords>::uninit();
    // SAFETY: each pointer and length are those of a slice alive for the
    // call, and `raw` is writable for one record.
    unsafe {
        editor_ffi_fuzzy_rank(
            pattern.as_ptr(),
            pattern.len(),
            words.as_ptr(),
            words.len(),
            strings.as_ptr(),
            strings.len(),
            raw.as_mut_ptr(),
        );
    }
    // SAFETY: the call filled the record.
    let raw = unsafe { raw.assume_init() };
    let answer = if raw.len == 0 {
        Vec::new()
    } else {
        // SAFETY: the record's buffer is `len` bytes, owned by this caller
        // until it is handed back.
        unsafe { slice::from_raw_parts(raw.words, raw.len) }.to_vec()
    };
    // SAFETY: the buffer came from the library in this record, and is
    // handed back once.
    unsafe { editor_ffi_text_free(raw.words, raw.len) };
    (raw.status, answer)
}

#[test]
fn candidates_are_ranked_through_c_as_the_ranking_rule_ranks_them() {
    let candidates = ["wq", "edit", "w"];
    let expected = editor_fuzzy::rank(&mut NucleoScorer::new(), "w", &candidates);
    // The case is not an empty one: two of the three match.
    assert_eq!(expected.len(), 2);

    let (status, answer) = rank_through_c("w", &buffer(&[3, 2, 4, 1]), b"wqeditw");

    assert_eq!(status, FuzzyStatus::Ranked as u64);
    assert_eq!(answer, fuzzy::ranking_words(&expected));
    // The words themselves, once: a count, then the indices.
    assert_eq!(answer, buffer(&[2, 2, 0]));
}

#[test]
fn no_candidates_are_ranked_as_none() {
    let (status, answer) = rank_through_c("w", &buffer(&[0]), b"");

    assert_eq!(status, FuzzyStatus::Ranked as u64);
    assert_eq!(answer, buffer(&[0]));
}

#[test]
fn candidates_that_cannot_be_read_are_refused_with_no_words() {
    // Words that are not whole words.
    let (status, answer) = rank_through_c("w", &[1, 2, 3], b"w");
    assert_eq!(status, FuzzyStatus::Malformed as u64);
    assert_eq!(answer, [0; 0]);

    // Lengths that do not add up to the string.
    let (status, answer) = rank_through_c("w", &buffer(&[1, 5]), b"w");
    assert_eq!(status, FuzzyStatus::Malformed as u64);
    assert_eq!(answer, [0; 0]);

    // A string that is not UTF-8.
    let (status, answer) = rank_through_c("w", &buffer(&[1, 2]), &[b'w', 0xff]);
    assert_eq!(status, FuzzyStatus::Malformed as u64);
    assert_eq!(answer, [0; 0]);

    // No words at all, lent with a null pointer as the glue may.
    let mut raw = MaybeUninit::<RawWords>::uninit();
    // SAFETY: no bytes are lent, which any pointer may do, and `raw` is
    // writable for one record.
    unsafe {
        editor_ffi_fuzzy_rank(
            std::ptr::null(),
            0,
            std::ptr::null(),
            0,
            std::ptr::null(),
            0,
            raw.as_mut_ptr(),
        );
    }
    // SAFETY: the call filled the record.
    let raw = unsafe { raw.assume_init() };
    assert_eq!(raw.status, FuzzyStatus::Malformed as u64);
    assert_eq!(raw.len, 0);
    // SAFETY: the buffer came from the library in this record, and is
    // handed back once.
    unsafe { editor_ffi_text_free(raw.words, raw.len) };
}
