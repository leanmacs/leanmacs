//! The C functions of grammar registration over the process's syntax
//! service, called the way the C glue calls them, with each completion
//! pulled from the process's completion queue.
//!
//! This is the wiring test: the C functions, the process's service, the
//! syntax worker's thread and the real adapter, `editor-syntax-treesitter`,
//! which loads native grammar libraries; the library registered is the
//! fixture INI grammar's (`editor-syntax-fixture-ini`). It asserts wiring
//! only: each registration that went in is completed on the completion
//! queue from the syntax service's source; a library that is not there is
//! taken as not found, and the fixture's grammar as registered with its
//! name lent; the grammars listed through C are those listed before, then
//! the new one; an unknown policy tag and an id in use start nothing; a
//! flush is completed; and nothing is left pending. What a registration
//! does is `editor-syntax`'s rule, pinned there on the fake and by the
//! registration contract, which the adapter keeps on the same fixture; the
//! service's waits are this crate's unit tests'.
//!
//! It is an integration test of its own, and one test function, because the
//! completion queue is process-wide: its pulls are its own, and the grammar
//! it registers stays registered in the process's service.

#[path = "common/watches.rs"]
mod common;

use std::mem::MaybeUninit;
use std::slice;

use common::{Seen, next_completion};
use editor_ffi::document::RawText;
use editor_ffi::events::{EventKind, SourceKind};
use editor_ffi::grammars::{
    GrammarStatus, editor_ffi_grammars_flush, editor_ffi_grammars_pending,
    editor_ffi_grammars_start, editor_ffi_grammars_take,
};
use editor_ffi::syntax::{RawStrings, SERVICE, editor_ffi_syntax_grammars};
use editor_ffi::text::editor_ffi_text_free;
use editor_syntax_fixture_ini as fixture;

/// The completion of the wait `id`, as it should arrive.
fn completion_of(id: u64) -> Seen {
    (
        Some(SourceKind::Library),
        SERVICE,
        Some(EventKind::Completion),
        id,
    )
}

/// The bytes of a buffer the library lent, copied out, with the buffer
/// handed back.
fn take_buffer(pointer: *mut u8, len: usize) -> Vec<u8> {
    let bytes = if len == 0 {
        Vec::new()
    } else {
        // SAFETY: the library lent `len` readable bytes at `pointer`.
        unsafe { slice::from_raw_parts(pointer, len) }.to_vec()
    };
    // SAFETY: the buffer came from the library, and is handed back once.
    unsafe { editor_ffi_text_free(pointer, len) };
    bytes
}

/// The grammars listed through C: the strings of the record, read by its
/// words, the count and then each one's length, each eight bytes, least
/// significant first.
fn grammars() -> Vec<String> {
    let mut raw = MaybeUninit::<RawStrings>::uninit();
    // SAFETY: `raw` is writable for one record.
    unsafe { editor_ffi_syntax_grammars(raw.as_mut_ptr()) };
    // SAFETY: the call filled the record.
    let raw = unsafe { raw.assume_init() };
    let words = take_buffer(raw.words, raw.words_len);
    let text = take_buffer(raw.text, raw.text_len);
    let mut sizes =
        words.as_chunks::<8>().0.iter().map(|word| {
            usize::try_from(u64::from_le_bytes(*word)).expect("a length a usize holds")
        });
    let count = sizes.next().expect("the count");
    let mut start = 0;
    let names: Vec<String> = sizes
        .map(|len| {
            let name = String::from_utf8(text[start..start + len].to_vec()).expect("UTF-8");
            start += len;
            name
        })
        .collect();
    assert_eq!((names.len(), start), (count, text.len()));
    names
}

/// Starts the registration `id` of `symbol` in `library` with the policy
/// tag `policy`, through the C function, as the glue does.
fn start(id: u64, library: &str, symbol: &str, policy: u8) -> bool {
    // SAFETY: the pointers and lengths are those of the two strings, alive
    // for the call.
    unsafe {
        editor_ffi_grammars_start(
            id,
            library.as_ptr(),
            library.len(),
            symbol.as_ptr(),
            symbol.len(),
            policy,
        )
    }
}

/// The status of the take of `id`, through the C function, with the name
/// lent beside a registered one.
fn take(id: u64) -> (u64, Option<String>) {
    let mut out = MaybeUninit::<RawText>::uninit();
    // SAFETY: `out` is writable for one record.
    let status = unsafe { editor_ffi_grammars_take(id, out.as_mut_ptr()) };
    if status == GrammarStatus::Registered as u64 {
        // SAFETY: a registered take filled the record.
        let out = unsafe { out.assume_init() };
        let name = take_buffer(out.text, out.text_len);
        return (status, Some(String::from_utf8(name).expect("UTF-8")));
    }
    (status, None)
}

/// The status of the take of `id`, which lends no name.
fn status(id: u64) -> u64 {
    let (status, name) = take(id);
    assert_eq!(name, None);
    status
}

#[test]
fn a_registration_through_c_is_completed_on_the_completion_queue_and_lists_the_loaded_grammar() {
    let before = grammars();
    let absent = "/nonexistent/libtree-sitter-python.so";

    // One registration of a library that is not there with each policy
    // tag, then the fixture's grammar.
    assert!(start(1, absent, "tree_sitter_python", 0));
    assert!(start(2, absent, "tree_sitter_python", 1));
    assert!(start(3, absent, "tree_sitter_python", 2));
    assert!(start(4, fixture::LIBRARY, fixture::SYMBOL, 0));
    // An unknown policy tag starts nothing, and an id in use is refused.
    assert!(!start(5, absent, "tree_sitter_python", 3));
    assert!(!start(1, absent, "tree_sitter_python", 0));
    assert!(editor_ffi_grammars_flush(6));

    let completions: Vec<Seen> = (0..5).map(|_| next_completion()).collect();
    assert_eq!(
        completions,
        [1, 2, 3, 4, 6].map(completion_of),
        "each registration, then the flush, is completed in order"
    );
    for id in 1..=3 {
        assert_eq!(status(id), GrammarStatus::NotFound as u64);
        assert_eq!(status(id), GrammarStatus::NoAnswer as u64);
    }
    assert_eq!(
        take(4),
        (
            GrammarStatus::Registered as u64,
            Some(fixture::NAME.to_owned())
        )
    );
    assert_eq!(status(4), GrammarStatus::NoAnswer as u64);
    assert_eq!(status(5), GrammarStatus::NoAnswer as u64);
    assert_eq!(status(6), GrammarStatus::NoAnswer as u64);
    let mut listed = before;
    listed.push(fixture::NAME.to_owned());
    assert_eq!(grammars(), listed);
    assert_eq!(editor_ffi_grammars_pending(), 0);
}
