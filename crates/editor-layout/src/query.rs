//! The three layout queries the editor asks in the same call: the rows a
//! view shows from its scroll anchor, the position some visual lines away
//! from a position, and where a position is drawn in a view (its spot).
//! Each lays out on demand whatever it reaches.
//!
//! They answer by layout's rules ([`line`](mod@crate::line)): a position at
//! a wrap is the start of the later visual line, only a row's last visual
//! line holds the row's end, and the position between a carriage return
//! and its line feed is the row's end. A move aims for an x (Vim's
//! "curswant"): the glyph the x is in, or past a line's last glyph its end
//! on the line that holds the row's end and its last glyph on any other.
//!
//! # The rows that fit
//!
//! A view shows the visual lines from its anchor that fit its height
//! whole, and a frame is built from the same walk
//! ([`frame`](crate::frame)). **In that count a line is at least one
//! pixel tall** ([`LEAST_ROW_HEIGHT`]), whatever height the shaper gave
//! it, so a view lays out at most one line for each pixel of its height.
//! A height that is no number holds no line.
//!
//! The rule is layout's own, because the cost it bounds is: a frame or a
//! query costs what its view shows, never the length of the text. Without
//! it, lines of no height all fit, and every frame would lay out the text
//! from the anchor to its end. Lines have no height in a font of size 0
//! or of a line height of 0, which a face may set and the wire carries
//! (the default face, or the face of a decoration or of the selection
//! once the walk reaches its rows), and wherever a shaper says so: the
//! shaper's contract holds only the default font's lines to a height. A
//! line a 64th of a pixel tall is the same case, which is why the rule
//! is a least height and not a refusal of 0.
//!
//! Only the count changes. A line keeps the height the shaper gave it: in
//! a frame a row of no height is that tall and the row after it starts
//! where it does, so each such row a view holds leaves a pixel less for
//! the rows after it.
//!
//! The move counts visual lines, not pixels, so no height changes what it
//! reaches or what it costs: as many steps as the lines asked for, fewer
//! at an end of the text.
//!
//! # Blocks
//!
//! A view's blocks ([`Block`](crate::scene::Block)) are rows of text of
//! their own between the rows of its text, laid out as a small text of
//! their own at the view's text width, in their own faces. They are
//! placed by this rule, which the rows query, the spot and the frame all
//! walk by, so the three agree:
//!
//! - A block is drawn above the first visual line (segment 0, line 0) of
//!   the buffer row that holds its `before`. A `before` that is not a
//!   character boundary is moved back to the one before it, and one past
//!   the end is the text's end. Several blocks before one row are drawn
//!   in the order the view lists them.
//! - Each block line counts like a text line among the lines that fit a
//!   height: its own height, and at least [`LEAST_ROW_HEIGHT`].
//! - A row's blocks are shown with the line below them or not at all:
//!   the walk ends before blocks whose line does not fit with them.
//! - The first line shown is the anchor's. Its blocks are shown above it
//!   only when they fit with it, and otherwise left out, so a view at
//!   least one line tall always shows its anchor's line. An anchor on a
//!   wrapped continuation line has no blocks above it.
//! - The rows query answers text rows only, and a spot below a block is
//!   lower by the block's lines, each at the height it is drawn at.
//! - **A block holds no position.** A position is located, and a move
//!   goes, as without blocks: the move query takes none, and counts the
//!   visual lines of the text alone.
//!
//! A refusal is [`QueryError::BadPosition`] for an offset that is not a
//! position of the text. An unknown snapshot is the binding's refusal:
//! layout is handed a snapshot or nothing.

use std::ops::Range;
use std::sync::Arc;

use editor_text::Snapshot;

use crate::line::LineEntry;
use crate::shaper::{FontId, Shaper};
use crate::tabs::{row_content, segment_of, segment_range};
use crate::wrap::{Outcome, WrapLayer};

/// The least a visual line counts for among the rows that fit a height, in
/// pixels, whatever height the shaper gave it (the module docs, "The rows
/// that fit").
pub const LEAST_ROW_HEIGHT: f32 = 1.0;

/// One visual row: the bytes from `start` up to `stop`, without its line
/// break.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RowRange {
    /// The byte offset of its first character.
    pub start: usize,
    /// The byte offset where its characters stop.
    pub stop: usize,
}

/// Where a move went.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Moved {
    /// The position it reached.
    pub position: usize,
    /// The x it aimed for, to pass to the next move.
    pub goal: f32,
}

/// Where a position is drawn in a view, in pixels from the view's own top
/// left, its padding included ([`Layout::spot`](crate::Layout::spot)).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Spot {
    /// From the view's left edge to the position's left.
    pub x: f32,
    /// From the view's top edge to the top of the row that holds it.
    pub y: f32,
    /// How tall that row is.
    pub height: f32,
}

/// Why a query was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QueryError {
    /// An offset is not a position of the text.
    BadPosition,
}

/// A visual line of a text: a row, a segment of it, a line of that.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct Visual {
    /// The buffer row.
    pub row: usize,
    /// The segment of the row.
    pub segment: usize,
    /// The visual line of the segment.
    pub line: usize,
}

/// A line a view shows: a visual line of its text, or a line of one of
/// its blocks (module docs, "Blocks").
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum Shown {
    /// The `line`th visual line of the view's `block`th block, `height`
    /// pixels tall as it is drawn.
    Block {
        /// Which block, by its index among the view's.
        block: usize,
        /// Which of its visual lines.
        line: usize,
        /// How tall it is drawn.
        height: f32,
    },
    /// A visual line of the view's text.
    Text(Visual),
}

impl Shown {
    /// What a block line counts for among the lines that fit a height:
    /// its height, and at least [`LEAST_ROW_HEIGHT`]. A text line is
    /// counted by the walk, which knows its height.
    fn counted(&self) -> f32 {
        match self {
            Self::Block { height, .. } => height.max(LEAST_ROW_HEIGHT),
            Self::Text(_) => 0.0,
        }
    }
}

/// Walks the visual lines of one text, laying out each segment it reaches
/// in a wrap layer, and reports how it got each one.
pub(crate) struct Walker<'a, S: Shaper> {
    /// The shaper.
    pub shaper: &'a S,
    /// The text's wrap layer.
    pub wrap: &'a mut WrapLayer<S::Shaped>,
    /// The base font: the font of every byte `fonts` gives no span for.
    pub base: FontId,
    /// The spans of a segment's bytes (absolute) in a font other than the
    /// base, by absolute bytes, later over earlier; asked only for the
    /// segments the walker lays out.
    pub fonts: &'a dyn Fn(Range<usize>) -> Vec<(Range<usize>, FontId)>,
    /// The align-to stops of a segment's bytes (absolute), each as an
    /// offset relative to the segment's start and an x in pixels, in
    /// order ([`relative_stops`]); asked only for the segments the walker
    /// lays out.
    pub stops: &'a dyn Fn(Range<usize>) -> Vec<(usize, f32)>,
    /// Told how each segment was got, by row and segment.
    pub outcome: &'a mut dyn FnMut(usize, usize, Outcome),
}

impl<S: Shaper> Walker<'_, S> {
    /// The text.
    pub fn snapshot(&self) -> Snapshot {
        self.wrap.tabs().buffer().clone()
    }

    /// `row`'s `segment`, laid out.
    pub fn entry(&mut self, row: usize, segment: usize) -> Option<Arc<LineEntry<S::Shaped>>> {
        let (fonts, stops) = {
            let snapshot = self.wrap.tabs().buffer();
            let content = row_content(snapshot, row)?;
            let bytes = segment_range(snapshot, &content, segment)?;
            let spans = (self.fonts)(bytes.clone());
            (relative_spans(&spans, &bytes), (self.stops)(bytes))
        };
        let (entry, outcome) =
            self.wrap
                .entry(self.shaper, row, segment, &fonts, self.base, &stops)?;
        (self.outcome)(row, segment, outcome);
        Some(entry)
    }

    /// Where `row` starts.
    fn row_start(&self, row: usize) -> usize {
        self.wrap
            .tabs()
            .buffer()
            .row_range(row)
            .map_or(0, |range| range.start)
    }

    /// The visual line that holds the position `offset`, and the x of it.
    pub fn locate(&mut self, offset: usize) -> Result<(Visual, f32), QueryError> {
        let snapshot = self.snapshot();
        if offset > snapshot.len() || !snapshot.is_char_boundary(offset) {
            return Err(QueryError::BadPosition);
        }
        let row = snapshot
            .offset_to_point(offset)
            .ok_or(QueryError::BadPosition)?
            .row;
        let content = row_content(&snapshot, row).ok_or(QueryError::BadPosition)?;
        let segment = segment_of(&snapshot, &content, offset);
        let entry = self.entry(row, segment).ok_or(QueryError::BadPosition)?;
        let relative = offset - content.start;
        let line = entry.line_of(relative);
        Ok((Visual { row, segment, line }, entry.x_of(line, relative)))
    }

    /// The visual line after `visual`, if there is one.
    pub fn next(&mut self, visual: Visual) -> Option<Visual> {
        let entry = self.entry(visual.row, visual.segment)?;
        if visual.line + 1 < entry.lines().len() {
            return Some(Visual {
                line: visual.line + 1,
                ..visual
            });
        }
        if visual.segment + 1 < self.wrap.segments(visual.row)? {
            return Some(Visual {
                segment: visual.segment + 1,
                line: 0,
                ..visual
            });
        }
        (visual.row + 1 < self.wrap.tabs().buffer().row_count()).then_some(Visual {
            row: visual.row + 1,
            segment: 0,
            line: 0,
        })
    }

    /// The visual line before `visual`, if there is one.
    pub fn previous(&mut self, visual: Visual) -> Option<Visual> {
        if visual.line > 0 {
            return Some(Visual {
                line: visual.line - 1,
                ..visual
            });
        }
        let (row, segment) = if visual.segment > 0 {
            (visual.row, visual.segment - 1)
        } else if visual.row > 0 {
            (visual.row - 1, self.wrap.segments(visual.row - 1)? - 1)
        } else {
            return None;
        };
        let lines = self.entry(row, segment)?.lines().len();
        Some(Visual {
            row,
            segment,
            line: lines - 1,
        })
    }

    /// The bytes of `visual`, without its line break.
    pub fn range(&mut self, visual: Visual) -> RowRange {
        let start = self.row_start(visual.row);
        let bytes = self
            .entry(visual.row, visual.segment)
            .and_then(|entry| entry.line_bytes(visual.line))
            .unwrap_or(0..0);
        RowRange {
            start: start + bytes.start,
            stop: start + bytes.end,
        }
    }

    /// How tall `visual` is.
    pub fn height(&mut self, visual: Visual) -> f32 {
        self.entry(visual.row, visual.segment)
            .and_then(|entry| entry.lines().get(visual.line).map(|line| line.height))
            .unwrap_or(0.0)
    }

    /// The visual lines from the one that holds `anchor` and the block
    /// lines above them, as many as fit `height` pixels whole, fewer at
    /// the end of the text, top to bottom (module docs, "Blocks").
    /// `above` gives the lines of the blocks before a buffer row, in
    /// order, and is asked only for the rows the walk reaches the first
    /// line of. Each line counts as at least [`LEAST_ROW_HEIGHT`].
    pub fn shown(
        &mut self,
        height: f32,
        anchor: usize,
        above: &mut dyn FnMut(usize) -> Vec<Shown>,
    ) -> Result<Vec<Shown>, QueryError> {
        let (mut visual, _) = self.locate(anchor)?;
        let mut shown = Vec::new();
        let mut used = 0.0;
        let mut first = true;
        loop {
            let mut blocks = if visual.segment == 0 && visual.line == 0 {
                above(visual.row)
            } else {
                Vec::new()
            };
            // `max` gives the least height for a height that is no number.
            let tall = self.height(visual).max(LEAST_ROW_HEIGHT);
            let blocks_tall: f32 = blocks.iter().map(Shown::counted).sum();
            // False when either side is no number, which stops the walk.
            let fits = used + blocks_tall + tall <= height;
            if !fits {
                // The first line is shown alone when its blocks do not
                // fit with it; any later one is shown with its blocks or
                // not at all.
                if first && tall <= height {
                    blocks.clear();
                } else {
                    break;
                }
            }
            first = false;
            used += blocks.iter().map(Shown::counted).sum::<f32>() + tall;
            shown.extend(blocks);
            shown.push(Shown::Text(visual));
            // A view filled exactly lays out no row past it.
            if used >= height {
                break;
            }
            match self.next(visual) {
                Some(next) => visual = next,
                None => break,
            }
        }
        Ok(shown)
    }

    /// Where `position` is among the visual lines from the one that holds
    /// `anchor` that fit `height` pixels whole, with the block lines
    /// `above` gives ([`Walker::shown`]): the x of it in its line, the y of
    /// its line's top below the first line shown, each line, a block's
    /// included, counted at the height it is drawn at, and its line's
    /// height. None when the rows shown do not hold it.
    pub fn spot(
        &mut self,
        height: f32,
        anchor: usize,
        position: usize,
        above: &mut dyn FnMut(usize) -> Vec<Shown>,
    ) -> Result<Option<Spot>, QueryError> {
        let (target, x) = self.locate(position)?;
        let mut y = 0.0;
        for shown in self.shown(height, anchor, above)? {
            let tall = match shown {
                Shown::Text(visual) => {
                    let tall = self.height(visual);
                    if visual == target {
                        return Ok(Some(Spot { x, y, height: tall }));
                    }
                    tall
                }
                Shown::Block { height, .. } => height,
            };
            y += tall;
        }
        Ok(None)
    }

    /// The position `lines` visual lines from `position`, aiming for
    /// `goal`, or for the position's own x when there is none.
    pub fn lines_from(
        &mut self,
        position: usize,
        lines: i64,
        goal: Option<f32>,
    ) -> Result<Moved, QueryError> {
        let (mut visual, x) = self.locate(position)?;
        let goal = goal.unwrap_or(x);
        for _ in 0..lines.unsigned_abs() {
            let step = if lines > 0 {
                self.next(visual)
            } else {
                self.previous(visual)
            };
            match step {
                Some(next) => visual = next,
                None => break,
            }
        }
        let entry = self
            .entry(visual.row, visual.segment)
            .ok_or(QueryError::BadPosition)?;
        Ok(Moved {
            position: self.row_start(visual.row) + entry.offset_at(visual.line, goal),
            goal,
        })
    }
}

/// The stops of `stops` (absolute byte offsets, in order, with their xs)
/// in `bytes`, a segment, made relative to its start: each with a
/// character of the segment after it. A stop at the segment's end is the
/// next segment's, or does nothing.
pub(crate) fn relative_stops(stops: &[(usize, f32)], bytes: &Range<usize>) -> Vec<(usize, f32)> {
    let first = stops.partition_point(|(offset, _)| *offset < bytes.start);
    stops[first..]
        .iter()
        .take_while(|(offset, _)| *offset < bytes.end)
        .map(|(offset, x)| (offset - bytes.start, *x))
        .collect()
}

/// The spans of `fonts` (absolute bytes) that touch `bytes`, clipped to it
/// and made relative to its start. On an empty range, a span that starts
/// there.
pub(crate) fn relative_spans(
    fonts: &[(Range<usize>, FontId)],
    bytes: &Range<usize>,
) -> Vec<(Range<usize>, FontId)> {
    fonts
        .iter()
        .filter(|(span, _)| {
            (span.start < bytes.end && bytes.start < span.end)
                || (bytes.is_empty() && span.start == bytes.start)
        })
        .map(|(span, font)| {
            let start = span.start.max(bytes.start) - bytes.start;
            let end = span.end.min(bytes.end).max(span.start.max(bytes.start)) - bytes.start;
            (start..end, *font)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use editor_text::Text;

    use super::{Moved, QueryError, RowRange};
    use crate::Layout;
    use crate::scene::{Padding, TextKey, TextRef};
    use crate::shaper::fake::CellShaper;
    use crate::shaper::scripted::{ScriptedShaper, glyph, line};
    use crate::tabs::SEGMENT_BYTES;

    /// A layout on cells 10 by 16.
    fn layout() -> Layout<CellShaper> {
        Layout::new(CellShaper::new(10.0, 16.0))
    }

    /// The rows of `text` a view `columns` cells wide and `rows` tall shows
    /// from `anchor`, as pairs.
    fn rows(text: &str, columns: u32, rows: u32, anchor: usize) -> Vec<(usize, usize)> {
        let snapshot = TextRef::fixed(TextKey(1), Text::from(text).snapshot());
        layout()
            .rows_shown(
                &snapshot,
                columns as f32 * 10.0,
                rows as f32 * 16.0,
                Padding::default(),
                anchor,
            )
            .unwrap()
            .into_iter()
            .map(|RowRange { start, stop }| (start, stop))
            .collect()
    }

    /// Where `position` of `text` goes `lines` down in a view `columns`
    /// wide, aiming for `goal`.
    fn moved(text: &str, columns: u32, position: usize, lines: i64, goal: Option<f32>) -> Moved {
        let snapshot = TextRef::fixed(TextKey(1), Text::from(text).snapshot());
        layout()
            .lines_from(&snapshot, columns as f32 * 10.0, 0, position, lines, goal)
            .unwrap()
    }

    /// Just the position of [`moved`].
    fn to(text: &str, columns: u32, position: usize, lines: i64) -> usize {
        moved(text, columns, position, lines, None).position
    }

    #[test]
    fn a_view_shows_the_rows_that_fit_from_its_anchor() {
        assert_eq!(
            rows("ab\ncd\nef\ngh", 4, 3, 3),
            vec![(3, 5), (6, 8), (9, 11)]
        );
        assert_eq!(rows("ab\ncd", 4, 10, 0), vec![(0, 2), (3, 5)]);
        // A view shorter than a row shows none.
        let snapshot = TextRef::fixed(TextKey(1), Text::from("ab").snapshot());
        assert_eq!(
            layout().rows_shown(&snapshot, 40.0, 15.0, Padding::default(), 0),
            Ok(vec![])
        );
    }

    #[test]
    fn a_view_shows_at_most_a_row_for_each_pixel_of_its_height() {
        let snapshot = TextRef::fixed(
            TextKey(1),
            Text::from("a\n".repeat(500).as_str()).snapshot(),
        );
        // Lines a quarter of a pixel tall, of no height, of less than
        // none, and of a height that is no number: each counts as one
        // pixel, so 20 pixels hold 20 of them and not the 501 of the text.
        for line_height in [0.25, 0.0, -16.0, f32::NAN] {
            let mut layout = Layout::new(CellShaper::new(10.0, line_height));
            let shown = layout
                .rows_shown(&snapshot, 40.0, 20.0, Padding::default(), 0)
                .unwrap();
            assert_eq!(shown.len(), 20, "lines {line_height} tall");
            assert_eq!(
                shown.last(),
                Some(&RowRange {
                    start: 38,
                    stop: 39
                }),
                "lines {line_height} tall"
            );
            // A part of a pixel holds no row.
            assert_eq!(
                layout.rows_shown(&snapshot, 40.0, 0.5, Padding::default(), 0),
                Ok(vec![])
            );
        }
        // A height that is no number holds no row.
        let shown = layout().rows_shown(&snapshot, 40.0, f32::NAN, Padding::default(), 0);
        assert_eq!(shown.map(|rows| rows.len()), Ok(0));
    }

    #[test]
    fn a_wrapped_line_is_a_row_per_visual_line_and_an_anchor_starts_its_row() {
        assert_eq!(rows("abcdefgh\nij", 4, 3, 0), vec![(0, 4), (4, 8), (9, 11)]);
        assert_eq!(rows("abcdefgh\nij", 4, 2, 6), vec![(4, 8), (9, 11)]);
        // A position at a wrap is the start of the later row.
        assert_eq!(rows("abcdefgh\nij", 4, 1, 4), vec![(4, 8)]);
    }

    #[test]
    fn an_empty_text_and_a_trailing_line_feed_are_an_empty_row() {
        assert_eq!(rows("", 4, 3, 0), vec![(0, 0)]);
        assert_eq!(rows("ab\n", 4, 3, 0), vec![(0, 2), (3, 3)]);
    }

    #[test]
    fn rows_are_byte_ranges_and_a_line_break_with_a_return_is_left_out() {
        assert_eq!(rows("é😀ab", 2, 3, 2), vec![(0, 6), (6, 8)]);
        assert_eq!(rows("ab\r\ncd", 4, 3, 0), vec![(0, 2), (4, 6)]);
        // The position between the return and the line feed is the row's
        // end, on its row.
        assert_eq!(rows("ab\r\ncd", 4, 1, 3), vec![(0, 2)]);
    }

    #[test]
    fn a_move_lands_on_the_character_under_its_goal_in_a_reordered_line() {
        // Three rows. The second is drawn right to left, z leftmost; the
        // third has `fi` as one glyph 20 across. The first and the last
        // row are the fake's.
        let reversed = vec![
            glyph('z', 3, 0.0, 10.0),
            glyph('y', 2, 10.0, 10.0),
            glyph('x', 1, 20.0, 10.0),
            glyph('w', 0, 30.0, 10.0),
        ];
        let ligature = vec![
            glyph('a', 0, 0.0, 10.0),
            glyph('f', 1, 10.0, 20.0),
            glyph('b', 3, 30.0, 10.0),
        ];
        let shaper = ScriptedShaper::new(10.0, 16.0)
            .with("wxyz", vec![line(0..4, reversed)])
            .with("afib", vec![line(0..4, ligature)]);
        let mut layout = Layout::new(shaper);
        let text = TextRef::fixed(TextKey(1), Text::from("abcd\nwxyz\nafib\nabcd").snapshot());
        let mut moved = |position: usize, lines: i64| {
            let moved = layout.lines_from(&text, 400.0, 0, position, lines, None);
            let Moved { position, goal } = moved.unwrap();
            (position, goal)
        };
        // Down from `b`, at x 10: the character drawn there is `y`, the
        // third of its row.
        assert_eq!(moved(1, 1), (7, 10.0));
        // The goal of a move from a reordered line is the x its character
        // is drawn at: `x`, the second of its row, is at 20, over `c`.
        assert_eq!(moved(6, -1), (2, 20.0));
        // And down from it, x 20 is the second half of the ligature: `i`.
        assert_eq!(moved(6, 1), (12, 20.0));
        // From `i`, at the middle of its glyph, to the row below and back.
        assert_eq!(moved(12, 1), (17, 20.0));
        assert_eq!(moved(17, -1), (12, 20.0));
        // From the first half, `f`.
        assert_eq!(moved(16, -1), (11, 10.0));
    }

    #[test]
    fn a_move_keeps_the_x_it_aimed_for_across_a_shorter_line() {
        let text = "abcdef\nab\nabcdefghij\nxyz";
        // From d (x 30) down: "ab" ends at x 20, so the move stops at its
        // end, and the goal 30 is passed back.
        assert_eq!(
            moved(text, 10, 3, 1, None),
            Moved {
                position: 9,
                goal: 30.0
            }
        );
        assert_eq!(moved(text, 10, 9, 1, Some(30.0)).position, 13);
        assert_eq!(to(text, 10, 3, 2), 13);
    }

    #[test]
    fn a_move_counts_visual_lines_of_wrapped_rows() {
        let text = "abcdef\nab\nabcdefghij\nxyz";
        // At width 4: abcd | ef | ab | abcd | efgh | ij | xyz.
        assert_eq!(to(text, 4, 1, 1), 5);
        // On a line that does not hold its row's end, the last glyph.
        assert_eq!(moved(text, 4, 6, -1, Some(100.0)).position, 3);
        // From b of "ab" (x 10) three lines down is j of "ij", and back.
        assert_eq!(to(text, 4, 8, 3), 19);
        assert_eq!(to(text, 4, 19, -3), 8);
    }

    #[test]
    fn a_move_crosses_a_segment_boundary_inside_a_long_row() {
        // One row of two segments. `SEGMENT_BYTES` is a multiple of 8, so
        // at 8 columns the first segment is whole lines of 8: its last
        // visual line starts 8 before the cut, and the second segment's
        // first starts at the cut.
        let text = "a".repeat(SEGMENT_BYTES + 64);
        let cut = SEGMENT_BYTES;
        // One line up from the first visual line of the second segment is
        // the same column of the last line of the first, and one line down
        // from there is back.
        assert_eq!(to(&text, 8, cut + 3, -1), cut - 5);
        assert_eq!(to(&text, 8, cut - 5, 1), cut + 3);
        // The cut is the start of the later segment's first line.
        assert_eq!(to(&text, 8, cut, -1), cut - 8);
        assert_eq!(to(&text, 8, cut - 8, 1), cut);
        // From the third line before the cut, n lines down and n back up
        // return to the start; from three lines on they cross the cut.
        let start = cut - 19;
        for n in 1..=6_usize {
            let lines = i64::try_from(n).unwrap();
            let down = to(&text, 8, start, lines);
            assert_eq!(down, start + 8 * n, "{n} lines down");
            assert_eq!(to(&text, 8, down, -lines), start, "{n} lines back up");
        }
    }

    #[test]
    fn a_tab_wider_than_the_view_leaves_no_row_a_move_cannot_reach() {
        // Tabs are 8 columns wide: "abc" and the tab's first space fill
        // the first row, and its other four spaces are no row.
        let text = "abc\tdef\nzz";
        assert_eq!(rows(text, 4, 4, 0), vec![(0, 4), (4, 7), (8, 10)]);
        assert_eq!(to(text, 4, 0, 1), 4);
        assert_eq!(rows(text, 4, 1, 4), vec![(4, 7)]);
        assert_eq!(to(text, 4, 4, -1), 0);
    }

    #[test]
    fn a_move_past_the_first_or_the_last_line_stops_there() {
        let text = "abcdef\nab\nabcdefghij\nxyz";
        assert_eq!(to(text, 4, 9, -5), 2);
        assert_eq!(to(text, 4, 1, -1), 1);
        assert_eq!(to(text, 4, 12, 9), 23);
        assert_eq!(to(text, 4, 22, 1), 22);
        assert_eq!(to(text, 4, 15, 0), 15);
    }

    #[test]
    fn a_move_from_between_a_return_and_its_line_feed_is_from_the_rows_end() {
        assert_eq!(
            moved("abc\r\nabcdef", 10, 4, 1, None),
            Moved {
                position: 8,
                goal: 30.0
            }
        );
    }

    #[test]
    fn an_offset_that_is_not_a_position_is_refused() {
        let snapshot = TextRef::fixed(TextKey(1), Text::from("é\nab").snapshot());
        let mut layout = layout();
        assert_eq!(
            layout.rows_shown(&snapshot, 40.0, 16.0, Padding::default(), 1),
            Err(QueryError::BadPosition)
        );
        assert_eq!(
            layout.rows_shown(&snapshot, 40.0, 16.0, Padding::default(), 6),
            Err(QueryError::BadPosition)
        );
        assert_eq!(
            layout.lines_from(&snapshot, 40.0, 0, 1, 1, None),
            Err(QueryError::BadPosition)
        );
    }
}
