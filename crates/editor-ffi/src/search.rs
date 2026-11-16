//! Search within a snapshot as it crosses the boundary: a pattern and an
//! offset or a range in, a match or the matches out.
//!
//! - **A search** ([`editor_ffi_snapshot_search`]): the pattern, the
//!   direction and the offset in; a [`RawWords`] out, whose words are a
//!   presence (1 found, 0 not), the match's two offsets and whether the
//!   search wrapped (1) or not (0).
//! - **The matches in a range** ([`editor_ffi_snapshot_matches`]): the
//!   pattern and the range in; words out, the count of matches and then
//!   the two offsets of each.
//!
//! Both answer one of three statuses ([`SearchStatus`]). For a pattern the
//! syntax refuses, the record's bytes are the sentence that says why, in
//! UTF-8, and not words: it is the one answer that is a text.
//!
//! Each call is stateless, as fuzzy ranking's is (`crate::fuzzy`): it makes
//! the search port's real adapter (`editor-search-regex`) for the call,
//! asks `editor-search`'s rule over the snapshot's pieces
//! ([`editor_text::Snapshot::chunks`], so no text is copied) with the text's
//! word class ([`editor_text::is_word_character`]), and keeps nothing. No
//! compiled pattern is cached: each call compiles its pattern. Which match
//! is answered, and what a pattern means, are those crates' rules, pinned
//! by their own tests; this module checks the offsets, forwards and writes
//! the words.

use std::ops::Range;

use editor_search::{Refusal, Searched};
use editor_search_regex::RegexEngine;

use crate::log::RawWords;
use crate::snapshot::Snapshot;
use crate::words::{self, Writer};

/// How a search or the matches in a range ended, as it crosses the
/// boundary: the `status` of the [`RawWords`] filled.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SearchStatus {
    /// Answered. The record's words are the answer.
    Answered = 0,
    /// Refused: the offset is not a position of the text, or the range is
    /// not two positions in order. No words.
    BadPosition = 1,
    /// The pattern is none the syntax takes. The record's bytes are the
    /// sentence that says why, in UTF-8.
    Invalid = 2,
}

/// What a search answers before it crosses: the match, or none, or the
/// status a refusal crosses as and its sentence.
pub type SearchAnswer = Result<Searched, (SearchStatus, String)>;

/// The search of `snapshot` for `pattern` from `offset`, forward when
/// `forward` and back otherwise, by the real engine and the text's word
/// class.
pub fn search(
    snapshot: &editor_text::Snapshot,
    pattern: &str,
    forward: bool,
    offset: usize,
) -> SearchAnswer {
    if !snapshot.is_char_boundary(offset) {
        return Err((SearchStatus::BadPosition, String::new()));
    }
    let pieces: Vec<&str> = snapshot.chunks().collect();
    editor_search::search(
        &mut RegexEngine::new(),
        pattern,
        &pieces,
        &editor_text::is_word_character,
        forward,
        offset,
    )
    .map_err(invalid)
}

/// The matches of `pattern` in `snapshot` that start from `start` up to
/// `stop`, in order, by the real engine and the text's word class.
pub fn matches(
    snapshot: &editor_text::Snapshot,
    pattern: &str,
    start: usize,
    stop: usize,
) -> Result<Vec<Range<usize>>, (SearchStatus, String)> {
    if !(snapshot.is_char_boundary(start) && snapshot.is_char_boundary(stop) && start <= stop) {
        return Err((SearchStatus::BadPosition, String::new()));
    }
    let pieces: Vec<&str> = snapshot.chunks().collect();
    editor_search::matches(
        &mut RegexEngine::new(),
        pattern,
        &pieces,
        &editor_text::is_word_character,
        start,
        stop,
    )
    .map_err(invalid)
}

/// A refusal of the pattern, as it crosses.
fn invalid(refusal: Refusal) -> (SearchStatus, String) {
    (SearchStatus::Invalid, refusal.reason().to_owned())
}

/// The record a refusal crosses as: its status, and its sentence as bytes.
fn refused((status, reason): (SearchStatus, String)) -> RawWords {
    RawWords::with_status(status as u64, reason.into_bytes())
}

/// The words of a search's answer, in the layout the module docs give.
pub fn searched_words(searched: Searched) -> Vec<u8> {
    let mut writer = Writer::with_capacity(4);
    match searched {
        Searched::Found {
            start,
            stop,
            wrapped,
        } => {
            writer.word(1);
            writer.size(start);
            writer.size(stop);
            writer.word(u64::from(wrapped));
        }
        Searched::NotFound => {
            for _ in 0..4 {
                writer.word(0);
            }
        }
    }
    writer.finish()
}

/// The words of the matches in a range, in the layout the module docs give.
pub fn matches_words(all: &[Range<usize>]) -> Vec<u8> {
    let mut writer = Writer::with_capacity(1 + 2 * all.len());
    writer.size(all.len());
    for range in all {
        writer.size(range.start);
        writer.size(range.end);
    }
    writer.finish()
}

/// [`search`] for C: fills `out` with the answer of a search of
/// `snapshot` for the `pattern_len` bytes at `pattern` from `offset`,
/// forward when `forward`, in the layout the module docs give. Bytes that
/// are not UTF-8 are read as the document's text is, each as a replacement
/// character.
///
/// # Safety
///
/// `snapshot` is a snapshot handle this library handed out and has not
/// taken back, `pattern` points to `pattern_len` readable bytes unchanged
/// for the call, and `out` points to a writable [`RawWords`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_snapshot_search(
    snapshot: *const Snapshot,
    pattern: *const u8,
    pattern_len: usize,
    forward: bool,
    offset: usize,
    out: *mut RawWords,
) {
    // SAFETY: the caller guarantees the pointer and its length for the call.
    let pattern = String::from_utf8_lossy(unsafe { words::borrow(pattern, pattern_len) });
    // SAFETY: the caller guarantees `snapshot` points to a live snapshot.
    let text = unsafe { &*snapshot }.text();
    let raw = match search(text, &pattern, forward, offset) {
        Ok(searched) => {
            RawWords::with_status(SearchStatus::Answered as u64, searched_words(searched))
        }
        Err(refusal) => refused(refusal),
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
}

/// [`matches()`] for C: fills `out` with the matches of the `pattern_len`
/// bytes at `pattern` in `snapshot` that start from `start` up to `stop`,
/// in the layout the module docs give.
///
/// # Safety
///
/// As [`editor_ffi_snapshot_search`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_snapshot_matches(
    snapshot: *const Snapshot,
    pattern: *const u8,
    pattern_len: usize,
    start: usize,
    stop: usize,
    out: *mut RawWords,
) {
    // SAFETY: the caller guarantees the pointer and its length for the call.
    let pattern = String::from_utf8_lossy(unsafe { words::borrow(pattern, pattern_len) });
    // SAFETY: the caller guarantees `snapshot` points to a live snapshot.
    let text = unsafe { &*snapshot }.text();
    let raw = match matches(text, &pattern, start, stop) {
        Ok(all) => RawWords::with_status(SearchStatus::Answered as u64, matches_words(&all)),
        Err(refusal) => refused(refusal),
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
}
