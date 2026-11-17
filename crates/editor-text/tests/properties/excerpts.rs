//! Properties of excerpt texts: each builds an excerpt text over two
//! generated sources and compares it with a reference, the ranges' strings
//! joined by a line feed, and, once the sources are edited, with each
//! excerpt's two ends kept as anchors mapped by hand.

use std::ops::Range;

use editor_text::excerpt::{Excerpts, SourceKey, Wanted};
use editor_text::{
    Anchor, Bias, ChangeSet, Marker, Origin, Point, PointCells, PointUtf16, Selection,
    SelectionRange, Text, Transaction,
};
use proptest::collection::vec;
use proptest::prelude::*;

use crate::motions::{count_or_column, motions, row_motions, text_and_edits};
use crate::{
    Walk, applied, check, edited, fitted_walk, floor, initial_text_to_walk, patched, steps,
};

/// The keys of the two sources.
const KEYS: [SourceKey; 2] = [SourceKey(0), SourceKey(1)];

/// One excerpt before it is fitted to its source: which source, and two
/// numbers to cut down to positions of it.
#[derive(Debug, Clone)]
struct Pick {
    /// Which of the two sources.
    source: usize,
    /// One end, as a number to cut down to the source.
    one: usize,
    /// The other end, likewise.
    other: usize,
}

impl Pick {
    /// The excerpt this pick names in `sources`: two positions of its
    /// source, in order.
    fn wanted(&self, sources: &[String; 2]) -> Wanted {
        let text = &sources[self.source];
        let reach = text.len() + 1;
        let (one, other) = (
            floor(text, self.one % reach),
            floor(text, self.other % reach),
        );
        Wanted {
            source: KEYS[self.source],
            range: one.min(other)..one.max(other),
        }
    }
}

/// Up to `count` excerpts of the two sources.
fn picks(count: usize) -> impl Strategy<Value = Vec<Pick>> {
    let pick = (0..2_usize, any::<usize>(), any::<usize>()).prop_map(|(source, one, other)| Pick {
        source,
        one,
        other,
    });
    vec(pick, 0..=count)
}

/// The excerpts of `picks` in `sources`.
fn list(picks: &[Pick], sources: &[String; 2]) -> Vec<Wanted> {
    picks.iter().map(|pick| pick.wanted(sources)).collect()
}

/// What an excerpt text of `list` over `sources` holds: the ranges'
/// strings joined by a line feed.
fn joined(list: &[Wanted], sources: &[String; 2]) -> String {
    list.iter()
        .map(|excerpt| {
            let index = KEYS
                .iter()
                .position(|key| *key == excerpt.source)
                .unwrap_or(0);
            &sources[index][excerpt.range.clone()]
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// An excerpt text of `list` over `texts`.
fn excerpt_text(texts: &mut [Text; 2], list: &[Wanted]) -> Result<(Excerpts, Text), TestCaseError> {
    let mut excerpts = Excerpts::new();
    let mut assembled = Text::new();
    let [first, second] = texts;
    excerpts
        .set(
            &mut assembled,
            list,
            &mut [(KEYS[0], first), (KEYS[1], second)],
        )
        .map_err(|refusal| TestCaseError::fail(format!("{refusal}")))?;
    Ok((excerpts, assembled))
}

#[test]
fn an_excerpt_text_reads_its_ranges_joined_by_line_feeds() {
    let sources = (
        (initial_text_to_walk(), steps(4)),
        (initial_text_to_walk(), steps(4)),
    );
    check(
        128,
        (sources, picks(4)),
        |(((one, one_steps), (two, two_steps)), picks)| {
            let (one, one_string) = edited(one, &one_steps);
            let (two, two_string) = edited(two, &two_steps);
            let strings = [one_string, two_string];
            let mut texts = [Text::from_snapshot(&one), Text::from_snapshot(&two)];
            let list = list(&picks, &strings);

            let (_, assembled) = excerpt_text(&mut texts, &list)?;

            let reference = joined(&list, &strings);
            let snapshot = assembled.snapshot();
            let plain = Text::from(reference.as_str()).snapshot();
            prop_assert_eq!(snapshot.to_string(), reference.clone());
            prop_assert_eq!(snapshot.chunks().collect::<String>(), reference.clone());
            prop_assert_eq!(snapshot.row_count(), plain.row_count());
            for row in 0..=plain.row_count() {
                prop_assert_eq!(snapshot.row_to_string(row), plain.row_to_string(row));
            }
            for offset in 0..=reference.len() + 1 {
                prop_assert_eq!(
                    snapshot.offset_to_point(offset),
                    plain.offset_to_point(offset)
                );
                prop_assert_eq!(
                    snapshot.offset_to_point_utf16(offset),
                    plain.offset_to_point_utf16(offset)
                );
                prop_assert_eq!(
                    snapshot.offset_to_point_cells(offset),
                    plain.offset_to_point_cells(offset)
                );
                if let Some(point) = plain.offset_to_point(offset) {
                    prop_assert_eq!(snapshot.point_to_offset(point), Some(offset));
                    let utf16 = plain
                        .offset_to_point_utf16(offset)
                        .unwrap_or(PointUtf16::new(0, 0));
                    prop_assert_eq!(snapshot.point_utf16_to_offset(utf16), Some(offset));
                    let cells = plain
                        .offset_to_point_cells(offset)
                        .unwrap_or(PointCells::new(0, 0));
                    prop_assert_eq!(snapshot.point_cells_to_offset(cells), Some(offset));
                }
            }
            prop_assert_eq!(
                snapshot.point_to_offset(Point::new(plain.row_count(), 0)),
                None
            );
            Ok(())
        },
    );
}

#[test]
fn every_motion_over_an_excerpt_text_is_the_motion_over_a_plain_text_of_its_contents() {
    let rows = vec((count_or_column(), count_or_column()), 2);
    let sources = (text_and_edits(), text_and_edits());
    check(
        64,
        (sources, picks(3), rows),
        |(((one, one_steps), (two, two_steps)), picks, rows)| {
            let (one, one_string) = edited(one, &one_steps);
            let (two, two_string) = edited(two, &two_steps);
            let strings = [one_string, two_string];
            let mut texts = [Text::from_snapshot(&one), Text::from_snapshot(&two)];
            let list = list(&picks, &strings);
            let (excerpts, assembled) = excerpt_text(&mut texts, &list)?;
            let snapshot = assembled.snapshot();
            let contents = snapshot.to_string();
            let plain = Text::from(contents.as_str()).snapshot();
            let mut motions = motions();
            motions.extend(row_motions(&rows));

            // Every position of every excerpt, both ends included: those right
            // before and right after a separator among them.
            for placed in excerpts.placed() {
                for offset in placed.range.clone() {
                    for &motion in &motions {
                        prop_assert_eq!(
                            snapshot.motion(motion, offset),
                            plain.motion(motion, offset),
                            "{:?} from {}",
                            motion,
                            offset
                        );
                    }
                }
                for &motion in &motions {
                    prop_assert_eq!(
                        snapshot.motion(motion, placed.range.end),
                        plain.motion(motion, placed.range.end)
                    );
                }
            }
            Ok(())
        },
    );
}

/// One step of a case: a change set to one source, or a catch-up.
#[derive(Debug, Clone)]
enum Op {
    /// Applies the walk, fitted, to the source.
    Edit(usize, Walk),
    /// Forgets the source's whole log, so its next catch-up cannot read a
    /// patch and replaces its excerpts whole.
    Forget(usize),
    /// Catches the excerpt text up.
    Refresh,
}

/// Up to `count` steps, a third of them catch-ups.
fn ops(count: usize) -> impl Strategy<Value = Vec<Op>> {
    let op = prop_oneof![
        6 => (0..2_usize, fitted_walk()).prop_map(|(source, walk)| Op::Edit(source, walk)),
        1 => (0..2_usize).prop_map(Op::Forget),
        3 => Just(Op::Refresh),
    ];
    vec(op, 0..=count)
}

/// The change set that makes `new` of `old` by the edits of a patch: each
/// old range replaced by its new range's bytes.
fn changes_of(old: &str, new: &str, edits: &[editor_text::Edit]) -> ChangeSet {
    let mut changes = ChangeSet::new();
    let mut at = 0;
    for edit in edits {
        changes.retain(edit.old.start - at);
        changes.delete(edit.old.end - edit.old.start);
        changes.insert(&new[edit.new.start..edit.new.end]);
        at = edit.old.end;
    }
    changes.retain(old.len() - at);
    changes
}

/// The offsets of the separators of `ranges`, the excerpts' ranges in
/// order: the byte after each but the last.
fn separators(ranges: &[Range<usize>]) -> Vec<usize> {
    ranges
        .iter()
        .take(ranges.len().saturating_sub(1))
        .map(|range| range.end)
        .collect()
}

#[test]
fn edits_to_sources_reach_the_excerpt_text() {
    let sources = (
        (initial_text_to_walk(), steps(2)),
        (initial_text_to_walk(), steps(2)),
    );
    check(
        128,
        (sources, picks(4), ops(16), any::<(usize, usize)>()),
        |(((one, one_steps), (two, two_steps)), picks, ops, (anchor, head))| {
            let (one, one_string) = edited(one, &one_steps);
            let (two, two_string) = edited(two, &two_steps);
            let mut strings = [one_string, two_string];
            let mut texts = [Text::from_snapshot(&one), Text::from_snapshot(&two)];
            let list = list(&picks, &strings);
            let (mut excerpts, mut assembled) = excerpt_text(&mut texts, &list)?;
            // Each excerpt's ends, as anchors mapped by hand.
            let mut ends: Vec<(usize, Anchor, Anchor)> = list
                .iter()
                .map(|excerpt| {
                    let index = usize::from(excerpt.source == KEYS[1]);
                    (
                        index,
                        Anchor::new(excerpt.range.start, Bias::Before),
                        Anchor::new(excerpt.range.end, Bias::After),
                    )
                })
                .collect();
            // A selection the assembled text holds, and the same mapped by
            // hand through each patch.
            let contents = assembled.current().to_string();
            let (anchor, head) = (
                floor(&contents, anchor % (contents.len() + 1)),
                floor(&contents, head % (contents.len() + 1)),
            );
            let mut selection = Selection::new(vec![SelectionRange::new(anchor, head)], 0)
                .ok_or_else(|| TestCaseError::fail("a range is a selection"))?;
            let marker = assembled
                .mark(Marker::Selection(selection.clone()))
                .map_err(|_| TestCaseError::fail("the selection is in the text"))?;

            for op in ops {
                match op {
                    Op::Edit(index, walk) => {
                        let changes = walk.changes(&strings[index]);
                        let made = applied(&changes, &strings[index])
                            .ok_or_else(|| TestCaseError::fail("a fitted walk fits"))?;
                        texts[index]
                            .apply(&Transaction::new(changes.clone()), Origin::default())
                            .map_err(|_| TestCaseError::fail("a fitted walk is accepted"))?;
                        strings[index] = made;
                        for (source, start, end) in &mut ends {
                            if *source == index {
                                *start = start.map(&changes).unwrap_or(*start);
                                *end = end.map(&changes).unwrap_or(*end);
                            }
                        }
                    }
                    Op::Forget(index) => {
                        let revision = texts[index].current().revision();
                        texts[index]
                            .forget(revision)
                            .map_err(|_| TestCaseError::fail("reached"))?;
                    }
                    Op::Refresh => {
                        let before = assembled.current().revision();
                        let old = assembled.current().to_string();
                        let old_ranges: Vec<_> = excerpts
                            .placed()
                            .map(|placed| placed.range.clone())
                            .collect();
                        let [first, second] = &mut texts;
                        excerpts
                            .refresh(&mut assembled, &mut [(KEYS[0], first), (KEYS[1], second)])
                            .map_err(|refusal| TestCaseError::fail(format!("{refusal}")))?;

                        let reference: Vec<_> = ends
                            .iter()
                            .map(|(source, start, end)| {
                                &strings[*source][start.offset..end.offset.max(start.offset)]
                            })
                            .collect();
                        let new = assembled.current().to_string();
                        prop_assert_eq!(&new, &reference.join("\n"));
                        let patch = assembled
                            .changes_since(before)
                            .map_err(|_| TestCaseError::fail("the log holds it"))?;
                        prop_assert_eq!(patched(&old, &new, &patch.edits), new.clone());
                        let new_ranges: Vec<_> = excerpts
                            .placed()
                            .map(|placed| placed.range.clone())
                            .collect();
                        for edit in &patch.edits {
                            for at in separators(&old_ranges) {
                                prop_assert!(
                                    !(edit.old.start <= at && at < edit.old.end),
                                    "{:?} touches the separator at {} of {:?}",
                                    edit,
                                    at,
                                    old
                                );
                            }
                            for at in separators(&new_ranges) {
                                prop_assert!(!(edit.new.start <= at && at < edit.new.end));
                            }
                        }
                        let changes = changes_of(&old, &new, &patch.edits);
                        if let Some(mapped) = selection.map(&changes) {
                            selection = mapped;
                        }
                        prop_assert_eq!(
                            assembled.marker(marker),
                            Some(&Marker::Selection(selection.clone()))
                        );
                    }
                }
            }
            Ok(())
        },
    );
}
