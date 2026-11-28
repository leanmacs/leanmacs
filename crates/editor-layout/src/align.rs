//! The column arithmetic of align-to stops and wrap indents: where the
//! cells of a row cut at its stops are placed, where the row breaks, and
//! where each of its visual lines starts. Every row is placed here, one
//! with no stop as a single cell.
//!
//! A row with align-to stops ([`AlignStop`]) is
//! cut at each stop's column into **cells**: cell 0 is the text before the
//! first stop, possibly empty, and each later cell starts at its stop's
//! first character and runs to the next stop or the segment's end. Each
//! cell is shaped and broken on its own through the `Shaper` port
//! ([`line`](mod@crate::line)), and [`place`] puts the pieces on visual
//! lines by these rules, all in pixels from the start of the text row:
//!
//! - Cell 0 is at x 0, broken at the width, as a row with no stop is
//!   (under a wrap indent, at `first`: "Wrap indents" below).
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
//!
//! # Wrap indents
//!
//! A row under a wrap indent ([`Placement`]) has its first visual line
//! start at x `first` and each later one at the continuation indent `C`;
//! the rules above hold with those in place of x 0. All are in pixels
//! from the start of the text row.
//!
//! - The first visual line starts at `first` and is broken at the room
//!   `width - first`; each later line starts at `C` and is broken at
//!   `width - C`. Cell 0 is broken at those two widths at once
//!   ([`ShapedLine::break_lines_in`](crate::shaper::ShapedLine::break_lines_in)).
//! - With [`Rest::Pixels`], `C` is that x. With [`Rest::Lead`] (the
//!   hanging form) the row is cut at its lead into cell 0, the leading
//!   span, and a [`Kind::Lead`] cell, the text after it. The text starts
//!   where the span ends (the pen) and is broken at the room right of it,
//!   and its later lines hang under it: that x is `C`. The hang is right
//!   whatever the font, since it is where the span's glyphs end. A span
//!   that reaches the width puts the text at `first` on the next line,
//!   and that is its hang. A lead of no byte, or at or past the row's end,
//!   makes no cut and hangs at `first`. A lead at a stop's column makes no
//!   cell of its own: the stop places the cell ([`Kind::Stop`]'s
//!   `hangs`), and the hang is where that cell starts. Until the hang is
//!   placed, `C` is `first`.
//! - An indent at or past the width is not applied: that line starts at
//!   x 0 and is broken at the whole width, as a stop past the width is
//!   broken before, so no text goes right of the view.
//! - With no width nothing breaks, and the line starts at `first`.
//! - With stops in the row, cell 0 starts at `first`, a cell moved down
//!   by the overflow rule starts the next line at `C` and is broken at
//!   `width - C`, and a cell hanging under its stop keeps its stop's x. A
//!   stop's x is still from the start of the text row.
//! - A composed line's glyph xs and its width include where it starts, so
//!   a cell, a position and a click on it are at the drawn x. An empty
//!   row is one empty line at `first`, as wide as `first`.

use std::ops::Range;

use editor_text::Snapshot;

use crate::scene::AlignStop;
use crate::shaper::{Glyph, VisualLine, Widths};
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

/// What a cell of a row is.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum Kind {
    /// Cell 0: the text before the first stop or lead, or the whole row.
    First,
    /// The text after a hanging indent's leading span: it starts where the
    /// span ends, and its later lines hang there.
    Lead,
    /// The text after an align-to stop.
    Stop {
        /// The stop's x, in pixels from the start of the text row.
        x: f32,
        /// Whether a hanging indent's lead falls at the stop's column, so
        /// that the row's later lines hang where this cell starts.
        hangs: bool,
    },
}

/// One cell of a row cut at its stops and its lead.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Cut {
    /// Its columns of the segment's expanded text.
    pub columns: Range<usize>,
    /// What it is.
    pub kind: Kind,
}

/// Where a row's visual lines start under its wrap indent, in pixels from
/// the start of the text row (module docs, "Wrap indents").
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Placement {
    /// Where its first visual line starts.
    pub first: f32,
    /// Where each later visual line starts.
    pub rest: Rest,
}

impl Placement {
    /// No indent: every visual line at x 0.
    pub const NONE: Self = Self {
        first: 0.0,
        rest: Rest::Pixels(0.0),
    };
}

/// Where a row's later visual lines start.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum Rest {
    /// At this x.
    Pixels(f32),
    /// Where the row's [`Kind::Lead`] cell starts, or its hanging stop's
    /// cell; at the first-line indent until one is placed.
    Lead,
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
    /// How tall it is: its one piece's height, or the lowest baseline
    /// plus the deepest depth of several, so that a line of one piece is
    /// exactly as tall as the shaper made it.
    height: f32,
    /// How many pieces it holds.
    pieces: usize,
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
            height: self.height,
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
        self.pieces += 1;
        self.height = if self.pieces == 1 {
            piece.height
        } else {
            self.baseline + self.depth
        };
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
            height: piece.height,
            pieces: 0,
        };
        line.add(piece, base, x);
        line
    }
}

/// The visual lines of a row cut into `cuts`, by the module's rules, at
/// `width` (`None` breaks nothing), under the wrap indent `placement`.
/// `break_cell` is asked for the visual lines of cell `index` broken at
/// widths (a first line's and the rest's, `None` for none), each with
/// its bytes relative to the cell's first column and its glyphs from its
/// own left edge; it is asked once for each cell that holds a column, in
/// order. A cell of no column is passed over, unless it is the row's only
/// cell: an empty row is one empty visual line at the first-line indent.
pub(crate) fn place(
    cuts: &[Cut],
    width: Option<f32>,
    placement: Placement,
    mut break_cell: impl FnMut(usize, Widths) -> Vec<VisualLine>,
) -> Vec<VisualLine> {
    // An indent at or past the width is not applied.
    let applied = |x: f32| match width {
        Some(width) if x >= width => 0.0,
        _ => x,
    };
    let room = |x: f32| width.map(|width| width - x);
    let first = applied(placement.first);
    // Where a later visual line starts: the continuation indent, which a
    // lead learns as it is placed.
    let mut hang = match placement.rest {
        Rest::Pixels(x) => applied(x),
        Rest::Lead => first,
    };
    let leads = placement.rest == Rest::Lead;
    let mut lines: Vec<VisualLine> = Vec::new();
    let mut current: Option<Composing> = None;
    for (index, cut) in cuts.iter().enumerate() {
        if cut.columns.is_empty() && cuts.len() > 1 {
            continue;
        }
        // Where a line that starts now starts: the first line at the
        // first-line indent, a later one at the continuation indent.
        let fresh = if lines.is_empty() { first } else { hang };
        let pen = current.as_ref().map_or(fresh, |line| line.pen);
        let holds = current.as_ref().is_some_and(Composing::holds);
        // Where the cell starts, and where its later lines go.
        let (start, later) = match cut.kind {
            // Cell 0's later lines are at the continuation indent.
            Kind::First => (pen, hang),
            Kind::Lead => {
                let over = width.is_some_and(|width| pen >= width);
                let start = if over {
                    if holds && let Some(line) = current.take() {
                        lines.push(line.finish());
                    }
                    first
                } else {
                    pen
                };
                if leads {
                    hang = start;
                }
                (start, start)
            }
            Kind::Stop { x: stop, hangs } => {
                let start = stop.max(pen);
                let over = width.is_some_and(|width| stop >= width || start >= width);
                let start = if over {
                    if holds && let Some(line) = current.take() {
                        lines.push(line.finish());
                    }
                    if lines.is_empty() { first } else { hang }
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
                    start
                };
                if leads && hangs {
                    hang = start;
                }
                (start, start)
            }
        };
        let widths = Widths {
            first: room(start),
            rest: room(later),
        };
        let base = cut.columns.start;
        for (piece_index, piece) in break_cell(index, widths).iter().enumerate() {
            match current.as_mut() {
                Some(line) if piece_index == 0 => line.add(piece, base, start),
                _ => {
                    if let Some(line) = current.take() {
                        lines.push(line.finish());
                    }
                    let x = if piece_index == 0 { start } else { later };
                    current = Some(Composing::of(piece, base, x));
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

    use super::{Cut, Kind, Placement, Rest, place, resolved};
    use crate::scene::AlignStop;
    use crate::shaper::{Glyph, ResolvedFontId, VisualLine, Widths};

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

    /// The visual lines of `cell` broken greedily at `widths`, every
    /// character 10 pixels across, at least one to a line.
    fn broken(cell: &Cell, widths: Widths) -> Vec<VisualLine> {
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
        let per_line = |room: Option<f32>| {
            room.map_or(usize::MAX, |room| ((room / 10.0).floor() as usize).max(1))
        };
        if chars.is_empty() {
            return vec![line(&[], 0)];
        }
        let (head, tail) = chars.split_at(per_line(widths.first).min(chars.len()));
        let pieces: Vec<&[(usize, char)]> = [head]
            .into_iter()
            .chain(tail.chunks(per_line(widths.rest)))
            .collect();
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
    /// stop beside it, at `width`; and the first-line width each cell was
    /// broken at.
    fn placed(
        cells: &[(Cell, Option<f32>)],
        width: Option<f32>,
    ) -> (Vec<VisualLine>, Vec<Option<f32>>) {
        let kinds: Vec<(&Cell, Kind)> = cells
            .iter()
            .map(|(cell, stop)| {
                let kind = stop.map_or(Kind::First, |x| Kind::Stop { x, hangs: false });
                (cell, kind)
            })
            .collect();
        let (lines, widths) = placed_under(&kinds, width, Placement::NONE);
        (lines, widths.iter().map(|widths| widths.first).collect())
    }

    /// The visual lines of the row of `cells`, each of the kind beside it,
    /// at `width` under `placement`; and the widths each cell was broken
    /// at.
    fn placed_under(
        cells: &[(&Cell, Kind)],
        width: Option<f32>,
        placement: Placement,
    ) -> (Vec<VisualLine>, Vec<Widths>) {
        let mut at = 0;
        let cuts: Vec<Cut> = cells
            .iter()
            .map(|(cell, kind)| {
                let columns = at..at + cell.text.len();
                at = columns.end;
                Cut {
                    columns,
                    kind: *kind,
                }
            })
            .collect();
        let mut asked = Vec::new();
        let lines = place(&cuts, width, placement, |index, widths| {
            asked.push(widths);
            broken(cells[index].0, widths)
        });
        (lines, asked)
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

    /// A wrap indent of `first` and a continuation at `rest` pixels.
    fn indent(first: f32, rest: f32) -> Placement {
        Placement {
            first,
            rest: Rest::Pixels(rest),
        }
    }

    /// A hanging indent with its first line at `first`.
    fn hanging(first: f32) -> Placement {
        Placement {
            first,
            rest: Rest::Lead,
        }
    }

    /// The x of the first glyph of each line.
    fn starts(lines: &[VisualLine]) -> Vec<f32> {
        lines
            .iter()
            .map(|line| line.glyphs.first().map_or(line.width, |glyph| glyph.x))
            .collect()
    }

    /// A stop at `x` that no lead falls at.
    fn stop_at(x: f32) -> Kind {
        Kind::Stop { x, hangs: false }
    }

    #[test]
    fn cell_0_starts_at_the_first_line_indent_and_its_later_lines_at_the_continuation() {
        let row = cell("abcdefghij");
        let (lines, asked) = placed_under(&[(&row, Kind::First)], Some(60.0), indent(20.0, 10.0));
        // 40 pixels right of 20 hold four glyphs, and 50 right of 10 five.
        assert_eq!(bytes(&lines), vec![0..4, 4..9, 9..10]);
        assert_eq!(starts(&lines), vec![20.0, 10.0, 10.0]);
        assert_eq!(
            asked,
            vec![Widths {
                first: Some(40.0),
                rest: Some(50.0)
            }]
        );
        // A line's width counts its indent, as its glyphs' xs do.
        assert_eq!(lines[0].width, 60.0);
        assert_eq!(lines[2].width, 20.0);
    }

    #[test]
    fn a_lead_cell_starts_where_the_leading_span_ends_and_its_later_lines_hang_there() {
        let (marker, text) = (cell("- "), cell("abcdefgh"));
        let (lines, asked) = placed_under(
            &[(&marker, Kind::First), (&text, Kind::Lead)],
            Some(60.0),
            hanging(0.0),
        );
        assert_eq!(bytes(&lines), vec![0..6, 6..10]);
        assert_eq!(glyph_at(&lines, 2), (0, 20.0));
        assert_eq!(glyph_at(&lines, 6), (1, 20.0));
        // The text is broken at the room right of the span, and its later
        // lines at the same room.
        assert_eq!(asked[1], Widths::all(Some(40.0)));
    }

    #[test]
    fn a_leading_span_that_reaches_the_width_puts_the_text_at_the_first_line_indent_below() {
        let (span, text) = (cell("abcde"), cell("uvwxyz"));
        let (lines, asked) = placed_under(
            &[(&span, Kind::First), (&text, Kind::Lead)],
            Some(60.0),
            hanging(10.0),
        );
        // `abcde` ends at 60, the width.
        assert_eq!(bytes(&lines), vec![0..5, 5..10, 10..11]);
        assert_eq!(starts(&lines), vec![10.0, 10.0, 10.0]);
        assert_eq!(asked[1], Widths::all(Some(50.0)));
    }

    #[test]
    fn a_lead_of_no_byte_hangs_at_the_first_line_indent() {
        let row = cell("abcdefgh");
        let (lines, asked) = placed_under(&[(&row, Kind::First)], Some(60.0), hanging(20.0));
        assert_eq!(bytes(&lines), vec![0..4, 4..8]);
        assert_eq!(starts(&lines), vec![20.0, 20.0]);
        assert_eq!(asked, vec![Widths::all(Some(40.0))]);
    }

    #[test]
    fn a_stop_cell_moved_by_the_overflow_rule_starts_at_the_continuation_indent() {
        let (first, after) = (cell("ab"), cell("cd"));
        let (lines, asked) = placed_under(
            &[(&first, Kind::First), (&after, stop_at(60.0))],
            Some(50.0),
            indent(20.0, 10.0),
        );
        assert_eq!(bytes(&lines), vec![0..2, 2..4]);
        assert_eq!(glyph_at(&lines, 0), (0, 20.0));
        assert_eq!(glyph_at(&lines, 2), (1, 10.0));
        assert_eq!(asked[1], Widths::all(Some(40.0)));
    }

    #[test]
    fn a_cell_hanging_under_its_stop_keeps_the_stops_x_under_an_indent() {
        let (first, after) = (cell("ab"), cell("cdefgh"));
        let (lines, _) = placed_under(
            &[(&first, Kind::First), (&after, stop_at(30.0))],
            Some(60.0),
            indent(10.0, 5.0),
        );
        assert_eq!(bytes(&lines), vec![0..5, 5..8]);
        assert_eq!(glyph_at(&lines, 2), (0, 30.0));
        assert_eq!(glyph_at(&lines, 5), (1, 30.0));
    }

    #[test]
    fn a_lead_at_a_stops_column_hangs_where_the_stop_places_its_cell() {
        let (marker, text, last) = (cell("- "), cell("abcdefgh"), cell("xy"));
        let cells = [
            (&marker, Kind::First),
            (
                &text,
                Kind::Stop {
                    x: 40.0,
                    hangs: true,
                },
            ),
            (&last, stop_at(90.0)),
        ];
        let (lines, _) = placed_under(&cells, Some(80.0), hanging(0.0));
        assert_eq!(bytes(&lines), vec![0..6, 6..10, 10..12]);
        assert_eq!(glyph_at(&lines, 2), (0, 40.0));
        assert_eq!(glyph_at(&lines, 6), (1, 40.0));
        // The cell the overflow rule moves down starts at the hang.
        assert_eq!(glyph_at(&lines, 10), (2, 40.0));
    }

    #[test]
    fn an_indent_at_or_past_the_width_is_not_applied() {
        let row = cell("abcdef");
        let (lines, asked) = placed_under(&[(&row, Kind::First)], Some(50.0), indent(50.0, 60.0));
        assert_eq!(bytes(&lines), vec![0..5, 5..6]);
        assert_eq!(starts(&lines), vec![0.0, 0.0]);
        assert_eq!(asked, vec![Widths::all(Some(50.0))]);
        // Each indent alone.
        let (lines, asked) = placed_under(&[(&row, Kind::First)], Some(50.0), indent(20.0, 50.0));
        assert_eq!(bytes(&lines), vec![0..3, 3..6]);
        assert_eq!(starts(&lines), vec![20.0, 0.0]);
        assert_eq!(
            asked,
            vec![Widths {
                first: Some(30.0),
                rest: Some(50.0)
            }]
        );
    }

    #[test]
    fn with_no_width_the_first_line_indent_applies_and_nothing_breaks() {
        let row = cell("abcdef");
        let (lines, asked) = placed_under(&[(&row, Kind::First)], None, indent(20.0, 40.0));
        assert_eq!(bytes(&lines), vec![0..6]);
        assert_eq!(starts(&lines), vec![20.0]);
        assert_eq!(asked, vec![Widths::all(None)]);
    }

    #[test]
    fn an_empty_row_is_one_empty_line_at_its_first_line_indent() {
        let row = cell("");
        for width in [Some(100.0), None] {
            let (lines, _) = placed_under(&[(&row, Kind::First)], width, indent(20.0, 40.0));
            assert_eq!(bytes(&lines), vec![0..0], "at {width:?}");
            assert_eq!((lines[0].width, lines[0].height), (20.0, 16.0));
        }
    }
}
