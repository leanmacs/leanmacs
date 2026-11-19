//! Fuzzy ranking as it crosses the boundary: a pattern and candidates in,
//! the indices of the candidates the pattern matches out, best first.
//!
//! The candidates are a list of strings, and cross as lists do (the
//! private module `words`) with one string beside them:
//!
//! - **candidates in** ([`editor_ffi_fuzzy_rank`]): words, the count of
//!   candidates and then the byte length of each; and one string, every
//!   candidate end to end, in the same order. Both are borrowed for the
//!   call.
//! - **a ranking out**, in a [`RawWords`]: the count of candidates the
//!   pattern matches, then the index of each among the candidates, best
//!   first.
//!
//! The candidates are trusted no more than any words are. Words that
//! cannot be read, lengths that do not add up to the string, a length that
//! ends inside a character, and a string that is not UTF-8 are one
//! refusal, [`FuzzyStatus::Malformed`], with no words: never a panic, and
//! nothing allocated by a count that was not checked.
//!
//! The call is stateless. It makes the scorer port's real adapter
//! (`editor-fuzzy-nucleo`) for the call, asks `editor-fuzzy`'s `rank` and
//! keeps nothing: there is no handle and no static. What matches, and in
//! what order, are those two crates' rules, pinned by their own tests.
//! That a pattern and candidates of any length are answered, and not a
//! panic of the matching library's, is the adapter's to keep (its crate
//! docs, "The library's limit") and is pinned there. This module takes the candidates apart, forwards and writes the words.
//!
//! # Locating a pattern
//!
//! [`editor_ffi_fuzzy_locate`] is the other call, and keeps nothing either:
//! a pattern, a text, the byte offset where the pattern is expected and the
//! most errors allowed in; whether a span was found, and its byte range in
//! a [`ByteRange`], out. It makes the searcher port's real adapter
//! (`editor-fuzzy-triple-accel`) for the call and asks `editor-fuzzy`'s
//! `locate::locate`, whose rule (fewest errors, then nearest, earliest,
//! longest, never a span that cuts a character) is pinned by that crate's
//! tests. A pattern or a text that is not UTF-8, which includes a length
//! that ends inside a character, is answered not found: a Lean string is
//! always UTF-8, so only a glue that is wrong sends one.

use editor_fuzzy_nucleo::NucleoScorer;
use editor_fuzzy_triple_accel::TripleAccel;

use crate::log::RawWords;
use crate::text::ByteRange;
use crate::words::{self, Reader, Writer};

/// How a ranking ended, as it crosses the boundary: the `status` of the
/// [`RawWords`] that [`editor_ffi_fuzzy_rank`] fills.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FuzzyStatus {
    /// Ranked. The record's words are the ranking.
    Ranked = 0,
    /// Refused: the words and the string do not spell a list of
    /// candidates.
    Malformed = 1,
}

/// The candidates that `words` and `strings` spell, in the layout the
/// module docs give. `None` when they spell none: `words` is not whole
/// words, its count runs past it, words are left over, the lengths do not
/// add up to `strings`, or a length ends inside a character.
pub(crate) fn candidates<'a>(words: &[u8], strings: &'a str) -> Option<Vec<&'a str>> {
    let mut reader = Reader::new(words)?;
    let count = reader.count(1)?;
    let mut candidates = Vec::with_capacity(count);
    let mut start = 0_usize;
    for _ in 0..count {
        let end = start.checked_add(reader.size()?)?;
        // `get` refuses a range past the string's end and one that cuts a
        // character.
        candidates.push(strings.get(start..end)?);
        start = end;
    }
    reader.finish()?;
    (start == strings.len()).then_some(candidates)
}

/// The words of a ranking, in the layout the module docs give: the count
/// of `indices`, then each.
pub fn ranking_words(indices: &[usize]) -> Vec<u8> {
    let mut writer = Writer::with_capacity(1 + indices.len());
    writer.size(indices.len());
    for &index in indices {
        writer.size(index);
    }
    writer.finish()
}

/// Ranks for C: fills `out` with the indices of the candidates that the
/// `pattern_len` bytes at `pattern` match, best first, as words, and the
/// status [`FuzzyStatus::Ranked`]; or with no words and the status
/// [`FuzzyStatus::Malformed`] when the `words_len` bytes at `words` and
/// the `strings_len` bytes at `strings` spell no list of candidates.
///
/// # Safety
///
/// `pattern` points to `pattern_len` readable bytes, `words` to
/// `words_len` and `strings` to `strings_len`, all unchanged for the call
/// (no bytes at all may be lent with any pointer), and `out` points to a
/// writable [`RawWords`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_fuzzy_rank(
    pattern: *const u8,
    pattern_len: usize,
    words: *const u8,
    words_len: usize,
    strings: *const u8,
    strings_len: usize,
    out: *mut RawWords,
) {
    // SAFETY: the caller guarantees each pointer and its length for the
    // call.
    let (pattern, words, strings) = unsafe {
        (
            words::borrow(pattern, pattern_len),
            words::borrow(words, words_len),
            words::borrow(strings, strings_len),
        )
    };
    let ranking = ranked(&String::from_utf8_lossy(pattern), words, strings);
    let raw = match ranking {
        Some(indices) => RawWords::with_status(FuzzyStatus::Ranked as u64, ranking_words(&indices)),
        None => RawWords::with_status(FuzzyStatus::Malformed as u64, Vec::new()),
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
}

/// The ranking of the candidates `words` and `strings` spell against
/// `pattern`, by the real scorer. `None` when they spell none.
fn ranked(pattern: &str, words: &[u8], strings: &[u8]) -> Option<Vec<usize>> {
    let strings = std::str::from_utf8(strings).ok()?;
    let candidates = candidates(words, strings)?;
    Some(editor_fuzzy::rank(
        &mut NucleoScorer::new(),
        pattern,
        &candidates,
    ))
}

/// The span of `text` that `pattern` is located at, `near` the byte offset
/// where it is expected and within `max_errors` byte edits, by the real
/// searcher. `None` when there is none, and when either is not UTF-8.
pub fn located(pattern: &[u8], text: &[u8], near: usize, max_errors: u32) -> Option<ByteRange> {
    let pattern = std::str::from_utf8(pattern).ok()?;
    let text = std::str::from_utf8(text).ok()?;
    let found =
        editor_fuzzy::locate::locate(&mut TripleAccel::new(), pattern, text, near, max_errors)?;
    Some(ByteRange {
        start: found.start as u64,
        end: found.end as u64,
    })
}

/// Locates for C: returns whether the `pattern_len` bytes at `pattern` are
/// found in the `text_len` bytes at `text`, expected at the byte offset
/// `near` and within `max_errors` byte edits, and if so fills `out` with
/// the span (the module docs, "Locating a pattern").
///
/// # Safety
///
/// `pattern` points to `pattern_len` readable bytes and `text` to
/// `text_len`, both unchanged for the call (no bytes at all may be lent
/// with any pointer), and `out` points to a writable [`ByteRange`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_fuzzy_locate(
    pattern: *const u8,
    pattern_len: usize,
    text: *const u8,
    text_len: usize,
    near: usize,
    max_errors: u32,
    out: *mut ByteRange,
) -> bool {
    // SAFETY: the caller guarantees each pointer and its length for the
    // call.
    let (pattern, text) = unsafe {
        (
            words::borrow(pattern, pattern_len),
            words::borrow(text, text_len),
        )
    };
    let Some(found) = located(pattern, text, near, max_errors) else {
        return false;
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(found) };
    true
}

#[cfg(test)]
mod tests {
    use super::{candidates, located, ranking_words};
    use crate::words::tests::{buffer, words_of};

    #[test]
    fn the_words_and_the_string_spell_the_candidates() {
        // An empty candidate among them, and one of two-byte characters.
        assert_eq!(
            candidates(&buffer(&[4, 2, 0, 4, 1]), "wqéèw"),
            Some(vec!["wq", "", "éè", "w"])
        );
        assert_eq!(candidates(&buffer(&[1, 3]), "abc"), Some(vec!["abc"]));
    }

    #[test]
    fn no_candidates_are_a_count_of_none_and_an_empty_string() {
        assert_eq!(candidates(&buffer(&[0]), ""), Some(vec![]));
        // Empty candidates take no bytes of the string.
        assert_eq!(candidates(&buffer(&[2, 0, 0]), ""), Some(vec!["", ""]));
    }

    #[test]
    fn words_that_are_not_whole_words_are_refused() {
        let mut bytes = buffer(&[1, 3]);
        bytes.pop();

        assert_eq!(candidates(&bytes, "abc"), None);
        // No words at all have no count.
        assert_eq!(candidates(&[], ""), None);
    }

    #[test]
    fn a_count_the_words_are_too_short_for_is_refused() {
        assert_eq!(candidates(&buffer(&[3, 1, 1]), "ab"), None);
        assert_eq!(candidates(&buffer(&[u64::MAX]), ""), None);
    }

    #[test]
    fn words_left_over_are_refused() {
        assert_eq!(candidates(&buffer(&[1, 2, 1]), "abc"), None);
        assert_eq!(candidates(&buffer(&[0, 0]), ""), None);
    }

    #[test]
    fn lengths_that_do_not_add_up_to_the_string_are_refused() {
        // Too short: a byte of the string is left over.
        assert_eq!(candidates(&buffer(&[2, 1, 1]), "abc"), None);
        // Too long: the second runs past the string's end.
        assert_eq!(candidates(&buffer(&[2, 1, 3]), "abc"), None);
        // A length no string has, and two that overflow together.
        assert_eq!(candidates(&buffer(&[1, u64::MAX]), "abc"), None);
        assert_eq!(candidates(&buffer(&[2, 1, u64::MAX]), "abc"), None);
    }

    #[test]
    fn a_length_that_ends_inside_a_character_is_refused() {
        // `é` is two bytes: 1 and 1 cut it, and 2 does not.
        assert_eq!(candidates(&buffer(&[2, 1, 1]), "é"), None);
        assert_eq!(candidates(&buffer(&[2, 2, 0]), "é"), Some(vec!["é", ""]));
    }

    #[test]
    fn a_pattern_or_a_text_that_is_not_utf8_is_not_found() {
        assert_eq!(located(&[0xff], b"a", 0, 1), None);
        // The first byte of `é` alone: a length that ends inside it.
        assert_eq!(located(b"a", &"é".as_bytes()[..1], 0, 1), None);
    }

    #[test]
    fn a_ranking_is_written_as_its_count_and_then_its_indices() {
        assert_eq!(words_of(&ranking_words(&[])), [0]);
        assert_eq!(words_of(&ranking_words(&[2, 0, 7])), [3, 2, 0, 7]);
    }
}
