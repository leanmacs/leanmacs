//! Layout over the real shaper: wiring only.
//!
//! What layout shapes, and when, is `editor-layout`'s rule, pinned there
//! on the port's fake; what a `shape` call costs is this crate's, pinned
//! in `tests/adapter.rs`. These tests put the two together and compare
//! the adapter's counters with layout's own, and with the longest segment
//! layout hands a shaper, by name. They state no row, no width and no
//! number of layout's.
//!
//! The wiring of face families is here too: layout merges a span's faces
//! attribute by attribute (`editor-layout`'s rule) and this crate resolves
//! a generic family name to the set's family (`tests/shaping.rs`), so a
//! span in a face naming `system-ui` is drawn in the proportional fixture
//! and a face naming `monospace` over it in the monospace one. The faces
//! are the tests' own; which faces the editor ships is Lean's.
//!
//! And of align-to stops: cells of one column, after first cells of
//! different widths on the proportional fixture, start at one x. The stop
//! is computed from layout's own measure, and the cells are compared with
//! each other, not with a number. And of a hanging wrap indent: each
//! row's later visual lines start under its first character after its
//! lead, on the proportional fixture, compared with that character's own
//! x in the frame.

mod common;

use std::ops::Range;

use editor_layout::Layout;
use editor_layout::face::{Face, FaceDef};
use editor_layout::scene::{AlignStop, Continuation, Decoration, Padding, Rect, Scene, WrapIndent};
use editor_layout::shaper::Shaper;
use editor_layout::tabs::SEGMENT_BYTES;
use editor_shape_parley::{FontSet, ParleyShaper, ShapeCounters};

use common::{MONO, MONO_FAMILY, SANS, SANS_FAMILY, shaper};

/// A view's rectangle `width` pixels across, tall enough for every row of
/// the texts here.
fn rect(width: u32) -> Rect {
    Rect {
        x: 0,
        y: 0,
        width,
        height: 4000,
    }
}

/// Twenty rows of two words, the row `changed` with one more.
fn twenty_rows(changed: Option<usize>) -> String {
    (0..20)
        .map(|row| match changed {
            Some(at) if at == row => format!("row {row} edited"),
            _ => format!("row {row}"),
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// How many segments layout says it shaped while `run` ran, and what its
/// shaper counted meanwhile. Of layout's counters only that one is read:
/// the others are layout's own business, and it may add to them.
fn counted(
    layout: &mut Layout<ParleyShaper>,
    run: impl FnOnce(&mut Layout<ParleyShaper>),
) -> (u64, ShapeCounters) {
    let (laid, shaped) = (layout.counters().shaped, layout.shaper().counters());
    run(layout);
    let (laid_after, shaped_after) = (layout.counters().shaped, layout.shaper().counters());
    (
        laid_after - laid,
        ShapeCounters {
            layouts: shaped_after.layouts - shaped.layouts,
            bytes: shaped_after.bytes - shaped.bytes,
        },
    )
}

#[test]
fn layout_builds_one_parley_layout_for_each_segment_it_shapes() {
    let mut layout = Layout::new(shaper());
    let text = twenty_rows(None);
    let steps: Vec<(&str, Scene)> = vec![
        ("a first frame", Scene::of_text(&text, rect(800))),
        ("the same frame again", Scene::of_text(&text, rect(800))),
        (
            "a row edited",
            Scene::of_text(&twenty_rows(Some(7)), rect(800)),
        ),
        ("a narrower view", Scene::of_text(&text, rect(40))),
        (
            "a cursor placed",
            Scene::of_text(&text, rect(40)).selecting(3..3),
        ),
        (
            "the cursor moved",
            Scene::of_text(&text, rect(40)).selecting(30..30),
        ),
    ];
    let mut any = 0;
    for (step, scene) in steps {
        let (laid, shaped) = counted(&mut layout, |layout| {
            let frame = layout.frame(&scene);
            assert!(!frame.views[0].rows.is_empty(), "{step}");
        });
        // Whatever layout says it shaped, the adapter built that many
        // Parley layouts and no more: none for a break, a reuse, a font's
        // metrics or a cursor.
        assert_eq!(shaped.layouts, laid, "{step}");
        any += shaped.layouts;
    }
    assert!(any > 0);
    // The queries go through the same entries.
    let scene = Scene::of_text(&text, rect(40));
    let shown = scene.views[0].text.clone().expect("a text");
    let (laid, shaped) = counted(&mut layout, |layout| {
        layout
            .rows_shown(&shown, 40.0, 100.0, Padding::default(), 0)
            .expect("rows");
        layout
            .lines_from(&shown, 300.0, 0, 0, 3, None)
            .expect("a move");
    });
    assert_eq!(shaped.layouts, laid);
}

#[test]
fn no_parley_layout_holds_a_whole_long_row() {
    // One row of four times the longest segment, with no tab, so that
    // what a shaper is handed is as long as the bytes of the row it is
    // cut from.
    let unit = "abcdefg xyz ";
    let row = unit.repeat(4 * SEGMENT_BYTES / unit.len());
    let mut scene = Scene::of_text(&row, rect(800));
    scene.views[0].rect.height = 400;
    scene.views[0].scroll = row.len() / 2;
    let mut layout = Layout::new(shaper());
    let (laid, shaped) = counted(&mut layout, |layout| {
        let frame = layout.frame(&scene);
        assert!(!frame.views[0].rows.is_empty());
    });
    assert!(laid > 0);
    assert_eq!(shaped.layouts, laid);
    // Each layout holds at most a segment, and all of them less than the
    // row.
    let segment = u64::try_from(SEGMENT_BYTES).expect("a length");
    assert!(shaped.bytes <= segment * laid, "{shaped:?}");
    assert!(shaped.bytes < u64::try_from(row.len()).expect("a length"));
}

#[test]
fn a_selection_across_latin_and_hebrew_covers_the_glyphs_of_what_is_selected() {
    // `abc`, a space, then four Hebrew letters of two bytes each, drawn
    // right to left. Bytes 2 to 8 are `c`, the space and the first two
    // Hebrew letters, which are the two rightmost glyphs of the line: what
    // is selected is not one stretch of the line.
    let selected = 2..8;
    let scene = Scene::of_text("abc שלום", rect(800)).selecting(selected.clone());
    let mut layout = Layout::new(shaper());
    let frame = layout.frame(&scene);
    let view = &frame.views[0];
    let glyphs = &view.rows[0].line.glyphs;
    let advances: f32 = glyphs
        .iter()
        .filter(|glyph| selected.contains(&glyph.cluster))
        .map(|glyph| glyph.advance)
        .sum();
    assert!(advances > 0.0);
    // Every area is wider than nothing, and together they are as wide as
    // the glyphs of the selected characters: no more and no less is
    // covered.
    assert!(!view.selections.is_empty());
    assert!(view.selections.iter().all(|area| area.width > 0.0));
    let covered: f32 = view.selections.iter().map(|area| area.width).sum();
    assert!((covered - advances).abs() < 0.01, "{covered} of {advances}");
}

/// A shaper over the proportional and the monospace fixture, the
/// monospace family the default, with `monospace` given as it and
/// `system-ui` as the proportional one.
fn generic_shaper() -> ParleyShaper {
    let fonts = FontSet::only(MONO_FAMILY, &[], [SANS.to_vec(), MONO.to_vec()])
        .and_then(|fonts| fonts.with_generic("monospace", &[MONO_FAMILY]))
        .and_then(|fonts| fonts.with_generic("system-ui", &[SANS_FAMILY]))
        .expect("the fixture fonts");
    ParleyShaper::new(fonts)
}

/// A face of the family `name` and nothing else, as `face`.
fn family_def(face: &str, name: &str) -> FaceDef {
    FaceDef {
        name: face.to_owned(),
        face: Face {
            family: Some(name.to_owned()),
            ..Face::default()
        },
    }
}

/// `text` in a wide view, with `default` in `monospace`, `prose` in
/// `system-ui` and `code` in `monospace`, and each of `spans` drawn in
/// its face, in that order.
fn faced(text: &str, spans: &[(Range<usize>, &str)]) -> Scene {
    let mut scene = Scene::of_text(text, rect(800));
    scene.faces = Some(vec![
        family_def("default", "monospace"),
        family_def("prose", "system-ui"),
        family_def("code", "monospace"),
    ]);
    scene.views[0].decorations = spans
        .iter()
        .map(|(bytes, face)| Decoration {
            start: bytes.start,
            stop: bytes.end,
            face: (*face).to_owned(),
        })
        .collect();
    scene
}

/// Whether each glyph of the first row of `scene`'s frame is drawn from
/// the bytes of `SANS` when `proportional` holds of its cluster, and from
/// `MONO` when it does not.
fn drawn_proportional_where(scene: &Scene, proportional: impl Fn(usize) -> bool) {
    let mut layout = Layout::new(generic_shaper());
    let frame = layout.frame(scene);
    let glyphs = &frame.views[0].rows[0].line.glyphs;
    assert!(!glyphs.is_empty());
    let resolved = layout.shaper().resolved();
    for glyph in glyphs {
        let data = &resolved[glyph.font.0 as usize].data;
        let expected = if proportional(glyph.cluster) {
            SANS
        } else {
            MONO
        };
        assert_eq!((**data).as_ref(), expected, "{glyph:?}");
    }
}

#[test]
fn a_span_in_a_face_naming_system_ui_is_shaped_in_the_sets_proportional_family() {
    let text = "some prose here";
    let word = 5..10;
    let scene = faced(text, &[(word.clone(), "prose")]);
    drawn_proportional_where(&scene, |cluster| word.contains(&cluster));
}

#[test]
fn a_code_face_naming_monospace_over_the_prose_face_is_shaped_in_monospace() {
    let text = "prose with code inside";
    let code = 11..15;
    let scene = faced(text, &[(0..text.len(), "prose"), (code.clone(), "code")]);
    drawn_proportional_where(&scene, |cluster| !code.contains(&cluster));
}

#[test]
fn stops_line_cells_up_over_the_proportional_fixture() {
    // Rows whose first cells are in the default family, the proportional
    // fixture, and of different measured widths; each has a second cell
    // at one stop. The stop is past the widest first cell, from layout's
    // own measure, so no number of layout's is stated.
    let rows = ["il x", "WWW x", "mm x"];
    let firsts = rows.map(|row| &row[..row.find('x').expect("a second cell")]);
    let mut layout = Layout::new(shaper());
    let widths = firsts.map(|first| layout.measure(first, &[]));
    assert!(
        widths[0] != widths[1] && widths[1] != widths[2] && widths[0] != widths[2],
        "the first cells measure apart: {widths:?}"
    );
    let stop_x = widths.iter().max().copied().unwrap_or_default() + 8;
    let text = rows.join("\n");
    let mut scene = Scene::of_text(&text, rect(800));
    let mut row_start = 0;
    let mut seconds = Vec::new();
    for row in rows {
        let offset = row_start + row.find('x').expect("a second cell");
        seconds.push((offset, offset - row_start));
        row_start += row.len() + 1;
    }
    scene.views[0].stops = seconds
        .iter()
        .map(|(offset, _)| AlignStop {
            offset: *offset,
            x: stop_x,
        })
        .collect();
    let frame = layout.frame(&scene);
    let xs: Vec<f32> = seconds
        .iter()
        .map(|(offset, column)| {
            let row = frame.views[0]
                .rows
                .iter()
                .find(|row| row.bytes.contains(offset))
                .expect("the row of the cell");
            let glyph = row
                .line
                .glyphs
                .iter()
                .find(|glyph| glyph.cluster == *column)
                .expect("the cell's first glyph");
            row.x + glyph.x
        })
        .collect();
    assert!(
        xs.iter().all(|x| *x == xs[0]),
        "every second cell starts at one x: {xs:?}"
    );
}

#[test]
fn a_hanging_indent_continues_under_the_text_after_its_lead_over_the_proportional_fixture() {
    // Two rows of words whose leads, a marker and a space, measure apart
    // on the proportional fixture. The view is as wide as the wider lead
    // and a few words, from layout's own measure, so each row wraps.
    let leads = ["\u{2022} ", "10. "];
    let words = "alpha beta gamma delta epsilon zeta eta theta iota kappa";
    let rows = leads.map(|lead| format!("{lead}{words}"));
    let mut layout = Layout::new(shaper());
    let widths = leads.map(|lead| layout.measure(lead, &[]));
    assert!(
        widths[0] != widths[1],
        "the leads measure apart: {widths:?}"
    );
    let width =
        widths.iter().max().copied().unwrap_or_default() + layout.measure("alpha beta", &[]);
    let text = rows.join("\n");
    let mut scene = Scene::of_text(&text, rect(width));
    let mut starts = Vec::new();
    let mut row_start = 0;
    for (row, lead) in rows.iter().zip(leads) {
        starts.push((row_start, row_start + row.len(), lead.len()));
        row_start += row.len() + 1;
    }
    scene.views[0].indents = starts
        .iter()
        .map(|&(start, _, lead)| WrapIndent {
            start,
            stop: start + 1,
            first: 0,
            rest: Continuation::Lead(lead),
        })
        .collect();
    let frame = layout.frame(&scene);
    let rows_of = |start: usize, end: usize| {
        frame.views[0]
            .rows
            .iter()
            .filter(move |row| row.is_text() && start <= row.bytes.start && row.bytes.start < end)
    };
    for &(start, end, lead) in &starts {
        let first = rows_of(start, end).next().expect("the row's first line");
        let after = first
            .line
            .glyphs
            .iter()
            .find(|glyph| glyph.cluster == lead)
            .map(|glyph| first.x + glyph.x)
            .expect("the first glyph after the lead");
        let later: Vec<f32> = rows_of(start, end)
            .skip(1)
            .map(|row| row.x + row.line.glyphs.first().map_or(0.0, |glyph| glyph.x))
            .collect();
        assert!(!later.is_empty(), "the row at {start} wraps");
        assert!(
            later.iter().all(|x| *x == after),
            "the later lines of the row at {start} start under {after}: {later:?}"
        );
    }
}
