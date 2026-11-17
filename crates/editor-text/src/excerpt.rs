//! Excerpt texts: a text made of ranges of other texts.
//!
//! An excerpt text is a list of excerpts ([`Excerpts`]) and one plain
//! [`Text`] that only the list writes, the *assembled* text. Each excerpt is
//! a range of a source text, held by two anchors the source itself marks
//! ([`Text::mark`]): its start with [`Bias::Before`] and its end with
//! [`Bias::After`], so text inserted at either end is inside the excerpt.
//! The source moves them at every transaction it accepts, as it moves any
//! marker.
//!
//! The assembled text holds the excerpts' bytes joined by one line feed,
//! the separator: none before the first excerpt and none after the last,
//! and the empty text for an empty list. So the end of one excerpt and the
//! start of the next are two positions. When an excerpt ends in a line
//! feed, the separator is an empty row of its own.
//!
//! **It is caught up at every request.** [`Excerpts::refresh`] reads, for
//! each excerpt whose source's revision moved since the revision it last
//! read, the source's patch since then ([`Text::changes_since`]), cuts each
//! edit to the excerpt (the old range to the excerpt as it was, the new one
//! to where its anchors are now), and applies them all to the assembled text
//! as one transaction. So the assembled text gets one revision, one log
//! entry and its markers move, however many sources moved and however many
//! edits each made. Where the cut edits do not line up with the anchors, or
//! the source's log no longer reaches the revision read, the excerpt is
//! replaced whole. Its snapshot, revision, log and markers are therefore a
//! plain text's, and every reader of a snapshot reads it unchanged.
//!
//! **The assembled text keeps no inverse**: each transaction's is dropped
//! as soon as it is applied, since the list, not an undo, says what the
//! assembled text holds. Anything else that writes it is caught: every
//! method first checks that the assembled text is at the revision the list
//! last wrote ([`ExcerptError::Moved`]).
//!
//! There is no port here. The sources are texts in the same process, and
//! the caller passes them in, with the key it names each by, for each call
//! that reads or marks them. A source the caller leaves out is not read:
//! its excerpts are kept as they were.
//!
//! The list is plain: [`Excerpts::locate`] finds the excerpt of an offset
//! by a binary search over the placed excerpts. A tree with running totals
//! waits for a measured need.

use std::error::Error;
use std::fmt;
use std::ops::Range;

use crate::anchor::Anchor;
use crate::change::{Bias, ChangeSet};
use crate::log::Origin;
use crate::marker::{Marker, MarkerId};
use crate::snapshot::{Revision, Snapshot};
use crate::text::Text;
use crate::transaction::Transaction;

/// The caller's name for a source text: whatever it tells its texts apart
/// by. Keys are compared, never read.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SourceKey(pub u64);

/// One excerpt as it is asked for: a range of a source as the source is
/// now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Wanted {
    /// The source.
    pub source: SourceKey,
    /// The range, two positions of the source in order.
    pub range: Range<usize>,
}

/// One excerpt where it is: which source it is of, the source as it was
/// when the excerpt last read it, the range there, and the range of the
/// assembled text that holds its bytes.
#[derive(Clone)]
pub struct Placed {
    /// The source.
    pub source: SourceKey,
    /// The source at the revision the excerpt last read.
    pub snapshot: Snapshot,
    /// The range of the source the excerpt holds, in `snapshot`.
    pub source_range: Range<usize>,
    /// The range of the assembled text that holds its bytes.
    pub range: Range<usize>,
}

/// Why an excerpt text refused a call. A refusal changes nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExcerptError {
    /// A source of the list, as it is or as it is wanted, is not among the
    /// sources given.
    NoSuchSource,
    /// A source is itself an excerpt text. This crate cannot tell; it is
    /// for a caller that can.
    Excerpted,
    /// A range is not two positions of its source in order.
    BadRange,
    /// The assembled text was written by something other than the list.
    Moved,
}

/// The snapshot is shown by its revision: what it holds is the source's.
impl fmt::Debug for Placed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Placed")
            .field("source", &self.source)
            .field("revision", &self.snapshot.revision())
            .field("source_range", &self.source_range)
            .field("range", &self.range)
            .finish()
    }
}

impl fmt::Display for ExcerptError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::NoSuchSource => "a source is not among the sources given",
            Self::Excerpted => "a source is an excerpt text",
            Self::BadRange => "a range is not two positions of its source in order",
            Self::Moved => "the assembled text was written by something other than its list",
        })
    }
}

impl Error for ExcerptError {}

/// One excerpt: where it is, and the ids of its two anchors in its source.
#[derive(Debug, Clone)]
struct Excerpt {
    /// Where it is.
    placed: Placed,
    /// The anchor at its start, with [`Bias::Before`].
    start: MarkerId,
    /// The anchor at its end, with [`Bias::After`].
    end: MarkerId,
}

/// The list of an excerpt text: its excerpts, in order, over an assembled
/// text the caller keeps. The module docs give the rules.
#[derive(Debug, Clone, Default)]
pub struct Excerpts {
    /// The excerpts, in the order they are joined.
    excerpts: Vec<Excerpt>,
    /// The assembled text's revision after the list last wrote it.
    written: Revision,
}

/// The text of `key` among `sources`.
fn find<'s>(sources: &'s [(SourceKey, &mut Text)], key: SourceKey) -> Option<&'s Text> {
    sources
        .iter()
        .find(|(each, _)| *each == key)
        .map(|(_, text)| &**text)
}

/// The text of `key` among `sources`, to mark.
fn find_mut<'s>(sources: &'s mut [(SourceKey, &mut Text)], key: SourceKey) -> Option<&'s mut Text> {
    sources
        .iter_mut()
        .find(|(each, _)| *each == key)
        .map(|(_, text)| &mut **text)
}

/// The offset of the anchor `id` of `text`, if it holds one.
fn anchor_offset(text: &Text, id: MarkerId) -> Option<usize> {
    match text.marker(id)? {
        Marker::Anchor(anchor) => Some(anchor.offset),
        Marker::Selection(_) => None,
    }
}

/// Where the closed range `bound` and the range `range` meet: `None` when
/// they do not, and an empty range when they only touch.
fn meet(range: Range<usize>, bound: &Range<usize>) -> Option<Range<usize>> {
    let start = range.start.max(bound.start);
    let end = range.end.min(bound.end);
    (start <= end).then_some(start..end)
}

impl Excerpts {
    /// An empty list, over a new text ([`Text::new`]) at revision 0.
    pub fn new() -> Self {
        Self::default()
    }

    /// The excerpts, in order, where they were when the list last caught
    /// up.
    pub fn placed(&self) -> impl ExactSizeIterator<Item = &Placed> {
        self.excerpts.iter().map(|excerpt| &excerpt.placed)
    }

    /// Which excerpt holds the position `offset` of the assembled text, its
    /// source, and the offset in the source as the excerpt last read it. An
    /// excerpt holds both its ends, and with one byte between two excerpts
    /// every position of a list that is not empty is in exactly one. `None`
    /// past the end, and for an empty list.
    pub fn locate(&self, offset: usize) -> Option<(usize, SourceKey, usize)> {
        let after = self
            .excerpts
            .partition_point(|excerpt| excerpt.placed.range.start <= offset);
        let index = after.checked_sub(1)?;
        let placed = &self.excerpts[index].placed;
        (offset <= placed.range.end).then(|| {
            (
                index,
                placed.source,
                placed.source_range.start + (offset - placed.range.start),
            )
        })
    }

    /// Refused with [`ExcerptError::Moved`] unless the list was the last to
    /// write `assembled`.
    fn check(&self, assembled: &Text) -> Result<(), ExcerptError> {
        if assembled.current().revision() == self.written {
            Ok(())
        } else {
            Err(ExcerptError::Moved)
        }
    }

    /// Catches the assembled text up with its sources: what every source
    /// among `sources` whose revision moved since an excerpt of it last
    /// read it changed in that excerpt is applied to `assembled` as one
    /// transaction, whose revision is returned. `None`, with nothing
    /// applied, when no source moved. The module docs give the rule.
    pub fn refresh(
        &mut self,
        assembled: &mut Text,
        sources: &mut [(SourceKey, &mut Text)],
    ) -> Result<Option<Revision>, ExcerptError> {
        self.check(assembled)?;
        let moved = self
            .excerpts
            .iter()
            .any(|excerpt| ends(excerpt, find(sources, excerpt.placed.source)).is_some());
        if !moved {
            return Ok(None);
        }
        let mut changes = ChangeSet::new();
        let mut next = Vec::with_capacity(self.excerpts.len());
        for (index, excerpt) in self.excerpts.iter().enumerate() {
            if index > 0 {
                changes.retain(1);
            }
            next.push(caught_up(
                excerpt,
                find(sources, excerpt.placed.source),
                &mut changes,
            ));
        }
        let revision = self.write(assembled, changes)?;
        self.excerpts = next;
        self.place();
        Ok(Some(revision))
    }

    /// Replaces the list with `wanted`, and returns the assembled text's
    /// revision after it.
    ///
    /// Refused, changing nothing, in this order: with
    /// [`ExcerptError::NoSuchSource`] when the source of an excerpt of the
    /// list, as it is or as it is wanted, is not among `sources`; with
    /// [`ExcerptError::BadRange`] when a range wanted is not two positions
    /// of its source in order.
    ///
    /// It catches up first ([`refresh`](Self::refresh)), which may be a
    /// revision of its own. Then the excerpts the two lists start and end
    /// with alike (one source and one range) are kept with their anchors;
    /// the anchors of the others are given up, and anchors are marked for
    /// the new ones, start then end, in list order. One transaction
    /// replaces the bytes from the end of the last excerpt kept at the
    /// start to the start of the first kept at the end, so the assembled
    /// text holds the new excerpts joined by a line feed. An identical list
    /// is one transaction that changes nothing.
    pub fn set(
        &mut self,
        assembled: &mut Text,
        wanted: &[Wanted],
        sources: &mut [(SourceKey, &mut Text)],
    ) -> Result<Revision, ExcerptError> {
        self.check(assembled)?;
        let known = |key| find(sources, key).is_some();
        if !self
            .excerpts
            .iter()
            .all(|excerpt| known(excerpt.placed.source))
            || !wanted.iter().all(|excerpt| known(excerpt.source))
        {
            return Err(ExcerptError::NoSuchSource);
        }
        let fits = |excerpt: &Wanted| {
            find(sources, excerpt.source).is_some_and(|text| {
                let current = text.current();
                excerpt.range.start <= excerpt.range.end
                    && current.is_char_boundary(excerpt.range.start)
                    && current.is_char_boundary(excerpt.range.end)
            })
        };
        if !wanted.iter().all(fits) {
            return Err(ExcerptError::BadRange);
        }
        self.refresh(assembled, sources)?;

        let alike = |excerpt: &Excerpt, wanted: &Wanted| {
            excerpt.placed.source == wanted.source && excerpt.placed.source_range == wanted.range
        };
        let prefix = self
            .excerpts
            .iter()
            .zip(wanted)
            .take_while(|(excerpt, wanted)| alike(excerpt, wanted))
            .count();
        let most = self.excerpts.len().min(wanted.len()) - prefix;
        let suffix = self
            .excerpts
            .iter()
            .rev()
            .zip(wanted.iter().rev())
            .take(most)
            .take_while(|(excerpt, wanted)| alike(excerpt, wanted))
            .count();

        // The excerpts between the two kept runs, in each list, and the
        // bytes kept at each end of the assembled text: through the last
        // excerpt kept at the start, and from the first kept at the end.
        let middle = prefix..self.excerpts.len() - suffix;
        let fresh = &wanted[prefix..wanted.len() - suffix];
        let len = assembled.current().len();
        let kept_start = match prefix {
            0 => 0,
            _ => self.excerpts[prefix - 1].placed.range.end,
        };
        let kept_end = match suffix {
            0 => len,
            _ => self.excerpts[middle.end].placed.range.start,
        };

        // The excerpts dropped give up their anchors.
        for excerpt in &self.excerpts[middle.clone()] {
            if let Some(text) = find_mut(sources, excerpt.placed.source) {
                text.unmark(excerpt.start);
                text.unmark(excerpt.end);
            }
        }
        // The new ones are marked, start then end, in list order, and what
        // replaces the bytes between the kept runs is read from their
        // sources, with the separators that join it to them.
        let mut inserted = String::new();
        if prefix > 0 && (!fresh.is_empty() || suffix > 0) {
            inserted.push('\n');
        }
        let mut made = Vec::with_capacity(fresh.len());
        for (index, excerpt) in fresh.iter().enumerate() {
            let Some(text) = find_mut(sources, excerpt.source) else {
                return Err(ExcerptError::NoSuchSource);
            };
            let range = excerpt.range.clone();
            let (Ok(start), Ok(end)) = (
                text.mark(Marker::Anchor(Anchor::new(range.start, Bias::Before))),
                text.mark(Marker::Anchor(Anchor::new(range.end, Bias::After))),
            ) else {
                return Err(ExcerptError::BadRange);
            };
            if index > 0 {
                inserted.push('\n');
            }
            let snapshot = text.snapshot();
            inserted.push_str(&snapshot.slice_to_string(range.clone()).unwrap_or_default());
            made.push(Excerpt {
                placed: Placed {
                    source: excerpt.source,
                    snapshot,
                    source_range: range,
                    range: 0..0,
                },
                start,
                end,
            });
        }
        if suffix > 0 && !fresh.is_empty() {
            inserted.push('\n');
        }

        let mut changes = ChangeSet::new();
        changes.retain(kept_start);
        changes.delete(kept_end - kept_start);
        changes.insert(&inserted);
        changes.retain(len - kept_end);
        let revision = self.write(assembled, changes)?;
        let tail = self.excerpts.split_off(middle.end);
        self.excerpts.truncate(prefix);
        self.excerpts.extend(made);
        self.excerpts.extend(tail);
        self.place();
        Ok(revision)
    }

    /// Gives up every anchor the list holds in `sources` and empties the
    /// list. The assembled text is left as it is.
    pub fn release(&mut self, sources: &mut [(SourceKey, &mut Text)]) {
        for excerpt in self.excerpts.drain(..) {
            if let Some(text) = find_mut(sources, excerpt.placed.source) {
                text.unmark(excerpt.start);
                text.unmark(excerpt.end);
            }
        }
    }

    /// Applies `changes` to `assembled` as one transaction, drops its
    /// inverse, and notes the revision as the list's.
    fn write(
        &mut self,
        assembled: &mut Text,
        changes: ChangeSet,
    ) -> Result<Revision, ExcerptError> {
        let revision = assembled
            .apply(&Transaction::new(changes), Origin::default())
            .map_err(|_| ExcerptError::Moved)?;
        // The revision was just made, so it is known.
        let _ = assembled.drop_inverses(revision, revision);
        self.written = revision;
        Ok(revision)
    }

    /// Puts each excerpt's range in the assembled text where the lengths
    /// before it say: one line feed between two.
    fn place(&mut self) {
        let mut at = 0;
        for excerpt in &mut self.excerpts {
            let len = excerpt.placed.source_range.len();
            excerpt.placed.range = at..at + len;
            at += len + 1;
        }
    }
}

/// Where the anchors of `excerpt` are in `source`, its source as it is now,
/// when the source was given and moved since the excerpt last read it.
/// `None` too when the source no longer holds both anchors (whoever holds
/// their ids may give them up): such an excerpt is kept as it was.
fn ends(excerpt: &Excerpt, source: Option<&Text>) -> Option<Range<usize>> {
    let source = source?;
    if source.current().revision() == excerpt.placed.snapshot.revision() {
        return None;
    }
    let start = anchor_offset(source, excerpt.start)?;
    let end = anchor_offset(source, excerpt.end)?;
    Some(start..end.max(start))
}

/// `excerpt` caught up with `source`, its source as it is now, if it was
/// given, and the changes that make the assembled text's bytes of it so,
/// pushed onto `changes`. The range in the assembled text is left for the
/// caller to place.
fn caught_up(excerpt: &Excerpt, source: Option<&Text>, changes: &mut ChangeSet) -> Excerpt {
    let placed = &excerpt.placed;
    let old = placed.source_range.clone();
    let unmoved = |changes: &mut ChangeSet| {
        changes.retain(old.len());
        excerpt.clone()
    };
    let (Some(source), Some(new)) = (source, ends(excerpt, source)) else {
        return unmoved(changes);
    };
    let current = source.current();
    let slice = |range: Range<usize>| current.slice_to_string(range).unwrap_or_default();
    match clipped(source, placed.snapshot.revision(), &old, &new) {
        Some(edits) => {
            let mut at = old.start;
            for (old_part, new_part) in edits {
                changes.retain(old_part.start - at);
                changes.delete(old_part.len());
                changes.insert(&slice(new_part));
                at = old_part.end;
            }
            changes.retain(old.end - at);
        }
        None => {
            changes.delete(old.len());
            changes.insert(&slice(new.clone()));
        }
    }
    Excerpt {
        placed: Placed {
            source: placed.source,
            snapshot: source.snapshot(),
            source_range: new,
            range: 0..0,
        },
        start: excerpt.start,
        end: excerpt.end,
    }
}

/// The edits of `source` since `seen`, each cut to the excerpt: its old
/// range to `old`, where the excerpt was, and its new range to `new`, where
/// its anchors are now. `None` when the log no longer reaches `seen`, or
/// the cut edits do not line up with the two ranges: in order, and with
/// every stretch they keep as long in both.
fn clipped(
    source: &Text,
    seen: Revision,
    old: &Range<usize>,
    new: &Range<usize>,
) -> Option<Vec<(Range<usize>, Range<usize>)>> {
    let patch = source.changes_since(seen).ok()?;
    let mut edits = Vec::new();
    let (mut old_at, mut new_at) = (old.start, new.start);
    for edit in &patch.edits {
        let old_part = meet(edit.old.start..edit.old.end, old);
        let new_part = meet(edit.new.start..edit.new.end, new);
        let (old_part, new_part) = match (old_part, new_part) {
            (Some(o), Some(n)) if o.is_empty() && n.is_empty() => continue,
            (None, None) => continue,
            (None, Some(n)) | (Some(n), None) if n.is_empty() => continue,
            (Some(o), Some(n)) => (o, n),
            _ => return None,
        };
        if old_part.start < old_at
            || new_part.start < new_at
            || old_part.start - old_at != new_part.start - new_at
        {
            return None;
        }
        old_at = old_part.end;
        new_at = new_part.end;
        edits.push((old_part, new_part));
    }
    (old.end >= old_at && new.end >= new_at && old.end - old_at == new.end - new_at)
        .then_some(edits)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::motion::Motion;
    use crate::point::Point;
    use crate::word::WordKind;

    /// The first source: excerpts take its second row, `4..8`.
    const ONE: SourceKey = SourceKey(1);
    /// The second source: excerpts take its first row, `0..6`.
    const TWO: SourceKey = SourceKey(2);

    /// The two sources.
    fn sources() -> (Text, Text) {
        (Text::from("one\ntwo\nthree\n"), Text::from("alpha\nbeta\n"))
    }

    /// An excerpt of `source` over `range`.
    fn wanted(source: SourceKey, range: Range<usize>) -> Wanted {
        Wanted { source, range }
    }

    /// The fixture's list: the second row of the first source, then the
    /// first row of the second.
    fn rows() -> Vec<Wanted> {
        vec![wanted(ONE, 4..8), wanted(TWO, 0..6)]
    }

    /// An excerpt text of `list` over `one` and `two`.
    fn made(one: &mut Text, two: &mut Text, list: &[Wanted]) -> (Excerpts, Text) {
        let mut excerpts = Excerpts::new();
        let mut assembled = Text::new();
        excerpts
            .set(&mut assembled, list, &mut [(ONE, one), (TWO, two)])
            .expect("the fixture's list is accepted");
        (excerpts, assembled)
    }

    /// Catches `excerpts` up with `one` and `two`.
    fn refresh(
        excerpts: &mut Excerpts,
        assembled: &mut Text,
        one: &mut Text,
        two: &mut Text,
    ) -> Option<Revision> {
        excerpts
            .refresh(assembled, &mut [(ONE, one), (TWO, two)])
            .expect("the list wrote the assembled text last")
    }

    /// The source ranges of the placed excerpts.
    fn source_ranges(excerpts: &Excerpts) -> Vec<Range<usize>> {
        excerpts
            .placed()
            .map(|placed| placed.source_range.clone())
            .collect()
    }

    #[test]
    fn two_ranges_of_two_texts_read_as_one_text_joined_by_a_line_feed() {
        let (mut one, mut two) = sources();

        let (excerpts, assembled) = made(&mut one, &mut two, &rows());

        assert_eq!(assembled.current().to_string(), "two\n\nalpha\n");
        let ranges: Vec<_> = excerpts
            .placed()
            .map(|placed| placed.range.clone())
            .collect();
        assert_eq!(ranges, [0..4, 5..11]);
        assert_eq!(source_ranges(&excerpts), [4..8, 0..6]);
    }

    #[test]
    fn an_empty_list_is_the_empty_text_and_one_excerpt_has_no_separator() {
        let (mut one, mut two) = sources();

        let (_, empty) = made(&mut one, &mut two, &[]);
        let (_, single) = made(&mut one, &mut two, &[wanted(TWO, 0..5)]);

        assert_eq!(empty.current().to_string(), "");
        assert_eq!(single.current().to_string(), "alpha");
    }

    #[test]
    fn an_empty_range_and_a_range_at_its_sources_end_are_kept() {
        let (mut one, mut two) = sources();

        let (excerpts, assembled) = made(
            &mut one,
            &mut two,
            &[wanted(ONE, 3..3), wanted(TWO, 11..11), wanted(ONE, 0..3)],
        );

        assert_eq!(assembled.current().to_string(), "\n\none");
        assert_eq!(excerpts.placed().len(), 3);
    }

    #[test]
    fn a_list_naming_a_source_not_given_is_refused_and_changes_nothing() {
        let (mut one, _) = sources();
        let mut excerpts = Excerpts::new();
        let mut assembled = Text::new();

        let refused = excerpts.set(
            &mut assembled,
            &[wanted(ONE, 0..3), wanted(TWO, 0..5)],
            &mut [(ONE, &mut one)],
        );

        assert_eq!(refused, Err(ExcerptError::NoSuchSource));
        assert_eq!(assembled.current().revision(), Revision::new(0));
        assert_eq!(excerpts.placed().len(), 0);
        // The first marker the source gives out is still its first.
        assert!(one.marker(MarkerId::new(0)).is_none());
        let first = one
            .mark(Marker::Anchor(Anchor::new(0, Bias::Before)))
            .expect("0 is a position");
        assert_eq!(first, MarkerId::new(0));
    }

    #[test]
    fn a_range_that_is_not_two_positions_in_order_is_refused_and_changes_nothing() {
        let (mut one, mut two) = (Text::from("héllo"), Text::from("world"));
        let (mut excerpts, mut assembled) = made(&mut one, &mut two, &[wanted(TWO, 0..5)]);
        let before = assembled.current().revision();

        // Out of order, inside "é", and past the end.
        for (start, end) in [(3, 1), (0, 2), (0, 7)] {
            let range = start..end;
            let refused = excerpts.set(
                &mut assembled,
                &[wanted(TWO, 0..5), wanted(ONE, range.clone())],
                &mut [(ONE, &mut one), (TWO, &mut two)],
            );
            assert_eq!(refused, Err(ExcerptError::BadRange), "{range:?}");
        }

        assert_eq!(assembled.current().revision(), before);
        assert_eq!(assembled.current().to_string(), "world");
        assert!(one.marker(MarkerId::new(0)).is_none());
        // The second source holds its two anchors and no more.
        assert!(two.marker(MarkerId::new(1)).is_some());
        assert!(two.marker(MarkerId::new(2)).is_none());
    }

    #[test]
    fn a_list_dropping_an_excerpt_whose_source_is_not_given_is_refused() {
        let (mut one, mut two) = sources();
        let (mut excerpts, mut assembled) = made(&mut one, &mut two, &rows());
        let before = assembled.current().revision();

        let refused = excerpts.set(&mut assembled, &[wanted(TWO, 0..6)], &mut [(TWO, &mut two)]);

        assert_eq!(refused, Err(ExcerptError::NoSuchSource));
        assert_eq!(assembled.current().revision(), before);
        assert_eq!(excerpts.placed().len(), 2);
        assert!(one.marker(MarkerId::new(0)).is_some());
        assert!(one.marker(MarkerId::new(1)).is_some());
    }

    #[test]
    fn every_position_is_located_in_one_excerpt_with_both_its_ends() {
        let (mut one, mut two) = sources();
        let (excerpts, _) = made(&mut one, &mut two, &rows());

        let located: Vec<_> = (0..=12).map(|offset| excerpts.locate(offset)).collect();

        let mut expected: Vec<_> = (0..=4).map(|at| Some((0, ONE, 4 + at))).collect();
        expected.extend((5..=11).map(|at| Some((1, TWO, at - 5))));
        expected.push(None);
        assert_eq!(located, expected);
        assert_eq!(Excerpts::new().locate(0), None);
    }

    #[test]
    fn a_word_motion_and_a_row_motion_cross_into_the_separator_row() {
        let (mut one, mut two) = sources();
        let (_, assembled) = made(&mut one, &mut two, &rows());
        let snapshot = assembled.snapshot();

        // "two\n" ends in a line feed, so the separator is the empty row 1.
        assert_eq!(
            snapshot.motion(Motion::NextWordStart(WordKind::Word), 1),
            Some(4)
        );
        assert_eq!(
            snapshot.motion(
                Motion::RowsDown {
                    count: 1,
                    column: 2
                },
                2
            ),
            Some(4)
        );
        assert_eq!(
            snapshot.motion(
                Motion::RowsDown {
                    count: 2,
                    column: 2
                },
                2
            ),
            Some(7)
        );
    }

    #[test]
    fn an_insert_before_an_excerpt_moves_its_anchors_and_adds_one_revision_with_no_edit() {
        let (mut one, mut two) = sources();
        let (mut excerpts, mut assembled) = made(&mut one, &mut two, &rows());
        let before = assembled.current().revision();

        one.replace(0..0, "zero\n").expect("0 is a position");
        let revision = refresh(&mut excerpts, &mut assembled, &mut one, &mut two);

        assert_eq!(revision, Some(Revision::new(before.get() + 1)));
        assert_eq!(assembled.current().to_string(), "two\n\nalpha\n");
        let patch = assembled.changes_since(before).expect("the log holds it");
        assert_eq!(patch.edits, []);
        assert_eq!(source_ranges(&excerpts), [9..13, 0..6]);
    }

    #[test]
    fn an_insert_inside_an_excerpt_is_one_edit_of_the_excerpt_text() {
        let (mut one, mut two) = sources();
        let (mut excerpts, mut assembled) = made(&mut one, &mut two, &rows());
        let before = assembled.current().revision();

        one.replace(5..5, "X").expect("5 is a position");
        refresh(&mut excerpts, &mut assembled, &mut one, &mut two);

        assert_eq!(assembled.current().to_string(), "tXwo\n\nalpha\n");
        let patch = assembled.changes_since(before).expect("the log holds it");
        assert_eq!(patch.edits.len(), 1);
        let edit = patch.edits[0];
        assert_eq!((edit.old.start, edit.old.end), (1, 1));
        assert_eq!(
            (edit.old.start_point, edit.old.end_point),
            (Point::new(0, 1), Point::new(0, 1))
        );
        assert_eq!((edit.new.start, edit.new.end), (1, 2));
        assert_eq!(
            (edit.new.start_point, edit.new.end_point),
            (Point::new(0, 1), Point::new(0, 2))
        );
    }

    #[test]
    fn text_inserted_at_either_end_of_an_excerpt_is_inside_it() {
        let (mut one, mut two) = sources();
        let (mut excerpts, mut assembled) = made(&mut one, &mut two, &rows());

        one.replace(4..4, "A").expect("4 is a position");
        one.replace(9..9, "B").expect("9 is a position");
        refresh(&mut excerpts, &mut assembled, &mut one, &mut two);

        assert_eq!(assembled.current().to_string(), "Atwo\nB\nalpha\n");
        assert_eq!(source_ranges(&excerpts), [4..10, 0..6]);
    }

    #[test]
    fn a_delete_across_an_excerpts_start_cuts_it() {
        let (mut one, mut two) = sources();
        let (mut excerpts, mut assembled) = made(&mut one, &mut two, &rows());

        one.replace(2..6, "").expect("2 and 6 are positions");
        refresh(&mut excerpts, &mut assembled, &mut one, &mut two);

        assert_eq!(assembled.current().to_string(), "o\n\nalpha\n");
        assert_eq!(source_ranges(&excerpts), [2..4, 0..6]);
    }

    #[test]
    fn deleting_all_of_an_excerpt_leaves_it_empty_with_its_separator() {
        let (mut one, mut two) = sources();
        let (mut excerpts, mut assembled) = made(&mut one, &mut two, &rows());

        one.replace(3..9, "").expect("3 and 9 are positions");
        refresh(&mut excerpts, &mut assembled, &mut one, &mut two);

        assert_eq!(assembled.current().to_string(), "\nalpha\n");
        assert_eq!(source_ranges(&excerpts), [3..3, 0..6]);
    }

    #[test]
    fn two_source_edits_between_two_catch_ups_are_one_revision() {
        let (mut one, mut two) = sources();
        let (mut excerpts, mut assembled) = made(&mut one, &mut two, &rows());
        let before = assembled.current().revision();

        one.replace(4..4, "A").expect("4 is a position");
        one.replace(6..6, "B").expect("6 is a position");
        refresh(&mut excerpts, &mut assembled, &mut one, &mut two);

        assert_eq!(assembled.current().revision().get(), before.get() + 1);
        assert_eq!(assembled.current().to_string(), "AtBwo\n\nalpha\n");
    }

    #[test]
    fn edits_to_both_sources_are_one_transaction() {
        let (mut one, mut two) = sources();
        let (mut excerpts, mut assembled) = made(&mut one, &mut two, &rows());
        let before = assembled.current().revision();

        one.replace(7..7, "!").expect("7 is a position");
        two.replace(0..1, "A").expect("0 and 1 are positions");
        refresh(&mut excerpts, &mut assembled, &mut one, &mut two);

        assert_eq!(assembled.current().revision().get(), before.get() + 1);
        assert_eq!(assembled.current().to_string(), "two!\n\nAlpha\n");
        let revision = assembled.current().revision();
        let entry = assembled.entry(revision).expect("the log holds it");
        assert_eq!(entry.edits().len(), 2);
    }

    #[test]
    fn no_source_moved_is_no_revision() {
        let (mut one, mut two) = sources();
        let (mut excerpts, mut assembled) = made(&mut one, &mut two, &rows());
        let before = assembled.current().revision();

        let revision = refresh(&mut excerpts, &mut assembled, &mut one, &mut two);

        assert_eq!(revision, None);
        assert_eq!(assembled.current().revision(), before);
    }

    #[test]
    fn an_edit_to_a_source_outside_every_excerpt_is_still_one_revision() {
        let (mut one, mut two) = sources();
        let (mut excerpts, mut assembled) = made(&mut one, &mut two, &rows());
        let before = assembled.current().revision();

        two.replace(11..11, "gamma").expect("11 is a position");
        refresh(&mut excerpts, &mut assembled, &mut one, &mut two);

        assert_eq!(assembled.current().revision().get(), before.get() + 1);
        assert!(
            assembled
                .changes_since(before)
                .expect("kept")
                .edits
                .is_empty()
        );
    }

    #[test]
    fn a_source_whose_log_no_longer_reaches_the_revision_read_replaces_the_excerpt_whole() {
        let (mut one, mut two) = sources();
        let (mut excerpts, mut assembled) = made(&mut one, &mut two, &rows());
        let before = assembled.current().revision();

        one.replace(5..5, "X").expect("5 is a position");
        one.forget(one.current().revision()).expect("reached");
        refresh(&mut excerpts, &mut assembled, &mut one, &mut two);

        assert_eq!(assembled.current().to_string(), "tXwo\n\nalpha\n");
        let patch = assembled.changes_since(before).expect("the log holds it");
        assert_eq!(patch.edits.len(), 1);
        let edit = patch.edits[0];
        assert_eq!((edit.old.start, edit.old.end), (0, 4));
        assert_eq!((edit.new.start, edit.new.end), (0, 5));
    }

    #[test]
    fn the_assembled_text_keeps_no_inverse() {
        let (mut one, mut two) = sources();
        let (mut excerpts, mut assembled) = made(&mut one, &mut two, &rows());
        one.replace(5..5, "X").expect("5 is a position");
        let revision =
            refresh(&mut excerpts, &mut assembled, &mut one, &mut two).expect("the source moved");

        for revision in [Revision::new(1), revision] {
            let inverted = assembled.apply_inverse(revision, revision, Origin::default());
            assert_eq!(inverted, Err(crate::inverse::InverseError::NotKept));
        }
    }

    #[test]
    fn a_new_list_keeps_the_excerpts_it_starts_and_ends_with_out_of_its_edit() {
        let (mut one, mut two) = sources();
        let list = [wanted(ONE, 0..3), wanted(TWO, 0..5), wanted(ONE, 8..13)];
        let (mut excerpts, mut assembled) = made(&mut one, &mut two, &list);
        assert_eq!(assembled.current().to_string(), "one\nalpha\nthree");
        let before = assembled.current().revision();

        let revision = excerpts
            .set(
                &mut assembled,
                &[wanted(ONE, 0..3), wanted(TWO, 6..10), wanted(ONE, 8..13)],
                &mut [(ONE, &mut one), (TWO, &mut two)],
            )
            .expect("accepted");

        assert_eq!(revision.get(), before.get() + 1);
        assert_eq!(assembled.current().to_string(), "one\nbeta\nthree");
        let patch = assembled.changes_since(before).expect("the log holds it");
        assert_eq!(patch.edits.len(), 1);
        let edit = patch.edits[0];
        assert_eq!((edit.old.start, edit.old.end), (3, 10));
        assert_eq!((edit.new.start, edit.new.end), (3, 9));
        // The kept excerpts kept their anchors, 0 and 1 then 2 and 3 of the
        // first source; the dropped one gave up 0 and 1 of the second, and
        // the new one took 2 and 3.
        for id in [0, 1, 2, 3] {
            assert!(one.marker(MarkerId::new(id)).is_some(), "{id}");
        }
        assert!(two.marker(MarkerId::new(0)).is_none());
        assert!(two.marker(MarkerId::new(1)).is_none());
        assert_eq!(
            two.marker(MarkerId::new(2)),
            Some(&Marker::Anchor(Anchor::new(6, Bias::Before)))
        );
        assert_eq!(
            two.marker(MarkerId::new(3)),
            Some(&Marker::Anchor(Anchor::new(10, Bias::After)))
        );
    }

    #[test]
    fn a_new_list_that_drops_or_adds_excerpts_joins_what_is_left_by_one_line_feed() {
        let (mut one, mut two) = sources();
        let cases: [(&[Wanted], &[Wanted], &str); 6] = [
            (
                &[wanted(ONE, 0..3), wanted(TWO, 0..5)],
                &[wanted(ONE, 0..3)],
                "one",
            ),
            (
                &[wanted(ONE, 0..3), wanted(TWO, 0..5)],
                &[wanted(TWO, 0..5)],
                "alpha",
            ),
            (
                &[wanted(ONE, 0..3), wanted(TWO, 0..5), wanted(ONE, 4..7)],
                &[wanted(ONE, 0..3), wanted(ONE, 4..7)],
                "one\ntwo",
            ),
            (
                &[wanted(ONE, 0..3), wanted(ONE, 4..7)],
                &[wanted(ONE, 0..3), wanted(TWO, 0..5), wanted(ONE, 4..7)],
                "one\nalpha\ntwo",
            ),
            (
                &[wanted(ONE, 0..3)],
                &[wanted(ONE, 0..3), wanted(TWO, 0..5)],
                "one\nalpha",
            ),
            (&[wanted(ONE, 0..3)], &[], ""),
        ];
        for (from, to, expected) in cases {
            let (mut excerpts, mut assembled) = made(&mut one, &mut two, from);

            excerpts
                .set(&mut assembled, to, &mut [(ONE, &mut one), (TWO, &mut two)])
                .expect("accepted");

            assert_eq!(
                assembled.current().to_string(),
                expected,
                "{from:?} to {to:?}"
            );
            let fresh = made(&mut one, &mut two, to).1;
            assert_eq!(assembled.current().to_string(), fresh.current().to_string());
        }
    }

    #[test]
    fn an_identical_list_is_one_revision_that_changes_nothing() {
        let (mut one, mut two) = sources();
        let (mut excerpts, mut assembled) = made(&mut one, &mut two, &rows());
        let before = assembled.current().revision();

        let revision = excerpts
            .set(
                &mut assembled,
                &rows(),
                &mut [(ONE, &mut one), (TWO, &mut two)],
            )
            .expect("accepted");

        assert_eq!(revision.get(), before.get() + 1);
        assert!(
            assembled
                .changes_since(before)
                .expect("kept")
                .edits
                .is_empty()
        );
        assert!(two.marker(MarkerId::new(2)).is_none());
    }

    #[test]
    fn an_assembled_text_written_behind_the_lists_back_is_refused() {
        let (mut one, mut two) = sources();
        let (mut excerpts, mut assembled) = made(&mut one, &mut two, &rows());

        assembled.replace(0..0, "!").expect("0 is a position");
        one.replace(5..5, "X").expect("5 is a position");

        let refreshed = excerpts.refresh(&mut assembled, &mut [(ONE, &mut one), (TWO, &mut two)]);
        let set = excerpts.set(
            &mut assembled,
            &rows(),
            &mut [(ONE, &mut one), (TWO, &mut two)],
        );
        assert_eq!(refreshed, Err(ExcerptError::Moved));
        assert_eq!(set, Err(ExcerptError::Moved));
        assert_eq!(assembled.current().to_string(), "!two\n\nalpha\n");
    }

    #[test]
    fn releasing_gives_up_every_anchor_and_empties_the_list() {
        let (mut one, mut two) = sources();
        let (mut excerpts, _) = made(&mut one, &mut two, &rows());

        excerpts.release(&mut [(ONE, &mut one), (TWO, &mut two)]);

        assert_eq!(excerpts.placed().len(), 0);
        for id in 0..2 {
            assert!(one.marker(MarkerId::new(id)).is_none());
            assert!(two.marker(MarkerId::new(id)).is_none());
        }
    }

    #[test]
    fn an_excerpt_whose_anchors_were_given_up_is_kept_as_it_was() {
        let (mut one, mut two) = sources();
        let (mut excerpts, mut assembled) = made(&mut one, &mut two, &rows());
        let before = assembled.current().revision();

        one.unmark(MarkerId::new(0));
        one.replace(5..5, "X").expect("5 is a position");

        assert_eq!(
            refresh(&mut excerpts, &mut assembled, &mut one, &mut two),
            None
        );
        assert_eq!(assembled.current().revision(), before);
        assert_eq!(assembled.current().to_string(), "two\n\nalpha\n");
    }
}
