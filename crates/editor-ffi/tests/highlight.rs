//! Highlighting wired to real documents, the real adapter and the display:
//! a document highlighted through the C functions, edited, and reparsed is
//! drawn as a fresh highlight of its text draws it; the adapter keeps the
//! layout's spans contract; and a published scene paints a keyword in its
//! face. The same holds of a Markdown document given its injections through
//! the C functions: its fences are drawn in their languages' captures over
//! the host's spans.
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
    AttachStatus, HighlightStatus, InjectLanguageStatus, InjectStatus, QueryStatus, RawQuery,
    ShippedStatus, SyntaxQuery, editor_ffi_syntax_highlight, editor_ffi_syntax_inject,
    editor_ffi_syntax_inject_language, editor_ffi_syntax_query_free, editor_ffi_syntax_query_new,
    editor_ffi_syntax_refresh_after, editor_ffi_syntax_shipped_query, strings_words, syntaxes,
};
use editor_ffi::text::editor_ffi_text_free;
use editor_layout::face::{Color, Face};
use editor_layout::scene::{Padding, spans_contract};
use editor_syntax::highlight::{self, Highlighter};
use editor_syntax::inject::{Injections, Language};
use editor_syntax::{GrammarName, QueryKind, Syntax};
use editor_syntax_treesitter::{TreeSitter, TreeSitterQuery};
use editor_text::{ChangeSet, Origin, Transaction};

/// The longest a test waits for a delivery.
const BOUND: Duration = Duration::from_secs(10);

/// Has the process's service refresh a text as soon as it is quiet, through
/// C: what a test that waits for [`settled_quiet`] sets before its first
/// edit, since an edit's incremental reparse equals a fresh parse only
/// once the text is quiet, and an edit's deadline is set with the interval
/// at the time of the edit. Every test of this binary that sets the
/// interval sets the same value, so tests in parallel agree.
fn refresh_at_once() {
    editor_ffi_syntax_refresh_after(0);
}

/// Waits, with a bound, for the tree delivered of `document` to be exact
/// for its text as it is now. The test sets the interval first
/// ([`refresh_at_once`]).
fn settled_quiet(document: &Document) -> bool {
    syntaxes().settle_exact(&Snapshot::of(document), BOUND)
}

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
    refresh_at_once();
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

    assert!(settled_quiet(&document));
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

/// The Markdown fixture of fences.
const FENCED: &str = include_str!("../../../tests/syntax/markdown/fenced.md");

/// The languages a Markdown document is given: each with its shipped
/// highlights, a face for each capture, and its shipped injections.
const LANGUAGES: [&str; 3] = ["rust", "json", "markdown_inline"];

/// The kind tag of injections.
const INJECTIONS: u8 = 1;

/// `grammar`'s shipped highlights as a highlighter, each capture in
/// `syntax.` and its name.
fn highlighter_of(grammar: &str) -> Highlighter<TreeSitterQuery> {
    let source = shipped(grammar, 0).unwrap();
    let (names, faces) = names_and_faces(grammar, &source);
    let query = TreeSitter
        .compile(&GrammarName::new(grammar), &source)
        .unwrap();
    let faces = faces.into_iter().map(Some).collect();
    Highlighter::new(std::sync::Arc::new(query), names.len(), faces).unwrap()
}

/// The injections a Markdown document is given, as the core holds them:
/// what a fresh highlight is drawn with.
fn markdown_injections() -> Injections<TreeSitterQuery> {
    let compiled = |grammar: &str, source: String| {
        std::sync::Arc::new(
            TreeSitter
                .compile(&GrammarName::new(grammar), &source)
                .unwrap(),
        )
    };
    Injections {
        query: Some(compiled(
            "markdown",
            shipped("markdown", INJECTIONS).unwrap(),
        )),
        languages: LANGUAGES
            .iter()
            .map(|grammar| {
                let language = Language {
                    grammar: GrammarName::new(*grammar),
                    highlighter: std::sync::Arc::new(highlighter_of(grammar)),
                    injections: shipped(grammar, INJECTIONS)
                        .ok()
                        .map(|source| compiled(grammar, source)),
                };
                ((*grammar).to_owned(), language)
            })
            .collect(),
    }
}

/// A document of `text`, attached to `markdown`, highlighted with its
/// shipped query and given its shipped injections and the languages of
/// [`LANGUAGES`], all through C, each capture in `syntax.` and its name.
fn injected_markdown(text: &str) -> Document {
    let document = Document::new(text);
    let snapshot = Snapshot::of(&document);
    assert_eq!(
        syntaxes().attach(&snapshot, "markdown"),
        AttachStatus::Attached
    );
    let source = shipped("markdown", 0).unwrap();
    let (_, faces) = names_and_faces("markdown", &source);
    let query = query_new("markdown", &source);
    assert_eq!(
        highlight_through_c(&snapshot, query, &faces),
        HighlightStatus::Highlighted as u64
    );
    let injections = query_new("markdown", &shipped("markdown", INJECTIONS).unwrap());
    // SAFETY: both handles are live.
    let injected = unsafe { editor_ffi_syntax_inject(&snapshot, injections) };
    assert_eq!(injected, InjectStatus::Injected as u64);
    for grammar in LANGUAGES {
        let source = shipped(grammar, 0).unwrap();
        let (_, faces) = names_and_faces(grammar, &source);
        let highlights = query_new(grammar, &source);
        let own = shipped(grammar, INJECTIONS)
            .map(|source| query_new(grammar, &source))
            .unwrap_or(std::ptr::null_mut());
        let words = strings_words(&faces);
        let strings = faces.concat();
        // SAFETY: the handles are live or null, and each buffer is alive
        // for the call.
        let status = unsafe {
            editor_ffi_syntax_inject_language(
                &snapshot,
                grammar.as_ptr(),
                grammar.len(),
                highlights,
                words.as_ptr(),
                words.len(),
                strings.as_ptr(),
                strings.len(),
                own,
            )
        };
        assert_eq!(status, InjectLanguageStatus::Injected as u64);
        // SAFETY: each handle is live, freed once: the language keeps its
        // queries.
        unsafe {
            editor_ffi_syntax_query_free(highlights);
            if !own.is_null() {
                editor_ffi_syntax_query_free(own);
            }
        }
    }
    // SAFETY: each handle is live, freed once.
    unsafe {
        editor_ffi_syntax_query_free(query);
        editor_ffi_syntax_query_free(injections);
    }
    document
}

/// A fresh highlight of `text` with `grammar`'s shipped highlights, and
/// with `injections` when given, each span with its face's name.
fn fresh_with(
    text: &str,
    grammar: &str,
    injections: Option<&Injections<TreeSitterQuery>>,
) -> Vec<(Range<usize>, String)> {
    let highlighter = highlighter_of(grammar);
    let (faces, _) = highlight::face_table(&highlighter, injections);
    let mut parser = TreeSitter.parser(&GrammarName::new(grammar)).unwrap();
    let snapshot = Document::new(text).snapshot();
    highlight::fresh(
        &TreeSitter,
        &highlighter,
        injections,
        &mut parser,
        &snapshot,
    )
    .into_iter()
    .map(|span| (span.bytes, faces[span.face].clone()))
    .collect()
}

/// The spans of `spans` within `range`, moved back by its start.
fn within(spans: &[(Range<usize>, String)], range: &Range<usize>) -> Vec<(Range<usize>, String)> {
    spans
        .iter()
        .filter(|(bytes, _)| range.start <= bytes.start && bytes.end <= range.end)
        .map(|(bytes, face)| {
            (
                bytes.start - range.start..bytes.end - range.start,
                face.clone(),
            )
        })
        .collect()
}

#[test]
fn a_fenced_rust_block_in_markdown_is_drawn_with_rusts_captures() {
    let document = injected_markdown(FENCED);
    assert!(syntaxes().settle(&Snapshot::of(&document), BOUND));
    let drawn = drawn(&document).unwrap();

    // The host's spans first, as a Markdown highlight alone draws them.
    let host = fresh_with(FENCED, "markdown", None);
    assert_eq!(drawn[..host.len()], host[..]);
    let layers = &drawn[host.len()..];

    // Over the Rust fence's content: the content alone, highlighted as
    // Rust with its own injections (its `println!`), shifted.
    let rust = "fn main() {\n    let x = (1, [2, 3]);\n    println!(\"{x:?}\");\n}\n";
    let at = FENCED.find(rust).unwrap();
    let languages = markdown_injections().languages;
    let rust_injections = Injections {
        query: languages["rust"].injections.clone(),
        languages,
    };
    let alone = fresh_with(rust, "rust", Some(&rust_injections));
    assert_eq!(within(layers, &(at..at + rust.len())), alone);
    assert!(alone.iter().any(|(_, face)| face == "syntax.keyword"));

    // The JSON fence in JSON's.
    let json = "{\"a\": [1, true, null]}\n";
    let at = FENCED.find(json).unwrap();
    assert_eq!(
        within(layers, &(at..at + json.len())),
        fresh_with(json, "json", None)
    );

    // No layer's span covers a `> ` of the quoted fence.
    let quoted = FENCED.find("> ```rust").unwrap();
    let markers: Vec<usize> = FENCED[quoted..]
        .match_indices("\n> ")
        .map(|(offset, _)| quoted + offset + 1)
        .take(4)
        .collect();
    for marker in markers {
        assert!(
            layers
                .iter()
                .all(|(bytes, _)| bytes.end <= marker || marker + 2 <= bytes.start),
            "a span over the `> ` at {marker}"
        );
    }
}

#[test]
fn injected_highlights_after_edits_and_a_reparse_equal_a_fresh_highlight() {
    refresh_at_once();
    let document = injected_markdown(FENCED);
    assert!(syntaxes().settle(&Snapshot::of(&document), BOUND));

    // An insert inside the Rust fence.
    let at = find(&document, "let x") + 4;
    assert!(document.replace(at, at, "y, "));
    // A new fence typed, at the end.
    let end = document.snapshot().len();
    assert!(document.replace(end, end, "\n```rust\nconst N: u8 = 1;\n```\n"));
    // A fence's info string changed from `rust` to `json`.
    let listed = find(&document, "```rust\n  struct") + 3;
    assert!(document.replace(listed, listed + 4, "json"));
    // A fence's closing line deleted: the JSON one's.
    let closing = find(&document, "null]}\n```\n") + "null]}\n".len();
    assert!(document.replace(closing, closing + 4, ""));

    assert!(settled_quiet(&document));
    let text = document.read().to_string();
    let drawn = drawn(&document).unwrap();
    assert_eq!(
        drawn,
        fresh_with(&text, "markdown", Some(&markdown_injections()))
    );
    assert!(drawn.iter().any(|(_, face)| face == "syntax.keyword"));
}

#[test]
fn markdown_emphasis_and_inline_code_are_drawn_with_the_inline_grammars_captures() {
    let text = "Some *emphasis* and `code`.\n";
    let document = injected_markdown(text);
    assert!(syntaxes().settle(&Snapshot::of(&document), BOUND));

    let drawn = drawn(&document).unwrap();
    let emphasis = find(&document, "*emphasis*");
    let code = find(&document, "`code`");
    let at = |range: Range<usize>, face: &str| (range, face.to_owned());
    assert!(drawn.contains(&at(emphasis..emphasis + 10, "syntax.text.emphasis")));
    assert!(drawn.contains(&at(code..code + 6, "syntax.text.literal")));
    assert_eq!(
        drawn,
        fresh_with(text, "markdown", Some(&markdown_injections()))
    );
}

#[test]
fn the_service_keeps_the_layout_spans_contract_with_layers() {
    let document = injected_markdown(FENCED);
    let snapshot = Snapshot::of(&document);
    assert!(syntaxes().settle(&snapshot, BOUND));
    let spans = syntaxes().spans(snapshot.key()).unwrap();
    assert_eq!(
        spans_contract::check(&*spans, &document.snapshot()),
        [""; 0]
    );

    // Carried through an edit not yet parsed too.
    let at = find(&document, "fn main");
    assert!(document.replace(at, at + 2, "pub fn é"));
    assert_eq!(
        spans_contract::check(&*spans, &document.snapshot()),
        [""; 0]
    );
}

#[test]
fn a_published_scene_draws_a_fenced_rust_keyword() {
    const RED: Color = Color::rgb(0xcc, 0, 0);
    let document = injected_markdown(FENCED);
    let snapshot = Snapshot::of(&document);
    assert!(syntaxes().settle(&snapshot, BOUND));
    let display = Display::cells(8, 16);
    let wire = WireScene {
        size: [960, 1280],
        views: vec![WireView {
            id: 1,
            rect: [0, 0, 960, 1280],
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
    let at = find(&document, "fn main");
    let row = frame.views[0]
        .rows
        .iter()
        .find(|row| row.bytes.start == at)
        .expect("the row of `fn main`");
    let (bytes, paint) = &row.runs[0];
    assert_eq!(*bytes, 0..2);
    assert_eq!(paint.foreground, RED);
    assert_ne!(row.runs[1].1.foreground, RED);
}
