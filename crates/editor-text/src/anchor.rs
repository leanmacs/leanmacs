//! An anchor: a position that moves with the text.

use crate::change::{Bias, ChangeSet};

/// A position in a text and the side of text inserted at it that it stays
/// on. It is a value: mapping it through each change set the text is
/// edited by ([`Anchor::map`]) keeps it where it was in the text, as an
/// Emacs marker is moved by each edit.
///
/// Two anchors of one bias never pass each other, and one with
/// [`Bias::Before`] never passes one with [`Bias::After`] that was at the
/// same or a later offset. An anchor with [`Bias::After`] and a later one
/// with [`Bias::Before`] can swap, where one replacement covers both or
/// text is inserted where both are: that is what the biases ask for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Anchor {
    /// Where the anchor is: a byte offset.
    pub offset: usize,
    /// Which side of text inserted at the anchor it stays on.
    pub bias: Bias,
}

impl Anchor {
    /// The anchor at `offset` with the bias `bias`.
    pub const fn new(offset: usize, bias: Bias) -> Self {
        Self { offset, bias }
    }

    /// Where this anchor is in the text `changes` makes: its offset mapped
    /// with its bias ([`ChangeSet::map`]). `None` when the offset is past
    /// the length the change set is for.
    pub fn map(&self, changes: &ChangeSet) -> Option<Self> {
        let offset = changes.map(self.offset, self.bias)?;
        Some(Self::new(offset, self.bias))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::change::Change;

    /// A change set over ten bytes with one of each case of the mapping:
    /// text inserted at 2, the bytes 4 and 5 replaced by three, and the
    /// bytes 7 and 8 deleted. It makes eleven bytes.
    fn mapped() -> ChangeSet {
        [
            Change::Retain(2),
            Change::Insert("XY".to_owned()),
            Change::Retain(2),
            Change::Insert("PQR".to_owned()),
            Change::Delete(2),
            Change::Retain(1),
            Change::Delete(2),
            Change::Retain(1),
        ]
        .into_iter()
        .collect()
    }

    /// Where an anchor at `offset` is after `changes`, with each bias:
    /// before, then after.
    fn both(changes: &ChangeSet, offset: usize) -> (Option<Anchor>, Option<Anchor>) {
        (
            Anchor::new(offset, Bias::Before).map(changes),
            Anchor::new(offset, Bias::After).map(changes),
        )
    }

    /// An anchor at `before` with bias before, and one at `after` with
    /// bias after.
    fn at(before: usize, after: usize) -> (Option<Anchor>, Option<Anchor>) {
        (
            Some(Anchor::new(before, Bias::Before)),
            Some(Anchor::new(after, Bias::After)),
        )
    }

    #[test]
    fn an_anchor_has_the_offset_and_the_bias_it_was_given() {
        let anchor = Anchor::new(3, Bias::After);

        assert_eq!(anchor.offset, 3);
        assert_eq!(anchor.bias, Bias::After);
    }

    #[test]
    fn an_anchor_moves_as_its_bias_says_and_keeps_the_bias() {
        let changes = mapped();

        // In retained text.
        assert_eq!(both(&changes, 1), at(1, 1));
        assert_eq!(both(&changes, 3), at(5, 5));
        // Where text is inserted.
        assert_eq!(both(&changes, 2), at(2, 4));
        // At the start of and inside a replaced range, and at its end.
        assert_eq!(both(&changes, 4), at(6, 9));
        assert_eq!(both(&changes, 5), at(6, 9));
        assert_eq!(both(&changes, 6), at(9, 9));
        // At the start of and inside a deleted range, and at its end.
        assert_eq!(both(&changes, 7), at(10, 10));
        assert_eq!(both(&changes, 8), at(10, 10));
        assert_eq!(both(&changes, 9), at(10, 10));
        assert_eq!(both(&changes, 10), at(11, 11));
    }

    #[test]
    fn an_anchor_past_the_length_the_change_set_is_for_maps_to_nothing() {
        assert_eq!(both(&mapped(), 11), (None, None));
        assert_eq!(both(&mapped(), usize::MAX), (None, None));
    }

    #[test]
    fn an_anchor_that_goes_after_and_a_later_one_that_stays_before_swap_inside_one_replacement() {
        // On "abcd", "abc" is replaced by "XY".
        let changes = ChangeSet::replacing(4, 0..3, "XY").expect("a range within the length");
        let earlier = Anchor::new(1, Bias::After);
        let later = Anchor::new(2, Bias::Before);

        assert_eq!(earlier.map(&changes), Some(Anchor::new(2, Bias::After)));
        assert_eq!(later.map(&changes), Some(Anchor::new(0, Bias::Before)));
    }

    #[test]
    fn two_anchors_at_one_offset_part_by_their_biases_where_text_is_inserted() {
        // On "abcd", "XY" is inserted at 2.
        let changes = ChangeSet::replacing(4, 2..2, "XY").expect("a range within the length");

        assert_eq!(both(&changes, 2), at(2, 4));
    }
}
