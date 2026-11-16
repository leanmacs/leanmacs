//! What layout costs, counted: segments shaped, segments broken into
//! visual lines, and laid-out segments reused as they were
//! ([`Counters`]). A count is the same on every machine, where a duration
//! is not.
//!
//! The texts are built with `editor_text::Text` and edited one change per
//! transaction, so no count depends on how the text's log joins edits
//! into a patch, which is `editor-text`'s rule.

use std::sync::{Arc, Mutex};

use editor_layout::Layout;
use editor_layout::cache::Counters;
use editor_layout::face::{Color, Face, FaceDef, Underline, UnderlineStyle};
use editor_layout::frame::Frame;
use editor_layout::scene::{
    Changes, Cursor, Decoration, Rect, Scene, StatusField, TextKey, TextRef, View, ViewId,
};
use editor_layout::shaper::fake::CellShaper;
use editor_layout::shaper::{Length, LineHeight, Slant, Weight};
use editor_text::{Patch, Revision, Selection, SelectionRange, Text};

/// A text behind a lock, as the binding holds one, and its changes.
#[derive(Clone)]
struct Shared(Arc<Mutex<Text>>);

impl Changes for Shared {
    fn since(&self, revision: Revision) -> Option<Patch> {
        self.0.lock().unwrap().changes_since(revision).ok()
    }
}

impl Shared {
    /// A shared text holding `text`.
    fn new(text: &str) -> Self {
        Self(Arc::new(Mutex::new(Text::from(text))))
    }

    /// The text as it is now, as key 1.
    fn now(&self) -> TextRef {
        TextRef {
            key: TextKey(1),
            snapshot: self.0.lock().unwrap().snapshot(),
            changes: Arc::new(self.clone()),
        }
    }

    /// Puts `text` in place of `range`, as one transaction.
    fn replace(&self, range: std::ops::Range<usize>, text: &str) {
        self.0.lock().unwrap().replace(range, text).unwrap();
    }
}

/// Twenty rows of one word.
fn twenty_words() -> String {
    (0..20)
        .map(|row| format!("word{row}"))
        .collect::<Vec<_>>()
        .join("\n")
}

/// A scene of one view of `text`, `width` pixels wide and tall enough for
/// forty rows, with a cursor at `cursor`.
fn scene(text: &TextRef, width: u32, cursor: usize) -> Scene {
    scene_rows(text, width, cursor, 40)
}

/// [`scene`] with a view `rows` rows tall.
fn scene_rows(text: &TextRef, width: u32, cursor: usize, rows: u32) -> Scene {
    Scene {
        views: vec![View {
            id: ViewId(1),
            rect: Rect {
                x: 0,
                y: 0,
                width,
                height: rows * 16,
            },
            text: Some(text.clone()),
            scroll: 0,
            selections: vec![Selection::new(vec![SelectionRange::new(cursor, cursor)], 0).unwrap()],
            cursor: Cursor::default(),
            decorations: vec![],
            status: vec![],
            status_face: None,
        }],
        ..Scene::default()
    }
}

/// What `layout` counted while `run` ran.
fn counted(layout: &mut Layout<CellShaper>, run: impl FnOnce(&mut Layout<CellShaper>)) -> Counters {
    let before = layout.counters();
    run(layout);
    let after = layout.counters();
    Counters {
        shaped: after.shaped - before.shaped,
        broken: after.broken - before.broken,
        reused: after.reused - before.reused,
    }
}

/// A count of `shaped`, `broken` and `reused`.
fn count(shaped: u64, broken: u64, reused: u64) -> Counters {
    Counters {
        shaped,
        broken,
        reused,
    }
}

#[test]
fn a_first_frame_shapes_every_row_it_shows_and_the_next_reuses_them() {
    let text = TextRef::fixed(TextKey(1), Text::from(twenty_words().as_str()).snapshot());
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    let first = counted(&mut layout, |layout| {
        layout.frame(&scene(&text, 400, 0));
    });
    assert_eq!(first, count(20, 20, 0));
    let again = counted(&mut layout, |layout| {
        layout.frame(&scene(&text, 400, 0));
    });
    assert_eq!(again, count(0, 0, 20));
}

#[test]
fn a_width_change_breaks_every_row_again_and_shapes_none() {
    let text = TextRef::fixed(TextKey(1), Text::from(twenty_words().as_str()).snapshot());
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.frame(&scene(&text, 400, 0));
    let wider = counted(&mut layout, |layout| {
        layout.frame(&scene(&text, 500, 0));
    });
    assert_eq!(wider, count(0, 20, 0));
}

#[test]
fn a_cursor_move_neither_shapes_nor_breaks() {
    let text = TextRef::fixed(TextKey(1), Text::from(twenty_words().as_str()).snapshot());
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.frame(&scene(&text, 400, 0));
    let moved = counted(&mut layout, |layout| {
        layout.frame(&scene(&text, 400, 12));
    });
    assert_eq!(moved, count(0, 0, 20));
}

#[test]
fn a_font_change_shapes_every_row_again() {
    let text = TextRef::fixed(TextKey(1), Text::from(twenty_words().as_str()).snapshot());
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.frame(&scene(&text, 400, 0));
    layout.shaper().change_fonts();
    let reshaped = counted(&mut layout, |layout| {
        layout.frame(&scene(&text, 400, 0));
    });
    assert_eq!(reshaped, count(20, 20, 0));
}

#[test]
fn a_query_reuses_what_a_frame_laid_out() {
    let text = TextRef::fixed(TextKey(1), Text::from(twenty_words().as_str()).snapshot());
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.frame(&scene(&text, 400, 0));
    let queried = counted(&mut layout, |layout| {
        layout.rows_shown(&text, 400.0, 5.0 * 16.0, 0).unwrap();
        layout.lines_from(&text, 400.0, 0, 3, None).unwrap();
    });
    assert_eq!((queried.shaped, queried.broken), (0, 0));
}

#[test]
fn an_edit_reshapes_only_the_row_it_touched() {
    let shared = Shared::new(&twenty_words());
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.frame(&scene(&shared.now(), 400, 0));
    // One character into row 5, "word5", which starts at byte 30.
    shared.replace(31..31, "x");
    let edited = counted(&mut layout, |layout| {
        layout.frame(&scene(&shared.now(), 400, 0));
    });
    assert_eq!(edited, count(1, 1, 19));
}

#[test]
fn a_line_feed_shapes_the_two_rows_it_made_and_moves_the_rest() {
    let shared = Shared::new(&twenty_words());
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.frame(&scene(&shared.now(), 400, 0));
    shared.replace(0..0, "\n");
    let edited = counted(&mut layout, |layout| {
        layout.frame(&scene(&shared.now(), 400, 0));
    });
    assert_eq!(edited, count(2, 2, 19));
}

#[test]
fn an_edit_below_the_view_reshapes_nothing_shown() {
    let shared = Shared::new(&twenty_words());
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.frame(&scene_rows(&shared.now(), 400, 0, 10));
    // Row 15 is not shown, and a line feed there moves no row shown.
    let row_15 = shared.now().snapshot.row_range(15).unwrap().start;
    shared.replace(row_15..row_15, "new\n");
    let edited = counted(&mut layout, |layout| {
        layout.frame(&scene_rows(&shared.now(), 400, 0, 10));
    });
    assert_eq!(edited, count(0, 0, 10));
}

/// The twenty rows as a text, and where row `row` of it starts.
fn twenty() -> (TextRef, impl Fn(usize) -> usize) {
    let text = TextRef::fixed(TextKey(1), Text::from(twenty_words().as_str()).snapshot());
    let snapshot = text.snapshot.clone();
    (text, move |row| snapshot.row_range(row).unwrap().start)
}

/// The scene of the twenty rows `text`, 400 pixels wide, with a cursor at
/// 0, the bytes `decorated` in the face `name`, and the faces `faces`.
fn styled(
    text: &TextRef,
    decorated: std::ops::Range<usize>,
    name: &str,
    faces: &[(&str, Face)],
) -> Scene {
    let mut scene = scene(text, 400, 0);
    scene.views[0].decorations = vec![Decoration {
        start: decorated.start,
        stop: decorated.end,
        face: name.to_owned(),
    }];
    scene.faces = Some(
        faces
            .iter()
            .map(|(name, face)| FaceDef {
                name: (*name).to_owned(),
                face: face.clone(),
            })
            .collect(),
    );
    scene
}

/// A face that sets a foreground alone.
fn coloured(red: u8) -> Face {
    Face {
        foreground: Some(Color::rgb(red, 0, 0)),
        ..Face::default()
    }
}

#[test]
fn a_paint_only_change_of_a_face_neither_shapes_nor_breaks() {
    let (text, _) = twenty();
    let all = 0..text.snapshot.len();
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    // The hash of each row of a frame.
    let hashes =
        |frame: Frame| -> Vec<u64> { frame.views[0].rows.iter().map(|row| row.hash).collect() };
    let mut before = hashes(layout.frame(&styled(
        &text,
        all.clone(),
        "body",
        &[("body", coloured(1))],
    )));
    let paints = [
        coloured(2),
        Face {
            background: Some(Color::rgb(0, 0, 9)),
            ..Face::default()
        },
        Face {
            underline: Some(Underline {
                style: UnderlineStyle::Curly,
                color: None,
            }),
            ..Face::default()
        },
        Face {
            strike_through: Some(true),
            ..Face::default()
        },
    ];
    for paint in paints {
        let mut after = Vec::new();
        let repainted = counted(&mut layout, |layout| {
            after = hashes(layout.frame(&styled(
                &text,
                all.clone(),
                "body",
                &[("body", paint.clone())],
            )));
        });
        assert_eq!(repainted, count(0, 0, 20), "{paint:?}");
        // Every row is drawn in the face, so every row's hash changed:
        // a renderer builds each again, and layout built none.
        assert_eq!(after.len(), 20);
        for (row, (now, then)) in after.iter().zip(&before).enumerate() {
            assert_ne!(now, then, "row {row}, {paint:?}");
        }
        before = after;
    }
    // The default face's paint likewise.
    let mut after = Vec::new();
    let repainted = counted(&mut layout, |layout| {
        after = hashes(layout.frame(&styled(&text, all, "body", &[("default", coloured(3))])));
    });
    assert_eq!(repainted, count(0, 0, 20));
    for (now, then) in after.iter().zip(&before) {
        assert_ne!(now, then);
    }
}

#[test]
fn a_size_change_of_a_face_shapes_only_the_rows_drawn_in_it() {
    let (text, start) = twenty();
    // Rows 3 and 4 are in the face `big`.
    let two = start(3)..start(5) - 1;
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.frame(&styled(&text, two.clone(), "big", &[("big", coloured(1))]));
    let big = Face {
        size: Some(Length::pixels(32)),
        ..Face::default()
    };
    let resized = counted(&mut layout, |layout| {
        layout.frame(&styled(&text, two.clone(), "big", &[("big", big.clone())]));
    });
    assert_eq!(resized, count(2, 2, 18));
    // The same faces again shape nothing, and a scene that carries no
    // faces keeps them.
    let mut kept = styled(&text, two.clone(), "big", &[]);
    kept.faces = None;
    for scene in [styled(&text, two, "big", &[("big", big)]), kept] {
        let again = counted(&mut layout, |layout| {
            layout.frame(&scene);
        });
        assert_eq!(again, count(0, 0, 20));
    }
}

#[test]
fn a_change_of_the_default_faces_font_shapes_every_row_again() {
    let (text, _) = twenty();
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.frame(&styled(&text, 0..0, "none", &[]));
    let fonts = [
        Face {
            family: Some("serif".to_owned()),
            ..Face::default()
        },
        Face {
            size: Some(Length::pixels(20)),
            ..Face::default()
        },
        Face {
            weight: Some(Weight::BOLD),
            ..Face::default()
        },
        Face {
            slant: Some(Slant::Italic),
            ..Face::default()
        },
        Face {
            line_height: Some(LineHeight::Multiple(96)),
            ..Face::default()
        },
    ];
    for font in fonts {
        let scene = styled(&text, 0..0, "none", &[("default", font.clone())]);
        let reshaped = counted(&mut layout, |layout| {
            layout.frame(&scene);
        });
        assert_eq!(reshaped, count(20, 20, 0), "{font:?}");
        let again = counted(&mut layout, |layout| {
            layout.frame(&scene);
        });
        assert_eq!(again, count(0, 0, 20), "{font:?}");
    }
}

/// The scene of the twenty rows `text` with the faces `faces` and one
/// selection from `anchor` to `head`.
fn selected(text: &TextRef, anchor: usize, head: usize, faces: &[(&str, Face)]) -> Scene {
    let mut scene = styled(text, 0..0, "none", faces);
    scene.views[0].selections =
        vec![Selection::new(vec![SelectionRange::new(anchor, head)], 0).unwrap()];
    scene
}

#[test]
fn a_selection_in_a_face_that_sets_no_font_attribute_neither_shapes_nor_breaks() {
    let (text, start) = twenty();
    let faces = [(
        "selection",
        Face {
            background: Some(Color::rgb(0, 0, 9)),
            ..Face::default()
        },
    )];
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.frame(&selected(&text, 0, 0, &faces));
    // From inside row 2 to inside row 4.
    let made = counted(&mut layout, |layout| {
        layout.frame(&selected(&text, start(2) + 1, start(4) + 2, &faces));
    });
    assert_eq!(made, count(0, 0, 20));
}

#[test]
fn a_selection_in_a_face_that_sets_a_weight_shapes_the_rows_it_covers() {
    let (text, start) = twenty();
    let faces = [(
        "selection",
        Face {
            weight: Some(Weight::BOLD),
            ..Face::default()
        },
    )];
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.frame(&selected(&text, 0, 0, &faces));
    // From inside row 2 to inside row 4: three rows.
    let made = counted(&mut layout, |layout| {
        layout.frame(&selected(&text, start(2) + 1, start(4) + 2, &faces));
    });
    assert_eq!(made, count(3, 3, 17));
    // Taken away, the same three are shaped again in the default font.
    let unmade = counted(&mut layout, |layout| {
        layout.frame(&selected(&text, 0, 0, &faces));
    });
    assert_eq!(unmade, count(3, 3, 17));
}

/// The scene of the twenty rows `text` in a view tall enough for all of
/// them at scale 2 as at scale 1, with rows 3 and 4 in the face `heavy`,
/// which sets a weight and so a font of its own that changes no row's
/// height.
fn at_any_scale(text: &TextRef, start: &impl Fn(usize) -> usize) -> Scene {
    let heavy = Face {
        weight: Some(Weight::BOLD),
        ..Face::default()
    };
    let mut scene = styled(text, start(3)..start(5) - 1, "heavy", &[("heavy", heavy)]);
    scene.views[0].rect.height = 2 * 40 * 16;
    scene
}

#[test]
fn a_change_of_scale_alone_lays_the_visible_rows_out_again() {
    let (text, start) = twenty();
    // With no face defined, every row is in the base font and no source
    // is asked for a row's fonts; with a face that sets a font, each
    // row's fonts are found run by run. A change of scale reaches both.
    let scenes = [
        ("no face", scene_rows(&text, 400, 0, 80)),
        ("a face with a font", at_any_scale(&text, &start)),
    ];
    for (name, scene) in scenes {
        let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
        let mut rows = 0;
        let first = counted(&mut layout, |layout| {
            rows = layout.frame(&scene).views[0].rows.len();
        });
        assert_eq!(rows, 20, "{name}");
        assert_eq!(first, count(20, 20, 0), "{name}");
        // The same scene again shapes nothing and reuses every row shown.
        let again = counted(&mut layout, |layout| {
            layout.frame(&scene);
        });
        assert_eq!(again, count(0, 0, 20), "{name}");
        // The scale, and nothing else: the scene is the one it was. Every
        // row shown is shaped again and none is reused.
        layout.set_scale(2.0);
        let scaled = counted(&mut layout, |layout| {
            rows = layout.frame(&scene).views[0].rows.len();
        });
        assert_eq!(rows, 20, "{name}");
        assert_eq!(scaled, count(20, 20, 0), "{name}");
        // Once more at the same scale: every row reused, none shaped.
        let settled = counted(&mut layout, |layout| {
            layout.frame(&scene);
        });
        assert_eq!(settled, count(0, 0, 20), "{name}");
    }
}

#[test]
fn the_scale_it_already_has_lays_nothing_out() {
    let (text, start) = twenty();
    let scene = at_any_scale(&text, &start);
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.frame(&scene);
    // The scale a layout begins at.
    layout.set_scale(1.0);
    let same = counted(&mut layout, |layout| {
        layout.frame(&scene);
    });
    assert_eq!(same, count(0, 0, 20));
    layout.set_scale(2.0);
    layout.frame(&scene);
    layout.set_scale(2.0);
    let same = counted(&mut layout, |layout| {
        layout.frame(&scene);
    });
    assert_eq!(same, count(0, 0, 20));
}

#[test]
fn a_change_of_scale_shapes_the_status_row_again() {
    let (text, _) = twenty();
    let fields = [("words.txt", "name"), (" 1:1", "position")];
    let mut scene = with_status(&text, &fields, &[]);
    // Tall enough for the twenty rows and the status row at scale 2.
    scene.views[0].rect.height = 2 * 40 * 16;
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    let first = bytes_shaped(&mut layout, |layout| {
        layout.frame(&scene);
    });
    // The twenty rows, and the status row's thirteen bytes.
    assert_eq!(first, text.snapshot.len() - 19 + 13);
    layout.set_scale(2.0);
    let scaled = bytes_shaped(&mut layout, |layout| {
        layout.frame(&scene);
    });
    assert_eq!(scaled, first);
    // The scale it has shapes nothing: neither a row nor the status row.
    layout.set_scale(2.0);
    let same = bytes_shaped(&mut layout, |layout| {
        layout.frame(&scene);
    });
    assert_eq!(same, 0);
}

/// Five thousand rows of one letter, and an empty row after them.
fn five_thousand_rows() -> TextRef {
    TextRef::fixed(
        TextKey(1),
        Text::from("a\n".repeat(5000).as_str()).snapshot(),
    )
}

/// Faces whose font has lines of no height on the fake shaper (a size of
/// 0, a line height of 0 pixels, a line height of 0 times the font's own),
/// and one whose lines are a 64th of a pixel tall (a size of a 64th).
fn flat_faces() -> [Face; 4] {
    [
        Face {
            size: Some(Length(0)),
            ..Face::default()
        },
        Face {
            line_height: Some(LineHeight::Pixels(Length(0))),
            ..Face::default()
        },
        Face {
            line_height: Some(LineHeight::Multiple(0)),
            ..Face::default()
        },
        Face {
            size: Some(Length(1)),
            ..Face::default()
        },
    ]
}

/// The scene of one view of `text` 200 pixels wide and 160 tall, with the
/// faces `faces`.
fn small_view(text: &TextRef, faces: &[(&str, Face)]) -> Scene {
    let mut scene = scene_rows(text, 200, 0, 10);
    scene.faces = Some(
        faces
            .iter()
            .map(|(name, face)| FaceDef {
                name: (*name).to_owned(),
                face: face.clone(),
            })
            .collect(),
    );
    scene
}

#[test]
fn a_default_face_whose_lines_have_no_height_lays_out_a_row_for_each_pixel_of_the_view() {
    let text = five_thousand_rows();
    for flat in flat_faces() {
        let scene = small_view(&text, &[("default", flat.clone())]);
        let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
        let mut rows = 0;
        // Not the 5001 rows of the text: one for each of the view's 160
        // pixels.
        let first = counted(&mut layout, |layout| {
            rows = layout.frame(&scene).views[0].rows.len();
        });
        assert_eq!((rows, first), (160, count(160, 160, 0)), "{flat:?}");
        let again = counted(&mut layout, |layout| {
            layout.frame(&scene);
        });
        assert_eq!(again, count(0, 0, 160), "{flat:?}");
        // And the rows query likewise.
        let queried = counted(&mut layout, |layout| {
            rows = layout.rows_shown(&text, 200.0, 160.0, 0).unwrap().len();
        });
        assert_eq!((rows, queried), (160, count(0, 0, 160)), "{flat:?}");
        // A move counts lines, not pixels: three lines down is on the
        // fourth row, and reaches the four rows from the first to it.
        let mut row = None;
        let moved = counted(&mut layout, |layout| {
            let to = layout
                .lines_from(&text, 200.0, 0, 3, None)
                .unwrap()
                .position;
            row = text.snapshot.offset_to_point(to).map(|point| point.row);
        });
        assert_eq!((row, moved), (Some(3), count(0, 0, 4)), "{flat:?}");
    }
}

#[test]
fn a_decoration_or_a_selection_whose_lines_have_no_height_lays_out_a_row_for_each_pixel_left() {
    let text = five_thousand_rows();
    // From the sixth row to the end of the text.
    let (from, to) = (10, text.snapshot.len());
    for flat in flat_faces() {
        // The first five rows are 16 pixels tall, which leaves 80 pixels:
        // 80 rows of the face, and not the 4996 the text has left.
        let mut decorated = small_view(&text, &[("flat", flat.clone())]);
        decorated.views[0].decorations = vec![Decoration {
            start: from,
            stop: to,
            face: "flat".to_owned(),
        }];
        let mut selected = small_view(&text, &[("selection", flat.clone())]);
        selected.views[0].selections =
            vec![Selection::new(vec![SelectionRange::new(from, to)], 0).unwrap()];
        for scene in [decorated, selected] {
            let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
            let mut rows = 0;
            let first = counted(&mut layout, |layout| {
                rows = layout.frame(&scene).views[0].rows.len();
            });
            assert_eq!((rows, first), (85, count(85, 85, 0)), "{flat:?}");
        }
    }
}

/// The scene of the twenty rows `text` with the faces `faces` and the
/// status fields `fields`: each its text and its face's name.
fn with_status(text: &TextRef, fields: &[(&str, &str)], faces: &[(&str, Face)]) -> Scene {
    let mut scene = styled(text, 0..0, "none", faces);
    scene.views[0].status = fields
        .iter()
        .map(|(text, face)| StatusField {
            text: (*text).to_owned(),
            face: (*face).to_owned(),
            ..StatusField::default()
        })
        .collect();
    scene
}

/// How many bytes the shaper of `layout` was asked to shape while `run`
/// ran. A status row is no segment of a text, so the counters do not
/// count it; the fake's bytes do.
fn bytes_shaped(
    layout: &mut Layout<CellShaper>,
    run: impl FnOnce(&mut Layout<CellShaper>),
) -> usize {
    let before = layout.shaper().bytes_shaped();
    run(layout);
    layout.shaper().bytes_shaped() - before
}

#[test]
fn an_unchanged_status_row_is_not_shaped_again() {
    let (text, _) = twenty();
    let fields = [("words.txt", "name"), (" 1:1", "position")];
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    let first = bytes_shaped(&mut layout, |layout| {
        layout.frame(&with_status(&text, &fields, &[]));
    });
    // The twenty rows, and the status row's thirteen bytes.
    assert_eq!(first, text.snapshot.len() - 19 + 13);
    let again = bytes_shaped(&mut layout, |layout| {
        layout.frame(&with_status(&text, &fields, &[]));
    });
    assert_eq!(again, 0);
    // A cursor move shapes neither a row nor the status row.
    let mut moved = with_status(&text, &fields, &[]);
    moved.views[0].selections = vec![Selection::new(vec![SelectionRange::new(12, 12)], 0).unwrap()];
    let moving = bytes_shaped(&mut layout, |layout| {
        layout.frame(&moved);
    });
    assert_eq!(moving, 0);
    // Another text of one field is shaped, and only that field: each
    // field is a line of its own.
    let fields = [("words.txt", "name"), (" 2:1", "position")];
    let changed = bytes_shaped(&mut layout, |layout| {
        layout.frame(&with_status(&text, &fields, &[]));
    });
    assert_eq!(changed, 4);
    // The same glyphs in fields cut another way are other fields, and are
    // shaped again.
    let fields = [("words", "name"), (".txt 2:1", "position")];
    let recut = bytes_shaped(&mut layout, |layout| {
        layout.frame(&with_status(&text, &fields, &[]));
    });
    assert_eq!(recut, 13);
    // A field that moves to another place in the row is found again.
    let fields = [(".txt 2:1", "position"), ("words", "name")];
    let moved = bytes_shaped(&mut layout, |layout| {
        layout.frame(&with_status(&text, &fields, &[]));
    });
    assert_eq!(moved, 0);
    // A font change shapes it again, with every row.
    layout.shaper().change_fonts();
    let reshaped = bytes_shaped(&mut layout, |layout| {
        layout.frame(&with_status(&text, &fields, &[]));
    });
    assert_eq!(reshaped, first);
}

#[test]
fn a_paint_only_change_does_not_shape_the_status_row() {
    let (text, _) = twenty();
    let fields = [("words.txt", "name"), (" 1:1", "position")];
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.frame(&with_status(&text, &fields, &[("name", coloured(1))]));
    let paints: [&[(&str, Face)]; 3] = [
        &[("name", coloured(2))],
        &[(
            "mode-line",
            Face {
                background: Some(Color::rgb(0, 0, 9)),
                ..Face::default()
            },
        )],
        &[(
            "position",
            Face {
                strike_through: Some(true),
                ..Face::default()
            },
        )],
    ];
    for faces in paints {
        let mut status = None;
        let repainted = bytes_shaped(&mut layout, |layout| {
            status = layout.frame(&with_status(&text, &fields, faces)).views[0]
                .status
                .clone();
        });
        assert_eq!(repainted, 0, "{faces:?}");
        assert!(status.is_some(), "{faces:?}");
    }
    // A face of a field that sets a font attribute shapes that field
    // again, and no other field and no row of the text.
    let bold = [(
        "name",
        Face {
            weight: Some(Weight::BOLD),
            ..Face::default()
        },
    )];
    let reshaped = bytes_shaped(&mut layout, |layout| {
        let counted = counted(layout, |layout| {
            layout.frame(&with_status(&text, &fields, &bold));
        });
        assert_eq!(counted, count(0, 0, 20));
    });
    assert_eq!(reshaped, 9);
    // And the mode line's font, which every field is under, shapes them
    // all.
    let sized = [(
        "mode-line",
        Face {
            size: Some(Length::pixels(8)),
            ..Face::default()
        },
    )];
    let resized = bytes_shaped(&mut layout, |layout| {
        layout.frame(&with_status(&text, &fields, &sized));
    });
    assert_eq!(resized, 13);
}
