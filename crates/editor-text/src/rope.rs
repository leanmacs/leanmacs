//! The rope: the one module that names the rope library.
//!
//! [`Rope`] wraps `ropey`'s rope in the few operations this crate uses, in
//! this crate's terms. Nothing outside this module names a `ropey` type, and
//! no public signature of the crate holds one, so the library can be
//! replaced by changing this file alone. `deny.toml` keeps every other crate
//! from depending on it.
//!
//! There is no trait here. A port stands between the core and something
//! outside the process, and a rope touches nothing outside it, so there is
//! no fake to publish: the reference the crate's property tests compare a
//! text against is a `String`. A second implementation would go behind this
//! same type.
//!
//! Every method that takes an offset or a row says what it requires of it.
//! The library panics on an offset past the end where it has no fallible
//! form, so the checks are made here, before it is called, and the methods
//! return an `Option` or a `bool`. [`Snapshot`](crate::Snapshot) and
//! [`Text`](crate::Text) are what a caller's values reach first.
//!
//! The library's own comparison of ropes is not used: a fix to its ordering
//! is unreleased at the pinned version.

/// The text of one snapshot. A clone shares the tree's nodes with the rope
/// it was made from, so it costs no copy of the text, and an edit to either
/// copies only the nodes it changes.
#[derive(Clone, Default)]
pub(crate) struct Rope(ropey::Rope);

impl Rope {
    /// A rope holding `text`.
    pub(crate) fn from_str(text: &str) -> Self {
        Self(ropey::Rope::from_str(text))
    }

    /// The length of the text in bytes.
    pub(crate) fn len(&self) -> usize {
        self.0.len()
    }

    /// Whether `offset` is a character boundary within the text, its end
    /// included. False past the end.
    pub(crate) fn is_char_boundary(&self, offset: usize) -> bool {
        // The library panics past the end.
        offset <= self.len() && self.0.is_char_boundary(offset)
    }

    /// The pieces the text is held in, in order. Joined, they are the text.
    /// None is empty.
    pub(crate) fn chunks(&self) -> impl Iterator<Item = &str> {
        self.0.chunks()
    }
}
