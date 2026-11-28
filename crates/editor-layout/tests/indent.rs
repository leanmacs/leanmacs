//! Wrap indents ([`WrapIndent`]): where the visual lines of a view's rows
//! start, by frame and by query.
//!
//! The shaper is the fake: a glyph of the default family is 10 pixels
//! across and a line 16 down at the base size, and a glyph of the family
//! `narrow` 7 across. So, worked by hand:
//!
//! - In a view 100 pixels wide, a row under a first-line indent of 20 and
//!   a continuation of 40 points holds 8 glyphs on its first visual line
//!   (80 pixels of room) and 6 on each later one (60): a row of 20 glyphs
//!   is three visual lines, `0..8`, `8..14` and `14..20`, whose first
//!   glyphs are at 20, 40 and 40. At scale 2 the view is 200 pixels and
//!   the glyphs 20: the same breaks, at 40 and 80.
//! - `• ` with `•` in `narrow` is 17 pixels, and `10. ` 40: a hang after
//!   either starts its later lines at 17 or 40, which no count of spaces
//!   gives on both rows.

use editor_layout::Layout;
use editor_layout::face::{Face, FaceDef};
use editor_layout::frame::ViewFrame;
use editor_layout::query::Spot;
use editor_layout::scene::{
    AlignStop, Continuation, Decoration, Padding, Rect, Scene, TextKey, TextRef, View, ViewId,
    WrapIndent,
};
use editor_layout::shaper::fake::CellShaper;
use editor_text::{Selection, SelectionRange, Text};

/// The fake, with the family `narrow` 7 pixels a glyph.
fn layout() -> Layout<CellShaper> {
    Layout::new(CellShaper::new(10.0, 16.0).with_family("narrow", 7.0, 16.0))
}

/// The face `narrow`: its family and nothing else.
fn narrow() -> FaceDef {
    FaceDef {
        name: "narrow".to_owned(),
        face: Face {
            family: Some("narrow".to_owned()),
            ..Face::default()
        },
    }
}

/// `text` as text 1.
fn text_ref(text: &str) -> TextRef {
    TextRef::fixed(TextKey(1), Text::from(text).snapshot())
}

/// A view of `text`, `width` pixels wide and 160 down, with `indents`.
fn view(text: &TextRef, width: u32, indents: Vec<WrapIndent>) -> View {
    View {
        id: ViewId(1),
        rect: Rect {
            x: 0,
            y: 0,
            width,
            height: 160,
        },
        text: Some(text.clone()),
        indents,
        ..View::default()
    }
}

/// A scene of `view`, with the face `narrow` defined.
fn scene(view: View) -> Scene {
    Scene {
        views: vec![view],
        faces: Some(vec![narrow()]),
        ..Scene::default()
    }
}

/// The frame of the one view of `scene`.
fn frame(layout: &mut Layout<CellShaper>, scene: &Scene) -> ViewFrame {
    layout.frame(scene).views.remove(0)
}

/// An indent over `start..stop`, its first line `first` points in and
/// the rest `rest` points in.
fn points(start: usize, stop: usize, first: u32, rest: u32) -> WrapIndent {
    WrapIndent {
        start,
        stop,
        first,
        rest: Continuation::Points(rest),
    }
}

/// A hanging indent over `start..stop`, its first line `first` points in
/// and the rest where the row's first `lead` bytes end.
fn hanging(start: usize, stop: usize, first: u32, lead: usize) -> WrapIndent {
    WrapIndent {
        start,
        stop,
        first,
        rest: Continuation::Lead(lead),
    }
}

/// Each text row of `frame` as its bytes and the x of its first glyph
/// from the view's left, or of its end when it has none.
fn starts(frame: &ViewFrame) -> Vec<((usize, usize), f32)> {
    frame
        .rows
        .iter()
        .filter(|row| row.is_text())
        .map(|row| {
            let x = row
                .line
                .glyphs
                .first()
                .map_or(row.line.width, |glyph| glyph.x);
            ((row.bytes.start, row.bytes.end), row.x + x)
        })
        .collect()
}

/// The x from the view's left of the glyph of byte `column` of the row
/// whose first byte is `row_start`, on whichever of its text rows draws
/// it, with the index of that row among the text rows.
fn drawn(frame: &ViewFrame, row_start: usize, column: usize) -> (usize, f32) {
    frame
        .rows
        .iter()
        .filter(|row| row.is_text())
        .enumerate()
        .find_map(|(index, row)| {
            if !row.bytes.contains(&(row_start + column)) {
                return None;
            }
            let glyph = row
                .line
                .glyphs
                .iter()
                .find(|glyph| glyph.cluster == column)?;
            Some((index, row.x + glyph.x))
        })
        .expect("a glyph drawn for the column")
}

/// The rows the rows query answers for a view of `text` `width` wide and
/// 160 down, with no padding, from the start.
fn asked(layout: &mut Layout<CellShaper>, text: &TextRef, width: f32) -> Vec<(usize, usize)> {
    layout
        .rows_shown(text, width, 160.0, Padding::default(), 0)
        .unwrap()
        .iter()
        .map(|row| (row.start, row.stop))
        .collect()
}

/// A row of 20 glyphs, an empty row, and a row of three.
const ROWS: &str = "abcdefghijklmnopqrst\n\nuvw";

/// An indent of 20 and 40 points over the first two rows of [`ROWS`].
fn twenty_and_forty() -> Vec<WrapIndent> {
    vec![points(0, 22, 20, 40)]
}

#[test]
fn a_first_line_and_a_continuation_indent_start_their_visual_lines_at_those_offsets() {
    let text = text_ref(ROWS);
    let mut layout = layout();
    // A cursor on the empty row.
    let mut shown = view(&text, 100, twenty_and_forty());
    shown.selections = vec![Selection::new(vec![SelectionRange::new(21, 21)], 0).unwrap()];
    let laid = frame(&mut layout, &scene(shown.clone()));
    assert_eq!(
        starts(&laid),
        vec![
            ((0, 8), 20.0),
            ((8, 14), 40.0),
            ((14, 20), 40.0),
            // The empty row is at its first-line indent, and the row
            // outside the range at 0.
            ((21, 21), 20.0),
            ((22, 25), 0.0),
        ]
    );
    assert_eq!(laid.cursors[0].area.x, 20.0);
    // At scale 2 the indents are twice as far in.
    let mut doubled = self::layout();
    doubled.set_scale(2.0);
    let laid = frame(
        &mut doubled,
        &scene(View {
            rect: Rect {
                width: 200,
                ..shown.rect
            },
            ..shown.clone()
        }),
    );
    let xs: Vec<f32> = starts(&laid).iter().map(|(_, x)| *x).collect();
    assert_eq!(xs, vec![40.0, 80.0, 80.0, 40.0, 0.0]);
    // With a padding and a gutter, from where the text rows start: 4
    // points across and a gutter of 6, the text 100 pixels wide.
    let mut padded = self::layout();
    let laid = frame(
        &mut padded,
        &scene(View {
            rect: Rect {
                width: 114,
                ..shown.rect
            },
            padding: Padding {
                gutter: 6,
                ..Padding::new(4, 0, 0)
            },
            ..shown
        }),
    );
    let xs: Vec<f32> = starts(&laid).iter().map(|(_, x)| *x).collect();
    assert_eq!(xs, vec![30.0, 50.0, 50.0, 30.0, 10.0]);
}

/// Two list items whose markers are of different widths: `• ` in
/// `narrow` (17 pixels) and `10. ` (40 pixels), each 4 bytes.
const ITEMS: &str = "• alpha beta gamma delta\n10. beta gamma delta epsilon";

/// A view of [`ITEMS`] 120 pixels wide, `•` in `narrow`, each row under a
/// hang after its marker and space, its first line `first` points in.
fn items(first: u32) -> View {
    let second = ITEMS.find('\n').unwrap() + 1;
    View {
        decorations: vec![Decoration {
            start: 0,
            stop: '•'.len_utf8(),
            face: "narrow".to_owned(),
        }],
        ..view(
            &text_ref(ITEMS),
            120,
            vec![
                hanging(0, 1, first, 4),
                hanging(second, second + 1, first, 4),
            ],
        )
    }
}

/// For each row of [`ITEMS`] in `frame`: the x of its first glyph after
/// its lead, on its first visual line, and the x of the first glyph of
/// each of its later visual lines.
fn hangs(frame: &ViewFrame) -> Vec<(f32, Vec<f32>)> {
    let second = ITEMS.find('\n').unwrap() + 1;
    [(0, second - 1), (second, ITEMS.len())]
        .into_iter()
        .map(|(start, end)| {
            let (line, after) = drawn(frame, start, 4);
            let later: Vec<f32> = starts(frame)
                .iter()
                .filter(|((first, _), _)| start < *first && *first < end)
                .map(|(_, x)| *x)
                .collect();
            // The glyph is on the row's first visual line.
            let first = starts(frame)
                .iter()
                .position(|((first, _), _)| *first == start);
            assert_eq!(Some(line), first);
            (after, later)
        })
        .collect()
}

#[test]
fn a_hanging_indent_continues_where_its_leading_span_ends_on_a_proportional_font() {
    let mut layout = layout();
    let flat = hangs(&frame(&mut layout, &scene(items(0))));
    for (after, later) in &flat {
        assert!(!later.is_empty(), "the row wraps");
        assert!(
            later.iter().all(|x| x == after),
            "{later:?} hang at {after}"
        );
    }
    // The two hangs differ: 17 and 40.
    assert_eq!(flat[0].0, 17.0);
    assert_eq!(flat[1].0, 40.0);
    // Under a first-line indent of 16 points, each moves right by 16.
    let nested = hangs(&frame(&mut layout, &scene(items(16))));
    for ((flat_after, _), (after, later)) in flat.iter().zip(&nested) {
        assert_eq!(*after, flat_after + 16.0);
        assert!(
            later.iter().all(|x| x == after),
            "{later:?} hang at {after}"
        );
    }
}

#[test]
fn a_move_and_a_spot_on_an_indented_line_are_at_its_drawn_x() {
    let text = text_ref(ROWS);
    let mut layout = layout();
    frame(&mut layout, &scene(view(&text, 100, twenty_and_forty())));
    // The rows query splits the row at the narrower room of the later
    // lines.
    assert_eq!(
        asked(&mut layout, &text, 100.0)[..3],
        [(0, 8), (8, 14), (14, 20)]
    );
    let moved = |layout: &mut Layout<CellShaper>, width, position, lines, goal| {
        layout
            .lines_from(&text, width, 0, position, lines, goal)
            .unwrap()
    };
    // A goal of 75 on the second line is the character drawn there: it
    // starts at 40, so 75 is in its fourth glyph, `l`.
    let down = moved(&mut layout, 100.0, 2, 1, Some(75.0));
    assert_eq!((down.position, down.goal), (11, 75.0));
    // With no goal, the goal passed back is the drawn x, the indent
    // counted: `j`, the second glyph of the second line, is at 50.
    let up = moved(&mut layout, 100.0, 9, -1, None);
    assert_eq!(up.goal, 50.0);
    // And 50 on the first line, which starts at 20, is `d`.
    assert_eq!(up.position, 3);
    // A goal left of the indent lands on the line's first character.
    assert_eq!(moved(&mut layout, 100.0, 0, 1, Some(5.0)).position, 8);
    // The spot of `j` is where it is drawn.
    assert_eq!(
        layout.spot(&text, 100.0, 160.0, Padding::default(), 0, 9),
        Ok(Some(Spot {
            x: 50.0,
            y: 16.0,
            height: 16.0
        }))
    );
    // Unwrapped, a width wider than any row, as a move within a line is
    // asked: the first-line indent is counted, and `c` is at 40.
    let wide = 1.0e12;
    let unwrapped = moved(&mut layout, wide, 2, 0, None);
    assert_eq!((unwrapped.position, unwrapped.goal), (2, 40.0));
    assert_eq!(moved(&mut layout, wide, 0, 0, Some(55.0)).position, 3);
}

#[test]
fn a_query_lays_a_row_out_under_the_indents_of_the_last_frame() {
    let mut edited = Text::from("abcdefgh");
    let text = TextRef::fixed(TextKey(1), edited.snapshot());
    let mut layout = layout();
    // Before any frame of the text the query knows no indent: six glyphs
    // fit 60 pixels.
    assert_eq!(asked(&mut layout, &text, 60.0), vec![(0, 6), (6, 8)]);
    let laid = frame(
        &mut layout,
        &scene(view(&text, 60, vec![points(0, 1, 20, 20)])),
    );
    let rows: Vec<(usize, usize)> = starts(&laid).iter().map(|(bytes, _)| *bytes).collect();
    assert_eq!(rows, vec![(0, 4), (4, 8)]);
    // After it, the query agrees with it.
    assert_eq!(asked(&mut layout, &text, 60.0), rows);
    // At a newer revision no frame has shown, no indent again.
    edited.replace(8..8, "!").unwrap();
    let newer = TextRef::fixed(TextKey(1), edited.snapshot());
    assert_eq!(asked(&mut layout, &newer, 60.0), vec![(0, 6), (6, 9)]);
}

#[test]
fn an_indent_at_or_past_the_width_is_not_applied() {
    let text = text_ref("abcdefgh");
    let mut layout = layout();
    // A first-line indent of 60 in a view 60 wide, and a continuation of
    // 70: each line starts at 0, broken at the whole width.
    let laid = frame(
        &mut layout,
        &scene(view(&text, 60, vec![points(0, 1, 60, 70)])),
    );
    assert_eq!(starts(&laid), vec![((0, 6), 0.0), ((6, 8), 0.0)]);
}

#[test]
fn of_two_indents_over_a_row_the_later_wins() {
    let text = text_ref("abc\ndef");
    let mut layout = layout();
    let laid = frame(
        &mut layout,
        &scene(view(
            &text,
            100,
            vec![points(0, 7, 10, 10), points(4, 5, 30, 30)],
        )),
    );
    assert_eq!(starts(&laid), vec![((0, 3), 10.0), ((4, 7), 30.0)]);
}

#[test]
fn a_row_with_stops_starts_its_first_cell_at_the_indent_and_an_overflowed_cell_at_the_continuation()
{
    let text = text_ref("ab cd");
    let mut layout = layout();
    // A stop at 60 in a view 50 wide moves `cd` down, to the continuation
    // indent.
    let laid = frame(
        &mut layout,
        &scene(View {
            stops: vec![AlignStop { offset: 3, x: 60 }],
            ..view(&text, 50, vec![points(0, 1, 10, 20)])
        }),
    );
    assert_eq!(starts(&laid), vec![((0, 3), 10.0), ((3, 5), 20.0)]);
}

#[test]
fn a_query_after_a_change_of_scale_lays_a_row_out_under_the_indents_at_the_new_scale() {
    let text = text_ref(ROWS);
    let mut layout = layout();
    frame(&mut layout, &scene(view(&text, 100, twenty_and_forty())));
    // At scale 2 the view is 200 pixels, a glyph 20 and the indents 40
    // and 80: the same breaks as at scale 1. At the indents' pixels of
    // scale 1, 20 and 40, the first line would hold 9 glyphs and the rest
    // 8.
    layout.set_scale(2.0);
    let asked_rows = asked(&mut layout, &text, 200.0);
    assert_eq!(asked_rows[..3], [(0, 8), (8, 14), (14, 20)]);
    // `i` starts the second line, at 80, and `j` is at 100.
    let spot = layout
        .spot(&text, 200.0, 160.0, Padding::default(), 0, 8)
        .unwrap()
        .expect("a spot");
    assert_eq!(spot.x, 80.0);
    let up = layout.lines_from(&text, 200.0, 0, 9, -1, None).unwrap();
    assert_eq!(up.goal, 100.0);
    // And the next frame is what the queries said.
    let laid = frame(&mut layout, &scene(view(&text, 200, twenty_and_forty())));
    let rows: Vec<(usize, usize)> = starts(&laid).iter().map(|(bytes, _)| *bytes).collect();
    assert_eq!(rows, asked_rows);
    assert_eq!(drawn(&laid, 0, 8), (1, 80.0));
    assert_eq!(drawn(&laid, 0, 9), (1, 100.0));
}
