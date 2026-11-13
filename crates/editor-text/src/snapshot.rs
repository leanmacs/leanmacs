//! A snapshot: the text at one moment, and every read of it.

use std::fmt;

use crate::rope::Rope;

/// Which state of a text a snapshot holds: how many edits the text had
/// accepted. A new text is at 0. Two snapshots of one text at the same
/// revision hold the same text; revisions of different texts do not compare.
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

/// The text as it was at one revision, and every read of it.
///
/// A snapshot never changes: an edit to the [`Text`](crate::Text) it was
/// taken from leaves it as it was, and it outlives that text. A clone shares
/// the text and copies none of it. It is `Send + Sync`, so it is what
/// crosses to another thread.
///
/// The default snapshot is of an empty text at revision 0.
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Text;

    #[test]
    fn a_snapshot_holds_the_text_and_the_revision_of_the_moment_it_was_taken() {
        let mut text = Text::from("héllo");
        let first = text.snapshot();
        text.replace(6..6, " wörld").expect("an insert at the end");
        let second = text.snapshot();
        text.replace(0..6, "").expect("a delete between boundaries");
        text.replace(0..0, "😀").expect("an insert at the start");

        assert_eq!(first.to_string(), "héllo");
        assert_eq!(first.revision().get(), 0);
        assert_eq!(second.to_string(), "héllo wörld");
        assert_eq!(second.revision().get(), 1);
        assert_eq!(text.snapshot().to_string(), "😀 wörld");
        assert_eq!(text.snapshot().revision().get(), 3);
    }

    #[test]
    fn a_snapshot_outlives_its_text() {
        let mut text = Text::from("héllo");
        text.replace(0..1, "H")
            .expect("a replacement of one character");
        let snapshot = text.snapshot();

        drop(text);

        assert_eq!(snapshot.to_string(), "Héllo");
        assert_eq!(snapshot.revision().get(), 1);
    }

    #[test]
    fn a_clone_of_a_snapshot_holds_the_same_text_at_the_same_revision() {
        let mut text = Text::from("héllo");
        text.replace(0..0, "x").expect("an insert at the start");
        let snapshot = text.snapshot();

        let clone = snapshot.clone();
        text.replace(0..1, "").expect("a delete of one character");

        assert_eq!(clone.to_string(), snapshot.to_string());
        assert_eq!(clone.to_string(), "xhéllo");
        assert_eq!(clone.revision(), snapshot.revision());
    }

    #[test]
    fn two_snapshots_with_no_edit_between_them_hold_the_same_text_at_the_same_revision() {
        let text = Text::from("héllo");

        assert_eq!(text.snapshot().to_string(), text.snapshot().to_string());
        assert_eq!(text.snapshot().revision(), text.snapshot().revision());
        assert_eq!(text.snapshot().revision(), text.current().revision());
    }

    /// A snapshot crosses to worker threads and is shared between them, and
    /// a text can be handed to another thread or put behind a lock. This
    /// fails to compile if either stops being so.
    #[test]
    fn a_snapshot_is_shared_between_threads_and_a_text_is_sent_to_one() {
        fn shared<T: Send + Sync + Clone>() {}
        fn sent<T: Send>() {}

        shared::<Snapshot>();
        sent::<Text>();
    }
}
