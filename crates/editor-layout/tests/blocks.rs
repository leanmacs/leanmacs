//! Block decorations: rows of text of their own, drawn between the rows of
//! a view ([`Block`]; `query`'s module docs, "Blocks").
//!
//! The text is what an excerpt list of two whole-line excerpts reads,
//! `two\n\nalpha\n`, built with `Text::from`: where a block goes is
//! layout's rule, whatever made the text. Its headers are blocks before
//! the start of each excerpt, 0 and 5, in a face `block-header` defined
//! red on yellow.
//!
//! The shaper is the fake, at 10 pixels across and 16 down, so every
//! number here is worked by hand.

use editor_layout::Layout;
use editor_layout::face::{Color, Face, FaceDef, Paint};
use editor_layout::frame::{FrameRow, ViewFrame};
use editor_layout::query::{Around, RowRange, Spot};
use editor_layout::scene::{
    Block, Cursor, Decoration, Padding, Rect, Scene, TextKey, TextRef, View, ViewId,
};
use editor_layout::shaper::Length;
use editor_layout::shaper::fake::CellShaper;
use editor_text::{Selection, SelectionRange, Text};

/// The text the excerpts read.
const EXCERPTS: &str = "two\n\nalpha\n";

/// The header face's ink and paper.
const RED: Color = Color::rgb(0xcc, 0, 0);
const YELLOW: Color = Color::rgb(0xee, 0xee, 0);

/// A layout on cells 10 by 16, with `block-header` red on yellow.
fn layout() -> Layout<CellShaper> {
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.define(&[FaceDef {
        name: "block-header".to_owned(),
        face: Face {
            foreground: Some(RED),
            background: Some(YELLOW),
            ..Face::default()
        },
    }]);
    layout
}

/// A header block of `text` before `before`, all of it in `block-header`.
fn header(before: usize, text: &str) -> Block {
    Block {
        before,
        text: text.to_owned(),
        decorations: vec![Decoration {
            start: 0,
            stop: text.len(),
            face: "block-header".to_owned(),
        }],
    }
}

/// The headers of the two excerpts.
fn headers() -> Vec<Block> {
    vec![header(0, "one.txt"), header(5, "two.txt")]
}

/// `text`, as text 1.
fn text_of(text: &str) -> TextRef {
    TextRef::fixed(TextKey(1), Text::from(text).snapshot())
}

/// A view of `text` `columns` cells wide and `rows` rows tall from
/// `scroll`, with `blocks`.
fn view(text: &str, columns: u32, rows: u32, scroll: usize, blocks: Vec<Block>) -> View {
    View {
        id: ViewId(1),
        rect: Rect {
            x: 0,
            y: 0,
            width: columns * 10,
            height: rows * 16,
        },
        text: Some(text_of(text)),
        scroll,
        cursor: Cursor {
            face: "cursor".to_owned(),
            ..Cursor::default()
        },
        blocks,
        ..View::default()
    }
}

/// The frame of `view` alone.
fn frame(layout: &mut Layout<CellShaper>, view: View) -> ViewFrame {
    let scene = Scene {
        views: vec![view],
        ..Scene::default()
    };
    layout.frame(&scene).views.remove(0)
}

/// Each row as its block, its top and its bytes.
fn described(rows: &[FrameRow]) -> Vec<(Option<usize>, f32, (usize, usize))> {
    rows.iter()
        .map(|row| (row.block, row.y, (row.bytes.start, row.bytes.end)))
        .collect()
}

/// The bytes of the text rows of `rows`.
fn text_rows(rows: &[FrameRow]) -> Vec<(usize, usize)> {
    rows.iter()
        .filter(|row| row.block.is_none())
        .map(|row| (row.bytes.start, row.bytes.end))
        .collect()
}

/// The glyph ids of `row`.
fn ids(row: &FrameRow) -> Vec<u32> {
    row.line.glyphs.iter().map(|glyph| glyph.id).collect()
}

#[test]
fn a_view_of_an_excerpt_buffer_draws_each_header_as_a_block_row_above_its_excerpt() {
    let mut layout = layout();
    let laid = frame(&mut layout, view(EXCERPTS, 40, 10, 0, headers()));
    assert_eq!(
        described(&laid.rows),
        vec![
            (Some(0), 0.0, (0, 7)),
            (None, 16.0, (0, 3)),
            (None, 32.0, (4, 4)),
            (Some(1), 48.0, (0, 7)),
            (None, 64.0, (5, 10)),
            (None, 80.0, (11, 11)),
        ]
    );
    // A block row draws its block's text: the glyphs a row of that text
    // has.
    let plain = frame(
        &mut self::layout(),
        view("one.txt\ntwo.txt", 40, 10, 0, vec![]),
    );
    assert_eq!(ids(&laid.rows[0]), ids(&plain.rows[0]));
    assert_eq!(ids(&laid.rows[3]), ids(&plain.rows[1]));
    // In its block's faces: the whole header red on yellow.
    let header = Paint {
        foreground: RED,
        background: YELLOW,
        ..Paint::default()
    };
    for row in [&laid.rows[0], &laid.rows[3]] {
        assert_eq!(row.runs, vec![(0..7, header)]);
        assert_eq!(row.height, 16.0);
    }
    // And a row of the text is drawn as it is without blocks.
    let bare = frame(&mut layout, view(EXCERPTS, 40, 10, 0, vec![]));
    assert_eq!(laid.rows[1].runs, bare.rows[0].runs);
    assert_eq!(laid.rows[1].hash, bare.rows[0].hash);
}

#[test]
fn several_blocks_before_one_row_are_drawn_in_the_order_the_view_lists_them() {
    let mut layout = layout();
    let blocks = vec![header(5, "a"), header(6, "bb"), header(0, "c")];
    let laid = frame(&mut layout, view(EXCERPTS, 40, 10, 0, blocks));
    assert_eq!(
        described(&laid.rows),
        vec![
            (Some(2), 0.0, (0, 1)),
            (None, 16.0, (0, 3)),
            (None, 32.0, (4, 4)),
            (Some(0), 48.0, (0, 1)),
            (Some(1), 64.0, (0, 2)),
            (None, 80.0, (5, 10)),
            (None, 96.0, (11, 11)),
        ]
    );
}

#[test]
fn a_block_wider_than_the_view_wraps_to_more_block_rows() {
    let mut layout = layout();
    // Four cells: `one.txt` is `one.` and `txt`.
    let laid = frame(&mut layout, view(EXCERPTS, 4, 10, 0, headers()));
    assert_eq!(
        described(&laid.rows)[..3],
        [
            (Some(0), 0.0, (0, 4)),
            (Some(0), 16.0, (4, 7)),
            (None, 32.0, (0, 3)),
        ]
    );
}

#[test]
fn cursors_and_selections_are_on_text_rows_only_and_lower_by_the_blocks_above() {
    let mut layout = layout();
    let mut shown = view(EXCERPTS, 40, 10, 0, headers());
    // A cursor on `alpha`, and `two` selected.
    shown.selections = vec![
        Selection::new(vec![SelectionRange::new(6, 6)], 0).unwrap(),
        Selection::new(vec![SelectionRange::new(0, 3)], 0).unwrap(),
    ];
    let laid = frame(&mut layout, shown);
    let tops: Vec<f32> = laid.cursors.iter().map(|cursor| cursor.area.y).collect();
    // `alpha` is below two blocks and two rows; `two` below one block.
    assert_eq!(tops, vec![64.0, 16.0]);
    assert_eq!(laid.cursors[0].area.x, 10.0);
    let areas: Vec<(f32, f32, f32)> = laid
        .selections
        .iter()
        .map(|area| (area.x, area.y, area.width))
        .collect();
    assert_eq!(areas, vec![(0.0, 16.0, 30.0)]);
}

#[test]
fn the_blocks_before_the_anchors_row_are_shown_when_they_fit_with_it() {
    let mut layout = layout();
    let laid = frame(&mut layout, view(EXCERPTS, 40, 2, 5, headers()));
    assert_eq!(
        described(&laid.rows),
        vec![(Some(1), 0.0, (0, 7)), (None, 16.0, (5, 10))]
    );
}

#[test]
fn the_blocks_before_the_anchors_row_are_left_out_when_they_do_not_fit_with_it() {
    let mut layout = layout();
    let laid = frame(&mut layout, view(EXCERPTS, 40, 1, 5, headers()));
    assert_eq!(described(&laid.rows), vec![(None, 0.0, (5, 10))]);
    // An anchor on a wrapped continuation line has no blocks above it:
    // at four cells `alpha` is `alph` and `a`.
    let laid = frame(&mut layout, view(EXCERPTS, 4, 3, 9, headers()));
    assert_eq!(
        described(&laid.rows),
        vec![(None, 0.0, (9, 10)), (None, 16.0, (11, 11))]
    );
}

#[test]
fn a_row_and_its_blocks_are_shown_together_or_not_at_all_after_the_first() {
    let mut layout = layout();
    // Four rows: the first header, `two`, the separator, and no room for
    // the second header and `alpha` both, so neither is shown.
    let laid = frame(&mut layout, view(EXCERPTS, 40, 4, 0, headers()));
    assert_eq!(text_rows(&laid.rows), vec![(0, 3), (4, 4)]);
    assert_eq!(laid.rows.len(), 3);
}

#[test]
fn the_rows_query_answers_the_frames_text_rows_with_blocks() {
    let text = text_of(EXCERPTS);
    let blocks = vec![header(0, "one.txt"), header(5, "two.txt"), header(6, "x")];
    for columns in [40, 4] {
        for rows in 1..=8 {
            for anchor in 0..=EXCERPTS.len() {
                let mut layout = layout();
                let laid = frame(
                    &mut layout,
                    view(EXCERPTS, columns, rows, anchor, blocks.clone()),
                );
                let (width, height) = (columns as f32 * 10.0, rows as f32 * 16.0);
                let asked: Vec<(usize, usize)> = layout
                    .rows_shown_with_blocks(
                        &text,
                        width,
                        height,
                        Padding::default(),
                        anchor,
                        Around {
                            blocks: &blocks,
                            folds: &[],
                        },
                    )
                    .unwrap()
                    .into_iter()
                    .map(|RowRange { start, stop }| (start, stop))
                    .collect();
                let case = format!("{columns} cells, {rows} rows, from {anchor}");
                assert_eq!(asked, text_rows(&laid.rows), "{case}");
                // Each position's spot is the top of the frame's row that
                // holds it.
                for position in 0..=EXCERPTS.len() {
                    let spot = layout
                        .spot_with_blocks(
                            &text,
                            width,
                            height,
                            Padding::default(),
                            anchor,
                            position,
                            Around {
                                blocks: &blocks,
                                folds: &[],
                            },
                        )
                        .unwrap();
                    let mut text_rows = laid.rows.iter().filter(|row| row.block.is_none());
                    match spot {
                        Some(Spot { y, .. }) => assert!(
                            text_rows.any(|row| row.y == y
                                && row.bytes.start <= position
                                && position <= row.bytes.end),
                            "{case}: {position} is at {y}, on no row that holds it"
                        ),
                        None => assert!(
                            !text_rows
                                .any(|row| row.bytes.start <= position && position < row.bytes.end),
                            "{case}: {position} has no spot and a row holds it"
                        ),
                    }
                }
            }
        }
    }
}

#[test]
fn a_spot_below_a_block_is_lower_by_the_blocks_rows() {
    let text = text_of(EXCERPTS);
    let mut layout = layout();
    let spot = |layout: &mut Layout<CellShaper>, blocks: &[Block]| {
        layout
            .spot_with_blocks(
                &text,
                400.0,
                160.0,
                Padding::default(),
                0,
                7,
                Around { blocks, folds: &[] },
            )
            .unwrap()
            .unwrap()
    };
    let bare = spot(&mut layout, &[]);
    let blocked = spot(&mut layout, &headers());
    assert_eq!(blocked.y, bare.y + 32.0);
    assert_eq!((blocked.x, blocked.height), (bare.x, bare.height));
    // With no block, it is the spot the query without blocks answers.
    assert_eq!(
        layout.spot(&text, 400.0, 160.0, Padding::default(), 0, 7),
        Ok(Some(bare))
    );
}

#[test]
fn a_block_in_a_taller_face_is_a_taller_row_and_the_queries_count_its_height() {
    let mut layout = layout();
    layout.define(&[FaceDef {
        name: "block-big".to_owned(),
        face: Face {
            size: Some(Length::pixels(32)),
            ..Face::default()
        },
    }]);
    let big = Block {
        before: 0,
        text: "one.txt".to_owned(),
        decorations: vec![Decoration {
            start: 0,
            stop: 7,
            face: "block-big".to_owned(),
        }],
    };
    let blocks = vec![big];
    let laid = frame(&mut layout, view(EXCERPTS, 40, 10, 0, blocks.clone()));
    assert_eq!(laid.rows[0].block, Some(0));
    assert_eq!(laid.rows[0].height, 32.0);
    // The text rows are lower by the block's 32 pixels.
    let bare = frame(&mut layout, view(EXCERPTS, 40, 10, 0, vec![]));
    let tops = |rows: &[FrameRow]| -> Vec<f32> {
        rows.iter()
            .filter(|row| row.block.is_none())
            .map(|row| row.y)
            .collect()
    };
    let lowered: Vec<f32> = tops(&bare.rows).iter().map(|y| y + 32.0).collect();
    assert_eq!(tops(&laid.rows), lowered);
    // A view 48 pixels tall holds the block and `two`, and not the
    // separator: the frame and the queries agree.
    let short = frame(&mut layout, view(EXCERPTS, 40, 3, 0, blocks.clone()));
    assert_eq!(
        described(&short.rows),
        vec![(Some(0), 0.0, (0, 7)), (None, 32.0, (0, 3))]
    );
    let text = text_of(EXCERPTS);
    let asked = layout
        .rows_shown_with_blocks(
            &text,
            400.0,
            48.0,
            Padding::default(),
            0,
            Around {
                blocks: &blocks,
                folds: &[],
            },
        )
        .unwrap();
    assert_eq!(asked, vec![RowRange { start: 0, stop: 3 }]);
    let spot = |layout: &mut Layout<CellShaper>, position: usize| {
        layout
            .spot_with_blocks(
                &text,
                400.0,
                48.0,
                Padding::default(),
                0,
                position,
                Around {
                    blocks: &blocks,
                    folds: &[],
                },
            )
            .unwrap()
    };
    let two = spot(&mut layout, 1).unwrap();
    assert_eq!((two.y, two.height), (32.0, 16.0));
    assert_eq!(spot(&mut layout, 4), None);
}

#[test]
fn a_move_goes_over_a_block() {
    let text = text_of(EXCERPTS);
    let mut layout = layout();
    // Blocks do not reach a move: one line up from `alpha` is the
    // separator row.
    frame(&mut layout, view(EXCERPTS, 40, 10, 0, headers()));
    let moved = layout.lines_from(&text, 400.0, 0, 5, -1, None).unwrap();
    assert_eq!(moved.position, 4);
}

#[test]
fn a_blocks_before_that_is_not_a_boundary_is_moved_back() {
    let mut layout = layout();
    // 1 is inside `é`, so the block is before row 0; 99 is past the end,
    // so it is before the last row.
    let blocks = vec![header(1, "a"), header(99, "b")];
    let laid = frame(&mut layout, view("é\nab", 40, 10, 0, blocks));
    assert_eq!(
        described(&laid.rows),
        vec![
            (Some(0), 0.0, (0, 1)),
            (None, 16.0, (0, 2)),
            (Some(1), 32.0, (0, 1)),
            (None, 48.0, (3, 5)),
        ]
    );
}

#[test]
fn a_view_with_no_blocks_lays_out_as_before() {
    let mut layout = layout();
    let laid = frame(&mut layout, view(EXCERPTS, 40, 10, 0, vec![]));
    assert!(laid.rows.iter().all(|row| row.block.is_none()));
    assert_eq!(
        text_rows(&laid.rows),
        vec![(0, 3), (4, 4), (5, 10), (11, 11)]
    );
}
