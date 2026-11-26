//! The fake of the stream port: a source whose children are a model,
//! stepped by the test on its own thread, published so that a package's
//! crate tests what it does with a taken-over child without a process.
//!
//! [`FakeSource`] registers a child ([`FakeSource::child`]) with its
//! framings, its bound and whether it has an input, and the test steps it
//! through the [`FakeChild`] it gets: it writes to a stream
//! ([`FakeChild::out`], [`FakeChild::err`]), answers a line of its input
//! ([`FakeChild::on_line`]), ends ([`FakeChild::exit`],
//! [`FakeChild::signal`]) or is cancelled ([`FakeChild::cancel`]); and the
//! job's read of it is pending or withdrawn ([`FakeChild::pend_read`],
//! [`FakeChild::withdraw_read`]). Each step is done at once, in order, but
//! one queued behind an [`FakeChild::on_line`] waits for the consumer to
//! write that line.
//!
//! It frames and bounds with the real [`Outbox`], so its framing and its
//! bound cannot drift from the process service's. What a child writes goes
//! into a model pipe, of which only the room the bound leaves enters the
//! outbox, chunk by chunk as it was written; the rest is held, and enters
//! as a pull makes room. A stream closes once the child has ended and its
//! pipe is drained. The rules the service keeps on top of the outbox are
//! kept here too: a partial line that fills the bound is too long once one
//! more byte is in its pipe, and the stream's last line if the stream
//! closes there; a message too long, or malformed, ends the child at once,
//! the group killed, with the rest of its pipe never read.
//!
//! It never blocks, so it never needs a wait: a pull with nothing to give
//! panics, saying to step the fake first. It records every take-over and
//! every write ([`FakeSource::record`]), and says whether a child is held
//! ([`FakeChild::held`]): a pipe holds bytes that the bound leaves no room
//! for.
//!
//! [`Flaws`] makes a fake that breaks one rule, for the contract's own
//! tests: that is how they show the contract bites. It is also the
//! contract's [`Ground`] over itself, every [`Scenario`] scripted as the
//! contract says.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use editor_wait::HangGuard;

use super::contract::{Ground, Scenario};
use super::{ChildStreams, Delivery, Ended, InputClosed, Pulled, Refused, StreamSource};
use crate::frame::{Fault, Frames, Framing, Outbox, Stream};

/// The rules a flawed fake breaks, for the contract's own tests. The fake
/// keeps every rule with [`Flaws::default`].
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Flaws {
    /// Output the bound leaves no room for is dropped, not held.
    pub drop_past_bound: bool,
    /// A child taken over may be taken over again.
    pub second_take_over: bool,
    /// A child is taken over though a job's read of it is pending.
    pub ignore_pending_read: bool,
    /// A `Content-Length` stream is cut into messages where a pull finds
    /// it, not where each message's length ends.
    pub split_messages: bool,
    /// A message longer than the bound is not refused when its length is
    /// parsed: its body is read first.
    pub read_long_body: bool,
}

/// What the fake has seen, as a test reads it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Record {
    /// Every child taken over, oldest first.
    pub taken: Vec<u64>,
    /// Every write a consumer made, oldest first: the child and the bytes.
    pub written: Vec<(u64, Vec<u8>)>,
}

/// One thing a child does, queued.
#[derive(Debug, Clone)]
enum Step {
    /// Writes these bytes to the stream.
    Write(Stream, Vec<u8>),
    /// Waits for one line of its input; writes the reply to standard
    /// output if the line is this one.
    OnLine(Vec<u8>, Vec<u8>),
    /// Ends as this.
    End(Ended),
}

/// One stream's pipe: the chunks written and not yet read, oldest first.
#[derive(Debug, Default)]
struct Pipe {
    /// The chunks.
    chunks: VecDeque<Vec<u8>>,
}

impl Pipe {
    /// Whether it holds nothing.
    fn is_empty(&self) -> bool {
        self.chunks.is_empty()
    }
}

/// A child of the fake's.
#[derive(Debug)]
struct Model {
    /// What has been read and not yet pulled, framed and bounded.
    outbox: Outbox,
    /// Each stream's framing, out then err.
    framing: [Framing; 2],
    /// Each stream's pipe, out then err.
    pipes: [Pipe; 2],
    /// What it does next, in order.
    steps: VecDeque<Step>,
    /// Its input received and not yet read, when it has one.
    input: Option<Vec<u8>>,
    /// How it ended, once it has: its streams close once drained.
    exit: Option<Ended>,
    /// What ended it before its streams did: a fault of its framing.
    failed: Option<Ended>,
    /// Whether the job's read of it is pending.
    read_pending: bool,
    /// Whether it was taken over.
    taken: bool,
    /// Whether it was cancelled, or its last delivery pulled: it is gone.
    gone: bool,
    /// The bytes written to a `Content-Length` stream and not yet pulled,
    /// under [`Flaws::split_messages`].
    split: [Vec<u8>; 2],
}

/// The slot of `stream`.
const fn slot(stream: Stream) -> usize {
    match stream {
        Stream::Out => 0,
        Stream::Err => 1,
    }
}

/// The streams, in slot order.
const STREAMS: [Stream; 2] = [Stream::Out, Stream::Err];

impl Model {
    /// Does its steps until one waits for input, or none is left.
    fn advance(&mut self) {
        while let Some(step) = self.steps.front().cloned() {
            if self.exit.is_some() || self.failed.is_some() {
                self.steps.clear();
                return;
            }
            match step {
                Step::Write(stream, bytes) => {
                    if !bytes.is_empty() {
                        self.pipes[slot(stream)].chunks.push_back(bytes);
                    }
                }
                Step::OnLine(line, reply) => {
                    let input = self.input.get_or_insert_with(Vec::new);
                    let Some(end) = input.iter().position(|&byte| byte == b'\n') else {
                        return;
                    };
                    let read: Vec<u8> = input.drain(..=end).collect();
                    if read == line && !reply.is_empty() {
                        self.pipes[0].chunks.push_back(reply);
                    }
                }
                Step::End(ended) => {
                    self.exit = Some(ended);
                    self.input = None;
                }
            }
            self.steps.pop_front();
        }
    }

    /// Reads what each pipe holds into the outbox, as far as the bound
    /// leaves room, as the service's readers do, and ends what can be
    /// framed no further.
    fn pump(&mut self, flaws: Flaws) {
        for stream in STREAMS {
            self.pump_stream(stream, flaws);
        }
    }

    /// [`Model::pump`], of one stream.
    fn pump_stream(&mut self, stream: Stream, flaws: Flaws) {
        let at = slot(stream);
        loop {
            if self.failed.is_some() {
                return;
            }
            if let Some(fault) = self.outbox.fault(stream) {
                let bound = self.outbox.bound();
                match fault {
                    Fault::LineFillsBound => {
                        if !self.pipes[at].is_empty() {
                            self.fail(Ended::LineTooLong { stream, bound });
                        } else if self.exit.is_some() {
                            self.outbox.end(stream);
                        }
                        return;
                    }
                    Fault::MessageTooLong if flaws.read_long_body => {}
                    Fault::MessageTooLong => {
                        self.fail(Ended::MessageTooLong { stream, bound });
                        return;
                    }
                    Fault::Malformed(words) => {
                        self.fail(Ended::Failed(words));
                        return;
                    }
                }
            }
            let room = usize::try_from(self.outbox.room(stream)).unwrap_or(usize::MAX);
            let Some(chunk) = self.pipes[at].chunks.front_mut() else {
                if self.exit.is_some() {
                    self.outbox.end(stream);
                }
                return;
            };
            if room == 0 && !flaws.drop_past_bound {
                return;
            }
            let count = room.min(chunk.len());
            let read: Vec<u8> = chunk.drain(..count).collect();
            if chunk.is_empty() || flaws.drop_past_bound {
                self.pipes[at].chunks.pop_front();
            }
            if flaws.split_messages && self.framing[at] == Framing::ContentLength {
                self.split[at].extend_from_slice(&read);
            }
            self.outbox.push(stream, &read);
        }
    }

    /// Ends it as `ended` before its streams did: its group is killed, and
    /// what its pipes hold is never read.
    fn fail(&mut self, ended: Ended) {
        self.failed = Some(ended);
        self.exit.get_or_insert(Ended::Signalled { signal: 9 });
        self.steps.clear();
        self.input = None;
        for pipe in &mut self.pipes {
            pipe.chunks.clear();
        }
    }

    /// Whether a pipe holds bytes the bound leaves no room for.
    fn held(&self) -> bool {
        self.failed.is_none()
            && STREAMS.iter().any(|&stream| {
                !self.pipes[slot(stream)].is_empty() && self.outbox.room(stream) == 0
            })
    }

    /// How it ended, once nothing more can be delivered.
    fn end(&self) -> Option<Ended> {
        if let Some(failed) = &self.failed {
            return Some(failed.clone());
        }
        self.outbox.ended().then(|| self.exit.clone()).flatten()
    }

    /// Takes every frame, as the outbox gives them, but in a split stream.
    fn drain(&mut self) -> (Frames, Frames) {
        let (out, err) = self.outbox.drain();
        let mut frames = [out, err];
        for (at, frames) in frames.iter_mut().enumerate() {
            if !self.split[at].is_empty() {
                *frames = Frames::Messages(vec![std::mem::take(&mut self.split[at])]);
            }
        }
        let [out, err] = frames;
        (out, err)
    }
}

/// What the fake holds.
#[derive(Debug, Default)]
struct State {
    /// Each child, by its number.
    children: HashMap<u64, Model>,
    /// The next child's number.
    next: u64,
    /// What a test reads.
    record: Record,
    /// The rules it breaks.
    flaws: Flaws,
}

/// A source whose children are a model a test steps: the port's fake. A
/// cheap handle: clones share one state.
#[derive(Debug, Clone, Default)]
pub struct FakeSource {
    /// The state its handles share.
    shared: Arc<Mutex<State>>,
}

impl FakeSource {
    /// A fake with no child.
    pub fn new() -> Self {
        Self::flawed(Flaws::default())
    }

    /// A fake that breaks the rules `flaws` names, for the contract's own
    /// tests.
    pub fn flawed(flaws: Flaws) -> Self {
        let fake = Self::default();
        let mut state = fake.state();
        state.flaws = flaws;
        state.next = 1;
        drop(state);
        fake
    }

    /// Locks the state. The lock is never held while a caller's code runs.
    fn state(&self) -> MutexGuard<'_, State> {
        self.shared.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Registers a live child whose standard output is framed as `out` and
    /// whose standard error as `err`, each holding up to `bound` bytes,
    /// with an input if `input`; it writes nothing until it is stepped.
    pub fn child(&self, out: Framing, err: Framing, bound: u64, input: bool) -> FakeChild {
        let mut state = self.state();
        let id = state.next;
        state.next += 1;
        state.children.insert(
            id,
            Model {
                outbox: Outbox::new(out, err, bound),
                framing: [out, err],
                pipes: [Pipe::default(), Pipe::default()],
                steps: VecDeque::new(),
                input: input.then(Vec::new),
                exit: None,
                failed: None,
                read_pending: false,
                taken: false,
                gone: false,
                split: [Vec::new(), Vec::new()],
            },
        );
        drop(state);
        FakeChild {
            source: self.clone(),
            id,
        }
    }

    /// What the fake has seen so far.
    pub fn record(&self) -> Record {
        self.state().record.clone()
    }

    /// Does `change` to the child `id`, then takes it as far as it can go.
    fn step(&self, id: u64, change: impl FnOnce(&mut Model)) {
        let mut state = self.state();
        let flaws = state.flaws;
        if let Some(model) = state.children.get_mut(&id) {
            change(model);
            model.advance();
            model.pump(flaws);
        }
    }

    /// The model's pull of the child `id`.
    fn pull(&self, id: u64) -> Pulled {
        let mut state = self.state();
        let flaws = state.flaws;
        let Some(model) = state.children.get_mut(&id) else {
            return Pulled::Cancelled;
        };
        if model.gone {
            return Pulled::Cancelled;
        }
        model.pump(flaws);
        let ended = model.end();
        if !model.outbox.deliverable() && ended.is_none() {
            drop(state);
            panic!("pull with nothing to deliver: step the fake first");
        }
        let (out, err) = model.drain();
        if ended.is_some() {
            model.gone = true;
        } else {
            model.pump(flaws);
        }
        Pulled::Delivered(Delivery { out, err, ended })
    }

    /// The model's write to the child `id`'s input.
    fn write(&self, id: u64, bytes: Vec<u8>) -> Result<(), InputClosed> {
        let mut state = self.state();
        let flaws = state.flaws;
        state.record.written.push((id, bytes.clone()));
        let Some(model) = state.children.get_mut(&id) else {
            return Err(InputClosed("the fake has no such child".into()));
        };
        let Some(input) = model.input.as_mut().filter(|_| !model.gone) else {
            return Err(InputClosed(
                "cannot write to the fake child's standard input: it is closed".into(),
            ));
        };
        input.extend_from_slice(&bytes);
        model.advance();
        model.pump(flaws);
        Ok(())
    }
}

impl StreamSource for FakeSource {
    fn take_over(&self, child: u64) -> Result<Box<dyn ChildStreams>, Refused> {
        let mut state = self.state();
        let flaws = state.flaws;
        let Some(model) = state.children.get_mut(&child).filter(|model| !model.gone) else {
            return Err(Refused::NoSuchChild);
        };
        if model.taken && !flaws.second_take_over {
            return Err(Refused::Taken);
        }
        if model.read_pending && !flaws.ignore_pending_read {
            return Err(Refused::ReadPending);
        }
        model.taken = true;
        state.record.taken.push(child);
        drop(state);
        Ok(Box::new(Taken {
            source: self.clone(),
            child,
        }))
    }
}

/// A child of the fake's, taken over.
struct Taken {
    /// The fake.
    source: FakeSource,
    /// The child's number.
    child: u64,
}

impl ChildStreams for Taken {
    fn pull(&self) -> Pulled {
        self.source.pull(self.child)
    }

    fn write(&self, bytes: Vec<u8>) -> Result<(), InputClosed> {
        self.source.write(self.child, bytes)
    }
}

/// A child of the fake's, as the test steps it. Each step returns the
/// child, so steps chain.
#[derive(Debug, Clone)]
pub struct FakeChild {
    /// The fake.
    source: FakeSource,
    /// Its number.
    id: u64,
}

impl FakeChild {
    /// Its number, which a take-over names.
    pub const fn id(&self) -> u64 {
        self.id
    }

    /// Writes `bytes` to its standard output.
    pub fn out(&self, bytes: impl Into<Vec<u8>>) -> &Self {
        self.queue(Step::Write(Stream::Out, bytes.into()))
    }

    /// Writes `bytes` to its standard error.
    pub fn err(&self, bytes: impl Into<Vec<u8>>) -> &Self {
        self.queue(Step::Write(Stream::Err, bytes.into()))
    }

    /// Waits for one line of its input, `\n` included, and writes `reply`
    /// to its standard output if it is `line`. The steps after it wait for
    /// it.
    pub fn on_line(&self, line: impl Into<Vec<u8>>, reply: impl Into<Vec<u8>>) -> &Self {
        self.queue(Step::OnLine(line.into(), reply.into()))
    }

    /// Exits with `code`: its streams close once their pipes are drained.
    pub fn exit(&self, code: i32) -> &Self {
        self.queue(Step::End(Ended::Exited { code }))
    }

    /// Is ended by the signal `signal`.
    pub fn signal(&self, signal: i32) -> &Self {
        self.queue(Step::End(Ended::Signalled { signal }))
    }

    /// The job's read of it is pending: a take-over is refused.
    pub fn pend_read(&self) -> &Self {
        self.source.step(self.id, |model| model.read_pending = true);
        self
    }

    /// The job's read of it is withdrawn.
    pub fn withdraw_read(&self) -> &Self {
        self.source
            .step(self.id, |model| model.read_pending = false);
        self
    }

    /// Cancels it, as the job's end does: a pull answers cancelled, and a
    /// take-over is refused.
    pub fn cancel(&self) -> &Self {
        self.source.step(self.id, |model| {
            model.gone = true;
            model.fail(Ended::Signalled { signal: 9 });
        });
        self
    }

    /// Whether it is held: a pipe holds bytes the bound leaves no room for.
    pub fn held(&self) -> bool {
        self.source
            .state()
            .children
            .get(&self.id)
            .is_some_and(Model::held)
    }

    /// Queues `step` and takes the child as far as it can go.
    fn queue(&self, step: Step) -> &Self {
        self.source
            .step(self.id, |model| model.steps.push_back(step));
        self
    }
}

/// hang guard: nothing of the fake's blocks, so only a contract that waits
/// on something that never comes reaches it, and the property then fails
/// as a hang.
const FAKE_DEADLINE: HangGuard = HangGuard::on(
    "a pull's return or a park on the bound, which the fake answers at once",
    Duration::from_secs(5),
);

impl FakeSource {
    /// The child the contract's `scenario` needs, stepped as far as it
    /// goes until the consumer acts.
    fn scenario(&self, scenario: Scenario) -> FakeChild {
        let shape = scenario.shape();
        let child = self.child(shape.out, shape.err, shape.bound, shape.input);
        for step in scenario_steps(scenario) {
            child.queue(step);
        }
        child
    }
}

/// What the child of `scenario` does, as the contract says.
fn scenario_steps(scenario: Scenario) -> Vec<Step> {
    let out = |bytes: &[u8]| Step::Write(Stream::Out, bytes.to_vec());
    let exit = |code| Step::End(Ended::Exited { code });
    match scenario {
        Scenario::Echo => vec![
            out(b"one\n"),
            Step::OnLine(b"pong\n".to_vec(), b"got pong\n".to_vec()),
            exit(3),
        ],
        Scenario::Numbered => vec![out(&super::contract::numbered()), exit(0)],
        Scenario::Megabytes => vec![out(&super::contract::megabyte_line()), exit(0)],
        Scenario::OneLine => vec![out(b"taken\n"), exit(0)],
        Scenario::AwaitsLine => vec![Step::OnLine(b"go\n".to_vec(), b"go\n".to_vec()), exit(0)],
        Scenario::Messages => {
            let mut steps: Vec<Step> = super::contract::MESSAGES_WRITTEN
                .iter()
                .map(|chunk| out(chunk))
                .collect();
            steps.push(exit(0));
            steps
        }
        Scenario::MessageAtBound => vec![out(super::contract::AT_BOUND_MESSAGE), exit(0)],
        Scenario::MessageTooLong => super::contract::TOO_LONG_WRITTEN
            .iter()
            .map(|chunk| out(chunk))
            .collect(),
        Scenario::MessageMalformed => super::contract::MALFORMED_WRITTEN
            .iter()
            .map(|chunk| out(chunk))
            .collect(),
    }
}

impl Ground for FakeSource {
    fn source(&self) -> &dyn StreamSource {
        self
    }

    fn open(&self, scenario: Scenario) -> Option<u64> {
        Some(self.scenario(scenario).id)
    }

    fn wait_held(&self, child: u64) -> bool {
        FakeChild {
            source: self.clone(),
            id: child,
        }
        .held()
    }

    fn pend_read(&self, child: u64) -> bool {
        let mut state = self.state();
        let Some(model) = state.children.get_mut(&child).filter(|model| !model.gone) else {
            return false;
        };
        model.read_pending = true;
        true
    }

    fn withdraw_read(&self, child: u64) {
        if let Some(model) = self.state().children.get_mut(&child) {
            model.read_pending = false;
        }
    }

    fn deadline(&self) -> HangGuard {
        FAKE_DEADLINE
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(lines: &[&str]) -> Frames {
        Frames::Lines(lines.iter().map(|line| line.as_bytes().to_vec()).collect())
    }

    fn delivered(out: Frames, err: Frames, ended: Option<Ended>) -> Pulled {
        Pulled::Delivered(Delivery { out, err, ended })
    }

    #[test]
    fn a_child_stepped_to_its_end_is_pulled_whole_then_forgotten() {
        let fake = FakeSource::new();
        let child = fake.child(Framing::Lines, Framing::Lines, 64, false);
        child.out(b"one\ntw").err(b"e\n").out(b"o\n").exit(2);
        let streams = fake.take_over(child.id()).expect("taken");

        assert_eq!(
            streams.pull(),
            delivered(
                lines(&["one", "two"]),
                lines(&["e"]),
                Some(Ended::Exited { code: 2 })
            )
        );
        assert_eq!(streams.pull(), Pulled::Cancelled, "nothing more comes");
        assert_eq!(fake.take_over(child.id()).err(), Some(Refused::NoSuchChild));
        assert_eq!(fake.record().taken, [child.id()]);
    }

    #[test]
    fn output_past_the_bound_is_held_in_its_pipe_and_enters_as_a_pull_makes_room() {
        let fake = FakeSource::new();
        let child = fake.child(Framing::Lines, Framing::Lines, 4, false);
        child.out(b"ab\ncd\nef\n").exit(0);
        assert!(child.held());
        let streams = fake.take_over(child.id()).expect("taken");

        let mut got = Vec::new();
        let ended = loop {
            let Pulled::Delivered(delivery) = streams.pull() else {
                panic!("a delivery");
            };
            let Frames::Lines(out) = delivery.out else {
                panic!("lines");
            };
            got.extend(out);
            if let Some(ended) = delivery.ended {
                break ended;
            }
        };

        assert_eq!(got, [b"ab".to_vec(), b"cd".to_vec(), b"ef".to_vec()]);
        assert_eq!(ended, Ended::Exited { code: 0 });
        assert!(!child.held());
    }

    #[test]
    fn a_line_answered_is_written_once_the_consumer_writes_it_and_the_steps_after_it_wait() {
        let fake = FakeSource::new();
        let child = fake.child(Framing::Lines, Framing::Lines, 64, true);
        child.out(b"one\n").on_line(b"ping\n", b"pong\n").exit(1);
        let streams = fake.take_over(child.id()).expect("taken");

        assert_eq!(streams.pull(), delivered(lines(&["one"]), lines(&[]), None));
        assert_eq!(streams.write(b"ping\n".to_vec()), Ok(()));
        assert_eq!(
            streams.pull(),
            delivered(
                lines(&["pong"]),
                lines(&[]),
                Some(Ended::Exited { code: 1 })
            )
        );
        assert_eq!(fake.record().written, [(child.id(), b"ping\n".to_vec())]);
    }

    #[test]
    fn a_write_to_a_child_with_no_input_or_one_that_ended_is_input_closed() {
        let fake = FakeSource::new();
        let closed = fake.child(Framing::Lines, Framing::Lines, 64, false);
        let ended = fake.child(Framing::Lines, Framing::Lines, 64, true);
        ended.exit(0);

        for child in [&closed, &ended] {
            let streams = fake.take_over(child.id()).expect("taken");
            assert!(streams.write(b"x".to_vec()).is_err());
        }
    }

    #[test]
    fn a_pending_read_a_second_take_over_and_a_cancel_are_refused_and_a_cancel_answers_cancelled() {
        let fake = FakeSource::new();
        let child = fake.child(Framing::Lines, Framing::Lines, 64, false);
        child.pend_read();
        assert_eq!(fake.take_over(child.id()).err(), Some(Refused::ReadPending));
        child.withdraw_read();
        let streams = fake.take_over(child.id()).expect("taken");
        assert_eq!(fake.take_over(child.id()).err(), Some(Refused::Taken));

        child.cancel();

        assert_eq!(streams.pull(), Pulled::Cancelled);
        assert_eq!(fake.take_over(child.id()).err(), Some(Refused::NoSuchChild));
        assert_eq!(fake.take_over(99).err(), Some(Refused::NoSuchChild));
    }

    #[test]
    #[should_panic(expected = "pull with nothing to deliver: step the fake first")]
    fn a_pull_with_nothing_to_deliver_panics_and_never_blocks() {
        let fake = FakeSource::new();
        let child = fake.child(Framing::Lines, Framing::Lines, 64, false);
        let streams = fake.take_over(child.id()).expect("taken");
        let _ = streams.pull();
    }

    #[test]
    fn a_line_that_fills_the_bound_is_too_long_once_more_comes_and_the_last_line_if_none_does() {
        let fake = FakeSource::new();
        let long = fake.child(Framing::Lines, Framing::Lines, 4, false);
        long.out(b"abcd").out(b"e\n").exit(0);
        let last = fake.child(Framing::Lines, Framing::Lines, 4, false);
        last.out(b"abcd").exit(0);

        assert_eq!(
            fake.take_over(long.id()).expect("taken").pull(),
            delivered(
                lines(&[]),
                lines(&[]),
                Some(Ended::LineTooLong {
                    stream: Stream::Out,
                    bound: 4
                })
            )
        );
        assert_eq!(
            fake.take_over(last.id()).expect("taken").pull(),
            delivered(
                lines(&["abcd"]),
                lines(&[]),
                Some(Ended::Exited { code: 0 })
            )
        );
    }

    #[test]
    fn a_message_too_long_ends_the_child_with_the_rest_of_its_pipe_unread() {
        let fake = FakeSource::new();
        let child = fake.child(Framing::ContentLength, Framing::Lines, 64, true);
        child
            .out(b"Content-Length: 2\r\n\r\nok")
            .out(b"Content-Length: 100\r\n\r\n")
            .out(vec![b'x'; 100]);

        assert_eq!(
            fake.take_over(child.id()).expect("taken").pull(),
            delivered(
                Frames::Messages(vec![b"ok".to_vec()]),
                lines(&[]),
                Some(Ended::MessageTooLong {
                    stream: Stream::Out,
                    bound: 64
                })
            )
        );
    }
}
