//! The C functions that apply a transaction to a document and read its
//! edit log, called the way the C glue calls them: with raw pointers,
//! buffers of words and out-records.
//!
//! This is an integration test of its own, so a process of its own, because
//! it makes documents: `tests/c_api.rs` counts the live documents of its
//! process, and a document made here beside it would be counted there.

use std::mem::MaybeUninit;
use std::slice;

use editor_ffi::document::{
    Document, RawText, editor_ffi_document_free, editor_ffi_document_new, editor_ffi_document_read,
};
use editor_ffi::log::{
    LogStatus, RawWords, editor_ffi_document_changes_since, editor_ffi_document_forget,
    editor_ffi_document_trace,
};
use editor_ffi::text::editor_ffi_text_free;
use editor_ffi::transaction::{ApplyStatus, RawApplied, editor_ffi_document_apply};

/// The kinds of a change, as words.
const RETAIN: u64 = 0;
const DELETE: u64 = 1;
const INSERT: u64 = 2;

/// The buffer that holds `words`: each as eight bytes, least significant
/// first.
fn buffer(words: &[u64]) -> Vec<u8> {
    words.iter().flat_map(|word| word.to_le_bytes()).collect()
}

/// A new document holding `text`.
fn document_new(text: &str) -> *mut Document {
    // SAFETY: the pointer and length are those of `text`, alive for the call.
    unsafe { editor_ffi_document_new(text.as_ptr(), text.len()) }
}

/// The text of `document`, read as the glue reads it.
///
/// # Safety
///
/// `document` came from [`document_new`] and has not been freed.
unsafe fn document_read(document: *const Document) -> String {
    let mut raw = MaybeUninit::<RawText>::uninit();
    // SAFETY: the caller guarantees `document`, and `raw` is writable for
    // one record.
    unsafe { editor_ffi_document_read(document, raw.as_mut_ptr()) };
    // SAFETY: the call filled the record.
    let raw = unsafe { raw.assume_init() };
    // SAFETY: the record's buffer is `text_len` bytes, owned by this caller
    // until it is handed back.
    let text = unsafe { slice::from_raw_parts(raw.text, raw.text_len) }.to_vec();
    // SAFETY: the buffer came from the library in this record, and is handed
    // back once.
    unsafe { editor_ffi_text_free(raw.text, raw.text_len) };
    String::from_utf8(text).expect("a document's text is UTF-8")
}

/// Applies to `document` the transaction `words` and `inserted` spell, with
/// `origin`, and returns the status and the revision the library reported.
///
/// # Safety
///
/// `document` came from [`document_new`] and has not been freed.
unsafe fn document_apply(
    document: *const Document,
    words: &[u64],
    inserted: &str,
    origin: u64,
) -> (u64, u64) {
    let words = buffer(words);
    let mut raw = MaybeUninit::<RawApplied>::uninit();
    // SAFETY: the caller guarantees `document`; the pointers and lengths
    // are those of `words` and `inserted`, alive for the call; and `raw` is
    // writable for one record.
    unsafe {
        editor_ffi_document_apply(
            document,
            words.as_ptr(),
            words.len(),
            inserted.as_ptr(),
            inserted.len(),
            origin,
            raw.as_mut_ptr(),
        );
    }
    // SAFETY: the call filled the record.
    let raw = unsafe { raw.assume_init() };
    (raw.status, raw.revision)
}

/// The status and the words of a filled record, read as the glue reads
/// them: copy the buffer, then hand it back.
///
/// # Safety
///
/// `raw` was filled by the library, and its buffer has not been handed
/// back.
unsafe fn take_words(raw: RawWords) -> (u64, Vec<u64>) {
    // SAFETY: the record's buffer is `len` bytes, owned by this caller
    // until it is handed back.
    let bytes = unsafe { slice::from_raw_parts(raw.words, raw.len) }.to_vec();
    // SAFETY: the buffer came from the library in this record, and is handed
    // back once.
    unsafe { editor_ffi_text_free(raw.words, raw.len) };
    let (words, rest) = bytes.as_chunks::<8>();
    assert!(rest.is_empty(), "whole words");
    let words = words.iter().copied().map(u64::from_le_bytes).collect();
    (raw.status, words)
}

/// What changed in `document` since `revision`: the status and the words.
///
/// # Safety
///
/// `document` came from [`document_new`] and has not been freed.
unsafe fn document_changes_since(document: *const Document, revision: u64) -> (u64, Vec<u64>) {
    let mut raw = MaybeUninit::<RawWords>::uninit();
    // SAFETY: the caller guarantees `document`, and `raw` is writable for
    // one record.
    unsafe { editor_ffi_document_changes_since(document, revision, raw.as_mut_ptr()) };
    // SAFETY: the call filled the record, whose buffer is taken once.
    unsafe { take_words(raw.assume_init()) }
}

/// The trace of the bytes `start..end` of `document`, as words, if the
/// library gave one.
///
/// # Safety
///
/// `document` came from [`document_new`] and has not been freed.
unsafe fn document_trace(document: *const Document, start: usize, end: usize) -> Option<Vec<u64>> {
    let mut raw = MaybeUninit::<RawWords>::uninit();
    // SAFETY: the caller guarantees `document`, and `raw` is writable for
    // one record.
    let traced = unsafe { editor_ffi_document_trace(document, start, end, raw.as_mut_ptr()) };
    // SAFETY: the record is filled when the call returns true, and its
    // buffer is taken once.
    traced.then(|| unsafe { take_words(raw.assume_init()) }.1)
}

const APPLIED: u64 = ApplyStatus::Applied as u64;
const BAD_CHANGE: u64 = ApplyStatus::BadChange as u64;
const BAD_SELECTION: u64 = ApplyStatus::BadSelection as u64;
const UNREADABLE: u64 = ApplyStatus::Unreadable as u64;
const ANSWERED: u64 = LogStatus::Answered as u64;
const UNKNOWN: u64 = LogStatus::Unknown as u64;
const FORGOTTEN: u64 = LogStatus::Forgotten as u64;

#[test]
fn a_transaction_is_applied_and_the_log_is_read_through_c() {
    // "é" is the bytes 1 and 2; the text is 12 bytes on two rows.
    let document = document_new("héllo\nwörl");

    // SAFETY: `document` is live until the free at the end of this block,
    // and every buffer a call fills is handed back by the helper that made
    // the call.
    unsafe {
        // A transaction with every kind of change, a selection before and
        // after, and an origin: "é" becomes "E\n", and "d" is added.
        let transaction = [
            5, RETAIN, 1, DELETE, 2, INSERT, 2, RETAIN, 9, INSERT, 1,
            // Before: exclusive, one range, from 1 to 3.
            1, 0, 0, 1, 1, 3, // After: block-wise, two ranges, the second the primary.
            1, 3, 1, 2, 1, 3, 13, 13,
        ];
        assert_eq!(
            document_apply(document, &transaction, "E\nd", 7),
            (APPLIED, 1)
        );
        assert_eq!(document_read(document), "hE\nllo\nwörld");

        // Each refusal is its status, and changes nothing.
        let short = [1, RETAIN, 12, 0, 0];
        assert_eq!(document_apply(document, &short, "", 1), (BAD_CHANGE, 0));
        // A selection after with an end inside "ö".
        let astray = [1, RETAIN, 13, 0, 1, 1, 0, 1, 9, 9];
        assert_eq!(document_apply(document, &astray, "", 1), (BAD_SELECTION, 0));
        let no_range = [1, RETAIN, 13, 1, 2, 0, 0, 0];
        assert_eq!(
            document_apply(document, &no_range, "", 1),
            (BAD_SELECTION, 0)
        );
        // A shape that is none of the four.
        let shapeless = [1, RETAIN, 13, 1, 4, 0, 1, 0, 0, 0];
        assert_eq!(document_apply(document, &shapeless, "", 1), (UNREADABLE, 0));
        let cut = [1, INSERT, 9, 0, 0];
        assert_eq!(document_apply(document, &cut, "x", 1), (UNREADABLE, 0));
        assert_eq!(document_apply(document, &[], "", 1), (UNREADABLE, 0));
        assert_eq!(document_read(document), "hE\nllo\nwörld");

        // A second transaction, with another origin: "llo" goes.
        let second = [3, RETAIN, 3, DELETE, 3, RETAIN, 7, 0, 0];
        assert_eq!(document_apply(document, &second, "", 9), (APPLIED, 2));
        assert_eq!(document_read(document), "hE\n\nwörld");

        // What changed since revision 0 is one patch of both.
        assert_eq!(
            document_changes_since(document, 0),
            (
                ANSWERED,
                vec![
                    0, 2, 2, // "éllo" became "E\n".
                    1, 6, 0, 1, 0, 6, 1, 3, 0, 1, 1, 0, // Nothing at the end became "d".
                    12, 12, 1, 5, 1, 5, 9, 10, 2, 5, 2, 6,
                ]
            )
        );
        assert_eq!(
            document_changes_since(document, 2),
            (ANSWERED, vec![2, 2, 0])
        );
        assert_eq!(document_changes_since(document, 3), (UNKNOWN, Vec::new()));
        assert_eq!(
            document_changes_since(document, u64::MAX),
            (UNKNOWN, Vec::new())
        );

        // The trace gives each origin back.
        assert_eq!(
            document_trace(document, 0, 10),
            Some(vec![
                4, 0, 1, 0, 0, 0, 1, 3, 1, 1, 7, 3, 9, 0, 0, 0, 9, 10, 1, 1, 7,
            ])
        );
        assert_eq!(document_trace(document, 4, 4), Some(vec![0]));
        // Inside "ö", backwards, and past the end.
        assert_eq!(document_trace(document, 0, 6), None);
        assert_eq!(document_trace(document, 3, 1), None);
        assert_eq!(document_trace(document, 0, 11), None);

        // Forgetting.
        assert!(!editor_ffi_document_forget(document, 3));
        assert!(editor_ffi_document_forget(document, 1));
        assert_eq!(document_changes_since(document, 0), (FORGOTTEN, Vec::new()));
        let (status, words) = document_changes_since(document, 1);
        assert_eq!(status, ANSWERED);
        assert_eq!(words[..3], [1, 2, 1]);
        assert_eq!(
            document_trace(document, 0, 10),
            Some(vec![1, 0, 10, 0, 1, 0])
        );
        assert_eq!(document_read(document), "hE\n\nwörld");

        editor_ffi_document_free(document);
    }
}
