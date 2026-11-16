//! The display handle and its C functions, called the way the C glue calls
//! them: with raw pointers and out-records of words.
//!
//! What layout answers is `editor-layout`'s rule. So every answer here is
//! compared with what an `editor_layout::Layout` over the same fake shaper
//! answers for the same text, called directly in the same test: what is
//! pinned is that the values cross, and that the handle reaches the
//! document's log.
//!
//! This is an integration test of its own, so a process of its own: it
//! counts the live displays of its process, and makes documents, which
//! `tests/c_api.rs` counts in its.

use std::mem::MaybeUninit;
use std::slice;
use std::sync::{Mutex, MutexGuard, PoisonError};

use editor_ffi::display::{
    DisplayStatus, WireFace, WireScene, WireView, editor_ffi_display_define,
    editor_ffi_display_frame_rows, editor_ffi_display_frame_text, editor_ffi_display_free,
    editor_ffi_display_heights, editor_ffi_display_live, editor_ffi_display_move,
    editor_ffi_display_new_cells, editor_ffi_display_publish, editor_ffi_display_rows,
    editor_ffi_display_scene, encode_definitions,
};
use editor_ffi::document::{
    Document, RawText, editor_ffi_document_free, editor_ffi_document_new,
    editor_ffi_document_replace,
};
use editor_ffi::log::{RawWords, editor_ffi_document_forget};
use editor_ffi::marker::{self, RawMarked, editor_ffi_document_mark};
use editor_ffi::snapshot::{
    Snapshot, editor_ffi_document_snapshot, editor_ffi_snapshot_free, editor_ffi_snapshot_info,
};
use editor_ffi::text::editor_ffi_text_free;
use editor_layout::Layout;
use editor_layout::face::{Color, Face, FaceDef, Underline, UnderlineStyle};
use editor_layout::scene::{
    Cursor, CursorShape, Decoration, Rect, Scene, Size, StatusField, TextKey, TextRef, View, ViewId,
};
use editor_layout::shaper::fake::CellShaper;
use editor_layout::shaper::{Length, LineHeight, Slant, Weight};
use editor_text::{Anchor, Bias, Marker, Selection, SelectionRange, Text};

/// Held by each test for its whole run: the tests count the live displays
/// of the process, so no two of them run at once.
static ONE_AT_A_TIME: Mutex<()> = Mutex::new(());

/// The lock that keeps this test the only one running.
fn alone() -> MutexGuard<'static, ()> {
    ONE_AT_A_TIME.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A new document holding `text`.
fn document_new(text: &str) -> *mut Document {
    // SAFETY: the pointer and length are those of `text`, alive for the call.
    unsafe { editor_ffi_document_new(text.as_ptr(), text.len()) }
}

/// The words of a filled record, as numbers, with its status; the buffer is
/// handed back.
///
/// # Safety
///
/// `raw` was filled by the library, and its buffer has not been handed
/// back.
unsafe fn take(raw: RawWords) -> (u64, Vec<u64>) {
    // SAFETY: the record's buffer is `len` bytes, owned until handed back.
    let bytes = unsafe { slice::from_raw_parts(raw.words, raw.len) }.to_vec();
    // SAFETY: the buffer came from the library in this record, handed back
    // once.
    unsafe { editor_ffi_text_free(raw.words, raw.len) };
    let words = bytes
        .as_chunks::<8>()
        .0
        .iter()
        .map(|word| u64::from_le_bytes(*word))
        .collect();
    (raw.status, words)
}

/// The rows a display shows of a snapshot, through C, as pairs; or the
/// status of its refusal.
fn rows(
    display: *const editor_ffi::display::Display,
    snapshot: *const Snapshot,
    width: u64,
    height: u64,
    anchor: usize,
) -> Result<Vec<(usize, usize)>, u64> {
    let mut raw = MaybeUninit::<RawWords>::uninit();
    // SAFETY: both handles are live, and `raw` is writable.
    let (status, words) = unsafe {
        editor_ffi_display_rows(display, snapshot, width, height, anchor, raw.as_mut_ptr());
        take(raw.assume_init())
    };
    if status != DisplayStatus::Done as u64 {
        return Err(status);
    }
    assert_eq!(words.len(), 1 + 2 * words[0] as usize);
    Ok(words[1..]
        .as_chunks::<2>()
        .0
        .iter()
        .map(|[start, stop]| (*start as usize, *stop as usize))
        .collect())
}

/// Where a move goes through C: the position and the goal.
fn moved(
    display: *const editor_ffi::display::Display,
    snapshot: *const Snapshot,
    width: u64,
    position: usize,
    lines: i64,
    goal: Option<u64>,
) -> Result<(usize, u64), u64> {
    let mut raw = MaybeUninit::<RawWords>::uninit();
    // SAFETY: both handles are live, and `raw` is writable.
    let (status, words) = unsafe {
        editor_ffi_display_move(
            display,
            snapshot,
            width,
            position,
            lines,
            goal.is_some(),
            goal.unwrap_or(0),
            raw.as_mut_ptr(),
        );
        take(raw.assume_init())
    };
    if status != DisplayStatus::Done as u64 {
        return Err(status);
    }
    Ok((words[0] as usize, words[1]))
}

/// The rows `Layout` itself shows of `text`, as pairs.
fn rows_directly(text: &str, width: f32, height: f32, anchor: usize) -> Vec<(usize, usize)> {
    let mut layout = Layout::new(CellShaper::new(8.0, 16.0));
    let text = TextRef::fixed(TextKey(0), Text::from(text).snapshot());
    layout
        .rows_shown(&text, width, height, anchor)
        .unwrap()
        .into_iter()
        .map(|row| (row.start, row.stop))
        .collect()
}

#[test]
fn a_display_is_live_from_new_until_free_and_answers_the_queries_as_layout_does() {
    let _alone = alone();
    let before = editor_ffi_display_live();
    let display = editor_ffi_display_new_cells(8, 16);
    assert_eq!(editor_ffi_display_live(), before + 1);
    let text = "abcdefgh\nij\n\tk";
    let document = document_new(text);
    // SAFETY: `document` is live.
    let snapshot = unsafe { editor_ffi_document_snapshot(document) };
    assert_eq!(
        rows(display, snapshot, 32, 64, 2),
        Ok(rows_directly(text, 32.0, 64.0, 2))
    );
    let mut layout = Layout::new(CellShaper::new(8.0, 16.0));
    let direct = TextRef::fixed(TextKey(0), Text::from(text).snapshot());
    for (position, lines, goal) in [(1, 1, None), (6, 2, Some(20)), (13, -3, None)] {
        let expected = layout
            .lines_from(&direct, 32.0, position, lines, goal.map(|goal| goal as f32))
            .unwrap();
        assert_eq!(
            moved(display, snapshot, 32, position, lines, goal),
            Ok((expected.position, expected.goal as u64))
        );
    }
    assert_eq!(
        rows(display, snapshot, 32, 64, 99),
        Err(DisplayStatus::BadPosition as u64)
    );
    assert_eq!(
        moved(display, snapshot, 32, 99, 1, None),
        Err(DisplayStatus::BadPosition as u64)
    );
    // SAFETY: each handle is live and freed once.
    unsafe {
        editor_ffi_snapshot_free(snapshot);
        editor_ffi_document_free(document);
        editor_ffi_display_free(display);
    }
    assert_eq!(editor_ffi_display_live(), before);
}

#[test]
fn a_document_whose_log_was_forgotten_is_laid_out_again_from_its_snapshot() {
    let _alone = alone();
    let display = editor_ffi_display_new_cells(8, 16);
    let document = document_new("abcdefgh\nij");
    // SAFETY: `document` is live.
    let first = unsafe { editor_ffi_document_snapshot(document) };
    assert!(rows(display, first, 32, 64, 0).is_ok());
    let inserted = "0123\n";
    // SAFETY: `document` is live, and `inserted` alive for the call.
    let second = unsafe {
        assert!(editor_ffi_document_replace(
            document,
            0,
            0,
            inserted.as_ptr(),
            inserted.len()
        ));
        let mut info = MaybeUninit::uninit();
        let latest = editor_ffi_document_snapshot(document);
        editor_ffi_snapshot_info(latest, info.as_mut_ptr());
        assert!(editor_ffi_document_forget(
            document,
            info.assume_init().revision
        ));
        latest
    };
    assert_eq!(
        rows(display, second, 32, 64, 0),
        Ok(rows_directly("0123\nabcdefgh\nij", 32.0, 64.0, 0))
    );
    // SAFETY: each handle is live and freed once.
    unsafe {
        editor_ffi_snapshot_free(first);
        editor_ffi_snapshot_free(second);
        editor_ffi_document_free(document);
        editor_ffi_display_free(display);
    }
}

/// A copy of a filled text record; its buffer is handed back.
///
/// # Safety
///
/// `raw` was filled by the library, and its buffer has not been handed
/// back.
unsafe fn take_text(raw: RawText) -> String {
    // SAFETY: the record's buffer is `text_len` bytes, owned until handed
    // back, and handed back once.
    unsafe {
        let text =
            String::from_utf8(slice::from_raw_parts(raw.text, raw.text_len).to_vec()).unwrap();
        editor_ffi_text_free(raw.text, raw.text_len);
        text
    }
}

/// Marks `document` with `marker` through C, and returns its number.
fn mark(document: *const Document, marker: &Marker) -> u64 {
    let words = marker::marker_words(marker);
    let mut raw = MaybeUninit::<RawMarked>::uninit();
    // SAFETY: `document` is live, the words alive for the call, and `raw`
    // filled before it is read.
    let marked = unsafe {
        editor_ffi_document_mark(document, words.as_ptr(), words.len(), raw.as_mut_ptr());
        raw.assume_init()
    };
    assert_eq!(marked.status, 0);
    marked.id
}

/// Publishes `scene` to `display` through C, with `handles` as its views'
/// snapshots, and returns whether it was taken.
fn publish(
    display: *const editor_ffi::display::Display,
    words: &[u8],
    strings: &str,
    handles: &[*const Snapshot],
) -> bool {
    // SAFETY: the buffers are alive for the call, and the handles live.
    unsafe {
        editor_ffi_display_publish(
            display,
            words.as_ptr(),
            words.len(),
            strings.as_ptr(),
            strings.len(),
            handles.as_ptr(),
            handles.len(),
        )
    }
}

/// The latest frame of `display` as text, through C.
fn frame_text(display: *const editor_ffi::display::Display) -> String {
    let mut raw = MaybeUninit::uninit();
    // SAFETY: `display` is live, `raw` writable, and filled before it is
    // read.
    unsafe {
        editor_ffi_display_frame_text(display, raw.as_mut_ptr());
        take_text(raw.assume_init())
    }
}

/// The text of the scene published below.
const TEXT: &str = "fn main() {\n\tlet x = 1;\n}";

/// The scene published below, as layout takes it, laid out by `Layout`
/// itself: its markers are the values the document holds.
fn scene_directly() -> Scene {
    Scene {
        size: Size {
            width: 96,
            height: 64,
        },
        views: vec![View {
            id: ViewId(3),
            rect: Rect {
                x: 0,
                y: 0,
                width: 96,
                height: 64,
            },
            text: Some(TextRef::fixed(TextKey(0), Text::from(TEXT).snapshot())),
            scroll: 0,
            selections: vec![Selection::new(vec![SelectionRange::new(3, 7)], 0).unwrap()],
            cursor: Cursor {
                shape: CursorShape::Bar,
                face: "cursor".to_owned(),
            },
            decorations: vec![Decoration {
                start: 0,
                stop: 2,
                face: "keyword".to_owned(),
            }],
            status: vec![StatusField {
                text: "NORMAL".to_owned(),
                face: "mode".to_owned(),
            }],
        }],
        focused: Some(ViewId(3)),
        echo: "hello".to_owned(),
        pending: String::new(),
        preedit: None,
        faces: None,
    }
}

#[test]
fn a_scene_published_through_c_is_laid_out_as_layout_lays_it_out() {
    let _alone = alone();
    let display = editor_ffi_display_new_cells(8, 16);
    let document = document_new(TEXT);
    let scroll = mark(
        document,
        &Marker::Anchor(Anchor {
            offset: 0,
            bias: Bias::Before,
        }),
    );
    let selection = mark(
        document,
        &Marker::Selection(Selection::new(vec![SelectionRange::new(3, 7)], 0).unwrap()),
    );
    // SAFETY: `document` is live.
    let snapshot = unsafe { editor_ffi_document_snapshot(document) };
    let wire = WireScene {
        size: [96, 64],
        focused: Some(3),
        echo: "hello".to_owned(),
        pending: String::new(),
        preedit: None,
        title: String::new(),
        views: vec![WireView {
            id: 3,
            rect: [0, 0, 96, 64],
            snapshot: Some(0),
            scroll: Some(scroll),
            selections: vec![selection],
            cursor_shape: 1,
            cursor_face: "cursor".to_owned(),
            decorations: vec![(0, 2, "keyword".to_owned())],
            status: vec![("NORMAL".to_owned(), "mode".to_owned())],
        }],
        faces: None,
    };
    let (words, strings) = wire.encode();
    assert!(publish(display, &words, &strings, &[snapshot]));
    let mut layout = Layout::new(CellShaper::new(8.0, 16.0));
    let direct = layout.frame(&scene_directly());
    assert_eq!(frame_text(display), direct.describe());
    // The rows of the view, through C.
    let mut raw = MaybeUninit::uninit();
    // SAFETY: `display` is live, and `raw` filled before it is read.
    let (status, rows) = unsafe {
        editor_ffi_display_frame_rows(display, 3, raw.as_mut_ptr());
        take(raw.assume_init())
    };
    let expected: Vec<u64> = std::iter::once(direct.views[0].rows.len() as u64)
        .chain(
            direct.views[0]
                .rows
                .iter()
                .flat_map(|row| [row.bytes.start as u64, row.bytes.end as u64]),
        )
        .collect();
    assert_eq!((status, rows), (0, expected));
    let mut raw = MaybeUninit::uninit();
    // SAFETY: as above.
    let (status, _) = unsafe {
        editor_ffi_display_frame_rows(display, 4, raw.as_mut_ptr());
        take(raw.assume_init())
    };
    assert_eq!(status, 1);
    // The scene comes back as it was sent.
    let (mut back, mut text) = (MaybeUninit::uninit(), MaybeUninit::uninit());
    // SAFETY: as above.
    let (status, back, text) = unsafe {
        editor_ffi_display_scene(display, back.as_mut_ptr(), text.as_mut_ptr());
        let (status, back) = take(back.assume_init());
        (status, back, take_text(text.assume_init()))
    };
    let sent: Vec<u64> = words
        .as_chunks::<8>()
        .0
        .iter()
        .map(|word| u64::from_le_bytes(*word))
        .collect();
    assert_eq!((status, back, text), (0, sent, strings));
    // SAFETY: each handle is live and freed once.
    unsafe {
        editor_ffi_snapshot_free(snapshot);
        editor_ffi_document_free(document);
        editor_ffi_display_free(display);
    }
}

#[test]
fn a_display_nothing_was_published_to_has_no_scene() {
    let _alone = alone();
    let display = editor_ffi_display_new_cells(8, 16);
    let (mut words, mut text) = (MaybeUninit::uninit(), MaybeUninit::uninit());
    // SAFETY: `display` is live, and both records are writable and filled
    // before they are read.
    let (status, words, text) = unsafe {
        editor_ffi_display_scene(display, words.as_mut_ptr(), text.as_mut_ptr());
        let (status, words) = take(words.assume_init());
        (status, words, take_text(text.assume_init()))
    };
    assert_eq!((status, words, text), (1, vec![], String::new()));
    // SAFETY: `display` is live and freed once.
    unsafe { editor_ffi_display_free(display) };
}

/// The scene of one view, numbered 1, of `text` from its start, `width`
/// pixels across and `height` down, and nothing else: what a `WireScene` of
/// one `WireView` with only its id, its rectangle and its snapshot set
/// resolves to. As layout takes it, to lay out with `Layout` itself.
fn plain_scene_directly(text: &str, width: u32, height: u32) -> Scene {
    Scene {
        views: vec![View {
            id: ViewId(1),
            rect: Rect {
                x: 0,
                y: 0,
                width,
                height,
            },
            text: Some(TextRef::fixed(TextKey(0), Text::from(text).snapshot())),
            ..View::default()
        }],
        ..Scene::default()
    }
}

/// The heights a display answers through C: text, status and message.
fn heights(display: *const editor_ffi::display::Display) -> (u64, Vec<u64>) {
    let mut raw = MaybeUninit::<RawWords>::uninit();
    // SAFETY: the handle is live, and `raw` is writable.
    unsafe {
        editor_ffi_display_heights(display, raw.as_mut_ptr());
        take(raw.assume_init())
    }
}

#[test]
fn a_display_answers_the_heights_of_its_rows_at_the_scale_it_was_told() {
    let _alone = alone();
    let display = editor_ffi_display_new_cells(8, 16);
    let mut layout = Layout::new(CellShaper::new(8.0, 16.0));
    let direct = layout.heights();
    assert_eq!(
        heights(display),
        (
            DisplayStatus::Done as u64,
            vec![
                u64::from(direct.text),
                u64::from(direct.status),
                u64::from(direct.message)
            ]
        )
    );
    // Told a scale of 2: the heights, a published scene's rows and a rows
    // query are each at it, as layout's at that scale are.
    // SAFETY: `display` is live.
    unsafe { &*display }.set_scale(2.0);
    layout.set_scale(2.0);
    let direct = layout.heights();
    assert_eq!(heights(display).1, vec![32, 32, 32]);
    assert_eq!(
        heights(display).1,
        vec![
            u64::from(direct.text),
            u64::from(direct.status),
            u64::from(direct.message)
        ]
    );
    let text = "abc\ndef\nghi";
    let document = document_new(text);
    // SAFETY: `document` is live.
    let snapshot = unsafe { editor_ffi_document_snapshot(document) };
    let wire = WireScene {
        views: vec![WireView {
            id: 1,
            rect: [0, 0, 160, 64],
            snapshot: Some(0),
            ..WireView::default()
        }],
        ..WireScene::default()
    };
    let (words, strings) = wire.encode();
    assert!(publish(display, &words, &strings, &[snapshot]));
    // SAFETY: `display` is live.
    let frame = unsafe { &*display }.latest();
    let tall: Vec<f32> = frame.views[0].rows.iter().map(|row| row.height).collect();
    assert_eq!(tall, vec![32.0, 32.0]);
    assert_eq!(
        frame_text(display),
        layout
            .frame(&plain_scene_directly(text, 160, 64))
            .describe()
    );
    let direct = TextRef::fixed(TextKey(0), Text::from(text).snapshot());
    let expected: Vec<(usize, usize)> = layout
        .rows_shown(&direct, 160.0, 64.0, 0)
        .unwrap()
        .into_iter()
        .map(|row| (row.start, row.stop))
        .collect();
    assert_eq!(expected.len(), 2);
    assert_eq!(rows(display, snapshot, 160, 64, 0), Ok(expected));
    // SAFETY: each handle is live and freed once.
    unsafe {
        editor_ffi_snapshot_free(snapshot);
        editor_ffi_document_free(document);
        editor_ffi_display_free(display);
    }
}

/// Defines the faces `words` and `strings` spell on `display` through C,
/// and returns whether they were taken.
fn define(display: *const editor_ffi::display::Display, words: &[u8], strings: &str) -> bool {
    // SAFETY: the buffers are alive for the call, and the handle live.
    unsafe {
        editor_ffi_display_define(
            display,
            words.as_ptr(),
            words.len(),
            strings.as_ptr(),
            strings.len(),
        )
    }
}

#[test]
fn faces_defined_through_c_are_the_faces_of_the_heights_and_of_a_frame_published_after_them() {
    let _alone = alone();
    let display = editor_ffi_display_new_cells(8, 16);
    let taller = WireFace {
        name: "mode-line".to_owned(),
        face: Face {
            line_height: Some(LineHeight::Multiple(128)),
            ..Face::default()
        },
    };
    let (words, strings) = encode_definitions(std::slice::from_ref(&taller));
    assert!(define(display, &words, &strings));
    let mut layout = Layout::new(CellShaper::new(8.0, 16.0));
    layout.define(&[FaceDef {
        name: taller.name.clone(),
        face: taller.face.clone(),
    }]);
    let direct = layout.heights();
    assert_eq!(direct.status, 32);
    assert_eq!(
        heights(display).1,
        vec![
            u64::from(direct.text),
            u64::from(direct.status),
            u64::from(direct.message)
        ]
    );
    // A scene that carries no faces is laid out in them: as layout lays
    // it out once they are defined.
    let text = "abc\ndef\nghi\njkl";
    let document = document_new(text);
    // SAFETY: `document` is live.
    let snapshot = unsafe { editor_ffi_document_snapshot(document) };
    let wire = WireScene {
        views: vec![WireView {
            id: 1,
            rect: [0, 0, 160, 64],
            snapshot: Some(0),
            status: vec![("NORMAL".to_owned(), "mode-line".to_owned())],
            ..WireView::default()
        }],
        ..WireScene::default()
    };
    let (scene_words, scene_strings) = wire.encode();
    assert!(publish(display, &scene_words, &scene_strings, &[snapshot]));
    let mut directly = plain_scene_directly(text, 160, 64);
    directly.views[0].status = vec![StatusField {
        text: "NORMAL".to_owned(),
        face: "mode-line".to_owned(),
    }];
    assert_eq!(frame_text(display), layout.frame(&directly).describe());
    // Words that spell no definitions are refused, and change nothing.
    assert!(!define(display, &words[..words.len() - 8], &strings));
    assert!(!define(display, &words, &format!("{strings}x")));
    assert_eq!(heights(display).1, vec![16, 32, 32]);
    // No definitions undefines every face.
    let (none, none_strings) = encode_definitions(&[]);
    assert!(define(display, &none, &none_strings));
    assert_eq!(heights(display).1, vec![16, 16, 16]);
    // SAFETY: each handle is live and freed once.
    unsafe {
        editor_ffi_snapshot_free(snapshot);
        editor_ffi_document_free(document);
        editor_ffi_display_free(display);
    }
}

#[test]
fn words_that_spell_no_scene_are_refused_and_the_last_frame_is_kept() {
    let _alone = alone();
    let display = editor_ffi_display_new_cells(8, 16);
    let document = document_new("abc");
    // SAFETY: `document` is live.
    let snapshot = unsafe { editor_ffi_document_snapshot(document) };
    let wire = WireScene {
        views: vec![WireView {
            id: 1,
            rect: [0, 0, 80, 16],
            snapshot: Some(0),
            ..WireView::default()
        }],
        ..WireScene::default()
    };
    let (words, strings) = wire.encode();
    assert!(publish(display, &words, &strings, &[snapshot]));
    // The frame kept is the scene's, as layout lays it out, and not the
    // frame of a display nothing was published to.
    let published = frame_text(display);
    let mut layout = Layout::new(CellShaper::new(8.0, 16.0));
    let direct = layout.frame(&plain_scene_directly("abc", 80, 16));
    assert_eq!(published, direct.describe());
    let unpublished = editor_ffi_display_new_cells(8, 16);
    assert_ne!(published, frame_text(unpublished));
    // SAFETY: `unpublished` is live and freed once.
    unsafe { editor_ffi_display_free(unpublished) };
    assert!(!publish(
        display,
        &words[..words.len() - 8],
        &strings,
        &[snapshot]
    ));
    assert!(!publish(display, &words, "x", &[snapshot]));
    assert_eq!(frame_text(display), published);
    // SAFETY: each handle is live and freed once.
    unsafe {
        editor_ffi_snapshot_free(snapshot);
        editor_ffi_document_free(document);
        editor_ffi_display_free(display);
    }
}

#[test]
fn the_latest_frame_is_taken_on_another_thread_as_it_was_published() {
    let _alone = alone();
    let display = editor_ffi::display::Display::cells(8, 16);
    let document = Document::new("one\ntwo");
    let snapshot = Snapshot::of(&document);
    let wire = WireScene {
        views: vec![WireView {
            id: 1,
            rect: [0, 0, 80, 32],
            snapshot: Some(0),
            ..WireView::default()
        }],
        ..WireScene::default()
    };
    let (words, strings) = wire.encode();
    assert!(display.publish(&words, &strings, &[&snapshot]));
    let here = display.latest();
    let there = std::thread::scope(|scope| scope.spawn(|| display.latest()).join().unwrap());
    assert_eq!(*there, *here);
    // And it is the scene's frame, as layout lays it out.
    let mut layout = Layout::new(CellShaper::new(8.0, 16.0));
    assert_eq!(
        *there,
        layout.frame(&plain_scene_directly("one\ntwo", 80, 32))
    );
}

/// Definitions that change what the scene published below looks like: a
/// default face, a keyword in another font, a selection, a mode line and
/// a cursor. What each comes to is layout's rule; here they only cross.
fn some_faces() -> Vec<WireFace> {
    let named = |name: &str, face: Face| WireFace {
        name: name.to_owned(),
        face,
    };
    vec![
        named(
            "default",
            Face {
                foreground: Some(Color(0x1020_30ff)),
                background: Some(Color(0xf0f0_f0ff)),
                line_height: Some(LineHeight::Multiple(80)),
                ..Face::default()
            },
        ),
        named(
            "keyword",
            Face {
                family: Some("serif".to_owned()),
                size: Some(Length(1152)),
                weight: Some(Weight(700)),
                slant: Some(Slant::Italic),
                underline: Some(Underline {
                    style: UnderlineStyle::Dotted,
                    color: None,
                }),
                strike_through: Some(true),
                ..Face::default()
            },
        ),
        named(
            "selection",
            Face {
                background: Some(Color(0x0000_80ff)),
                ..Face::default()
            },
        ),
        named(
            "mode-line",
            Face {
                background: Some(Color(0x4040_40ff)),
                ..Face::default()
            },
        ),
        named(
            "cursor",
            Face {
                background: Some(Color(0xff00_00ff)),
                ..Face::default()
            },
        ),
    ]
}

/// The frame `layout` lays out of `scene_directly` with the definitions
/// `faces`, as text.
///
/// A frame's text names fonts by the ids its shaper gave them, in the
/// order it was first asked for each. So a display that has been
/// published to is compared with one `Layout` handed the same scenes in
/// the same order, not with a fresh one.
fn described_by(layout: &mut Layout<CellShaper>, faces: Option<&[WireFace]>) -> String {
    let mut scene = scene_directly();
    scene.faces = faces.map(|faces| {
        faces
            .iter()
            .map(|face| FaceDef {
                name: face.name.clone(),
                face: face.face.clone(),
            })
            .collect()
    });
    layout.frame(&scene).describe()
}

/// A display, a document holding [`TEXT`] with its markers, a snapshot of
/// it, and the scene `scene_directly` lays out, as it crosses, with no
/// faces.
fn published_scene() -> (
    *mut editor_ffi::display::Display,
    *mut Document,
    *mut Snapshot,
    WireScene,
) {
    let display = editor_ffi_display_new_cells(8, 16);
    let document = document_new(TEXT);
    let scroll = mark(
        document,
        &Marker::Anchor(Anchor {
            offset: 0,
            bias: Bias::Before,
        }),
    );
    let selection = mark(
        document,
        &Marker::Selection(Selection::new(vec![SelectionRange::new(3, 7)], 0).unwrap()),
    );
    // SAFETY: `document` is live.
    let snapshot = unsafe { editor_ffi_document_snapshot(document) };
    let wire = WireScene {
        size: [96, 64],
        focused: Some(3),
        echo: "hello".to_owned(),
        views: vec![WireView {
            id: 3,
            rect: [0, 0, 96, 64],
            snapshot: Some(0),
            scroll: Some(scroll),
            selections: vec![selection],
            cursor_shape: 1,
            cursor_face: "cursor".to_owned(),
            decorations: vec![(0, 2, "keyword".to_owned())],
            status: vec![("NORMAL".to_owned(), "mode".to_owned())],
        }],
        ..WireScene::default()
    };
    (display, document, snapshot, wire)
}

/// Publishes `wire` to `display` through C with `snapshot` as its view's,
/// and returns whether it was taken.
fn publish_wire(
    display: *const editor_ffi::display::Display,
    snapshot: *const Snapshot,
    wire: &WireScene,
) -> bool {
    let (words, strings) = wire.encode();
    publish(display, &words, &strings, &[snapshot])
}

#[test]
fn faces_published_through_c_reach_layout_and_absent_faces_keep_the_last() {
    let _alone = alone();
    let (display, document, snapshot, mut wire) = published_scene();
    let faces = some_faces();
    // The layout the display is compared with, handed the same scenes.
    let mut direct = Layout::new(CellShaper::new(8.0, 16.0));
    // With no face yet, the frame of the scene with none.
    assert!(publish_wire(display, snapshot, &wire));
    let bare = frame_text(display);
    assert_eq!(bare, described_by(&mut direct, None));
    // With the definitions, the frame layout makes of the same ones.
    wire.faces = Some(faces.clone());
    assert!(publish_wire(display, snapshot, &wire));
    let styled = frame_text(display);
    assert_eq!(styled, described_by(&mut direct, Some(&faces)));
    assert_ne!(styled, bare);
    // A publish with absent faces keeps them.
    wire.faces = None;
    assert!(publish_wire(display, snapshot, &wire));
    assert_eq!(frame_text(display), styled);
    assert_eq!(styled, described_by(&mut direct, None));
    // The definitions cross in the order sent. With `keyword` defined a
    // second time, the two orders are two frames to layout, and each
    // published order is layout's frame of that order.
    let mut twice = faces.clone();
    twice.push(WireFace {
        name: "keyword".to_owned(),
        face: Face {
            size: Some(Length(1600)),
            foreground: Some(Color(0x0080_00ff)),
            ..Face::default()
        },
    });
    let reversed: Vec<WireFace> = twice.iter().rev().cloned().collect();
    let mut frames = Vec::new();
    for order in [twice, reversed] {
        wire.faces = Some(order.clone());
        assert!(publish_wire(display, snapshot, &wire));
        let published = frame_text(display);
        assert_eq!(published, described_by(&mut direct, Some(&order)));
        frames.push(published);
    }
    assert_ne!(frames[0], frames[1]);
    // A publish with no definitions takes them away.
    wire.faces = Some(vec![]);
    assert!(publish_wire(display, snapshot, &wire));
    assert_eq!(frame_text(display), bare);
    assert_eq!(bare, described_by(&mut direct, Some(&[])));
    // SAFETY: each handle is live and freed once.
    unsafe {
        editor_ffi_snapshot_free(snapshot);
        editor_ffi_document_free(document);
        editor_ffi_display_free(display);
    }
}

#[test]
fn words_that_spell_no_face_are_refused_and_the_last_frame_and_faces_are_kept() {
    let _alone = alone();
    let (display, document, snapshot, mut wire) = published_scene();
    wire.faces = Some(some_faces());
    assert!(publish_wire(display, snapshot, &wire));
    let styled = frame_text(display);
    // The same scene with other faces, and its last word, a line height's
    // value, made one no `u32` holds.
    wire.faces = Some(vec![WireFace {
        name: "default".to_owned(),
        face: Face {
            line_height: Some(LineHeight::Pixels(Length(1280))),
            ..Face::default()
        },
    }]);
    let (mut words, strings) = wire.encode();
    let last = words.len() - 8;
    words[last..].copy_from_slice(&(u64::from(u32::MAX) + 1).to_le_bytes());
    assert!(!publish(display, &words, &strings, &[snapshot]));
    assert_eq!(frame_text(display), styled);
    // Neither the frame nor the faces changed: a publish with absent
    // faces is still in the ones before the refusal.
    wire.faces = None;
    assert!(publish_wire(display, snapshot, &wire));
    assert_eq!(frame_text(display), styled);
    // SAFETY: each handle is live and freed once.
    unsafe {
        editor_ffi_snapshot_free(snapshot);
        editor_ffi_document_free(document);
        editor_ffi_display_free(display);
    }
}

#[test]
fn a_scene_published_with_faces_comes_back_with_them() {
    let _alone = alone();
    let (display, document, snapshot, mut wire) = published_scene();
    wire.faces = Some(some_faces());
    let (words, strings) = wire.encode();
    assert!(publish(display, &words, &strings, &[snapshot]));
    let (mut back, mut text) = (MaybeUninit::uninit(), MaybeUninit::uninit());
    // SAFETY: `display` is live, and both records are writable and filled
    // before they are read.
    let (status, back, text) = unsafe {
        editor_ffi_display_scene(display, back.as_mut_ptr(), text.as_mut_ptr());
        let (status, back) = take(back.assume_init());
        (status, back, take_text(text.assume_init()))
    };
    let sent: Vec<u64> = words
        .as_chunks::<8>()
        .0
        .iter()
        .map(|word| u64::from_le_bytes(*word))
        .collect();
    assert_eq!((status, back, text), (0, sent, strings));
    // SAFETY: each handle is live and freed once.
    unsafe {
        editor_ffi_snapshot_free(snapshot);
        editor_ffi_document_free(document);
        editor_ffi_display_free(display);
    }
}
