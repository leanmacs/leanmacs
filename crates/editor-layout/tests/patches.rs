//! What layout does with a text that changed: its entries moved through
//! the patch it pulls, or, when there is none to pull, rebuilt from the
//! snapshot at hand; never a stale row, and never the cache moved
//! backwards.

use std::collections::BTreeSet;
use std::fmt::Debug;
use std::sync::{Arc, Mutex};

use editor_layout::Layout;
use editor_layout::scene::{Changes, Cursor, Rect, Scene, TextKey, TextRef, View, ViewId};
use editor_layout::shaper::fake::CellShaper;
use editor_text::{Patch, Revision, Text};
use proptest::collection::vec;
use proptest::prelude::*;
use proptest::sample::select;
use proptest::test_runner::{Config, RngAlgorithm, TestCaseError, TestRng, TestRunner};

/// A text behind a lock, and its changes.
#[derive(Clone)]
struct Shared(Arc<Mutex<Text>>);

impl Changes for Shared {
    fn since(&self, revision: Revision) -> Option<Patch> {
        self.0.lock().unwrap().changes_since(revision).ok()
    }
}

/// Changes that are always refused: a text whose log was forgotten, or
/// that is gone.
struct Refused;

impl Changes for Refused {
    fn since(&self, _revision: Revision) -> Option<Patch> {
        None
    }
}

/// The text `text` as `key`, its changes pulled through `changes`.
fn text_ref(key: u64, text: &Text, changes: Arc<dyn Changes>) -> TextRef {
    TextRef {
        key: TextKey(key),
        snapshot: text.snapshot(),
        changes,
    }
}

/// A scene of one view of each of `texts`, 4 cells wide and 10 rows tall.
fn scene(texts: &[TextRef]) -> Scene {
    scene_rows(texts, 10)
}

/// A scene of one view of each of `texts`, 4 cells wide and `rows` rows
/// tall.
fn scene_rows(texts: &[TextRef], rows: u32) -> Scene {
    Scene {
        views: texts
            .iter()
            .enumerate()
            .map(|(index, text)| View {
                id: ViewId(index as u64),
                rect: Rect {
                    x: 0,
                    y: 0,
                    width: 40,
                    height: rows * 16,
                },
                text: Some(text.clone()),
                cursor: Cursor::default(),
                ..View::default()
            })
            .collect(),
        ..Scene::default()
    }
}

/// A layout on cells 10 by 16.
fn layout() -> Layout<CellShaper> {
    Layout::new(CellShaper::new(10.0, 16.0))
}

/// Runs `property` on `cases` values of `strategy`, from a fixed seed, with
/// failure persistence off so no file is written beside the sources.
fn check<S>(cases: u32, strategy: S, property: impl Fn(S::Value) -> Result<(), TestCaseError>)
where
    S: Strategy,
    S::Value: Debug,
{
    let config = Config {
        cases,
        failure_persistence: None,
        ..Config::default()
    };
    let mut runner =
        TestRunner::new_with_rng(config, TestRng::deterministic_rng(RngAlgorithm::ChaCha));
    if let Err(failure) = runner.run(&strategy, property) {
        panic!("{failure}");
    }
}

/// Where row `row` of `text` starts.
fn row_start(text: &Text, row: usize) -> usize {
    text.snapshot().row_range(row).unwrap().start
}

#[test]
fn several_edits_in_one_patch_move_the_rows_between_and_after_them() {
    let rows: Vec<String> = (0..20).map(|row| format!("r{row}")).collect();
    let shared = Shared(Arc::new(Mutex::new(Text::from(rows.join("\n").as_str()))));
    let changes: Arc<dyn Changes> = Arc::new(shared.clone());
    let mut layout = layout();
    let first = text_ref(1, &shared.0.lock().unwrap(), changes.clone());
    layout.frame(&scene_rows(std::slice::from_ref(&first), 20));
    // Three transactions between the two frames, not from the top down: a
    // row changed near the end, two rows put in near the start, and two
    // rows taken out between them.
    let patch = {
        let mut text = shared.0.lock().unwrap();
        let at = row_start(&text, 15) + 1;
        text.replace(at..at, "x").unwrap();
        let at = row_start(&text, 3);
        text.replace(at..at, "new\nrows\n").unwrap();
        let (from, to) = (row_start(&text, 10), row_start(&text, 12));
        text.replace(from..to, "").unwrap();
        text.changes_since(first.snapshot.revision()).unwrap()
    };
    let edited = text_ref(1, &shared.0.lock().unwrap(), changes);
    let scene = scene_rows(std::slice::from_ref(&edited), 20);
    let before = layout.counters();
    let frame = layout.frame(&scene);
    assert_eq!(frame, self::layout().frame(&scene));
    // The rows shaped again are the rows of the new text an edit of the
    // patch reaches, each from its start's row to its end's; every other
    // row was moved and is used as it was kept.
    let touched: BTreeSet<usize> = patch
        .edits
        .iter()
        .flat_map(|edit| edit.new.start_point.row..=edit.new.end_point.row)
        .collect();
    let shown = frame.views[0].rows.len();
    assert_eq!(shown, 20);
    let after = layout.counters();
    assert_eq!(after.shaped - before.shaped, touched.len() as u64);
    assert_eq!(after.reused - before.reused, (shown - touched.len()) as u64);
}

/// A short text of what moves rows and what a row is cut and expanded by.
fn texts() -> impl Strategy<Value = String> {
    let piece = select(vec!["a", "bcdef", "\t", "é", "\r\n", "\n", "\n"]);
    vec(piece, 0..30).prop_map(|pieces| pieces.concat())
}

/// The last position of `text` at or before `offset`.
fn position(text: &Text, offset: usize) -> usize {
    let snapshot = text.snapshot();
    let mut at = offset.min(snapshot.len());
    while !snapshot.is_char_boundary(at) {
        at -= 1;
    }
    at
}

#[test]
fn a_frame_after_any_edits_is_a_fresh_layouts() {
    // Each edit: where it starts, in thousandths of the text; how many
    // bytes it replaces; and what with.
    let edits = vec((0usize..=1000, 0usize..8, texts()), 1..5);
    check(256, (texts(), edits), |(start, edits)| {
        let shared = Shared(Arc::new(Mutex::new(Text::from(start.as_str()))));
        let changes: Arc<dyn Changes> = Arc::new(shared.clone());
        let mut layout = layout();
        layout.frame(&scene(&[text_ref(
            1,
            &shared.0.lock().unwrap(),
            changes.clone(),
        )]));
        {
            let mut text = shared.0.lock().unwrap();
            for (at, len, with) in &edits {
                let len_now = text.snapshot().len();
                let from = position(&text, at * len_now / 1000);
                let to = position(&text, from + len).max(from);
                text.replace(from..to, with).unwrap();
            }
        }
        let edited = text_ref(1, &shared.0.lock().unwrap(), changes);
        let scene = scene(&[edited]);
        prop_assert_eq!(layout.frame(&scene), self::layout().frame(&scene));
        Ok(())
    });
}

#[test]
fn a_refused_patch_rebuilds_and_the_frame_is_a_fresh_layouts() {
    let shared = Shared(Arc::new(Mutex::new(Text::from("abcdef\nghi\njkl"))));
    let mut layout = layout();
    let changes: Arc<dyn Changes> = Arc::new(shared.clone());
    layout.frame(&scene(&[text_ref(
        1,
        &shared.0.lock().unwrap(),
        changes.clone(),
    )]));
    {
        let mut text = shared.0.lock().unwrap();
        text.replace(7..7, "x\ny").unwrap();
        let now = text.snapshot().revision();
        text.forget(now).unwrap();
    }
    let edited = text_ref(1, &shared.0.lock().unwrap(), changes);
    let frame = layout.frame(&scene(std::slice::from_ref(&edited)));
    assert_eq!(frame, self::layout().frame(&scene(&[edited])));
}

#[test]
fn a_text_whose_changes_are_refused_is_rebuilt_from_its_snapshot() {
    let mut text = Text::from("abcdef\nghi");
    let mut layout = layout();
    layout.frame(&scene(&[text_ref(1, &text, Arc::new(Refused))]));
    text.replace(0..6, "uvwxyz0123").unwrap();
    let edited = text_ref(1, &text, Arc::new(Refused));
    let frame = layout.frame(&scene(std::slice::from_ref(&edited)));
    assert_eq!(frame, self::layout().frame(&scene(&[edited])));
}

#[test]
fn a_patch_that_goes_past_the_snapshot_shown_rebuilds() {
    let shared = Shared(Arc::new(Mutex::new(Text::from("aa\nbb\ncc\ndd\nee\nff"))));
    let changes: Arc<dyn Changes> = Arc::new(shared.clone());
    let mut layout = layout();
    layout.frame(&scene(&[text_ref(
        1,
        &shared.0.lock().unwrap(),
        changes.clone(),
    )]));
    // The view keeps showing the text as it was between two edits, while
    // the changes pulled are the text's up to now: a patch through both.
    // The second edit takes out the first two rows, which the snapshot
    // shown still has.
    shared.0.lock().unwrap().replace(16..17, "x").unwrap();
    let between = text_ref(1, &shared.0.lock().unwrap(), changes);
    shared.0.lock().unwrap().replace(0..6, "").unwrap();
    let scene = scene(&[between]);
    assert_eq!(layout.frame(&scene), self::layout().frame(&scene));
}

#[test]
fn an_older_snapshot_is_laid_out_apart_and_leaves_the_cache_as_it_was() {
    let shared = Shared(Arc::new(Mutex::new(Text::from("abcdefgh\nij"))));
    let changes: Arc<dyn Changes> = Arc::new(shared.clone());
    let old = text_ref(1, &shared.0.lock().unwrap(), changes.clone());
    shared.0.lock().unwrap().replace(0..0, "0123").unwrap();
    let new = text_ref(1, &shared.0.lock().unwrap(), changes);
    let mut layout = layout();
    layout.frame(&scene(std::slice::from_ref(&new)));
    // The old text's rows, at its revision.
    let rows = layout.rows_shown(&old, 40.0, 48.0, 0).unwrap();
    let pairs: Vec<(usize, usize)> = rows.iter().map(|row| (row.start, row.stop)).collect();
    assert_eq!(pairs, vec![(0, 4), (4, 8), (9, 11)]);
    // The new text's entries are all still kept.
    let before = layout.counters();
    layout.frame(&scene(&[new]));
    assert_eq!(layout.counters().shaped, before.shaped);
}

#[test]
fn texts_are_kept_apart_by_key() {
    let one = Text::from("one");
    let two = Text::from("two two");
    let mut layout = layout();
    let refs = [
        text_ref(1, &one, Arc::new(Refused)),
        text_ref(2, &two, Arc::new(Refused)),
    ];
    let frame = layout.frame(&scene(&refs));
    assert_eq!(frame.views[0].rows[0].bytes, 0..3);
    assert_eq!(frame.views[1].rows[0].bytes, 0..4);
    let before = layout.counters();
    layout.frame(&scene(&refs));
    assert_eq!(layout.counters().shaped, before.shaped);
}

#[test]
fn a_text_no_scene_names_is_dropped_when_a_scene_is_published() {
    let one = Text::from("one");
    let two = Text::from("two");
    let mut layout = layout();
    let first = text_ref(1, &one, Arc::new(Refused));
    layout.frame(&scene(&[
        first.clone(),
        text_ref(2, &two, Arc::new(Refused)),
    ]));
    assert_eq!(layout.texts_kept(), 2);
    layout.frame(&scene(&[first]));
    assert_eq!(layout.texts_kept(), 1);
}
