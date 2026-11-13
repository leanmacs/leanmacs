//! A selection, as a transaction carries one: plain ranges of offsets.
//!
//! This is what there is of a selection so far. It has no order among its
//! ranges, no merging of ranges that overlap, no shape, no anchors and no
//! mapping through a change set: the ranges are kept exactly as given. The
//! rest of the crate reaches a selection only through [`Selection::new`],
//! [`Selection::ranges`], [`Selection::primary`] and the crate's one check
//! of it, whether it fits a snapshot, so the type can grow behind those.

use crate::snapshot::Snapshot;

/// One range of a selection: two byte offsets. The anchor is the end that
/// stays where it is when the selection is extended and the head the end
/// that moves; either may be first, and the two may be equal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SelectionRange {
    /// The end that stays.
    pub anchor: usize,
    /// The end that moves.
    pub head: usize,
}

impl SelectionRange {
    /// The range from `anchor` to `head`.
    pub const fn new(anchor: usize, head: usize) -> Self {
        Self { anchor, head }
    }
}

/// One or more ranges, one of which is the primary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Selection {
    /// The ranges, as given. Never empty.
    ranges: Vec<SelectionRange>,
    /// Which of the ranges is the primary one: an index into `ranges`.
    primary: usize,
}

impl Selection {
    /// The selection of `ranges`, kept in the order given, whose primary
    /// range is the one at the index `primary`. `None` when there is no
    /// range, or `primary` names none.
    pub fn new(ranges: Vec<SelectionRange>, primary: usize) -> Option<Self> {
        (primary < ranges.len()).then_some(Self { ranges, primary })
    }

    /// The ranges, in the order they were given. Never empty.
    pub fn ranges(&self) -> &[SelectionRange] {
        &self.ranges
    }

    /// The index in [`ranges`](Self::ranges) of the primary range.
    pub fn primary(&self) -> usize {
        self.primary
    }

    /// Whether every end of every range is a position of `snapshot`.
    pub(crate) fn fits(&self, snapshot: &Snapshot) -> bool {
        self.ranges.iter().all(|range| {
            snapshot.is_char_boundary(range.anchor) && snapshot.is_char_boundary(range.head)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Text;

    #[test]
    fn a_selection_with_no_range_is_none() {
        assert_eq!(Selection::new(Vec::new(), 0), None);
    }

    #[test]
    fn a_selection_whose_primary_names_no_range_is_none() {
        let ranges = vec![SelectionRange::new(0, 1), SelectionRange::new(2, 2)];

        assert_eq!(Selection::new(ranges.clone(), 2), None);
        assert_eq!(Selection::new(ranges, usize::MAX), None);
    }

    #[test]
    fn the_ranges_come_back_as_given_unsorted_and_overlapping_included() {
        let ranges = vec![
            SelectionRange::new(9, 4),
            SelectionRange::new(0, 6),
            SelectionRange::new(9, 4),
            SelectionRange::new(2, 2),
        ];

        let selection = Selection::new(ranges.clone(), 3).expect("a primary among the ranges");

        assert_eq!(selection.ranges(), ranges.as_slice());
        assert_eq!(selection.primary(), 3);
        assert_eq!(selection.ranges()[0].anchor, 9);
        assert_eq!(selection.ranges()[0].head, 4);
    }

    #[test]
    fn a_selection_fits_a_snapshot_when_every_end_is_a_position_of_it() {
        // "é" is the bytes 1 and 2, so 2 is inside it.
        let snapshot = Text::from("héllo").snapshot();
        let selection = |ranges: &[(usize, usize)]| {
            let ranges = ranges
                .iter()
                .map(|&(anchor, head)| SelectionRange::new(anchor, head))
                .collect();
            Selection::new(ranges, 0).expect("at least one range")
        };

        assert!(selection(&[(0, 6), (3, 1)]).fits(&snapshot));
        assert!(!selection(&[(0, 6), (2, 1)]).fits(&snapshot));
        assert!(!selection(&[(0, 6), (1, 2)]).fits(&snapshot));
        assert!(!selection(&[(0, 7)]).fits(&snapshot));
        assert!(!selection(&[(usize::MAX, 0)]).fits(&snapshot));
    }
}
