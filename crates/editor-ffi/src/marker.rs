//! A document's markers as they cross the boundary, and what a selection
//! covers.
//!
//! A marker is an anchor or a selection that a document's text holds and
//! moves with every transaction. It crosses as words (the private module
//! `words`), in both directions:
//!
//! - **an anchor**: 0, its offset, and its bias (0 before, 1 after);
//! - **a selection**: 1, and then the selection's words as a transaction
//!   carries them, without the presence word: its shape (0 exclusive, 1
//!   inclusive, 2 line-wise, 3 block-wise), the index of its primary
//!   range, the count of ranges, and an anchor and a head for each.
//!
//! A marker's id is the text's number for it, and crosses as a `u64`.
//!
//! What a selection covers in a snapshot
//! ([`editor_ffi_snapshot_extents`](crate::snapshot::editor_ffi_snapshot_extents))
//! takes the selection's words, without the 1 that says a marker is one,
//! and answers with **extents**: their count, and a start and an end for
//! each.
//!
//! Where a marker goes when the text is edited, which markers are refused,
//! the form a selection is kept in and what a shape covers are the text's
//! rules, pinned by `editor-text`'s own tests. This module reads and writes
//! the words and forwards.

use std::ops::Range;

use editor_text::{Anchor, Bias, MarkError, Marker, MarkerId, Selection};

use crate::document::Document;
use crate::log::RawWords;
use crate::transaction::{SelectionWords, Undecoded, shape_word};
use crate::words::{Reader, Writer};

/// How a request about a marker, or about what a selection covers, ended,
/// as it crosses the boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarkStatus {
    /// Done: marked, placed, or answered.
    Done = 0,
    /// Refused: the anchor's offset is not a position of the text.
    BadPosition = 1,
    /// Refused: the selection is not one, or an end of one of its ranges
    /// is not a position of the text.
    BadSelection = 2,
    /// Refused: the words could not be read.
    Unreadable = 3,
    /// Refused: the text holds no marker with that id.
    NoSuchMarker = 4,
}

impl MarkStatus {
    /// The status that reports `error`. The text's refusals are few and
    /// each has a status of its own, so this names every one: a new
    /// refusal must be given a number here before it can cross.
    pub const fn of(error: MarkError) -> Self {
        match error {
            MarkError::NoSuchMarker => Self::NoSuchMarker,
            MarkError::BadPosition => Self::BadPosition,
            MarkError::BadSelection => Self::BadSelection,
        }
    }

    /// The status that reports why words did not spell a marker or a
    /// selection.
    const fn undecoded(undecoded: Undecoded) -> Self {
        match undecoded {
            Undecoded::Unreadable => Self::Unreadable,
            Undecoded::NotASelection => Self::BadSelection,
        }
    }
}

/// The marker `words` spell, in the layout the module docs give.
/// [`Undecoded::Unreadable`] when they cannot be read: the buffer is not
/// whole words, it stops short, words are left over, or a kind, a bias or
/// a shape is unknown. [`Undecoded::NotASelection`] for a selection with
/// no range or whose primary names none.
pub fn decode(words: &[u8]) -> Result<Marker, Undecoded> {
    // Everything is read before anything is judged, so words that cannot
    // be read are reported as that whatever else is wrong with them.
    match read(words).ok_or(Undecoded::Unreadable)? {
        MarkerWords::Anchor(anchor) => Ok(Marker::Anchor(anchor)),
        MarkerWords::Selection(selection) => Ok(Marker::Selection(selection.selection()?)),
    }
}

/// The selection `words` spell: a selection's words, from its shape on.
/// The refusals are [`decode`]'s.
pub fn decode_selection(words: &[u8]) -> Result<Selection, Undecoded> {
    let read = |words| {
        let mut reader = Reader::new(words)?;
        let selection = SelectionWords::read(&mut reader)?;
        reader.finish()?;
        Some(selection)
    };
    read(words).ok_or(Undecoded::Unreadable)?.selection()
}

/// What a marker's words spell, before a selection is known to be one.
enum MarkerWords {
    /// An anchor.
    Anchor(Anchor),
    /// A selection's words.
    Selection(SelectionWords),
}

/// The marker `words` spell, read and not yet judged. `None` when they
/// cannot be read.
fn read(words: &[u8]) -> Option<MarkerWords> {
    let mut reader = Reader::new(words)?;
    let marker = match reader.word()? {
        0 => {
            let offset = reader.size()?;
            let bias = match reader.word()? {
                0 => Bias::Before,
                1 => Bias::After,
                _ => return None,
            };
            MarkerWords::Anchor(Anchor::new(offset, bias))
        }
        1 => MarkerWords::Selection(SelectionWords::read(&mut reader)?),
        _ => return None,
    };
    reader.finish()?;
    Some(marker)
}

/// The words of `marker`, in the layout the module docs give. Every kind
/// of marker, and either bias, must cross, so this names every one: a new
/// kind must be given its words here, and in [`decode`], before it can.
pub fn marker_words(marker: &Marker) -> Vec<u8> {
    match marker {
        Marker::Anchor(anchor) => {
            let mut writer = Writer::with_capacity(3);
            writer.word(0);
            writer.size(anchor.offset);
            writer.word(match anchor.bias {
                Bias::Before => 0,
                Bias::After => 1,
            });
            writer.finish()
        }
        Marker::Selection(selection) => {
            let ranges = selection.ranges();
            let mut writer = Writer::with_capacity(4 + 2 * ranges.len());
            writer.word(1);
            writer.word(shape_word(selection.shape()));
            writer.size(selection.primary());
            writer.size(ranges.len());
            for range in ranges {
                writer.size(range.anchor);
                writer.size(range.head);
            }
            writer.finish()
        }
    }
}

/// The words of `extents`: their count, and a start and an end for each.
pub fn extent_words(extents: &[Range<usize>]) -> Vec<u8> {
    let mut writer = Writer::with_capacity(1 + 2 * extents.len());
    writer.size(extents.len());
    for extent in extents {
        writer.size(extent.start);
        writer.size(extent.end);
    }
    writer.finish()
}

/// The result of marking a document: one record, filled in one call.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RawMarked {
    /// A [`MarkStatus`], as its number.
    pub status: u64,
    /// The id of the new marker. 0 unless the status is
    /// [`MarkStatus::Done`].
    pub id: u64,
}

impl Document {
    /// Has the text hold `marker` ([`editor_text::Text::mark`]).
    pub fn mark(&self, marker: Marker) -> Result<MarkerId, MarkError> {
        self.lock().mark(marker)
    }

    /// A copy of the marker with the id `id`, where it is now
    /// ([`editor_text::Text::marker`]).
    pub fn marker(&self, id: MarkerId) -> Option<Marker> {
        self.lock().marker(id).cloned()
    }

    /// Puts `marker` in place of the marker with the id `id`
    /// ([`editor_text::Text::place`]).
    pub fn place(&self, id: MarkerId, marker: Marker) -> Result<(), MarkError> {
        self.lock().place(id, marker)
    }

    /// Gives up the marker with the id `id`, and returns whether there was
    /// one ([`editor_text::Text::unmark`]).
    pub fn unmark(&self, id: MarkerId) -> bool {
        self.lock().unmark(id)
    }

    /// Marks the document with the marker `words` spell ([`decode`]), and
    /// says how it ended. Anything but [`MarkStatus::Done`] marked nothing.
    pub fn mark_words(&self, words: &[u8]) -> RawMarked {
        let marked = decode(words)
            .map_err(MarkStatus::undecoded)
            .and_then(|marker| self.mark(marker).map_err(MarkStatus::of));
        match marked {
            Ok(id) => RawMarked {
                status: MarkStatus::Done as u64,
                id: id.get(),
            },
            Err(status) => RawMarked {
                status: status as u64,
                id: 0,
            },
        }
    }

    /// Puts the marker `words` spell ([`decode`]) in place of the marker
    /// with the number `id`, and says how it ended. Anything but
    /// [`MarkStatus::Done`] changed nothing.
    ///
    /// Words that cannot be read, and a selection that is not one, are
    /// refused before the id is looked up; after that the order is the
    /// text's ([`editor_text::Text::place`]).
    pub fn place_words(&self, id: u64, words: &[u8]) -> MarkStatus {
        let placed = decode(words)
            .map_err(MarkStatus::undecoded)
            .and_then(|marker| {
                self.place(MarkerId::new(id), marker)
                    .map_err(MarkStatus::of)
            });
        match placed {
            Ok(()) => MarkStatus::Done,
            Err(status) => status,
        }
    }
}

/// [`Document::mark_words`] for C: marks `document` with the marker the
/// `len` bytes at `words` spell, and fills `out`.
///
/// # Safety
///
/// `document` came from [`editor_ffi_document_new`] and has not been freed;
/// `words` points to `len` readable bytes; and `out` points to a writable
/// [`RawMarked`].
///
/// [`editor_ffi_document_new`]: crate::document::editor_ffi_document_new
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_document_mark(
    document: *const Document,
    words: *const u8,
    len: usize,
    out: *mut RawMarked,
) {
    // SAFETY: the caller guarantees the pointer and the length.
    let words = unsafe { crate::words::borrow(words, len) };
    // SAFETY: the caller guarantees `document` points to a live document.
    let marked = unsafe { &*document }.mark_words(words);
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(marked) };
}

/// [`Document::marker`] for C: fills `out` with the words of the marker of
/// `document` with the number `id`, where it is now, and the status
/// [`MarkStatus::Done`]; or with no words and
/// [`MarkStatus::NoSuchMarker`].
///
/// # Safety
///
/// `document` came from [`editor_ffi_document_new`] and has not been freed,
/// and `out` points to a writable [`RawWords`].
///
/// [`editor_ffi_document_new`]: crate::document::editor_ffi_document_new
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_document_marker(
    document: *const Document,
    id: u64,
    out: *mut RawWords,
) {
    // SAFETY: the caller guarantees `document` points to a live document.
    let marker = unsafe { &*document }.marker(MarkerId::new(id));
    let raw = match marker {
        Some(marker) => RawWords::with_status(MarkStatus::Done as u64, marker_words(&marker)),
        None => RawWords::with_status(MarkStatus::NoSuchMarker as u64, Vec::new()),
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
}

/// [`Document::place_words`] for C: puts the marker the `len` bytes at
/// `words` spell in place of the marker of `document` with the number
/// `id`, and returns a [`MarkStatus`] as its number.
///
/// # Safety
///
/// `document` came from [`editor_ffi_document_new`] and has not been freed,
/// and `words` points to `len` readable bytes.
///
/// [`editor_ffi_document_new`]: crate::document::editor_ffi_document_new
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_document_place(
    document: *const Document,
    id: u64,
    words: *const u8,
    len: usize,
) -> u64 {
    // SAFETY: the caller guarantees the pointer and the length.
    let words = unsafe { crate::words::borrow(words, len) };
    // SAFETY: the caller guarantees `document` points to a live document.
    unsafe { &*document }.place_words(id, words) as u64
}

/// [`Document::unmark`] for C: gives up the marker of `document` with the
/// number `id`, and returns whether there was one.
///
/// # Safety
///
/// `document` came from [`editor_ffi_document_new`] and has not been freed.
///
/// [`editor_ffi_document_new`]: crate::document::editor_ffi_document_new
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_document_unmark(document: *const Document, id: u64) -> bool {
    // SAFETY: the caller guarantees `document` points to a live document.
    unsafe { &*document }.unmark(MarkerId::new(id))
}

#[cfg(test)]
mod tests {
    use editor_text::{SelectionRange, Shape, Text};

    use super::*;
    use crate::words::tests::{buffer, words_of};

    /// The kinds of a marker, as words.
    const ANCHOR: u64 = 0;
    const SELECTION: u64 = 1;

    /// The biases of an anchor, as words.
    const BEFORE: u64 = 0;
    const AFTER: u64 = 1;

    /// The shapes of a selection, as words.
    const EXCLUSIVE: u64 = 0;
    const INCLUSIVE: u64 = 1;
    const LINE: u64 = 2;
    const BLOCK: u64 = 3;

    /// "é" and "ö" are two bytes each: in "héllo wörld" the offset 2 is
    /// inside "é". The text is 13 bytes.
    const TEXT: &str = "héllo wörld";

    /// A selection of shape `shape` of the ranges `ranges`, each an anchor
    /// and a head.
    fn shaped(shape: Shape, ranges: &[(usize, usize)], primary: usize) -> Selection {
        let ranges = ranges
            .iter()
            .map(|&(anchor, head)| SelectionRange::new(anchor, head))
            .collect();
        Selection::shaped(shape, ranges, primary).expect("a primary among the ranges")
    }

    #[test]
    fn the_words_of_an_anchor_decode_to_it() {
        assert_eq!(
            decode(&buffer(&[ANCHOR, 7, BEFORE])),
            Ok(Marker::Anchor(Anchor::new(7, Bias::Before)))
        );
        assert_eq!(
            decode(&buffer(&[ANCHOR, 0, AFTER])),
            Ok(Marker::Anchor(Anchor::new(0, Bias::After)))
        );
        // An offset no size holds is the largest size, and not cut down.
        assert_eq!(
            decode(&buffer(&[ANCHOR, u64::MAX, AFTER])),
            Ok(Marker::Anchor(Anchor::new(usize::MAX, Bias::After)))
        );
    }

    #[test]
    fn the_words_of_a_selection_decode_to_it() {
        let words = buffer(&[SELECTION, BLOCK, 1, 2, 9, 7, 2, 5]);

        assert_eq!(
            decode(&words),
            Ok(Marker::Selection(shaped(
                Shape::Block,
                &[(9, 7), (2, 5)],
                1
            )))
        );
        // The same words without the kind are the selection alone.
        assert_eq!(
            decode_selection(&buffer(&[BLOCK, 1, 2, 9, 7, 2, 5])),
            Ok(shaped(Shape::Block, &[(9, 7), (2, 5)], 1))
        );
        assert_eq!(
            decode_selection(&buffer(&[EXCLUSIVE, 0, 1, 3, 3])),
            Ok(shaped(Shape::Exclusive, &[(3, 3)], 0))
        );
    }

    #[test]
    fn an_anchor_is_written_as_its_kind_its_offset_and_its_bias() {
        let before = Marker::Anchor(Anchor::new(7, Bias::Before));
        let after = Marker::Anchor(Anchor::new(11, Bias::After));

        assert_eq!(words_of(&marker_words(&before)), [ANCHOR, 7, BEFORE]);
        assert_eq!(words_of(&marker_words(&after)), [ANCHOR, 11, AFTER]);
    }

    #[test]
    fn a_selection_is_written_as_its_kind_its_shape_its_primary_and_its_ranges() {
        let shapes = [
            (EXCLUSIVE, Shape::Exclusive),
            (INCLUSIVE, Shape::Inclusive),
            (LINE, Shape::Line),
            (BLOCK, Shape::Block),
        ];
        for (word, shape) in shapes {
            let selection = shaped(shape, &[(21, 25), (30, 31), (9, 4)], 1);
            // The order of the ranges, their merging and the primary's
            // index are the text's rules: what is written is what the
            // selection holds, whatever that is.
            let mut expected = vec![
                SELECTION,
                word,
                selection.primary() as u64,
                selection.ranges().len() as u64,
            ];
            for range in selection.ranges() {
                expected.extend([range.anchor as u64, range.head as u64]);
            }

            let written = marker_words(&Marker::Selection(selection.clone()));

            assert_eq!(words_of(&written), expected, "{shape:?}");
            // And the words read back as the marker.
            assert_eq!(decode(&written), Ok(Marker::Selection(selection)));
        }
    }

    #[test]
    fn marker_words_that_cannot_be_read_are_unreadable() {
        let unreadable = |words: &[u64]| {
            assert_eq!(
                decode(&buffer(words)),
                Err(Undecoded::Unreadable),
                "{words:?}"
            );
        };

        // Nothing at all, and a kind that is none.
        unreadable(&[]);
        unreadable(&[2, 0, 0]);
        unreadable(&[u64::MAX]);
        // An anchor that stops short, one with words left over, and a bias
        // that is none.
        unreadable(&[ANCHOR]);
        unreadable(&[ANCHOR, 3]);
        unreadable(&[ANCHOR, 3, BEFORE, 0]);
        unreadable(&[ANCHOR, 3, 2]);
        // A selection that stops short, one whose count runs past the
        // buffer, one with words left over, and a shape that is none.
        unreadable(&[SELECTION]);
        unreadable(&[SELECTION, LINE, 0]);
        unreadable(&[SELECTION, LINE, 0, 2, 1, 1]);
        unreadable(&[SELECTION, LINE, 0, 1, 1, 1, 1]);
        unreadable(&[SELECTION, 4, 0, 1, 1, 1]);
        // A length that is not whole words.
        assert_eq!(decode(&[0; 23]), Err(Undecoded::Unreadable));
    }

    #[test]
    fn selection_words_that_cannot_be_read_are_unreadable() {
        for words in [
            &[][..],
            &[LINE],
            &[4, 0, 1, 1, 1],
            &[LINE, 0, 2, 1, 1],
            &[LINE, 0, 1, 1, 1, 1],
        ] {
            assert_eq!(
                decode_selection(&buffer(words)),
                Err(Undecoded::Unreadable),
                "{words:?}"
            );
        }
    }

    #[test]
    fn a_selection_with_no_range_or_whose_primary_names_none_is_not_a_selection() {
        assert_eq!(
            decode(&buffer(&[SELECTION, EXCLUSIVE, 0, 0])),
            Err(Undecoded::NotASelection)
        );
        assert_eq!(
            decode(&buffer(&[SELECTION, INCLUSIVE, 1, 1, 0, 0])),
            Err(Undecoded::NotASelection)
        );
        assert_eq!(
            decode_selection(&buffer(&[BLOCK, u64::MAX, 1, 0, 0])),
            Err(Undecoded::NotASelection)
        );
    }

    #[test]
    fn each_refusal_of_a_marker_is_its_status() {
        assert_eq!(
            MarkStatus::of(MarkError::BadPosition),
            MarkStatus::BadPosition
        );
        assert_eq!(
            MarkStatus::of(MarkError::BadSelection),
            MarkStatus::BadSelection
        );
        assert_eq!(
            MarkStatus::of(MarkError::NoSuchMarker),
            MarkStatus::NoSuchMarker
        );
        // The numbers the glue and Lean read.
        assert_eq!(MarkStatus::Done as u64, 0);
        assert_eq!(MarkStatus::BadPosition as u64, 1);
        assert_eq!(MarkStatus::BadSelection as u64, 2);
        assert_eq!(MarkStatus::Unreadable as u64, 3);
        assert_eq!(MarkStatus::NoSuchMarker as u64, 4);
    }

    #[test]
    fn marking_with_words_holds_the_marker_they_spell_and_reports_its_id() {
        let document = Document::new(TEXT);
        let anchor = buffer(&[ANCHOR, 3, AFTER]);
        let selection = buffer(&[SELECTION, LINE, 0, 1, 6, 1]);

        let first = document.mark_words(&anchor);
        let second = document.mark_words(&selection);

        assert_eq!(first.status, MarkStatus::Done as u64);
        assert_eq!(second.status, MarkStatus::Done as u64);
        assert_ne!(first.id, second.id);
        assert_eq!(
            document.marker(MarkerId::new(first.id)),
            decode(&anchor).ok()
        );
        assert_eq!(
            document.marker(MarkerId::new(second.id)),
            decode(&selection).ok()
        );
    }

    #[test]
    fn a_marker_the_text_refuses_is_reported_as_the_texts_refusal() {
        let document = Document::new(TEXT);
        // Inside "é", and past the end: which markers are refused is the
        // text's rule, so each status is the one of what a text holding
        // the same string answers.
        for words in [
            &[ANCHOR, 2, BEFORE][..],
            &[ANCHOR, 99, AFTER],
            &[SELECTION, EXCLUSIVE, 0, 1, 0, 2],
            &[SELECTION, BLOCK, 0, 1, 99, 0],
        ] {
            let words = buffer(words);
            let marker = decode(&words).expect("words that can be read");
            let refusal = Text::from(TEXT)
                .mark(marker)
                .expect_err("a marker the text refuses");

            assert_eq!(
                document.mark_words(&words),
                RawMarked {
                    status: MarkStatus::of(refusal) as u64,
                    id: 0
                }
            );
        }
    }

    #[test]
    fn words_that_spell_no_marker_are_reported_and_mark_nothing() {
        let document = Document::new(TEXT);

        assert_eq!(
            document.mark_words(&buffer(&[ANCHOR, 3, 2])),
            RawMarked {
                status: MarkStatus::Unreadable as u64,
                id: 0
            }
        );
        assert_eq!(
            document.mark_words(&buffer(&[SELECTION, LINE, 0, 0])),
            RawMarked {
                status: MarkStatus::BadSelection as u64,
                id: 0
            }
        );
    }

    #[test]
    fn placing_with_words_puts_the_marker_they_spell_in_place() {
        let document = Document::new(TEXT);
        let id = document.mark_words(&buffer(&[ANCHOR, 3, AFTER])).id;
        let selection = buffer(&[SELECTION, INCLUSIVE, 0, 1, 4, 4]);

        assert_eq!(document.place_words(id, &selection), MarkStatus::Done);

        assert_eq!(document.marker(MarkerId::new(id)), decode(&selection).ok());
    }

    #[test]
    fn a_place_the_text_refuses_is_reported_as_the_texts_refusal() {
        let document = Document::new(TEXT);
        let held = buffer(&[ANCHOR, 3, AFTER]);
        let id = document.mark_words(&held).id;
        let mut text = Text::from(TEXT);
        let same = text
            .mark(decode(&held).expect("an anchor"))
            .expect("a position");
        let unknown = MarkerId::new(same.get() + 1);

        // A marker that is not in the text for a known id, and a marker
        // that is and one that is not for an unknown one.
        for (id, of_text, words) in [
            (id, same, &[ANCHOR, 2, BEFORE][..]),
            (id, same, &[SELECTION, LINE, 0, 1, 0, 99]),
            (id + 1, unknown, &[ANCHOR, 0, BEFORE]),
            (id + 1, unknown, &[ANCHOR, 2, BEFORE]),
        ] {
            let words = buffer(words);
            let marker = decode(&words).expect("words that can be read");
            let refusal = text
                .place(of_text, marker)
                .expect_err("a place the text refuses");

            assert_eq!(document.place_words(id, &words), MarkStatus::of(refusal));
        }
        assert_eq!(document.marker(MarkerId::new(id)), decode(&held).ok());
    }

    #[test]
    fn words_that_spell_no_marker_are_refused_before_the_id_is_looked_up() {
        let document = Document::new(TEXT);
        let unknown = document.mark_words(&buffer(&[ANCHOR, 3, AFTER])).id + 1;

        assert_eq!(
            document.place_words(unknown, &buffer(&[SELECTION, LINE, 0, 0])),
            MarkStatus::BadSelection
        );
        assert_eq!(
            document.place_words(unknown, &buffer(&[ANCHOR, 3])),
            MarkStatus::Unreadable
        );
    }

    #[test]
    fn unmarking_gives_the_marker_up_and_an_unknown_id_is_false() {
        let document = Document::new(TEXT);
        let id = document.mark_words(&buffer(&[ANCHOR, 3, AFTER])).id;

        assert!(!document.unmark(MarkerId::new(id + 1)));
        assert!(document.unmark(MarkerId::new(id)));
        assert_eq!(document.marker(MarkerId::new(id)), None);
        assert!(!document.unmark(MarkerId::new(id)));
    }

    #[test]
    fn extents_are_written_as_their_count_and_a_start_and_an_end_for_each() {
        // The extents of no text: what a selection covers is the text's
        // rule.
        let extents = [3..7, 9..9, 12..40];

        assert_eq!(words_of(&extent_words(&extents)), [3, 3, 7, 9, 9, 12, 40]);
        assert_eq!(words_of(&extent_words(&[])), [0]);
    }
}
