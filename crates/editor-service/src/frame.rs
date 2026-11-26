//! A streaming child's output as a job receives it: framed, by line, as
//! raw bytes or as `Content-Length` messages, and bounded. Plain data, with
//! no thread and no port.
//!
//! [`Framer`] frames one stream. Under [`Framing::Lines`] it splits on
//! `\n`: a line excludes its `\n` and keeps a `\r` before it, and at the
//! stream's end any bytes after the last `\n` are a last line. Under
//! [`Framing::Bytes`] a take is every byte pushed and not yet taken, with
//! no boundary kept, so the takes end to end are the stream byte for byte.
//!
//! Under [`Framing::ContentLength`] the stream is messages, as a language
//! server's JSON-RPC is framed, and a take gives each whole message's body
//! without its header ([`Frames::Messages`]). A message is a header, then
//! its body:
//!
//! - **The header** is ASCII lines, each ending in `\r\n`, up to an empty
//!   line. `Content-Length: <decimal>` is required, once; its name is
//!   matched without regard to case. `Content-Type` is allowed and
//!   ignored. Any other header, a length given twice or not at all, one
//!   that is not a decimal number a length holds, a line that ends in a
//!   bare `\n`, a line with no colon and a byte that is not ASCII each
//!   break a rule ([`Fault::Malformed`], which says what in words).
//! - **The body** is exactly the length's bytes, never looked at.
//!
//! The framer keeps a parse cursor, so a push parses only what it adds: a
//! stream pushed a byte at a time is parsed once. A stream that ends inside
//! a header or a body is malformed too: a message is never delivered cut
//! short.
//!
//! [`Outbox`] holds a child's two framers and its *bound*: how many bytes
//! of each stream may have been read from the child and not yet taken by
//! its job, a line or a message still in progress among them, and the
//! headers of whole messages not yet taken. Its reader asks for at most
//! [`Outbox::room`] bytes, so a stream never holds more than the bound; at
//! a room of 0 the reader stops reading, which is what holds the child.
//! [`Outbox::fault`] says when a stream can be framed no further
//! ([`Fault`]): a partial line that alone fills the bound can never be
//! delivered whole unless the stream ends there, and the service ends the
//! child with it once one more byte of the stream shows the line goes on;
//! a message's size is known once its length is parsed, so one longer
//! than the bound, its header counted, is too long at once, with no probe
//! and before any byte of its body is pushed, and so is a header with no
//! end that fills the bound; and a malformed message ends the stream.
//!
//! It lives here, in the service conventions, rather than in
//! `editor-process`, so that a package's crate that takes a streaming
//! child over is handed the same frames the process service makes, one
//! type on both sides. It is plain data, with no thread and no port: what
//! it adds to every package crate's reach is a value and its rules,
//! nothing that runs. `editor-process` re-exports it
//! (`editor_process::frame`, `editor_process::Stream`).

/// One of a child's output streams.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Stream {
    /// Its standard output.
    Out,
    /// Its standard error.
    Err,
}

/// How a stream reaches its job.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Framing {
    /// As lines, split on `\n`.
    Lines,
    /// As raw bytes, with arbitrary boundaries.
    Bytes,
    /// As messages, each a `Content-Length` header and that many bytes of
    /// body, as JSON-RPC over a language server's streams is framed.
    ContentLength,
}

/// What a take of one stream gives.
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

/// Why a stream can be framed no further: the service ends its child.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Fault {
    /// Under lines framing, a partial line fills the bound: it is too long
    /// if one more byte of the stream comes, and the stream's last line if
    /// the stream ends there. The service looks one byte further to know.
    LineFillsBound,
    /// Under `Content-Length` framing, the message in progress is longer
    /// than the bound, its header counted: known once its length is
    /// parsed, or once a header with no end fills the bound. No probe is
    /// needed: a message is never a valid last frame unless it is whole.
    MessageTooLong,
    /// Under `Content-Length` framing, a header that breaks a rule, or a
    /// stream that ended inside a message; what is wrong, in words.
    Malformed(String),
}

/// One stream's framing: the bytes pushed and not yet taken.
#[derive(Debug, Clone)]
pub struct Framer {
    /// How it frames.
    framing: Framing,
    /// The bytes pushed and not yet taken.
    held: Vec<u8>,
    /// How many of `held` are complete frames: under lines, the length up
    /// to and including the last `\n`; under `Content-Length`, up to the
    /// end of the last whole message.
    complete: usize,
    /// Whether the stream has ended.
    ended: bool,
    /// Where `Content-Length` parsing is: unused under the other framings.
    message: Parse,
}

/// Where a `Content-Length` framer's parse is, as offsets into what it
/// holds. A push parses from `cursor` on and never again before it, so a
/// stream pushed a byte at a time is parsed once.
#[derive(Debug, Clone, Default)]
struct Parse {
    /// The body of each whole message held and not yet taken, as a range
    /// of what is held.
    bodies: Vec<(usize, usize)>,
    /// Where the message in progress starts.
    start: usize,
    /// How far what is held has been parsed.
    cursor: usize,
    /// Where the header line in progress starts.
    line: usize,
    /// The length the message's header gave, once it has.
    length: Option<usize>,
    /// Where the message's body starts, once its header has ended.
    body: Option<usize>,
    /// What broke a rule, once something has: nothing is parsed after it.
    malformed: Option<String>,
    /// How many bytes of a header have been looked at, for the test that
    /// a stream is parsed once.
    #[cfg(test)]
    scanned: usize,
}

impl Parse {
    /// Parses `held` from the cursor on, and gives the end of the last
    /// whole message, if it parsed one.
    fn parse(&mut self, held: &[u8]) -> Option<usize> {
        let mut complete = None;
        while self.malformed.is_none() {
            if let Some(body) = self.body {
                let Some(end) = body.checked_add(self.length.unwrap_or(0)) else {
                    self.malformed = Some("a message's Content-Length runs past memory".into());
                    break;
                };
                if held.len() < end {
                    // The body is not looked at: it is a count.
                    self.cursor = held.len();
                    break;
                }
                self.bodies.push((body, end));
                complete = Some(end);
                *self = Self {
                    bodies: std::mem::take(&mut self.bodies),
                    start: end,
                    cursor: end,
                    line: end,
                    #[cfg(test)]
                    scanned: self.scanned,
                    ..Self::default()
                };
                continue;
            }
            let rest = &held[self.cursor..];
            let Some(offset) = rest
                .iter()
                .position(|&byte| byte == b'\n' || !byte.is_ascii())
            else {
                #[cfg(test)]
                {
                    self.scanned += rest.len();
                }
                self.cursor = held.len();
                break;
            };
            #[cfg(test)]
            {
                self.scanned += offset + 1;
            }
            let at = self.cursor + offset;
            self.cursor = at + 1;
            if held[at] != b'\n' {
                self.malformed = Some("a message's header holds a byte that is not ASCII".into());
                break;
            }
            let Some(line) = held[self.line..at].strip_suffix(b"\r") else {
                self.malformed = Some("a message's header line ends in a bare line feed".into());
                break;
            };
            self.line = at + 1;
            if line.is_empty() {
                if self.length.is_none() {
                    self.malformed = Some("a message's header has no Content-Length".into());
                    break;
                }
                self.body = Some(at + 1);
                continue;
            }
            if let Err(words) = header(line, &mut self.length) {
                self.malformed = Some(words);
            }
        }
        complete
    }

    /// Moves every offset back by `taken`, the bytes taken from the front
    /// of what is held.
    fn shift(&mut self, taken: usize) {
        self.bodies.clear();
        self.start -= taken;
        self.cursor -= taken;
        self.line -= taken;
        if let Some(body) = &mut self.body {
            *body -= taken;
        }
    }

    /// The least the message in progress can be, its header counted, when
    /// `held` bytes are held: `None` with none in progress. A header not
    /// yet ended needs one byte more at least, and one whose length is
    /// known its end's two bytes and its body.
    fn least(&self, held: usize) -> Option<usize> {
        if let (Some(body), Some(length)) = (self.body, self.length) {
            return Some((body - self.start).saturating_add(length));
        }
        let in_progress = held - self.start;
        let known = self.length.map_or(0, |length| {
            (self.cursor - self.start + 2).saturating_add(length)
        });
        (in_progress > 0 || self.length.is_some()).then_some(known.max(in_progress + 1))
    }
}

/// Reads one header line, `line` without its `\r\n`, into `length`: a
/// `Content-Length` sets it, once; a `Content-Type` is ignored; anything
/// else breaks a rule, and the words say what.
fn header(line: &[u8], length: &mut Option<usize>) -> Result<(), String> {
    let text = String::from_utf8_lossy(line);
    let Some((name, value)) = text.split_once(':') else {
        return Err(format!("a message's header line has no colon: {text:?}"));
    };
    if name.eq_ignore_ascii_case("Content-Type") {
        return Ok(());
    }
    if !name.eq_ignore_ascii_case("Content-Length") {
        return Err(format!(
            "a message's header names `{name}`, which is neither Content-Length nor Content-Type"
        ));
    }
    if length.is_some() {
        return Err("a message's header gives its Content-Length twice".into());
    }
    let value = value.trim_matches([' ', '\t']);
    let parsed = (!value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit()))
        .then(|| value.parse::<usize>().ok())
        .flatten();
    let Some(parsed) = parsed else {
        return Err(format!(
            "a message's Content-Length is not a decimal number a length holds: {value:?}"
        ));
    };
    *length = Some(parsed);
    Ok(())
}

impl Framer {
    /// A framer of `framing` with nothing in it.
    pub const fn new(framing: Framing) -> Self {
        Self {
            framing,
            held: Vec::new(),
            complete: 0,
            ended: false,
            message: Parse {
                bodies: Vec::new(),
                start: 0,
                cursor: 0,
                line: 0,
                length: None,
                body: None,
                malformed: None,
                #[cfg(test)]
                scanned: 0,
            },
        }
    }

    /// Appends `bytes`.
    pub fn push(&mut self, bytes: &[u8]) {
        let start = self.held.len();
        self.held.extend_from_slice(bytes);
        match self.framing {
            Framing::Bytes => {}
            Framing::Lines => {
                if let Some(last) = bytes.iter().rposition(|&byte| byte == b'\n') {
                    self.complete = start + last + 1;
                }
            }
            Framing::ContentLength => {
                if let Some(end) = self.message.parse(&self.held) {
                    self.complete = end;
                }
            }
        }
    }

    /// Says the stream has ended: the bytes after the last `\n` are then a
    /// last line; and a message in progress was cut short, which is
    /// malformed.
    pub fn end(&mut self) {
        self.ended = true;
        if self.framing == Framing::ContentLength
            && self.held.len() > self.complete
            && self.message.malformed.is_none()
        {
            self.message.malformed = Some("the stream ended inside a message".into());
        }
    }

    /// Whether the stream has ended.
    pub const fn ended(&self) -> bool {
        self.ended
    }

    /// Takes every complete frame: the complete lines, keeping the partial
    /// one, or every byte, or the whole messages, keeping the one in
    /// progress. Once the stream has ended, the partial line is a last
    /// line.
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
            Framing::ContentLength => {
                let rest = self.held.split_off(self.complete);
                let whole = std::mem::replace(&mut self.held, rest);
                let bodies = self
                    .message
                    .bodies
                    .iter()
                    .map(|&(start, end)| whole[start..end].to_vec())
                    .collect();
                self.message.shift(self.complete);
                self.complete = 0;
                Frames::Messages(bodies)
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

    /// The bytes of the line or the message in progress: none under bytes
    /// framing.
    pub const fn partial_len(&self) -> usize {
        match self.framing {
            Framing::Bytes => 0,
            Framing::Lines | Framing::ContentLength => self.held.len() - self.complete,
        }
    }

    /// Whether a take would give anything.
    pub fn has_frame(&self) -> bool {
        match self.framing {
            Framing::Bytes => !self.held.is_empty(),
            Framing::Lines => self.complete > 0 || (self.ended && !self.held.is_empty()),
            Framing::ContentLength => self.complete > 0,
        }
    }

    /// What broke a rule of `Content-Length` framing, in words: a header
    /// that breaks one, or the stream's end inside a message. `None` under
    /// the other framings.
    pub fn fault(&self) -> Option<&str> {
        self.message.malformed.as_deref()
    }

    /// How many bytes of a header the parse has looked at so far.
    #[cfg(test)]
    const fn scanned(&self) -> usize {
        self.message.scanned
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

    /// Why `stream` can be framed no further, if it cannot ([`Fault`]): a
    /// partial line that alone fills the bound under lines framing; and
    /// under `Content-Length`, a header that breaks a rule, or a message
    /// longer than the bound, its header counted. Never under bytes
    /// framing.
    pub fn fault(&self, stream: Stream) -> Option<Fault> {
        let framer = &self.streams[slot(stream)];
        match framer.framing {
            Framing::Bytes => None,
            Framing::Lines => {
                (self.room(stream) == 0 && !framer.has_frame()).then_some(Fault::LineFillsBound)
            }
            Framing::ContentLength => {
                if let Some(words) = framer.fault() {
                    return Some(Fault::Malformed(words.to_owned()));
                }
                let least = framer.message.least(framer.held_bytes())?;
                (least as u64 > self.bound).then_some(Fault::MessageTooLong)
            }
        }
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
    fn a_line_fills_the_bound_only_as_a_partial_line_that_fills_it_under_lines() {
        let mut outbox = Outbox::new(Framing::Lines, Framing::Bytes, 3);
        outbox.push(Stream::Out, b"ab");
        assert_eq!(outbox.fault(Stream::Out), None, "room is left");
        outbox.push(Stream::Out, b"c");
        assert_eq!(outbox.fault(Stream::Out), Some(Fault::LineFillsBound));

        let mut whole = Outbox::new(Framing::Lines, Framing::Bytes, 3);
        whole.push(Stream::Out, b"ab\n");
        assert_eq!(whole.fault(Stream::Out), None, "a whole line fills it");

        outbox.push(Stream::Err, b"abc");
        assert_eq!(outbox.fault(Stream::Err), None, "never under bytes framing");
    }

    /// `body` framed as a message: its `Content-Length` header and the body.
    fn message(body: &[u8]) -> Vec<u8> {
        let mut framed = format!("Content-Length: {}\r\n\r\n", body.len()).into_bytes();
        framed.extend_from_slice(body);
        framed
    }

    fn messages(bodies: &[&[u8]]) -> Frames {
        Frames::Messages(bodies.iter().map(|body| body.to_vec()).collect())
    }

    #[test]
    fn no_messages_is_the_empty_frames_of_content_length() {
        let none = Frames::none(Framing::ContentLength);
        assert_eq!(none, messages(&[]));
        assert!(none.is_empty());
        assert!(!messages(&[b""]).is_empty(), "an empty body is a message");
    }

    #[test]
    fn whole_messages_are_delivered_however_the_stream_is_split_several_in_one_push() {
        let mut stream = message(b"{\"one\":1}");
        stream.extend(message(b"two"));
        stream.extend(message(b"three"));
        for split in 1..stream.len() {
            let mut framer = Framer::new(Framing::ContentLength);
            framer.push(&stream[..split]);
            let mut got = Vec::new();
            if let Frames::Messages(first) = framer.take() {
                got.extend(first);
            }
            framer.push(&stream[split..]);
            let Frames::Messages(rest) = framer.take() else {
                panic!("messages");
            };
            got.extend(rest);
            assert_eq!(
                got,
                [b"{\"one\":1}".to_vec(), b"two".to_vec(), b"three".to_vec()],
                "split at {split}"
            );
            assert_eq!(framer.held_bytes(), 0);
            assert_eq!(framer.fault(), None);
        }
    }

    #[test]
    fn a_message_is_a_frame_only_once_its_body_is_whole() {
        let mut framer = Framer::new(Framing::ContentLength);
        let framed = message(b"abc");
        framer.push(&framed[..framed.len() - 1]);
        assert!(!framer.has_frame());
        assert_eq!(framer.take(), messages(&[]));
        assert_eq!(framer.partial_len(), framed.len() - 1, "kept");
        framer.push(&framed[framed.len() - 1..]);
        assert!(framer.has_frame());
        assert_eq!(framer.take(), messages(&[b"abc"]));
    }

    #[test]
    fn an_empty_body_is_a_message() {
        let mut framer = Framer::new(Framing::ContentLength);
        framer.push(b"Content-Length: 0\r\n\r\n");
        assert_eq!(framer.take(), messages(&[b""]));
    }

    #[test]
    fn content_type_is_ignored_and_the_header_names_are_matched_without_regard_to_case() {
        let mut framer = Framer::new(Framing::ContentLength);
        framer.push(
            b"content-length: 2\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\nhi",
        );
        framer.push(b"CONTENT-TYPE: x\r\nCONTENT-LENGTH:1\r\n\r\n!");
        assert_eq!(framer.take(), messages(&[b"hi", b"!"]));
        assert_eq!(framer.fault(), None);
    }

    /// The fault of a framer pushed `bytes`, ended if `end`.
    fn malformed(bytes: &[u8], end: bool) -> Option<String> {
        let mut framer = Framer::new(Framing::ContentLength);
        framer.push(bytes);
        if end {
            framer.end();
        }
        framer.fault().map(str::to_owned)
    }

    #[test]
    fn a_header_that_breaks_a_rule_is_malformed_and_says_what() {
        let cases: [(&[u8], &str); 8] = [
            (b"X-Other: 1\r\n", "X-Other"),
            (b"Content-Length: 1\r\nContent-Length: 1\r\n", "twice"),
            (b"\r\n", "no Content-Length"),
            (b"Content-Type: x\r\n\r\n", "no Content-Length"),
            (b"Content-Length: 1x\r\n", "decimal"),
            (b"Content-Length: \r\n", "decimal"),
            (b"Content-Length: 1\n", "bare line feed"),
            (b"Content-Length: 1\r\nCont\xc3\xa9nt-Type: x", "ASCII"),
        ];
        for (bytes, says) in cases {
            let fault = malformed(bytes, false).unwrap_or_default();
            assert!(
                fault.contains(says),
                "{:?} is malformed saying {says:?}, not {fault:?}",
                String::from_utf8_lossy(bytes)
            );
        }
        assert!(
            malformed(b"NoColon\r\n", false).is_some(),
            "a line with no colon"
        );
        assert_eq!(
            malformed(b"Content-Length: 99999999999999999999999\r\n", false)
                .map(|fault| fault.contains("decimal")),
            Some(true),
            "a length no number holds"
        );
    }

    #[test]
    fn a_stream_that_ends_inside_a_header_or_a_body_is_malformed_and_one_that_ends_between_is_not()
    {
        let ended_inside = Some("the stream ended inside a message".to_owned());
        assert_eq!(malformed(b"Content-Len", true), ended_inside);
        assert_eq!(
            malformed(b"Content-Length: 3\r\n\r\nab", true),
            ended_inside
        );
        assert_eq!(malformed(&message(b"abc"), true), None);
        assert_eq!(malformed(b"", true), None);
    }

    #[test]
    fn a_malformed_header_keeps_the_messages_before_it() {
        let mut framer = Framer::new(Framing::ContentLength);
        let mut stream = message(b"good");
        stream.extend_from_slice(b"Bad: 1\r\n\r\n");
        stream.extend(message(b"after"));
        framer.push(&stream);
        assert!(framer.fault().is_some());
        assert_eq!(framer.take(), messages(&[b"good"]), "and nothing after it");
    }

    #[test]
    fn a_message_past_the_bound_is_too_long_as_soon_as_its_length_is_parsed_with_no_body_byte() {
        // The length's line is 19 bytes and the header's end 2 more: 21
        // and a body of 5 is 26.
        let mut outbox = Outbox::new(Framing::ContentLength, Framing::Lines, 25);
        outbox.push(Stream::Out, b"Content-Length: 5\r\n");
        assert_eq!(outbox.fault(Stream::Out), Some(Fault::MessageTooLong));

        let mut whole = Outbox::new(Framing::ContentLength, Framing::Lines, 26);
        whole.push(Stream::Out, b"Content-Length: 5\r\n");
        assert_eq!(whole.fault(Stream::Out), None, "exactly the bound");
        whole.push(Stream::Out, b"\r\nabcd");
        assert_eq!(whole.fault(Stream::Out), None);
        assert_eq!(whole.room(Stream::Out), 1);
        whole.push(Stream::Out, b"e");
        assert_eq!(whole.fault(Stream::Out), None);
        assert_eq!(whole.drain().0, messages(&[b"abcde"]), "delivered whole");
    }

    #[test]
    fn a_header_with_no_end_that_fills_the_bound_is_too_long_with_no_probe() {
        let mut outbox = Outbox::new(Framing::ContentLength, Framing::Lines, 8);
        outbox.push(Stream::Out, b"Content");
        assert_eq!(outbox.fault(Stream::Out), None, "room is left");
        outbox.push(Stream::Out, b"-");
        assert_eq!(outbox.fault(Stream::Out), Some(Fault::MessageTooLong));
    }

    #[test]
    fn a_malformed_header_is_the_fault_before_a_length_past_the_bound() {
        let mut outbox = Outbox::new(Framing::ContentLength, Framing::Lines, 4);
        outbox.push(Stream::Out, b"X: 1\r\n");
        assert!(matches!(
            outbox.fault(Stream::Out),
            Some(Fault::Malformed(_))
        ));
    }

    #[test]
    fn the_room_of_a_content_length_stream_is_the_bound_less_what_it_holds_untaken_messages_included()
     {
        let framed = message(b"abc");
        let mut outbox = Outbox::new(Framing::ContentLength, Framing::Lines, 100);
        outbox.push(Stream::Out, &framed);
        outbox.push(Stream::Out, b"Content-");
        assert!(outbox.deliverable());
        assert_eq!(outbox.room(Stream::Out), 100 - framed.len() as u64 - 8);
        assert_eq!(outbox.drain().0, messages(&[b"abc"]));
        assert_eq!(outbox.room(Stream::Out), 92, "the header in progress");
    }

    #[test]
    fn four_mebibytes_pushed_a_byte_at_a_time_are_scanned_once() {
        let body = vec![b'x'; 1 << 20];
        let mut stream = Vec::new();
        for _ in 0..4 {
            stream.extend(message(&body));
        }
        let mut framer = Framer::new(Framing::ContentLength);
        let mut got = 0;
        for byte in &stream {
            framer.push(std::slice::from_ref(byte));
            if framer.has_frame() {
                let Frames::Messages(taken) = framer.take() else {
                    panic!("messages");
                };
                got += taken.len();
            }
        }
        assert_eq!(got, 4);
        assert!(
            framer.scanned() <= stream.len(),
            "{} bytes scanned of {}",
            framer.scanned(),
            stream.len()
        );
        assert_eq!(
            framer.scanned(),
            4 * "Content-Length: 1048576\r\n\r\n".len(),
            "a body is never scanned"
        );
    }
}
