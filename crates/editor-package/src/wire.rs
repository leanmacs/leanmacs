//! How a pull crosses the runtime (`editor_package_runtime`'s crate docs,
//! "How a pull crosses"): [`decode`] reads the words and bytes a runtime's
//! `child_pull` lends back into a [`Pulled`], and [`encode`] makes them, as
//! the core's runtime does, for the fake runtime.
//!
//! Both match every variant of [`Frames`] and [`Ended`] on purpose: a new
//! way to frame or to end must be given its words here, and its tag in the
//! definitions. `editor-package-check`'s `tests/wire.rs` pins both
//! directions against the core's own encoder and decoder.

use editor_package_runtime::{
    END_EXITED, END_FAILED, END_LINE_TOO_LONG, END_MESSAGE_TOO_LONG, END_NONE, END_SIGNALLED,
    FRAMING_BYTES, FRAMING_LINES, FRAMING_MESSAGES, STREAM_ERR, STREAM_OUT,
};

use crate::frame::{Frames, Stream};
use crate::stream::{Delivery, Ended, Pulled};

/// What a pull whose words cannot be read delivers as its end
/// ([`Ended::Failed`]), never a panic.
pub const UNREADABLE: &str = "the runtime's pull could not be read";

/// A pull, encoded: whether it delivered, its words and its bytes.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Encoded {
    /// Whether it delivered.
    pub delivered: bool,
    /// The words, as their little-endian bytes.
    pub words: Vec<u8>,
    /// The frames and the failed words, end to end.
    pub bytes: Vec<u8>,
}

/// Encodes `pulled` as it crosses. It matches every variant of [`Frames`]
/// and [`Ended`] on purpose: each must cross, and a new one must be given
/// its words here.
pub fn encode(pulled: Pulled) -> Encoded {
    let Pulled::Delivered(delivery) = pulled else {
        return Encoded::default();
    };
    let mut encoded = Encoded {
        delivered: true,
        ..Encoded::default()
    };
    encoded.frames(delivery.out);
    encoded.frames(delivery.err);
    let end = match delivery.ended {
        None => [END_NONE, 0, 0, 0],
        Some(Ended::Exited { code }) => [END_EXITED, i64::from(code).cast_unsigned(), 0, 0],
        Some(Ended::Signalled { signal }) => {
            [END_SIGNALLED, i64::from(signal).cast_unsigned(), 0, 0]
        }
        Some(Ended::LineTooLong { stream, bound }) => {
            [END_LINE_TOO_LONG, stream_tag(stream), bound, 0]
        }
        Some(Ended::MessageTooLong { stream, bound }) => {
            [END_MESSAGE_TOO_LONG, stream_tag(stream), bound, 0]
        }
        Some(Ended::Failed(words)) => {
            let len = words.len() as u64;
            encoded.bytes.extend_from_slice(words.as_bytes());
            [END_FAILED, 0, 0, len]
        }
    };
    for word in end {
        encoded.word(word);
    }
    encoded
}

impl Encoded {
    /// Appends `word`.
    fn word(&mut self, word: u64) {
        self.words.extend_from_slice(&word.to_le_bytes());
    }

    /// Appends one stream's framing, its frames' count and lengths, and
    /// their bytes.
    fn frames(&mut self, frames: Frames) {
        let (framing, frames) = match frames {
            Frames::Lines(lines) => (FRAMING_LINES, lines),
            Frames::Bytes(bytes) => (FRAMING_BYTES, vec![bytes]),
            Frames::Messages(bodies) => (FRAMING_MESSAGES, bodies),
        };
        self.word(framing);
        self.word(frames.len() as u64);
        for frame in frames {
            self.word(frame.len() as u64);
            self.bytes.extend_from_slice(&frame);
        }
    }
}

/// The number a stream crosses as.
const fn stream_tag(stream: Stream) -> u64 {
    match stream {
        Stream::Out => STREAM_OUT,
        Stream::Err => STREAM_ERR,
    }
}

/// The stream a number stands for, [`stream_tag`]'s inverse.
const fn stream_of(tag: u64) -> Option<Stream> {
    match tag {
        STREAM_OUT => Some(Stream::Out),
        STREAM_ERR => Some(Stream::Err),
        _ => None,
    }
}

/// Reads `encoded` back as the pull it encodes, or none when its words
/// cannot be read: a framing, an end or a stream with no tag, a count or a
/// length past what is there, a status that is no `i32`, failed words that
/// are no UTF-8, or words or bytes left over. A pull not delivered reads as
/// [`Pulled::Cancelled`] when it carries nothing.
pub fn decode(encoded: &Encoded) -> Option<Pulled> {
    if !encoded.delivered {
        let empty = encoded.words.is_empty() && encoded.bytes.is_empty();
        return empty.then_some(Pulled::Cancelled);
    }
    let mut reader = Reader {
        words: &encoded.words,
        bytes: &encoded.bytes,
    };
    let out = reader.frames()?;
    let err = reader.frames()?;
    let (tag, first, second, failed) = (
        reader.word()?,
        reader.word()?,
        reader.word()?,
        reader.length()?,
    );
    let status = || i32::try_from(first.cast_signed()).ok();
    let ended = match tag {
        END_NONE => None,
        END_EXITED => Some(Ended::Exited { code: status()? }),
        END_SIGNALLED => Some(Ended::Signalled { signal: status()? }),
        END_LINE_TOO_LONG => Some(Ended::LineTooLong {
            stream: stream_of(first)?,
            bound: second,
        }),
        END_MESSAGE_TOO_LONG => Some(Ended::MessageTooLong {
            stream: stream_of(first)?,
            bound: second,
        }),
        END_FAILED => Some(Ended::Failed(
            String::from_utf8(reader.bytes(failed)?).ok()?,
        )),
        _ => return None,
    };
    let whole = reader.words.is_empty() && reader.bytes.is_empty();
    whole.then_some(Pulled::Delivered(Delivery { out, err, ended }))
}

/// A reader of a pull's words and bytes, front to back.
struct Reader<'a> {
    /// The words left, as bytes.
    words: &'a [u8],
    /// The bytes left.
    bytes: &'a [u8],
}

impl Reader<'_> {
    /// The next word.
    fn word(&mut self) -> Option<u64> {
        let (word, rest) = self.words.split_first_chunk::<8>()?;
        self.words = rest;
        Some(u64::from_le_bytes(*word))
    }

    /// The next word, as a length.
    fn length(&mut self) -> Option<usize> {
        usize::try_from(self.word()?).ok()
    }

    /// The next `len` bytes.
    fn bytes(&mut self, len: usize) -> Option<Vec<u8>> {
        let (taken, rest) = self.bytes.split_at_checked(len)?;
        self.bytes = rest;
        Some(taken.to_vec())
    }

    /// One stream's frames: its framing, their count and lengths, then
    /// their bytes.
    fn frames(&mut self) -> Option<Frames> {
        let framing = self.word()?;
        let count = self.length()?;
        if count > self.words.len() / 8 {
            return None;
        }
        let lengths = (0..count)
            .map(|_| self.length())
            .collect::<Option<Vec<_>>>()?;
        let frames = lengths
            .into_iter()
            .map(|len| self.bytes(len))
            .collect::<Option<Vec<_>>>()?;
        match framing {
            FRAMING_LINES => Some(Frames::Lines(frames)),
            FRAMING_BYTES => Some(Frames::Bytes(frames.concat())),
            FRAMING_MESSAGES => Some(Frames::Messages(frames)),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests;
