//! A scripted shaper, for this crate's own tests of what the fake never
//! produces: a glyph drawn off its pen position, glyphs out of cluster
//! order, a glyph that draws two characters, a cluster of two glyphs.
//!
//! A [`ScriptedShaper`] is the fake ([`CellShaper`]) but for the texts it
//! was given a script for: such a text is shaped to the visual lines of
//! its script, as written, at every width. Fonts, metrics and the
//! generation are the fake's.

use std::collections::HashMap;
use std::ops::Range;
use std::sync::Arc;

use super::fake::{CellLine, CellShaper};
use super::{
    FontId, FontSpec, Glyph, Metrics, ResolvedFont, ResolvedFontId, ShapeInput, ShapedLine, Shaper,
    VisualLine, Widths,
};

/// The fake, but for the texts it has a script for.
pub(crate) struct ScriptedShaper {
    /// What shapes every other text.
    fake: CellShaper,
    /// The visual lines of each scripted text.
    scripts: HashMap<String, Vec<VisualLine>>,
}

impl ScriptedShaper {
    /// A shaper that is the fake on cells `advance` by `line_height`, with
    /// no script.
    pub(crate) fn new(advance: f32, line_height: f32) -> Self {
        Self {
            fake: CellShaper::new(advance, line_height),
            scripts: HashMap::new(),
        }
    }

    /// This shaper with `text` shaped to `lines`, at every width.
    #[must_use]
    pub(crate) fn with(mut self, text: &str, lines: Vec<VisualLine>) -> Self {
        self.scripts.insert(text.to_owned(), lines);
        self
    }
}

/// The glyph of `character` for the cluster at byte `cluster`, at `x` and
/// `advance` across, drawn in the default font and with no offset: the
/// fake's glyph, placed by hand.
pub(crate) fn glyph(character: char, cluster: usize, x: f32, advance: f32) -> Glyph {
    Glyph {
        id: u32::from(character),
        font: ResolvedFontId::default(),
        cluster,
        x,
        dx: 0.0,
        dy: 0.0,
        advance,
    }
}

/// The visual line of `glyphs` over `bytes`, 16 pixels tall with its
/// baseline at 12, as wide as its glyphs reach.
pub(crate) fn line(bytes: Range<usize>, glyphs: Vec<Glyph>) -> VisualLine {
    let width = glyphs
        .iter()
        .map(|glyph| glyph.x + glyph.advance)
        .fold(0.0, f32::max);
    VisualLine {
        bytes,
        glyphs,
        width,
        height: 16.0,
        baseline: 12.0,
    }
}

/// What [`ScriptedShaper`] keeps of a shaped line.
pub(crate) enum ScriptedLine {
    /// The lines of a script.
    Scripted(Vec<VisualLine>),
    /// The fake's line.
    Cells(CellLine),
}

impl ShapedLine for ScriptedLine {
    fn break_lines_in(&self, widths: Widths) -> Vec<VisualLine> {
        match self {
            Self::Scripted(lines) => lines.clone(),
            Self::Cells(line) => line.break_lines_in(widths),
        }
    }
}

impl Shaper for ScriptedShaper {
    type Shaped = ScriptedLine;

    fn shape(&self, input: &ShapeInput) -> ScriptedLine {
        match self.scripts.get(&input.text) {
            Some(lines) => ScriptedLine::Scripted(lines.clone()),
            None => ScriptedLine::Cells(self.fake.shape(input)),
        }
    }

    fn generation(&self) -> u64 {
        self.fake.generation()
    }

    fn resolved(&self) -> Arc<[ResolvedFont]> {
        self.fake.resolved()
    }

    fn font(&self, spec: &FontSpec) -> FontId {
        self.fake.font(spec)
    }

    fn metrics(&self, font: FontId) -> Metrics {
        self.fake.metrics(font)
    }
}
