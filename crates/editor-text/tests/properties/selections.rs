//! Properties of selections: the form a selection is kept in, compared
//! with a reference that merges ranges two at a time.

use editor_text::{Bias, ChangeSet, Selection, SelectionRange, Shape, Text};
use proptest::collection::vec;
use proptest::prelude::*;
use proptest::sample::select;
use proptest::test_runner::TestCaseError;

use crate::{check, floor, initial_text_to_walk, short_text, walk};

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

/// The reference for mapping: the ends of `selection`'s ranges mapped one
/// at a time with [`ChangeSet::map`] and the bias its shape gives each, a
/// non-empty exclusive range whose mapped start is past its mapped end
/// made a cursor at the mapped start, and the selection built again from
/// those. `None` when an end maps to nothing.
pub(crate) fn mapped_one_by_one(selection: &Selection, changes: &ChangeSet) -> Option<Selection> {
    let shape = selection.shape();
    let mut ranges = Vec::new();
    for range in selection.ranges() {
        let (start, end) = span(range);
        let end_bias = if shape == Shape::Exclusive && start < end {
            Bias::Before
        } else {
            Bias::After
        };
        let start = changes.map(start, Bias::After)?;
        let end = changes.map(end, end_bias)?;
        // Only the two ends of a non-empty exclusive range can swap.
        let end = end.max(start);
        ranges.push(if backward(range) {
            SelectionRange::new(end, start)
        } else {
            SelectionRange::new(start, end)
        });
    }
    Selection::shaped(shape, ranges, selection.primary())
}

#[test]
fn a_mapped_selection_is_its_ends_mapped_and_merged() {
    check(
        1024,
        (short_text(24), walk(), parts(6, usize::MAX)),
        |(initial, walk, mut parts)| {
            let changes = walk.changes(&initial);
            // Ends within the length the change set is for, and now and
            // then one past it.
            let reach = changes.len_before() + 1;
            for (anchor, head) in &mut parts.ranges {
                let past = usize::from(*anchor % 61 == 0);
                (*anchor, *head) = (*anchor % reach + past, *head % reach);
            }
            let selection = parts.selection();
            let fits = selection
                .ranges()
                .iter()
                .all(|range| range.end() <= changes.len_before());

            let mapped = selection.map(&changes);

            prop_assert_eq!(mapped.is_some(), fits);
            prop_assert_eq!(&mapped, &mapped_one_by_one(&selection, &changes));
            if let Some(mapped) = mapped {
                prop_assert!(in_form(&mapped), "{:?}", mapped);
                prop_assert_eq!(mapped.shape(), selection.shape());
                for range in mapped.ranges() {
                    prop_assert!(range.end() <= changes.len_after());
                }
            }
            Ok(())
        },
    );
}

/// One row of a string, found by splitting it on line feeds.
struct Row {
    /// Where the row starts.
    start: usize,
    /// Where its content ends: before its line break.
    content: usize,
    /// Where the row ends, its line feed included if it has one.
    end: usize,
    /// The cells of its content, each a start and an end.
    cells: Vec<(usize, usize)>,
}

/// The rows of `string`.
fn rows(string: &str) -> Vec<Row> {
    let pieces: Vec<&str> = string.split('\n').collect();
    let mut start = 0;
    let mut rows = Vec::new();
    for (index, piece) in pieces.iter().enumerate() {
        let has_line_feed = index + 1 < pieces.len();
        let content = if has_line_feed {
            piece.strip_suffix('\r').unwrap_or(piece)
        } else {
            piece
        };
        // Content holds no carriage return with a line feed after it, so
        // each of its characters is a cell.
        let cells = content
            .char_indices()
            .map(|(at, character)| (start + at, start + at + character.len_utf8()))
            .collect();
        let end = start + piece.len() + usize::from(has_line_feed);
        rows.push(Row {
            start,
            content: start + content.len(),
            end,
            cells,
        });
        start = end;
    }
    rows
}

/// The row of `rows` the position `offset` is in.
fn row_of(rows: &[Row], offset: usize) -> usize {
    rows.iter()
        .rposition(|row| row.start <= offset)
        .unwrap_or(0)
}

/// How many cells of its row start before the position `offset`. A line
/// break is one more cell after the content.
fn column(row: &Row, offset: usize) -> usize {
    let before = row.cells.iter().filter(|cell| cell.0 < offset).count();
    before + usize::from(offset > row.content)
}

/// The reference for extents: what `selection` covers in `string`, found
/// from the string's rows and characters.
fn covered(string: &str, selection: &Selection) -> Vec<(usize, usize)> {
    let rows = rows(string);
    let mut extents = Vec::new();
    for range in selection.ranges() {
        let (start, end) = span(range);
        let (first, last) = (row_of(&rows, start), row_of(&rows, end));
        match selection.shape() {
            Shape::Exclusive => extents.push((start, end)),
            Shape::Inclusive => {
                let rest = &string[end..];
                let cell = if rest.starts_with("\r\n") {
                    2
                } else {
                    rest.chars().next().map_or(0, char::len_utf8)
                };
                extents.push((start, end + cell));
            }
            Shape::Line => extents.push((rows[first].start, rows[last].end)),
            Shape::Block => {
                let one = column(&rows[row_of(&rows, range.anchor)], range.anchor);
                let other = column(&rows[row_of(&rows, range.head)], range.head);
                let (lower, higher) = (one.min(other), one.max(other));
                for row in &rows[first..=last] {
                    extents.push(match row.cells.get(lower) {
                        Some(from) => {
                            let through = higher.min(row.cells.len() - 1);
                            (from.0, row.cells[through].1)
                        }
                        None => (row.content, row.content),
                    });
                }
            }
        }
    }
    // Extents merge as exclusive ranges do.
    merged_pairwise(Shape::Exclusive, &extents)
}

#[test]
fn extents_agree_with_a_reference_on_a_string() {
    check(
        1024,
        (initial_text_to_walk(), parts(5, usize::MAX)),
        |(string, mut parts)| {
            for (anchor, head) in &mut parts.ranges {
                *anchor = floor(&string, *anchor % (string.len() + 1));
                *head = floor(&string, *head % (string.len() + 1));
            }
            let selection = parts.selection();
            let snapshot = Text::from(string.as_str()).snapshot();

            let extents = snapshot.extents(&selection);

            let Some(extents) = extents else {
                return Err(TestCaseError::fail("a selection that fits has no extents"));
            };
            let extents: Vec<_> = extents
                .into_iter()
                .map(|extent| (extent.start, extent.end))
                .collect();
            prop_assert_eq!(&extents, &covered(&string, &selection));
            for (index, &(start, end)) in extents.iter().enumerate() {
                // Two positions in order.
                prop_assert!(start <= end);
                prop_assert!(string.is_char_boundary(start) && string.is_char_boundary(end));
                // Sorted, and no two overlap.
                if let Some(&next) = extents.get(index + 1) {
                    prop_assert!((start, end) <= next);
                    prop_assert!(!overlap(Shape::Exclusive, (start, end), next));
                }
            }
            Ok(())
        },
    );
}

#[test]
fn a_selection_that_does_not_fit_has_no_extents() {
    check(
        512,
        (short_text(12), parts(4, usize::MAX)),
        |(string, mut parts)| {
            for (anchor, head) in &mut parts.ranges {
                *anchor %= string.len() + 3;
                *head %= string.len() + 3;
            }
            let selection = parts.selection();
            let fits = selection.ranges().iter().all(|range| {
                string.is_char_boundary(range.anchor) && string.is_char_boundary(range.head)
            });

            let extents = Text::from(string.as_str()).snapshot().extents(&selection);

            prop_assert_eq!(extents.is_some(), fits);
            Ok(())
        },
    );
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
