//! Text search: the example of options and a byte range crossing the
//! boundary.

use std::borrow::Cow;
use std::ops::Range;
use std::{ptr, slice};

/// The byte offsets of the first occurrence of `needle` in `haystack` at or
/// after the byte offset `start` (the beginning, if `None`).
///
/// `None` when there is no such occurrence, and when `start` is past the end
/// of `haystack` or inside a character.
pub fn find(haystack: &str, needle: &str, start: Option<usize>) -> Option<Range<usize>> {
    let start = start.unwrap_or(0);
    let found = start + haystack.get(start..)?.find(needle)?;
    Some(found..found + needle.len())
}

/// A range of byte offsets into text, half-open, as it crosses the boundary.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ByteRange {
    /// The offset of the first byte.
    pub start: u64,
    /// The offset one past the last byte.
    pub end: u64,
}

/// [`find`] for C: returns whether there is a match, and if so fills `out`
/// with its range. `start` is read only when `has_start` is set.
///
/// Both texts are expected to be UTF-8, as a Lean string is. Bytes that are
/// not are read as text with U+FFFD in place of each invalid sequence, in
/// the haystack and in the needle alike. The search runs over that text, so
/// `start` and the range filled in are byte offsets into it, not into the
/// bytes passed in: a replacement character is three bytes long.
///
/// # Safety
///
/// `haystack` and `needle` point to `haystack_len` and `needle_len` readable
/// bytes, and `out` to a writable [`ByteRange`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_text_find(
    haystack: *const u8,
    haystack_len: usize,
    needle: *const u8,
    needle_len: usize,
    has_start: bool,
    start: usize,
    out: *mut ByteRange,
) -> bool {
    // SAFETY: the caller guarantees both pointers and lengths.
    let (haystack, needle) =
        unsafe { (borrow(haystack, haystack_len), borrow(needle, needle_len)) };
    let Some(found) = find(&haystack, &needle, has_start.then_some(start)) else {
        return false;
    };
    let range = ByteRange {
        start: found.start as u64,
        end: found.end as u64,
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(range) };
    true
}

/// The text Lean lent for the length of a call: `len` bytes at `text`.
///
/// A Lean string is UTF-8, so this borrows. The conversion is the lossy one
/// only so that a caller that breaks that rule gets replacement characters
/// and not undefined behaviour; there is no failure to report. Each invalid
/// sequence becomes U+FFFD, which is three bytes long, so the result can be
/// longer than `len`.
///
/// # Safety
///
/// `text` points to `len` readable bytes that stay unchanged for `'a`.
pub(crate) unsafe fn borrow<'a>(text: *const u8, len: usize) -> Cow<'a, str> {
    // SAFETY: the caller guarantees the pointer, the length and the lifetime.
    String::from_utf8_lossy(unsafe { slice::from_raw_parts(text, len) })
}

/// Gives `text` up as a buffer for a result record: its pointer and its
/// length in bytes. The caller hands both back to [`editor_ffi_text_free`].
pub(crate) fn lend(text: String) -> (*mut u8, usize) {
    let bytes = text.into_bytes().into_boxed_slice();
    let len = bytes.len();
    (Box::into_raw(bytes).cast(), len)
}

/// Takes back a buffer the library handed out in a result record, and
/// frees it. It frees any such buffer, whatever it holds: every one is a
/// boxed slice of bytes, a text and a buffer of words (the private module
/// `words`) alike.
///
/// # Safety
///
/// `text` and `len` are the pointer and length of a buffer the library
/// handed out, which has not been handed back and is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_text_free(text: *mut u8, len: usize) {
    // SAFETY: the caller guarantees these are the parts of a boxed slice
    // the library gave up, taken back this once.
    drop(unsafe { Box::from_raw(ptr::slice_from_raw_parts_mut(text, len)) });
}

#[cfg(test)]
mod tests {
    use super::*;

    /// "é" and "ö" are two bytes each, so byte offsets and character counts
    /// differ from the second character on.
    const HAYSTACK: &str = "héllo wörld, hello";

    #[test]
    fn find_returns_the_byte_offsets_of_the_first_match() {
        assert_eq!(find(HAYSTACK, "llo", None), Some(3..6));
        assert_eq!(find(HAYSTACK, "wörld", None), Some(7..13));
    }

    #[test]
    fn find_starts_looking_at_the_start_offset() {
        assert_eq!(find(HAYSTACK, "llo", Some(3)), Some(3..6));
        assert_eq!(find(HAYSTACK, "llo", Some(4)), Some(17..20));
    }

    #[test]
    fn find_returns_nothing_when_there_is_no_match() {
        assert_eq!(find(HAYSTACK, "zzz", None), None);
        assert_eq!(find(HAYSTACK, "llo", Some(18)), None);
    }

    #[test]
    fn find_returns_nothing_for_a_start_past_the_end() {
        assert_eq!(find(HAYSTACK, "llo", Some(HAYSTACK.len() + 1)), None);
    }

    #[test]
    fn find_returns_nothing_for_a_start_inside_a_character() {
        assert_eq!(find(HAYSTACK, "llo", Some(2)), None);
    }
}
