//! A snapshot: the text at one moment, and every read of it.

use std::fmt;

use crate::rope::Rope;

/// Which state of a text a snapshot holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub struct Revision(pub(crate) u64);

impl Revision {
    /// The revision as a number: how many edits the text had accepted.
    pub const fn get(self) -> u64 {
        self.0
    }

    /// The revision after one more accepted edit. It wraps, and does not
    /// panic, after 2^64 edits, which no text reaches.
    pub(crate) const fn next(self) -> Self {
        Self(self.0.wrapping_add(1))
    }
}

/// The text as it was at one moment.
#[derive(Clone, Default)]
pub struct Snapshot {
    /// The text.
    pub(crate) rope: Rope,
    /// The revision of the text this is.
    pub(crate) revision: Revision,
}

impl Snapshot {
    /// Which state of its text this is.
    pub fn revision(&self) -> Revision {
        self.revision
    }

    /// The length of the text in bytes.
    pub fn len(&self) -> usize {
        self.rope.len()
    }

    /// Whether the text is empty.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Whether `offset` is a position: a byte offset within the text, its
    /// end included, that is not inside a character.
    pub fn is_char_boundary(&self, offset: usize) -> bool {
        self.rope.is_char_boundary(offset)
    }
}

impl fmt::Display for Snapshot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.rope.chunks().try_for_each(|chunk| f.write_str(chunk))
    }
}
