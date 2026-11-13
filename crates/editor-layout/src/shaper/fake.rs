//! The published fake of the [`Shaper`] port: [`CellShaper`].
//!
//! Every character is one glyph, and every glyph of a font has the same
//! advance and line height, from a table of fonts the test sets. Lines
//! break greedily at character boundaries: a visual line takes glyphs
//! while the next one still fits the width, and always takes at least one.
//! That is the rule of the display interface's model in Lean
//! (`lean/Editor/Display/Model.lean`), so a binding over this fake answers
//! the layout queries as the model does.
//!
//! It is the "cell shaper" of `docs/design/text-and-display.md` ("The frame
//! is device-independent") and what `editor-ffi`'s display handle runs on
//! until a real adapter exists. It counts the bytes it is asked to shape,
//! so a test can bound what a query costs.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

use super::{FontId, Glyph, Metrics, ShapeInput, ShapedLine, Shaper, VisualLine};

/// The fake shaper: fixed-size glyphs per font.
#[derive(Debug)]
pub struct CellShaper {
    /// The metrics of each font that is not the default.
    fonts: BTreeMap<FontId, Metrics>,
    /// The default font's metrics, and those of any font not in `fonts`.
    default: Metrics,
    /// The generation ([`Shaper::generation`]).
    generation: AtomicU64,
    /// The bytes shaped so far.
    shaped: AtomicUsize,
}

impl CellShaper {
    /// A shaper whose every glyph is `advance` pixels across and every line
    /// `line_height` down.
    pub fn new(advance: f32, line_height: f32) -> Self {
        Self {
            fonts: BTreeMap::new(),
            default: Metrics {
                advance,
                line_height,
            },
            generation: AtomicU64::new(0),
            shaped: AtomicUsize::new(0),
        }
    }

    /// This shaper with `font` given glyphs `advance` across and lines
    /// `line_height` down.
    #[must_use]
    pub fn with_font(mut self, font: FontId, advance: f32, line_height: f32) -> Self {
        self.fonts.insert(
            font,
            Metrics {
                advance,
                line_height,
            },
        );
        self
    }

    /// How many bytes of text it has been asked to shape, in all.
    pub fn bytes_shaped(&self) -> usize {
        self.shaped.load(Ordering::Relaxed)
    }

    /// Says the fonts changed: the generation moves on.
    pub fn change_fonts(&self) {
        self.generation.fetch_add(1, Ordering::Relaxed);
    }

    /// The metrics of `font`.
    fn metrics_of(&self, font: FontId) -> Metrics {
        self.fonts.get(&font).copied().unwrap_or(self.default)
    }
}

/// What [`CellShaper`] keeps of a shaped line.
#[derive(Debug, Clone, PartialEq)]
pub struct CellLine {
    /// Its characters, in order.
    cells: Vec<Cell>,
    /// The length of the text in bytes.
    len: usize,
    /// The line height of an empty text.
    empty_height: f32,
}

/// One character of a [`CellLine`].
#[derive(Debug, Clone, Copy, PartialEq)]
struct Cell {
    /// Its byte offset.
    offset: usize,
    /// Its glyph id: the character's scalar value.
    id: u32,
    /// Its font.
    font: FontId,
    /// Its font's advance.
    advance: f32,
    /// Its font's line height.
    height: f32,
}

/// The baseline of a line `height` down: three quarters of the way.
fn baseline(height: f32) -> f32 {
    height * 0.75
}

impl CellLine {
    /// The visual line of the cells `cells`, which hold the bytes `bytes`.
    fn line(cells: &[Cell], bytes: std::ops::Range<usize>) -> VisualLine {
        let mut x = 0.0;
        let mut height: f32 = 0.0;
        let mut glyphs = Vec::with_capacity(cells.len());
        for cell in cells {
            glyphs.push(Glyph {
                id: cell.id,
                font: cell.font,
                cluster: cell.offset,
                x,
                advance: cell.advance,
            });
            x += cell.advance;
            height = height.max(cell.height);
        }
        VisualLine {
            bytes,
            glyphs,
            width: x,
            height,
            baseline: baseline(height),
        }
    }
}

impl ShapedLine for CellLine {
    fn break_lines(&self, width: Option<f32>) -> Vec<VisualLine> {
        if self.cells.is_empty() {
            return vec![VisualLine {
                bytes: 0..0,
                glyphs: Vec::new(),
                width: 0.0,
                height: self.empty_height,
                baseline: baseline(self.empty_height),
            }];
        }
        let mut lines = Vec::new();
        let mut first = 0;
        let mut x = 0.0;
        for (index, cell) in self.cells.iter().enumerate() {
            let fits = width.is_none_or(|width| x + cell.advance <= width);
            if index > first && !fits {
                let bytes = self.cells[first].offset..cell.offset;
                lines.push(Self::line(&self.cells[first..index], bytes));
                first = index;
                x = 0.0;
            }
            x += cell.advance;
        }
        let bytes = self.cells[first].offset..self.len;
        lines.push(Self::line(&self.cells[first..], bytes));
        lines
    }
}

impl Shaper for CellShaper {
    type Shaped = CellLine;

    fn shape(&self, input: &ShapeInput) -> CellLine {
        self.shaped.fetch_add(input.text.len(), Ordering::Relaxed);
        let font_at = |offset: usize| {
            input
                .runs
                .iter()
                .find(|run| run.bytes.contains(&offset))
                .map_or(FontId::default(), |run| run.font)
        };
        let cells = input
            .text
            .char_indices()
            .map(|(offset, character)| {
                let font = font_at(offset);
                let metrics = self.metrics_of(font);
                Cell {
                    offset,
                    id: u32::from(character),
                    font,
                    advance: metrics.advance,
                    height: metrics.line_height,
                }
            })
            .collect();
        let empty_font = input.runs.first().map_or(FontId::default(), |run| run.font);
        CellLine {
            cells,
            len: input.text.len(),
            empty_height: self.metrics_of(empty_font).line_height,
        }
    }

    fn generation(&self) -> u64 {
        self.generation.load(Ordering::Relaxed)
    }

    fn metrics(&self) -> Metrics {
        self.default
    }
}

#[cfg(test)]
mod tests {
    use std::ops::Range;

    use super::CellShaper;
    use crate::shaper::{FontId, FontRun, ShapeInput, ShapedLine, Shaper, VisualLine};

    /// `text` in the default font.
    fn plain(text: &str) -> ShapeInput {
        ShapeInput {
            text: text.to_owned(),
            runs: Vec::new(),
        }
    }

    /// The byte ranges of `lines`.
    fn ranges(lines: &[VisualLine]) -> Vec<Range<usize>> {
        lines.iter().map(|line| line.bytes.clone()).collect()
    }

    #[test]
    fn a_line_wider_than_the_width_wraps_at_the_glyphs_that_fit() {
        let shaper = CellShaper::new(10.0, 16.0);
        let shaped = shaper.shape(&plain("abcdefghij"));
        assert_eq!(
            ranges(&shaped.break_lines(Some(40.0))),
            vec![0..4, 4..8, 8..10]
        );
        // No partial glyph: 45 pixels hold four glyphs, as 40 do.
        assert_eq!(
            ranges(&shaped.break_lines(Some(45.0))),
            vec![0..4, 4..8, 8..10]
        );
    }

    #[test]
    fn every_character_is_one_glyph_placed_at_the_sum_of_the_advances_before_it() {
        let shaper = CellShaper::new(10.0, 16.0);
        let lines = shaper.shape(&plain("aé😀b")).break_lines(None);
        assert_eq!(lines.len(), 1);
        let glyphs: Vec<(u32, usize, f32, f32)> = lines[0]
            .glyphs
            .iter()
            .map(|glyph| (glyph.id, glyph.cluster, glyph.x, glyph.advance))
            .collect();
        assert_eq!(
            glyphs,
            vec![
                (u32::from('a'), 0, 0.0, 10.0),
                (u32::from('é'), 1, 10.0, 10.0),
                (u32::from('😀'), 3, 20.0, 10.0),
                (u32::from('b'), 7, 30.0, 10.0),
            ]
        );
        assert_eq!(lines[0].bytes, 0..8);
        assert_eq!(lines[0].width, 40.0);
        assert_eq!(lines[0].height, 16.0);
        assert_eq!(lines[0].baseline, 12.0);
    }

    #[test]
    fn a_wrapped_line_starts_its_glyphs_at_x_zero() {
        let shaper = CellShaper::new(10.0, 16.0);
        let lines = shaper.shape(&plain("abcdef")).break_lines(Some(40.0));
        let xs: Vec<f32> = lines[1].glyphs.iter().map(|glyph| glyph.x).collect();
        assert_eq!(xs, vec![0.0, 10.0]);
        assert_eq!(lines[1].width, 20.0);
    }

    #[test]
    fn a_glyph_wider_than_the_width_is_a_line_of_its_own() {
        let shaper = CellShaper::new(10.0, 16.0);
        let lines = shaper.shape(&plain("abc")).break_lines(Some(5.0));
        assert_eq!(ranges(&lines), vec![0..1, 1..2, 2..3]);
    }

    #[test]
    fn an_empty_text_is_one_empty_line_of_the_runs_font() {
        let shaper = CellShaper::new(10.0, 16.0).with_font(FontId(1), 20.0, 32.0);
        let lines = shaper.shape(&plain("")).break_lines(Some(40.0));
        assert_eq!(ranges(&lines), vec![0..0]);
        assert_eq!(lines[0].height, 16.0);
        let tall = ShapeInput {
            text: String::new(),
            runs: vec![FontRun {
                bytes: 0..0,
                font: FontId(1),
            }],
        };
        assert_eq!(shaper.shape(&tall).break_lines(None)[0].height, 32.0);
    }

    #[test]
    fn each_font_has_its_own_advance_and_a_line_is_as_tall_as_its_tallest_glyph() {
        let shaper = CellShaper::new(10.0, 16.0).with_font(FontId(1), 20.0, 32.0);
        let input = ShapeInput {
            text: "abcd".to_owned(),
            runs: vec![
                FontRun {
                    bytes: 0..1,
                    font: FontId(0),
                },
                FontRun {
                    bytes: 1..2,
                    font: FontId(1),
                },
            ],
        };
        let lines = shaper.shape(&input).break_lines(Some(40.0));
        // a (10) and b (20) fit 40 and c (10) makes 40; d is on the next line.
        assert_eq!(ranges(&lines), vec![0..3, 3..4]);
        assert_eq!(lines[0].glyphs[1].font, FontId(1));
        assert_eq!(lines[0].glyphs[2].x, 30.0);
        assert_eq!(
            (lines[0].height, lines[0].baseline, lines[1].height),
            (32.0, 24.0, 16.0)
        );
    }

    #[test]
    fn it_counts_the_bytes_it_is_asked_to_shape() {
        let shaper = CellShaper::new(10.0, 16.0);
        let shaped = shaper.shape(&plain("aé"));
        shaped.break_lines(Some(10.0));
        shaper.shape(&plain("bc"));
        assert_eq!(shaper.bytes_shaped(), 5);
    }

    #[test]
    fn its_generation_moves_on_when_the_fonts_change() {
        let shaper = CellShaper::new(10.0, 16.0);
        let before = shaper.generation();
        shaper.change_fonts();
        assert_ne!(shaper.generation(), before);
        assert_eq!(shaper.metrics().advance, 10.0);
        assert_eq!(shaper.metrics().line_height, 16.0);
    }
}
