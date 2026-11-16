//! Highlighting wired to real documents, the real adapter and the display:
//! a document highlighted through the C functions, edited, and reparsed is
//! drawn as a fresh highlight of its text draws it; the adapter keeps the
//! layout's spans contract; and a published scene paints a keyword in its
//! face.
//!
//! Every test runs on the process's syntax service, as the edit paths reach
//! it (the module docs of `editor_ffi::syntax`), in parallel: each makes
//! documents of its own. A wait for a delivery blocks on the session with a
//! bound, and nothing sleeps.

use std::mem::MaybeUninit;
use std::ops::Range;
use std::slice;
use std::time::Duration;

use editor_ffi::display::{Display, WireFace, WireScene, WireView};
use editor_ffi::document::{Document, RawText};
use editor_ffi::snapshot::Snapshot;
use editor_ffi::syntax::{
    AttachStatus, HighlightStatus, QueryStatus, RawQuery, ShippedStatus, SyntaxQuery,
    editor_ffi_syntax_highlight, editor_ffi_syntax_query_free, editor_ffi_syntax_query_new,
    editor_ffi_syntax_shipped_query, strings_words, syntaxes,
};
use editor_ffi::text::editor_ffi_text_free;
use editor_layout::face::{Color, Face};
use editor_layout::scene::{Padding, spans_contract};
use editor_syntax::highlight::{self, Highlighter};
use editor_syntax::{GrammarName, QueryKind, Syntax};
use editor_syntax_treesitter::TreeSitter;
use editor_text::{ChangeSet, Origin, Transaction};

/// The longest a test waits for a delivery.
const BOUND: Duration = Duration::from_secs(10);

/// The Rust fixture the highlights are drawn over.
const ITEMS: &str = include_str!("../../../tests/syntax/rust/items.rs");

/// The source of `grammar`'s shipped highlights, asked through C; or the
/// status of the refusal.
fn shipped(grammar: &str, kind: u8) -> Result<String, u64> {
    let mut raw = MaybeUninit::<RawText>::uninit();
    // SAFETY: the grammar's bytes are alive for the call, and `raw` is
    // writable for one record.
    let status = unsafe {
        editor_ffi_syntax_shipped_query(grammar.as_ptr(), grammar.len(), kind, raw.as_mut_ptr())
    };
    if status != ShippedStatus::Shipped as u64 {
        return Err(status);
    }
    // SAFETY: the call filled the record.
    let raw = unsafe { raw.assume_init() };
    // SAFETY: the library lent `text_len` bytes at `text`.
    let source = unsafe { slice::from_raw_parts(raw.text, raw.text_len) }.to_vec();
    // SAFETY: the buffer came from the library and is handed back once.
    unsafe { editor_ffi_text_free(raw.text, raw.text_len) };
    Ok(String::from_utf8(source).unwrap())
}

/// A query of `grammar` made through C.
fn query_new(grammar: &str, source: &str) -> *mut SyntaxQuery {
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
    let raw = unsafe { raw.assume_init() };
    assert_eq!(raw.status, QueryStatus::Made as u64);
    raw.query
}

/// Highlights `snapshot`'s document with `query` in `faces` through C, the
/// faces as a list of strings, and returns the status.
fn highlight_through_c(snapshot: &Snapshot, query: *const SyntaxQuery, faces: &[String]) -> u64 {
    let words = strings_words(faces);
    let strings = faces.concat();
    // SAFETY: the handles are live, and each buffer is alive for the call.
    unsafe {
        editor_ffi_syntax_highlight(
            snapshot,
            query,
            words.as_ptr(),
            words.len(),
            strings.as_ptr(),
            strings.len(),
        )
    }
}

/// The capture names of `source`, compiled for `grammar`, and the face
/// each is drawn in by the shipped default: `syntax.` and its name.
fn names_and_faces(grammar: &str, source: &str) -> (Vec<String>, Vec<String>) {
    let query = TreeSitter
        .compile(&GrammarName::new(grammar), source)
        .unwrap();
    let names = TreeSitter.capture_names(&query);
    let faces = names.iter().map(|name| format!("syntax.{name}")).collect();
    (names, faces)
}

/// What the service draws over the whole of `document`'s text as it is now,
/// each span with its face's name; none when it draws nothing.
fn drawn(document: &Document) -> Option<Vec<(Range<usize>, String)>> {
    let text = document.snapshot();
    let at = syntaxes().spans(document.key())?.at(&text)?;
    let mut spans = Vec::new();
    at.spans(0..text.len(), &mut spans);
    Some(
        spans
            .into_iter()
            .map(|(bytes, face)| (bytes, at.faces()[face].clone()))
            .collect(),
    )
}

/// A fresh highlight of `document`'s text with `source` of `grammar`, in
/// `faces`, each span with its face's name.
fn fresh(
    document: &Document,
    grammar: &str,
    source: &str,
    faces: &[String],
) -> Vec<(Range<usize>, String)> {
    let grammar = GrammarName::new(grammar);
    let query = TreeSitter.compile(&grammar, source).unwrap();
    let count = TreeSitter.capture_names(&query).len();
    let faces = faces.iter().cloned().map(Some).collect();
    let highlighter = Highlighter::new(std::sync::Arc::new(query), count, faces).unwrap();
    let mut parser = TreeSitter.parser(&grammar).unwrap();
    highlight::fresh(
        &TreeSitter,
        &highlighter,
        None,
        &mut parser,
        &document.snapshot(),
    )
    .into_iter()
    .map(|span| (span.bytes, highlighter.names()[span.face].clone()))
    .collect()
}

/// The offset of `needle` in `document`'s text, which holds it.
fn find(document: &Document, needle: &str) -> usize {
    document.read().find(needle).expect("the text holds it")
}

/// Applies one transaction to `document`: each change a range of the text
/// as it is, in order and apart, and what replaces it.
fn apply(document: &Document, changes: &[(Range<usize>, &str)]) {
    let len = document.snapshot().len();
    let mut set = ChangeSet::new();
    let mut kept = 0;
    for (range, text) in changes {
        set.retain(range.start - kept);
        set.insert(text);
        set.delete(range.end - range.start);
        kept = range.end;
    }
    set.retain(len - kept);
    document
        .apply(&Transaction::new(set), Origin::default())
        .unwrap();
}

/// A document of [`ITEMS`], attached to `rust` and highlighted with its
/// shipped query through C, each capture in `syntax.` and its name; and
/// that query's source and faces. The query's handle is freed once the
/// highlighter is set: the highlighter keeps the query.
fn highlighted_items() -> (Document, String, Vec<String>) {
    let document = Document::new(ITEMS);
    let snapshot = Snapshot::of(&document);
    assert_eq!(syntaxes().attach(&snapshot, "rust"), AttachStatus::Attached);
    let source = shipped("rust", 0).unwrap();
    let (_, faces) = names_and_faces("rust", &source);
    let query = query_new("rust", &source);
    assert_eq!(
        highlight_through_c(&snapshot, query, &faces),
        HighlightStatus::Highlighted as u64
    );
    // SAFETY: `query` is a live handle, freed once.
    unsafe { editor_ffi_syntax_query_free(query) };
    (document, source, faces)
}

#[test]
fn highlights_after_edits_and_a_reparse_equal_a_fresh_highlight() {
    let (document, source, faces) = highlighted_items();
    assert!(syntaxes().settle(&Snapshot::of(&document), BOUND));
    assert_eq!(
        drawn(&document),
        Some(fresh(&document, "rust", &source, &faces))
    );

    // A new `fn`, which holds a string.
    let end = document.snapshot().len();
    apply(
        &document,
        &[(
            end..end,
            "\nfn greet() -> &'static str {\n    \"hello\"\n}\n",
        )],
    );
    // An insert inside the string.
    let at = find(&document, "hello") + 2;
    assert!(document.replace(at, at, "y, wor"));
    // A delete across lines: from inside the doc comment of `Point` to
    // inside its derive.
    let start = find(&document, "point on");
    let stop = find(&document, "Clone");
    assert!(document.replace(start, stop, ""));
    // A line commented out.
    let line = find(&document, "    counts\n}");
    assert!(document.replace(line, line, "// "));
    // One transaction of several changes.
    let first = find(&document, "use std");
    let second = find(&document, "pub row");
    let third = find(&document, "-> Self");
    apply(
        &document,
        &[
            (first..first, "#![allow(dead_code)]\n"),
            (second..second + 3, "pub(crate)"),
            (third..third + 7, "-> Point"),
        ],
    );

    let snapshot = Snapshot::of(&document);
    assert!(syntaxes().settle(&snapshot, BOUND));
    let drawn = drawn(&document).expect("highlights of the delivered tree");
    assert_eq!(drawn, fresh(&document, "rust", &source, &faces));
    // Something is drawn: a keyword, the string and the comment.
    for face in ["syntax.keyword", "syntax.string", "syntax.comment"] {
        assert!(drawn.iter().any(|(_, drawn)| drawn == face), "{face}");
    }
}

#[test]
fn the_service_keeps_the_layout_spans_contract() {
    let (document, _, _) = highlighted_items();
    let snapshot = Snapshot::of(&document);
    assert!(syntaxes().settle(&snapshot, BOUND));
    let spans = syntaxes().spans(snapshot.key()).unwrap();
    assert_eq!(
        spans_contract::check(&*spans, &document.snapshot()),
        [""; 0]
    );

    // Carried through an edit not yet parsed too, whatever the worker has
    // done by the time it is asked.
    let at = find(&document, "Point {");
    assert!(document.replace(at, at + 5, "Pößition"));
    assert_eq!(
        spans_contract::check(&*spans, &document.snapshot()),
        [""; 0]
    );
}

#[test]
fn a_shipped_query_crosses_as_its_source_or_a_status() {
    assert_eq!(
        shipped("rust", 0),
        Ok(TreeSitter
            .shipped_query(&GrammarName::new("rust"), QueryKind::Highlights)
            .unwrap())
    );
    assert_eq!(
        shipped("cobol", 0),
        Err(ShippedStatus::UnknownGrammar as u64)
    );
    assert_eq!(
        shipped("json", 9),
        Err(ShippedStatus::NoShippedQuery as u64)
    );
    assert_eq!(
        shipped("cobol", 9),
        Err(ShippedStatus::UnknownGrammar as u64)
    );
}

#[test]
fn a_highlight_is_refused_with_its_status() {
    let document = Document::new("{\"a\": [1, true]}");
    let snapshot = Snapshot::of(&document);
    let source = shipped("json", 0).unwrap();
    let (_, faces) = names_and_faces("json", &source);
    let json = query_new("json", &source);
    let rust = query_new("rust", "(identifier) @variable");

    assert_eq!(
        highlight_through_c(&snapshot, json, &faces),
        HighlightStatus::NotAttached as u64
    );
    assert_eq!(syntaxes().attach(&snapshot, "json"), AttachStatus::Attached);
    assert_eq!(
        highlight_through_c(&snapshot, rust, &["syntax.variable".to_owned()]),
        HighlightStatus::WrongGrammar as u64
    );
    assert_eq!(
        highlight_through_c(&snapshot, json, &faces[1..]),
        HighlightStatus::BadFaces as u64
    );
    // Words that do not spell a list of strings.
    let words = strings_words(&["toolong".to_owned()]);
    // SAFETY: the handles are live, and each buffer is alive for the call.
    let malformed = unsafe {
        editor_ffi_syntax_highlight(
            &snapshot,
            json,
            words.as_ptr(),
            words.len(),
            "x".as_ptr(),
            1,
        )
    };
    assert_eq!(malformed, HighlightStatus::BadFaces as u64);
    assert_eq!(
        highlight_through_c(&snapshot, json, &faces),
        HighlightStatus::Highlighted as u64
    );
    // SAFETY: both handles are live, each freed once.
    unsafe {
        editor_ffi_syntax_query_free(json);
        editor_ffi_syntax_query_free(rust);
    }
}

#[test]
fn an_attach_with_the_same_grammar_keeps_the_highlights_and_another_grammar_drops_them() {
    let (document, source, faces) = highlighted_items();
    let snapshot = Snapshot::of(&document);
    assert!(syntaxes().settle(&snapshot, BOUND));
    let before = drawn(&document).unwrap();

    assert_eq!(syntaxes().attach(&snapshot, "rust"), AttachStatus::Attached);
    assert_eq!(drawn(&document), Some(before));
    assert_eq!(
        drawn(&document),
        Some(fresh(&document, "rust", &source, &faces))
    );

    assert_eq!(syntaxes().attach(&snapshot, "json"), AttachStatus::Attached);
    assert_eq!(drawn(&document), None);
}

#[test]
fn a_published_scene_draws_the_highlights() {
    const RED: Color = Color::rgb(0xcc, 0, 0);
    let (document, _, _) = highlighted_items();
    let snapshot = Snapshot::of(&document);
    assert!(syntaxes().settle(&snapshot, BOUND));
    let display = Display::cells(8, 16);
    let wire = WireScene {
        size: [960, 640],
        views: vec![WireView {
            id: 1,
            rect: [0, 0, 960, 640],
            snapshot: Some(0),
            scroll: None,
            selections: vec![],
            cursor_shape: 0,
            cursor_face: "cursor".to_owned(),
            decorations: vec![],
            status: vec![],
            status_face: None,
            padding: Padding::default(),
        }],
        faces: Some(vec![WireFace {
            name: "syntax.keyword".to_owned(),
            face: Face {
                foreground: Some(RED),
                ..Face::default()
            },
        }]),
        ..WireScene::default()
    };
    let (words, strings) = wire.encode();
    assert!(display.publish(&words, &strings, &[&snapshot]));

    let frame = display.latest();
    let at = find(&document, "fn count");
    let row = frame.views[0]
        .rows
        .iter()
        .find(|row| row.bytes.start == at)
        .expect("the row of `fn count`");
    let (bytes, paint) = &row.runs[0];
    assert_eq!(*bytes, 0..2);
    assert_eq!(paint.foreground, RED);
    // The name after it is not a keyword.
    assert_ne!(row.runs[1].1.foreground, RED);
}
