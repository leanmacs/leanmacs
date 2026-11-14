//! The shaper: [`ParleyShaper`], and what it keeps of a shaped line,
//! [`ParleyLine`].

use std::borrow::Cow;
use std::collections::HashMap;
use std::ops::Range;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use editor_layout::shaper::{
    FontId, FontRun, FontSpec, Glyph, LineHeight, Metrics, ResolvedFont, ResolvedFontId,
    ShapeInput, ShapedLine, Shaper, Slant, VisualLine,
};
use parley::fontique::SourceCache;
use parley::{
    BaseDirection, Cluster, FontContext, FontFamily, FontFamilyName, FontStyle, FontWeight, Layout,
    LayoutContext, Line, OverflowWrap, Run, StyleProperty, WhiteSpaceCollapse,
};

use crate::fonts::FontSet;

/// Parley's layout of one text. Nothing is painted from it, so its brush,
/// the value Parley carries per style for a renderer, is the unit.
type Laid = Layout<()>;

/// The real shaper, over Parley.
pub struct ParleyShaper {
    /// Everything it holds, behind one lock: Parley builds a layout with
    /// exclusive access to its font context and its scratch space.
    state: Mutex<State>,
}

/// What a [`ParleyShaper`] holds.
struct State {
    /// The fonts, and fontique's cache of the files it has loaded.
    fonts: FontContext,
    /// Parley's scratch space, kept from one layout to the next.
    layouts: LayoutContext<()>,
    /// The default family: what a spec with no family is shaped in, and
    /// the second family a character is looked for in.
    default: String,
    /// The fallback families, in the order a character is looked for in
    /// them after the default family.
    fallbacks: Vec<String>,
    /// The spec of each font asked for, by id: the default spec is font 0.
    specs: Vec<FontSpec>,
    /// The fonts glyphs are drawn in, by resolved id.
    resolved: Arc<[ResolvedFont]>,
    /// The metrics of each font asked about: a space is shaped once for
    /// each.
    metrics: HashMap<FontId, Metrics>,
    /// The generation: how often the fonts were set again.
    generation: u64,
    /// The work done so far.
    counters: ShapeCounters,
}

impl State {
    /// The spec of `font`: the default spec for an id never given.
    fn spec(specs: &[FontSpec], font: FontId) -> &FontSpec {
        usize::try_from(font.0)
            .ok()
            .and_then(|index| specs.get(index))
            .unwrap_or(&specs[0])
    }

    /// Parley's layout of `text` with the font runs `runs`, not yet
    /// broken: the one place a layout is built.
    ///
    /// Every byte is in the font of the run that covers it, and in font 0
    /// where none does. The base direction is left to right whatever the
    /// text starts with, no locale is set, a word wider than the width
    /// breaks inside itself, and spaces at a wrap count toward the width
    /// and wrap.
    ///
    /// **A line is as tall as the fonts on it.** Parley makes every line
    /// at least as tall as the layout's default style, whether or not any
    /// text of the line is in it (the "strut" of CSS). So the default
    /// style of a text is one of no size and no line height, which adds
    /// nothing, and each font is stated over its bytes. An empty text has
    /// no byte to state a font over: its default style is its run's font,
    /// or font 0's with no run, and its one line is that tall.
    fn lay_out(&mut self, text: &str, runs: &[FontRun]) -> Laid {
        let Self {
            fonts,
            layouts,
            default,
            fallbacks,
            specs,
            ..
        } = self;
        let text = &*stand_ins(text);
        let mut builder = layouts.ranged_builder(fonts, text, 1.0, true);
        builder.set_base_direction(BaseDirection::Ltr);
        builder.push_default(StyleProperty::OverflowWrap(OverflowWrap::Anywhere));
        builder.push_default(StyleProperty::WhiteSpaceCollapse(
            WhiteSpaceCollapse::BreakSpaces,
        ));
        if text.is_empty() {
            let font = runs.first().map_or(FontId::default(), |run| run.font);
            for property in properties(Self::spec(specs, font), default, fallbacks) {
                builder.push_default(property);
            }
            return builder.build(text);
        }
        builder.push_default(StyleProperty::FontSize(0.0));
        builder.push_default(StyleProperty::LineHeight(parley::LineHeight::Absolute(0.0)));
        // Font 0 over the whole text, then each run over its bytes: a
        // later statement is over an earlier one.
        let whole = FontRun {
            bytes: 0..text.len(),
            font: FontId::default(),
        };
        let stated = runs.iter().filter(|run| run.font != FontId::default());
        for run in std::iter::once(&whole).chain(stated) {
            let bytes = run.bytes.start.min(text.len())..run.bytes.end.min(text.len());
            if bytes.is_empty() {
                continue;
            }
            for property in properties(Self::spec(specs, run.font), default, fallbacks) {
                builder.push(property, bytes.clone());
            }
        }
        builder.build(text)
    }

    /// Adds to the table each font a run of `layout` is drawn in that is
    /// not yet in it.
    fn describe(&mut self, layout: &Laid) {
        let mut new: Vec<ResolvedFont> = Vec::new();
        for run in layout.lines().flat_map(|line| line.runs()) {
            let known = self.resolved.iter().chain(&new).any(|font| is(font, &run));
            if !known {
                new.push(described(&run));
            }
        }
        if !new.is_empty() {
            self.resolved = self.resolved.iter().cloned().chain(new).collect();
        }
    }
}

/// `text` as it is handed to Parley: each character Parley would break a
/// line at though the port says it is content (a carriage return, U+2028
/// and U+2029; `editor_layout::shaper::ShapeInput::text`) replaced by a
/// stand-in of the same length in bytes, so every offset of the text is
/// an offset of what Parley is handed. A carriage return is a space, and
/// each separator the replacement character, U+FFFD.
///
/// The stand-ins only keep the line whole. What such a character should
/// look like is not decided here.
fn stand_ins(text: &str) -> Cow<'_, str> {
    const BROKEN_AT: [char; 3] = ['\r', '\u{2028}', '\u{2029}'];
    if !text.contains(BROKEN_AT) {
        return Cow::Borrowed(text);
    }
    let handed = text.chars().map(|character| match character {
        // One byte for one byte, and three for three.
        '\r' => ' ',
        '\u{2028}' | '\u{2029}' => '\u{fffd}',
        other => other,
    });
    Cow::Owned(handed.collect())
}

/// `spec` as Parley's style properties: the families a character is looked
/// for in (the spec's own, then `default`, then `fallbacks` in order), the
/// size in pixels, the weight, the style and the line height.
///
/// The matches on [`Slant`] and [`LineHeight`] are exhaustive on purpose:
/// this is where each value of a font attribute of the port is stated to
/// Parley, so a new one must be stated here too.
fn properties<'a>(
    spec: &'a FontSpec,
    default: &'a str,
    fallbacks: &'a [String],
) -> [StyleProperty<'a, ()>; 5] {
    let families: Vec<FontFamilyName<'a>> = spec
        .family
        .iter()
        .map(String::as_str)
        .chain([default])
        .chain(fallbacks.iter().map(String::as_str))
        .map(FontFamilyName::named)
        .collect();
    [
        StyleProperty::FontFamily(FontFamily::List(families.into())),
        StyleProperty::FontSize(spec.size.as_pixels()),
        StyleProperty::FontWeight(FontWeight::new(f32::from(spec.weight.0))),
        StyleProperty::FontStyle(match spec.slant {
            Slant::Upright => FontStyle::Normal,
            Slant::Italic => FontStyle::Italic,
            Slant::Oblique => FontStyle::Oblique(None),
        }),
        StyleProperty::LineHeight(match spec.line_height {
            LineHeight::Multiple(multiple) => {
                parley::LineHeight::MetricsRelative(multiple as f32 / 64.0)
            }
            LineHeight::Pixels(pixels) => parley::LineHeight::Absolute(pixels.as_pixels()),
        }),
    ]
}

/// What placing a cluster's glyphs on a line needs of the cluster:
/// Parley's own, or one written out by hand in a test.
trait Placed {
    /// The byte offset its text starts at.
    fn start(&self) -> usize;
    /// How far it moves the pen.
    fn advance(&self) -> f32;
    /// Whether it is a later character of a ligature. It has no glyph: the
    /// ligature's first character holds the glyph, and the glyph's advance
    /// is shared out among the ligature's clusters.
    fn continues(&self) -> bool;
    /// Its glyphs, each as its id, how far right of the pen and below the
    /// baseline its outline is drawn, and how far it moves the pen.
    fn drawn(&self) -> impl Iterator<Item = (u32, f32, f32, f32)>;
}

impl Placed for Cluster<'_, ()> {
    fn start(&self) -> usize {
        self.text_range().start
    }

    fn advance(&self) -> f32 {
        Cluster::advance(self)
    }

    fn continues(&self) -> bool {
        self.is_ligature_continuation()
    }

    fn drawn(&self) -> impl Iterator<Item = (u32, f32, f32, f32)> {
        self.glyphs()
            .map(|glyph| (glyph.id, glyph.x, glyph.y, glyph.advance))
    }
}

/// Adds to `glyphs` the glyphs of `clusters`, the clusters of one run in
/// the order they are drawn in, each drawn in `font`, from the pen
/// position `x`, and moves `x` past them. `rtl` is whether the run reads
/// right to left.
///
/// A cluster's glyphs start at its left edge, one after another. A
/// ligature's glyph starts at the left edge of the leftmost of its
/// clusters. Left to right that is the cluster that holds the glyph. Right
/// to left the ligature's later characters are drawn first and hold no
/// glyph, so the glyph starts where the first of them did.
fn place<C: Placed>(
    clusters: impl Iterator<Item = C>,
    rtl: bool,
    font: ResolvedFontId,
    x: &mut f32,
    glyphs: &mut Vec<Glyph>,
) {
    // Where a ligature starts whose later characters have been passed and
    // whose glyph is still to come.
    let mut ligature: Option<f32> = None;
    for cluster in clusters {
        if rtl && cluster.continues() {
            ligature.get_or_insert(*x);
        }
        let mut pen = *x;
        for (index, (id, dx, dy, advance)) in cluster.drawn().enumerate() {
            if index == 0 {
                pen = ligature.take().unwrap_or(pen);
            }
            glyphs.push(Glyph {
                id,
                font,
                cluster: cluster.start(),
                x: pen,
                dx,
                dy,
                advance,
            });
            pen += advance;
        }
        *x += cluster.advance();
    }
}

/// Whether `font` is the font `run` is drawn in: the same face of the same
/// file at the same size, with the same variation and the same synthesis.
fn is(font: &ResolvedFont, run: &Run<'_, ()>) -> bool {
    let drawn = run.font();
    let synthesis = run.synthesis();
    font.file == drawn.data.id()
        && font.index == drawn.index
        && font.size == run.font_size()
        && font.embolden == synthesis.embolden()
        && font.skew == synthesis.skew()
        && font
            .coords
            .iter()
            .copied()
            .eq(run.normalized_coords().iter().map(|coord| coord.to_bits()))
}

/// The font `run` is drawn in, described.
fn described(run: &Run<'_, ()>) -> ResolvedFont {
    let drawn = run.font();
    let synthesis = run.synthesis();
    let (data, file) = drawn.data.clone().into_raw_parts();
    ResolvedFont {
        data,
        file,
        index: drawn.index,
        size: run.font_size(),
        coords: run
            .normalized_coords()
            .iter()
            .map(|coord| coord.to_bits())
            .collect(),
        embolden: synthesis.embolden(),
        skew: synthesis.skew(),
    }
}

/// The work a [`ParleyShaper`] has done since it was made, counted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ShapeCounters {
    /// The Parley layouts built by [`Shaper::shape`]: one for each call.
    pub layouts: u64,
    /// The bytes of text in those layouts.
    pub bytes: u64,
}

impl ParleyShaper {
    /// A shaper drawing in the fonts of `fonts`.
    pub fn new(fonts: FontSet) -> Self {
        let FontSet {
            collection,
            default,
            fallbacks,
            ..
        } = fonts;
        Self {
            state: Mutex::new(State {
                fonts: FontContext {
                    collection,
                    source_cache: SourceCache::default(),
                },
                layouts: LayoutContext::new(),
                default,
                fallbacks,
                specs: vec![FontSpec::default()],
                resolved: Arc::from(Vec::new()),
                metrics: HashMap::new(),
                generation: 0,
                counters: ShapeCounters::default(),
            }),
        }
    }

    /// Draws in the fonts of `fonts` from now on. The generation moves on,
    /// whether or not the fonts differ, so layout shapes again what it
    /// kept. The table of resolved fonts starts again from nothing, so a
    /// resolved id of before means nothing now; the metrics are asked of
    /// the new fonts; and the id of every spec stays as it was given.
    ///
    /// A line shaped before still breaks as it was shaped: it holds its
    /// own layout and the table it was shaped under.
    pub fn set_fonts(&self, fonts: FontSet) {
        let FontSet {
            collection,
            default,
            fallbacks,
            ..
        } = fonts;
        let mut state = self.state();
        state.fonts = FontContext {
            collection,
            source_cache: SourceCache::default(),
        };
        // Parley's scratch space is kept: what it resolved of a family is
        // dropped at the start of each layout, and what it keeps of a
        // shaped font is keyed by the file's own number.
        state.default = default;
        state.fallbacks = fallbacks;
        state.resolved = Arc::from(Vec::new());
        state.metrics.clear();
        state.generation += 1;
    }

    /// The work done so far.
    pub fn counters(&self) -> ShapeCounters {
        self.state().counters
    }

    /// What it holds, locked. A poisoned lock is used as it is: a panic
    /// inside Parley leaves tables that are only ever added to.
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// What [`ParleyShaper`] keeps of a shaped line: Parley's layout of it,
/// which breaks again at another width without shaping again.
pub struct ParleyLine {
    /// The layout, behind a lock: Parley breaks a layout in place.
    layout: Mutex<Laid>,
    /// The shaper's table of resolved fonts as it was when the line was
    /// shaped, which holds every font a run of the layout is drawn in.
    /// Breaking reads it and never adds to it.
    fonts: Arc<[ResolvedFont]>,
}

impl ParleyLine {
    /// The id of the font `run` is drawn in.
    fn font_of(&self, run: &Run<'_, ()>) -> ResolvedFontId {
        let index = self.fonts.iter().position(|font| is(font, run));
        ResolvedFontId(
            index
                .and_then(|index| u32::try_from(index).ok())
                .unwrap_or(0),
        )
    }

    /// `line` as the port's visual line: its glyphs in order from its left
    /// edge, each at its pen position, with its cluster's first byte.
    fn visual_line(&self, line: &Line<'_, ()>) -> VisualLine {
        let metrics = line.metrics();
        let mut glyphs = Vec::new();
        let mut x = 0.0;
        for run in line.runs() {
            let font = self.font_of(&run);
            place(
                run.visual_clusters(),
                run.is_rtl(),
                font,
                &mut x,
                &mut glyphs,
            );
        }
        let bytes: Range<usize> = line.text_range();
        VisualLine {
            bytes,
            glyphs,
            width: metrics.advance,
            height: metrics.line_height,
            // Parley's baseline is from the layout's top, and the line's
            // top is its least coordinate down the layout.
            baseline: metrics.baseline - metrics.block_min_coord,
        }
    }
}

impl ShapedLine for ParleyLine {
    fn break_lines(&self, width: Option<f32>) -> Vec<VisualLine> {
        let mut layout = self.layout.lock().unwrap_or_else(PoisonError::into_inner);
        layout.break_all_lines(width);
        layout.lines().map(|line| self.visual_line(&line)).collect()
    }
}

impl Shaper for ParleyShaper {
    type Shaped = ParleyLine;

    fn shape(&self, input: &ShapeInput) -> ParleyLine {
        let mut state = self.state();
        state.counters.layouts += 1;
        state.counters.bytes += input.text.len() as u64;
        let mut layout = state.lay_out(&input.text, &input.runs);
        // Broken once, unbroken, to learn the fonts its runs are drawn in:
        // a break at a width splits runs and never changes their fonts.
        layout.break_all_lines(None);
        state.describe(&layout);
        ParleyLine {
            layout: Mutex::new(layout),
            fonts: Arc::clone(&state.resolved),
        }
    }

    fn generation(&self) -> u64 {
        self.state().generation
    }

    fn resolved(&self) -> Arc<[ResolvedFont]> {
        Arc::clone(&self.state().resolved)
    }

    fn font(&self, spec: &FontSpec) -> FontId {
        let mut state = self.state();
        let index = state
            .specs
            .iter()
            .position(|known| known == spec)
            .unwrap_or_else(|| {
                state.specs.push(spec.clone());
                state.specs.len() - 1
            });
        FontId(u32::try_from(index).unwrap_or(u32::MAX))
    }

    fn metrics(&self, font: FontId) -> Metrics {
        let mut state = self.state();
        if let Some(known) = state.metrics.get(&font) {
            return *known;
        }
        // One space shaped in the font: its advance, and its line's
        // height. It is no line of a text, so it is not counted.
        let mut layout = state.lay_out(" ", &[FontRun { bytes: 0..1, font }]);
        layout.break_all_lines(None);
        let metrics = layout.lines().next().map_or(
            Metrics {
                advance: 0.0,
                line_height: 0.0,
            },
            |line| Metrics {
                advance: line.metrics().advance,
                line_height: line.metrics().line_height,
            },
        );
        state.metrics.insert(font, metrics);
        metrics
    }
}

#[cfg(test)]
mod tests {
    use std::borrow::Cow;

    use editor_layout::shaper::ResolvedFontId;

    use super::{Placed, place, stand_ins};

    #[test]
    fn a_return_and_the_separators_have_stand_ins_of_their_own_length() {
        assert_eq!(stand_ins("a\rb\u{2028}c\u{2029}d"), "a b\u{fffd}c\u{fffd}d");
        // Every offset of the text is an offset of what is handed on.
        for text in ["\r", "\u{2028}", "\u{2029}", "\r\r", "é\u{2028}😀\r"] {
            let handed = stand_ins(text);
            assert_eq!(handed.len(), text.len(), "{text:?}");
            let offsets = |text: &str| text.char_indices().map(|(at, _)| at).collect::<Vec<_>>();
            assert_eq!(offsets(&handed), offsets(text), "{text:?}");
            assert!(!handed.contains(['\r', '\u{2028}', '\u{2029}']), "{text:?}");
        }
    }

    #[test]
    fn a_text_with_none_of_them_is_handed_on_as_it_is() {
        // Other characters a paragraph layout treats specially are left:
        // Parley breaks at none of them.
        for text in [
            "",
            "plain text",
            "a\u{85}b\u{b}c\u{c}d",
            "x\u{fffd}y\u{fffc}z",
        ] {
            assert!(matches!(stand_ins(text), Cow::Borrowed(same) if same == text));
        }
    }

    /// A cluster written out by hand: where it starts, how far it moves
    /// the pen, whether it is a later character of a ligature, and the
    /// advance of each of its glyphs. A glyph's id is its cluster's start.
    struct Written {
        start: usize,
        advance: f32,
        continues: bool,
        glyphs: Vec<f32>,
    }

    impl Placed for Written {
        fn start(&self) -> usize {
            self.start
        }

        fn advance(&self) -> f32 {
            self.advance
        }

        fn continues(&self) -> bool {
            self.continues
        }

        fn drawn(&self) -> impl Iterator<Item = (u32, f32, f32, f32)> {
            let id = u32::try_from(self.start).unwrap();
            self.glyphs
                .iter()
                .map(move |advance| (id, 0.0, 0.0, *advance))
        }
    }

    /// A cluster of one character and the glyphs `glyphs`, as wide as
    /// they are.
    fn cluster(start: usize, glyphs: &[f32]) -> Written {
        Written {
            start,
            advance: glyphs.iter().sum(),
            continues: false,
            glyphs: glyphs.to_vec(),
        }
    }

    /// The two clusters of a ligature of two characters at `start` and
    /// `start + 1` whose one glyph is `advance` across: the first holds
    /// the glyph, the second none, and each moves the pen half the way.
    fn ligature(start: usize, advance: f32) -> [Written; 2] {
        let half = |start: usize, continues: bool, glyphs: Vec<f32>| Written {
            start,
            advance: advance / 2.0,
            continues,
            glyphs,
        };
        [
            half(start, false, vec![advance]),
            half(start + 1, true, vec![]),
        ]
    }

    /// The cluster, the x and the advance of each glyph `clusters` are
    /// placed as from x 100, and the x after them.
    fn placed(clusters: Vec<Written>, rtl: bool) -> (Vec<(usize, f32, f32)>, f32) {
        let mut glyphs = Vec::new();
        let mut x = 100.0;
        place(
            clusters.into_iter(),
            rtl,
            ResolvedFontId(3),
            &mut x,
            &mut glyphs,
        );
        assert!(glyphs.iter().all(|glyph| glyph.font == ResolvedFontId(3)));
        let glyphs = glyphs
            .iter()
            .map(|glyph| (glyph.cluster, glyph.x, glyph.advance))
            .collect();
        (glyphs, x)
    }

    #[test]
    fn a_clusters_glyphs_start_at_its_left_edge_one_after_another() {
        // A letter, a letter with a mark of no advance, and a letter.
        let clusters = vec![
            cluster(0, &[10.0]),
            cluster(1, &[8.0, 0.0]),
            cluster(4, &[6.0]),
        ];
        let (glyphs, x) = placed(clusters, false);
        assert_eq!(
            glyphs,
            vec![
                (0, 100.0, 10.0),
                (1, 110.0, 8.0),
                (1, 118.0, 0.0),
                (4, 118.0, 6.0)
            ]
        );
        assert_eq!(x, 124.0);
    }

    #[test]
    fn a_ligatures_glyph_starts_at_the_left_edge_of_its_leftmost_cluster() {
        // Left to right, the ligature's first character is the leftmost:
        // `a`, the ligature, `b`.
        let [first, later] = ligature(1, 12.0);
        let clusters = vec![cluster(0, &[10.0]), first, later, cluster(3, &[5.0])];
        let (glyphs, x) = placed(clusters, false);
        let expected = vec![(0, 100.0, 10.0), (1, 110.0, 12.0), (3, 122.0, 5.0)];
        assert_eq!(glyphs, expected);
        assert_eq!(x, 127.0);
        // Right to left, the clusters are drawn in the reverse of their
        // order in the text, so the ligature's later character comes
        // first, with no glyph: the glyph, which the first character
        // holds, starts where that later character does.
        let [first, later] = ligature(1, 12.0);
        let clusters = vec![cluster(3, &[5.0]), later, first, cluster(0, &[10.0])];
        let (glyphs, x) = placed(clusters, true);
        let expected = vec![(3, 100.0, 5.0), (1, 105.0, 12.0), (0, 117.0, 10.0)];
        assert_eq!(glyphs, expected);
        assert_eq!(x, 127.0);
    }
}
