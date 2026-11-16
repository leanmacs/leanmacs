//! Search of a snapshot, wired: the real engine over a real text's pieces,
//! and the two C functions called the way the C glue calls them.
//!
//! Which match is answered is `editor-search`'s rule, pinned there on its
//! fake and on the adapter. What is pinned here is the wiring: that a text
//! the rope holds in several pieces is searched whole, a match split
//! between two pieces included, and that the answers and the refusals
//! cross as words.

use std::mem::MaybeUninit;
use std::slice;

use editor_ffi::document::{editor_ffi_document_free, editor_ffi_document_new};
use editor_ffi::log::RawWords;
use editor_ffi::search::{
    self, SearchStatus, editor_ffi_snapshot_matches, editor_ffi_snapshot_search,
};
use editor_ffi::snapshot::{editor_ffi_document_snapshot, editor_ffi_snapshot_free};
use editor_ffi::text::editor_ffi_text_free;
use editor_search::Searched;
use editor_text::Text;

/// A text long enough that the rope holds it in several pieces, of `word`
/// and a space again and again: a pattern of the word matches at every
/// tenth byte.
fn long_text() -> String {
    "foobarbaz ".repeat(2000)
}

/// The record's status and bytes, copied out and handed back as the glue
/// does.
fn taken(raw: RawWords) -> (u64, Vec<u8>) {
    let bytes = if raw.len == 0 {
        Vec::new()
    } else {
        // SAFETY: the record's buffer is `len` bytes, owned by this caller
        // until it is handed back.
        unsafe { slice::from_raw_parts(raw.words, raw.len) }.to_vec()
    };
    // SAFETY: the buffer came from the library in this record, and is
    // handed back once.
    unsafe { editor_ffi_text_free(raw.words, raw.len) };
    (raw.status, bytes)
}

/// What the two C functions answer of a document holding `text`: a search
/// for `pattern` forward from `offset`, and its matches from 0 to `stop`.
fn through_c(
    text: &str,
    pattern: &str,
    offset: usize,
    stop: usize,
) -> ((u64, Vec<u8>), (u64, Vec<u8>)) {
    // SAFETY: the text is a slice alive for the call; each handle is freed
    // once, after its last use.
    unsafe {
        let document = editor_ffi_document_new(text.as_ptr(), text.len());
        let snapshot = editor_ffi_document_snapshot(document);
        let mut found = MaybeUninit::<RawWords>::uninit();
        editor_ffi_snapshot_search(
            snapshot,
            pattern.as_ptr(),
            pattern.len(),
            true,
            offset,
            found.as_mut_ptr(),
        );
        let mut all = MaybeUninit::<RawWords>::uninit();
        editor_ffi_snapshot_matches(
            snapshot,
            pattern.as_ptr(),
            pattern.len(),
            0,
            stop,
            all.as_mut_ptr(),
        );
        editor_ffi_snapshot_free(snapshot);
        editor_ffi_document_free(document);
        (taken(found.assume_init()), taken(all.assume_init()))
    }
}

#[test]
fn a_match_split_between_two_pieces_of_the_rope_is_found() {
    let text = long_text();
    let snapshot = Text::from(text.as_str()).snapshot();
    let pieces: Vec<&str> = snapshot.chunks().collect();
    // The case is not an empty one: the text is in several pieces, and at
    // least one occurrence of the word runs across where one ends.
    assert!(pieces.len() > 1);
    // An occurrence starts at every tenth byte and is nine long, so a
    // piece that ends one to eight bytes past a tenth ends inside one.
    let ends = pieces.iter().scan(0, |end, piece| {
        *end += piece.len();
        Some(*end)
    });
    assert!(ends.into_iter().any(|end| (1..9).contains(&(end % 10))));

    let all = search::matches(&snapshot, "foobarbaz", 0, text.len()).unwrap();
    let expected: Vec<_> = (0..2000).map(|index| index * 10..index * 10 + 9).collect();
    assert_eq!(all, expected);
    assert_eq!(
        search::search(&snapshot, "rbaz f", true, 0),
        Ok(Searched::Found {
            start: 5,
            stop: 11,
            wrapped: false,
        })
    );
}

#[test]
fn a_search_and_the_matches_cross_as_words() {
    let ((status, found), (all_status, all)) = through_c("a foo foo", "foo", 2, 9);

    assert_eq!(status, SearchStatus::Answered as u64);
    assert_eq!(
        found,
        search::searched_words(Searched::Found {
            start: 6,
            stop: 9,
            wrapped: false,
        })
    );
    assert_eq!(all_status, SearchStatus::Answered as u64);
    assert_eq!(all, search::matches_words(&[2..5, 6..9]));
}

#[test]
fn a_pattern_the_syntax_refuses_crosses_as_its_sentence() {
    let ((status, reason), (all_status, all_reason)) = through_c("abc", "\\(a", 0, 3);

    assert_eq!(status, SearchStatus::Invalid as u64);
    assert_eq!(String::from_utf8(reason).unwrap(), "E54: Unmatched \\(");
    assert_eq!(all_status, SearchStatus::Invalid as u64);
    assert_eq!(String::from_utf8(all_reason).unwrap(), "E54: Unmatched \\(");
}

#[test]
fn an_offset_inside_a_character_and_a_range_past_the_text_are_refused() {
    let ((status, words), (all_status, all)) = through_c("héllo", "l", 2, 99);

    assert_eq!(
        (status, words),
        (SearchStatus::BadPosition as u64, Vec::new())
    );
    assert_eq!(
        (all_status, all),
        (SearchStatus::BadPosition as u64, Vec::new())
    );
}
