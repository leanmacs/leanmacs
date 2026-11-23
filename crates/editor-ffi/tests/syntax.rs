//! The syntax service wired to real documents and the real adapter: edits
//! made through a document reach its session, the tree delivered is, once
//! the text is quiet, the one a fresh parse of the document's text gives,
//! and a query is answered only from a tree of the snapshot's own revision.
//!
//! Every test runs on the process's service, as the edit paths reach it
//! (the module docs of `editor_ffi::syntax`), in parallel: each makes
//! documents of its own, and keys are given out once in the process. A
//! wait for a delivery blocks on the session with a bound, and nothing
//! sleeps.

#![expect(
    clippy::disallowed_methods,
    reason = "the syntax service's wiring tests: they wait for an exact delivery on its readout `Syntaxes::settle_exact` before they compare it with a fresh parse"
)]

use std::mem::MaybeUninit;
use std::slice;
use std::time::Duration;

use editor_wait::HangGuard;

use editor_diff::Step;
use editor_ffi::document::{Document, editor_ffi_document_free, editor_ffi_document_new};
use editor_ffi::log::RawWords;
use editor_ffi::snapshot::{Snapshot, editor_ffi_document_snapshot, editor_ffi_snapshot_free};
use editor_ffi::syntax::{
    AttachStatus, CapturesStatus, QueryStatus, RawQuery, RawStrings, SyntaxQuery,
    editor_ffi_syntax_attach, editor_ffi_syntax_capture_names, editor_ffi_syntax_captures,
    editor_ffi_syntax_detach, editor_ffi_syntax_grammars, editor_ffi_syntax_query_free,
    editor_ffi_syntax_query_new, editor_ffi_syntax_refresh_after, editor_ffi_syntax_settle,
    kind_tag, syntaxes,
};
use editor_ffi::text::editor_ffi_text_free;
use editor_syntax::{GrammarName, QueryErrorKind, Syntax};
use editor_syntax_treesitter::TreeSitter;
use editor_text::{ChangeSet, Origin, Transaction};

/// hang guard: a delivery; only a hang reaches the bound, and the test
/// then fails as a hang. The longest a test waits for one.
const BOUND: HangGuard = HangGuard::on("a delivery", Duration::from_secs(10));

/// A Rust text of two functions.
const RUST: &str = "fn one() {}\n\nfn two(x: u8) -> u8 {\n    x\n}\n";

/// The bytes of a buffer the library lent, copied out and handed back.
fn take(bytes: *mut u8, len: usize) -> Vec<u8> {
    let copied = if len == 0 {
        Vec::new()
    } else {
        // SAFETY: the library lent `len` bytes at `bytes` to this caller.
        unsafe { slice::from_raw_parts(bytes, len) }.to_vec()
    };
    // SAFETY: the buffer came from the library and is handed back once.
    unsafe { editor_ffi_text_free(bytes, len) };
    copied
}

/// The words of `bytes`.
fn words(bytes: &[u8]) -> Vec<u64> {
    bytes
        .as_chunks::<8>()
        .0
        .iter()
        .map(|word| u64::from_le_bytes(*word))
        .collect()
}

/// The strings a [`RawStrings`] holds.
fn strings(raw: RawStrings) -> Vec<String> {
    let lengths = words(&take(raw.words, raw.words_len));
    let text = String::from_utf8(take(raw.text, raw.text_len)).unwrap();
    let mut at = 0;
    lengths[1..]
        .iter()
        .map(|&len| {
            let len = usize::try_from(len).unwrap();
            let string = text[at..at + len].to_owned();
            at += len;
            string
        })
        .collect()
}

/// Has the process's service refresh a text as soon as it is quiet, through
/// C: what a test that compares the tree delivered with a fresh parse sets
/// before its first edit, since an edit's incremental reparse is exact
/// only once the text is quiet, and an edit's deadline is set with the
/// interval at the time of the edit. Every test of this binary that sets
/// it sets the same value, so tests in parallel agree.
fn refresh_at_once() {
    editor_ffi_syntax_refresh_after(0);
}

/// Whether the tree the service delivered of `document` is of its text as
/// it is now and equals a fresh parse of it, once the text is quiet and
/// the tree delivered is exact. The test sets the interval first
/// ([`refresh_at_once`]).
fn delivered_is_fresh(document: &Document) -> bool {
    let snapshot = Snapshot::of(document);
    if !syntaxes().settle_exact(&snapshot, BOUND) {
        return false;
    }
    let text = document.snapshot();
    let mut parser = TreeSitter.parser(&GrammarName::new("rust")).unwrap();
    let fresh = TreeSitter.nodes(&TreeSitter.parse(&mut parser, &text, None));
    syntaxes().delivered(document.key()) == Some((text.revision(), fresh))
}

/// A transaction over a text of `len` bytes that replaces each range with
/// its text, in order.
fn transaction(len: usize, changes: &[(usize, usize, &str)]) -> Transaction {
    let mut set = ChangeSet::new();
    let mut kept = 0;
    for &(start, end, text) in changes {
        set.retain(start - kept);
        set.insert(text);
        set.delete(end - start);
        kept = end;
    }
    set.retain(len - kept);
    Transaction::new(set)
}

#[test]
fn the_grammars_compiled_in_cross_as_a_list_of_strings() {
    let mut raw = MaybeUninit::<RawStrings>::uninit();
    // SAFETY: `raw` is writable for one record.
    unsafe { editor_ffi_syntax_grammars(raw.as_mut_ptr()) };
    // SAFETY: the call filled the record.
    let names = strings(unsafe { raw.assume_init() });

    // The adapter's own list, which its crate pins: every name crosses,
    // in order.
    let compiled: Vec<String> = TreeSitter
        .grammars()
        .into_iter()
        .map(|grammar| grammar.0)
        .collect();
    assert_eq!(names, compiled);
    assert!(names.contains(&"rust".to_owned()));
}

#[test]
fn edits_made_through_a_document_are_reparsed_to_the_tree_a_fresh_parse_gives() {
    refresh_at_once();
    let document = Document::new(RUST);
    assert_eq!(
        syntaxes().attach(&Snapshot::of(&document), "rust"),
        AttachStatus::Attached
    );
    assert!(delivered_is_fresh(&document));

    // One change, through a replace.
    assert!(document.replace(3, 6, "first"));
    assert!(delivered_is_fresh(&document));

    // A transaction of several changes.
    let len = document.snapshot().len();
    let several = transaction(
        len,
        &[(0, 0, "// a\n"), (5, 7, ""), (len - 2, len - 1, " ")],
    );
    document.apply(&several, Origin::default()).unwrap();
    assert!(delivered_is_fresh(&document));

    // Several transactions one after another, with no wait between.
    for piece in ["fn three() {}\n", "struct S;\n", "\n"] {
        let len = document.snapshot().len();
        let at_end = transaction(len, &[(len, len, piece)]);
        document.apply(&at_end, Origin::default()).unwrap();
    }
    assert!(delivered_is_fresh(&document));

    // An inverse, applied through the document.
    let last = document.snapshot().revision();
    document
        .apply_inverse(editor_text::Revision::new(1), last, Origin::default())
        .unwrap();
    assert!(delivered_is_fresh(&document));
    assert_eq!(document.read(), RUST);

    // An edit script, as a reload applies one, through the document.
    let base = document.snapshot().revision().get();
    let source = editor_text::Text::from(format!("{RUST}fn four() {{}}\n").as_str()).snapshot();
    let steps = [
        Step::Retain(RUST.len()),
        Step::Insert {
            start: RUST.len(),
            count: source.len() - RUST.len(),
        },
    ];
    document
        .apply_script(base, &source, &steps, Origin::default())
        .unwrap();
    assert!(delivered_is_fresh(&document));
}

/// A query made through C: the handle, or the refusal's status, kind and
/// offset.
fn query_new(grammar: &str, source: &str) -> RawQuery {
    let mut raw = MaybeUninit::<RawQuery>::uninit();
    // SAFETY: each pointer and length are a slice alive for the call, and
    // `raw` is writable for one record.
    unsafe {
        editor_ffi_syntax_query_new(
            grammar.as_ptr(),
            grammar.len(),
            source.as_ptr(),
            source.len(),
            raw.as_mut_ptr(),
        );
    }
    // SAFETY: the call filled the record.
    unsafe { raw.assume_init() }
}

/// What `query` answers of the range of `snapshot` through C: the status,
/// and the words.
fn captures(
    snapshot: *const Snapshot,
    query: *const SyntaxQuery,
    start: usize,
    end: usize,
) -> (u64, Vec<u64>) {
    let mut raw = MaybeUninit::<RawWords>::uninit();
    // SAFETY: both handles are live, and `raw` is writable for one record.
    unsafe { editor_ffi_syntax_captures(snapshot, query, start, end, raw.as_mut_ptr()) };
    // SAFETY: the call filled the record.
    let raw = unsafe { raw.assume_init() };
    (raw.status, words(&take(raw.words, raw.len)))
}

#[expect(
    clippy::disallowed_methods,
    reason = "inferred-waits W84: a delivery of the snapshot's revision or a newer one, on the C function `editor_ffi_syntax_settle`"
)]
#[test]
fn a_query_is_answered_only_from_a_tree_of_the_snapshots_revision() {
    // SAFETY: the text's bytes are alive for the call.
    let document = unsafe { editor_ffi_document_new(RUST.as_ptr(), RUST.len()) };
    // SAFETY: the document is live.
    let before = unsafe { editor_ffi_document_snapshot(document) };
    let made = query_new("rust", "(function_item name: (identifier) @name)");
    assert_eq!(made.status, QueryStatus::Made as u64);
    let query = made.query;

    // Not attached yet.
    assert_eq!(
        captures(before, query, 0, 4).0,
        CapturesStatus::NotAttached as u64
    );
    // SAFETY: the snapshot is live, and the grammar's bytes alive for the
    // call.
    let attached = unsafe { editor_ffi_syntax_attach(before, "rust".as_ptr(), 4) };
    assert_eq!(attached, AttachStatus::Attached as u64);
    // SAFETY: the snapshot is live.
    assert!(unsafe { editor_ffi_syntax_settle(before, BOUND.as_millis()) });
    assert_eq!(
        captures(before, query, 0, RUST.len()),
        (
            CapturesStatus::Answered as u64,
            vec![2, 0, 0, 3, 6, 0, 0, 16, 19]
        )
    );

    // An edit: the snapshot taken after it has no tree until one is
    // delivered, and the earlier snapshot's revision is no longer the
    // delivered tree's once one is.
    // SAFETY: the document is live.
    let text = unsafe { &*document };
    assert!(text.replace(0, 0, "fn zero() {}\n"));
    // SAFETY: the document is live.
    let after = unsafe { editor_ffi_document_snapshot(document) };
    let (status, _) = captures(after, query, 0, 4);
    assert!(
        status == CapturesStatus::NotParsed as u64 || status == CapturesStatus::Answered as u64
    );
    // SAFETY: the snapshot is live.
    assert!(unsafe { editor_ffi_syntax_settle(after, BOUND.as_millis()) });
    assert_eq!(
        captures(before, query, 0, 4).0,
        CapturesStatus::NotParsed as u64
    );
    let (status, found) = captures(after, query, 0, 13);
    assert_eq!(status, CapturesStatus::Answered as u64);
    assert_eq!(found, [1, 0, 0, 3, 7]);

    // A range that is not two positions in order, and a query of another
    // grammar.
    assert_eq!(
        captures(after, query, 5, 2).0,
        CapturesStatus::BadRange as u64
    );
    assert_eq!(
        captures(after, query, 0, 10_000).0,
        CapturesStatus::BadRange as u64
    );
    let json = query_new("json", "(number) @n");
    assert_eq!(
        captures(after, json.query, 0, 4).0,
        CapturesStatus::WrongGrammar as u64
    );

    // Detached, and attached again: then freeing the document ends it.
    // SAFETY: the snapshot is live.
    assert!(unsafe { editor_ffi_syntax_detach(after) });
    assert_eq!(
        captures(after, query, 0, 4).0,
        CapturesStatus::NotAttached as u64
    );
    // SAFETY: as above.
    unsafe { editor_ffi_syntax_attach(after, "rust".as_ptr(), 4) };
    // SAFETY: the document is live, and is not used again.
    unsafe { editor_ffi_document_free(document) };
    assert_eq!(
        captures(after, query, 0, 4).0,
        CapturesStatus::NotAttached as u64
    );

    // SAFETY: each handle is live and freed once.
    unsafe {
        editor_ffi_syntax_query_free(query);
        editor_ffi_syntax_query_free(json.query);
        editor_ffi_snapshot_free(before);
        editor_ffi_snapshot_free(after);
    }
}

#[test]
fn a_snapshot_no_document_holds_and_an_unknown_grammar_are_refused() {
    let loaded = Snapshot::loaded(editor_text::Text::from(RUST).snapshot());
    assert_eq!(syntaxes().attach(&loaded, "rust"), AttachStatus::NoDocument);

    let document = Document::new(RUST);
    assert_eq!(
        syntaxes().attach(&Snapshot::of(&document), "cobol"),
        AttachStatus::UnknownGrammar
    );
    assert_eq!(
        query_new("cobol", "(x) @x").status,
        QueryStatus::UnknownGrammar as u64
    );
}

#[test]
fn a_refused_query_crosses_with_its_kind_and_offset_and_a_made_one_with_its_names() {
    let refused = query_new("json", "(object) @o\n(no_such_kind) @x");
    assert_eq!(refused.status, QueryStatus::Refused as u64);
    assert_eq!(refused.kind, kind_tag(QueryErrorKind::NodeType));
    assert_eq!(refused.offset, 13);
    assert!(refused.query.is_null());

    let made = query_new("json", "(pair key: (string) @key value: (_) @value)");
    let mut raw = MaybeUninit::<RawStrings>::uninit();
    // SAFETY: the query is live, and `raw` writable for one record.
    unsafe { editor_ffi_syntax_capture_names(made.query, raw.as_mut_ptr()) };
    // SAFETY: the call filled the record.
    assert_eq!(strings(unsafe { raw.assume_init() }), ["key", "value"]);
    // SAFETY: the query is live and freed once.
    unsafe { editor_ffi_syntax_query_free(made.query) };
}
