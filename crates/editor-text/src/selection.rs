//! A selection: ranges of one shape, sorted and merged, one of them the
//! primary.
//!
//! A range is two byte offsets. The constructor has no text, so the form
//! it keeps a selection in is a rule about offsets alone; whether the ends
//! are positions of a text is the crate's one check of a selection against
//! a snapshot.

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

    /// The lower of the two ends.
    pub fn start(&self) -> usize {
        self.anchor.min(self.head)
    }

    /// The higher of the two ends.
    pub fn end(&self) -> usize {
        self.anchor.max(self.head)
    }

    /// Whether the head is before the anchor. A range with equal ends
    /// points forward.
    fn is_backward(&self) -> bool {
        self.head < self.anchor
    }

    /// The range from `start` to `end`, with its head at `start` when
    /// `backward` and at `end` otherwise.
    fn pointing(start: usize, end: usize, backward: bool) -> Self {
        if backward {
            Self::new(end, start)
        } else {
            Self::new(start, end)
        }
    }
}

impl Shape {
    /// Whether `later`, which starts at or after `earlier`, overlaps it by
    /// this shape's rule ([`Selection`]).
    fn overlap(self, earlier: &SelectionRange, later: &SelectionRange) -> bool {
        match self {
            Self::Exclusive => later.start() < earlier.end() || later.start() == earlier.start(),
            Self::Inclusive | Self::Line | Self::Block => later.start() <= earlier.end(),
        }
    }
}

/// What the ranges of a selection cover, given their two ends. A selection
/// has one shape for all its ranges.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Shape {
    /// From the lower end up to, not including, the higher: the ends are
    /// between characters. A range with equal ends is a bar cursor.
    #[default]
    Exclusive,
    /// From the lower end through the character at the higher: both ends
    /// are on characters. A range with equal ends is a cursor on one.
    Inclusive,
    /// The whole rows of both ends and those between them.
    Line,
    /// A rectangle of characters whose corners are the two ends.
    Block,
}

/// One or more ranges of one shape, one of which is the primary.
///
/// A selection is always in one form, whatever it was built from:
///
/// - its ranges are sorted by where they start, and then by where they
///   end;
/// - no two of them overlap, by the rule of its shape (below);
/// - ranges that were given and overlap are one range, from the lowest
///   start to the highest end;
/// - the primary is the range the one given as primary ended in.
///
/// **When two ranges overlap.** In an [`Shape::Exclusive`] selection, when
/// the later starts before the earlier ends, or the two start at one
/// offset: so two cursors at one place are one and a cursor at the start
/// of a range is in it, while ranges that only touch stay two. In the
/// other shapes both ends are on characters, so two ranges overlap when
/// the later starts at or before the earlier's end.
///
/// **Which way a merged range points.** The way the primary did, if the
/// primary is among the ranges it is made of, and otherwise the way the
/// first of them did, in the sorted order (of two that start and end
/// alike, the one given first). A range with equal ends points forward.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Selection {
    /// What the ranges cover.
    shape: Shape,
    /// The ranges, sorted and merged. Never empty.
    ranges: Vec<SelectionRange>,
    /// Which of the ranges is the primary one: an index into `ranges`.
    primary: usize,
}

impl Selection {
    /// The [`Shape::Exclusive`] selection of `ranges`
    /// ([`shaped`](Self::shaped)).
    pub fn new(ranges: Vec<SelectionRange>, primary: usize) -> Option<Self> {
        Self::shaped(Shape::Exclusive, ranges, primary)
    }

    /// The selection of `ranges` with the shape `shape`, whose primary
    /// range is the one at the index `primary` of `ranges`. The ranges are
    /// sorted, and those that overlap are made one, as the type's docs
    /// say. `None` when there is no range, or `primary` names none.
    pub fn shaped(shape: Shape, ranges: Vec<SelectionRange>, primary: usize) -> Option<Self> {
        if primary >= ranges.len() {
            return None;
        }
        // Sorted with the place each was given at, so the primary can be
        // followed. The sort is stable: of two ranges that start and end
        // alike, the one given first stays first.
        let mut given: Vec<(usize, SelectionRange)> = ranges.into_iter().enumerate().collect();
        given.sort_by_key(|(_, range)| (range.start(), range.end()));

        // One walk: a range either joins the last merged range or starts
        // the next. A range that overlaps none of the last one's cannot
        // overlap an earlier one, since those end no later.
        let mut merged: Vec<SelectionRange> = Vec::with_capacity(given.len());
        let mut merged_primary = 0;
        for (index, range) in given {
            let is_primary = index == primary;
            match merged.last_mut() {
                Some(last) if shape.overlap(last, &range) => {
                    // The last one already points the way its first range
                    // did, or the primary if the primary is in it.
                    let leader = if is_primary { range } else { *last };
                    *last = SelectionRange::pointing(
                        last.start(),
                        last.end().max(range.end()),
                        leader.is_backward(),
                    );
                }
                _ => merged.push(range),
            }
            if is_primary {
                merged_primary = merged.len() - 1;
            }
        }
        Some(Self {
            shape,
            ranges: merged,
            primary: merged_primary,
        })
    }

    /// What the ranges cover.
    pub fn shape(&self) -> Shape {
        self.shape
    }

    /// The ranges, sorted and merged. Never empty.
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

    /// The three shapes whose ranges have both ends on characters.
    const ON_CHARACTERS: [Shape; 3] = [Shape::Inclusive, Shape::Line, Shape::Block];

    /// The ranges, as anchor and head, and the primary of the selection of
    /// shape `shape` built from `ranges`, given as anchor and head.
    fn built(
        shape: Shape,
        ranges: &[(usize, usize)],
        primary: usize,
    ) -> (Vec<(usize, usize)>, usize) {
        let ranges = ranges
            .iter()
            .map(|&(anchor, head)| SelectionRange::new(anchor, head))
            .collect();
        let selection = Selection::shaped(shape, ranges, primary).expect("a primary among them");
        let ranges = selection
            .ranges()
            .iter()
            .map(|range| (range.anchor, range.head))
            .collect();
        (ranges, selection.primary())
    }

    #[test]
    fn a_shaped_selection_with_no_range_or_no_such_primary_is_none() {
        for shape in ON_CHARACTERS {
            assert_eq!(Selection::shaped(shape, Vec::new(), 0), None);
            assert_eq!(
                Selection::shaped(shape, vec![SelectionRange::new(0, 1)], 1),
                None
            );
        }
    }

    #[test]
    fn a_range_starts_at_its_lower_end_and_ends_at_its_higher() {
        assert_eq!(SelectionRange::new(2, 7).start(), 2);
        assert_eq!(SelectionRange::new(2, 7).end(), 7);
        assert_eq!(SelectionRange::new(7, 2).start(), 2);
        assert_eq!(SelectionRange::new(7, 2).end(), 7);
        assert_eq!(SelectionRange::new(4, 4).start(), 4);
        assert_eq!(SelectionRange::new(4, 4).end(), 4);
    }

    #[test]
    fn new_makes_the_exclusive_shape_and_shaped_the_shape_it_is_given() {
        let ranges = vec![SelectionRange::new(0, 1)];

        let plain = Selection::new(ranges.clone(), 0).expect("one range");

        assert_eq!(plain.shape(), Shape::Exclusive);
        assert_eq!(
            Some(plain),
            Selection::shaped(Shape::Exclusive, ranges.clone(), 0)
        );
        for shape in ON_CHARACTERS {
            let selection = Selection::shaped(shape, ranges.clone(), 0).expect("one range");
            assert_eq!(selection.shape(), shape);
        }
    }

    #[test]
    fn the_ranges_come_back_sorted_by_start_and_then_by_end() {
        let given = [(9, 7), (0, 1), (4, 3), (12, 20), (12, 15)];

        assert_eq!(
            built(Shape::Exclusive, &given, 0).0,
            [(0, 1), (4, 3), (9, 7), (12, 20)]
        );
        // Apart, by the rule of every shape.
        for shape in ON_CHARACTERS {
            assert_eq!(
                built(shape, &[(9, 7), (0, 1), (4, 3)], 0).0,
                [(0, 1), (4, 3), (9, 7)]
            );
        }
    }

    #[test]
    fn exclusive_ranges_that_only_touch_stay_two() {
        assert_eq!(
            built(Shape::Exclusive, &[(0, 2), (2, 5)], 0).0,
            [(0, 2), (2, 5)]
        );
        assert_eq!(
            built(Shape::Exclusive, &[(5, 2), (2, 0)], 0).0,
            [(2, 0), (5, 2)]
        );
    }

    #[test]
    fn exclusive_ranges_overlap_when_the_later_starts_before_the_earlier_ends() {
        assert_eq!(built(Shape::Exclusive, &[(0, 3), (2, 5)], 0).0, [(0, 5)]);
        assert_eq!(built(Shape::Exclusive, &[(2, 5), (0, 3)], 1).0, [(0, 5)]);
    }

    #[test]
    fn exclusive_ranges_that_start_at_one_offset_are_one() {
        // Two cursors at one place.
        assert_eq!(built(Shape::Exclusive, &[(2, 2), (2, 2)], 0).0, [(2, 2)]);
        // A cursor at the start of a range is in it.
        assert_eq!(built(Shape::Exclusive, &[(2, 5), (2, 2)], 0).0, [(2, 5)]);
        assert_eq!(built(Shape::Exclusive, &[(2, 4), (2, 7)], 0).0, [(2, 7)]);
    }

    #[test]
    fn an_exclusive_cursor_at_the_end_of_a_range_is_not_in_it() {
        assert_eq!(
            built(Shape::Exclusive, &[(2, 5), (5, 5)], 0).0,
            [(2, 5), (5, 5)]
        );
        // And a range that starts where both are is one with the cursor.
        assert_eq!(
            built(Shape::Exclusive, &[(2, 5), (5, 5), (5, 8)], 0).0,
            [(2, 5), (5, 8)]
        );
    }

    #[test]
    fn a_range_inside_another_is_part_of_it() {
        assert_eq!(built(Shape::Exclusive, &[(0, 9), (3, 4)], 0).0, [(0, 9)]);
        for shape in ON_CHARACTERS {
            assert_eq!(built(shape, &[(0, 9), (3, 4)], 0).0, [(0, 9)]);
        }
    }

    #[test]
    fn three_ranges_that_chain_are_one() {
        assert_eq!(
            built(Shape::Exclusive, &[(4, 8), (0, 3), (2, 5), (8, 9)], 1).0,
            [(0, 8), (8, 9)]
        );
        for shape in ON_CHARACTERS {
            assert_eq!(
                built(shape, &[(4, 8), (0, 3), (2, 5), (10, 11)], 1).0,
                [(0, 8), (10, 11)]
            );
        }
    }

    #[test]
    fn ranges_on_characters_overlap_when_the_later_starts_at_or_before_the_earliers_end() {
        for shape in ON_CHARACTERS {
            // They share the character at 2.
            assert_eq!(built(shape, &[(0, 2), (2, 5)], 0).0, [(0, 5)], "{shape:?}");
            // A cursor on the last character of a range.
            assert_eq!(built(shape, &[(2, 5), (5, 5)], 0).0, [(2, 5)], "{shape:?}");
            assert_eq!(built(shape, &[(2, 2), (2, 2)], 0).0, [(2, 2)], "{shape:?}");
            // Neighbouring characters are two ranges.
            assert_eq!(
                built(shape, &[(0, 2), (3, 5)], 0).0,
                [(0, 2), (3, 5)],
                "{shape:?}"
            );
        }
    }

    #[test]
    fn a_merged_range_points_the_way_the_primary_did_when_the_primary_is_in_it() {
        assert_eq!(
            built(Shape::Exclusive, &[(0, 3), (5, 2)], 1),
            (vec![(5, 0)], 0)
        );
        assert_eq!(
            built(Shape::Exclusive, &[(0, 3), (5, 2)], 0),
            (vec![(0, 5)], 0)
        );
        assert_eq!(
            built(Shape::Inclusive, &[(3, 0), (2, 5)], 1),
            (vec![(0, 5)], 0)
        );
        // A primary with equal ends points forward.
        assert_eq!(
            built(Shape::Exclusive, &[(5, 2), (2, 2)], 1),
            (vec![(2, 5)], 0)
        );
    }

    #[test]
    fn a_merged_range_without_the_primary_points_the_way_its_first_range_did() {
        assert_eq!(
            built(Shape::Exclusive, &[(5, 2), (0, 3), (9, 9)], 2),
            (vec![(0, 5), (9, 9)], 1)
        );
        assert_eq!(
            built(Shape::Exclusive, &[(2, 5), (3, 0), (9, 9)], 2),
            (vec![(5, 0), (9, 9)], 1)
        );
        // Of two that start and end alike, the one given first.
        assert_eq!(
            built(Shape::Line, &[(4, 1), (1, 4), (9, 9)], 2),
            (vec![(4, 1), (9, 9)], 1)
        );
    }

    #[test]
    fn the_primary_is_the_range_the_given_primary_ended_in() {
        let given = [(9, 7), (0, 1), (4, 3)];
        assert_eq!(built(Shape::Exclusive, &given, 0).1, 2);
        assert_eq!(built(Shape::Exclusive, &given, 1).1, 0);
        assert_eq!(built(Shape::Exclusive, &given, 2).1, 1);

        // (20, 22) and (21, 25) are one range, the second of three.
        let merging = [(21, 25), (30, 31), (0, 1), (20, 22)];
        assert_eq!(
            built(Shape::Exclusive, &merging, 0),
            (vec![(0, 1), (20, 25), (30, 31)], 1)
        );
        assert_eq!(built(Shape::Exclusive, &merging, 3).1, 1);
        assert_eq!(built(Shape::Exclusive, &merging, 1).1, 2);
        assert_eq!(built(Shape::Exclusive, &merging, 2).1, 0);
    }

    #[test]
    fn building_a_selection_again_from_its_ranges_changes_nothing() {
        let ranges = vec![
            SelectionRange::new(9, 4),
            SelectionRange::new(0, 6),
            SelectionRange::new(9, 4),
            SelectionRange::new(2, 2),
            SelectionRange::new(12, 12),
        ];
        let selection = Selection::new(ranges, 3).expect("a primary among the ranges");

        let again = Selection::new(selection.ranges().to_vec(), selection.primary());

        assert_eq!(again, Some(selection));
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

        // The ranges are apart, so each is still a range of the selection:
        // an end of a range that merged into another is no end any more.
        assert!(selection(&[(0, 1), (6, 3)]).fits(&snapshot));
        assert!(!selection(&[(0, 1), (6, 2)]).fits(&snapshot));
        assert!(!selection(&[(1, 2), (3, 6)]).fits(&snapshot));
        assert!(selection(&[(0, 6), (2, 1)]).fits(&snapshot));
        assert!(!selection(&[(0, 7)]).fits(&snapshot));
        assert!(!selection(&[(usize::MAX, 0)]).fits(&snapshot));
    }
}
