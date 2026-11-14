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
//! This module takes the candidates apart, forwards and writes the words.

use editor_fuzzy_nucleo::NucleoScorer;

use crate::log::RawWords;
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

#[cfg(test)]
mod tests {
    use super::{candidates, ranking_words};
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
    fn a_ranking_is_written_as_its_count_and_then_its_indices() {
        assert_eq!(words_of(&ranking_words(&[])), [0]);
        assert_eq!(words_of(&ranking_words(&[2, 0, 7])), [3, 2, 0, 7]);
    }
}
