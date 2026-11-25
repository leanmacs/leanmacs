//! A snapshot: the text at one moment, and every read of it.

use std::fmt;
use std::ops::Range;

use crate::rope::{self, Rope};

/// Which state of a text a snapshot holds: how many edits the text had
/// accepted. A new text is at 0. Two snapshots of one text at the same
/// revision hold the same text; revisions of different texts do not compare.
/// A revision only grows: taking edits back
/// ([`Text::apply_inverse`](crate::Text::apply_inverse)) is an edit, so two
/// revisions of one text may hold the same text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub struct Revision(pub(crate) u64);

impl Revision {
    /// The revision a text is at once it has accepted `edits` edits. This
    /// is for a consumer that kept a revision as a number, across a
    /// boundary that carries numbers, and asks the log about it; whether
    /// the text has reached it is the text's to say.
    pub const fn new(edits: u64) -> Self {
        Self(edits)
    }

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

    /// The pieces the text is held in, in order. Joined, they are the text,
    /// and none is empty. This is the read for search and for shaping, which
    /// want the text without a copy of it.
    ///
    /// Where a piece ends is the rope's business and changes with edits: it
    /// is always a character boundary, and nothing else may be assumed.
    pub fn chunks(&self) -> Chunks<'_> {
        Chunks(self.rope.chunks())
    }

    /// The pieces of the text between the two positions of `range`, in
    /// order, with the first and the last cut to it. `None` unless both
    /// ends of the range are positions and the start is not after the end.
    pub fn chunks_in(&self, range: Range<usize>) -> Option<Chunks<'_>> {
        self.rope.chunks_in(range.start, range.end).map(Chunks)
    }

    /// The piece that holds the byte at `offset`, and the offset that piece
    /// starts at. This is what a parser's read callback asks: the text from
    /// `offset` on is the piece from `offset - start`.
    ///
    /// At the end of the text it is the last piece, so there is nothing
    /// from the offset on; in an empty text that piece is empty. `None`
    /// past the end. `offset` need not be a position.
    pub fn chunk_at(&self, offset: usize) -> Option<(&str, usize)> {
        self.rope.chunk_at(offset)
    }

    /// A copy of the text between the two positions of `range`. `None`
    /// unless both ends are positions and the start is not after the end.
    pub fn slice_to_string(&self, range: Range<usize>) -> Option<String> {
        self.chunks_in(range).map(Iterator::collect)
    }
}

/// The whole text. `to_string` copies it; [`Snapshot::chunks`] reads it
/// without a copy.
impl fmt::Display for Snapshot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.chunks().try_for_each(|chunk| f.write_str(chunk))
    }
}

/// The pieces of a snapshot's text, or of a range of it, in order
/// ([`Snapshot::chunks`], [`Snapshot::chunks_in`]).
pub struct Chunks<'a>(rope::Chunks<'a>);

impl<'a> Iterator for Chunks<'a> {
    type Item = &'a str;

    fn next(&mut self) -> Option<&'a str> {
        self.0.next()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Text;

    #[test]
    fn a_revision_made_from_a_number_is_the_revision_a_text_reaches_after_that_many_edits() {
        let mut text = Text::from("héllo");
        assert_eq!(Revision::new(0), text.current().revision());
        assert_eq!(Revision::new(0), Revision::default());

        text.replace(0..0, "x").expect("an insert at the start");
        text.replace(0..0, "y").expect("an insert at the start");

        assert_eq!(Revision::new(2), text.current().revision());
        assert_eq!(Revision::new(u64::MAX).get(), u64::MAX);
        assert!(Revision::new(3) > text.current().revision());
    }

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

    /// Two lines, with characters of one to four bytes.
    const LINES: &str = "héllo wörld\n😀 and the rest of a line\r\n";

    /// A text the rope holds in many pieces: tens of kilobytes of [`LINES`].
    fn long_text() -> String {
        LINES.repeat(1_000)
    }

    #[test]
    fn the_chunks_of_a_snapshot_joined_are_its_text() {
        for string in ["héllo", "😀", "a\0b", &long_text()] {
            let snapshot = Text::from(string).snapshot();

            assert_eq!(snapshot.chunks().collect::<String>(), string);
        }
    }

    #[test]
    fn a_long_text_is_held_in_many_chunks_and_none_is_empty() {
        let snapshot = Text::from(long_text().as_str()).snapshot();

        assert!(snapshot.chunks().count() > 16);
        assert!(snapshot.chunks().all(|chunk| !chunk.is_empty()));
    }

    #[test]
    fn an_empty_text_has_no_chunks() {
        assert_eq!(Text::new().snapshot().chunks().count(), 0);
    }

    #[test]
    fn the_chunks_in_a_range_joined_are_that_slice_of_the_text() {
        let string = long_text();
        let snapshot = Text::from(string.as_str()).snapshot();
        // From inside the first line to inside a line far from it, so the
        // first and the last chunk are both cut.
        let range = 3..LINES.len() * 700 + 4;

        let chunks = snapshot.chunks_in(range.clone()).expect("two positions");

        assert_eq!(chunks.collect::<String>(), string[range]);
    }

    #[test]
    fn the_chunks_in_an_empty_range_are_none_and_in_the_whole_text_are_all_of_it() {
        let string = long_text();
        let snapshot = Text::from(string.as_str()).snapshot();

        let empty = snapshot.chunks_in(4..4).expect("two positions");
        let whole = snapshot.chunks_in(0..string.len()).expect("two positions");

        assert_eq!(empty.count(), 0);
        assert_eq!(whole.collect::<String>(), string);
    }

    #[expect(
        clippy::reversed_empty_ranges,
        reason = "a backwards range is the point of the test: a caller can pass one"
    )]
    #[test]
    fn a_range_that_is_not_two_positions_in_order_has_no_chunks_and_no_slice() {
        let snapshot = Text::from("héllo").snapshot();

        for range in [2..3, 0..2, 3..1, 0..7, 7..7, usize::MAX..usize::MAX] {
            assert!(snapshot.chunks_in(range.clone()).is_none(), "{range:?}");
            assert_eq!(snapshot.slice_to_string(range.clone()), None, "{range:?}");
        }
    }

    #[test]
    fn a_slice_of_a_snapshot_is_the_text_between_two_positions() {
        let snapshot = Text::from("héllo wörld").snapshot();

        assert_eq!(snapshot.slice_to_string(1..3).as_deref(), Some("é"));
        assert_eq!(snapshot.slice_to_string(7..13).as_deref(), Some("wörld"));
        assert_eq!(snapshot.slice_to_string(4..4).as_deref(), Some(""));
        assert_eq!(
            snapshot.slice_to_string(0..13).as_deref(),
            Some("héllo wörld")
        );
    }

    #[test]
    fn the_chunk_at_an_offset_holds_the_byte_at_that_offset_and_says_where_it_starts() {
        let string = long_text();
        let snapshot = Text::from(string.as_str()).snapshot();

        for offset in 0..string.len() {
            let (chunk, start) = snapshot
                .chunk_at(offset)
                .expect("an offset within the text");

            assert!(
                start <= offset && offset < start + chunk.len(),
                "the chunk at {offset} is {start}..{}",
                start + chunk.len()
            );
            assert_eq!(
                chunk.as_bytes(),
                &string.as_bytes()[start..start + chunk.len()]
            );
        }
    }

    #[test]
    fn the_chunk_at_the_end_of_the_text_is_the_last_one_and_past_the_end_there_is_none() {
        let string = long_text();
        let snapshot = Text::from(string.as_str()).snapshot();

        let (chunk, start) = snapshot
            .chunk_at(string.len())
            .expect("the end of the text");

        assert_eq!(start + chunk.len(), string.len());
        assert_eq!(Some(chunk), snapshot.chunks().last());
        assert_eq!(snapshot.chunk_at(string.len() + 1), None);
        assert_eq!(snapshot.chunk_at(usize::MAX), None);
        assert_eq!(Text::new().snapshot().chunk_at(0), Some(("", 0)));
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
