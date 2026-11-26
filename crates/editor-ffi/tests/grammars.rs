//! The C functions of grammar registration over the process's syntax
//! service, called the way the C glue calls them, with each completion
//! pulled from the process's completion queue.
//!
//! This is the wiring test: the C functions, the process's service, the
//! syntax worker's thread and the real adapter, `editor-syntax-treesitter`,
//! which refuses every registration as unsupported until it loads native
//! libraries. It asserts wiring only: a registration that went in is
//! completed on the completion queue from the syntax service's source and
//! taken as unsupported, the grammars listed through C are as before, an
//! unknown policy tag starts nothing, a flush is completed, and nothing is
//! left pending. What a registration does is `editor-syntax`'s rule, pinned
//! there on the fake and by the registration contract; the service's waits
//! are this crate's unit tests'.
//!
//! It is an integration test of its own, and one test function, because the
//! completion queue is process-wide: its pulls are its own.

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

/// The grammars listed through C, as the words and the strings they cross
/// as.
fn grammars() -> (Vec<u8>, Vec<u8>) {
    let mut raw = MaybeUninit::<RawStrings>::uninit();
    // SAFETY: `raw` is writable for one record.
    unsafe { editor_ffi_syntax_grammars(raw.as_mut_ptr()) };
    // SAFETY: the call filled the record.
    let raw = unsafe { raw.assume_init() };
    (
        take_buffer(raw.words, raw.words_len),
        take_buffer(raw.text, raw.text_len),
    )
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

/// The status of the take of `id`, through the C function.
fn take(id: u64) -> u64 {
    let mut out = MaybeUninit::<RawText>::uninit();
    // SAFETY: `out` is writable for one record.
    let status = unsafe { editor_ffi_grammars_take(id, out.as_mut_ptr()) };
    if status == GrammarStatus::Registered as u64 {
        // SAFETY: a registered take filled the record.
        let out = unsafe { out.assume_init() };
        take_buffer(out.text, out.text_len);
    }
    status
}

#[test]
fn a_registration_through_c_is_completed_on_the_completion_queue_refused_as_unsupported_and_leaves_the_grammars()
 {
    let before = grammars();
    let library = "/nonexistent/libtree-sitter-python.so";

    // One registration with each policy tag, then one of a compiled-in name.
    assert!(start(1, library, "tree_sitter_python", 0));
    assert!(start(2, library, "tree_sitter_python", 1));
    assert!(start(3, library, "tree_sitter_python", 2));
    assert!(start(4, library, "tree_sitter_rust", 0));
    // An unknown policy tag starts nothing, and an id in use is refused.
    assert!(!start(5, library, "tree_sitter_python", 3));
    assert!(!start(1, library, "tree_sitter_python", 0));
    assert!(editor_ffi_grammars_flush(6));

    let completions: Vec<Seen> = (0..5).map(|_| next_completion()).collect();
    assert_eq!(
        completions,
        [1, 2, 3, 4, 6].map(completion_of),
        "each registration, then the flush, is completed in order"
    );
    for id in 1..=4 {
        assert_eq!(take(id), GrammarStatus::Unsupported as u64);
        assert_eq!(take(id), GrammarStatus::NoAnswer as u64);
    }
    assert_eq!(take(5), GrammarStatus::NoAnswer as u64);
    assert_eq!(take(6), GrammarStatus::NoAnswer as u64);
    assert_eq!(grammars(), before);
    assert_eq!(editor_ffi_grammars_pending(), 0);
}
