//! A view's wrap indents resolved for its snapshot: which rows each
//! covers, and the indent a segment of a row is laid out under.
//!
//! An indent ([`WrapIndent`]) covers the rows its range has a byte in, a
//! line break being the row's it ends, or the row of `start` when the
//! range is empty: the fold rule ([`folds`](crate::folds)). An offset past
//! the end is the end, and one inside a character is moved back to its
//! start. Of two indents over a row the later one listed wins. They are
//! kept in whole points, so that a query after a change of scale lays a
//! row out under them at the new scale, as the stops are.
//!
//! A row is laid out segment by segment ([`SEGMENT_BYTES`]), each on its
//! own. Its first segment is under the indent's first-line and
//! continuation indents. A later segment starts on a continuation line,
//! so it is under the continuation indent for every line of it; a hanging
//! indent's lead is measured on the first segment alone, so a later
//! segment of a hanging row is at the first-line indent.
//!
//! [`SEGMENT_BYTES`]: crate::tabs::SEGMENT_BYTES

use editor_text::Snapshot;

use crate::pixels;
use crate::scene::{Continuation, WrapIndent};
use crate::tabs::{boundary_at_or_before, row_content};

/// The indent one segment is laid out under, in pixels.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SegmentIndent {
    /// Where its first visual line starts, from the start of the text row.
    pub first: f32,
    /// Where each later visual line starts.
    pub rest: SegmentRest,
}

/// Where the later visual lines of a segment start.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SegmentRest {
    /// At this x, in pixels from the start of the text row.
    Pixels(f32),
    /// Where the segment's first this many bytes end: a character
    /// boundary of the segment, or at or past its end, which hangs at the
    /// first-line indent.
    Lead(usize),
}

/// A view's indents, resolved for its snapshot, in points.
#[derive(Clone, Default)]
pub(crate) struct RowIndents {
    /// The snapshot they were resolved for; none when there is no indent.
    snapshot: Option<Snapshot>,
    /// The rows each covers, first and last, with its indent, in the
    /// order they were listed.
    covers: Vec<(usize, usize, WrapIndent)>,
}

/// `indents`, a view's, resolved for `snapshot`.
pub(crate) fn resolved(snapshot: &Snapshot, indents: &[WrapIndent]) -> RowIndents {
    if indents.is_empty() {
        return RowIndents::default();
    }
    let row_of = |offset: usize| {
        snapshot
            .offset_to_point(boundary_at_or_before(snapshot, offset))
            .map_or(0, |point| point.row)
    };
    let covers = indents
        .iter()
        .map(|indent| {
            let start = boundary_at_or_before(snapshot, indent.start.min(snapshot.len()));
            let stop = indent.stop.min(snapshot.len()).max(start);
            let first = row_of(start);
            let last = if stop > start {
                row_of(stop - 1)
            } else {
                first
            };
            (first, last, *indent)
        })
        .collect();
    RowIndents {
        snapshot: Some(snapshot.clone()),
        covers,
    }
}

impl RowIndents {
    /// The indent of `row`, if one covers it: the later listed of those
    /// that do.
    fn covering(&self, row: usize) -> Option<&WrapIndent> {
        self.covers
            .iter()
            .rev()
            .find(|(first, last, _)| (*first..=*last).contains(&row))
            .map(|(_, _, indent)| indent)
    }

    /// The indent `row`'s `segment` is laid out under at `scale`, in
    /// pixels; none when no indent covers the row.
    pub(crate) fn of(&self, row: usize, segment: usize, scale: f32) -> Option<SegmentIndent> {
        let indent = self.covering(row)?;
        let first = pixels(indent.first, scale);
        Some(match (indent.rest, segment) {
            (Continuation::Points(rest), 0) => SegmentIndent {
                first,
                rest: SegmentRest::Pixels(pixels(rest, scale)),
            },
            (Continuation::Lead(bytes), 0) => SegmentIndent {
                first,
                rest: SegmentRest::Lead(self.lead(row, bytes)),
            },
            (Continuation::Points(rest), _) => {
                let rest = pixels(rest, scale);
                SegmentIndent {
                    first: rest,
                    rest: SegmentRest::Pixels(rest),
                }
            }
            (Continuation::Lead(_), _) => SegmentIndent {
                first,
                rest: SegmentRest::Pixels(first),
            },
        })
    }

    /// The lead of `bytes` on `row`, moved back to a character boundary
    /// inside the row; at or past the row's end, as it is.
    fn lead(&self, row: usize, bytes: usize) -> usize {
        let Some(snapshot) = &self.snapshot else {
            return bytes;
        };
        let Some(content) = row_content(snapshot, row) else {
            return bytes;
        };
        let at = content.start.saturating_add(bytes);
        if at >= content.end {
            return bytes;
        }
        boundary_at_or_before(snapshot, at) - content.start
    }
}

#[cfg(test)]
mod tests {
    use editor_text::Text;

    use super::{SegmentIndent, SegmentRest, resolved};
    use crate::scene::{Continuation, WrapIndent};

    /// An indent over `start..stop`, `first` points in, continued at
    /// `rest` points.
    fn points(start: usize, stop: usize, first: u32, rest: u32) -> WrapIndent {
        WrapIndent {
            start,
            stop,
            first,
            rest: Continuation::Points(rest),
        }
    }

    /// The segment indent of `first` and `rest` pixels.
    fn pixels(first: f32, rest: f32) -> Option<SegmentIndent> {
        Some(SegmentIndent {
            first,
            rest: SegmentRest::Pixels(rest),
        })
    }

    #[test]
    fn a_range_covers_the_rows_that_hold_one_of_its_bytes() {
        let snapshot = Text::from("ab\ncd\nef\ngh").snapshot();
        // From `b` to the line break that ends row 1: rows 0 and 1.
        let indents = resolved(&snapshot, &[points(1, 6, 10, 20)]);
        let covered: Vec<bool> = (0..4)
            .map(|row| indents.of(row, 0, 1.0).is_some())
            .collect();
        assert_eq!(covered, vec![true, true, false, false]);
        assert_eq!(indents.of(0, 0, 1.0), pixels(10.0, 20.0));
    }

    #[test]
    fn an_empty_range_covers_its_starts_row() {
        let snapshot = Text::from("ab\ncd").snapshot();
        let indents = resolved(&snapshot, &[points(4, 4, 10, 20)]);
        assert!(indents.of(0, 0, 1.0).is_none());
        assert_eq!(indents.of(1, 0, 1.0), pixels(10.0, 20.0));
    }

    #[test]
    fn an_offset_past_the_end_counts_as_the_end() {
        let snapshot = Text::from("ab\ncd").snapshot();
        let indents = resolved(&snapshot, &[points(40, 90, 10, 20)]);
        assert!(indents.of(0, 0, 1.0).is_none());
        assert_eq!(indents.of(1, 0, 1.0), pixels(10.0, 20.0));
    }

    #[test]
    fn a_lead_inside_a_character_is_moved_back_to_its_start() {
        // `•` is bytes 1, 2 and 3 of row 1.
        let snapshot = Text::from("x\n-•ab").snapshot();
        let lead = |bytes| WrapIndent {
            start: 2,
            stop: 2,
            first: 0,
            rest: Continuation::Lead(bytes),
        };
        let rest = |bytes| {
            resolved(&snapshot, &[lead(bytes)])
                .of(1, 0, 1.0)
                .unwrap()
                .rest
        };
        assert_eq!(rest(3), SegmentRest::Lead(1));
        assert_eq!(rest(4), SegmentRest::Lead(4));
        // At or past the row's end, as it is.
        assert_eq!(rest(6), SegmentRest::Lead(6));
    }

    #[test]
    fn of_two_indents_over_a_row_the_later_listed_wins() {
        let snapshot = Text::from("ab\ncd").snapshot();
        let indents = resolved(&snapshot, &[points(0, 5, 10, 20), points(3, 4, 30, 40)]);
        assert_eq!(indents.of(0, 0, 1.0), pixels(10.0, 20.0));
        assert_eq!(indents.of(1, 0, 1.0), pixels(30.0, 40.0));
    }

    #[test]
    fn a_later_segment_is_at_the_continuation_indent() {
        let snapshot = Text::from("abc").snapshot();
        let indents = resolved(&snapshot, &[points(0, 1, 10, 20)]);
        assert_eq!(indents.of(0, 1, 1.0), pixels(20.0, 20.0));
        // A hanging row's later segment, at its first-line indent.
        let hanging = WrapIndent {
            rest: Continuation::Lead(2),
            ..points(0, 1, 10, 0)
        };
        let indents = resolved(&snapshot, &[hanging]);
        assert_eq!(indents.of(0, 3, 1.0), pixels(10.0, 10.0));
    }

    #[test]
    fn points_are_pixels_at_the_scale() {
        let snapshot = Text::from("abc").snapshot();
        let indents = resolved(&snapshot, &[points(0, 1, 10, 20)]);
        assert_eq!(indents.of(0, 0, 2.0), pixels(20.0, 40.0));
        assert_eq!(indents.of(0, 0, 1.5), pixels(15.0, 30.0));
    }
}
