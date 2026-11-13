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
//! bidirectional text. They use only the default font, [`FontId`] 0, which
//! every adapter has.

use super::{FontId, FontRun, ShapeInput, ShapedLine, Shaper, VisualLine};

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

/// Every property, by name.
pub const PROPERTIES: [&str; 6] = [COVER, FIT, UNBROKEN, KEPT, CLUSTERS, HEIGHTS];

/// The texts the properties are run over: empty, one character, a long
/// run of one script, characters of two to four bytes, and words with
/// spaces.
pub fn texts() -> Vec<&'static str> {
    vec![
        "",
        "a",
        "abcdefghijklmnopqrstuvwxyz",
        "aé😀b€c\u{10dc80}",
        "one two three four five six seven",
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
    let metrics = shaper.metrics();
    if !(metrics.line_height > 0.0 && metrics.advance > 0.0) {
        failed[5] = true;
    }
    for text in texts() {
        let input = ShapeInput {
            text: text.to_owned(),
            runs: vec![FontRun {
                bytes: 0..text.len(),
                font: FontId::default(),
            }],
        };
        let kept = shaper.shape(&input);
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
            // Broken at every other width first, then at this one.
            for other in widths() {
                kept.break_lines(other);
                failed[3] |= kept.break_lines(width) != shaper.shape(&input).break_lines(width);
            }
        }
    }
    PROPERTIES
        .iter()
        .zip(failed)
        .filter_map(|(name, failed)| failed.then_some(*name))
        .collect()
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
    use std::sync::Mutex;

    use super::{CLUSTERS, COVER, FIT, HEIGHTS, KEPT, UNBROKEN, check};
    use crate::shaper::fake::{CellLine, CellShaper};
    use crate::shaper::{Metrics, ShapeInput, ShapedLine, Shaper, VisualLine};

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
    }

    /// A shaper that is the fake with one fault.
    struct Wrong {
        fault: Fault,
        fake: CellShaper,
    }

    /// What [`Wrong`] keeps.
    struct WrongLine {
        fault: Fault,
        line: CellLine,
        first: Mutex<Option<Option<f32>>>,
    }

    impl ShapedLine for WrongLine {
        fn break_lines(&self, width: Option<f32>) -> Vec<VisualLine> {
            let width = match self.fault {
                Fault::NeverBreaks => None,
                Fault::AlwaysBreaks => Some(0.0),
                Fault::RemembersItsFirstWidth => *self.first.lock().unwrap().get_or_insert(width),
                _ => width,
            };
            let mut lines = self.line.break_lines(width);
            for line in &mut lines {
                match self.fault {
                    Fault::ShiftsClusters => {
                        for glyph in &mut line.glyphs {
                            glyph.cluster += 1;
                        }
                    }
                    Fault::Flat => line.height = 0.0,
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
            WrongLine {
                fault: self.fault,
                line: self.fake.shape(input),
                first: Mutex::new(None),
            }
        }

        fn generation(&self) -> u64 {
            0
        }

        fn metrics(&self) -> Metrics {
            self.fake.metrics()
        }
    }

    /// The properties the fake with `fault` fails.
    fn failures(fault: Fault) -> Vec<&'static str> {
        check(&Wrong {
            fault,
            fake: CellShaper::new(10.0, 16.0),
        })
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
}
