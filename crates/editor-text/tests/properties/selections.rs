//! Properties of selections: the form a selection is kept in, compared
//! with a reference that merges ranges two at a time.

use editor_text::{Selection, SelectionRange, Shape};
use proptest::collection::vec;
use proptest::prelude::*;
use proptest::sample::select;

use crate::check;

/// Every shape a selection can have.
pub(crate) const SHAPES: [Shape; 4] = [
    Shape::Exclusive,
    Shape::Inclusive,
    Shape::Line,
    Shape::Block,
];

/// What a selection is built from, before it is fitted to anything.
#[derive(Debug, Clone)]
pub(crate) struct Parts {
    /// The selection's shape.
    pub(crate) shape: Shape,
    /// The ranges, as anchor and head.
    pub(crate) ranges: Vec<(usize, usize)>,
    /// Which range is the primary, as a number to cut down to the ranges.
    pub(crate) primary: usize,
}

impl Parts {
    /// The index of the primary among the ranges.
    pub(crate) fn primary(&self) -> usize {
        self.primary % self.ranges.len()
    }

    /// The ranges as the crate's type.
    pub(crate) fn ranges(&self) -> Vec<SelectionRange> {
        self.ranges
            .iter()
            .map(|&(anchor, head)| SelectionRange::new(anchor, head))
            .collect()
    }

    /// The selection of these parts.
    pub(crate) fn selection(&self) -> Selection {
        Selection::shaped(self.shape, self.ranges(), self.primary())
            .expect("at least one range, and a primary among them")
    }
}

/// One to `ranges` ranges with ends below `reach`, of any shape. The ends
/// are few enough values that ranges often touch, start together and
/// overlap.
pub(crate) fn parts(ranges: usize, reach: usize) -> impl Strategy<Value = Parts> {
    (
        select(&SHAPES[..]),
        vec((0..reach, 0..reach), 1..=ranges),
        any::<usize>(),
    )
        .prop_map(|(shape, ranges, primary)| Parts {
            shape,
            ranges,
            primary,
        })
}

/// Whether two ranges, each a start and an end, overlap by the rule of
/// `shape`.
pub(crate) fn overlap(shape: Shape, one: (usize, usize), other: (usize, usize)) -> bool {
    let (earlier, later) = if one <= other {
        (one, other)
    } else {
        (other, one)
    };
    match shape {
        Shape::Exclusive => later.0 < earlier.1 || later.0 == earlier.0,
        Shape::Inclusive | Shape::Line | Shape::Block => later.0 <= earlier.1,
    }
}

/// The reference: `ranges`, each a start and an end, with any two that
/// overlap replaced by their union, again and again until no two do,
/// sorted.
pub(crate) fn merged_pairwise(shape: Shape, ranges: &[(usize, usize)]) -> Vec<(usize, usize)> {
    let mut ranges = ranges.to_vec();
    // Each merge removes a range, so this ends.
    'again: loop {
        for one in 0..ranges.len() {
            for other in one + 1..ranges.len() {
                if overlap(shape, ranges[one], ranges[other]) {
                    let removed = ranges.remove(other);
                    let kept = &mut ranges[one];
                    *kept = (kept.0.min(removed.0), kept.1.max(removed.1));
                    continue 'again;
                }
            }
        }
        break;
    }
    ranges.sort_unstable();
    ranges
}

/// A range as its start and its end.
pub(crate) fn span(range: &SelectionRange) -> (usize, usize) {
    (range.start(), range.end())
}

/// Whether a range points backward: its head is before its anchor.
fn backward(range: &SelectionRange) -> bool {
    range.head < range.anchor
}

/// Whether `selection` is in the form the crate keeps one in: sorted, and
/// no two of its ranges overlapping.
pub(crate) fn in_form(selection: &Selection) -> bool {
    let spans: Vec<_> = selection.ranges().iter().map(span).collect();
    let sorted = spans.windows(2).all(|pair| pair[0] <= pair[1]);
    let apart = (0..spans.len()).all(|one| {
        (one + 1..spans.len()).all(|other| !overlap(selection.shape(), spans[one], spans[other]))
    });
    sorted && apart && selection.primary() < spans.len()
}

#[test]
fn overlapping_selections_merge() {
    check(2048, parts(8, 24), |parts| {
        let given = parts.ranges();
        let shape = parts.shape;

        let selection = parts.selection();

        prop_assert_eq!(selection.shape(), shape);
        // Sorted, and no two overlap.
        prop_assert!(in_form(&selection), "{:?}", selection);
        // Each is the union of given ranges.
        let spans: Vec<_> = selection.ranges().iter().map(span).collect();
        let given_spans: Vec<_> = given.iter().map(span).collect();
        prop_assert_eq!(&spans, &merged_pairwise(shape, &given_spans));
        // Every given range lies inside exactly one of them: the one that
        // holds it and that it overlaps.
        let holder = |range: &SelectionRange| -> Vec<usize> {
            let inner = span(range);
            (0..spans.len())
                .filter(|&index| {
                    let outer = spans[index];
                    outer.0 <= inner.0 && inner.1 <= outer.1 && overlap(shape, outer, inner)
                })
                .collect()
        };
        for range in &given {
            prop_assert_eq!(holder(range).len(), 1, "{:?} in {:?}", range, selection);
        }
        // The primary is the range the given primary lies in.
        let primary = &given[parts.primary()];
        prop_assert_eq!(holder(primary), vec![selection.primary()]);
        // Each points the way the primary did, or its first range did.
        let mut sorted = given.clone();
        sorted.sort_by_key(span);
        for (index, range) in selection.ranges().iter().enumerate() {
            let leader = if index == selection.primary() {
                primary
            } else {
                sorted
                    .iter()
                    .find(|given| holder(given) == [index])
                    .expect("a union of given ranges")
            };
            prop_assert_eq!(backward(range), backward(leader), "{:?}", selection);
        }
        // Building again from the result changes nothing.
        let again = Selection::shaped(shape, selection.ranges().to_vec(), selection.primary());
        prop_assert_eq!(again, Some(selection));
        Ok(())
    });
}
