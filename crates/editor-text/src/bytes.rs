//! Bytes: a text made from the bytes of a file, and the bytes to save.
//!
//! A text is always valid UTF-8, and a file need not be. So that a file
//! loaded and saved unchanged is the same bytes, a byte that is not part of
//! valid UTF-8 is kept in the text as one reserved character, its *escape*,
//! and written back as that one byte.
//!
//! # The mapping
//!
//! The byte `b`, which is always `0x80` or more, is the code point
//! `U+10DC00 + b`: the 128 code points `U+10DC80..=U+10DCFF`, in
//! Supplementary Private Use Area-B. The scheme is Python's
//! `surrogateescape`, which uses `U+DC80..=U+DCFF`; those are surrogates,
//! which neither a Rust `str` nor a Lean `String` can hold, so the range is
//! moved to code points a string can.
//!
//! - **In** ([`Text::from_bytes`]): a valid character is kept; each byte of
//!   an invalid sequence becomes its escape. A valid character that is
//!   itself in the reserved range is not kept as it is: each of its four
//!   bytes becomes an escape. That is what makes the mapping one-to-one.
//! - **Out** ([`Snapshot::to_bytes`], [`Snapshot::byte_chunks`]): an escape
//!   becomes its one byte, and every other character its UTF-8.
//!
//! So `Text::from_bytes(b).snapshot().to_bytes() == b` for every byte
//! string `b`. Line endings are bytes like any other: nothing is normalised
//! in either direction.
//!
//! # Why an escape, and what it costs
//!
//! An escape is ordinary text. A deletion and its undo, a cut and a paste,
//! a diff and a transaction all carry the byte with no machinery of their
//! own. A table of the original bytes beside replacement characters would
//! lose the byte the first time its character was deleted and restored,
//! since edits carry strings.
//!
//! The cost:
//!
//! - In a file with invalid bytes, an offset in the text is not an offset
//!   in the file: an escape is four bytes of text, and two UTF-16 units.
//! - Whatever reads the text sees an escape as a private-use character.
//!   Drawing it as its byte is the display's job.
//! - A file that validly holds a reserved code point shows it as four raw
//!   bytes.
//! - Text given as a string ([`Text::from`], [`Text::replace`]) is taken
//!   as it is, so a reserved code point typed or pasted into a text is
//!   saved as one raw byte. That is also how a caller writes a raw byte.

use std::borrow::Cow;

use crate::snapshot::{Chunks, Snapshot};
use crate::text::Text;

/// The code point the byte 0 would be kept as: a byte's escape is this
/// plus the byte. Only the bytes from `0x80` up are ever escaped.
const ESCAPE_BASE: u32 = 0x10_DC00;

/// The first byte of the UTF-8 of every reserved code point (they are
/// `F4 8D B2 80` to `F4 8D B3 BF`). Text without this byte holds no escape,
/// which is how the common case is told without decoding a character.
const ESCAPE_LEAD: u8 = 0xF4;

/// The character the byte `byte` is kept as.
fn escape(byte: u8) -> char {
    // Every code point from the base to 255 past it is a character, so the
    // fallback is never taken; it is there in place of a panic.
    char::from_u32(ESCAPE_BASE + u32::from(byte)).unwrap_or(char::REPLACEMENT_CHARACTER)
}

/// The byte `character` is the escape of, if it is one.
fn escaped(character: char) -> Option<u8> {
    let offset = u32::from(character).checked_sub(ESCAPE_BASE)?;
    u8::try_from(offset).ok().filter(|byte| *byte >= 0x80)
}

/// Whether `text` may hold a reserved code point. False is certain; true
/// means its characters have to be looked at.
fn may_hold_escape(text: &str) -> bool {
    text.as_bytes().contains(&ESCAPE_LEAD)
}

/// Whether `text` holds a reserved code point.
fn holds_escape(text: &str) -> bool {
    may_hold_escape(text) && text.chars().any(|character| escaped(character).is_some())
}

/// The text the bytes `bytes` are kept as. Borrowed when they are valid
/// UTF-8 that holds no reserved code point, which is nearly every file.
pub(crate) fn decode(bytes: &[u8]) -> Cow<'_, str> {
    if let Ok(text) = str::from_utf8(bytes)
        && !holds_escape(text)
    {
        return Cow::Borrowed(text);
    }
    let mut text = String::with_capacity(bytes.len());
    for chunk in bytes.utf8_chunks() {
        let valid = chunk.valid();
        if may_hold_escape(valid) {
            for character in valid.chars() {
                if escaped(character).is_some() {
                    // A reserved code point in the file is not kept as
                    // itself, or it would be saved as one byte.
                    let mut utf8 = [0; 4];
                    text.extend(character.encode_utf8(&mut utf8).bytes().map(escape));
                } else {
                    text.push(character);
                }
            }
        } else {
            text.push_str(valid);
        }
        text.extend(chunk.invalid().iter().copied().map(escape));
    }
    Cow::Owned(text)
}

/// The bytes the piece of text `text` is saved as. Borrowed when it holds
/// no escape.
pub(crate) fn encode(text: &str) -> Cow<'_, [u8]> {
    if !holds_escape(text) {
        return Cow::Borrowed(text.as_bytes());
    }
    let mut bytes = Vec::with_capacity(text.len());
    for character in text.chars() {
        match escaped(character) {
            Some(byte) => bytes.push(byte),
            None => bytes.extend_from_slice(character.encode_utf8(&mut [0; 4]).as_bytes()),
        }
    }
    Cow::Owned(bytes)
}

impl Text {
    /// A text made from the bytes of a file, which need not be UTF-8. Each
    /// byte that is not part of valid UTF-8 is kept as one reserved
    /// character, so that [`Snapshot::to_bytes`] gives the same bytes back.
    /// Line endings are kept as they are.
    pub fn from_bytes(bytes: &[u8]) -> Self {
        Self::from(&*decode(bytes))
    }
}

impl Snapshot {
    /// The bytes to save the text as: each character a raw byte is kept as
    /// becomes that byte, and every other character its UTF-8. For a text
    /// made by [`Text::from_bytes`] and not edited, these are the bytes it
    /// was made from.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(self.len());
        for chunk in self.byte_chunks() {
            bytes.extend_from_slice(&chunk);
        }
        bytes
    }

    /// [`to_bytes`](Self::to_bytes) in pieces, in order, for a writer that
    /// wants no copy of the whole text. A piece is borrowed from the text
    /// unless it holds a character a raw byte is kept as.
    pub fn byte_chunks(&self) -> ByteChunks<'_> {
        ByteChunks(self.chunks())
    }
}

/// The bytes to save a snapshot's text as, in pieces
/// ([`Snapshot::byte_chunks`]).
pub struct ByteChunks<'a>(Chunks<'a>);

impl<'a> Iterator for ByteChunks<'a> {
    type Item = Cow<'a, [u8]>;

    fn next(&mut self) -> Option<Cow<'a, [u8]>> {
        self.0.next().map(encode)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Byte strings that are not UTF-8, or that hold what the mapping must
    /// not confuse with an escape, each with what it shows.
    const CASES: &[(&str, &[u8])] = &[
        ("Latin-1 text", b"caf\xE9 na\xEFve"),
        ("two bytes that are never valid", b"\xFF\xFE"),
        ("a sequence cut short at the end", b"abc\xE2\x82"),
        ("a sequence cut short in the middle", b"a\xF0\x9F\x98b"),
        ("an overlong form", b"\xC0\xAF"),
        ("an encoded surrogate", b"\xED\xA0\x80"),
        ("a continuation byte alone", b"a\x80b"),
        (
            "the lowest reserved code point, validly encoded",
            "a\u{10DC80}b".as_bytes(),
        ),
        (
            "the highest reserved code point, validly encoded",
            "\u{10DCFF}".as_bytes(),
        ),
        (
            "the code points either side of the reserved range",
            "\u{10DC7F}\u{10DD00}".as_bytes(),
        ),
        (
            "line endings of each kind around invalid bytes",
            b"a\r\n\xFFb\n\xFE\rc\r\n",
        ),
        ("embedded NULs", b"a\0\xFF\0b"),
        ("valid text", "h\u{e9}llo \u{1F600}\r\n".as_bytes()),
        ("nothing", b""),
    ];

    /// What a text made from `bytes` saves as.
    fn round_trip(bytes: &[u8]) -> Vec<u8> {
        Text::from_bytes(bytes).snapshot().to_bytes()
    }

    /// What a text made from `bytes` holds.
    fn loaded(bytes: &[u8]) -> String {
        Text::from_bytes(bytes).snapshot().to_string()
    }

    #[test]
    fn bytes_that_are_not_utf8_come_back_as_they_went_in() {
        for (what, bytes) in CASES {
            assert_eq!(round_trip(bytes), *bytes, "{what}");
        }
    }

    #[test]
    fn valid_utf8_with_no_reserved_code_point_is_taken_as_it_is() {
        let text = "héllo wörld 😀\r\na\0b\n\u{10DC7F}\u{10DD00}\u{FFFD}";

        assert_eq!(loaded(text.as_bytes()), text);
        assert!(matches!(decode(text.as_bytes()), Cow::Borrowed(_)));
    }

    #[test]
    fn each_invalid_byte_is_kept_as_one_character() {
        assert_eq!(loaded(b"a\xFF\xFEb"), "a\u{10DCFF}\u{10DCFE}b");
        assert_eq!(loaded(b"\x80"), "\u{10DC80}");
        // A sequence cut short: each of its bytes, not one character for
        // the whole of it.
        assert_eq!(loaded(b"abc\xE2\x82"), "abc\u{10DCE2}\u{10DC82}");
        assert_eq!(loaded(b"caf\xE9").chars().count(), 4);
    }

    #[test]
    fn a_reserved_code_point_in_the_bytes_is_kept_as_its_four_bytes() {
        // U+10DC80 is F4 8D B2 80 in UTF-8.
        assert_eq!(
            loaded("\u{10DC80}".as_bytes()),
            "\u{10DCF4}\u{10DC8D}\u{10DCB2}\u{10DC80}"
        );
        assert_eq!(loaded("a\u{10DCFF}b".as_bytes()).chars().count(), 6);
    }

    #[test]
    fn line_endings_are_kept_as_they_are() {
        let bytes = b"one\r\ntwo\nthree\rfour\n\r\n";

        assert_eq!(loaded(bytes), "one\r\ntwo\nthree\rfour\n\r\n");
        assert_eq!(round_trip(bytes), bytes);
    }

    #[test]
    fn a_reserved_code_point_given_as_a_string_is_saved_as_one_raw_byte() {
        let mut text = Text::from("a\u{10DCFF}");
        text.replace(0..0, "\u{10DC80}")
            .expect("an insert at the start");

        assert_eq!(text.snapshot().to_bytes(), b"\x80a\xFF");
    }

    #[test]
    fn an_edit_beside_an_invalid_byte_leaves_the_byte_as_it_was() {
        let mut text = Text::from_bytes(b"a\xFFb\r\n");

        // After the escape, which is four bytes of text.
        text.replace(5..5, "é").expect("an insert after the escape");

        assert_eq!(text.snapshot().to_bytes(), b"a\xFF\xC3\xA9b\r\n");
    }

    #[test]
    fn the_byte_chunks_of_a_snapshot_joined_are_its_bytes() {
        let mut bytes = Vec::new();
        for line in 0..2_000 {
            bytes.extend_from_slice(
                b"a line of Latin-1 text, caf\xE9, and some UTF-8, h\xC3\xA9llo\r\n",
            );
            if line % 7 == 0 {
                bytes.extend_from_slice(b"\xFF\xFE\n");
            }
        }
        let snapshot = Text::from_bytes(&bytes).snapshot();

        assert!(snapshot.byte_chunks().count() > 16);
        assert_eq!(snapshot.byte_chunks().collect::<Vec<_>>().concat(), bytes);
        assert_eq!(snapshot.to_bytes(), bytes);
    }

    #[test]
    fn a_byte_chunk_with_no_escape_in_it_is_borrowed_from_the_text() {
        let plain = Text::from("héllo 😀").snapshot();
        let escaped = Text::from_bytes(b"h\xFF").snapshot();

        assert!(
            plain
                .byte_chunks()
                .all(|chunk| matches!(chunk, Cow::Borrowed(_)))
        );
        assert!(
            escaped
                .byte_chunks()
                .all(|chunk| matches!(chunk, Cow::Owned(_)))
        );
    }

    #[test]
    fn a_long_text_with_no_escape_saves_as_its_utf8() {
        let string = "héllo wörld 😀\r\n".repeat(3_000);

        assert_eq!(round_trip(string.as_bytes()), string.as_bytes());
    }
}
