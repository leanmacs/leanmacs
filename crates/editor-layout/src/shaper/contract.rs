//! The contract of the [`Shaper`] port: the rules the fake and every real
//! adapter are held to.
//!
//! [`check`] runs every property over a fixed set of inputs and widths and
//! returns the names of those that fail. The published fake runs it in
//! `tests/shaper_contract.rs`; a real adapter (Parley, the display
//! pipeline's phase 3) runs it in its own crate's tests.
//!
//! The rules leave the breaking policy open: a shaper may break at
//! characters, as the fake does, or at words, and may reorder glyphs for
//! bidirectional text: a line's glyphs are in the order they are drawn
//! in, from its left edge ([`ORDERED`]), whatever the order of their
//! clusters. What is not open is that nothing in a text forces a break
//! ([`UNBROKEN`]): a segment has no line feed, and every other character,
//! a carriage return and the Unicode line and paragraph separators among
//! them, is content. They shape only in the default font, [`FontId`] 0,
//! which every adapter has. Of the other fonts they say only how ids stand
//! for specs ([`FONTS`]): what a spec's glyphs measure is each adapter's.
//! Which font a glyph is drawn in is the adapter's too (a fallback font, a
//! synthesis); the rule is that the shaper describes it ([`RESOLVED`]):
//! the glyph names an entry of the table as it was when its line was
//! shaped, and the table keeps every entry as it was for the generation.
//! A line broken at two widths ([`ShapedLine::break_lines_in`]) breaks its
//! first line as at the first width alone and every later one within the
//! second ([`INDENTED`]), so a wrap indent's lines are the shaper's.

use std::sync::Arc;

use super::{
    FontId, FontRun, FontSpec, Length, LineHeight, ResolvedFont, ShapeInput, ShapedLine, Shaper,
    Slant, VisualLine, Weight, Widths,
};

/// The visual lines cover the input's bytes in order, with no gap and no
/// overlap.
pub const COVER: &str = "the visual lines cover the input's bytes in order, without gap or overlap";
/// No visual line is wider than the width, unless it holds one cluster.
pub const FIT: &str = "no visual line is wider than the width unless it holds one cluster";
/// No width is one visual line.
pub const UNBROKEN: &str = "breaking at no width gives one visual line";
/// A kept shaped line breaks as a fresh one does.
pub const KEPT: &str =
    "breaking a kept shaped line again at a width equals shaping afresh and breaking at it";
/// Each glyph is of its own visual line.
pub const CLUSTERS: &str = "every glyph's cluster lies in its visual line";
/// Every line has a height.
pub const HEIGHTS: &str = "every visual line, and the default font's line, is taller than nothing";

/// A font's id stands for its spec.
pub const FONTS: &str =
    "the default spec is font 0, equal specs are one font, and different specs are different fonts";

/// Every glyph names a font of the shaper's table, and the table keeps
/// what it said.
pub const RESOLVED: &str = "every glyph is drawn in a font the shaper describes, and a description stays as given for the generation";

/// A line's glyphs are in the order they are drawn in, left to right.
pub const ORDERED: &str =
    "a line's glyphs are in order from its left edge, none starting before the one before it";

/// A line starts at its left edge and holds its glyphs: what layout
/// relies on to place the cells of a row at align-to stops (the port's
/// module docs, [`shaper`](crate::shaper)).
pub const ORIGIN: &str =
    "a line's first glyph's pen is at 0, and no glyph ends past the line's width";

/// Broken at two widths, a line's first visual line is as it is at the
/// first width alone, and its later lines fit the second: what layout
/// relies on to start a row's first line at a wrap indent's first-line
/// indent and the rest at its continuation indent (the port's module
/// docs, [`shaper`](crate::shaper)).
pub const INDENTED: &str = "broken at a first width and a rest width, the first line is the first line broken at the first width alone, every later line fits the rest width unless it holds one cluster, and the lines cover the input";

/// How far a glyph may be from where [`ORIGIN`] puts it, in pixels: a
/// 64th, so that float noise in an adapter's sums is no fault.
const ORIGIN_TOLERANCE: f32 = 1.0 / 64.0;

/// Every property, by name.
pub const PROPERTIES: [&str; 11] = [
    COVER, FIT, UNBROKEN, KEPT, CLUSTERS, HEIGHTS, FONTS, RESOLVED, ORDERED, ORIGIN, INDENTED,
];

/// The texts the properties are run over: empty, one character, a long
/// run of one script, characters of two to four bytes, words with spaces,
/// and the characters a paragraph layout breaks at that are content here:
/// a carriage return alone, U+2028 and U+2029 ([`UNBROKEN`]; a row is
/// split at line feeds only, so they reach a shaper).
pub fn texts() -> Vec<&'static str> {
    vec![
        "",
        "a",
        "abcdefghijklmnopqrstuvwxyz",
        "aé😀b€c\u{10dc80}",
        "one two three four five six seven",
        "a\rb\u{2028}c\u{2029}d",
    ]
}

/// The widths each text is broken at, in pixels, with none first.
pub fn widths() -> Vec<Option<f32>> {
    vec![
        None,
        Some(1.0),
        Some(17.0),
        Some(40.0),
        Some(95.5),
        Some(10_000.0),
    ]
}

/// The names of the properties `shaper` does not hold, in the order of
/// [`PROPERTIES`].
pub fn check<S: Shaper>(shaper: &S) -> Vec<&'static str> {
    let mut failed = [false; PROPERTIES.len()];
    let metrics = shaper.metrics(FontId::default());
    if !(metrics.line_height > 0.0 && metrics.advance > 0.0) {
        failed[5] = true;
    }
    let mut described = Described::of(shaper);
    for text in texts() {
        let input = ShapeInput {
            text: text.to_owned(),
            runs: vec![FontRun {
                bytes: 0..text.len(),
                font: FontId::default(),
            }],
        };
        let kept = shaper.shape(&input);
        failed[7] |= !described.still(shaper);
        // The fonts described when the line was shaped: its glyphs name
        // one of them at whatever width it is broken, and however the
        // table grows after.
        let known = described.fonts.len();
        failed[2] |= kept.break_lines(None).len() != 1;
        for width in widths() {
            let lines = kept.break_lines(width);
            failed[0] |= !covers(&lines, text.len());
            failed[1] |= width.is_some_and(|width| !fits(&lines, width));
            failed[4] |= !lines.iter().all(|line| {
                line.glyphs
                    .iter()
                    .all(|glyph| line.bytes.contains(&glyph.cluster))
            });
            failed[5] |= !lines.iter().all(|line| line.height > 0.0);
            failed[7] |= !lines.iter().all(|line| {
                line.glyphs
                    .iter()
                    .all(|glyph| usize::try_from(glyph.font.0).is_ok_and(|font| font < known))
            });
            failed[8] |= !lines
                .iter()
                .all(|line| line.glyphs.windows(2).all(|pair| pair[0].x <= pair[1].x));
            failed[9] |= !lines.iter().all(starts_at_its_edge);
            // Broken at every other width first, then at this one.
            for other in widths() {
                kept.break_lines(other);
                failed[3] |= kept.break_lines(width) != shaper.shape(&input).break_lines(width);
            }
            // The first line at this width, the rest at every other.
            for rest in widths() {
                failed[10] |= !indented(&kept, width, rest, text.len());
            }
        }
        failed[7] |= !described.still(shaper);
    }
    failed[6] = !fonts_are_told_apart(shaper);
    failed[7] |= !described.still(shaper);
    PROPERTIES
        .iter()
        .zip(failed)
        .filter_map(|(name, failed)| failed.then_some(*name))
        .collect()
}

/// A shaper's table of resolved fonts as it was last read, to see that it
/// keeps what it said ([`RESOLVED`]).
struct Described {
    /// The shaper's generation when it was read.
    generation: u64,
    /// The table.
    fonts: Arc<[ResolvedFont]>,
}

impl Described {
    /// The table of `shaper` as it is now.
    fn of<S: Shaper>(shaper: &S) -> Self {
        Self {
            generation: shaper.generation(),
            fonts: shaper.resolved(),
        }
    }

    /// Reads the table of `shaper` again: whether, under the generation it
    /// was last read under, it still holds every entry it held, each as it
    /// was. Under another generation it may hold anything.
    fn still<S: Shaper>(&mut self, shaper: &S) -> bool {
        let now = Self::of(shaper);
        let kept = now.generation != self.generation
            || now
                .fonts
                .get(..self.fonts.len())
                .is_some_and(|held| held == &self.fonts[..]);
        *self = now;
        kept
    }
}

/// The specs [`FONTS`] is run over: the default, and one that differs from
/// it in each field alone. The family is one no adapter need have: a
/// family it cannot find is still another spec.
pub fn specs() -> Vec<FontSpec> {
    let default = FontSpec::default();
    vec![
        default.clone(),
        FontSpec {
            family: Some("a family of the shaper contract".to_owned()),
            ..default.clone()
        },
        FontSpec {
            size: Length::pixels(24),
            ..default.clone()
        },
        FontSpec {
            weight: Weight::BOLD,
            ..default.clone()
        },
        FontSpec {
            slant: Slant::Italic,
            ..default.clone()
        },
        FontSpec {
            slant: Slant::Oblique,
            ..default.clone()
        },
        FontSpec {
            line_height: LineHeight::Multiple(96),
            ..default.clone()
        },
        FontSpec {
            line_height: LineHeight::Pixels(Length::pixels(24)),
            ..default
        },
    ]
}

/// Whether `shaper` gives the default spec font 0, each of [`specs`] one
/// id however often and in whatever order it is asked, and no two of them
/// the same id.
fn fonts_are_told_apart<S: Shaper>(shaper: &S) -> bool {
    let specs = specs();
    let first: Vec<FontId> = specs.iter().map(|spec| shaper.font(spec)).collect();
    let again: Vec<FontId> = specs.iter().rev().map(|spec| shaper.font(spec)).collect();
    let distinct = first
        .iter()
        .enumerate()
        .all(|(index, id)| !first[..index].contains(id));
    shaper.font(&FontSpec::default()) == FontId::default()
        && first.first() == Some(&FontId::default())
        && first.iter().eq(again.iter().rev())
        && distinct
}

/// Whether `line`'s first glyph from its left edge has its pen at 0 and
/// none of its glyphs ends past its width, each within
/// [`ORIGIN_TOLERANCE`]. The leftmost pen is found whatever order the
/// glyphs are listed in, which is [`ORDERED`]'s to hold.
fn starts_at_its_edge(line: &VisualLine) -> bool {
    let leftmost = line.glyphs.iter().map(|glyph| glyph.x).reduce(f32::min);
    let first = leftmost.is_none_or(|x| x.abs() <= ORIGIN_TOLERANCE);
    let held = line
        .glyphs
        .iter()
        .all(|glyph| glyph.x + glyph.advance <= line.width + ORIGIN_TOLERANCE);
    first && held
}

/// Whether `line`, `len` bytes long, broken with its first visual line at
/// `first` and the rest at `rest`, has the first line it has broken at
/// `first` alone, every later line fitting `rest`, and lines that cover
/// it ([`INDENTED`]).
fn indented<L: ShapedLine>(line: &L, first: Option<f32>, rest: Option<f32>, len: usize) -> bool {
    let lines = line.break_lines_in(Widths { first, rest });
    let alone = line.break_lines(first);
    let later = lines.get(1..).unwrap_or_default();
    lines.first() == alone.first()
        && rest.is_none_or(|rest| fits(later, rest))
        && covers(&lines, len)
}

/// Whether `lines` cover `0..len` in order, with no gap and no overlap,
/// and each holds a byte unless the text is empty.
fn covers(lines: &[VisualLine], len: usize) -> bool {
    let mut at = 0;
    for line in lines {
        if line.bytes.start != at || (line.bytes.is_empty() && len > 0) {
            return false;
        }
        at = line.bytes.end;
    }
    !lines.is_empty() && at == len
}

/// Whether every line of `lines` is at most `width` across or holds one
/// cluster.
fn fits(lines: &[VisualLine], width: f32) -> bool {
    lines.iter().all(|line| {
        let one_cluster = line.glyphs.iter().all(|glyph| {
            line.glyphs
                .first()
                .is_some_and(|first| first.cluster == glyph.cluster)
        });
        line.width <= width || one_cluster
    })
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use super::{
        CLUSTERS, COVER, FIT, FONTS, HEIGHTS, INDENTED, KEPT, ORDERED, ORIGIN, RESOLVED, UNBROKEN,
        check,
    };
    use crate::shaper::fake::{CellLine, CellShaper};
    use crate::shaper::{
        FontId, FontSpec, Metrics, ResolvedFont, ResolvedFontId, ShapeInput, ShapedLine, Shaper,
        VisualLine, Widths,
    };

    /// How a [`Wrong`] shaper breaks the contract.
    #[derive(Debug, Clone, Copy, PartialEq)]
    enum Fault {
        /// Its last visual line stops a byte short of the text.
        DropsTheLastByte,
        /// It never breaks.
        NeverBreaks,
        /// It breaks into one line per character even with no width.
        AlwaysBreaks,
        /// A kept line breaks at the first width it was ever broken at.
        RemembersItsFirstWidth,
        /// Its glyphs' clusters are one byte on.
        ShiftsClusters,
        /// Its lines have no height.
        Flat,
        /// Every spec is font 0.
        OneFont,
        /// Its glyphs name a font its table has no entry for.
        UnknownFont,
        /// It forgets what it said of a font: each time its table is asked
        /// for, every entry is a pixel larger.
        ForgetsFonts,
        /// Its lines list their glyphs from the right edge to the left.
        Reverses,
        /// It breaks after a carriage return, U+2028 and U+2029, as a
        /// paragraph layout does, even with no width: each paragraph is
        /// shaped on its own, and its lines are the fake's at the widths
        /// their places among the lines give them.
        BreaksAtReturns,
        /// Every glyph of its lines is a pixel right of where the fake
        /// puts it, the line's width unchanged.
        Indents,
        /// Its lines' widths are a pixel short of their last glyph's end.
        Overruns,
        /// Broken at two widths, it breaks every line at the first.
        OneWidth,
    }

    /// The paragraphs of `text` as a paragraph layout cuts it: after each
    /// carriage return, U+2028 and U+2029 that is not its last character,
    /// each with its first byte.
    fn paragraphs(text: &str) -> Vec<(usize, &str)> {
        let mut pieces = Vec::new();
        let mut start = 0;
        for (offset, character) in text.char_indices() {
            let end = offset + character.len_utf8();
            if ['\r', '\u{2028}', '\u{2029}'].contains(&character) && end < text.len() {
                pieces.push((start, &text[start..end]));
                start = end;
            }
        }
        pieces.push((start, &text[start..]));
        pieces
    }

    /// `line`, a line of the paragraph whose first byte is `start`, with
    /// its bytes and clusters made the whole text's.
    fn moved(mut line: VisualLine, start: usize) -> VisualLine {
        line.bytes = line.bytes.start + start..line.bytes.end + start;
        for glyph in &mut line.glyphs {
            glyph.cluster += start;
        }
        line
    }

    /// A shaper that is the fake with one fault.
    struct Wrong {
        fault: Fault,
        fake: CellShaper,
        /// How often its table was asked for.
        asked: Mutex<u32>,
    }

    /// What [`Wrong`] keeps.
    struct WrongLine {
        fault: Fault,
        line: CellLine,
        first: Mutex<Option<Widths>>,
        /// For [`Fault::BreaksAtReturns`], each paragraph of the text
        /// shaped on its own, with its first byte; none for another fault.
        paragraphs: Vec<(usize, CellLine)>,
    }

    impl ShapedLine for WrongLine {
        fn break_lines_in(&self, widths: Widths) -> Vec<VisualLine> {
            let widths = match self.fault {
                Fault::NeverBreaks => Widths::all(None),
                Fault::AlwaysBreaks => Widths::all(Some(0.0)),
                Fault::RemembersItsFirstWidth => *self.first.lock().unwrap().get_or_insert(widths),
                Fault::OneWidth => Widths::all(widths.first),
                _ => widths,
            };
            let mut lines = self.line.break_lines_in(widths);
            if self.fault == Fault::BreaksAtReturns {
                // The first paragraph's lines at the widths, and every
                // later paragraph's at the rest width.
                lines = Vec::new();
                for (index, (start, paragraph)) in self.paragraphs.iter().enumerate() {
                    let at = if index == 0 {
                        widths
                    } else {
                        Widths::all(widths.rest)
                    };
                    let broken = paragraph.break_lines_in(at);
                    lines.extend(broken.into_iter().map(|line| moved(line, *start)));
                }
            }
            for line in &mut lines {
                match self.fault {
                    Fault::Reverses => line.glyphs.reverse(),
                    Fault::ShiftsClusters => {
                        for glyph in &mut line.glyphs {
                            glyph.cluster += 1;
                        }
                    }
                    Fault::Flat => line.height = 0.0,
                    Fault::Indents => {
                        for glyph in &mut line.glyphs {
                            glyph.x += 1.0;
                        }
                    }
                    Fault::Overruns => {
                        if let Some(last) = line.glyphs.last() {
                            line.width = last.x + last.advance - 1.0;
                        }
                    }
                    Fault::UnknownFont => {
                        for glyph in &mut line.glyphs {
                            glyph.font = ResolvedFontId(glyph.font.0 + 1000);
                        }
                    }
                    _ => {}
                }
            }
            if self.fault == Fault::DropsTheLastByte
                && let Some(last) = lines.last_mut()
            {
                last.bytes.end = last.bytes.end.saturating_sub(1);
            }
            lines
        }
    }

    impl Shaper for Wrong {
        type Shaped = WrongLine;

        fn shape(&self, input: &ShapeInput) -> WrongLine {
            let paragraphs = match self.fault {
                Fault::BreaksAtReturns => paragraphs(&input.text)
                    .into_iter()
                    .map(|(start, text)| {
                        let input = ShapeInput {
                            text: text.to_owned(),
                            runs: Vec::new(),
                        };
                        (start, self.fake.shape(&input))
                    })
                    .collect(),
                _ => Vec::new(),
            };
            WrongLine {
                fault: self.fault,
                line: self.fake.shape(input),
                first: Mutex::new(None),
                paragraphs,
            }
        }

        fn generation(&self) -> u64 {
            0
        }

        fn resolved(&self) -> Arc<[ResolvedFont]> {
            let table = self.fake.resolved();
            if self.fault != Fault::ForgetsFonts {
                return table;
            }
            let mut asked = self.asked.lock().unwrap();
            *asked += 1;
            table
                .iter()
                .map(|font| ResolvedFont {
                    size: font.size + *asked as f32,
                    ..font.clone()
                })
                .collect()
        }

        fn font(&self, spec: &FontSpec) -> FontId {
            match self.fault {
                Fault::OneFont => FontId::default(),
                _ => self.fake.font(spec),
            }
        }

        fn metrics(&self, font: FontId) -> Metrics {
            self.fake.metrics(font)
        }
    }

    /// The properties the fake with `fault` fails.
    fn failures(fault: Fault) -> Vec<&'static str> {
        check(&Wrong {
            fault,
            fake: CellShaper::new(10.0, 16.0),
            asked: Mutex::new(0),
        })
    }

    #[test]
    fn a_shaper_whose_glyphs_name_a_font_it_does_not_describe_fails_the_resolved_rule() {
        assert_eq!(failures(Fault::UnknownFont), vec![RESOLVED]);
    }

    #[test]
    fn a_shaper_whose_description_of_a_font_changes_fails_the_resolved_rule() {
        assert_eq!(failures(Fault::ForgetsFonts), vec![RESOLVED]);
    }

    #[test]
    fn a_shaper_whose_glyphs_are_listed_from_the_right_is_not_ordered() {
        assert_eq!(failures(Fault::Reverses), vec![ORDERED]);
    }

    #[test]
    fn a_shaper_that_breaks_at_a_return_or_a_separator_is_not_one_line() {
        assert_eq!(failures(Fault::BreaksAtReturns), vec![UNBROKEN]);
    }

    #[test]
    fn a_shaper_whose_first_glyph_is_not_at_its_lines_left_edge_fails_the_origin_rule() {
        assert_eq!(failures(Fault::Indents), vec![ORIGIN]);
    }

    #[test]
    fn a_shaper_whose_glyphs_end_past_their_lines_width_fails_the_origin_rule() {
        assert_eq!(failures(Fault::Overruns), vec![ORIGIN]);
    }

    #[test]
    fn a_shaper_that_breaks_every_line_at_the_first_width_fails_the_indent_rule() {
        assert_eq!(failures(Fault::OneWidth), vec![INDENTED]);
    }

    #[test]
    fn a_shaper_whose_lines_stop_short_of_the_text_does_not_cover_it() {
        assert!(failures(Fault::DropsTheLastByte).contains(&COVER));
    }

    #[test]
    fn a_shaper_that_never_breaks_is_wider_than_the_width() {
        assert_eq!(failures(Fault::NeverBreaks), vec![FIT]);
    }

    #[test]
    fn a_shaper_that_breaks_with_no_width_is_not_one_line() {
        assert_eq!(failures(Fault::AlwaysBreaks), vec![UNBROKEN]);
    }

    #[test]
    fn a_shaper_whose_kept_lines_break_at_an_old_width_is_not_a_fresh_one() {
        assert!(failures(Fault::RemembersItsFirstWidth).contains(&KEPT));
    }

    #[test]
    fn a_shaper_whose_clusters_are_off_has_glyphs_outside_their_line() {
        assert_eq!(failures(Fault::ShiftsClusters), vec![CLUSTERS]);
    }

    #[test]
    fn a_shaper_with_flat_lines_has_no_heights() {
        assert_eq!(failures(Fault::Flat), vec![HEIGHTS]);
    }

    #[test]
    fn a_shaper_whose_every_spec_is_font_0_does_not_tell_fonts_apart() {
        assert_eq!(failures(Fault::OneFont), vec![FONTS]);
    }

    /// A shaper that is the fake with its font ids changed by `id`, which
    /// is given the spec and the fake's id for it.
    struct Renumbered<F> {
        fake: CellShaper,
        id: F,
    }

    impl<F: Fn(&FontSpec, FontId) -> FontId> Shaper for Renumbered<F> {
        type Shaped = CellLine;

        fn shape(&self, input: &ShapeInput) -> CellLine {
            self.fake.shape(input)
        }

        fn generation(&self) -> u64 {
            0
        }

        fn resolved(&self) -> Arc<[ResolvedFont]> {
            self.fake.resolved()
        }

        fn font(&self, spec: &FontSpec) -> FontId {
            (self.id)(spec, self.fake.font(spec))
        }

        fn metrics(&self, _font: FontId) -> Metrics {
            self.fake.metrics(FontId::default())
        }
    }

    #[test]
    fn a_shaper_that_gives_one_spec_two_ids_does_not_tell_fonts_apart() {
        // The default spec is font 0, and any other gets a new id each
        // time it is asked for.
        let asked = Mutex::new(0);
        let forgetful = Renumbered {
            fake: CellShaper::new(10.0, 16.0),
            id: |spec: &FontSpec, _| {
                if *spec == FontSpec::default() {
                    return FontId(0);
                }
                let mut asked = asked.lock().unwrap();
                *asked += 1;
                FontId(*asked)
            },
        };
        assert_eq!(check(&forgetful), vec![FONTS]);
    }

    #[test]
    fn a_shaper_whose_default_spec_is_not_font_0_fails_the_font_rule() {
        // One id for each spec, each one more than the fake's.
        let shifted = Renumbered {
            fake: CellShaper::new(10.0, 16.0),
            id: |_: &FontSpec, id: FontId| FontId(id.0 + 1),
        };
        assert_eq!(check(&shifted), vec![FONTS]);
    }
}
