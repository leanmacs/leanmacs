//! Words: variable-length plain data as it crosses the boundary.
//!
//! A list (the changes of a transaction, the edits of a patch, the pieces
//! of a trace) crosses as a buffer of *words*: 64-bit numbers, each as
//! eight bytes, least significant first. What the words mean is the
//! function's that takes or fills them, and its doc comment gives the
//! layout.
//!
//! - **Lean to Rust**: the buffer is borrowed for the call. A [`Reader`]
//!   takes it apart, and trusts nothing in it: a length that is not whole
//!   words, a count of items the buffer is too short for, and words left
//!   over when the reading is done are each a refusal, never a panic and
//!   never an allocation sized by a number that was not checked.
//! - **Rust to Lean**: a [`Writer`] builds the buffer, and it is lent in
//!   the result record as a string is ([`lend`]): the caller copies it and
//!   hands it back with one call to
//!   [`editor_ffi_text_free`](crate::text::editor_ffi_text_free).
//!
//! A number the other side cannot hold is not cut down. A word no `usize`
//! holds reads as the largest `usize` ([`size`]), which no text is long
//! enough to accept as a length or an offset, so the text refuses it in
//! its usual order; Lean sends a number no word holds as the largest word
//! for the same reason.

/// How many bytes a word is.
const WORD: usize = size_of::<u64>();

/// The length or offset `word` stands for: the word, or the largest
/// `usize` when no `usize` holds it.
pub(crate) fn size(word: u64) -> usize {
    usize::try_from(word).unwrap_or(usize::MAX)
}

/// The word that stands for the length or offset `size`.
pub(crate) fn word(size: usize) -> u64 {
    u64::try_from(size).unwrap_or(u64::MAX)
}

/// Words being read from a buffer the caller lent.
pub(crate) struct Reader<'a> {
    /// The words not yet read, each as its eight bytes.
    words: std::slice::Iter<'a, [u8; WORD]>,
}

impl<'a> Reader<'a> {
    /// A reader of `bytes`. `None` unless its length is whole words.
    pub(crate) fn new(bytes: &'a [u8]) -> Option<Self> {
        let (words, rest) = bytes.as_chunks::<WORD>();
        rest.is_empty().then(|| Self {
            words: words.iter(),
        })
    }

    /// The next word. `None` when there is none left.
    pub(crate) fn word(&mut self) -> Option<u64> {
        self.words.next().copied().map(u64::from_le_bytes)
    }

    /// The next word as a length or an offset ([`size`]).
    pub(crate) fn size(&mut self) -> Option<usize> {
        self.word().map(size)
    }

    /// The next word as a count of items that are `each` words long.
    /// `None` when the buffer has fewer words left than that many items
    /// take, so a count is safe to allocate by and to loop to.
    pub(crate) fn count(&mut self, each: usize) -> Option<usize> {
        let count = usize::try_from(self.word()?).ok()?;
        (count.checked_mul(each)? <= self.words.len()).then_some(count)
    }

    /// Ends the reading. `None` when words are left over.
    pub(crate) fn finish(self) -> Option<()> {
        (self.words.len() == 0).then_some(())
    }
}

/// Words being written to a buffer for a result record.
#[derive(Default)]
pub(crate) struct Writer {
    /// The words so far, as bytes.
    bytes: Vec<u8>,
}

impl Writer {
    /// A writer with room for `words` words.
    pub(crate) fn with_capacity(words: usize) -> Self {
        Self {
            bytes: Vec::with_capacity(words.saturating_mul(WORD)),
        }
    }

    /// Adds `word`.
    pub(crate) fn word(&mut self, word: u64) {
        self.bytes.extend_from_slice(&word.to_le_bytes());
    }

    /// Adds the length or offset `size` ([`word`]).
    pub(crate) fn size(&mut self, size: usize) {
        self.word(word(size));
    }

    /// The buffer written.
    pub(crate) fn finish(self) -> Vec<u8> {
        self.bytes
    }
}

/// The bytes Lean lent for the length of a call: `len` bytes at `bytes`.
/// No bytes at all may be lent with any pointer, a null one included.
///
/// # Safety
///
/// `bytes` points to `len` readable bytes that stay unchanged for `'a`.
pub(crate) unsafe fn borrow<'a>(bytes: *const u8, len: usize) -> &'a [u8] {
    if len == 0 {
        return &[];
    }
    // SAFETY: the caller guarantees the pointer, the length and the
    // lifetime, and a slice of bytes has no alignment to keep.
    unsafe { std::slice::from_raw_parts(bytes, len) }
}

/// Gives `bytes` up as a buffer for a result record: its pointer and its
/// length. The caller hands both back to
/// [`editor_ffi_text_free`](crate::text::editor_ffi_text_free).
pub(crate) fn lend(bytes: Vec<u8>) -> (*mut u8, usize) {
    let bytes = bytes.into_boxed_slice();
    let len = bytes.len();
    (Box::into_raw(bytes).cast(), len)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// The buffer that holds `words`.
    pub(crate) fn buffer(words: &[u64]) -> Vec<u8> {
        words.iter().flat_map(|word| word.to_le_bytes()).collect()
    }

    /// The words `bytes` holds.
    pub(crate) fn words_of(bytes: &[u8]) -> Vec<u64> {
        let mut reader = Reader::new(bytes).expect("whole words");
        std::iter::from_fn(|| reader.word()).collect()
    }

    #[test]
    fn a_word_is_eight_bytes_least_significant_first() {
        let mut writer = Writer::default();
        writer.word(0x0102_0304_0506_0708);

        assert_eq!(writer.finish(), [8, 7, 6, 5, 4, 3, 2, 1]);
    }

    #[test]
    fn the_words_a_writer_wrote_read_back_in_order() {
        let mut writer = Writer::with_capacity(4);
        writer.word(0);
        writer.word(u64::MAX);
        writer.size(7);
        writer.word(1 << 40);
        let bytes = writer.finish();

        let mut reader = Reader::new(&bytes).expect("whole words");

        assert_eq!(reader.word(), Some(0));
        assert_eq!(reader.word(), Some(u64::MAX));
        assert_eq!(reader.size(), Some(7));
        assert_eq!(reader.word(), Some(1 << 40));
        assert_eq!(reader.word(), None);
        assert_eq!(reader.finish(), Some(()));
    }

    #[test]
    fn an_empty_buffer_has_no_word_and_nothing_left_over() {
        let mut reader = Reader::new(&[]).expect("no words are whole words");

        assert_eq!(reader.word(), None);
        assert_eq!(reader.finish(), Some(()));
    }

    #[test]
    fn a_reader_refuses_a_length_that_is_not_whole_words() {
        assert!(Reader::new(&[0; 7]).is_none());
        assert!(Reader::new(&[0; 9]).is_none());
        assert!(Reader::new(&[0; 1]).is_none());
        assert!(Reader::new(&[0; 16]).is_some());
    }

    #[test]
    fn a_reader_refuses_a_count_that_runs_past_the_buffer() {
        // A count of two items of two words, with three words after it.
        let bytes = buffer(&[2, 10, 11, 12]);
        let mut reader = Reader::new(&bytes).expect("whole words");
        assert_eq!(reader.count(2), None);

        // The same count fits items of one word.
        let mut reader = Reader::new(&bytes).expect("whole words");
        assert_eq!(reader.count(1), Some(2));

        // A count no buffer could hold, and one whose size overflows.
        let bytes = buffer(&[u64::MAX, 0]);
        let mut reader = Reader::new(&bytes).expect("whole words");
        assert_eq!(reader.count(1), None);
        let mut reader = Reader::new(&bytes).expect("whole words");
        assert_eq!(reader.count(2), None);

        // A count of no items is always there to read.
        let bytes = buffer(&[0]);
        let mut reader = Reader::new(&bytes).expect("whole words");
        assert_eq!(reader.count(12), Some(0));
        // And no count at all is not.
        assert_eq!(reader.count(1), None);
    }

    #[test]
    fn a_reader_refuses_to_finish_with_words_left_over() {
        let bytes = buffer(&[1, 2]);
        let mut reader = Reader::new(&bytes).expect("whole words");
        assert_eq!(reader.word(), Some(1));

        assert_eq!(reader.finish(), None);
    }

    #[test]
    fn a_word_no_size_holds_reads_as_the_largest_size() {
        assert_eq!(size(0), 0);
        assert_eq!(size(20), 20);
        assert_eq!(size(u64::MAX), usize::MAX);
        let bytes = buffer(&[u64::MAX]);
        let mut reader = Reader::new(&bytes).expect("whole words");
        assert_eq!(reader.size(), Some(usize::MAX));
    }

    #[test]
    fn a_size_is_written_as_its_word() {
        assert_eq!(word(0), 0);
        assert_eq!(word(20), 20);
        let mut writer = Writer::default();
        writer.size(20);
        assert_eq!(words_of(&writer.finish()), [20]);
    }

    #[test]
    fn a_lent_buffer_is_the_bytes_and_their_length() {
        let (pointer, len) = lend(vec![1, 2, 3]);

        assert_eq!(len, 3);
        // SAFETY: `lend` gave these parts up, and they are taken back once.
        let bytes = unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(pointer, len)) };
        assert_eq!(*bytes, [1, 2, 3]);
    }
}
