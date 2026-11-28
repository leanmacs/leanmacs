//! The fold layer: which rows of a text a view's folds
//! ([`Fold`]; [`scene`](crate::scene), "A fold") show as one placeholder
//! row, and the mapping between a buffer offset and a point of the rows
//! that are left (a [`FoldPoint`]).
//!
//! # The rule
//!
//! - **A fold is whole rows.** It covers each buffer row its range
//!   `[start, stop)` has a byte in, a line break being the row's it ends,
//!   or the row that holds `start` when the range is empty. Its offsets
//!   past the text's end are the end, and a byte inside a character is
//!   on that character's row.
//! - **The shown folds** are the folds in order of start, of two with one
//!   start the longer first; one whose first row an earlier shown fold
//!   covers is dropped. So of two nested folds the outer one shows, and a
//!   fold that only partly overlaps a shown one leaves its later rows
//!   visible. Lean hands a view only the folds it shows, by the same rule,
//!   so the two never disagree.
//! - **The placeholder row** of a shown fold holds every position of the
//!   rows it covers, from the first row's start (the fold's start) up to
//!   the next row's start. Each of them is at its offset 0. Down to the
//!   buffer, the placeholder's point is the fold's start before and the
//!   end of its last covered row's content (its row's end without a
//!   carriage return before the line feed) after
//!   ([`FoldSnapshot::to_buffer`]).
//!
//! # Where it sits
//!
//! The fold layer sits **beside** the tab and wrap layers, not under them:
//! a fold never changes the text of a row it leaves shown, so the tab
//! layer still reads the buffer ([`TabLayer`](crate::tabs::TabLayer)'s
//! `Below` stays the buffer's snapshot) and the tab and wrap layers keep
//! their entries keyed by buffer row. Folding or unfolding shapes only the
//! placeholder; the rows it hides are simply not laid out.
//!
//! Layout keeps no [`FoldLayer`] between calls. The frame and the queries
//! build a [`FoldSnapshot`] for each walk from the view's or the query's
//! folds, which costs the folds and no row. [`FoldLayer`] is the same
//! mapping behind the [`Layer`] contract, whose round trip
//! `tests/layers.rs` checks.

use std::ops::Range;

use editor_text::Snapshot;

use crate::layer::{Bias, Layer, LayerEdit};
use crate::scene::Fold;
use crate::tabs::{boundary_at_or_before, row_content};

/// A fold the snapshot shows, by the rule (module docs, "The rule").
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ShownFold {
    /// Which fold, by its index among those the snapshot was made from.
    pub index: usize,
    /// The first buffer row it covers.
    pub first: usize,
    /// The last buffer row it covers.
    pub last: usize,
    /// Its start: where its first row starts.
    pub start: usize,
    /// Its stop: the end of its last row's content.
    pub stop: usize,
}

/// A point of the fold layer: a row of the rows a text's shown folds
/// leave, and a byte from that row's start; 0 on a placeholder row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct FoldPoint {
    /// The row, counting each placeholder as one.
    pub row: usize,
    /// The byte from the row's start.
    pub offset: usize,
}

/// A buffer snapshot read with the folds it shows.
#[derive(Clone)]
pub struct FoldSnapshot {
    /// The buffer's snapshot.
    buffer: Snapshot,
    /// The shown folds, in order of row; no two cover a row in common.
    shown: Vec<ShownFold>,
    /// For each shown fold, how many buffer rows the folds before it hide.
    hidden_before: Vec<usize>,
}

/// The first and last rows of `snapshot` that the range `start..stop`
/// covers, by the rule (module docs, "The rule"): each row it has a byte
/// in, a line break being the row's it ends, or the row of `start` when
/// it is empty. Offsets past the end are the end, and a stop before the
/// start is the start. A wrap indent covers rows by the same rule
/// ([`indent`](crate::indent)).
pub(crate) fn covered_rows(snapshot: &Snapshot, start: usize, stop: usize) -> (usize, usize) {
    let row_of = |offset: usize| {
        snapshot
            .offset_to_point(boundary_at_or_before(snapshot, offset))
            .map_or(0, |point| point.row)
    };
    // Clamped but not moved back: a range covers the row of each of its
    // bytes, the last one included, even where that byte is inside a
    // character (Lean's model reads the range the same way).
    let start = start.min(snapshot.len());
    let stop = stop.min(snapshot.len()).max(start);
    let first = row_of(start);
    let last = if stop > start {
        row_of(stop - 1)
    } else {
        first
    };
    (first, last)
}

impl FoldSnapshot {
    /// `buffer` with `folds` shown by the rule (module docs, "The rule").
    pub fn new(buffer: &Snapshot, folds: &[Fold]) -> Self {
        // Ordered by the ranges as clamped (`covered_rows`).
        let mut ranges: Vec<(usize, usize, usize)> = folds
            .iter()
            .enumerate()
            .map(|(index, fold)| {
                let start = fold.start.min(buffer.len());
                let stop = fold.stop.min(buffer.len()).max(start);
                (index, start, stop)
            })
            .collect();
        ranges.sort_by(|a, b| a.1.cmp(&b.1).then(b.2.cmp(&a.2)));
        let mut shown: Vec<ShownFold> = Vec::new();
        for (index, start, stop) in ranges {
            let (first, last) = covered_rows(buffer, start, stop);
            if shown.last().is_some_and(|before| first <= before.last) {
                continue;
            }
            shown.push(ShownFold {
                index,
                first,
                last,
                start: buffer.row_range(first).map_or(0, |row| row.start),
                stop: row_content(buffer, last).map_or(buffer.len(), |row| row.end),
            });
        }
        let mut hidden_before = Vec::with_capacity(shown.len());
        let mut hidden = 0;
        for fold in &shown {
            hidden_before.push(hidden);
            hidden += fold.last - fold.first;
        }
        Self {
            buffer: buffer.clone(),
            shown,
            hidden_before,
        }
    }

    /// `buffer` with no fold.
    pub fn none(buffer: &Snapshot) -> Self {
        Self::new(buffer, &[])
    }

    /// The buffer's snapshot.
    pub fn buffer(&self) -> &Snapshot {
        &self.buffer
    }

    /// The shown folds, in order of row.
    pub fn shown(&self) -> &[ShownFold] {
        &self.shown
    }

    /// Whether it shows no fold.
    pub fn is_empty(&self) -> bool {
        self.shown.is_empty()
    }

    /// The position among the shown folds of the last one that starts at
    /// or before buffer row `row`.
    fn last_at_or_before(&self, row: usize) -> Option<usize> {
        self.shown
            .partition_point(|fold| fold.first <= row)
            .checked_sub(1)
    }

    /// The shown fold that covers buffer row `row`, if one does.
    pub fn fold_covering_row(&self, row: usize) -> Option<&ShownFold> {
        let at = self.last_at_or_before(row)?;
        let fold = &self.shown[at];
        (row <= fold.last).then_some(fold)
    }

    /// The shown fold whose placeholder holds `offset`: the one that covers
    /// its row. None when `offset` is not a position or no fold covers it.
    pub fn fold_holding(&self, offset: usize) -> Option<&ShownFold> {
        let row = self.buffer.offset_to_point(offset)?.row;
        self.fold_covering_row(row)
    }

    /// How many rows there are: the buffer's, each shown fold counted as
    /// one.
    pub fn row_count(&self) -> usize {
        let hidden = self
            .shown
            .last()
            .zip(self.hidden_before.last())
            .map_or(0, |(fold, before)| before + fold.last - fold.first);
        self.buffer.row_count() - hidden
    }

    /// The fold row that shows buffer row `row`: a covered row's is its
    /// fold's placeholder row.
    pub fn fold_row(&self, row: usize) -> usize {
        match self.last_at_or_before(row) {
            None => row,
            Some(at) => {
                let fold = &self.shown[at];
                let hidden = self.hidden_before[at] + (row.min(fold.last) - fold.first);
                row - hidden
            }
        }
    }

    /// The first buffer row fold row `row` shows: a placeholder's is its
    /// fold's first row. None past the last row.
    pub fn buffer_row(&self, row: usize) -> Option<usize> {
        if row >= self.row_count() {
            return None;
        }
        // The folds whose placeholder row is at or before `row`.
        let at = self
            .shown
            .iter()
            .zip(&self.hidden_before)
            .take_while(|(fold, before)| fold.first - **before <= row)
            .count();
        let hidden = match at.checked_sub(1) {
            None => 0,
            Some(at) => {
                let fold = &self.shown[at];
                let placeholder = fold.first - self.hidden_before[at];
                if placeholder == row {
                    return Some(fold.first);
                }
                self.hidden_before[at] + fold.last - fold.first
            }
        };
        Some(row + hidden)
    }

    /// The point of the position `offset`: its row's fold row, and its byte
    /// from that row's start, or 0 on a placeholder. None when `offset` is
    /// not a position.
    pub fn to_fold(&self, offset: usize) -> Option<FoldPoint> {
        if offset > self.buffer.len() || !self.buffer.is_char_boundary(offset) {
            return None;
        }
        let row = self.buffer.offset_to_point(offset)?.row;
        let fold_row = self.fold_row(row);
        if self.fold_covering_row(row).is_some() {
            return Some(FoldPoint {
                row: fold_row,
                offset: 0,
            });
        }
        let start = self.buffer.row_range(row)?.start;
        Some(FoldPoint {
            row: fold_row,
            offset: offset - start,
        })
    }

    /// The position at `point`. On a placeholder, `Bias::Before` is the
    /// fold's start and `Bias::After` the end of its last row's content.
    /// None when the layer has no such point.
    pub fn to_buffer(&self, point: FoldPoint, bias: Bias) -> Option<usize> {
        let row = self.buffer_row(point.row)?;
        if let Some(fold) = self.fold_covering_row(row) {
            if point.offset != 0 {
                return None;
            }
            return Some(match bias {
                Bias::Before => fold.start,
                Bias::After => fold.stop,
            });
        }
        let range = self.buffer.row_range(row)?;
        let offset = range.start.checked_add(point.offset)?;
        (offset <= range.end && self.buffer.is_char_boundary(offset)).then_some(offset)
    }

    /// The buffer bytes a shown fold covers: from its start up to the next
    /// row's start, or the text's end after the last row.
    pub fn covered_bytes(&self, fold: &ShownFold) -> Range<usize> {
        let end = self
            .buffer
            .row_range(fold.last + 1)
            .map_or(self.buffer.len(), |row| row.start);
        fold.start..end
    }
}

/// The fold layer: a buffer read with the folds it holds, behind the
/// [`Layer`] contract (module docs, "Where it sits").
#[derive(Clone)]
pub struct FoldLayer {
    /// The folds.
    folds: Vec<Fold>,
    /// The snapshot last taken.
    snapshot: FoldSnapshot,
}

impl FoldLayer {
    /// A fold layer over `buffer` that shows `folds`.
    pub fn new(buffer: &Snapshot, folds: Vec<Fold>) -> Self {
        let snapshot = FoldSnapshot::new(buffer, &folds);
        Self { folds, snapshot }
    }

    /// The snapshot last taken.
    pub fn snapshot(&self) -> &FoldSnapshot {
        &self.snapshot
    }
}

impl Layer for FoldLayer {
    type Below = Snapshot;
    type BelowPoint = usize;
    type Snapshot = FoldSnapshot;
    type Point = FoldPoint;

    /// The folds read over the buffer's new snapshot, their offsets as
    /// they were. An edit of the buffer is an edit of the fold layer from
    /// its start's row to the end of its end's row: a fold over either end
    /// takes in its whole placeholder.
    fn sync(
        &mut self,
        below: &Snapshot,
        edits: &[LayerEdit<usize>],
    ) -> (FoldSnapshot, Vec<LayerEdit<FoldPoint>>) {
        let old = std::mem::replace(&mut self.snapshot, FoldSnapshot::new(below, &self.folds));
        let new = &self.snapshot;
        let row_start = |snapshot: &FoldSnapshot, offset: usize| {
            snapshot.to_fold(offset).map(|point| FoldPoint {
                row: point.row,
                offset: 0,
            })
        };
        let row_end = |snapshot: &FoldSnapshot, offset: usize| {
            let row = snapshot.buffer.offset_to_point(offset)?.row;
            if snapshot.fold_covering_row(row).is_some() {
                return snapshot.to_fold(offset);
            }
            snapshot.to_fold(snapshot.buffer.row_range(row)?.end)
        };
        let mut out: Vec<LayerEdit<FoldPoint>> = Vec::with_capacity(edits.len());
        for edit in edits {
            let points = (|| {
                Some(LayerEdit {
                    old: row_start(&old, edit.old.start)?..row_end(&old, edit.old.end)?,
                    new: row_start(new, edit.new.start)?..row_end(new, edit.new.end)?,
                })
            })();
            let Some(edit) = points else { continue };
            match out.last_mut() {
                Some(last) if last.old.end >= edit.old.start => {
                    last.old.end = last.old.end.max(edit.old.end);
                    last.new.end = last.new.end.max(edit.new.end);
                }
                _ => out.push(edit),
            }
        }
        (new.clone(), out)
    }

    fn to_layer(&self, point: usize, _bias: Bias) -> Option<FoldPoint> {
        self.snapshot.to_fold(point)
    }

    fn to_below(&self, point: FoldPoint, bias: Bias) -> Option<usize> {
        self.snapshot.to_buffer(point, bias)
    }
}

#[cfg(test)]
mod tests {
    use editor_text::Text;

    use super::{FoldLayer, FoldPoint, FoldSnapshot, ShownFold, covered_rows};
    use crate::layer::{Bias, Layer, LayerEdit};
    use crate::scene::Fold;

    /// A fold of `start..stop` saying `…`.
    fn fold(start: usize, stop: usize) -> Fold {
        Fold {
            start,
            stop,
            text: "…".to_owned(),
            decorations: Vec::new(),
        }
    }

    /// The first and last rows of each fold `text` shows of `folds`.
    fn rows(text: &str, folds: &[Fold]) -> Vec<(usize, usize, usize)> {
        FoldSnapshot::new(&Text::from(text).snapshot(), folds)
            .shown()
            .iter()
            .map(|fold| (fold.index, fold.first, fold.last))
            .collect()
    }

    const TEXT: &str = "ab\ncd\nef\ngh";

    #[test]
    fn a_range_covers_the_rows_it_has_a_byte_in() {
        let covered =
            |text: &str, start, stop| covered_rows(&Text::from(text).snapshot(), start, stop);
        // `[3,6)` is `cd` and the line break that ends it: row 1 alone.
        assert_eq!(covered(TEXT, 3, 6), (1, 1));
        assert_eq!(covered(TEXT, 3, 7), (1, 2));
        // An empty range, the row of its start.
        assert_eq!(covered(TEXT, 4, 4), (1, 1));
        // A stop before the start is the start.
        assert_eq!(covered(TEXT, 7, 2), (2, 2));
        // Offsets past the end are the end.
        assert_eq!(covered(TEXT, 6, 99), (2, 3));
        assert_eq!(covered(TEXT, 40, 90), (3, 3));
        // `é` is bytes 3 and 4 of `ab\néx\nz`. A start inside it is on its
        // row, empty or not; a stop at 4 holds its first byte, so covers
        // its row, and one at 3 only the line break of row 0.
        let accented = "ab\néx\nz";
        assert_eq!(covered(accented, 4, 4), (1, 1));
        assert_eq!(covered(accented, 4, 7), (1, 1));
        assert_eq!(covered(accented, 4, 8), (1, 2));
        assert_eq!(covered(accented, 0, 4), (0, 1));
        assert_eq!(covered(accented, 0, 3), (0, 0));
    }

    #[test]
    fn a_fold_covers_the_rows_its_range_has_a_byte_in() {
        // `[3,6)` is `cd` and the line break that ends it: row 1 alone.
        assert_eq!(rows(TEXT, &[fold(3, 6)]), vec![(0, 1, 1)]);
        // One byte more is the first of row 2.
        assert_eq!(rows(TEXT, &[fold(3, 7)]), vec![(0, 1, 2)]);
        // An empty range covers the row of its start.
        assert_eq!(rows(TEXT, &[fold(4, 4)]), vec![(0, 1, 1)]);
        // A start inside a row covers the whole of it.
        assert_eq!(rows(TEXT, &[fold(4, 8)]), vec![(0, 1, 2)]);
    }

    #[test]
    fn a_fold_past_the_end_is_clamped_and_one_off_a_boundary_is_moved_back() {
        assert_eq!(rows(TEXT, &[fold(6, 99)]), vec![(0, 2, 3)]);
        // `é` is bytes 3 and 4 of `ab\néx\nz`: a start at 4 is on `é`'s
        // row, and a stop at 4 holds `é`'s first byte, so covers its row;
        // a stop at 3 holds only the line break of row 0.
        assert_eq!(rows("ab\néx\nz", &[fold(4, 4)]), vec![(0, 1, 1)]);
        assert_eq!(rows("ab\néx\nz", &[fold(0, 4)]), vec![(0, 0, 1)]);
        assert_eq!(rows("ab\néx\nz", &[fold(0, 3)]), vec![(0, 0, 0)]);
    }

    #[test]
    fn a_fold_whose_first_row_an_earlier_one_covers_is_dropped() {
        // Nested: the outer one shows, whichever is listed first.
        assert_eq!(rows(TEXT, &[fold(3, 8), fold(0, 11)]), vec![(1, 0, 3)]);
        assert_eq!(rows(TEXT, &[fold(0, 4), fold(0, 9)]), vec![(1, 0, 2)]);
        // Partly overlapping: the later one is dropped, and its rows past
        // the earlier one's are left shown.
        assert_eq!(rows(TEXT, &[fold(0, 4), fold(3, 11)]), vec![(0, 0, 1)]);
        // Apart: both show.
        assert_eq!(
            rows(TEXT, &[fold(6, 8), fold(0, 2)]),
            vec![(1, 0, 0), (0, 2, 2)]
        );
    }

    #[test]
    fn a_fold_knows_its_start_and_the_end_of_its_last_rows_content() {
        let snapshot = Text::from("ab\ncd\r\nef\ngh").snapshot();
        let folds = FoldSnapshot::new(&snapshot, &[fold(4, 5)]);
        assert_eq!(
            folds.shown(),
            &[ShownFold {
                index: 0,
                first: 1,
                last: 1,
                start: 3,
                stop: 5
            }]
        );
        assert_eq!(folds.covered_bytes(&folds.shown()[0]), 3..7);
    }

    #[test]
    fn rows_are_counted_with_each_fold_as_one() {
        let snapshot = Text::from("a\nb\nc\nd\ne\nf").snapshot();
        let folds = FoldSnapshot::new(&snapshot, &[fold(2, 6), fold(8, 11)]);
        // Rows 1–2 and 4–5 folded: a, [b c], d, [e f].
        assert_eq!(folds.row_count(), 4);
        let fold_rows: Vec<usize> = (0..6).map(|row| folds.fold_row(row)).collect();
        assert_eq!(fold_rows, vec![0, 1, 1, 2, 3, 3]);
        let buffer_rows: Vec<Option<usize>> = (0..5).map(|row| folds.buffer_row(row)).collect();
        assert_eq!(buffer_rows, vec![Some(0), Some(1), Some(3), Some(4), None]);
        assert_eq!(folds.fold_covering_row(2).map(|fold| fold.index), Some(0));
        assert_eq!(folds.fold_covering_row(3), None);
        assert_eq!(folds.fold_holding(9).map(|fold| fold.index), Some(1));
        assert_eq!(folds.fold_holding(6), None);
    }

    #[test]
    fn a_point_goes_to_the_layer_and_back_with_both_biases() {
        let snapshot = Text::from(TEXT).snapshot();
        let layer = FoldLayer::new(&snapshot, vec![fold(3, 7)]);
        // Outside the fold, each position comes back as itself.
        for offset in [0, 1, 2, 9, 10, 11] {
            let point = layer.to_layer(offset, Bias::Before).unwrap();
            assert_eq!(layer.to_below(point, Bias::Before), Some(offset));
            assert_eq!(layer.to_below(point, Bias::After), Some(offset));
        }
        assert_eq!(
            layer.to_layer(10, Bias::Before),
            Some(FoldPoint { row: 2, offset: 1 })
        );
        // Inside, each goes to the placeholder at 0, and back to the
        // fold's start before and the end of row 2 after.
        for offset in 3..=8 {
            let point = layer.to_layer(offset, Bias::Before).unwrap();
            assert_eq!(point, FoldPoint { row: 1, offset: 0 });
            assert_eq!(layer.to_below(point, Bias::Before), Some(3));
            assert_eq!(layer.to_below(point, Bias::After), Some(8));
        }
        // A placeholder has no other offset, and there is no row 3.
        assert_eq!(
            layer.to_below(FoldPoint { row: 1, offset: 1 }, Bias::Before),
            None
        );
        assert_eq!(
            layer.to_below(FoldPoint { row: 3, offset: 0 }, Bias::Before),
            None
        );
        assert_eq!(layer.to_layer(12, Bias::Before), None);
    }

    #[test]
    fn a_sync_keeps_the_folds_and_gives_the_rows_an_edit_touched() {
        let mut text = Text::from(TEXT);
        let mut layer = FoldLayer::new(&text.snapshot(), vec![fold(3, 7)]);
        // An `x` typed at the start of row 3: the rows after the fold.
        text.replace(9..9, "x").unwrap();
        let (snapshot, edits) = layer.sync(
            &text.snapshot(),
            &[LayerEdit {
                old: 9..9,
                new: 9..10,
            }],
        );
        assert_eq!(snapshot.shown()[0].first, 1);
        assert_eq!(
            edits,
            vec![LayerEdit {
                old: FoldPoint { row: 2, offset: 0 }..FoldPoint { row: 2, offset: 2 },
                new: FoldPoint { row: 2, offset: 0 }..FoldPoint { row: 2, offset: 3 },
            }]
        );
        // An edit inside the fold is an edit of its placeholder row.
        text.replace(4..4, "y").unwrap();
        let (_, edits) = layer.sync(
            &text.snapshot(),
            &[LayerEdit {
                old: 4..4,
                new: 4..5,
            }],
        );
        assert_eq!(
            edits,
            vec![LayerEdit {
                old: FoldPoint { row: 1, offset: 0 }..FoldPoint { row: 1, offset: 0 },
                new: FoldPoint { row: 1, offset: 0 }..FoldPoint { row: 1, offset: 0 },
            }]
        );
    }
}
