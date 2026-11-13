//! The C functions that apply the inverse of a run of revisions to a
//! document and drop its kept inverses, called the way the C glue calls
//! them: with raw pointers and out-records.
//!
//! What the inverse of a run does, when it is refused and what it hands
//! back are the text's rules. So every answer here is compared with what
//! an [`editor_text::Text`] given the same calls answers, written as words
//! by this crate's own encoder: what is pinned is that the values cross.
//!
//! This is an integration test of its own, so a process of its own, because
//! it makes documents: `tests/c_api.rs` counts the live documents of its
//! process, and a document made here beside it would be counted there.

use std::mem::MaybeUninit;
use std::slice;

use editor_ffi::document::{
    Document, RawText, editor_ffi_document_free, editor_ffi_document_new, editor_ffi_document_read,
};
use editor_ffi::inverse::{
    self, InverseStatus, editor_ffi_document_apply_inverse, editor_ffi_document_drop_inverses,
};
use editor_ffi::log::RawWords;
use editor_ffi::text::editor_ffi_text_free;
use editor_ffi::transaction::{self, ApplyStatus, RawApplied, editor_ffi_document_apply};
use editor_text::{Origin, Revision, Text};

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

/// Applies to `document` the inverse of the run from `first` to `last`,
/// with `origin`, and returns the status and the bytes the library
/// reported, read as the glue reads them: copy the buffer, then hand it
/// back.
///
/// # Safety
///
/// `document` came from [`document_new`] and has not been freed.
unsafe fn document_apply_inverse(
    document: *const Document,
    first: u64,
    last: u64,
    origin: u64,
) -> (u64, Vec<u8>) {
    let mut raw = MaybeUninit::<RawWords>::uninit();
    // SAFETY: the caller guarantees `document`, and `raw` is writable for
    // one record.
    unsafe { editor_ffi_document_apply_inverse(document, first, last, origin, raw.as_mut_ptr()) };
    // SAFETY: the call filled the record.
    let raw = unsafe { raw.assume_init() };
    // SAFETY: the record's buffer is `len` bytes, owned by this caller
    // until it is handed back.
    let bytes = unsafe { slice::from_raw_parts(raw.words, raw.len) }.to_vec();
    // SAFETY: the buffer came from the library in this record, and is
    // handed back once.
    unsafe { editor_ffi_text_free(raw.words, raw.len) };
    (raw.status, bytes)
}

/// What the inverse of the run from `first` to `last`, applied to `text`
/// with `origin`, crosses as: the status and the words.
fn of_text(text: &mut Text, first: u64, last: u64, origin: u64) -> (u64, Vec<u8>) {
    let inverted = text.apply_inverse(
        Revision::new(first),
        Revision::new(last),
        Origin::new(origin),
    );
    match inverted {
        Ok(inverted) => (
            InverseStatus::Done as u64,
            inverse::inverted_words(&inverted),
        ),
        Err(error) => (InverseStatus::of(error) as u64, Vec::new()),
    }
}

#[test]
fn the_inverse_of_a_run_is_applied_and_inverses_are_dropped_through_c() {
    // "é" is the bytes 1 and 2, and "😀" the bytes 7 to 10; the text is 12
    // bytes.
    const TEXT: &str = "héllo 😀x";
    let document = document_new(TEXT);
    // The same text, to ask what the text's rules answer.
    let mut text = Text::from(TEXT);

    // Two transactions. "é" is deleted, with a line-wise selection of two
    // ranges before it and a cursor after it; then "!" is added at the end,
    // with a block before it and an inclusive range after it.
    let first = buffer(&[
        3, 0, 1, 1, 2, 0, 9, // The changes.
        1, 2, 1, 2, 11, 7, 1, 0, // Before.
        1, 0, 0, 1, 1, 1, // After.
    ]);
    let second = buffer(&[
        2, 0, 10, 2, 1, // The changes.
        1, 3, 0, 1, 4, 9, // Before.
        1, 1, 0, 1, 11, 0, // After.
    ]);

    // SAFETY: `document` is live until the free at the end of this block,
    // and every buffer a call fills is handed back by the helper that made
    // the call.
    unsafe {
        for (words, inserted) in [(&first, ""), (&second, "!")] {
            let mut applied = MaybeUninit::<RawApplied>::uninit();
            editor_ffi_document_apply(
                document,
                words.as_ptr(),
                words.len(),
                inserted.as_ptr(),
                inserted.len(),
                7,
                applied.as_mut_ptr(),
            );
            assert_eq!(applied.assume_init().status, ApplyStatus::Applied as u64);
            let same = transaction::decode(words, inserted.as_bytes()).expect("a transaction");
            text.apply(&same, Origin::new(7)).expect("it fits");
        }
        assert_eq!(document_read(document), text.current().to_string());

        // The inverse of the run, of that inverse, and of a run the text
        // is then not at the end of: each crosses as what the text
        // answers, and leaves the document holding what the text holds.
        for (first, last) in [(1, 2), (3, 3), (1, 1)] {
            let expected = of_text(&mut text, first, last, 9);
            assert_eq!(
                document_apply_inverse(document, first, last, 9),
                expected,
                "{first}..={last}"
            );
            assert_eq!(document_read(document), text.current().to_string());
        }
        // Something was applied, and a selection crossed: the first two
        // answers above were not refusals with no words.
        assert_eq!(text.current().revision(), Revision::new(4));

        // The other refusals: a revision not reached, and a run from 0.
        for (first, last) in [(1, 99), (u64::MAX, u64::MAX), (0, 4)] {
            let expected = of_text(&mut text, first, last, 9);
            assert_ne!(expected.0, InverseStatus::Done as u64);
            assert_eq!(
                document_apply_inverse(document, first, last, 9),
                expected,
                "{first}..={last}"
            );
        }

        // A drop past the document's revision is refused, as the text's
        // is; a drop of a run is made, and the run is then asked for.
        for (first, last) in [(4, 99), (4, 4)] {
            let dropped = text
                .drop_inverses(Revision::new(first), Revision::new(last))
                .is_ok();
            assert_eq!(
                editor_ffi_document_drop_inverses(document, first, last),
                dropped,
                "{first}..={last}"
            );
        }
        let expected = of_text(&mut text, 4, 4, 9);
        assert_eq!(document_apply_inverse(document, 4, 4, 9), expected);
        assert_eq!(document_read(document), text.current().to_string());

        editor_ffi_document_free(document);
    }
}
