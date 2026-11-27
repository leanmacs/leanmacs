//! The wrap layer: each segment of the tab layer shaped and broken into
//! visual lines at the view's width.
//!
//! Its snapshot is the per-text line store: the segments laid out so far,
//! as immutable [`LineEntry`] values keyed by row and segment. A segment is
//! laid out on demand ([`WrapLayer::entry`]) and kept; a width change
//! breaks the kept shaped line again without shaping it; spans that change
//! no font change nothing. Align-to stops that cut the segment as it was
//! cut, at other xs, break and place it again without shaping it; stops
//! that cut it otherwise shape it again. An edit of the layer below moves the entries
//! ([`Layer::sync`]): those of the rows it touched are dropped and those
//! after it move by the rows it added or removed, untouched.
//!
//! A point of this layer is a [`WrapPoint`]: a row, a segment, a visual
//! line of the segment, and an x on it. A conversion answers only for a
//! segment that is laid out.

use std::collections::BTreeMap;
use std::ops::Range;
use std::sync::Arc;

use crate::layer::{Bias, Layer, LayerEdit};
use crate::line::{LineEntry, Source, lay_out};
use crate::shaper::{FontId, ShapedLine, Shaper};
use crate::tabs::{TabPoint, TabSnapshot, row_content, segment_count};

/// A point of the wrap layer.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WrapPoint {
    /// The buffer row.
    pub row: usize,
    /// The segment of the row.
    pub segment: usize,
    /// The visual line of the segment.
    pub visual: usize,
    /// The x, in pixels from the visual line's left edge.
    pub x: f32,
}

/// How [`WrapLayer::entry`] got the entry it gave.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// The segment was shaped (and broken).
    Shaped,
    /// A kept shaped line was broken again at another width.
    Broken,
    /// A kept entry was used as it was.
    Reused,
}

/// The wrap layer: the segments laid out so far, at one width.
pub struct WrapLayer<L> {
    /// The tab layer's snapshot it was last synced to.
    tabs: TabSnapshot,
    /// The width it breaks at; `None` breaks nothing.
    width: Option<f32>,
    /// The segments laid out, by row and segment.
    entries: BTreeMap<(usize, usize), Arc<LineEntry<L>>>,
}

impl<L: ShapedLine> WrapLayer<L> {
    /// A wrap layer over `tabs` breaking at `width`, with nothing laid
    /// out.
    pub fn new(tabs: TabSnapshot, width: Option<f32>) -> Self {
        Self {
            tabs,
            width,
            entries: BTreeMap::new(),
        }
    }

    /// The tab layer's snapshot it was last synced to.
    pub fn tabs(&self) -> &TabSnapshot {
        &self.tabs
    }

    /// The width it breaks at.
    pub fn width(&self) -> Option<f32> {
        self.width
    }

    /// Breaks at `width` from now on. Each kept entry is broken again the
    /// next time it is asked for.
    pub fn set_width(&mut self, width: Option<f32>) {
        self.width = width;
    }

    /// How many segments are laid out.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether no segment is laid out.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// The entry laid out for `row`'s `segment`, if there is one, as it is.
    pub fn kept(&self, row: usize, segment: usize) -> Option<&Arc<LineEntry<L>>> {
        self.entries.get(&(row, segment))
    }

    /// Drops every entry whose row is not in `keep`.
    pub fn retain_rows(&mut self, keep: impl Fn(usize) -> bool) {
        self.entries.retain(|&(row, _), _| keep(row));
    }

    /// Drops every entry.
    pub fn clear(&mut self) {
        self.entries.clear();
    }

    /// `row`'s `segment` laid out at the layer's width with the spans
    /// `fonts` (bytes relative to the segment's start) over the base font
    /// `base` and the align-to stops `stops` (as
    /// [`Source::stops`](crate::line::Source::stops)), and how it was got:
    /// the kept entry if it was shaped with the same font runs and cut at
    /// the same columns under `shaper`'s generation, and broken at this
    /// width with its cells at the same xs; broken again if only the width
    /// or the xs differ; shaped otherwise. `None` when the text has no
    /// such segment.
    pub fn entry<S: Shaper<Shaped = L>>(
        &mut self,
        shaper: &S,
        row: usize,
        segment: usize,
        fonts: &[(Range<usize>, FontId)],
        base: FontId,
        stops: &[(usize, f32)],
    ) -> Option<(Arc<LineEntry<L>>, Outcome)> {
        let generation = shaper.generation();
        if let Some(kept) = self.entries.get(&(row, segment))
            && kept.generation() == generation
            && kept.shaped_with(fonts, base, stops)
        {
            if kept.width() == self.width && kept.placed_at(stops) {
                return Some((Arc::clone(kept), Outcome::Reused));
            }
            let entry = Arc::new(kept.rebreak_with(self.width, stops));
            self.entries.insert((row, segment), Arc::clone(&entry));
            return Some((entry, Outcome::Broken));
        }
        let content = row_content(self.tabs.buffer(), row)?;
        let last = segment + 1 == segment_count(self.tabs.buffer(), &content);
        let (bytes, expanded) = self.tabs.segment(row, segment)?;
        let relative = bytes.start - content.start..bytes.end - content.start;
        let entry = Arc::new(lay_out(
            shaper,
            Source {
                bytes: relative,
                expanded,
                last,
                fonts,
                base,
                stops,
            },
            self.width,
        ));
        self.entries.insert((row, segment), Arc::clone(&entry));
        Some((entry, Outcome::Shaped))
    }

    /// How many segments `row` is cut into. `None` when the text has no
    /// such row.
    pub fn segments(&self, row: usize) -> Option<usize> {
        let content = row_content(self.tabs.buffer(), row)?;
        Some(segment_count(self.tabs.buffer(), &content))
    }
}

impl<L: ShapedLine> Layer for WrapLayer<L> {
    type Below = TabSnapshot;
    type BelowPoint = TabPoint;
    type Snapshot = ();
    type Point = WrapPoint;

    /// Moves the entries through `edits`: the rows an edit touched are
    /// dropped, and the rows after it move by the rows it added or
    /// removed. Its edits are the rows whose visual lines changed, from the
    /// start of the first to the start of the row after the last.
    fn sync(
        &mut self,
        below: &TabSnapshot,
        edits: &[LayerEdit<TabPoint>],
    ) -> ((), Vec<LayerEdit<WrapPoint>>) {
        self.tabs = below.clone();
        // Each edit's rows, before and after, and how many rows it added.
        let spans: Vec<(Range<usize>, Range<usize>)> = edits
            .iter()
            .map(|edit| {
                (
                    edit.old.start.row..edit.old.end.row + 1,
                    edit.new.start.row..edit.new.end.row + 1,
                )
            })
            .collect();
        let entries = std::mem::take(&mut self.entries);
        for ((row, segment), entry) in entries {
            let mut moved = Some(row);
            for (old, new) in &spans {
                if old.contains(&row) {
                    moved = None;
                    break;
                }
                if old.end <= row {
                    moved = moved.map(|row| row - old.len() + new.len());
                }
            }
            if let Some(row) = moved {
                self.entries.insert((row, segment), entry);
            }
        }
        let at = |row| WrapPoint {
            row,
            segment: 0,
            visual: 0,
            x: 0.0,
        };
        let out = spans
            .into_iter()
            .map(|(old, new)| LayerEdit {
                old: at(old.start)..at(old.end),
                new: at(new.start)..at(new.end),
            })
            .collect();
        ((), out)
    }

    fn to_layer(&self, point: TabPoint, _bias: Bias) -> Option<WrapPoint> {
        let entry = self.entries.get(&(point.row, point.segment))?;
        let visual = entry.line_of_column(point.column);
        Some(WrapPoint {
            row: point.row,
            segment: point.segment,
            visual,
            x: entry.x_of_column(visual, point.column),
        })
    }

    fn to_below(&self, point: WrapPoint, _bias: Bias) -> Option<TabPoint> {
        let entry = self.entries.get(&(point.row, point.segment))?;
        Some(TabPoint {
            row: point.row,
            segment: point.segment,
            column: entry.column_at(point.visual, point.x)?,
        })
    }
}

#[cfg(test)]
mod tests {
    use editor_text::Text;

    use super::{Outcome, WrapLayer, WrapPoint};
    use crate::layer::{Bias, Layer, LayerEdit};
    use crate::shaper::fake::{CellLine, CellShaper};
    use crate::shaper::{FontId, FontSpec, Shaper, Weight};
    use crate::tabs::{TabLayer, TabPoint, TabSnapshot};

    /// Cells 10 by 16.
    fn shaper() -> CellShaper {
        CellShaper::new(10.0, 16.0)
    }

    /// A wrap layer over `text` with tabs 4 wide, at `width`.
    fn layer(text: &str, width: Option<f32>) -> WrapLayer<CellLine> {
        WrapLayer::new(TabSnapshot::new(Text::from(text).snapshot(), 4), width)
    }

    /// The outcome of asking `layer` for `row`'s first segment.
    fn outcome(layer: &mut WrapLayer<CellLine>, shaper: &CellShaper, row: usize) -> Outcome {
        layer.entry(shaper, row, 0, &[], FontId(0), &[]).unwrap().1
    }

    #[test]
    fn a_segment_is_shaped_once_and_then_reused() {
        let shaper = shaper();
        let mut layer = layer("ab\ncd", Some(40.0));
        assert_eq!(outcome(&mut layer, &shaper, 0), Outcome::Shaped);
        assert_eq!(outcome(&mut layer, &shaper, 0), Outcome::Reused);
        assert_eq!(outcome(&mut layer, &shaper, 1), Outcome::Shaped);
        assert!(layer.entry(&shaper, 2, 0, &[], FontId(0), &[]).is_none());
    }

    #[test]
    fn a_width_change_breaks_the_kept_line_again_without_shaping_it() {
        let shaper = shaper();
        let mut layer = layer("abcdef", Some(40.0));
        outcome(&mut layer, &shaper, 0);
        layer.set_width(Some(100.0));
        assert_eq!(outcome(&mut layer, &shaper, 0), Outcome::Broken);
        assert_eq!(layer.kept(0, 0).unwrap().lines().len(), 1);
        assert_eq!(shaper.bytes_shaped(), 6);
    }

    #[test]
    fn another_font_or_another_generation_shapes_again() {
        let shaper = shaper();
        let mut layer = layer("abcdef", None);
        outcome(&mut layer, &shaper, 0);
        let bold = [(
            0..2,
            shaper.font(&FontSpec {
                weight: Weight::BOLD,
                ..FontSpec::default()
            }),
        )];
        let mut with_bold =
            |shaper: &CellShaper| layer.entry(shaper, 0, 0, &bold, FontId(0), &[]).unwrap().1;
        assert_eq!(with_bold(&shaper), Outcome::Shaped);
        assert_eq!(with_bold(&shaper), Outcome::Reused);
        shaper.change_fonts();
        assert_eq!(with_bold(&shaper), Outcome::Shaped);
    }

    #[test]
    fn another_base_font_shapes_again() {
        let shaper = shaper();
        let bold = shaper.font(&FontSpec {
            weight: Weight::BOLD,
            ..FontSpec::default()
        });
        let mut layer = layer("abcdef", None);
        let mut under = |base: FontId| layer.entry(&shaper, 0, 0, &[], base, &[]).unwrap().1;
        assert_eq!(under(FontId(0)), Outcome::Shaped);
        assert_eq!(under(bold), Outcome::Shaped);
        assert_eq!(under(bold), Outcome::Reused);
        assert_eq!(under(FontId(0)), Outcome::Shaped);
    }

    #[test]
    fn the_same_stops_reuse_another_x_breaks_and_another_offset_shapes() {
        let shaper = shaper();
        let mut layer = layer("abcdef", Some(100.0));
        let mut at = |stops: &[(usize, f32)]| layer.entry(&shaper, 0, 0, &[], FontId(0), stops);
        let (entry, outcome) = at(&[(2, 50.0)]).unwrap();
        assert_eq!(outcome, Outcome::Shaped);
        // `c` is at its stop.
        assert_eq!(entry.x_of(0, 2), 50.0);
        assert_eq!(at(&[(2, 50.0)]).unwrap().1, Outcome::Reused);
        // The same cut at another x is broken and placed again, not shaped.
        let (entry, outcome) = at(&[(2, 70.0)]).unwrap();
        assert_eq!(outcome, Outcome::Broken);
        assert_eq!(entry.x_of(0, 2), 70.0);
        assert_eq!(shaper.bytes_shaped(), 6);
        // Another offset cuts it otherwise: shaped again.
        assert_eq!(at(&[(3, 70.0)]).unwrap().1, Outcome::Shaped);
        // And no stop is another cut too.
        assert_eq!(at(&[]).unwrap().1, Outcome::Shaped);
        // A stop at the end does nothing: the entry with none is used.
        assert_eq!(at(&[(6, 70.0)]).unwrap().1, Outcome::Reused);
    }

    #[test]
    fn a_point_on_a_wrapped_line_is_its_visual_line_and_x() {
        let shaper = shaper();
        let mut layer = layer("abcdef", Some(40.0));
        let tab = |column| TabPoint {
            row: 0,
            segment: 0,
            column,
        };
        let wrap = |visual, x| WrapPoint {
            row: 0,
            segment: 0,
            visual,
            x,
        };
        assert_eq!(layer.to_layer(tab(4), Bias::Before), None);
        layer.entry(&shaper, 0, 0, &[], FontId(0), &[]);
        assert_eq!(layer.to_layer(tab(3), Bias::Before), Some(wrap(0, 30.0)));
        // A position at a wrap is the start of the later line.
        assert_eq!(layer.to_layer(tab(4), Bias::Before), Some(wrap(1, 0.0)));
        assert_eq!(layer.to_layer(tab(6), Bias::Before), Some(wrap(1, 20.0)));
        assert_eq!(layer.to_below(wrap(1, 20.0), Bias::Before), Some(tab(6)));
        assert_eq!(layer.to_below(wrap(1, 15.0), Bias::Before), Some(tab(5)));
        assert_eq!(layer.to_below(wrap(0, 30.0), Bias::Before), Some(tab(3)));
    }

    #[test]
    fn an_edit_drops_the_rows_it_touched_and_moves_the_rows_after_it() {
        let shaper = shaper();
        let mut text = Text::from("ab\ncd\nef");
        let mut tabs = TabLayer::new(text.snapshot(), 4);
        let mut layer = WrapLayer::new(tabs.snapshot().clone(), None);
        for row in 0..3 {
            layer.entry(&shaper, row, 0, &[], FontId(0), &[]);
        }
        let before = text.snapshot().revision();
        // A line feed in row 1: rows 1 and 2 of the new text are its.
        text.replace(4..4, "\n").unwrap();
        let edits: Vec<LayerEdit<usize>> = text
            .changes_since(before)
            .unwrap()
            .edits
            .iter()
            .map(|edit| LayerEdit {
                old: edit.old.start..edit.old.end,
                new: edit.new.start..edit.new.end,
            })
            .collect();
        let (snapshot, tab_edits) = tabs.sync(&text.snapshot(), &edits);
        let ((), wrap_edits) = layer.sync(&snapshot, &tab_edits);
        let rows = |edit: &LayerEdit<WrapPoint>| {
            (
                edit.old.start.row..edit.old.end.row,
                edit.new.start.row..edit.new.end.row,
            )
        };
        assert_eq!(
            wrap_edits.iter().map(rows).collect::<Vec<_>>(),
            vec![(1..2, 1..3)]
        );
        assert!(layer.kept(0, 0).is_some());
        assert!(layer.kept(1, 0).is_none());
        assert!(layer.kept(2, 0).is_none());
        // Old row 2, "ef", is row 3 now, and was not shaped again.
        assert_eq!(
            layer.entry(&shaper, 3, 0, &[], FontId(0), &[]).unwrap().1,
            Outcome::Reused
        );
        assert_eq!(layer.len(), 2);
    }
}
