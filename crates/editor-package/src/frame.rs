//! A taken-over child's output, framed, as plain data: the frames a pull
//! delivers, the same names, variants and fields as `editor-service`'s
//! `frame` module, so a crate's logic written over one ports to the other
//! by its imports.
//!
//! There is no framer here: framing is the core's process service's rule
//! (lines, bytes and `Content-Length` messages, and the bound), applied
//! before a pull crosses the runtime. A package's library is handed frames
//! already made.

/// One of a child's output streams.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Stream {
    /// Its standard output.
    Out,
    /// Its standard error.
    Err,
}

/// How a stream reaches its consumer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Framing {
    /// As lines, split on `\n`.
    Lines,
    /// As raw bytes, with arbitrary boundaries.
    Bytes,
    /// As messages, each a `Content-Length` header and that many bytes of
    /// body.
    ContentLength,
}

/// What a pull gives of one stream.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Frames {
    /// Whole lines, each without its `\n`.
    Lines(Vec<Vec<u8>>),
    /// Bytes.
    Bytes(Vec<u8>),
    /// Whole messages' bodies, each without its header.
    Messages(Vec<Vec<u8>>),
}

impl Frames {
    /// No frames of `framing`.
    pub const fn none(framing: Framing) -> Self {
        match framing {
            Framing::Lines => Self::Lines(Vec::new()),
            Framing::Bytes => Self::Bytes(Vec::new()),
            Framing::ContentLength => Self::Messages(Vec::new()),
        }
    }

    /// Whether there is nothing in it.
    pub fn is_empty(&self) -> bool {
        match self {
            Self::Lines(lines) => lines.is_empty(),
            Self::Bytes(bytes) => bytes.is_empty(),
            Self::Messages(bodies) => bodies.is_empty(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_frames_of_each_framing_are_empty_and_some_are_not() {
        for framing in [Framing::Lines, Framing::Bytes, Framing::ContentLength] {
            assert!(Frames::none(framing).is_empty(), "{framing:?}");
        }
        assert_eq!(Frames::none(Framing::Bytes), Frames::Bytes(Vec::new()));
        assert_eq!(
            Frames::none(Framing::ContentLength),
            Frames::Messages(Vec::new())
        );
        assert!(
            !Frames::Lines(vec![Vec::new()]).is_empty(),
            "one empty line"
        );
        assert!(!Frames::Bytes(b"x".to_vec()).is_empty());
        assert!(!Frames::Messages(vec![Vec::new()]).is_empty());
    }
}
