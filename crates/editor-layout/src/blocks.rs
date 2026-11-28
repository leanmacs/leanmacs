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
//!
//! **Gutter marks** ([`GutterMark`]) are laid out through the same store:
//! a mark is the block of its text with two decorations over the whole of
//! it, `gutter` and then its own face ([`mark_block`]), so it is keyed by
//! its text and its face, and two marks of one text and face share one
//! entry and one row hash. Only a mark's first visual line is drawn.
//!
//! **Fold placeholders** ([`Fold`]) are laid out through the same store
//! too, unbroken: the first line of a fold's text, in its decorations over
//! the default face, as one visual line whatever the view's width
//! ([`ViewFolds`]). A placeholder is keyed apart from a block of the same
//! text and decorations, so the two never share an entry, and one shown
//! again is not shaped again.

use std::collections::{BTreeMap, HashMap};
use std::hash::{DefaultHasher, Hash, Hasher};
use std::ops::Range;
use std::sync::Arc;

use editor_text::{Snapshot, Text};

use crate::cache::{Counters, TextState};
use crate::decoration::{DecorationSource, FaceSpanSource, Span, Styles, fonts_of};
use crate::face::{FaceId, Paint};
use crate::folds::FoldSnapshot;
use crate::frame::paint_line;
use crate::query::Beside;
use crate::query::{Shown, Walker};
use crate::scene::{Block, Decoration, Fold, GutterMark};
use crate::shaper::{FontId, Shaper, VisualLine};
use crate::tabs::boundary_at_or_before;
use crate::wrap::Outcome;

/// Which block: a hash of its text and its decorations.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct BlockKey(u64);

impl BlockKey {
    /// The key of `block`. Where it is drawn is not in it.
    pub(crate) fn of(block: &Block) -> Self {
        Self::tagged(block, false)
    }

    /// The key of `fold`'s placeholder ([`placeholder_block`]), laid out
    /// unbroken.
    pub(crate) fn placeholder(fold: &Fold) -> Self {
        Self::tagged(&placeholder_block(fold), true)
    }

    /// The key of `block` laid out unbroken, as a fold's placeholder, or
    /// at a width, as a block or a mark.
    fn tagged(block: &Block, unbroken: bool) -> Self {
        let mut hasher = DefaultHasher::new();
        unbroken.hash(&mut hasher);
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
    /// of its text, with their faces interned), top to bottom, at the
    /// view's text width.
    fn lay(&mut self, block: &Block, spans: &[(Range<usize>, FaceId)]) -> Vec<BlockLine> {
        self.lay_at(block, spans, Some(self.width))
    }

    /// The visual lines of `block` as [`BlockLayout::lay`] gives them,
    /// broken at `width`, or unbroken with none.
    fn lay_at(
        &mut self,
        block: &Block,
        spans: &[(Range<usize>, FaceId)],
        width: Option<f32>,
    ) -> Vec<BlockLine> {
        let tab_width = self.tab_width;
        let key = BlockKey::tagged(block, width.is_none());
        let state = self.store.entry(key).or_insert_with(|| {
            let snapshot = Text::from(block.text.as_str()).snapshot();
            TextState::fresh(&snapshot, tab_width, width)
        });
        state.wrap.set_width(width);
        let none = FoldSnapshot::none(state.wrap.tabs().buffer());
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
                folds: &none,
                base,
                fonts: &fonts,
                stops: &|_| Vec::new(),
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
                    let painted = paint_line(
                        &entry, at.line, &line, row_start, &snapshot, &sources, styles, shaper,
                    );
                    lines.push(BlockLine {
                        line,
                        bytes: range.start..range.stop,
                        runs: painted.runs,
                        hash: painted.hash,
                    });
                }
                visual = walker.next(at);
            }
        }
        self.counters.add(&seen);
        lines
    }
}

/// The face every gutter mark is drawn over, under its own.
pub(crate) const GUTTER_FACE: &str = "gutter";

/// The block `mark`'s text is laid out as: its text, in `gutter` and then
/// in its face over the whole of it.
pub(crate) fn mark_block(mark: &GutterMark) -> Block {
    let whole = |face: &str| Decoration {
        start: 0,
        stop: mark.text.len(),
        face: face.to_owned(),
    };
    Block {
        before: 0,
        text: mark.text.clone(),
        decorations: vec![whole(GUTTER_FACE), whole(&mark.face)],
    }
}

/// A view's gutter marks for one frame: the buffer rows each covers, and
/// its text laid out when it is first drawn.
pub(crate) struct ViewMarks {
    /// Each mark as the block its text is laid out as.
    blocks: Vec<Block>,
    /// Each block's decorations, their faces interned.
    spans: Vec<Vec<(Range<usize>, FaceId)>>,
    /// The buffer rows each mark is drawn beside, from the first to the
    /// last, both included.
    rows: Vec<(usize, usize)>,
    /// The first line of each mark laid out so far.
    laid: HashMap<usize, Option<BlockLine>>,
}

impl ViewMarks {
    /// `marks` over `snapshot`, the view's text, their faces interned into
    /// `styles`. A mark covers each row its range has a byte in, or the
    /// row that holds its start when the range is empty; its offsets are
    /// moved back to a character boundary, and past the end to the end.
    pub(crate) fn new(marks: &[GutterMark], snapshot: &Snapshot, styles: &mut Styles) -> Self {
        let blocks: Vec<Block> = marks.iter().map(mark_block).collect();
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
        let row_of = |offset| {
            snapshot
                .offset_to_point(boundary_at_or_before(snapshot, offset))
                .map_or(0, |point| point.row)
        };
        let rows = marks
            .iter()
            .map(|mark| {
                let start = boundary_at_or_before(snapshot, mark.start);
                let stop = boundary_at_or_before(snapshot, mark.stop).max(start);
                let last = if stop > start { stop - 1 } else { start };
                (row_of(start), row_of(last))
            })
            .collect();
        Self {
            blocks,
            spans,
            rows,
            laid: HashMap::new(),
        }
    }

    /// The marks drawn beside buffer row `row`, by index, in the view's
    /// order.
    pub(crate) fn on(&self, row: usize) -> Vec<usize> {
        self.rows
            .iter()
            .enumerate()
            .filter(|(_, (first, last))| (*first..=*last).contains(&row))
            .map(|(index, _)| index)
            .collect()
    }

    /// The first line of mark `mark`, laid out by `layout` when it is first
    /// asked for; `None` for a mark of no text.
    pub(crate) fn line<S: Shaper>(
        &mut self,
        mark: usize,
        layout: &mut BlockLayout<'_, S>,
    ) -> Option<&BlockLine> {
        self.laid
            .entry(mark)
            .or_insert_with(|| {
                layout
                    .lay(&self.blocks[mark], &self.spans[mark])
                    .into_iter()
                    .next()
            })
            .as_ref()
    }
}

/// The block `fold`'s placeholder is laid out as: the first line of its
/// text, without a carriage return before the line feed, in its
/// decorations.
pub(crate) fn placeholder_block(fold: &Fold) -> Block {
    let line = fold.text.split('\n').next().unwrap_or_default();
    let line = if line.len() < fold.text.len() {
        line.strip_suffix('\r').unwrap_or(line)
    } else {
        line
    };
    Block {
        before: 0,
        text: line.to_owned(),
        decorations: fold.decorations.clone(),
    }
}

/// A view's folds for one frame or query: each placeholder laid out when
/// the walk first reaches it (module docs, "Fold placeholders").
pub(crate) struct ViewFolds {
    /// Each fold's placeholder as the block its text is laid out as: the
    /// first line of its text, and its decorations.
    blocks: Vec<Block>,
    /// Each block's decorations, their faces interned.
    spans: Vec<Vec<(Range<usize>, FaceId)>>,
    /// The placeholder line of each fold laid out so far.
    laid: HashMap<usize, Option<BlockLine>>,
}

impl ViewFolds {
    /// The placeholders of `folds`, their faces interned into `styles`.
    pub(crate) fn new(folds: &[Fold], styles: &mut Styles) -> Self {
        let blocks: Vec<Block> = folds.iter().map(placeholder_block).collect();
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
        Self {
            blocks,
            spans,
            laid: HashMap::new(),
        }
    }

    /// The placeholder line of fold `fold`, laid out unbroken by `layout`
    /// when it is first asked for.
    pub(crate) fn line<S: Shaper>(
        &mut self,
        fold: usize,
        layout: &mut BlockLayout<'_, S>,
    ) -> Option<&BlockLine> {
        let (blocks, spans) = (&self.blocks, &self.spans);
        self.laid
            .entry(fold)
            .or_insert_with(|| {
                let block = blocks.get(fold)?;
                layout.lay_at(block, &spans[fold], None).into_iter().next()
            })
            .as_ref()
    }
}

/// What a walk of a view's text is handed beside it: its blocks and its
/// fold placeholders, laid out through one block layout.
pub(crate) struct ViewBeside<'r, 'a, 'l, S: Shaper> {
    /// The view's blocks.
    pub blocks: &'r mut ViewBlocks<'a>,
    /// The view's fold placeholders.
    pub folds: &'r mut ViewFolds,
    /// What both are laid out with.
    pub layout: &'r mut BlockLayout<'l, S>,
}

impl<S: Shaper> Beside for ViewBeside<'_, '_, '_, S> {
    fn above(&mut self, row: usize) -> Vec<Shown> {
        self.blocks.above(row, self.layout)
    }

    fn placeholder(&mut self, fold: usize) -> f32 {
        self.folds
            .line(fold, self.layout)
            .map_or(0.0, |laid| laid.line.height)
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
