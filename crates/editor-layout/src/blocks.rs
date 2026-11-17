//! Laying out a view's blocks ([`Block`]; [`query`](crate::query),
//! "Blocks"): each a small text of its own, through the same wrap layer,
//! line store and styles a view's text uses, at the view's text width.
//!
//! A block's text is `Text::from(block.text)`. Its only decoration source
//! is its own decorations, interned into the layout's styles and drawn
//! through a [`FaceSpanSource`] over the default face, so a face that
//! sets a font shapes the block in that font. It has no selection, no
//! cursor and no text spans.
//!
//! **The block store** is a map of its own, apart from the texts, so a
//! block's key never meets a document's [`TextKey`](crate::scene::TextKey).
//! A block is keyed by a hash of its text and its decorations, so two
//! views that show the same header share one entry. A frame keeps the
//! entries of the blocks some view of it names and drops the rest, as it
//! drops the texts no view names; a block laid out by a query and named
//! by no view of the next frame is dropped at that frame. A block's
//! shaping is counted as a text row's ([`Counters`]).
//!
//! Blocks never enter a text's wrap layer: what layout keeps of a text is
//! unchanged by them, and they are matched to the text's rows afresh in
//! each frame and query, from their `before`.

use std::collections::{BTreeMap, HashMap};
use std::hash::{DefaultHasher, Hash, Hasher};
use std::ops::Range;
use std::sync::Arc;

use editor_text::{Snapshot, Text};

use crate::cache::{Counters, TextState};
use crate::decoration::{DecorationSource, FaceSpanSource, Span, Styles, fonts_of, merge};
use crate::face::{FaceId, Paint};
use crate::frame::hash;
use crate::query::{Shown, Walker};
use crate::scene::Block;
use crate::shaper::{FontId, Shaper, VisualLine};
use crate::tabs::boundary_at_or_before;
use crate::wrap::Outcome;

/// Which block: a hash of its text and its decorations.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct BlockKey(u64);

impl BlockKey {
    /// The key of `block`. Where it is drawn is not in it.
    pub(crate) fn of(block: &Block) -> Self {
        let mut hasher = DefaultHasher::new();
        block.text.hash(&mut hasher);
        for decoration in &block.decorations {
            (decoration.start, decoration.stop, &decoration.face).hash(&mut hasher);
        }
        Self(hasher.finish())
    }
}

/// What layout keeps of the blocks, by key.
pub(crate) type Blocks<L> = HashMap<BlockKey, TextState<L>>;

/// One visual line of a block, laid out and painted.
#[derive(Debug, Clone)]
pub(crate) struct BlockLine {
    /// Its glyphs, as the block's line store holds them.
    pub line: Arc<VisualLine>,
    /// Its bytes in the block's text, without its line break.
    pub bytes: Range<usize>,
    /// Its runs, as a text row's are.
    pub runs: Vec<(Range<usize>, Paint)>,
    /// Its content hash, as a text row's is.
    pub hash: u64,
}

/// What a block is laid out with: the store, the shaper, the styles and
/// the width, and the counters its shaping is counted in.
pub(crate) struct BlockLayout<'a, S: Shaper> {
    /// What is kept of each block.
    pub store: &'a mut Blocks<S::Shaped>,
    /// The shaper.
    pub shaper: &'a S,
    /// The styles, the block's faces already interned.
    pub styles: &'a Styles,
    /// The base font.
    pub base: FontId,
    /// The tab width, in columns.
    pub tab_width: usize,
    /// The width it wraps at: the view's text width.
    pub width: f32,
    /// The work done.
    pub counters: &'a mut Counters,
}

impl<S: Shaper> BlockLayout<'_, S> {
    /// The visual lines of `block`, whose decorations are `spans` (bytes
    /// of its text, with their faces interned), top to bottom.
    fn lay(&mut self, block: &Block, spans: &[(Range<usize>, FaceId)]) -> Vec<BlockLine> {
        let (tab_width, width) = (self.tab_width, self.width);
        let state = self.store.entry(BlockKey::of(block)).or_insert_with(|| {
            let snapshot = Text::from(block.text.as_str()).snapshot();
            TextState::fresh(&snapshot, tab_width, Some(width))
        });
        state.wrap.set_width(Some(width));
        let snapshot = state.wrap.tabs().buffer().clone();
        let source = FaceSpanSource::new(
            spans
                .iter()
                .map(|(bytes, face)| {
                    let start = boundary_at_or_before(&snapshot, bytes.start);
                    Span {
                        bytes: start..boundary_at_or_before(&snapshot, bytes.end).max(start),
                        face: *face,
                    }
                })
                .collect(),
        );
        let sources: [&dyn DecorationSource; 1] = [&source];
        let (styles, shaper, base) = (self.styles, self.shaper, self.base);
        let fonts = |bytes| fonts_of(&sources, &snapshot, bytes, styles, shaper, base);
        let mut seen: HashMap<(usize, usize), Outcome> = HashMap::new();
        let mut lines = Vec::new();
        {
            let mut walker = Walker {
                shaper,
                wrap: &mut state.wrap,
                base,
                fonts: &fonts,
                outcome: &mut |row, segment, outcome| {
                    seen.entry((row, segment)).or_insert(outcome);
                },
            };
            let mut visual = walker.locate(0).ok().map(|(visual, _)| visual);
            while let Some(at) = visual {
                if let Some(entry) = walker.entry(at.row, at.segment)
                    && let Some(line) = entry.lines().get(at.line).cloned()
                {
                    let range = walker.range(at);
                    let row_start = snapshot.row_range(at.row).map_or(0, |row| row.start);
                    let drawn = entry.drawn_bytes(at.line).unwrap_or(0..0);
                    let mut found = Vec::new();
                    source.spans(
                        &snapshot,
                        row_start + drawn.start..row_start + drawn.end,
                        &mut found,
                    );
                    let columns = line.bytes.clone();
                    let column = |offset: usize| {
                        entry
                            .column(offset - row_start)
                            .clamp(columns.start, columns.end)
                            - columns.start
                    };
                    let on_row: Vec<Span> = found
                        .iter()
                        .filter_map(|span| {
                            let covered = column(span.bytes.start)..column(span.bytes.end);
                            (!covered.is_empty()).then_some(Span {
                                bytes: covered,
                                face: span.face,
                            })
                        })
                        .collect();
                    let mut runs: Vec<(Range<usize>, Paint)> = Vec::new();
                    for run in merge(0..columns.len(), &on_row) {
                        let paint = styles.style(shaper, &run.faces).paint;
                        match runs.last_mut() {
                            Some((bytes, last)) if *last == paint => bytes.end = run.bytes.end,
                            _ => runs.push((run.bytes, paint)),
                        }
                    }
                    lines.push(BlockLine {
                        hash: hash(&line, &runs),
                        line,
                        bytes: range.start..range.stop,
                        runs,
                    });
                }
                visual = walker.next(at);
            }
        }
        self.counters.add(&seen);
        lines
    }
}

/// A view's blocks for one frame or query: grouped by the buffer row of
/// the view's text each is drawn above, each laid out when the walk first
/// reaches it.
pub(crate) struct ViewBlocks<'a> {
    /// The blocks, as the view lists them.
    blocks: &'a [Block],
    /// Each block's decorations, their faces interned.
    spans: Vec<Vec<(Range<usize>, FaceId)>>,
    /// The blocks before each row, by index, in the view's order.
    by_row: BTreeMap<usize, Vec<usize>>,
    /// The lines of each block laid out so far.
    laid: HashMap<usize, Vec<BlockLine>>,
}

impl<'a> ViewBlocks<'a> {
    /// `blocks` over `snapshot`, the view's text, their faces interned
    /// into `styles`.
    pub(crate) fn new(blocks: &'a [Block], snapshot: &Snapshot, styles: &mut Styles) -> Self {
        let spans = blocks
            .iter()
            .map(|block| {
                block
                    .decorations
                    .iter()
                    .map(|decoration| {
                        (
                            decoration.start..decoration.stop,
                            styles.intern(&decoration.face),
                        )
                    })
                    .collect()
            })
            .collect();
        let mut by_row: BTreeMap<usize, Vec<usize>> = BTreeMap::new();
        for (index, block) in blocks.iter().enumerate() {
            let before = boundary_at_or_before(snapshot, block.before);
            let row = snapshot
                .offset_to_point(before)
                .map_or(0, |point| point.row);
            by_row.entry(row).or_default().push(index);
        }
        Self {
            blocks,
            spans,
            by_row,
            laid: HashMap::new(),
        }
    }

    /// The lines of the blocks before buffer row `row`, in order, each
    /// laid out by `layout` when it is first asked for.
    pub(crate) fn above<S: Shaper>(
        &mut self,
        row: usize,
        layout: &mut BlockLayout<'_, S>,
    ) -> Vec<Shown> {
        let Some(indexes) = self.by_row.get(&row) else {
            return Vec::new();
        };
        let mut shown = Vec::new();
        for &block in indexes {
            let lines = self
                .laid
                .entry(block)
                .or_insert_with(|| layout.lay(&self.blocks[block], &self.spans[block]));
            shown.extend(lines.iter().enumerate().map(|(line, laid)| Shown::Block {
                block,
                line,
                height: laid.line.height,
            }));
        }
        shown
    }

    /// The `line`th line of block `block`, once it has been laid out.
    pub(crate) fn line(&self, block: usize, line: usize) -> Option<&BlockLine> {
        self.laid.get(&block)?.get(line)
    }
}
