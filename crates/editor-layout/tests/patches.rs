//! What layout does with a text that changed: its entries moved through
//! the patch it pulls, or, when there is none to pull, rebuilt from the
//! snapshot at hand; never a stale row, and never the cache moved
//! backwards.

use std::sync::{Arc, Mutex};

use editor_layout::Layout;
use editor_layout::scene::{Changes, Cursor, Rect, Scene, TextKey, TextRef, View, ViewId};
use editor_layout::shaper::fake::CellShaper;
use editor_text::{Patch, Revision, Text};

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
                    height: 160,
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
