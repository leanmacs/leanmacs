//! A snapshot: the text at one moment, and every read of it.

use std::fmt;

use crate::rope::Rope;

/// The text as it was at one moment.
#[derive(Clone, Default)]
pub struct Snapshot {
    /// The text.
    pub(crate) rope: Rope,
}

impl Snapshot {
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
