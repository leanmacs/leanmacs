//! A streaming child's output as a job receives it: framed, by line or as
//! raw bytes, and bounded. Plain data, with no thread and no port.
//!
//! [`Framer`] frames one stream. Under [`Framing::Lines`] it splits on
//! `\n`: a line excludes its `\n` and keeps a `\r` before it, and at the
//! stream's end any bytes after the last `\n` are a last line. Under
//! [`Framing::Bytes`] a take is every byte pushed and not yet taken, with
//! no boundary kept, so the takes end to end are the stream byte for byte.
//!
//! [`Outbox`] holds a child's two framers and its *bound*: how many bytes
//! of each stream may have been read from the child and not yet taken by
//! its job, a line still in progress among them. Its reader asks for at
//! most [`Outbox::room`] bytes, so a stream never holds more than the
//! bound; at a room of 0 the reader stops reading, which is what holds
//! the child. A partial line that alone fills the bound can never be
//! delivered whole unless the stream ends there: [`Outbox::too_long`] says
//! so, and the service ends the child with it once one more byte of the
//! stream shows the line goes on.

use crate::Stream;

/// How a stream reaches its job.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Framing {
    /// As lines, split on `\n`.
    Lines,
    /// As raw bytes, with arbitrary boundaries.
    Bytes,
}

/// What a take of one stream gives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Frames {
    /// Whole lines, each without its `\n`.
    Lines(Vec<Vec<u8>>),
    /// Bytes.
    Bytes(Vec<u8>),
}

impl Frames {
    /// No frames of `framing`.
    pub const fn none(framing: Framing) -> Self {
        match framing {
            Framing::Lines => Self::Lines(Vec::new()),
            Framing::Bytes => Self::Bytes(Vec::new()),
        }
    }

    /// Whether there is nothing in it.
    pub fn is_empty(&self) -> bool {
        match self {
            Self::Lines(lines) => lines.is_empty(),
            Self::Bytes(bytes) => bytes.is_empty(),
        }
    }
}

/// One stream's framing: the bytes pushed and not yet taken.
#[derive(Debug, Clone)]
pub struct Framer {
    /// How it frames.
    framing: Framing,
    /// The bytes pushed and not yet taken.
    held: Vec<u8>,
    /// How many of `held` are complete lines: the length up to and
    /// including the last `\n`.
    complete: usize,
    /// Whether the stream has ended.
    ended: bool,
}

impl Framer {
    /// A framer of `framing` with nothing in it.
    pub const fn new(framing: Framing) -> Self {
        Self {
            framing,
            held: Vec::new(),
            complete: 0,
            ended: false,
        }
    }

    /// Appends `bytes`.
    pub fn push(&mut self, bytes: &[u8]) {
        let start = self.held.len();
        self.held.extend_from_slice(bytes);
        if let Some(last) = bytes.iter().rposition(|&byte| byte == b'\n') {
            self.complete = start + last + 1;
        }
    }

    /// Says the stream has ended: the bytes after the last `\n` are then a
    /// last line.
    pub fn end(&mut self) {
        self.ended = true;
    }

    /// Whether the stream has ended.
    pub const fn ended(&self) -> bool {
        self.ended
    }

    /// Takes every complete frame: the complete lines, keeping the partial
    /// one, or every byte. Once the stream has ended, the partial line is
    /// a last line.
    pub fn take(&mut self) -> Frames {
        match self.framing {
            Framing::Bytes => {
                self.complete = 0;
                Frames::Bytes(std::mem::take(&mut self.held))
            }
            Framing::Lines => {
                let rest = self.held.split_off(self.complete);
                let whole = std::mem::replace(&mut self.held, rest);
                self.complete = 0;
                let mut lines: Vec<Vec<u8>> = whole
                    .split(|&byte| byte == b'\n')
                    .map(<[u8]>::to_vec)
                    .collect();
                // The bytes after the last `\n` of the complete part: none.
                lines.pop();
                if self.ended && !self.held.is_empty() {
                    lines.push(std::mem::take(&mut self.held));
                }
                Frames::Lines(lines)
            }
        }
    }

    /// Says the stream has ended and takes what is left.
    pub fn finish(&mut self) -> Frames {
        self.end();
        self.take()
    }

    /// The bytes it holds: its share of the bound.
    pub const fn held_bytes(&self) -> usize {
        self.held.len()
    }

    /// The bytes of the line in progress: none under bytes framing.
    pub fn partial_len(&self) -> usize {
        match self.framing {
            Framing::Bytes => 0,
            Framing::Lines => self.held.len() - self.complete,
        }
    }

    /// Whether a take would give anything.
    pub fn has_frame(&self) -> bool {
        match self.framing {
            Framing::Bytes => !self.held.is_empty(),
            Framing::Lines => self.complete > 0 || (self.ended && !self.held.is_empty()),
        }
    }
}

/// A child's two framers and its bound.
#[derive(Debug, Clone)]
pub struct Outbox {
    /// Its standard output's framer, then its standard error's.
    streams: [Framer; 2],
    /// How many bytes of each stream may be held.
    bound: u64,
}

/// The slot of `stream` in an outbox.
const fn slot(stream: Stream) -> usize {
    match stream {
        Stream::Out => 0,
        Stream::Err => 1,
    }
}

impl Outbox {
    /// An outbox that frames standard output as `out` and standard error
    /// as `err`, each holding up to `bound` bytes.
    pub const fn new(out: Framing, err: Framing, bound: u64) -> Self {
        Self {
            streams: [Framer::new(out), Framer::new(err)],
            bound,
        }
    }

    /// The bound.
    pub const fn bound(&self) -> u64 {
        self.bound
    }

    /// How many more bytes of `stream` may be read: the bound less what it
    /// holds, never below 0.
    pub fn room(&self, stream: Stream) -> u64 {
        self.bound.saturating_sub(self.held_bytes(stream) as u64)
    }

    /// Appends `bytes` to `stream`.
    pub fn push(&mut self, stream: Stream, bytes: &[u8]) {
        self.streams[slot(stream)].push(bytes);
    }

    /// Says `stream` has ended.
    pub fn end(&mut self, stream: Stream) {
        self.streams[slot(stream)].end();
    }

    /// Whether both streams have ended.
    pub fn ended(&self) -> bool {
        self.streams.iter().all(Framer::ended)
    }

    /// The bytes `stream` holds.
    pub const fn held_bytes(&self, stream: Stream) -> usize {
        self.streams[slot(stream)].held_bytes()
    }

    /// Whether a drain would give anything.
    pub fn deliverable(&self) -> bool {
        self.streams.iter().any(Framer::has_frame)
    }

    /// Takes every complete frame of both streams, out then err.
    pub fn drain(&mut self) -> (Frames, Frames) {
        let [out, err] = &mut self.streams;
        (out.take(), err.take())
    }

    /// Whether `stream` holds a partial line that alone fills the bound,
    /// so it can never be delivered whole unless the stream ends here.
    /// Never under bytes framing.
    pub fn too_long(&self, stream: Stream) -> bool {
        let framer = &self.streams[slot(stream)];
        self.room(stream) == 0 && framer.framing == Framing::Lines && !framer.has_frame()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(lines: &[&[u8]]) -> Frames {
        Frames::Lines(lines.iter().map(|line| line.to_vec()).collect())
    }

    #[test]
    fn lines_split_across_chunks_are_whole_and_the_partial_one_is_kept() {
        let mut framer = Framer::new(Framing::Lines);
        framer.push(b"on");
        assert_eq!(framer.take(), lines(&[]));
        framer.push(b"e\ntw");
        assert_eq!(framer.take(), lines(&[b"one"]));
        assert_eq!(framer.partial_len(), 2);
        framer.push(b"o");
        framer.push(b"\n");
        assert_eq!(framer.take(), lines(&[b"two"]));
        assert_eq!(framer.held_bytes(), 0);
    }

    #[test]
    fn a_chunk_that_is_only_a_line_feed_ends_the_line_and_empty_lines_are_lines() {
        let mut framer = Framer::new(Framing::Lines);
        framer.push(b"a");
        framer.push(b"\n");
        framer.push(b"\n\n");
        assert_eq!(framer.take(), lines(&[b"a", b"", b""]));
    }

    #[test]
    fn a_carriage_return_before_the_line_feed_is_kept() {
        let mut framer = Framer::new(Framing::Lines);
        framer.push(b"a\r\nb\r");
        assert_eq!(framer.take(), lines(&[b"a\r"]));
        assert_eq!(framer.finish(), lines(&[b"b\r"]));
    }

    #[test]
    fn an_unterminated_last_line_is_given_at_the_end_and_nothing_after_a_final_line_feed() {
        let mut framer = Framer::new(Framing::Lines);
        framer.push(b"x\ny");
        assert!(!framer.ended());
        assert_eq!(framer.finish(), lines(&[b"x", b"y"]));
        assert!(framer.ended());

        let mut framer = Framer::new(Framing::Lines);
        framer.push(b"x\n");
        assert_eq!(framer.finish(), lines(&[b"x"]));
        assert!(!framer.has_frame());
    }

    #[test]
    fn bytes_concatenate_exactly_a_byte_that_is_not_utf_8_among_them() {
        let mut framer = Framer::new(Framing::Bytes);
        framer.push(b"a\xff");
        assert_eq!(framer.partial_len(), 0);
        assert!(framer.has_frame());
        let first = framer.take();
        framer.push(b"\nb");
        let second = framer.finish();

        let mut all = Vec::new();
        for frames in [first, second] {
            let Frames::Bytes(bytes) = frames else {
                panic!("bytes");
            };
            all.extend(bytes);
        }
        assert_eq!(all, b"a\xff\nb");
        assert_eq!(framer.take(), Frames::Bytes(Vec::new()));
    }

    #[test]
    fn the_room_of_each_stream_is_the_bound_less_what_it_holds_and_never_below_zero() {
        let mut outbox = Outbox::new(Framing::Lines, Framing::Bytes, 4);
        assert_eq!(outbox.room(Stream::Out), 4);
        outbox.push(Stream::Out, b"ab\n");
        assert_eq!(outbox.room(Stream::Out), 1);
        assert_eq!(outbox.room(Stream::Err), 4, "each stream has its own");
        outbox.push(Stream::Out, b"cd");
        assert_eq!(outbox.room(Stream::Out), 0, "never below zero");
    }

    #[test]
    fn after_a_drain_the_room_is_the_bound_less_the_partial_line() {
        let mut outbox = Outbox::new(Framing::Lines, Framing::Lines, 10);
        outbox.push(Stream::Out, b"one\ntw");
        outbox.push(Stream::Err, b"e\n");
        assert!(outbox.deliverable());

        assert_eq!(outbox.drain(), (lines(&[b"one"]), lines(&[b"e"])));
        assert_eq!(outbox.room(Stream::Out), 8);
        assert_eq!(outbox.room(Stream::Err), 10);
        assert!(!outbox.deliverable());
    }

    #[test]
    fn a_stream_that_ended_with_a_remainder_is_deliverable_and_both_ended_is_ended() {
        let mut outbox = Outbox::new(Framing::Lines, Framing::Lines, 10);
        outbox.push(Stream::Out, b"x");
        assert!(!outbox.deliverable());
        outbox.end(Stream::Out);
        assert!(outbox.deliverable());
        assert!(!outbox.ended());
        outbox.end(Stream::Err);
        assert!(outbox.ended());
        assert_eq!(outbox.drain(), (lines(&[b"x"]), lines(&[])));
    }

    #[test]
    fn too_long_is_only_a_partial_line_that_fills_the_bound_under_lines() {
        let mut outbox = Outbox::new(Framing::Lines, Framing::Bytes, 3);
        outbox.push(Stream::Out, b"ab");
        assert!(!outbox.too_long(Stream::Out), "room is left");
        outbox.push(Stream::Out, b"c");
        assert!(outbox.too_long(Stream::Out));

        let mut whole = Outbox::new(Framing::Lines, Framing::Bytes, 3);
        whole.push(Stream::Out, b"ab\n");
        assert!(!whole.too_long(Stream::Out), "a whole line fills it");

        outbox.push(Stream::Err, b"abc");
        assert!(!outbox.too_long(Stream::Err), "never under bytes framing");
    }
}
