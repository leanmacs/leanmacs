//! The contract of the stream port: the rules every [`StreamSource`]
//! keeps, as a check that takes children over and pulls them.
//!
//! [`check`] runs every property and returns the names of those that fail.
//! Each needs a child of a [`Scenario`] the contract describes in its own
//! terms, and the [`Ground`] opens one: the fake ([`FakeSource`]) steps a
//! model as the scenario says, and `editor-process`'s ground over the real
//! service starts a `/bin/sh -c` script, or a `FakeProcesses` script that
//! mimics it, as a streaming child. So one contract holds the fake and the
//! real service to the same rules.
//!
//! The properties are [`TAKEN_LINES`] to [`REFUSED_WRITE_ENDED`] for a
//! child taken over, its bound and the refusals of a take-over and of a
//! write, and [`MESSAGES`] to
//! [`MESSAGE_MALFORMED`] for `Content-Length` framing.
//!
//! Every wait of the check returns on its event, a pull's or a write's
//! return or a reader's park on the bound ([`Ground::wait_held`]), and is
//! bounded only by [`Ground::deadline`], a hang guard: no property is
//! decided by a time running out. A pull and a write each run on a thread
//! of the check's, which the check waits for on a channel; a call that
//! does not return within the deadline fails its property as a hang, and
//! its thread is left to the ground's shutdown, which answers it. A call
//! that panics, as the fake's pull with nothing to deliver does, fails its
//! property too.
//!
//! Seen to bite: the contract's own tests run it over fakes written to
//! break one rule each ([`Flaws`](super::fake::Flaws)), and each names the
//! property it breaks.
//!
//! # Where an addition goes
//!
//! A new rule is a named `pub const`, an entry of [`PROPERTIES`], a step of
//! [`check`], a [`Scenario`] for each child it needs with its [`Shape`],
//! the fake's steps for it and `editor-process`'s script for it, and a
//! flaw of the fake's that breaks it, in this module's tests.

use std::sync::Arc;
use std::sync::mpsc;
use std::thread;

use editor_wait::HangGuard;

use super::{ChildStreams, Delivery, Ended, InputClosed, Pulled, Refused, StreamSource};
use crate::frame::{Frames, Framing, Stream};

#[cfg(doc)]
use super::fake::FakeSource;

/// What [`check`] needs done that the port has no method for: a child
/// opened, a job's read of it pending and withdrawn, and whether its
/// reader is parked on the bound.
pub trait Ground {
    /// The source checked.
    fn source(&self) -> &dyn StreamSource;

    /// Opens the child of `scenario` as a live streaming child, as a job
    /// does, and gives its number: `None` if it cannot. Its number is
    /// never [`UNUSED`].
    fn open(&self, scenario: Scenario) -> Option<u64>;

    /// Waits until a reader of the child `child` is parked on its bound,
    /// up to [`Ground::deadline`], and says whether one was: a hang guard,
    /// for a park that must come.
    fn wait_held(&self, child: u64) -> bool;

    /// Makes a job's read of the child `child` pending, with nothing yet
    /// to deliver, and says whether it is.
    fn pend_read(&self, child: u64) -> bool;

    /// Withdraws the job's read of the child `child`, as a cancel of the
    /// read does.
    fn withdraw_read(&self, child: u64);

    /// hang guard: each event the check waits for with it, a pull's or a
    /// write's return or a reader's park, which must come; only a hang
    /// reaches the bound, and the property then fails as a hang.
    fn deadline(&self) -> HangGuard;
}

/// A child the check needs, in the contract's terms. A ground maps each to
/// a child of its own: a fake's steps, a `FakeProcesses` script, or a
/// `/bin/sh -c` script.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Scenario {
    /// Writes `one`, reads a line and, if it is `pong`, writes
    /// `got pong`; then exits 3. Lines, with an input.
    Echo,
    /// Writes [`NUMBERED`] numbered lines ([`numbered`]) and exits 0, at a
    /// bound of [`HELD_BOUND`]. Lines, no input.
    Numbered,
    /// Writes one line of three mebibytes ([`megabyte_line`]) and exits 0,
    /// at a bound of [`MEGABYTES_BOUND`]: the opener's bound in megabytes,
    /// an agent's case. Lines, no input.
    Megabytes,
    /// Writes `taken` and exits 0. Lines, no input.
    OneLine,
    /// Writes nothing until it reads a line; then writes it back and exits
    /// 0. Lines, with an input.
    AwaitsLine,
    /// Writes [`MESSAGES_WRITTEN`], each chunk a write, and exits 0.
    /// `Content-Length` on standard output, no input.
    Messages,
    /// Writes [`AT_BOUND_MESSAGE`], exactly its bound long, and exits 0.
    /// `Content-Length` on standard output, no input.
    MessageAtBound,
    /// Writes [`TOO_LONG_WRITTEN`], a message and then a header whose
    /// length passes the bound of [`TOO_LONG_BOUND`], then writes nothing
    /// and waits on its input. `Content-Length` on standard output, with
    /// an input.
    MessageTooLong,
    /// Writes [`MALFORMED_WRITTEN`], a message and then a header naming an
    /// unknown field, then waits on its input. `Content-Length` on
    /// standard output, with an input.
    MessageMalformed,
}

/// How a scenario's child is opened: its framings, its bound and whether
/// it has an input.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Shape {
    /// How its standard output is framed.
    pub out: Framing,
    /// How its standard error is framed.
    pub err: Framing,
    /// Its bound, in bytes.
    pub bound: u64,
    /// Whether it has an input.
    pub input: bool,
}

/// A bound no scenario's output reaches but where it says.
pub const ROOMY: u64 = 1 << 20;
/// How many lines [`Scenario::Numbered`] writes.
pub const NUMBERED: usize = 2000;
/// [`Scenario::Numbered`]'s bound.
pub const HELD_BOUND: u64 = 64;
/// How long [`Scenario::Megabytes`]'s line is, its line feed not counted.
pub const MEGABYTE_LINE: usize = 3 << 20;
/// [`Scenario::Megabytes`]'s bound.
pub const MEGABYTES_BOUND: u64 = 4 << 20;
/// What [`Scenario::Messages`] writes, a write each: a message split
/// across writes, one with a `Content-Type`, and one with an empty body.
pub const MESSAGES_WRITTEN: [&[u8]; 4] = [
    b"Content-Length: 5\r\n\r\nhel",
    b"lo",
    b"Content-Length: 2\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\nhi",
    b"Content-Length: 0\r\n\r\n",
];
/// The bodies of [`MESSAGES_WRITTEN`].
pub const MESSAGES_BODIES: [&[u8]; 3] = [b"hello", b"hi", b""];
/// What [`Scenario::MessageAtBound`] writes: a message exactly its bound
/// long, its header counted.
pub const AT_BOUND_MESSAGE: &[u8] = b"Content-Length: 5\r\n\r\nhello";
/// What [`Scenario::MessageTooLong`] writes, a write each.
pub const TOO_LONG_WRITTEN: [&[u8]; 2] = [
    b"Content-Length: 2\r\n\r\nok",
    b"Content-Length: 1000\r\n\r\n",
];
/// [`Scenario::MessageTooLong`]'s bound: both its writes fit, and the
/// message the second announces does not.
pub const TOO_LONG_BOUND: u64 = 64;
/// What [`Scenario::MessageMalformed`] writes, a write each.
pub const MALFORMED_WRITTEN: [&[u8]; 2] = [b"Content-Length: 2\r\n\r\nok", b"X-Unknown: 1\r\n\r\n"];

impl Scenario {
    /// Every scenario.
    pub const ALL: [Self; 9] = [
        Self::Echo,
        Self::Numbered,
        Self::Megabytes,
        Self::OneLine,
        Self::AwaitsLine,
        Self::Messages,
        Self::MessageAtBound,
        Self::MessageTooLong,
        Self::MessageMalformed,
    ];

    /// How its child is opened.
    pub const fn shape(self) -> Shape {
        const fn lines(bound: u64, input: bool) -> Shape {
            Shape {
                out: Framing::Lines,
                err: Framing::Lines,
                bound,
                input,
            }
        }
        const fn messages(bound: u64, input: bool) -> Shape {
            Shape {
                out: Framing::ContentLength,
                err: Framing::Lines,
                bound,
                input,
            }
        }
        match self {
            Self::Echo | Self::AwaitsLine => lines(ROOMY, true),
            Self::Numbered => lines(HELD_BOUND, false),
            Self::Megabytes => lines(MEGABYTES_BOUND, false),
            Self::OneLine => lines(ROOMY, false),
            Self::Messages => messages(ROOMY, false),
            Self::MessageAtBound => messages(AT_BOUND_MESSAGE.len() as u64, false),
            Self::MessageTooLong => messages(TOO_LONG_BOUND, true),
            Self::MessageMalformed => messages(ROOMY, true),
        }
    }
}

/// What [`Scenario::Numbered`] writes: the numbers from 0 below
/// [`NUMBERED`], a line each, as `echo` writes them.
pub fn numbered() -> Vec<u8> {
    (0..NUMBERED)
        .flat_map(|n| format!("{n}\n").into_bytes())
        .collect()
}

/// What [`Scenario::Megabytes`] writes: [`MEGABYTE_LINE`] bytes, spaces
/// and a last `x`, and a line feed, as `printf '%3145728s\n' x` writes it.
pub fn megabyte_line() -> Vec<u8> {
    let mut line = vec![b' '; MEGABYTE_LINE - 1];
    line.extend_from_slice(b"x\n");
    line
}

/// A number no ground gives a child.
pub const UNUSED: u64 = u64::MAX - 1;

/// A child's lines arrive as it writes them after a take-over, and a line
/// written reaches its input: [`Scenario::Echo`] gives `one`, takes `pong`
/// and gives `got pong`, then its exit, 3.
pub const TAKEN_LINES: &str =
    "a child taken over gives its lines, takes a line written, and gives its exit";
/// A child is held at its bound while nothing pulls, and everything it
/// wrote is delivered once pulling resumes: [`Scenario::Numbered`]'s
/// reader parks, then pulls give every line in order, none over the
/// bound, and the exit.
pub const TAKEN_HELD: &str =
    "a child taken over is held at its bound while nothing pulls, and loses nothing";
/// A line of three mebibytes, under a bound of four, is delivered whole:
/// the bound is the opener's, in megabytes.
pub const TAKEN_MEGABYTES: &str = "a line of megabytes under a bound of megabytes arrives whole";
/// A second take-over of a child taken over is refused as taken.
pub const REFUSED_TAKEN: &str = "a second take-over is refused";
/// A child with a job's read pending is refused as such, and taken over
/// once the read is withdrawn.
pub const REFUSED_READ_PENDING: &str =
    "a child with a job's read pending is refused until the read is withdrawn";
/// A number no child has is refused as no such child, and so is a child
/// whose last delivery was pulled.
pub const REFUSED_NO_SUCH_CHILD: &str =
    "an unknown child, and one whose last delivery was pulled, is no such child";
/// A write to a child taken over that has no input is refused as
/// [`InputClosed`], with words: [`Scenario::OneLine`]'s, before it is
/// pulled, which still gives its line and its exit.
pub const REFUSED_WRITE_NO_INPUT: &str =
    "a write to a child with no input is refused as input closed";
/// A write to a child whose last delivery was pulled is refused as
/// [`InputClosed`], with words, though it had an input:
/// [`Scenario::AwaitsLine`]'s, after the line it was written came back
/// and its exit.
pub const REFUSED_WRITE_ENDED: &str =
    "a write after the last delivery was pulled is refused as input closed";
/// `Content-Length` messages, split across writes, one with a
/// `Content-Type` and one with an empty body, are delivered whole as
/// [`Frames::Messages`], then the exit.
pub const MESSAGES: &str = "Content-Length messages are delivered whole whatever the writes";
/// A message exactly the bound long, its header counted, is delivered.
pub const MESSAGE_AT_BOUND: &str = "a message exactly the bound long, header counted, is delivered";
/// A header whose length passes the bound ends the child as message too
/// long, the messages before it intact, though the child never writes its
/// body: it is refused without reading it.
pub const MESSAGE_TOO_LONG: &str =
    "a message past the bound ends the child at its header, the messages before it intact";
/// A header naming an unknown field ends the child as failed, the message
/// before it intact.
pub const MESSAGE_MALFORMED: &str =
    "a malformed header ends the child, the messages before it intact";

/// Every property, by name, in the order [`check`] runs them.
pub const PROPERTIES: [&str; 12] = [
    TAKEN_LINES,
    TAKEN_HELD,
    TAKEN_MEGABYTES,
    REFUSED_TAKEN,
    REFUSED_READ_PENDING,
    REFUSED_NO_SUCH_CHILD,
    REFUSED_WRITE_NO_INPUT,
    REFUSED_WRITE_ENDED,
    MESSAGES,
    MESSAGE_AT_BOUND,
    MESSAGE_TOO_LONG,
    MESSAGE_MALFORMED,
];

/// Holds the source of `ground` to the contract, and returns the names of
/// the properties that fail: none when it keeps them all.
pub fn check(ground: &impl Ground) -> Vec<&'static str> {
    let check = Check { ground };
    let results = [
        (TAKEN_LINES, check.taken_lines()),
        (TAKEN_HELD, check.taken_held()),
        (TAKEN_MEGABYTES, check.taken_megabytes()),
        (REFUSED_TAKEN, check.refused_taken()),
        (REFUSED_READ_PENDING, check.refused_read_pending()),
        (REFUSED_NO_SUCH_CHILD, check.refused_no_such_child()),
        (REFUSED_WRITE_NO_INPUT, check.refused_write_no_input()),
        (REFUSED_WRITE_ENDED, check.refused_write_ended()),
        (MESSAGES, check.messages()),
        (MESSAGE_AT_BOUND, check.message_at_bound()),
        (MESSAGE_TOO_LONG, check.message_too_long()),
        (MESSAGE_MALFORMED, check.message_malformed()),
    ];
    results
        .into_iter()
        .filter_map(|(name, holds)| (!holds.unwrap_or(false)).then_some(name))
        .collect()
}

/// A child taken over, shared with the threads that call it.
type Streams = Arc<dyn ChildStreams>;

/// A check in progress.
struct Check<'a, G> {
    /// The ground.
    ground: &'a G,
}

impl<G: Ground> Check<'_, G> {
    /// Takes the child `child` over.
    fn take(&self, child: u64) -> Result<Streams, Refused> {
        self.ground.source().take_over(child).map(Arc::from)
    }

    /// What `call` answers of `streams`, run on a thread of its own and
    /// waited for up to the deadline: `None` if it does not return by
    /// then, or panics.
    fn bounded<T: Send + 'static>(
        &self,
        streams: &Streams,
        call: impl FnOnce(&dyn ChildStreams) -> T + Send + 'static,
    ) -> Option<T> {
        let (sender, answer) = mpsc::channel();
        let streams = Arc::clone(streams);
        let calling = thread::Builder::new()
            .name("stream-contract".into())
            .spawn(move || {
                let _ = sender.send(call(&*streams));
            })
            .ok()?;
        let answered = editor_wait::recv(&answer, self.ground.deadline()).ok();
        if answered.is_some() {
            // It has sent its answer, so it returns now.
            let _ = calling.join();
        }
        answered
    }

    /// The next pull of `streams`.
    fn pull(&self, streams: &Streams) -> Option<Pulled> {
        self.bounded(streams, |streams| streams.pull())
    }

    /// A write of `bytes` to `streams`.
    fn write(&self, streams: &Streams, bytes: &[u8]) -> Option<Result<(), InputClosed>> {
        let bytes = bytes.to_vec();
        self.bounded(streams, move |streams| streams.write(bytes))
    }

    /// Every delivery of `streams` to its last: `None` if a pull does not
    /// return, or answers cancelled, first.
    fn to_the_end(&self, streams: &Streams) -> Option<Vec<Delivery>> {
        let mut deliveries = Vec::new();
        loop {
            let Pulled::Delivered(delivery) = self.pull(streams)? else {
                return None;
            };
            let ended = delivery.ended.is_some();
            deliveries.push(delivery);
            if ended {
                return Some(deliveries);
            }
        }
    }

    /// Opens `scenario`'s child and takes it over.
    fn opened(&self, scenario: Scenario) -> Option<(u64, Streams)> {
        let child = self.ground.open(scenario)?;
        Some((child, self.take(child).ok()?))
    }

    /// [`TAKEN_LINES`].
    fn taken_lines(&self) -> Option<bool> {
        let (_, streams) = self.opened(Scenario::Echo)?;
        let Pulled::Delivered(first) = self.pull(&streams)? else {
            return Some(false);
        };
        let first_is_one = lines_of(std::slice::from_ref(&first), Stream::Out) == [b"one".to_vec()]
            && first.ended.is_none();
        let written = self.write(&streams, b"pong\n")? == Ok(());
        let rest = self.to_the_end(&streams)?;
        Some(
            first_is_one
                && written
                && lines_of(&rest, Stream::Out) == [b"got pong".to_vec()]
                && last_end(&rest) == Some(Ended::Exited { code: 3 }),
        )
    }

    /// [`TAKEN_HELD`].
    fn taken_held(&self) -> Option<bool> {
        let (child, streams) = self.opened(Scenario::Numbered)?;
        let held = self.ground.wait_held(child);
        let all = self.to_the_end(&streams)?;
        let expected: Vec<Vec<u8>> = numbered()
            .split(|&byte| byte == b'\n')
            .filter(|line| !line.is_empty())
            .map(<[u8]>::to_vec)
            .collect();
        Some(
            held && lines_of(&all, Stream::Out) == expected
                && all.iter().all(|delivery| {
                    frame_bytes(&delivery.out) <= HELD_BOUND as usize
                        && frame_bytes(&delivery.err) <= HELD_BOUND as usize
                })
                && last_end(&all) == Some(Ended::Exited { code: 0 }),
        )
    }

    /// [`TAKEN_MEGABYTES`].
    fn taken_megabytes(&self) -> Option<bool> {
        let (_, streams) = self.opened(Scenario::Megabytes)?;
        let all = self.to_the_end(&streams)?;
        let mut line = megabyte_line();
        line.pop();
        Some(
            lines_of(&all, Stream::Out) == [line]
                && last_end(&all) == Some(Ended::Exited { code: 0 }),
        )
    }

    /// [`REFUSED_TAKEN`].
    fn refused_taken(&self) -> Option<bool> {
        let (child, streams) = self.opened(Scenario::OneLine)?;
        let again = self.take(child).err();
        let all = self.to_the_end(&streams)?;
        Some(
            again == Some(Refused::Taken)
                && lines_of(&all, Stream::Out) == [b"taken".to_vec()]
                && last_end(&all) == Some(Ended::Exited { code: 0 }),
        )
    }

    /// [`REFUSED_READ_PENDING`].
    fn refused_read_pending(&self) -> Option<bool> {
        let child = self.ground.open(Scenario::AwaitsLine)?;
        let pending = self.ground.pend_read(child);
        let refused = self.take(child).err();
        self.ground.withdraw_read(child);
        let streams = self.take(child).ok()?;
        let written = self.write(&streams, b"go\n")? == Ok(());
        let all = self.to_the_end(&streams)?;
        Some(
            pending
                && refused == Some(Refused::ReadPending)
                && written
                && lines_of(&all, Stream::Out) == [b"go".to_vec()]
                && last_end(&all) == Some(Ended::Exited { code: 0 }),
        )
    }

    /// [`REFUSED_NO_SUCH_CHILD`].
    fn refused_no_such_child(&self) -> Option<bool> {
        let unknown = self.take(UNUSED).err();
        let (child, streams) = self.opened(Scenario::OneLine)?;
        let all = self.to_the_end(&streams)?;
        let forgotten = self.take(child).err();
        Some(
            unknown == Some(Refused::NoSuchChild)
                && last_end(&all) == Some(Ended::Exited { code: 0 })
                && forgotten == Some(Refused::NoSuchChild),
        )
    }

    /// [`REFUSED_WRITE_NO_INPUT`].
    fn refused_write_no_input(&self) -> Option<bool> {
        let (_, streams) = self.opened(Scenario::OneLine)?;
        let refused = self.write(&streams, b"x\n")?;
        let all = self.to_the_end(&streams)?;
        Some(
            input_closed(&refused)
                && lines_of(&all, Stream::Out) == [b"taken".to_vec()]
                && last_end(&all) == Some(Ended::Exited { code: 0 }),
        )
    }

    /// [`REFUSED_WRITE_ENDED`].
    fn refused_write_ended(&self) -> Option<bool> {
        let (_, streams) = self.opened(Scenario::AwaitsLine)?;
        let written = self.write(&streams, b"go\n")? == Ok(());
        let all = self.to_the_end(&streams)?;
        let refused = self.write(&streams, b"again\n")?;
        Some(
            written
                && lines_of(&all, Stream::Out) == [b"go".to_vec()]
                && last_end(&all) == Some(Ended::Exited { code: 0 })
                && input_closed(&refused),
        )
    }

    /// The messages `scenario`'s child delivers on standard output to its
    /// last delivery, and how it ended.
    fn messages_to_the_end(&self, scenario: Scenario) -> Option<(Vec<Vec<u8>>, Option<Ended>)> {
        let (_, streams) = self.opened(scenario)?;
        let all = self.to_the_end(&streams)?;
        let mut messages = Vec::new();
        for delivery in &all {
            match &delivery.out {
                Frames::Messages(bodies) => messages.extend(bodies.iter().cloned()),
                other if other.is_empty() => {}
                // Anything but messages is not this framing's.
                _ => return Some((Vec::new(), None)),
            }
        }
        Some((messages, last_end(&all)))
    }

    /// [`MESSAGES`].
    fn messages(&self) -> Option<bool> {
        let (messages, ended) = self.messages_to_the_end(Scenario::Messages)?;
        Some(messages == MESSAGES_BODIES && ended == Some(Ended::Exited { code: 0 }))
    }

    /// [`MESSAGE_AT_BOUND`].
    fn message_at_bound(&self) -> Option<bool> {
        let (messages, ended) = self.messages_to_the_end(Scenario::MessageAtBound)?;
        Some(messages == [b"hello"] && ended == Some(Ended::Exited { code: 0 }))
    }

    /// [`MESSAGE_TOO_LONG`].
    fn message_too_long(&self) -> Option<bool> {
        let (messages, ended) = self.messages_to_the_end(Scenario::MessageTooLong)?;
        Some(
            messages == [b"ok"]
                && ended
                    == Some(Ended::MessageTooLong {
                        stream: Stream::Out,
                        bound: TOO_LONG_BOUND,
                    }),
        )
    }

    /// [`MESSAGE_MALFORMED`].
    fn message_malformed(&self) -> Option<bool> {
        let (messages, ended) = self.messages_to_the_end(Scenario::MessageMalformed)?;
        Some(messages == [b"ok"] && matches!(ended, Some(Ended::Failed(_))))
    }
}

/// Whether `written` is a refusal as input closed, in words.
fn input_closed(written: &Result<(), InputClosed>) -> bool {
    matches!(written, Err(InputClosed(words)) if !words.is_empty())
}

/// How the last of `deliveries` says the child ended.
fn last_end(deliveries: &[Delivery]) -> Option<Ended> {
    deliveries.last().and_then(|last| last.ended.clone())
}

/// Every line of `stream` in `deliveries`, in order.
fn lines_of(deliveries: &[Delivery], stream: Stream) -> Vec<Vec<u8>> {
    deliveries
        .iter()
        .flat_map(|delivery| {
            let frames = match stream {
                Stream::Out => &delivery.out,
                Stream::Err => &delivery.err,
            };
            match frames {
                Frames::Lines(lines) => lines.clone(),
                _ => Vec::new(),
            }
        })
        .collect()
}

/// How many bytes `frames` stand for, a line feed counted for each line.
fn frame_bytes(frames: &Frames) -> usize {
    match frames {
        Frames::Lines(lines) => lines.iter().map(|line| line.len() + 1).sum(),
        Frames::Bytes(bytes) => bytes.len(),
        Frames::Messages(bodies) => bodies.iter().map(Vec::len).sum(),
    }
}

#[cfg(test)]
mod tests {
    use super::super::fake::{FakeSource, Flaws};
    use super::*;

    #[test]
    fn the_properties_are_twelve_and_each_is_named_once() {
        let mut names = PROPERTIES.to_vec();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), 12);
    }

    #[test]
    fn the_fake_keeps_the_contract() {
        let fake = FakeSource::new();

        let failures = check(&fake);

        assert_eq!(failures, [""; 0]);
        assert_eq!(
            fake.record().written.len(),
            5,
            "the echo's line, the awaited one twice and the two refused"
        );
    }

    /// The properties a fake that breaks the rules `flaws` names fails.
    fn failures(flaws: Flaws) -> Vec<&'static str> {
        check(&FakeSource::flawed(flaws))
    }

    #[test]
    fn a_fake_that_drops_output_past_the_bound_is_reported() {
        let failed = failures(Flaws {
            drop_past_bound: true,
            ..Flaws::default()
        });

        assert_eq!(failed, [TAKEN_HELD]);
    }

    #[test]
    fn a_fake_that_allows_a_second_take_over_is_reported() {
        let failed = failures(Flaws {
            second_take_over: true,
            ..Flaws::default()
        });

        assert_eq!(failed, [REFUSED_TAKEN]);
    }

    #[test]
    fn a_fake_that_ignores_a_pending_read_is_reported() {
        let failed = failures(Flaws {
            ignore_pending_read: true,
            ..Flaws::default()
        });

        assert_eq!(failed, [REFUSED_READ_PENDING]);
    }

    #[test]
    fn a_fake_that_accepts_a_write_to_a_closed_input_is_reported() {
        let failed = failures(Flaws {
            accept_closed_write: true,
            ..Flaws::default()
        });

        assert_eq!(failed, [REFUSED_WRITE_NO_INPUT, REFUSED_WRITE_ENDED]);
    }

    #[test]
    fn a_fake_that_splits_a_message_where_a_pull_finds_it_is_reported() {
        let failed = failures(Flaws {
            split_messages: true,
            ..Flaws::default()
        });

        assert_eq!(
            failed,
            [
                MESSAGES,
                MESSAGE_AT_BOUND,
                MESSAGE_TOO_LONG,
                MESSAGE_MALFORMED
            ]
        );
    }

    #[test]
    fn a_fake_that_reads_a_too_long_messages_body_before_refusing_it_is_reported() {
        let failed = failures(Flaws {
            read_long_body: true,
            ..Flaws::default()
        });

        assert_eq!(failed, [MESSAGE_TOO_LONG]);
    }
}
