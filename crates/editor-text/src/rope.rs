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

    /// Replaces the bytes from `start` up to, not including, `end` with
    /// `text`, and returns whether it did.
    ///
    /// The caller has checked that both offsets are character boundaries
    /// within the text and that `start <= end`, which is all either step
    /// below can fail on. So false is not expected; it is returned, and not
    /// a panic, because the library reports its refusals as errors.
    pub(crate) fn replace(&mut self, start: usize, end: usize, text: &str) -> bool {
        // An empty step is skipped, so an edit that changes nothing does not
        // touch the tree.
        (start == end || self.0.try_remove(start..end).is_ok())
            && (text.is_empty() || self.0.try_insert(start, text).is_ok())
    }

    /// How many rows the text has: one more than its line feeds.
    pub(crate) fn row_count(&self) -> usize {
        self.0.len_lines(ROWS)
    }

    /// The row that holds `offset`: how many line feeds are before it.
    /// `None` past the end of the text.
    pub(crate) fn row_of(&self, offset: usize) -> Option<usize> {
        (offset <= self.len()).then(|| self.0.byte_to_line_idx(offset, ROWS))
    }

    /// The offset the row `row` starts at. `None` when the text has no such
    /// row.
    pub(crate) fn row_start(&self, row: usize) -> Option<usize> {
        (row < self.row_count()).then(|| self.0.line_to_byte_idx(row, ROWS))
    }

    /// The length of the text in UTF-16 code units.
    pub(crate) fn len_utf16(&self) -> usize {
        self.0.len_utf16()
    }

    /// How many UTF-16 code units are before `offset`. `None` past the end
    /// of the text. An offset inside a character counts as the character's
    /// start.
    pub(crate) fn utf16_of(&self, offset: usize) -> Option<usize> {
        (offset <= self.len()).then(|| self.0.byte_to_utf16_idx(offset))
    }

    /// The offset `units` UTF-16 code units into the text. `None` past the
    /// end of the text. A count that falls between the two units of one
    /// character gives the character's start.
    pub(crate) fn offset_of_utf16(&self, units: usize) -> Option<usize> {
        (units <= self.len_utf16()).then(|| self.0.utf16_to_byte_idx(units))
    }

    /// The pieces the text is held in, in order. Joined, they are the text.
    /// None is empty.
    pub(crate) fn chunks(&self) -> Chunks<'_> {
        Chunks(self.0.chunks())
    }

    /// The pieces of the text from `start` up to, not including, `end`, in
    /// order: the first and the last are cut to the range. `None` unless
    /// both offsets are character boundaries within the text and
    /// `start <= end`.
    pub(crate) fn chunks_in(&self, start: usize, end: usize) -> Option<Chunks<'_>> {
        // The library panics past the end before it reports a refusal.
        if start > end || !self.is_char_boundary(start) || !self.is_char_boundary(end) {
            return None;
        }
        let slice = self.0.try_slice(start..end).ok()?;
        Some(Chunks(slice.chunks()))
    }

    /// The piece that holds the byte at `offset`, and the offset the piece
    /// starts at. At the end of the text, the last piece, which is empty
    /// only when the text is. `None` past the end.
    pub(crate) fn chunk_at(&self, offset: usize) -> Option<(&str, usize)> {
        self.0.get_chunk(offset)
    }
}

/// The row rule the crate counts by: a row ends at a line feed and nowhere
/// else, so a carriage return is a character of its row.
const ROWS: ropey::LineType = ropey::LineType::LF;

/// The pieces of a text, or of a range of one, in order.
pub(crate) struct Chunks<'a>(ropey::iter::Chunks<'a>);

impl<'a> Iterator for Chunks<'a> {
    type Item = &'a str;

    fn next(&mut self) -> Option<&'a str> {
        self.0.next()
    }
}
