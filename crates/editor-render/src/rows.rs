//! Row reuse: which rows of a frame a renderer builds draw data for, and
//! which it draws from what it kept.
//!
//! A row of a frame carries a content hash that covers what it draws
//! relative to its own start, and neither where it is nor any cursor
//! (`editor-layout`'s `frame`). So whatever a renderer builds for a row,
//! relative to the row's start, it can keep by that hash and draw again
//! wherever the row is next. [`RowCache`] is that rule, written once so it
//! is the same for every back end; the payload it keeps for a row is the
//! back end's own.
//!
//! It keeps one payload for each distinct hash of the frame it was last
//! given, text rows and status rows alike, builds a payload only for a hash
//! it does not hold, and hands back those of rows the frame no longer
//! shows. What was built under another generation of the frame's fonts, or
//! at another scale, is of no use: it hands all of it back and builds
//! every row.

use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet};
use std::ops::Range;
use std::sync::Arc;

use editor_layout::face::{Color, Paint};
use editor_layout::frame::Frame;
use editor_layout::shaper::VisualLine;

/// One row of a frame, as a renderer builds draw data from it: a text row
/// or a status row.
#[derive(Debug, Clone, Copy)]
pub struct RowRef<'a> {
    /// Its content hash.
    pub hash: u64,
    /// Its glyphs.
    pub line: &'a Arc<VisualLine>,
    /// Its runs, each with what it is painted with.
    pub runs: &'a [(Range<usize>, Paint)],
    /// How far down it is.
    pub height: f32,
    /// Its baseline, from its top.
    pub baseline: f32,
    /// The colour behind a status row, which its hash covers; `None` for
    /// a text row.
    pub status: Option<Color>,
}

/// The rows `frame` shows: for each view, its text rows from the top and
/// then its status row.
pub fn shown(frame: &Frame) -> impl Iterator<Item = RowRef<'_>> {
    frame.views.iter().flat_map(|view| {
        let rows = view.rows.iter().map(|row| RowRef {
            hash: row.hash,
            line: &row.line,
            runs: &row.runs,
            height: row.height,
            baseline: row.baseline,
            status: None,
        });
        let status = view.status.iter().map(|row| RowRef {
            hash: row.hash,
            line: &row.line,
            runs: &row.runs,
            height: row.height,
            baseline: row.baseline,
            status: Some(row.background),
        });
        rows.chain(status)
    })
}

/// What an update of a [`RowCache`] did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reuse<T> {
    /// How many payloads were built: one for each distinct hash of the
    /// frame that was not held.
    pub rebuilt: u64,
    /// How many distinct hashes of the frame were held already.
    pub reused: u64,
    /// The payloads no longer kept, in no order: those of rows the frame
    /// does not show, or all of them when the generation or the scale
    /// changed.
    pub dropped: Vec<T>,
}

/// What a renderer keeps for the rows of the frame it last drew, by their
/// content hashes.
#[derive(Debug)]
pub struct RowCache<T> {
    /// The generation and the scale (its bits) the payloads were built
    /// under; `None` before the first frame.
    built_under: Option<(u64, u32)>,
    /// The payloads, by row hash.
    rows: HashMap<u64, T>,
}

impl<T> Default for RowCache<T> {
    fn default() -> Self {
        Self {
            built_under: None,
            rows: HashMap::new(),
        }
    }
}

impl<T> RowCache<T> {
    /// A cache that holds nothing.
    pub fn new() -> Self {
        Self::default()
    }

    /// Makes the cache hold a payload for each distinct row hash of
    /// `frame` and for nothing else, calling `build` for each hash it does
    /// not hold, in the order the frame shows them.
    pub fn update(
        &mut self,
        frame: &Frame,
        scale: f32,
        mut build: impl FnMut(RowRef<'_>) -> T,
    ) -> Reuse<T> {
        let under = Some((frame.generation, scale.to_bits()));
        let mut dropped = Vec::new();
        if self.built_under != under {
            dropped.extend(self.rows.drain().map(|(_, payload)| payload));
            self.built_under = under;
        }
        let (mut rebuilt, mut reused) = (0, 0);
        let mut seen = HashSet::new();
        for row in shown(frame) {
            if !seen.insert(row.hash) {
                continue;
            }
            match self.rows.entry(row.hash) {
                Entry::Occupied(_) => reused += 1,
                Entry::Vacant(vacant) => {
                    vacant.insert(build(row));
                    rebuilt += 1;
                }
            }
        }
        dropped.extend(
            self.rows
                .extract_if(|hash, _| !seen.contains(hash))
                .map(|(_, payload)| payload),
        );
        Reuse {
            rebuilt,
            reused,
            dropped,
        }
    }

    /// The payload kept for the row hash `hash`.
    pub fn get(&self, hash: u64) -> Option<&T> {
        self.rows.get(&hash)
    }

    /// How many payloads are kept.
    pub fn len(&self) -> usize {
        self.rows.len()
    }

    /// Whether nothing is kept.
    pub fn is_empty(&self) -> bool {
        self.rows.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use editor_layout::Layout;
    use editor_layout::frame::{CursorBox, Frame, FrameRow};
    use editor_layout::scene::{Rect, Scene, StatusField};
    use editor_layout::shaper::fake::CellShaper;

    use super::{Reuse, RowCache, shown};

    /// A view's rectangle, tall enough for every row of the texts here.
    const RECT: Rect = Rect {
        x: 0,
        y: 0,
        width: 400,
        height: 400,
    };

    /// The frame of `text` in one view, with a status row, laid out on the
    /// fake shaper.
    fn frame_of(text: &str) -> Frame {
        let mut scene = Scene::of_text(text, RECT).selecting(0..0);
        scene.views[0].status = vec![StatusField {
            text: "status".to_owned(),
            face: "mode-line".to_owned(),
        }];
        Layout::new(CellShaper::new(10.0, 16.0)).frame(&scene)
    }

    /// The frame every test starts from: three text rows, each unlike the
    /// others, and a status row.
    fn three_rows() -> Frame {
        frame_of("one\ntwo\nthree")
    }

    /// The first text row of the frame of `text`.
    fn row_of(text: &str) -> FrameRow {
        frame_of(text).views[0].rows[0].clone()
    }

    /// The distinct row hashes of `frame`.
    fn hashes(frame: &Frame) -> BTreeSet<u64> {
        shown(frame).map(|row| row.hash).collect()
    }

    /// Updates `cache` with `frame` at scale 1, the payload of a row being
    /// its hash: what was built in order, and what the update said.
    fn update(cache: &mut RowCache<u64>, frame: &Frame) -> (Vec<u64>, Reuse<u64>) {
        update_at(cache, frame, 1.0)
    }

    /// As [`update`], at `scale`.
    fn update_at(cache: &mut RowCache<u64>, frame: &Frame, scale: f32) -> (Vec<u64>, Reuse<u64>) {
        let mut built = Vec::new();
        let reuse = cache.update(frame, scale, |row| {
            built.push(row.hash);
            row.hash
        });
        (built, reuse)
    }

    /// `dropped` as a set.
    fn set(dropped: &[u64]) -> BTreeSet<u64> {
        dropped.iter().copied().collect()
    }

    #[test]
    fn the_fixture_shows_three_text_rows_and_a_status_row_all_unlike() {
        let frame = three_rows();
        assert_eq!(shown(&frame).count(), 4);
        assert_eq!(hashes(&frame).len(), 4);
        assert_eq!(shown(&frame).filter(|row| row.status.is_some()).count(), 1);
    }

    #[test]
    fn the_first_frame_builds_every_row() {
        let frame = three_rows();
        let mut cache = RowCache::new();
        let (built, reuse) = update(&mut cache, &frame);
        // In the order the frame shows them, the status row last.
        let order: Vec<u64> = shown(&frame).map(|row| row.hash).collect();
        assert_eq!(built, order);
        assert_eq!((reuse.rebuilt, reuse.reused), (4, 0));
        assert!(reuse.dropped.is_empty());
        assert_eq!(cache.len(), 4);
        for hash in order {
            assert_eq!(cache.get(hash), Some(&hash));
        }
    }

    #[test]
    fn the_same_frame_again_builds_none() {
        let frame = three_rows();
        let mut cache = RowCache::new();
        update(&mut cache, &frame);
        let (built, reuse) = update(&mut cache, &frame);
        assert!(built.is_empty());
        assert_eq!((reuse.rebuilt, reuse.reused), (0, 4));
        assert!(reuse.dropped.is_empty());
    }

    #[test]
    fn a_frame_that_differs_only_in_its_cursor_builds_no_row() {
        let frame = three_rows();
        // The same frame with its cursor moved and reshaped, and one more.
        let mut moved = frame.clone();
        let cursor: CursorBox = moved.views[0].cursors[0];
        moved.views[0].cursors[0].area.x += 10.0;
        moved.views[0].cursors[0].paint.background.0 ^= 0xff00;
        moved.views[0].cursors.push(cursor);
        assert_ne!(moved, frame);
        let mut cache = RowCache::new();
        update(&mut cache, &frame);
        let (built, reuse) = update(&mut cache, &moved);
        assert!(built.is_empty());
        assert_eq!((reuse.rebuilt, reuse.reused), (0, 4));
        assert!(reuse.dropped.is_empty());
    }

    #[test]
    fn a_frame_that_differs_in_one_row_builds_that_row_alone() {
        let frame = three_rows();
        let mut edited = frame.clone();
        let old = edited.views[0].rows[1].hash;
        let new = FrameRow {
            y: edited.views[0].rows[1].y,
            ..row_of("another")
        };
        edited.views[0].rows[1] = new.clone();
        let mut cache = RowCache::new();
        update(&mut cache, &frame);
        let (built, reuse) = update(&mut cache, &edited);
        assert_eq!(built, vec![new.hash]);
        assert_eq!((reuse.rebuilt, reuse.reused), (1, 3));
        // What the row was before is handed back, and no longer kept.
        assert_eq!(reuse.dropped, vec![old]);
        assert_eq!(cache.get(old), None);
        assert_eq!(cache.len(), 4);
    }

    #[test]
    fn a_frame_scrolled_by_a_row_builds_only_the_row_that_came_into_view() {
        let frame = three_rows();
        // The first row gone, the others one row up, and a new last row.
        let mut scrolled = frame.clone();
        let rows = &mut scrolled.views[0].rows;
        let gone = rows.remove(0);
        let mut y = gone.y;
        for row in rows.iter_mut() {
            row.y = y;
            y += row.height;
        }
        let new = FrameRow {
            y,
            ..row_of("four")
        };
        rows.push(new.clone());
        let mut cache = RowCache::new();
        update(&mut cache, &frame);
        let (built, reuse) = update(&mut cache, &scrolled);
        assert_eq!(built, vec![new.hash]);
        assert_eq!((reuse.rebuilt, reuse.reused), (1, 3));
        assert_eq!(reuse.dropped, vec![gone.hash]);
    }

    #[test]
    fn a_frame_of_another_generation_builds_every_row() {
        let frame = three_rows();
        let mut later = frame.clone();
        later.generation += 1;
        let mut cache = RowCache::new();
        update(&mut cache, &frame);
        let (built, reuse) = update(&mut cache, &later);
        assert_eq!(set(&built), hashes(&later));
        assert_eq!((reuse.rebuilt, reuse.reused), (4, 0));
        // Everything built under the generation before is handed back.
        assert_eq!(reuse.dropped.len(), 4);
        assert_eq!(set(&reuse.dropped), hashes(&frame));
        assert_eq!(cache.len(), 4);
        // And the generation it now holds is the later one.
        let (built, _) = update(&mut cache, &later);
        assert!(built.is_empty());
    }

    #[test]
    fn another_scale_builds_every_row() {
        let frame = three_rows();
        let mut cache = RowCache::new();
        update_at(&mut cache, &frame, 1.0);
        let (built, reuse) = update_at(&mut cache, &frame, 2.0);
        assert_eq!(built.len(), 4);
        assert_eq!((reuse.rebuilt, reuse.reused), (4, 0));
        assert_eq!(set(&reuse.dropped), hashes(&frame));
        let (built, reuse) = update_at(&mut cache, &frame, 2.0);
        assert!(built.is_empty());
        assert_eq!((reuse.rebuilt, reuse.reused), (0, 4));
    }

    #[test]
    fn two_rows_alike_are_one_entry() {
        let mut frame = three_rows();
        // The second row made the same as the first, a row lower.
        let first = frame.views[0].rows[0].clone();
        let y = frame.views[0].rows[1].y;
        frame.views[0].rows[1] = FrameRow { y, ..first };
        assert_eq!(shown(&frame).count(), 4);
        let mut cache = RowCache::new();
        let (built, reuse) = update(&mut cache, &frame);
        assert_eq!(built.len(), 3);
        assert_eq!((reuse.rebuilt, reuse.reused), (3, 0));
        assert_eq!(cache.len(), 3);
        let (_, reuse) = update(&mut cache, &frame);
        assert_eq!((reuse.rebuilt, reuse.reused), (0, 3));
    }

    #[test]
    fn a_frame_of_no_views_drops_what_was_kept() {
        let frame = three_rows();
        let mut cache = RowCache::new();
        assert!(cache.is_empty());
        update(&mut cache, &frame);
        let (built, reuse) = update(&mut cache, &Frame::default());
        assert!(built.is_empty());
        assert_eq!((reuse.rebuilt, reuse.reused), (0, 0));
        assert_eq!(set(&reuse.dropped), hashes(&frame));
        assert!(cache.is_empty());
    }
}
