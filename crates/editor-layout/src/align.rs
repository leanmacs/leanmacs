//! The column arithmetic of align-to stops: where the cells of a row cut
//! at its stops are placed, and where the row breaks.
//!
//! A row with align-to stops ([`AlignStop`]) is
//! cut at each stop's column into **cells**: cell 0 is the text before the
//! first stop, possibly empty, and each later cell starts at its stop's
//! first character and runs to the next stop or the segment's end. Each
//! cell is shaped and broken on its own through the `Shaper` port
//! ([`line`](mod@crate::line)), and [`place`] puts the pieces on visual
//! lines by these rules, all in pixels from the start of the text row:
//!
//! - Cell 0 is at x 0, broken at the width, as a row with no stop is.
//! - A later cell whose stop is at or past the width, on a visual line
//!   that already holds something, starts the next visual line at x 0 and
//!   is broken at the whole width: the row breaks before the stop's cell
//!   (the overflow rule). A stop at the very start of a row is never
//!   broken before, so no empty visual line is made.
//! - Otherwise the cell starts at its stop, or where the line's content
//!   ends when that is further right: cells never overlap, and a cell
//!   that runs past the next stop pushes the next cell right. A cell
//!   pushed to or past the width is broken before as above.
//! - Otherwise the cell is broken at the room right of where it starts.
//!   Its first visual line goes on the current line there, and its later
//!   visual lines hang under it, each at the same x, so a long cell stays
//!   in its column.
//! - The gap before a cell on the line it follows belongs to the
//!   character before it, as a tab's spaces belong to the tab: the last
//!   glyph before the stop gets the advance that reaches it, so a cursor
//!   on that character spans the gap and an x in the gap aims for it.
//! - A visual line made of several pieces sits on the lowest of their
//!   baselines, and is as tall as that baseline plus the most any piece
//!   reaches below its own. Its glyphs keep their offsets from the
//!   baseline.
//! - With no width nothing breaks: every cell is on one line, at its stop
//!   or after the cell before it.
//!
//! A composed visual line holds its pieces' bytes, one after another, as
//! columns of the segment's expanded text; its glyphs' clusters are
//! columns of it too, and their `x` is from the line's left edge.

use std::ops::Range;

use editor_text::Snapshot;

use crate::scene::AlignStop;
use crate::shaper::{Glyph, VisualLine};
use crate::tabs::boundary_at_or_before;

/// `stops`, a view's, resolved for `snapshot`: each moved back to a
/// character boundary (past the end, to the end), in the order of their
/// offsets, and of two at one offset the later listed, each with its x in
/// points.
pub(crate) fn resolved(snapshot: &Snapshot, stops: &[AlignStop]) -> Vec<(usize, u32)> {
    let mut resolved: Vec<(usize, u32)> = stops
        .iter()
        .map(|stop| (boundary_at_or_before(snapshot, stop.offset), stop.x))
        .collect();
    // A stable sort keeps the order they were listed in at one offset.
    resolved.sort_by_key(|(offset, _)| *offset);
    let mut kept: Vec<(usize, u32)> = Vec::with_capacity(resolved.len());
    for stop in resolved {
        match kept.last_mut() {
            Some(last) if last.0 == stop.0 => *last = stop,
            _ => kept.push(stop),
        }
    }
    kept
}

/// One cell of a row cut at its stops.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Cut {
    /// Its columns of the segment's expanded text.
    pub columns: Range<usize>,
    /// The x of its stop, in pixels from the start of the text row; none
    /// for cell 0, the text before the first stop.
    pub stop: Option<f32>,
}

/// A visual line being put together from the pieces of cells.
struct Composing {
    /// The columns it holds so far.
    bytes: Range<usize>,
    /// Its glyphs, from its left edge.
    glyphs: Vec<Glyph>,
    /// Where its content ends: the pen for what comes next.
    pen: f32,
    /// The lowest baseline of its pieces, from its top.
    baseline: f32,
    /// The most any piece reaches below its own baseline.
    depth: f32,
}

impl Composing {
    /// Whether it holds a character.
    fn holds(&self) -> bool {
        !self.bytes.is_empty() || !self.glyphs.is_empty()
    }

    /// The visual line it makes.
    fn finish(self) -> VisualLine {
        VisualLine {
            bytes: self.bytes,
            glyphs: self.glyphs,
            width: self.pen,
            height: self.baseline + self.depth,
            baseline: self.baseline,
        }
    }

    /// Adds `piece`, a visual line of the cell whose columns start at
    /// `base`, at `x`.
    fn add(&mut self, piece: &VisualLine, base: usize, x: f32) {
        self.bytes.end = base + piece.bytes.end;
        self.glyphs.extend(piece.glyphs.iter().map(|glyph| Glyph {
            x: glyph.x + x,
            cluster: glyph.cluster + base,
            ..*glyph
        }));
        self.pen = x + piece.width;
        self.baseline = self.baseline.max(piece.baseline);
        self.depth = self.depth.max(piece.height - piece.baseline);
    }

    /// A line that starts at `piece`, a visual line of the cell whose
    /// columns start at `base`, placed at `x`.
    fn of(piece: &VisualLine, base: usize, x: f32) -> Self {
        let start = base + piece.bytes.start;
        let mut line = Self {
            bytes: start..start,
            glyphs: Vec::new(),
            pen: x,
            baseline: piece.baseline,
            depth: piece.height - piece.baseline,
        };
        line.add(piece, base, x);
        line
    }
}

/// The visual lines of a row cut into `cuts`, by the module's rules, at
/// `width` (`None` breaks nothing). `break_cell` is asked for the visual
/// lines of cell `index` broken at a width (`None` for none), each with
/// its bytes relative to the cell's first column and its glyphs from its
/// own left edge; it is asked once for each cell that holds a column, in
/// order. A cell of no column is passed over.
pub(crate) fn place(
    cuts: &[Cut],
    width: Option<f32>,
    mut break_cell: impl FnMut(usize, Option<f32>) -> Vec<VisualLine>,
) -> Vec<VisualLine> {
    let mut lines: Vec<VisualLine> = Vec::new();
    let mut current: Option<Composing> = None;
    for (index, cut) in cuts.iter().enumerate() {
        if cut.columns.is_empty() {
            continue;
        }
        let pen = current.as_ref().map_or(0.0, |line| line.pen);
        let holds = current.as_ref().is_some_and(Composing::holds);
        let (start, room) = match cut.stop {
            None => (pen, width.map(|width| width - pen)),
            Some(stop) => {
                let start = stop.max(pen);
                let over = width.is_some_and(|width| stop >= width || start >= width);
                if over {
                    if holds && let Some(line) = current.take() {
                        lines.push(line.finish());
                    }
                    (0.0, width)
                } else {
                    // The gap goes to the last glyph before the stop.
                    if let Some(line) = current.as_mut()
                        && start > line.pen
                    {
                        if let Some(last) = line.glyphs.last_mut() {
                            last.advance += start - line.pen;
                        }
                        line.pen = start;
                    }
                    (start, width.map(|width| width - start))
                }
            }
        };
        let base = cut.columns.start;
        for (piece_index, piece) in break_cell(index, room).iter().enumerate() {
            match current.as_mut() {
                Some(line) if piece_index == 0 => line.add(piece, base, start),
                _ => {
                    if let Some(line) = current.take() {
                        lines.push(line.finish());
                    }
                    current = Some(Composing::of(piece, base, start));
                }
            }
        }
    }
    lines.extend(current.map(Composing::finish));
    lines
}

#[cfg(test)]
mod tests {
    use std::ops::Range;

    use editor_text::Text;

    use super::{Cut, place, resolved};
    use crate::scene::AlignStop;
    use crate::shaper::{Glyph, ResolvedFontId, VisualLine};

    #[test]
    fn a_views_stops_are_moved_to_a_boundary_ordered_and_the_later_of_two_wins() {
        // `é` is bytes 1 and 2.
        let snapshot = Text::from("aéb").snapshot();
        let stop = |offset, x| AlignStop { offset, x };
        assert_eq!(
            resolved(
                &snapshot,
                &[stop(3, 30), stop(2, 20), stop(1, 10), stop(9, 90)]
            ),
            // 2 is inside `é`: moved back to 1, where the stop listed
            // after it is, which wins. 9 is past the end: the end.
            vec![(1, 10), (3, 30), (4, 90)]
        );
        assert_eq!(
            resolved(&snapshot, &[stop(1, 10), stop(2, 20)]),
            vec![(1, 20)]
        );
    }

    /// What a hand-written breaker knows of a cell: its text and the
    /// height and baseline of its lines.
    struct Cell {
        text: &'static str,
        height: f32,
        baseline: f32,
    }

    /// A cell of `text` in lines 16 tall on a baseline 12 down.
    fn cell(text: &'static str) -> Cell {
        Cell {
            text,
            height: 16.0,
            baseline: 12.0,
        }
    }

    /// The visual lines of `cell` broken greedily at `room`, every
    /// character 10 pixels across, at least one to a line.
    fn broken(cell: &Cell, room: Option<f32>) -> Vec<VisualLine> {
        let line = |chars: &[(usize, char)], end: usize| {
            let start = chars.first().map_or(end, |(offset, _)| *offset);
            let glyphs: Vec<Glyph> = chars
                .iter()
                .enumerate()
                .map(|(index, (offset, character))| Glyph {
                    id: u32::from(*character),
                    font: ResolvedFontId(0),
                    cluster: *offset,
                    x: index as f32 * 10.0,
                    dx: 0.0,
                    dy: 0.0,
                    advance: 10.0,
                })
                .collect();
            VisualLine {
                bytes: start..end,
                width: glyphs.len() as f32 * 10.0,
                glyphs,
                height: cell.height,
                baseline: cell.baseline,
            }
        };
        let chars: Vec<(usize, char)> = cell.text.char_indices().collect();
        let per_line = room.map_or(usize::MAX, |room| ((room / 10.0).floor() as usize).max(1));
        if chars.is_empty() {
            return vec![line(&[], 0)];
        }
        let pieces: Vec<&[(usize, char)]> = chars.chunks(per_line).collect();
        pieces
            .iter()
            .enumerate()
            .map(|(index, piece)| {
                let end = pieces
                    .get(index + 1)
                    .map_or(cell.text.len(), |next| next[0].0);
                line(piece, end)
            })
            .collect()
    }

    /// The visual lines of the row of `cells`, each but the first with the
    /// stop beside it, at `width`; and the rooms each cell was broken at.
    fn placed(
        cells: &[(Cell, Option<f32>)],
        width: Option<f32>,
    ) -> (Vec<VisualLine>, Vec<Option<f32>>) {
        let mut at = 0;
        let cuts: Vec<Cut> = cells
            .iter()
            .map(|(cell, stop)| {
                let columns = at..at + cell.text.len();
                at = columns.end;
                Cut {
                    columns,
                    stop: *stop,
                }
            })
            .collect();
        let mut rooms = Vec::new();
        let lines = place(&cuts, width, |index, room| {
            rooms.push(room);
            broken(&cells[index].0, room)
        });
        (lines, rooms)
    }

    /// The x of the glyph of each line that draws column `column`, with
    /// the line's index.
    fn glyph_at(lines: &[VisualLine], column: usize) -> (usize, f32) {
        lines
            .iter()
            .enumerate()
            .find_map(|(index, line)| {
                line.glyphs
                    .iter()
                    .find(|glyph| glyph.cluster == column)
                    .map(|glyph| (index, glyph.x))
            })
            .expect("a glyph of the column")
    }

    /// The columns each line holds.
    fn bytes(lines: &[VisualLine]) -> Vec<Range<usize>> {
        lines.iter().map(|line| line.bytes.clone()).collect()
    }

    /// The advance of the glyph of column `column`.
    fn advance(lines: &[VisualLine], column: usize) -> f32 {
        lines
            .iter()
            .flat_map(|line| &line.glyphs)
            .find(|glyph| glyph.cluster == column)
            .map(|glyph| glyph.advance)
            .expect("a glyph of the column")
    }

    #[test]
    fn a_cell_starts_at_its_stop() {
        let (lines, _) = placed(&[(cell("ab"), None), (cell("cd"), Some(50.0))], None);
        assert_eq!(bytes(&lines), vec![0..4]);
        // `c` is column 2 of the row, at the stop.
        assert_eq!(glyph_at(&lines, 2), (0, 50.0));
        assert_eq!(glyph_at(&lines, 3), (0, 60.0));
        assert_eq!(lines[0].width, 70.0);
    }

    #[test]
    fn cells_before_of_different_widths_give_the_next_cell_one_x() {
        for first in ["a", "abc", ""] {
            let (lines, _) = placed(&[(cell(first), None), (cell("x"), Some(40.0))], None);
            assert_eq!(glyph_at(&lines, first.len()), (0, 40.0), "after {first:?}");
        }
    }

    #[test]
    fn a_pen_past_the_stop_pushes_the_cell_to_the_pen() {
        let (lines, _) = placed(&[(cell("abcdef"), None), (cell("x"), Some(30.0))], None);
        assert_eq!(glyph_at(&lines, 6), (0, 60.0));
        // No gap: `f` keeps its own advance.
        assert_eq!(advance(&lines, 5), 10.0);
        // And the cell after it is pushed in turn.
        let cells = [
            (cell("abcdef"), None),
            (cell("xy"), Some(30.0)),
            (cell("z"), Some(70.0)),
        ];
        let (lines, _) = placed(&cells, None);
        assert_eq!(glyph_at(&lines, 8), (0, 80.0));
    }

    #[test]
    fn a_stop_at_or_past_the_width_breaks_before_its_cell_which_starts_at_x_0() {
        for stop in [50.0, 60.0] {
            let (lines, rooms) =
                placed(&[(cell("ab"), None), (cell("cd"), Some(stop))], Some(50.0));
            assert_eq!(bytes(&lines), vec![0..2, 2..4], "a stop at {stop}");
            assert_eq!(glyph_at(&lines, 2), (1, 0.0));
            // Broken at the whole width.
            assert_eq!(rooms, vec![Some(50.0), Some(50.0)]);
        }
        // The cells after it break before likewise.
        let cells = [
            (cell("ab"), None),
            (cell("cd"), Some(50.0)),
            (cell("ef"), Some(60.0)),
        ];
        let (lines, _) = placed(&cells, Some(50.0));
        assert_eq!(bytes(&lines), vec![0..2, 2..4, 4..6]);
        assert_eq!(glyph_at(&lines, 4), (2, 0.0));
    }

    #[test]
    fn a_cell_pushed_to_the_width_breaks_before_likewise() {
        // `abcde` ends at 50, the width: `x` cannot start on the line.
        let (lines, _) = placed(
            &[(cell("abcde"), None), (cell("x"), Some(20.0))],
            Some(50.0),
        );
        assert_eq!(bytes(&lines), vec![0..5, 5..6]);
        assert_eq!(glyph_at(&lines, 5), (1, 0.0));
        // Ending at 40 it has 10 pixels, which hold it.
        let (lines, rooms) = placed(&[(cell("abcd"), None), (cell("x"), Some(20.0))], Some(50.0));
        assert_eq!(bytes(&lines), vec![0..5]);
        assert_eq!(glyph_at(&lines, 4), (0, 40.0));
        assert_eq!(rooms, vec![Some(50.0), Some(10.0)]);
    }

    #[test]
    fn a_long_cell_after_a_stop_inside_the_width_hangs_under_the_stop() {
        let (lines, rooms) = placed(
            &[(cell("ab"), None), (cell("cdefgh"), Some(20.0))],
            Some(60.0),
        );
        assert_eq!(rooms, vec![Some(60.0), Some(40.0)]);
        assert_eq!(bytes(&lines), vec![0..6, 6..8]);
        assert_eq!(glyph_at(&lines, 2), (0, 20.0));
        assert_eq!(glyph_at(&lines, 6), (1, 20.0));
        assert_eq!(lines[1].width, 40.0);
        // A cell after it follows on the hung line.
        let cells = [
            (cell("ab"), None),
            (cell("cdefgh"), Some(20.0)),
            (cell("z"), Some(50.0)),
        ];
        let (lines, _) = placed(&cells, Some(60.0));
        assert_eq!(glyph_at(&lines, 8), (1, 50.0));
    }

    #[test]
    fn the_gap_goes_to_the_last_glyph_before_the_stop_and_not_when_the_cell_moved_down() {
        let (lines, _) = placed(&[(cell("ab"), None), (cell("cd"), Some(50.0))], None);
        // `b` reaches the stop: 30 pixels of gap and its own 10.
        assert_eq!(advance(&lines, 1), 40.0);
        assert_eq!(advance(&lines, 0), 10.0);
        // Moved down by the overflow rule, the gap is no one's.
        let (lines, _) = placed(&[(cell("ab"), None), (cell("cd"), Some(50.0))], Some(50.0));
        assert_eq!(advance(&lines, 1), 10.0);
        assert_eq!(lines[0].width, 20.0);
    }

    #[test]
    fn a_stop_at_the_start_of_a_row_indents_it_and_past_the_width_makes_no_empty_line() {
        // An empty cell 0 and a stop at column 0.
        let (lines, rooms) = placed(&[(cell(""), None), (cell("ab"), Some(30.0))], Some(100.0));
        assert_eq!(bytes(&lines), vec![0..2]);
        assert_eq!(glyph_at(&lines, 0), (0, 30.0));
        // Only the cell that holds a column is broken.
        assert_eq!(rooms, vec![Some(70.0)]);
        // Past the width: the cell is on the first line, at 0.
        let (lines, _) = placed(&[(cell(""), None), (cell("ab"), Some(30.0))], Some(20.0));
        assert_eq!(bytes(&lines), vec![0..2]);
        assert_eq!(glyph_at(&lines, 0), (0, 0.0));
        // The same with no cell 0 at all.
        let (lines, _) = placed(&[(cell("ab"), Some(30.0))], Some(20.0));
        assert_eq!(bytes(&lines), vec![0..2]);
        assert_eq!(glyph_at(&lines, 0), (0, 0.0));
    }

    #[test]
    fn with_no_width_nothing_breaks() {
        let cells = [
            (cell("abcdefgh"), None),
            (cell("x"), Some(20.0)),
            (cell("y"), Some(500.0)),
        ];
        let (lines, rooms) = placed(&cells, None);
        assert_eq!(bytes(&lines), vec![0..10]);
        assert_eq!(glyph_at(&lines, 8), (0, 80.0));
        assert_eq!(glyph_at(&lines, 9), (0, 500.0));
        assert_eq!(rooms, vec![None; 3]);
    }

    #[test]
    fn a_line_of_several_pieces_sits_on_the_lowest_baseline_and_reaches_the_deepest_depth() {
        let tall = Cell {
            text: "cd",
            height: 20.0,
            baseline: 10.0,
        };
        let (lines, _) = placed(&[(cell("ab"), None), (tall, Some(30.0))], None);
        // Baselines 12 and 10; depths 4 and 10.
        assert_eq!(lines[0].baseline, 12.0);
        assert_eq!(lines[0].height, 22.0);
        // One piece alone keeps its own.
        let (lines, _) = placed(&[(cell("ab"), None)], None);
        assert_eq!((lines[0].height, lines[0].baseline), (16.0, 12.0));
    }
}
