//! Markers: the anchors and selections a text holds and moves.
//!
//! The crate docs give the rules. [`Markers`] is the table a
//! [`Text`](crate::Text) keeps them in; the text's methods check a marker
//! against the text before it reaches the table.

use std::collections::BTreeMap;
use std::error::Error;
use std::fmt;

use crate::anchor::Anchor;
use crate::change::ChangeSet;
use crate::selection::Selection;

/// Something a text holds and moves with every transaction it accepts
/// ([`Text::mark`](crate::Text::mark)).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Marker {
    /// One position, moved by its bias ([`Anchor::map`]).
    Anchor(Anchor),
    /// A selection, moved as [`Selection::map`] says.
    Selection(Selection),
}

/// Which marker of a text: a number the text gave out when the marker was
/// made ([`Text::mark`](crate::Text::mark)). A text never gives a number
/// out twice, so the id of a marker that is gone names nothing, for good.
/// The ids of different texts do not compare.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct MarkerId(u64);

impl MarkerId {
    /// The id with the number `id`. This is for a caller that kept an id
    /// as a number, across a boundary that carries numbers; whether the
    /// text has such a marker is the text's to say.
    pub const fn new(id: u64) -> Self {
        Self(id)
    }

    /// The id as a number.
    pub const fn get(self) -> u64 {
        self.0
    }
}

/// Why a marker was refused ([`Text::mark`](crate::Text::mark),
/// [`Text::place`](crate::Text::place)).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarkError {
    /// The text holds no marker with that id.
    NoSuchMarker,
    /// The anchor's offset is not a position of the text.
    BadPosition,
    /// An end of a range of the selection is not a position of the text.
    BadSelection,
}

impl fmt::Display for MarkError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::NoSuchMarker => "the text holds no marker with that id",
            Self::BadPosition => "the anchor is not at a position of the text",
            Self::BadSelection => "a selection's end is not a position of the text",
        })
    }
}

impl Error for MarkError {}

/// The markers of one text, by the number of their ids.
#[derive(Default)]
pub(crate) struct Markers {
    /// The markers the text holds.
    held: BTreeMap<u64, Marker>,
    /// The number the next marker gets: one more than the last given out.
    next: u64,
}

impl Markers {
    /// Holds `marker` and returns its id, which no marker had before.
    pub(crate) fn add(&mut self, marker: Marker) -> MarkerId {
        let id = self.next;
        // It wraps, and does not panic, after 2^64 markers, which no text
        // reaches.
        self.next = id.wrapping_add(1);
        self.held.insert(id, marker);
        MarkerId(id)
    }

    /// The marker with the id `id`, if one is held.
    pub(crate) fn get(&self, id: MarkerId) -> Option<&Marker> {
        self.held.get(&id.0)
    }

    /// The marker with the id `id`, to put another in its place.
    pub(crate) fn get_mut(&mut self, id: MarkerId) -> Option<&mut Marker> {
        self.held.get_mut(&id.0)
    }

    /// Gives up the marker with the id `id`, and returns whether there
    /// was one.
    pub(crate) fn remove(&mut self, id: MarkerId) -> bool {
        self.held.remove(&id.0).is_some()
    }

    /// Where every end the markers hold is in the text `changes` makes,
    /// for [`place_all`](Self::place_all): an anchor's offset, and the
    /// ends of a selection's ranges, in the order the markers are held in.
    /// `None` when an end is past the length the change set is for, which
    /// no marker checked against the text the change set fits is.
    ///
    /// The ends are sorted by offset and mapped in one walk of the change
    /// set ([`Mapper`](crate::Mapper)), so this costs the ends held plus
    /// the changes, and allocates nothing when no marker is held.
    pub(crate) fn mapped(&self, changes: &ChangeSet) -> Option<Vec<usize>> {
        if self.held.is_empty() {
            return Some(Vec::new());
        }
        // Each end with its place in the order the markers are held in.
        let count = self.held.values().map(Marker::ends).sum();
        let mut ends = Vec::with_capacity(count);
        for marker in self.held.values() {
            match marker {
                Marker::Anchor(anchor) => ends.push((anchor.offset, anchor.bias, ends.len())),
                Marker::Selection(selection) => {
                    for (offset, bias) in selection.ends() {
                        ends.push((offset, bias, ends.len()));
                    }
                }
            }
        }
        ends.sort_unstable_by_key(|&(offset, _, _)| offset);
        let mut mapped = vec![0; ends.len()];
        let mut mapper = changes.mapper();
        for (offset, bias, place) in ends {
            *mapped.get_mut(place)? = mapper.map(offset, bias)?;
        }
        Some(mapped)
    }

    /// Moves every marker to where [`mapped`](Self::mapped) found its
    /// ends to be.
    pub(crate) fn place_all(&mut self, mapped: &[usize]) {
        let mut mapped = mapped.iter().copied();
        for marker in self.held.values_mut() {
            match marker {
                Marker::Anchor(anchor) => {
                    if let Some(offset) = mapped.next() {
                        anchor.offset = offset;
                    }
                }
                Marker::Selection(selection) => {
                    // The ends are asked for in the order they were
                    // gathered in.
                    if let Some(moved) = selection.moved(|_, _| mapped.next()) {
                        *selection = moved;
                    }
                }
            }
        }
    }
}

impl Marker {
    /// How many ends the marker has to move: one for an anchor, and two
    /// for each range of a selection.
    fn ends(&self) -> usize {
        match self {
            Self::Anchor(_) => 1,
            Self::Selection(selection) => selection.ranges().len() * 2,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_marker_id_is_the_number_it_was_made_from() {
        assert_eq!(MarkerId::new(7).get(), 7);
        assert_eq!(MarkerId::new(7), MarkerId::new(7));
        assert_ne!(MarkerId::new(7), MarkerId::new(8));
        assert!(MarkerId::new(7) < MarkerId::new(8));
    }

    #[test]
    fn each_refusal_of_a_marker_says_what_was_refused() {
        let no_such_marker = MarkError::NoSuchMarker.to_string();
        let bad_position = MarkError::BadPosition.to_string();
        let bad_selection = MarkError::BadSelection.to_string();

        // Each names what it is about, and not what the others are about.
        assert!(no_such_marker.contains("no marker"), "{no_such_marker:?}");
        assert!(!no_such_marker.contains("position"), "{no_such_marker:?}");
        assert!(bad_position.contains("anchor"), "{bad_position:?}");
        assert!(bad_position.contains("position"), "{bad_position:?}");
        assert!(!bad_position.contains("selection"), "{bad_position:?}");
        assert!(bad_selection.contains("selection"), "{bad_selection:?}");
        assert!(bad_selection.contains("position"), "{bad_selection:?}");
        assert!(!bad_selection.contains("anchor"), "{bad_selection:?}");
    }
}
