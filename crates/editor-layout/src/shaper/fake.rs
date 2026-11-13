//! The published fake of the [`Shaper`] port: [`CellShaper`].
//!
//! Every character is one glyph, and every glyph of a font has the same
//! advance and line height. Lines break greedily at character boundaries:
//! a visual line takes glyphs while the next one still fits the width, and
//! always takes at least one.
//!
//! What a font is, here ([`FontSpec`]):
//!
//! - A family has a cell, an advance and a line height at the base size
//!   (16 pixels): the default family's is [`CellShaper::new`]'s, a test
//!   gives another family one with [`CellShaper::with_family`], and a
//!   family it was given none for has the default cell.
//! - A font's advance and its own line height are its family's cell times
//!   its size over the base size. Its line height is that times its
//!   multiple, or the pixels its spec states.
//! - Weight and slant change no geometry. A spec that differs only in them
//!   is still another font: its glyphs carry its id.
//! - Ids are given in the order specs are first asked for, from 1; the
//!   default spec is font 0. An id it never gave has the default font's
//!   metrics.
//!
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
use std::sync::{Mutex, MutexGuard, PoisonError};

use super::{
    BASE_SIZE, FontId, FontSpec, Glyph, LineHeight, Metrics, ShapeInput, ShapedLine, Shaper,
    VisualLine,
};

/// The fake shaper: fixed-size glyphs per font.
#[derive(Debug)]
pub struct CellShaper {
    /// The cell, at the base size, of each family that has one of its own.
    families: BTreeMap<String, Metrics>,
    /// The cell of the default family at the base size, and of any family
    /// not in `families`.
    default: Metrics,
    /// The spec of each font asked for, by id: the default spec is font 0.
    fonts: Mutex<Vec<FontSpec>>,
    /// The generation ([`Shaper::generation`]).
    generation: AtomicU64,
    /// The bytes shaped so far.
    shaped: AtomicUsize,
}

impl CellShaper {
    /// A shaper whose every glyph of the default font is `advance` pixels
    /// across and every line `line_height` down: the cell of the default
    /// family at the base size.
    pub fn new(advance: f32, line_height: f32) -> Self {
        Self {
            families: BTreeMap::new(),
            default: Metrics {
                advance,
                line_height,
            },
            fonts: Mutex::new(vec![FontSpec::default()]),
            generation: AtomicU64::new(0),
            shaped: AtomicUsize::new(0),
        }
    }

    /// This shaper with the family `name` given a cell `advance` across
    /// and `line_height` down at the base size.
    #[must_use]
    pub fn with_family(mut self, name: &str, advance: f32, line_height: f32) -> Self {
        self.families.insert(
            name.to_owned(),
            Metrics {
                advance,
                line_height,
            },
        );
        self
    }

    /// The fonts asked for so far, locked. A poisoned lock is used as it
    /// is: the table is only ever added to, one whole spec at a time.
    fn fonts(&self) -> MutexGuard<'_, Vec<FontSpec>> {
        self.fonts.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The metrics of the font `spec`: its family's cell times its size
    /// over the base size, and for its line height that times its
    /// multiple, or its pixels.
    fn metrics_of_spec(&self, spec: &FontSpec) -> Metrics {
        let cell = spec
            .family
            .as_ref()
            .and_then(|family| self.families.get(family))
            .copied()
            .unwrap_or(self.default);
        let scale = spec.size.as_pixels() / BASE_SIZE.as_pixels();
        Metrics {
            advance: cell.advance * scale,
            line_height: match spec.line_height {
                LineHeight::Multiple(multiple) => {
                    cell.line_height * scale * (multiple as f32 / 64.0)
                }
                LineHeight::Pixels(pixels) => pixels.as_pixels(),
            },
        }
    }

    /// How many bytes of text it has been asked to shape, in all.
    pub fn bytes_shaped(&self) -> usize {
        self.shaped.load(Ordering::Relaxed)
    }

    /// Says the fonts changed: the generation moves on.
    pub fn change_fonts(&self) {
        self.generation.fetch_add(1, Ordering::Relaxed);
    }

    /// The metrics of `font`: the default font's for an id never given.
    fn metrics_of(&self, font: FontId) -> Metrics {
        let fonts = self.fonts();
        let spec = usize::try_from(font.0)
            .ok()
            .and_then(|index| fonts.get(index));
        spec.map_or(self.default, |spec| self.metrics_of_spec(spec))
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

    fn font(&self, spec: &FontSpec) -> FontId {
        let mut fonts = self.fonts();
        let index = fonts
            .iter()
            .position(|known| known == spec)
            .unwrap_or_else(|| {
                fonts.push(spec.clone());
                fonts.len() - 1
            });
        FontId(u32::try_from(index).unwrap_or(u32::MAX))
    }

    fn metrics(&self, font: FontId) -> Metrics {
        self.metrics_of(font)
    }
}

#[cfg(test)]
mod tests {
    use std::ops::Range;

    use super::CellShaper;
    use crate::shaper::{
        FontId, FontRun, FontSpec, Length, LineHeight, ShapeInput, ShapedLine, Shaper, Slant,
        VisualLine, Weight,
    };

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

    /// The default font in the family `name`.
    fn family(name: &str) -> FontSpec {
        FontSpec {
            family: Some(name.to_owned()),
            ..FontSpec::default()
        }
    }

    /// The default font at `pixels` pixels.
    fn sized(pixels: u32) -> FontSpec {
        FontSpec {
            size: Length::pixels(pixels),
            ..FontSpec::default()
        }
    }

    /// The advance and the line height of the font `spec` of `shaper`.
    fn cell(shaper: &CellShaper, spec: &FontSpec) -> (f32, f32) {
        let metrics = shaper.metrics(shaper.font(spec));
        (metrics.advance, metrics.line_height)
    }

    #[test]
    fn equal_specs_are_one_font_and_the_default_spec_is_font_0() {
        let shaper = CellShaper::new(10.0, 16.0);
        assert_eq!(shaper.font(&FontSpec::default()), FontId(0));
        let big = shaper.font(&sized(32));
        assert_ne!(big, FontId(0));
        assert_eq!(shaper.font(&sized(32)), big);
        assert_eq!(shaper.font(&FontSpec::default()), FontId(0));
        // Ids are given in the order specs are first asked for.
        assert_eq!(big, FontId(1));
        assert_eq!(shaper.font(&sized(8)), FontId(2));
        assert_eq!(shaper.font(&sized(32)), FontId(1));
    }

    #[test]
    fn a_fonts_cell_is_its_familys_at_the_base_size_times_its_size() {
        let shaper = CellShaper::new(10.0, 16.0);
        assert_eq!(cell(&shaper, &FontSpec::default()), (10.0, 16.0));
        assert_eq!(cell(&shaper, &sized(32)), (20.0, 32.0));
        assert_eq!(cell(&shaper, &sized(8)), (5.0, 8.0));
        // A size that is not whole pixels: 24.5 pixels.
        let fractional = FontSpec {
            size: Length(24 * 64 + 32),
            ..FontSpec::default()
        };
        assert_eq!(cell(&shaper, &fractional), (15.3125, 24.5));
    }

    #[test]
    fn a_line_height_is_a_multiple_of_the_fonts_own_or_pixels() {
        let shaper = CellShaper::new(10.0, 16.0);
        let with = |size: u32, line_height: LineHeight| FontSpec {
            line_height,
            ..sized(size)
        };
        // One and a half times the font's own, at 16 and at 32 pixels.
        assert_eq!(
            cell(&shaper, &with(16, LineHeight::Multiple(96))),
            (10.0, 24.0)
        );
        assert_eq!(
            cell(&shaper, &with(32, LineHeight::Multiple(96))),
            (20.0, 48.0)
        );
        // Pixels are the line's height whatever the size.
        let twenty = LineHeight::Pixels(Length::pixels(20));
        assert_eq!(cell(&shaper, &with(16, twenty)), (10.0, 20.0));
        assert_eq!(cell(&shaper, &with(32, twenty)), (20.0, 20.0));
        // And the advance is never the line height's.
        assert_ne!(
            shaper.font(&with(16, twenty)),
            shaper.font(&FontSpec::default())
        );
    }

    #[test]
    fn a_family_has_the_cell_it_was_given_and_any_other_the_default_cell() {
        let shaper = CellShaper::new(10.0, 16.0).with_family("wide", 20.0, 18.0);
        assert_eq!(cell(&shaper, &family("wide")), (20.0, 18.0));
        let big = FontSpec {
            size: Length::pixels(32),
            ..family("wide")
        };
        assert_eq!(cell(&shaper, &big), (40.0, 36.0));
        // A family it was not given is another font with the default cell.
        assert_eq!(cell(&shaper, &family("unknown")), (10.0, 16.0));
        assert_ne!(shaper.font(&family("unknown")), FontId(0));
        assert_ne!(
            shaper.font(&family("unknown")),
            shaper.font(&family("wide"))
        );
    }

    #[test]
    fn a_spec_that_differs_only_in_weight_or_slant_is_another_font_of_the_same_cell() {
        let shaper = CellShaper::new(10.0, 16.0);
        let bold = FontSpec {
            weight: Weight::BOLD,
            ..FontSpec::default()
        };
        let italic = FontSpec {
            slant: Slant::Italic,
            ..FontSpec::default()
        };
        let oblique = FontSpec {
            slant: Slant::Oblique,
            ..FontSpec::default()
        };
        let ids = [
            shaper.font(&FontSpec::default()),
            shaper.font(&bold),
            shaper.font(&italic),
            shaper.font(&oblique),
        ];
        for (index, id) in ids.iter().enumerate() {
            assert_eq!(ids.iter().position(|other| other == id), Some(index));
        }
        for spec in [&bold, &italic, &oblique] {
            assert_eq!(cell(&shaper, spec), (10.0, 16.0));
        }
        // So its glyphs carry it.
        let input = ShapeInput {
            text: "ab".to_owned(),
            runs: vec![FontRun {
                bytes: 1..2,
                font: ids[1],
            }],
        };
        let lines = shaper.shape(&input).break_lines(None);
        let fonts: Vec<FontId> = lines[0].glyphs.iter().map(|glyph| glyph.font).collect();
        assert_eq!(fonts, vec![FontId(0), ids[1]]);
    }

    #[test]
    fn a_font_id_it_never_gave_has_the_default_fonts_metrics() {
        let shaper = CellShaper::new(10.0, 16.0);
        let metrics = shaper.metrics(FontId(7));
        assert_eq!((metrics.advance, metrics.line_height), (10.0, 16.0));
    }

    #[test]
    fn an_empty_text_is_one_empty_line_of_the_runs_font() {
        let shaper = CellShaper::new(10.0, 16.0).with_family("tall", 20.0, 32.0);
        let lines = shaper.shape(&plain("")).break_lines(Some(40.0));
        assert_eq!(ranges(&lines), vec![0..0]);
        assert_eq!(lines[0].height, 16.0);
        let tall = ShapeInput {
            text: String::new(),
            runs: vec![FontRun {
                bytes: 0..0,
                font: shaper.font(&family("tall")),
            }],
        };
        assert_eq!(shaper.shape(&tall).break_lines(None)[0].height, 32.0);
    }

    #[test]
    fn each_font_has_its_own_advance_and_a_line_is_as_tall_as_its_tallest_glyph() {
        let shaper = CellShaper::new(10.0, 16.0).with_family("tall", 20.0, 32.0);
        let tall = shaper.font(&family("tall"));
        let input = ShapeInput {
            text: "abcd".to_owned(),
            runs: vec![
                FontRun {
                    bytes: 0..1,
                    font: FontId(0),
                },
                FontRun {
                    bytes: 1..2,
                    font: tall,
                },
            ],
        };
        let lines = shaper.shape(&input).break_lines(Some(40.0));
        // a (10) and b (20) fit 40 and c (10) makes 40; d is on the next line.
        assert_eq!(ranges(&lines), vec![0..3, 3..4]);
        assert_eq!(lines[0].glyphs[1].font, tall);
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
        assert_eq!(shaper.metrics(FontId(0)).advance, 10.0);
        assert_eq!(shaper.metrics(FontId(0)).line_height, 16.0);
    }
}
