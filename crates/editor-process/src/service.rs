//! The service above the port: runs to their end, and streaming children,
//! owned from spawn to reap.
//!
//! [`Service`] is what the editor asks for a process. A run is started
//! with an id the caller chose ([`Service::start`]) and returns at once;
//! its thread does the rest and, when the run has come to something,
//! keeps the result under the id and calls the `complete` closure the
//! service was made with. The caller takes the result once
//! ([`Service::take`]). A streaming child ([`Service::open`]) is the same
//! shape, a request at a time: each open, read, write and close is a wait
//! with an id of the caller's, completed once, whose reply is taken once
//! ([`Service::take_stream`]).
//!
//! # A streaming child
//!
//! [`Service::open`] starts a command with [`Streaming`]: whether its
//! standard input is a pipe, how each output stream is framed (as lines or
//! as bytes, [`Framing`]), and its bound. The child's thread, its waiter,
//! refuses what a run refuses and a bound of 0, spawns, takes both outputs
//! and the input, registers the child, keeps [`StreamReply::Opened`] under
//! the child's id and completes it; then it starts a reader for each
//! stream and a writer for the input, waits for the child, which reaps it,
//! and records the exit. The child is named by the open's id from then on.
//!
//! - **A read** ([`Service::read`]) is a pull. It is completed at once if
//!   something is deliverable, or the child has ended; otherwise the first
//!   reader that makes something deliverable completes it. **A completion
//!   is queued only while the pending read's completion has not been
//!   queued yet**, and a second read while one is pending is refused: so
//!   there is one completion for each read, never one for each chunk,
//!   however fast the child writes. A completion-queue turn ends at most
//!   one wait, so a job gets at most one delivery a turn. The delivery is
//!   drained when it is taken, not when it was completed: it holds every
//!   frame of both streams read up to the take.
//! - **The bound** is how many bytes of each stream may have been read and
//!   not yet taken, a line in progress among them. A reader reads at most
//!   the room the bound leaves; at none it parks and reads nothing more,
//!   so the kernel pipe fills and the child blocks in `write(2)`: it is
//!   **held**. A take makes room and wakes it. Nothing is dropped, and no
//!   delivery says the child was held ([`Service::held`] is a readout for
//!   tests). The bound counts each stream on its own, so a reader blocked
//!   on a stream the child does not write takes nothing from the other's
//!   room.
//! - **A line longer than the bound**, its line feed counted, can never be
//!   delivered whole. It ends the child: the group is killed, and the last
//!   delivery ends with [`End::LineTooLong`], the frames before it intact.
//!   A partial line that fills the bound exactly is not yet too long: the
//!   reader reads one byte more, kept outside the bound, and the line is
//!   too long only if that byte comes. If the stream ends there instead,
//!   the line is its last, delivered whole. A read that fails ends the
//!   child as a line too long does, with [`End::Failed`].
//! - **The last delivery** says how the child ended ([`Delivery::ended`]):
//!   [`End::Exited`] once both streams have ended, every frame is in it and
//!   the child has been reaped. The service then forgets the child: a
//!   later read of it is refused.
//! - **A write** ([`Service::write`]) is handed to the writer, which writes
//!   every byte, then keeps [`StreamReply::Written`] and completes it; a
//!   child that closed its input, or ended, is a refusal as
//!   [`RefusalKind::InputClosed`]. A child with no input, or one the job
//!   closed, is refused at once. Nothing is buffered beyond the pipe, so a
//!   write's reply is the truth about delivery. **A close**
//!   ([`Service::close_input`]) is completed at once, and the writer drops
//!   the input behind any write in flight.
//! - **Cancelling** a streaming child kills its group, stops its readers
//!   (a parked one returns without another read) and its writer, and drops
//!   its waits and kept replies without completing them; it is over once
//!   its child is reaped. A pending read is dropped with its wait, in one
//!   step under the state lock and before the kill, so no reader or waiter
//!   completes it afterwards, even one already inside a read when the kill
//!   lands. Cancelling a pending read or write drops that wait alone: the
//!   child keeps running and keeps what it wrote.
//! - **Shutdown** cancels every streaming child as it does every run, its
//!   pending read dropped with its waits as a cancel drops it, and waits
//!   for every waiter. It waits for no reader and no writer.
//!
//! So each streaming child has four threads: its waiter, two readers, and
//! a writer when its input is piped. A reader blocked in `read(2)` on a
//! stream that a process outside the group holds, and a writer blocked in
//! `write(2)` on an input such a process holds and does not read, are left
//! detached, as a run's readers are.
//!
//! # A run
//!
//! The run's thread:
//!
//! 1. refuses a directory that is not absolute, or a program that names a
//!    directory without being absolute ([`refusal_before_spawn`]), before
//!    any spawn;
//! 2. spawns the command, its standard input closed: a run's child has no
//!    input, so one that reads it reads its end at once. A run started
//!    with input ([`Service::start_with_input`]) has a pipe instead, and a
//!    writer thread writes every byte to it and then drops it, so the
//!    child reads the input and then its end. A write the child does not
//!    take, because it closed its input or ended, is ignored: the run
//!    comes to what the child did. A refusal of the spawn is the run's
//!    result;
//! 3. takes both streams and starts a reader thread for each, which keeps
//!    up to `limit` bytes; a stream with more than that kills the group,
//!    and the run comes to [`RunResult::OutputTooLarge`], never to output
//!    cut short; except for standard output of a run that keeps its head
//!    ([`Service::start_head`]), whose reader, once the stream goes past
//!    `limit` bytes, keeps exactly the first `limit`, kills the group, and
//!    the run comes to [`RunResult::Cut`] with them and what was read of
//!    standard error;
//! 4. waits for the child, which ends what is left of its group and reaps
//!    it ([`Child::wait`]);
//! 5. waits for both readers to reach their stream's end, so the streams
//!    are whole before the result is kept; unless the run is cancelled, or
//!    the service shuts down, first: then it stops waiting for them;
//! 6. keeps the result and completes the run, unless it was cancelled.
//!
//! A read that fails kills the group too, and its refusal is the run's
//! result. Nothing of a run panics into its caller.
//!
//! So each running child has three threads: the run's, which waits, and
//! one reader for each stream; and a fourth, its writer, when it is fed.
//! The writer is detached, as the readers are: it writes while the
//! readers read, so input larger than a pipe cannot hold a child that
//! writes as it reads, and it ends once its bytes are written or refused.
//!
//! # A stream held open after the reap
//!
//! A stream closes once every process that holds it has ended. The group
//! kill ends the child and what is still in its group, but a process the
//! child started that left the group (`setsid`, `setpgid`) and kept the
//! stream holds it open after the child has been reaped. A run to its end
//! then waits for that process to close it, which is what keeps its output
//! whole. A cancelled run does not: it is over once its child is reaped,
//! and its readers are left behind, each holding only its stream's read
//! end, to end when the stream closes. The escaped process itself is not
//! ended: no portable mechanism reaches it. A streaming child's writer
//! blocked in `write(2)` because such a process holds its input without
//! reading is left the same way, holding only the input's write end.
//!
//! # The rules
//!
//! - **An id in use is refused**: one whose run has not ended, a cancelled
//!   one whose child is not yet reaped among them, and one whose result has
//!   not been taken. [`Service::start`] then returns false and starts
//!   nothing, as it does when the system refuses the run its thread.
//! - **One completion for each run**, after its result is kept. A cancelled
//!   run is never completed.
//! - **Cancelling** ([`Service::cancel`]) kills the child's group if the
//!   child is running, and marks the run cancelled: its result is dropped.
//!   A cancel that comes between the spawn and the run's registering its
//!   child is seen by the run's thread, under the state lock, and the
//!   thread kills the child it has just made. A kept result is dropped. It
//!   is safe for any id. A completion the closure queued before the cancel
//!   is the caller's to ignore.
//! - **Shutdown** ([`Service::shutdown`]) refuses every later start, which
//!   then comes to [`RefusalKind::ShutDown`] and is completed at once;
//!   cancels every run, killing every child's group; drops every kept
//!   result; and blocks until every run's wait has returned, so every
//!   child it started has been reaped and its group killed. It does not
//!   wait for a stream to close, so a process that left a child's group
//!   and holds its stream cannot hold shutdown. It is idempotent.
//! - **An id in use** is one of a run's, a streaming child's or a wait's:
//!   an open, a read, a write or a close naming it as its own id is
//!   refused, as a start is.
//! - **A flush is a barrier** ([`Service::flush`]): a wait of the
//!   caller's, completed once every run started before it has ended (its
//!   result kept, or cancelled and its child reaped), every open asked
//!   before it answered, and every streaming child cancelled or forgotten
//!   before it reaped; at once, on the caller's thread, when there is
//!   nothing to wait for. A run's thread, after its own completion, and a
//!   streaming child's waiter, once its child is reaped, completes each
//!   flush it was the last thing for, in the order they were asked;
//!   shutdown completes the rest once every child is reaped. A live
//!   streaming child, its pending read and a write held by a full pipe are
//!   not covered: they wait on the child, not on the service, and would
//!   never let a flush complete. A flush keeps no reply, its id is in use
//!   while it waits, and a cancel withdraws it.
//! - **[`Service::pending`]** counts the runs and the streaming children
//!   not over, a cancelled one being over once its child is reaped, the
//!   results not taken, and the waits on streaming children not answered
//!   or not taken, and the flushes waiting: a readout for tests. A test
//!   that needs the service to have finished waits on a flush.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread;

use crate::frame::{Frames, Framing, Outbox};
use crate::{
    Child, ChildInput, Command, Exit, Input, Output, Processes, Refusal, RefusalKind, Stream,
    refusal_before_spawn,
};

/// What a run came to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RunResult {
    /// The child ran to its end: how it ended, and every byte of each
    /// stream.
    Ran {
        /// How it ended.
        exit: Exit,
        /// Its standard output.
        stdout: Vec<u8>,
        /// Its standard error.
        stderr: Vec<u8>,
    },
    /// The run was refused, before or at its spawn, or a stream could not
    /// be read.
    Refused(Refusal),
    /// A stream had more than the run's limit of bytes, and the group was
    /// killed.
    OutputTooLarge {
        /// The stream.
        stream: Stream,
        /// The limit, in bytes.
        limit: u64,
    },
    /// A run that keeps its head ([`Service::start_head`]): standard output
    /// went past the run's limit, and the group was killed. Output of
    /// exactly `limit` bytes is not cut: the run comes to
    /// [`RunResult::Ran`]. How the child ended is not said: the service
    /// ended it.
    Cut {
        /// The first `limit` bytes of its standard output, exactly.
        stdout: Vec<u8>,
        /// Its standard error, as far as it was read before the group was
        /// killed.
        stderr: Vec<u8>,
    },
}

/// How a streaming child is started: its input, how each output stream
/// reaches its job, and its bound.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Streaming {
    /// Its standard input: closed, or a pipe the job writes to. A
    /// [`Command`] carries none: a streaming child's input is chosen here,
    /// and a run's by whether it is fed ([`Service::start_with_input`]).
    pub input: Input,
    /// How its standard output is framed.
    pub out: Framing,
    /// How its standard error is framed.
    pub err: Framing,
    /// How many bytes of each stream may be read and not yet taken: at
    /// least one.
    pub bound: u64,
}

/// What a read of a streaming child takes: every frame of both streams
/// read and not yet taken, and, in the last one, how the child ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Delivery {
    /// Its standard output's frames.
    pub out: Frames,
    /// Its standard error's frames.
    pub err: Frames,
    /// How it ended, in its last delivery only.
    pub ended: Option<End>,
}

/// How a streaming child ended, as its last delivery says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum End {
    /// Both streams reached their end, every frame was delivered and the
    /// child was reaped: how it exited.
    Exited(Exit),
    /// A line of this stream was longer than the bound, so could never be
    /// delivered whole, and the group was killed.
    LineTooLong {
        /// The stream.
        stream: Stream,
        /// The bound, in bytes.
        bound: u64,
    },
    /// A read failed, and the group was killed.
    Failed(Refusal),
}

/// A reply to a request about a streaming child.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StreamReply {
    /// The child was started.
    Opened,
    /// The request was refused.
    Refused(Refusal),
    /// A read's delivery.
    Delivered(Delivery),
    /// The bytes are in the child's standard input, or it was closed.
    Written,
}

/// A streaming child's streams, input and pending read, shared between
/// the service, its waiter, its readers and its writer.
struct StreamState {
    /// What they share.
    state: Mutex<Streamed>,
    /// Told when a reader may go on, when there is work for the writer,
    /// and when the child is abandoned.
    changed: Condvar,
}

/// What [`StreamState`] holds.
struct Streamed {
    /// Its program, which a refusal of its input names.
    program: String,
    /// What has been read and not yet taken, framed.
    outbox: Outbox,
    /// How it exited, once its waiter has reaped it.
    exit: Option<Exit>,
    /// What ended it before its streams did: a line too long, or a read
    /// that failed.
    failed: Option<End>,
    /// The pending read's wait, and whether its completion was queued.
    read: Option<(u64, bool)>,
    /// The write waiting for the writer: its wait and its bytes.
    write: Option<(u64, Vec<u8>)>,
    /// Whether the job has asked for its input to be closed.
    closing: bool,
    /// Whether it has an input that is open: false when none was asked
    /// for, the job closed it, or the child did.
    input: bool,
    /// Whether it was cancelled: its readers and writer stop.
    abandoned: bool,
    /// Whether each reader, out then err, is parked on the bound.
    parked: [bool; 2],
}

impl StreamState {
    /// Locks what they share. The lock is never held while other code
    /// runs.
    fn state(&self) -> MutexGuard<'_, Streamed> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Stops its readers and its writer, and drops its pending read: an
    /// abandoned stream has no pending read, so no reader or waiter can
    /// complete one after this. It takes only the stream's own lock, so it
    /// is atomic with nothing else by itself: cancel and shutdown call it
    /// under the service's state lock, in the same step that drops the
    /// child's waits, and before the kill, and that is what drops a
    /// pending read with its wait. A caller with no pending read to drop
    /// may call it anywhere.
    fn abandon(&self) {
        let mut streamed = self.state();
        streamed.abandoned = true;
        streamed.read = None;
        drop(streamed);
        self.changed.notify_all();
    }
}

impl Streamed {
    /// How it ended, once nothing more can be delivered: a failure, or
    /// both streams at their end with the child reaped.
    fn end(&self) -> Option<End> {
        if let Some(failed) = &self.failed {
            return Some(failed.clone());
        }
        (self.outbox.ended())
            .then_some(self.exit)
            .flatten()
            .map(End::Exited)
    }

    /// The pending read to complete now, if its completion is not queued
    /// yet and it has an answer: something deliverable, or the end. This is
    /// the coalescing rule: one completion for each read, never one for
    /// each chunk.
    fn wake(&mut self) -> Option<u64> {
        let answered = self.outbox.deliverable() || self.end().is_some();
        match &mut self.read {
            Some((wait, queued)) if !*queued && answered => {
                *queued = true;
                Some(*wait)
            }
            _ => None,
        }
    }
}

/// Where a run is.
enum Run<C> {
    /// Its thread is spawning its child. `cancelled` is for its thread to
    /// see once the child is made.
    Starting {
        /// Whether it has been cancelled.
        cancelled: bool,
    },
    /// Its child is running, or its wait has not yet returned, or its
    /// streams have not reached their end.
    Running {
        /// The child.
        child: Arc<C>,
        /// What its readers have read, which a cancel stops it waiting for.
        reads: Arc<Reads>,
        /// Whether it has been cancelled.
        cancelled: bool,
    },
    /// It came to this, which has not been taken.
    Kept(RunResult),
    /// A streaming child, from its registering until its last delivery has
    /// been taken, or until it is cancelled and reaped.
    Streaming {
        /// The child.
        child: Arc<C>,
        /// Its streams, its input and its pending read.
        stream: Arc<StreamState>,
        /// Whether it has been cancelled, or forgotten after its last
        /// delivery: it takes no more requests.
        cancelled: bool,
        /// Whether its waiter has finished: its child has been reaped.
        reaped: bool,
    },
}

/// A wait on a streaming child: a read or a write not yet answered, or a
/// reply not yet taken.
enum Wait {
    /// A read of this child.
    Reading(u64),
    /// A write to, or a close of, this child's input.
    Writing(u64),
    /// This reply, kept.
    Kept(StreamReply),
    /// A flush ([`Service::flush`]), the `order`th asked, waiting for the
    /// runs and children `awaited` to be done.
    Flush {
        /// How many flushes were asked before it.
        order: u64,
        /// The runs and children it still waits for.
        awaited: HashSet<u64>,
    },
}

/// What the service holds.
struct State<C> {
    /// Whether it has shut down.
    shut: bool,
    /// Each run not yet over, by its id.
    runs: HashMap<u64, Run<C>>,
    /// Each wait on a streaming child, by its id, an open's among them.
    waits: HashMap<u64, Wait>,
    /// How many runs' threads have not finished.
    active: usize,
    /// How many flushes have been asked: the next one's order.
    flushes: u64,
}

impl<C> State<C> {
    /// Whether `id` names a run, a child or a wait.
    fn in_use(&self, id: u64) -> bool {
        self.runs.contains_key(&id) || self.waits.contains_key(&id)
    }

    /// Marks the run or child `id` done for every flush, and removes and
    /// returns the flushes it was the last thing for, in the order they
    /// were asked: for the caller to complete with no lock held.
    fn settle(&mut self, id: u64) -> Vec<u64> {
        let mut done = Vec::new();
        for (&wait, kept) in &mut self.waits {
            if let Wait::Flush { order, awaited } = kept
                && awaited.remove(&id)
                && awaited.is_empty()
            {
                done.push((*order, wait));
            }
        }
        self.take_flushes(done)
    }

    /// Removes the flushes `done`, each with its order, and returns their
    /// ids in that order.
    fn take_flushes(&mut self, mut done: Vec<(u64, u64)>) -> Vec<u64> {
        done.sort_unstable();
        done.into_iter()
            .map(|(_, wait)| {
                self.waits.remove(&wait);
                wait
            })
            .collect()
    }

    /// Removes and returns every flush waiting, in the order they were
    /// asked.
    fn take_every_flush(&mut self) -> Vec<u64> {
        let every = self
            .waits
            .iter()
            .filter_map(|(&wait, kept)| match kept {
                Wait::Flush { order, .. } => Some((*order, wait)),
                _ => None,
            })
            .collect();
        self.take_flushes(every)
    }
}

/// What a service's handles and its runs' threads share.
struct Inner<P: Processes> {
    /// What starts the children.
    processes: P,
    /// What is called with a run's id when its result is kept.
    complete: Box<dyn Fn(u64) + Send + Sync>,
    /// The state. The lock is never held while a child is waited for, a
    /// stream read, or the closure called.
    state: Mutex<State<P::Child>>,
    /// Told whenever a run's thread finishes.
    finished: Condvar,
}

/// The process service over `P`. A cheap handle: clones share one service.
pub struct Service<P: Processes + 'static> {
    /// What its handles share.
    inner: Arc<Inner<P>>,
}

impl<P: Processes + 'static> Clone for Service<P> {
    fn clone(&self) -> Self {
        Self {
            inner: Arc::clone(&self.inner),
        }
    }
}

/// How one stream's reading ended.
enum Read {
    /// Every byte, the stream having closed.
    Whole(Vec<u8>),
    /// More than the limit.
    TooLarge,
    /// More than the limit, of a stream whose head is kept: its first
    /// `limit` bytes.
    Cut(Vec<u8>),
    /// A read failed.
    Failed(Refusal),
}

/// What a reader does with a stream past the run's limit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Overflow {
    /// Refuses it: the run comes to [`RunResult::OutputTooLarge`].
    Refuse,
    /// Keeps its first `limit` bytes: the run comes to [`RunResult::Cut`].
    Keep,
}

/// What a run's two readers have read, shared between them and the run.
#[derive(Default)]
struct Reads {
    /// The readings, and whether the run still waits for them.
    state: Mutex<Readings>,
    /// Told when a reading ends, and when the run stops waiting.
    changed: Condvar,
}

/// What [`Reads`] holds.
#[derive(Default)]
struct Readings {
    /// How each stream's reading ended, out then err, once it has.
    read: [Option<Read>; 2],
    /// Whether the run has stopped waiting: it was cancelled.
    abandoned: bool,
}

impl Reads {
    /// Locks the readings. The lock is never held while other code runs.
    fn state(&self) -> MutexGuard<'_, Readings> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Hands over how the reading of the stream in `slot` ended.
    fn deliver(&self, slot: usize, read: Read) {
        self.state().read[slot] = Some(read);
        self.changed.notify_all();
    }

    /// Stops the run waiting for its readers.
    fn abandon(&self) {
        self.state().abandoned = true;
        self.changed.notify_all();
    }

    /// Both readings, once both have ended; `None` if the run stops
    /// waiting first.
    fn wait(&self) -> Option<[Read; 2]> {
        let mut state = self
            .changed
            .wait_while(self.state(), |state| {
                !state.abandoned && state.read.iter().any(Option::is_none)
            })
            .unwrap_or_else(PoisonError::into_inner);
        match &mut state.read {
            [out @ Some(_), err @ Some(_)] => Some([out.take()?, err.take()?]),
            _ => None,
        }
    }
}

/// A reader's hand-over: how its reading ended reaches the run when it is
/// dropped, as a failure if the reader panicked before it ended.
struct HandOver {
    /// Where it goes.
    reads: Arc<Reads>,
    /// Which stream, out (0) or err (1).
    slot: usize,
    /// How the reading ended, once it has.
    read: Option<Read>,
}

impl Drop for HandOver {
    fn drop(&mut self) {
        let read = self.read.take().unwrap_or_else(|| {
            Read::Failed(Refusal::new(
                RefusalKind::Failed,
                "a stream's reader panicked",
            ))
        });
        self.reads.deliver(self.slot, read);
    }
}

impl<P: Processes + 'static> Service<P> {
    /// A service that starts children with `processes` and calls `complete`
    /// with an id when its reply is kept: a run's id, whose result
    /// [`take`](Self::take) collects; or an open's id, or the wait id of a
    /// read, a write or a close of a streaming child's input, whose reply
    /// [`take_stream`](Self::take_stream) collects.
    pub fn new(processes: P, complete: impl Fn(u64) + Send + Sync + 'static) -> Self {
        Self {
            inner: Arc::new(Inner {
                processes,
                complete: Box::new(complete),
                state: Mutex::new(State {
                    shut: false,
                    runs: HashMap::new(),
                    waits: HashMap::new(),
                    active: 0,
                    flushes: 0,
                }),
                finished: Condvar::new(),
            }),
        }
    }

    /// What starts the children.
    pub fn processes(&self) -> &P {
        &self.inner.processes
    }

    /// Starts `command` as the run `id`, whose streams may each hold up to
    /// `limit` bytes, and returns at once. False, starting nothing, for an
    /// id in use, or when the system refuses the run its thread. After
    /// shutdown the run is accepted, comes to [`RefusalKind::ShutDown`] and
    /// is completed at once.
    pub fn start(&self, id: u64, command: Command, limit: u64) -> bool {
        self.start_with_input(id, command, None, limit)
    }

    /// Starts `command` as the run `id`, as [`start`](Self::start) does,
    /// fed `input`: with some, the child's standard input is a pipe that a
    /// thread of the run's writes the bytes to and then closes, while the
    /// run reads the child's output ("A run", in the module docs); with
    /// none, its input is closed. A write the child does not take is no
    /// refusal: the run comes to what the child did.
    pub fn start_with_input(
        &self,
        id: u64,
        command: Command,
        input: Option<Vec<u8>>,
        limit: u64,
    ) -> bool {
        self.begin(id, command, input, limit, Overflow::Refuse)
    }

    /// Starts `command` as the run `id`, fed `input`, as
    /// [`start_with_input`](Self::start_with_input) does, keeping the head
    /// of its standard output: once it goes past `limit` bytes the group is
    /// killed and the run comes to [`RunResult::Cut`] with exactly its first
    /// `limit` bytes. Standard error keeps the usual rule, and a run whose
    /// output stays within the limit, exactly `limit` bytes among it, comes
    /// to [`RunResult::Ran`].
    pub fn start_head(
        &self,
        id: u64,
        command: Command,
        input: Option<Vec<u8>>,
        limit: u64,
    ) -> bool {
        self.begin(id, command, input, limit, Overflow::Keep)
    }

    /// Starts a run, its standard output past `limit` handled as `overflow`
    /// says.
    fn begin(
        &self,
        id: u64,
        command: Command,
        input: Option<Vec<u8>>,
        limit: u64,
        overflow: Overflow,
    ) -> bool {
        let command = command.without_app_identity();
        let mut state = self.inner.state();
        if state.in_use(id) {
            return false;
        }
        if state.shut {
            state.runs.insert(
                id,
                Run::Kept(RunResult::Refused(Refusal::new(
                    RefusalKind::ShutDown,
                    format!(
                        "cannot start `{}` in {}: the process service has shut down",
                        command.program,
                        command.directory.display()
                    ),
                ))),
            );
            drop(state);
            (self.inner.complete)(id);
            return true;
        }
        state.runs.insert(id, Run::Starting { cancelled: false });
        state.active += 1;
        drop(state);
        let inner = Arc::clone(&self.inner);
        let started = thread::Builder::new()
            .name("editor-process".into())
            .spawn(move || inner.run(id, &command, input, limit, overflow))
            .is_ok();
        if !started {
            let mut state = self.inner.state();
            state.runs.remove(&id);
            state.active -= 1;
            let flushed = state.settle(id);
            drop(state);
            self.inner.finished.notify_all();
            self.inner.complete_all(flushed);
        }
        started
    }

    /// The result of the run `id`, once: `None` while it runs, once it was
    /// taken, and for an id the service does not know.
    pub fn take(&self, id: u64) -> Option<RunResult> {
        let mut state = self.inner.state();
        match state.runs.remove(&id) {
            Some(Run::Kept(result)) => Some(result),
            Some(run) => {
                state.runs.insert(id, run);
                None
            }
            None => None,
        }
    }

    /// Cancels the run, the streaming child or the wait `id`, and says
    /// whether there was anything to cancel: a run or a child not over, a
    /// wait not answered, or a result or a reply not taken.
    pub fn cancel(&self, id: u64) -> bool {
        let mut state = self.inner.state();
        let child = match state.runs.get_mut(&id) {
            None => return Self::cancel_wait(&mut state, id),
            Some(Run::Kept(_)) => {
                state.runs.remove(&id);
                return true;
            }
            Some(Run::Starting { cancelled }) => {
                *cancelled = true;
                return true;
            }
            Some(Run::Running {
                child,
                reads,
                cancelled,
            }) => {
                *cancelled = true;
                (Arc::clone(child), Arc::clone(reads))
            }
            Some(Run::Streaming {
                child,
                stream,
                cancelled,
                reaped,
            }) => {
                *cancelled = true;
                let (child, stream, reaped) = (Arc::clone(child), Arc::clone(stream), *reaped);
                if reaped {
                    state.runs.remove(&id);
                }
                // Its waits are dropped, never completed: the open's reply,
                // a pending read and a pending write among them. The
                // stream's own record of the pending read goes in the same
                // step, so no reader or waiter finds it to complete.
                state.waits.retain(|&wait, kept| {
                    wait != id
                        && !matches!(kept, Wait::Reading(of) | Wait::Writing(of) if *of == id)
                });
                stream.abandon();
                drop(state);
                child.kill();
                return true;
            }
        };
        drop(state);
        let (child, reads) = child;
        child.kill();
        reads.abandon();
        true
    }

    /// Refuses every later start, cancels every run, killing each child's
    /// group, drops every kept result, and returns once every child the
    /// service started has been reaped. It does not wait for a stream to
    /// close. Safe to call again.
    pub fn shutdown(&self) {
        let mut state = self.inner.state();
        state.shut = true;
        let mut children = Vec::new();
        let mut streaming = Vec::new();
        state.runs.retain(|_, run| match run {
            Run::Kept(_) => false,
            Run::Starting { cancelled } => {
                *cancelled = true;
                true
            }
            Run::Running {
                child,
                reads,
                cancelled,
            } => {
                *cancelled = true;
                children.push((Arc::clone(child), Arc::clone(reads)));
                true
            }
            Run::Streaming {
                child,
                stream,
                cancelled,
                reaped,
            } => {
                *cancelled = true;
                // Abandoned with its waits, so its pending read is dropped
                // uncompleted.
                stream.abandon();
                streaming.push(Arc::clone(child));
                !*reaped
            }
        });
        // A flush is kept: it is completed once everything has been reaped.
        state
            .waits
            .retain(|_, kept| matches!(kept, Wait::Flush { .. }));
        drop(state);
        for (child, reads) in children {
            child.kill();
            reads.abandon();
        }
        for child in streaming {
            child.kill();
        }
        let state = self.inner.state();
        let mut state = self
            .inner
            .finished
            .wait_while(state, |state| state.active > 0)
            .unwrap_or_else(PoisonError::into_inner);
        // Every child the service started has been reaped, so whatever a
        // flush still waits for has ended.
        let flushed = state.take_every_flush();
        drop(state);
        self.inner.complete_all(flushed);
    }

    /// Asks for the wait `id` to be completed once every run started before
    /// this call has ended (its result kept, or it was cancelled and its
    /// child reaped), every open asked before it has been answered, and
    /// every streaming child cancelled or forgotten before it has been
    /// reaped. A live streaming child, its pending read and a write held by
    /// a full pipe are not waited for: they wait on the child, not on the
    /// service. It returns at once and keeps no reply. An id in use is
    /// refused; one with nothing to wait for is completed at once, on the
    /// caller's thread. It is counted in [`pending`](Self::pending) while
    /// it waits, and a cancel withdraws it.
    pub fn flush(&self, id: u64) -> bool {
        let mut state = self.inner.state();
        if state.in_use(id) {
            return false;
        }
        let awaited: HashSet<u64> = state
            .runs
            .iter()
            .filter(|(_, run)| match run {
                Run::Starting { .. } | Run::Running { .. } => true,
                Run::Streaming {
                    cancelled, reaped, ..
                } => *cancelled && !*reaped,
                Run::Kept(_) => false,
            })
            .map(|(&run, _)| run)
            .collect();
        if awaited.is_empty() {
            drop(state);
            (self.inner.complete)(id);
            return true;
        }
        let order = state.flushes;
        state.flushes += 1;
        state.waits.insert(id, Wait::Flush { order, awaited });
        true
    }

    /// The runs and the streaming children not over, a cancelled one being
    /// over once its child is reaped; the results not taken; and the waits
    /// on streaming children not answered or not taken.
    pub fn pending(&self) -> usize {
        let state = self.inner.state();
        state.runs.len() + state.waits.len()
    }

    /// Starts `command` as the streaming child `id`, as `streaming` says,
    /// and returns at once. False, starting nothing, for an id in use, or
    /// when the system refuses the child its thread. Its reply,
    /// [`StreamReply::Opened`] or [`StreamReply::Refused`], is kept under
    /// `id` and completed; after shutdown it is refused as shut down at
    /// once.
    pub fn open(&self, id: u64, command: Command, streaming: Streaming) -> bool {
        let command = command.without_app_identity();
        let mut state = self.inner.state();
        if state.in_use(id) {
            return false;
        }
        if state.shut {
            let refusal = Refusal::new(
                RefusalKind::ShutDown,
                format!(
                    "cannot start `{}` in {}: the process service has shut down",
                    command.program,
                    command.directory.display()
                ),
            );
            state
                .waits
                .insert(id, Wait::Kept(StreamReply::Refused(refusal)));
            drop(state);
            (self.inner.complete)(id);
            return true;
        }
        state.runs.insert(id, Run::Starting { cancelled: false });
        state.active += 1;
        drop(state);
        let inner = Arc::clone(&self.inner);
        let started = thread::Builder::new()
            .name("editor-process-stream".into())
            .spawn(move || Inner::stream(&inner, id, &command, streaming))
            .is_ok();
        if !started {
            let mut state = self.inner.state();
            state.runs.remove(&id);
            state.active -= 1;
            let flushed = state.settle(id);
            drop(state);
            self.inner.finished.notify_all();
            self.inner.complete_all(flushed);
        }
        started
    }

    /// Asks for the next delivery of the child `child`, as the wait `wait`,
    /// and returns at once. It is completed once something is deliverable,
    /// or the child has ended, and only once: the delivery is drained when
    /// it is taken ([`Service::take_stream`]). False for a child the
    /// service does not hold, a wait id in use, or a read already pending.
    pub fn read(&self, child: u64, wait: u64) -> bool {
        let mut state = self.inner.state();
        if state.in_use(wait) {
            return false;
        }
        let Some(Run::Streaming {
            stream,
            cancelled: false,
            ..
        }) = state.runs.get(&child)
        else {
            return false;
        };
        let stream = Arc::clone(stream);
        let mut streamed = stream.state();
        if streamed.read.is_some() {
            return false;
        }
        streamed.read = Some((wait, false));
        let wake = streamed.wake();
        drop(streamed);
        state.waits.insert(wait, Wait::Reading(child));
        drop(state);
        if let Some(wait) = wake {
            (self.inner.complete)(wait);
        }
        true
    }

    /// The reply of the wait `wait`, once: an open's, a write's, or a
    /// read's delivery, drained at the moment it is taken. `None` while it
    /// is not answered, once it was taken, and for a wait the service does
    /// not know.
    pub fn take_stream(&self, wait: u64) -> Option<StreamReply> {
        let mut state = self.inner.state();
        let child = match state.waits.get(&wait)? {
            Wait::Kept(_) => {
                let Some(Wait::Kept(reply)) = state.waits.remove(&wait) else {
                    return None;
                };
                return Some(reply);
            }
            Wait::Writing(_) | Wait::Flush { .. } => return None,
            Wait::Reading(child) => *child,
        };
        let Some(Run::Streaming { stream, .. }) = state.runs.get(&child) else {
            return None;
        };
        let stream = Arc::clone(stream);
        let mut streamed = stream.state();
        if streamed.read != Some((wait, true)) {
            return None;
        }
        streamed.read = None;
        let (out, err) = streamed.outbox.drain();
        let ended = streamed.end();
        drop(streamed);
        // The readers parked on the bound go on.
        stream.changed.notify_all();
        state.waits.remove(&wait);
        if ended.is_some() {
            Self::forget(&mut state, child);
            drop(state);
            // Outside the state lock: the read was just taken, and the
            // child is forgotten, so no later read can be pending.
            stream.abandon();
        }
        Some(StreamReply::Delivered(Delivery { out, err, ended }))
    }

    /// Writes `bytes` to the standard input of the child `child`, as the
    /// wait `wait`, and returns at once. It is completed with
    /// [`StreamReply::Written`] once every byte is in the pipe, or with a
    /// refusal as [`RefusalKind::InputClosed`]: at once when the child has
    /// no input or it was closed. False for a child the service does not
    /// hold, a wait id in use, or a write already pending.
    pub fn write(&self, child: u64, wait: u64, bytes: Vec<u8>) -> bool {
        self.ask_input(child, wait, Some(bytes))
    }

    /// Closes the standard input of the child `child`, as the wait `wait`,
    /// and returns at once: it is completed with [`StreamReply::Written`]
    /// at once, and the input is dropped behind any write in flight. False
    /// as for [`Service::write`].
    pub fn close_input(&self, child: u64, wait: u64) -> bool {
        self.ask_input(child, wait, None)
    }

    /// A write of `bytes` or, with none, a close: [`Service::write`] and
    /// [`Service::close_input`].
    fn ask_input(&self, child: u64, wait: u64, bytes: Option<Vec<u8>>) -> bool {
        let mut state = self.inner.state();
        if state.in_use(wait) {
            return false;
        }
        let Some(Run::Streaming {
            stream,
            cancelled: false,
            ..
        }) = state.runs.get(&child)
        else {
            return false;
        };
        let stream = Arc::clone(stream);
        let mut streamed = stream.state();
        if streamed.write.is_some() {
            return false;
        }
        let reply = match bytes {
            Some(_) if !streamed.input => Some(StreamReply::Refused(Refusal::new(
                RefusalKind::InputClosed,
                format!(
                    "cannot write to the standard input of `{}`: it is closed",
                    streamed.program
                ),
            ))),
            Some(bytes) => {
                streamed.write = Some((wait, bytes));
                None
            }
            None => {
                streamed.closing = true;
                streamed.input = false;
                Some(StreamReply::Written)
            }
        };
        drop(streamed);
        stream.changed.notify_all();
        match reply {
            None => {
                state.waits.insert(wait, Wait::Writing(child));
                true
            }
            Some(reply) => {
                state.waits.insert(wait, Wait::Kept(reply));
                drop(state);
                (self.inner.complete)(wait);
                true
            }
        }
    }

    /// Whether the readers of the child `child` are parked on its bound: a
    /// readout for tests. `None` for a child the service does not hold.
    pub fn held(&self, child: u64) -> Option<bool> {
        let state = self.inner.state();
        let Some(Run::Streaming { stream, .. }) = state.runs.get(&child) else {
            return None;
        };
        let held = stream.state().parked.iter().any(|&parked| parked);
        Some(held)
    }

    /// Cancels the wait `id` on a streaming child, if it is one: drops it,
    /// or its kept reply, without completing it. The child keeps running
    /// and keeps what it wrote. A write already handed to the writer still
    /// reaches the pipe; only its reply is dropped.
    fn cancel_wait(state: &mut State<P::Child>, id: u64) -> bool {
        let Some(wait) = state.waits.remove(&id) else {
            return false;
        };
        let child = match wait {
            Wait::Kept(_) | Wait::Flush { .. } => return true,
            Wait::Reading(child) | Wait::Writing(child) => child,
        };
        if let Some(Run::Streaming { stream, .. }) = state.runs.get(&child) {
            let mut streamed = stream.state();
            if streamed.read.is_some_and(|(wait, _)| wait == id) {
                streamed.read = None;
            }
            if streamed.write.as_ref().is_some_and(|(wait, _)| *wait == id) {
                streamed.write = None;
            }
        }
        true
    }

    /// Forgets the child `child`, whose last delivery has been taken: it is
    /// gone once its waiter has finished.
    fn forget(state: &mut State<P::Child>, child: u64) {
        if let Some(Run::Streaming {
            cancelled, reaped, ..
        }) = state.runs.get_mut(&child)
        {
            *cancelled = true;
            if *reaped {
                state.runs.remove(&child);
            }
        }
    }
}

impl<P: Processes + 'static> Inner<P> {
    /// Locks the state. The lock is never held while other code runs, so a
    /// poisoned lock still guards a consistent state.
    fn state(&self) -> MutexGuard<'_, State<P::Child>> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The run `id`'s thread: the module docs' steps.
    fn run(
        &self,
        id: u64,
        command: &Command,
        input: Option<Vec<u8>>,
        limit: u64,
        overflow: Overflow,
    ) {
        let piped = if input.is_some() {
            Input::Pipe
        } else {
            Input::Closed
        };
        let result = match refusal_before_spawn(command) {
            Some(refusal) => RunResult::Refused(refusal),
            None => match self.processes.spawn(command, piped) {
                Err(refusal) => RunResult::Refused(refusal),
                Ok(child) => match self.own(id, child, input, limit, overflow) {
                    Some(result) => result,
                    None => {
                        self.finish(id, None);
                        return;
                    }
                },
            },
        };
        self.finish(id, Some(result));
    }

    /// Registers `child` as the run `id`'s, kills it if the run was
    /// cancelled meanwhile, feeds it `input`, reads its streams, waits for
    /// it and says what the run came to: `None` if it was cancelled before
    /// its streams reached their end. Standard output past `limit` is
    /// handled as `overflow` says; standard error is always refused.
    fn own(
        &self,
        id: u64,
        mut child: P::Child,
        input: Option<Vec<u8>>,
        limit: u64,
        overflow: Overflow,
    ) -> Option<RunResult> {
        let outputs = [
            child.take_output(Stream::Out),
            child.take_output(Stream::Err),
        ];
        let fed = input.and_then(|bytes| child.take_input().map(|pipe| (pipe, bytes)));
        let child = Arc::new(child);
        let reads = Arc::new(Reads::default());
        {
            let mut state = self.state();
            let cancelled = match state.runs.get(&id) {
                Some(Run::Starting { cancelled }) => *cancelled,
                _ => true,
            };
            state.runs.insert(
                id,
                Run::Running {
                    child: Arc::clone(&child),
                    reads: Arc::clone(&reads),
                    cancelled,
                },
            );
            drop(state);
            if cancelled {
                child.kill();
                reads.abandon();
            }
        }
        let [out, err] = outputs;
        for (slot, output) in [out, err].into_iter().enumerate() {
            let (killed, delivered) = (Arc::clone(&child), Arc::clone(&reads));
            let overflow = if slot == 0 {
                overflow
            } else {
                Overflow::Refuse
            };
            // The reader's thread is detached: a run that stops waiting for
            // it leaves it to end when its stream closes.
            let spawned = thread::Builder::new()
                .name("editor-process-read".into())
                .spawn(move || {
                    let mut hand_over = HandOver {
                        reads: delivered,
                        slot,
                        read: None,
                    };
                    hand_over.read = Some(output.map_or(Read::Whole(Vec::new()), |output| {
                        read(output, limit, overflow, &*killed)
                    }));
                });
            if let Err(error) = spawned {
                reads.deliver(
                    slot,
                    Read::Failed(Refusal::new(
                        RefusalKind::Failed,
                        format!("no thread to read a stream: {error}"),
                    )),
                );
                // A stream that has no reader would fill and hold the child.
                child.kill();
            }
        }
        let unfed = fed.and_then(|(pipe, bytes)| feed(pipe, bytes, &*child));
        let exit = child.wait();
        let streams = reads.wait()?;
        if let Some(refusal) = unfed {
            return Some(RunResult::Refused(refusal));
        }
        let streams = [Stream::Out, Stream::Err].into_iter().zip(streams);
        let mut whole = [Vec::new(), Vec::new()];
        let mut failed = None;
        let mut cut = false;
        for (stream, read) in streams {
            match read {
                Read::TooLarge => return Some(RunResult::OutputTooLarge { stream, limit }),
                Read::Failed(refusal) => {
                    failed.get_or_insert(refusal);
                }
                Read::Cut(bytes) => {
                    cut = true;
                    whole[0] = bytes;
                }
                Read::Whole(bytes) => whole[usize::from(stream == Stream::Err)] = bytes,
            }
        }
        if let Some(refusal) = failed {
            return Some(RunResult::Refused(refusal));
        }
        let [stdout, stderr] = whole;
        if cut {
            return Some(RunResult::Cut { stdout, stderr });
        }
        Some(RunResult::Ran {
            exit,
            stdout,
            stderr,
        })
    }

    /// Completes each of `waits`, in order, with no lock held.
    fn complete_all(&self, waits: Vec<u64>) {
        for wait in waits {
            (self.complete)(wait);
        }
    }

    /// Ends the run `id` as `result`: kept and completed, or dropped if it
    /// was cancelled. `None` is a run cancelled before it came to anything.
    /// A flush it was the last thing for is completed after it.
    fn finish(&self, id: u64, result: Option<RunResult>) {
        let mut state = self.state();
        let cancelled = match state.runs.remove(&id) {
            Some(Run::Starting { cancelled } | Run::Running { cancelled, .. }) => cancelled,
            Some(Run::Kept(_) | Run::Streaming { .. }) | None => true,
        };
        let kept = result.filter(|_| !cancelled);
        let cancelled = kept.is_none();
        if let Some(result) = kept {
            state.runs.insert(id, Run::Kept(result));
        }
        state.active -= 1;
        let flushed = state.settle(id);
        drop(state);
        self.finished.notify_all();
        if !cancelled {
            (self.complete)(id);
        }
        self.complete_all(flushed);
    }

    /// The streaming child `id`'s thread, its waiter: the module docs'
    /// steps for a streaming child.
    fn stream(inner: &Arc<Self>, id: u64, command: &Command, streaming: Streaming) {
        let refusal = refusal_before_spawn(command).or_else(|| {
            (streaming.bound == 0).then(|| {
                Refusal::new(
                    RefusalKind::Failed,
                    format!(
                        "cannot start `{}` in {}: the bound must be at least one byte",
                        command.program,
                        command.directory.display()
                    ),
                )
            })
        });
        let child = match refusal {
            Some(refusal) => Err(refusal),
            None => inner.processes.spawn(command, streaming.input),
        };
        let mut child = match child {
            Ok(child) => child,
            Err(refusal) => {
                inner.refuse_stream(id, refusal);
                return;
            }
        };
        let outputs = [
            child.take_output(Stream::Out),
            child.take_output(Stream::Err),
        ];
        let input = child.take_input();
        let child = Arc::new(child);
        let stream = Arc::new(StreamState {
            state: Mutex::new(Streamed {
                program: command.program.clone(),
                outbox: Outbox::new(streaming.out, streaming.err, streaming.bound),
                exit: None,
                failed: None,
                read: None,
                write: None,
                closing: false,
                input: input.is_some(),
                abandoned: false,
                parked: [false; 2],
            }),
            changed: Condvar::new(),
        });
        let mut state = inner.state();
        let cancelled = !matches!(
            state.runs.get(&id),
            Some(Run::Starting { cancelled: false })
        );
        state.runs.insert(
            id,
            Run::Streaming {
                child: Arc::clone(&child),
                stream: Arc::clone(&stream),
                cancelled,
                reaped: false,
            },
        );
        // A live child's open is answered here, so a flush waits for it no
        // longer; a cancelled one's waits for its reap.
        let flushed = if cancelled {
            Vec::new()
        } else {
            state.waits.insert(id, Wait::Kept(StreamReply::Opened));
            state.settle(id)
        };
        drop(state);
        if cancelled {
            // Outside the state lock: a read refuses a cancelled child, so
            // none can be pending.
            child.kill();
            stream.abandon();
        } else {
            (inner.complete)(id);
            inner.complete_all(flushed);
        }
        for (output, which) in outputs.into_iter().zip([Stream::Out, Stream::Err]) {
            let Some(output) = output else {
                stream.state().outbox.end(which);
                continue;
            };
            let (reading, killed, completing) =
                (Arc::clone(&stream), Arc::clone(&child), Arc::clone(inner));
            // The reader's thread is detached: a cancel leaves it to end
            // when its stream closes, as a run's.
            let spawned = thread::Builder::new()
                .name("editor-process-read".into())
                .spawn(move || {
                    stream_reader(output, which, &reading, &*killed, &*completing.complete);
                });
            if let Err(error) = spawned {
                let mut streamed = stream.state();
                streamed.failed.get_or_insert(End::Failed(Refusal::new(
                    RefusalKind::Failed,
                    format!("no thread to read a stream: {error}"),
                )));
                drop(streamed);
                // A stream that has no reader would fill and hold the child.
                child.kill();
            }
        }
        if let Some(input) = input {
            let (writing, keeping) = (Arc::clone(&stream), Arc::clone(inner));
            // Detached too: a writer blocked in `write(2)` returns once the
            // child is dead, unless a process that left its group holds its
            // input.
            let spawned = thread::Builder::new()
                .name("editor-process-write".into())
                .spawn(move || stream_writer(input, &writing, &keeping));
            if spawned.is_err() {
                stream.state().input = false;
            }
        }
        let exit = child.wait();
        let mut streamed = stream.state();
        streamed.exit = Some(exit);
        let wake = streamed.wake();
        drop(streamed);
        if let Some(wait) = wake {
            (inner.complete)(wait);
        }
        let mut state = inner.state();
        if let Some(Run::Streaming {
            cancelled, reaped, ..
        }) = state.runs.get_mut(&id)
        {
            if *cancelled {
                state.runs.remove(&id);
            } else {
                *reaped = true;
            }
        }
        state.active -= 1;
        let flushed = state.settle(id);
        drop(state);
        inner.finished.notify_all();
        inner.complete_all(flushed);
    }

    /// Keeps `reply` under the wait `wait` and completes it, unless the
    /// wait was cancelled meanwhile.
    fn keep(&self, wait: u64, reply: StreamReply) {
        let mut state = self.state();
        if !matches!(state.waits.get(&wait), Some(Wait::Writing(_))) {
            return;
        }
        state.waits.insert(wait, Wait::Kept(reply));
        drop(state);
        (self.complete)(wait);
    }

    /// Ends the streaming child `id`, which was refused before it ran, as
    /// `refusal`: kept and completed, unless it was cancelled.
    fn refuse_stream(&self, id: u64, refusal: Refusal) {
        let mut state = self.state();
        let cancelled = !matches!(
            state.runs.remove(&id),
            Some(Run::Starting { cancelled: false })
        );
        if !cancelled {
            state
                .waits
                .insert(id, Wait::Kept(StreamReply::Refused(refusal)));
        }
        state.active -= 1;
        let flushed = state.settle(id);
        drop(state);
        self.finished.notify_all();
        if !cancelled {
            (self.complete)(id);
        }
        self.complete_all(flushed);
    }
}

/// A streaming child's writer: it writes each write it is handed whole,
/// keeps its reply and completes it, and drops the input when the job
/// closes it or the child is abandoned.
fn stream_writer<P: Processes + 'static>(
    mut input: impl ChildInput,
    shared: &StreamState,
    inner: &Inner<P>,
) {
    loop {
        let streamed = shared.state();
        let mut streamed = shared
            .changed
            .wait_while(streamed, |streamed| {
                !streamed.abandoned && streamed.write.is_none() && !streamed.closing
            })
            .unwrap_or_else(PoisonError::into_inner);
        if streamed.abandoned {
            return;
        }
        let Some((wait, bytes)) = streamed.write.take() else {
            // Closed: dropping the input closes the child's end.
            return;
        };
        drop(streamed);
        let reply = match write_all(&mut input, &bytes) {
            Ok(()) => StreamReply::Written,
            Err(refusal) => {
                if refusal.kind == RefusalKind::InputClosed {
                    shared.state().input = false;
                }
                StreamReply::Refused(refusal)
            }
        };
        inner.keep(wait, reply);
    }
}

/// Starts a run's writer: a thread that writes every byte of `bytes` to
/// `pipe`, the child's standard input, and then drops it, which closes it.
/// A write the child does not take is ignored: the run's result is what
/// the child did. The thread is detached, as a run's readers are. `Some`
/// refusal, with the child killed, when the system refuses the thread: a
/// child that is never fed must not be taken to have read its input.
fn feed(mut pipe: impl ChildInput, bytes: Vec<u8>, child: &impl Child) -> Option<Refusal> {
    let spawned = thread::Builder::new()
        .name("editor-process-input".into())
        .spawn(move || {
            // A refusal is the child's closing its input, or its end: what
            // the run comes to is what the child did.
            write_all(&mut pipe, &bytes).ok();
        });
    spawned.err().map(|error| {
        child.kill();
        Refusal::new(
            RefusalKind::Failed,
            format!("no thread to write a child's standard input: {error}"),
        )
    })
}

/// Writes every byte of `bytes` to `input`.
fn write_all(input: &mut impl ChildInput, bytes: &[u8]) -> Result<(), Refusal> {
    let mut at = 0;
    while at < bytes.len() {
        match input.write(&bytes[at..])? {
            0 => {
                return Err(Refusal::new(
                    RefusalKind::Failed,
                    "a write to a child's standard input wrote nothing",
                ));
            }
            count => at += count.min(bytes.len() - at),
        }
    }
    Ok(())
}

/// A streaming child's reader of `stream`: it reads as much as the bound
/// leaves room for, frames it and wakes the pending read, until the stream
/// ends, a read fails, a line is too long, or the child is abandoned. At a
/// room of 0 it parks, which holds the child.
fn stream_reader(
    mut output: impl Output,
    stream: Stream,
    shared: &StreamState,
    child: &impl Child,
    complete: &(dyn Fn(u64) + Send + Sync),
) {
    let slot = usize::from(stream == Stream::Err);
    let mut buffer = vec![0; 8192];
    loop {
        let mut streamed = shared.state();
        loop {
            if streamed.abandoned || streamed.failed.is_some() {
                streamed.parked[slot] = false;
                return;
            }
            if streamed.outbox.room(stream) > 0 {
                break;
            }
            // Held: nothing reads the pipe, so it fills and the child
            // blocks in `write(2)`, until a take makes room.
            streamed.parked[slot] = true;
            streamed = shared
                .changed
                .wait(streamed)
                .unwrap_or_else(PoisonError::into_inner);
        }
        streamed.parked[slot] = false;
        let want = usize::try_from(streamed.outbox.room(stream))
            .unwrap_or(usize::MAX)
            .min(buffer.len());
        drop(streamed);
        let read = output.read(&mut buffer[..want]);
        let mut streamed = shared.state();
        let (ended, kill) = match read {
            Ok(0) => {
                streamed.outbox.end(stream);
                (true, false)
            }
            Ok(count) => {
                streamed.outbox.push(stream, &buffer[..count.min(want)]);
                if streamed.outbox.too_long(stream) && streamed.failed.is_none() {
                    // A partial line fills the bound. It is a last line if
                    // the stream ends here, and longer than the bound if one
                    // more byte comes: look one byte further, kept outside
                    // the outbox, so the bound still holds.
                    drop(streamed);
                    let probe = output.read(&mut buffer[..1]);
                    streamed = shared.state();
                    match probe {
                        Ok(0) => {
                            streamed.outbox.end(stream);
                            (true, false)
                        }
                        // The line is longer than the bound, so can never be
                        // delivered whole: the child ends, never with a line
                        // cut.
                        Ok(_) => {
                            let bound = streamed.outbox.bound();
                            streamed
                                .failed
                                .get_or_insert(End::LineTooLong { stream, bound });
                            (true, true)
                        }
                        Err(refusal) => {
                            streamed.failed.get_or_insert(End::Failed(refusal));
                            (true, true)
                        }
                    }
                } else {
                    (false, false)
                }
            }
            Err(refusal) => {
                streamed.failed.get_or_insert(End::Failed(refusal));
                (true, true)
            }
        };
        let wake = streamed.wake();
        drop(streamed);
        shared.changed.notify_all();
        if kill {
            child.kill();
        }
        if let Some(wait) = wake {
            complete(wait);
        }
        if ended {
            return;
        }
    }
}

/// Reads `output` to its end, keeping up to `limit` bytes. Past the limit,
/// or when a read fails, it kills `child`'s group and stops: past the
/// limit it refuses the stream, or keeps its first `limit` bytes, as
/// `overflow` says.
fn read(mut output: impl Output, limit: u64, overflow: Overflow, child: &impl Child) -> Read {
    let mut kept = Vec::new();
    let mut buffer = [0; 8192];
    loop {
        match output.read(&mut buffer) {
            Ok(0) => return Read::Whole(kept),
            Ok(count) => {
                let count = count.min(buffer.len());
                if (kept.len() as u64).saturating_add(count as u64) > limit {
                    child.kill();
                    if overflow == Overflow::Refuse {
                        return Read::TooLarge;
                    }
                    let room = usize::try_from(limit).map_or(count, |limit| limit - kept.len());
                    kept.extend_from_slice(&buffer[..room]);
                    return Read::Cut(kept);
                }
                kept.extend_from_slice(&buffer[..count]);
            }
            Err(refusal) => {
                child.kill();
                return Read::Failed(refusal);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;
    use std::sync::mpsc::{self, Receiver};
    use std::time::Duration;

    use super::*;
    use crate::fake::{FakeProcesses, Hold, Script};

    /// How long a test waits for something that should happen at once.
    /// Only a broken service takes this long, and the test then fails
    /// instead of hanging.
    const DEADLINE: Duration = Duration::from_secs(5);

    /// A limit no test's output is over.
    const ROOMY: u64 = 1 << 20;

    fn command(script: &str) -> Command {
        Command::new("/bin/sh", ["-c", script], "/dir")
    }

    /// A service over `fake`, and the ids it completes, in order.
    fn service(fake: &FakeProcesses) -> (Service<FakeProcesses>, Receiver<u64>) {
        let (sender, completed) = mpsc::channel();
        let sender = Mutex::new(sender);
        let service = Service::new(fake.clone(), move |id| {
            sender
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .send(id)
                .ok();
        });
        (service, completed)
    }

    /// Flushes `service` and waits for the flush's completion, which must
    /// be the next on `completed`; then says whether nothing is pending.
    /// The flush is completed once every run before it has ended and every
    /// child cancelled or forgotten before it has been reaped.
    fn flushed(service: &Service<FakeProcesses>, completed: &Receiver<u64>) -> bool {
        assert!(service.flush(FLUSH), "the flush's id is free");
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(FLUSH));
        service.pending() == 0
    }

    /// The id of [`flushed`]'s flush: one no test names otherwise.
    const FLUSH: u64 = u64::MAX;

    fn ran(exit: Exit, stdout: &[u8], stderr: &[u8]) -> RunResult {
        RunResult::Ran {
            exit,
            stdout: stdout.to_vec(),
            stderr: stderr.to_vec(),
        }
    }

    #[test]
    fn a_flush_with_nothing_to_wait_for_is_completed_at_once_and_keeps_nothing() {
        let fake = FakeProcesses::new();
        let (service, completed) = service(&fake);

        assert!(service.flush(1));

        assert_eq!(completed.try_recv(), Ok(1));
        assert_eq!(service.pending(), 0);
        assert!(service.take(1).is_none() && service.take_stream(1).is_none());
    }

    #[test]
    fn a_flush_waits_for_a_held_run_counts_while_it_does_and_a_cancel_withdraws_it() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).hold(Hold::UntilLetGo)),
        )]);
        let (service, completed) = service(&fake);
        assert!(service.start(1, command("x"), ROOMY));
        assert!(fake.until(DEADLINE, |record| record.waiting.len() == 1));

        assert!(service.flush(2));
        assert!(!service.flush(2), "its id is in use");
        assert!(!service.start(2, command("x"), ROOMY));
        assert!(service.flush(3));
        assert_eq!(service.pending(), 3);
        assert!(service.cancel(2));
        assert!(!service.cancel(2));
        fake.let_go_all();

        // The run's completion, then the flush left.
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(1));
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(3));
        assert!(service.take(1).is_some());
        assert!(flushed(&service, &completed));
    }

    #[test]
    fn shutdown_completes_a_waiting_flush_once_every_child_is_reaped() {
        let fake = FakeProcesses::scripted([(
            command("held"),
            Ok(Script::ends(Exit::Code(0)).hold(Hold::UntilKilled)),
        )]);
        let (service, completed) = service(&fake);
        assert!(service.start(1, command("held"), ROOMY));
        assert!(fake.until(DEADLINE, |record| record.waiting.len() == 1));
        assert!(service.flush(2));

        service.shutdown();

        assert_eq!(completed.try_recv(), Ok(2));
        let child = fake.record().spawned[0].0;
        assert!(!fake.alive(child));
        assert_eq!(service.pending(), 0);
    }

    #[test]
    fn an_id_in_use_is_refused_while_it_runs_and_while_its_result_is_not_taken() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).hold(Hold::UntilLetGo)),
        )]);
        let (service, completed) = service(&fake);

        assert!(service.start(1, command("x"), ROOMY));
        assert!(!service.start(1, command("x"), ROOMY), "running");
        assert!(fake.until(DEADLINE, |record| record.waiting.len() == 1));
        fake.let_go_all();
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(1));
        assert!(!service.start(1, command("x"), ROOMY), "not taken");
        assert_eq!(fake.record().spawned.len(), 1);

        assert!(service.take(1).is_some());
        assert!(
            service.start(1, command("x"), ROOMY),
            "taken, the id is free"
        );
        assert!(fake.until(DEADLINE, |record| record.waiting.len() == 1
            && record.spawned.len() == 2));
        fake.let_go_all();
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(1));
    }

    #[test]
    fn a_spawn_refusal_is_the_kept_result_and_is_completed_once() {
        let fake = FakeProcesses::new();
        let (service, completed) = service(&fake);

        assert!(service.start(4, command("unscripted"), ROOMY));

        assert_eq!(completed.recv_timeout(DEADLINE), Ok(4));
        let Some(RunResult::Refused(refusal)) = service.take(4) else {
            panic!("a refusal");
        };
        assert_eq!(refusal.kind, RefusalKind::NotFound);
        assert!(completed.recv_timeout(Duration::from_millis(50)).is_err());
        assert_eq!(service.pending(), 0);
    }

    #[test]
    fn a_relative_directory_or_program_is_refused_without_a_spawn() {
        let fake = FakeProcesses::new();
        let (service, completed) = service(&fake);

        assert!(service.start(1, Command::new("/bin/sh", [""; 0], "relative"), ROOMY));
        assert!(service.start(2, Command::new("bin/sh", [""; 0], "/dir"), ROOMY));
        let mut done = [
            completed.recv_timeout(DEADLINE).expect("one"),
            completed.recv_timeout(DEADLINE).expect("two"),
        ];
        done.sort_unstable();

        assert_eq!(done, [1, 2]);
        let kinds = [service.take(1), service.take(2)].map(|result| match result {
            Some(RunResult::Refused(refusal)) => Some(refusal.kind),
            _ => None,
        });
        assert_eq!(
            kinds,
            [
                Some(RefusalKind::RelativeDirectory),
                Some(RefusalKind::RelativeProgram)
            ]
        );
        assert_eq!(fake.record().spawned, []);
    }

    #[test]
    fn a_run_to_its_end_gives_its_exit_and_its_streams_once_and_reaps_its_child() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(3))
                .stdout(b"out\n\xff".to_vec())
                .stderr("err")),
        )]);
        let (service, completed) = service(&fake);

        assert!(service.start(9, command("x"), ROOMY));

        assert_eq!(completed.recv_timeout(DEADLINE), Ok(9));
        assert_eq!(
            service.take(9),
            Some(ran(Exit::Code(3), b"out\n\xff", b"err"))
        );
        assert_eq!(service.take(9), None, "taken once");
        let record = fake.record();
        assert_eq!(record.reaped, [record.spawned[0].0]);
        assert_eq!(service.pending(), 0);
    }

    #[test]
    fn a_fed_run_gives_its_child_the_input_then_closes_it_and_reaps_the_child() {
        let fake = FakeProcesses::scripted([(
            command("cat"),
            Ok(Script::ends(Exit::Code(0)).step(crate::fake::Step::EchoUntilClosed(Stream::Out))),
        )]);
        let (service, completed) = service(&fake);

        assert!(service.start_with_input(9, command("cat"), Some(b"in\0\xff".to_vec()), ROOMY));

        assert_eq!(completed.recv_timeout(DEADLINE), Ok(9));
        assert_eq!(service.take(9), Some(ran(Exit::Code(0), b"in\0\xff", b"")));
        let record = fake.record();
        let child = record.spawned[0].0;
        assert_eq!(record.children[&child].input, Input::Pipe);
        assert_eq!(record.children[&child].received, b"in\0\xff");
        assert!(
            record.children[&child].input_closed,
            "the writer wrote every byte and dropped the input"
        );
        assert_eq!(record.reaped, [child]);
        assert_eq!(service.pending(), 0);
    }

    #[test]
    fn a_fed_run_whose_child_reads_nothing_comes_to_what_the_child_did() {
        let fake = FakeProcesses::scripted([(
            command("true"),
            Ok(Script::ends(Exit::Code(0)).stdout("done")),
        )]);
        let (service, completed) = service(&fake);

        assert!(service.start_with_input(3, command("true"), Some(vec![b'x'; 1 << 16]), ROOMY));

        assert_eq!(completed.recv_timeout(DEADLINE), Ok(3));
        assert_eq!(service.take(3), Some(ran(Exit::Code(0), b"done", b"")));
        assert!(flushed(&service, &completed));
    }

    #[test]
    fn a_run_the_service_does_not_know_has_no_result_and_nothing_to_cancel() {
        let (service, _) = service(&FakeProcesses::new());

        assert_eq!(service.take(5), None);
        assert!(!service.cancel(5));
    }

    #[test]
    fn a_cancel_seen_at_registration_kills_the_child_it_has_just_made() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).hold(Hold::UntilKilled)),
        )]);
        let (service, completed) = service(&fake);
        let mut state = service.inner.state();
        state.runs.insert(3, Run::Starting { cancelled: true });
        state.active += 1;
        drop(state);

        let inner = Arc::clone(&service.inner);
        thread::spawn(move || inner.run(3, &command("x"), None, ROOMY, Overflow::Refuse))
            .join()
            .expect("the run ends");

        let record = fake.record();
        assert_eq!(record.killed, [record.spawned[0].0]);
        assert_eq!(record.reaped, [record.spawned[0].0]);
        assert_eq!(service.pending(), 0);
        assert!(completed.try_recv().is_err());
    }

    #[test]
    fn a_run_cancelled_while_it_waits_kills_its_group_is_reaped_and_is_never_completed() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .hold(Hold::UntilKilled)
                .members(1)),
        )]);
        let (service, completed) = service(&fake);
        assert!(service.start(6, command("x"), ROOMY));
        assert!(fake.until(DEADLINE, |record| record.waiting.len() == 1));
        let child = fake.record().spawned[0].0;

        assert!(service.cancel(6));

        assert!(flushed(&service, &completed));
        assert!(!fake.alive(child) && !fake.alive(child + 1));
        assert_eq!(fake.record().killed, [child]);
        assert!(completed.recv_timeout(Duration::from_millis(50)).is_err());
        assert_eq!(service.take(6), None);
    }

    #[test]
    fn cancelling_a_kept_result_drops_it() {
        let fake = FakeProcesses::scripted([(command("x"), Ok(Script::ends(Exit::Code(0))))]);
        let (service, completed) = service(&fake);
        assert!(service.start(1, command("x"), ROOMY));
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(1));

        assert!(service.cancel(1));

        assert_eq!(service.take(1), None);
        assert_eq!(service.pending(), 0);
    }

    #[test]
    fn the_streams_are_read_to_their_end_before_the_result_is_kept() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).stdout("out").stderr("err")),
        )]);
        let (service, completed) = service(&fake);
        fake.hold_reads();

        assert!(service.start(1, command("x"), ROOMY));
        assert!(fake.until(DEADLINE, |record| record.reads_parked == 2
            && record.reaped.len() == 1));
        assert_eq!(
            service.take(1),
            None,
            "the child is reaped, the readers not joined"
        );
        assert!(completed.try_recv().is_err());
        fake.release_reads();

        assert_eq!(completed.recv_timeout(DEADLINE), Ok(1));
        assert_eq!(service.take(1), Some(ran(Exit::Code(0), b"out", b"err")));
    }

    #[test]
    fn shutdown_blocks_until_every_held_wait_has_returned_and_every_child_is_reaped() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .hold(Hold::UntilKilled)
                .members(1)),
        )]);
        let (service, completed) = service(&fake);
        // Holding the reaps holds each wait after its child has been killed:
        // shutdown must not return before they are let go.
        fake.hold_reaps();
        assert!(service.start(1, command("x"), ROOMY));
        assert!(service.start(2, command("x"), ROOMY));
        assert!(fake.until(DEADLINE, |record| record.waiting.len() == 2));

        let (sender, returned) = mpsc::channel();
        let shutting = service.clone();
        let shutdown = thread::spawn(move || {
            shutting.shutdown();
            sender.send(()).ok();
        });
        assert!(fake.until(DEADLINE, |record| record.reaps_parked == 2));
        assert!(returned.recv_timeout(Duration::from_millis(100)).is_err());
        assert_eq!(fake.record().reaped, []);
        fake.release_reaps();

        assert_eq!(returned.recv_timeout(DEADLINE), Ok(()));
        shutdown.join().expect("shutdown returns");
        let record = fake.record();
        assert!(
            record
                .spawned
                .iter()
                .all(|&(id, _)| !fake.alive(id) && !fake.alive(id + 1))
        );
        assert_eq!(service.pending(), 0);
        assert!(
            completed.try_recv().is_err(),
            "a run cancelled by shutdown is never completed"
        );
    }

    /// A child whose streams never reach their end once it has been
    /// reaped, as when a process it started has left its group and holds
    /// them.
    fn streams_held_open(fake: &FakeProcesses) {
        fake.script(
            command("held"),
            Ok(Script::ends(Exit::Code(0))
                .stdout("out")
                .hold(Hold::UntilKilled)
                .escaped(1)),
        );
    }

    #[test]
    fn shutdown_returns_once_every_child_is_reaped_though_a_stream_never_ends() {
        let fake = FakeProcesses::new();
        streams_held_open(&fake);
        let (service, completed) = service(&fake);
        assert!(service.start(1, command("held"), ROOMY));
        assert!(fake.until(DEADLINE, |record| record.waiting.len() == 1));
        let child = fake.record().spawned[0].0;

        let (sender, returned) = mpsc::channel();
        let shutting = service.clone();
        thread::spawn(move || {
            shutting.shutdown();
            sender.send(()).ok();
        });

        assert_eq!(returned.recv_timeout(DEADLINE), Ok(()));
        assert!(!fake.alive(child), "reaped");
        assert!(fake.alive(child + 1), "the escaped process is not ended");
        assert_eq!(service.pending(), 0);
        assert!(completed.try_recv().is_err());
        fake.end(child + 1);
    }

    #[test]
    fn a_cancelled_run_whose_stream_never_ends_is_over_once_its_child_is_reaped() {
        let fake = FakeProcesses::new();
        streams_held_open(&fake);
        let (service, completed) = service(&fake);
        assert!(service.start(1, command("held"), ROOMY));
        assert!(fake.until(DEADLINE, |record| record.waiting.len() == 1));
        let child = fake.record().spawned[0].0;

        assert!(service.cancel(1));

        assert!(flushed(&service, &completed));
        assert!(!fake.alive(child));
        assert!(
            service.start(1, command("held"), ROOMY),
            "the id is free again"
        );
        assert!(service.cancel(1));
        assert!(flushed(&service, &completed));
        assert!(completed.recv_timeout(Duration::from_millis(50)).is_err());
        fake.end(child + 1);
        fake.end(fake.record().spawned[1].0 + 1);
    }

    #[test]
    fn a_run_whose_stream_is_held_open_after_the_reap_waits_for_it_and_keeps_it_whole() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).stdout("out").escaped(1)),
        )]);
        let (service, completed) = service(&fake);

        assert!(service.start(1, command("x"), ROOMY));
        assert!(fake.until(DEADLINE, |record| record.reaped.len() == 1));
        assert!(completed.recv_timeout(Duration::from_millis(50)).is_err());
        fake.end(fake.record().spawned[0].0 + 1);

        assert_eq!(completed.recv_timeout(DEADLINE), Ok(1));
        assert_eq!(service.take(1), Some(ran(Exit::Code(0), b"out", b"")));
    }

    #[test]
    fn shutdown_drops_kept_results_and_is_idempotent() {
        let fake = FakeProcesses::scripted([(command("x"), Ok(Script::ends(Exit::Code(0))))]);
        let (service, completed) = service(&fake);
        assert!(service.start(1, command("x"), ROOMY));
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(1));

        service.shutdown();
        service.shutdown();

        assert_eq!(service.pending(), 0);
        assert_eq!(service.take(1), None);
    }

    #[test]
    fn a_start_after_shutdown_comes_to_shut_down_and_is_completed_at_once_with_no_spawn() {
        let fake = FakeProcesses::scripted([(command("x"), Ok(Script::ends(Exit::Code(0))))]);
        let (service, completed) = service(&fake);
        service.shutdown();

        assert!(service.start(7, command("x"), ROOMY));

        assert_eq!(completed.try_recv(), Ok(7));
        let Some(RunResult::Refused(refusal)) = service.take(7) else {
            panic!("a refusal");
        };
        assert_eq!(refusal.kind, RefusalKind::ShutDown);
        assert_eq!(fake.record().spawned, []);
    }

    #[test]
    fn output_past_the_limit_kills_the_group_and_comes_to_output_too_large() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .stdout("0123456789")
                .hold(Hold::UntilKilled)
                .members(1)),
        )]);
        let (service, completed) = service(&fake);

        assert!(service.start(1, command("x"), 4));

        assert_eq!(completed.recv_timeout(DEADLINE), Ok(1));
        assert_eq!(
            service.take(1),
            Some(RunResult::OutputTooLarge {
                stream: Stream::Out,
                limit: 4
            })
        );
        let child = fake.record().spawned[0].0;
        assert!(!fake.alive(child) && !fake.alive(child + 1));
    }

    // Seen to bite once by hand, on 2026-11-15: with the `child.kill()` in
    // `read`'s `Err` arm taken out, the child held until it is killed is
    // never ended, and the test fails waiting for the completion. With it
    // put back it passes.
    #[test]
    fn a_read_that_fails_kills_the_group_and_its_refusal_is_the_result_completed_once() {
        let refusal = Refusal::new(RefusalKind::Failed, "cannot read a child's stream: EIO");
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .stdout("out")
                .hold(Hold::UntilKilled)
                .members(1)
                .read_fails(Stream::Err, refusal.clone())),
        )]);
        let (service, completed) = service(&fake);

        assert!(service.start(1, command("x"), ROOMY));

        assert_eq!(completed.recv_timeout(DEADLINE), Ok(1));
        assert_eq!(service.take(1), Some(RunResult::Refused(refusal)));
        let child = fake.record().spawned[0].0;
        assert_eq!(fake.record().killed, [child]);
        assert!(!fake.alive(child) && !fake.alive(child + 1));
        assert!(completed.recv_timeout(Duration::from_millis(50)).is_err());
        assert_eq!(service.pending(), 0);
    }

    #[test]
    fn a_runs_child_has_no_input_so_a_child_that_reads_it_reads_its_end_at_once() {
        let fake = FakeProcesses::scripted([(
            command("cat"),
            Ok(Script::ends(Exit::Code(0)).step(crate::fake::Step::EchoUntilClosed(Stream::Out))),
        )]);
        let (service, completed) = service(&fake);

        assert!(service.start(1, command("cat"), ROOMY));

        assert_eq!(completed.recv_timeout(DEADLINE), Ok(1));
        assert_eq!(service.take(1), Some(ran(Exit::Code(0), b"", b"")));
        let child = fake.record().spawned[0].0;
        assert_eq!(fake.record().children[&child].input, Input::Closed);
    }

    #[test]
    fn output_at_the_limit_is_kept_whole() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).stdout("0123").stderr("abcd")),
        )]);
        let (service, completed) = service(&fake);

        assert!(service.start(1, command("x"), 4));

        assert_eq!(completed.recv_timeout(DEADLINE), Ok(1));
        assert_eq!(service.take(1), Some(ran(Exit::Code(0), b"0123", b"abcd")));
        assert!(Path::new("/dir").is_absolute());
    }

    #[test]
    fn a_head_run_past_its_limit_keeps_the_first_limit_bytes_of_its_output_and_kills_the_group() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .stdout("0123456789")
                .hold(Hold::UntilKilled)
                .members(1)),
        )]);
        let (service, completed) = service(&fake);

        assert!(service.start_head(1, command("x"), Some(b"in".to_vec()), 4));

        assert_eq!(completed.recv_timeout(DEADLINE), Ok(1));
        assert_eq!(
            service.take(1),
            Some(RunResult::Cut {
                stdout: b"0123".to_vec(),
                stderr: Vec::new(),
            })
        );
        let child = fake.record().spawned[0].0;
        assert_eq!(fake.record().killed, [child]);
        assert!(!fake.alive(child) && !fake.alive(child + 1));
        assert!(flushed(&service, &completed));
    }

    #[test]
    fn a_head_run_within_its_limit_comes_to_its_whole_output() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(1)).stdout("0123").stderr("ab")),
        )]);
        let (service, completed) = service(&fake);

        assert!(service.start_head(1, command("x"), None, 4));

        assert_eq!(completed.recv_timeout(DEADLINE), Ok(1));
        assert_eq!(service.take(1), Some(ran(Exit::Code(1), b"0123", b"ab")));
        assert_eq!(fake.record().killed, []);
    }

    #[test]
    fn a_head_runs_standard_error_past_its_limit_is_still_output_too_large() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .stderr("0123456789")
                .hold(Hold::UntilKilled)
                .members(1)),
        )]);
        let (service, completed) = service(&fake);

        assert!(service.start_head(1, command("x"), None, 4));

        assert_eq!(completed.recv_timeout(DEADLINE), Ok(1));
        assert_eq!(
            service.take(1),
            Some(RunResult::OutputTooLarge {
                stream: Stream::Err,
                limit: 4
            })
        );
    }

    #[test]
    fn a_cancelled_head_run_is_never_completed() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .hold(Hold::UntilKilled)
                .members(1)),
        )]);
        let (service, completed) = service(&fake);
        assert!(service.start_head(6, command("x"), Some(b"in".to_vec()), 4));
        assert!(fake.until(DEADLINE, |record| record.waiting.len() == 1));
        let child = fake.record().spawned[0].0;

        assert!(service.cancel(6));

        assert!(flushed(&service, &completed));
        assert!(!fake.alive(child) && !fake.alive(child + 1));
        assert!(completed.recv_timeout(Duration::from_millis(50)).is_err());
        assert_eq!(service.take(6), None);
    }
}

#[cfg(test)]
mod streaming {
    use std::sync::mpsc::{self, Receiver, TryRecvError};
    use std::time::Duration;

    use super::*;
    use crate::fake::{Blocked, FakeProcesses, Hold, Script, Step};
    use crate::frame::{Frames, Framing};
    use crate::{APP_IDENTITY, Environment};

    /// How long a test waits for something that should happen at once.
    const DEADLINE: Duration = Duration::from_secs(5);

    /// A bound no test's output reaches.
    const ROOMY: u64 = 1 << 20;

    fn command(script: &str) -> Command {
        Command::new("/bin/sh", ["-c", script], "/dir")
    }

    fn lines_with(input: Input, bound: u64) -> Streaming {
        Streaming {
            input,
            out: Framing::Lines,
            err: Framing::Lines,
            bound,
        }
    }

    fn service(fake: &FakeProcesses) -> (Service<FakeProcesses>, Receiver<u64>) {
        let (sender, completed) = mpsc::channel();
        let sender = Mutex::new(sender);
        let service = Service::new(fake.clone(), move |id| {
            sender
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .send(id)
                .ok();
        });
        (service, completed)
    }

    fn lines(lines: &[&str]) -> Frames {
        Frames::Lines(lines.iter().map(|line| line.as_bytes().to_vec()).collect())
    }

    #[test]
    fn every_child_is_started_without_the_apps_identity_whatever_its_command_said() {
        let mut cleared = command("run");
        cleared.environment = Environment {
            clear: true,
            set: vec![("A".into(), "1".into())],
            unset: vec!["B".into()],
        };
        let fake = FakeProcesses::scripted([
            (cleared.clone(), Ok(Script::ends(Exit::Code(0)))),
            (command("stream"), Ok(Script::ends(Exit::Code(0)))),
        ]);
        let (service, completed) = service(&fake);

        assert!(service.start(1, cleared, ROOMY));
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(1));
        assert!(matches!(
            opened(
                &service,
                &completed,
                2,
                command("stream"),
                lines_with(Input::Closed, ROOMY)
            ),
            Some(StreamReply::Opened)
        ));

        let unsets: Vec<Vec<String>> = fake
            .record()
            .spawned
            .iter()
            .map(|(_, command)| command.environment.unset.clone())
            .collect();
        assert_eq!(
            unsets,
            [
                vec!["B".to_owned(), APP_IDENTITY.to_owned()],
                vec![APP_IDENTITY.to_owned()]
            ]
        );
    }

    /// Opens `command` as the child `id` and takes the open's reply.
    fn opened(
        service: &Service<FakeProcesses>,
        completed: &Receiver<u64>,
        id: u64,
        command: Command,
        streaming: Streaming,
    ) -> Option<StreamReply> {
        assert!(service.open(id, command, streaming));
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(id));
        service.take_stream(id)
    }

    /// Reads the child `child` as the wait `wait`, and takes the delivery
    /// once it is completed.
    fn delivery(
        service: &Service<FakeProcesses>,
        completed: &Receiver<u64>,
        child: u64,
        wait: u64,
    ) -> Delivery {
        assert!(service.read(child, wait), "the read is taken");
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(wait));
        match service.take_stream(wait) {
            Some(StreamReply::Delivered(delivery)) => delivery,
            other => panic!("a delivery, not {other:?}"),
        }
    }

    fn refusal_kind(reply: Option<StreamReply>) -> Option<RefusalKind> {
        match reply {
            Some(StreamReply::Refused(refusal)) => Some(refusal.kind),
            _ => None,
        }
    }

    #[test]
    fn an_open_completes_its_id_once_with_opened() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).hold(Hold::UntilKilled)),
        )]);
        let (service, completed) = service(&fake);

        assert_eq!(
            opened(
                &service,
                &completed,
                1,
                command("x"),
                lines_with(Input::Closed, ROOMY)
            ),
            Some(StreamReply::Opened)
        );
        assert_eq!(service.take_stream(1), None, "taken once");
        assert_eq!(fake.record().spawned.len(), 1);
        assert!(service.cancel(1));
    }

    #[test]
    fn an_open_is_refused_before_a_spawn_at_a_spawn_and_for_a_bound_of_zero() {
        let fake = FakeProcesses::scripted([(command("x"), Ok(Script::ends(Exit::Code(0))))]);
        let (service, completed) = service(&fake);
        let closed = || lines_with(Input::Closed, ROOMY);

        let relative = Command::new("/bin/sh", [""; 0], "relative");
        assert_eq!(
            refusal_kind(opened(&service, &completed, 1, relative, closed())),
            Some(RefusalKind::RelativeDirectory)
        );
        assert_eq!(
            refusal_kind(opened(
                &service,
                &completed,
                2,
                command("unscripted"),
                closed()
            )),
            Some(RefusalKind::NotFound)
        );
        let zero = opened(
            &service,
            &completed,
            3,
            command("x"),
            lines_with(Input::Closed, 0),
        );
        let Some(StreamReply::Refused(refusal)) = zero else {
            panic!("refused");
        };
        assert_eq!(refusal.kind, RefusalKind::Failed);
        assert!(refusal.detail.contains("at least one byte"));
        assert_eq!(fake.record().spawned, [], "nothing was spawned");
        assert_eq!(service.pending(), 0);
    }

    #[test]
    fn an_id_in_use_is_refused_by_open_and_after_shutdown_an_open_is_refused_as_shut_down() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).hold(Hold::UntilKilled)),
        )]);
        let (service, completed) = service(&fake);
        assert!(service.start(1, command("x"), ROOMY));
        assert!(!service.open(1, command("x"), lines_with(Input::Closed, ROOMY)));
        assert_eq!(
            opened(
                &service,
                &completed,
                2,
                command("x"),
                lines_with(Input::Closed, ROOMY)
            ),
            Some(StreamReply::Opened)
        );
        assert!(!service.open(2, command("x"), lines_with(Input::Closed, ROOMY)));
        assert!(!service.start(2, command("x"), ROOMY));

        service.shutdown();

        assert_eq!(
            refusal_kind(opened(
                &service,
                &completed,
                3,
                command("x"),
                lines_with(Input::Closed, ROOMY)
            )),
            Some(RefusalKind::ShutDown)
        );
        assert_eq!(fake.record().spawned.len(), 2);
    }

    #[test]
    fn a_read_delivers_each_line_as_the_child_writes_it_while_the_child_waits_for_input() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).steps([
                Step::Write(Stream::Out, b"one\n".to_vec()),
                Step::EchoLine(Stream::Out),
            ])),
        )]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Pipe, ROOMY),
        );

        let first = delivery(&service, &completed, 1, 2);

        assert_eq!(first.out, lines(&["one"]));
        assert_eq!(first.err, lines(&[]));
        assert_eq!(first.ended, None);
        let child = fake.record().spawned[0].0;
        assert!(fake.alive(child));
        assert_eq!(fake.record().children[&child].blocked_on, Blocked::Input);
        assert!(service.cancel(1));
    }

    /// Reads the child `child` to its last delivery, with waits from
    /// `first`: every delivery, oldest first.
    fn to_the_end(
        service: &Service<FakeProcesses>,
        completed: &Receiver<u64>,
        child: u64,
        first: u64,
    ) -> Vec<Delivery> {
        let mut deliveries = Vec::new();
        for wait in first.. {
            let delivered = delivery(service, completed, child, wait);
            let ended = delivered.ended.is_some();
            deliveries.push(delivered);
            if ended {
                return deliveries;
            }
        }
        deliveries
    }

    fn all_bytes(deliveries: &[Delivery], stream: Stream) -> Vec<u8> {
        let mut all = Vec::new();
        for delivered in deliveries {
            let frames = if stream == Stream::Out {
                &delivered.out
            } else {
                &delivered.err
            };
            match frames {
                Frames::Bytes(bytes) => all.extend_from_slice(bytes),
                Frames::Lines(lines) => {
                    for line in lines {
                        all.extend_from_slice(line);
                        all.push(b'\n');
                    }
                }
            }
        }
        all
    }

    #[test]
    fn bytes_framing_delivers_every_byte_and_lines_framing_gives_the_unterminated_last_line() {
        let fake = FakeProcesses::scripted([
            (
                command("bytes"),
                Ok(Script::ends(Exit::Code(0)).stdout(b"a\xffb".to_vec())),
            ),
            (
                command("lines"),
                Ok(Script::ends(Exit::Code(0)).stdout("x\ny")),
            ),
        ]);
        let (service, completed) = service(&fake);
        let bytes = Streaming {
            input: Input::Closed,
            out: Framing::Bytes,
            err: Framing::Bytes,
            bound: ROOMY,
        };
        opened(&service, &completed, 1, command("bytes"), bytes);
        opened(
            &service,
            &completed,
            10,
            command("lines"),
            lines_with(Input::Closed, ROOMY),
        );

        assert_eq!(
            all_bytes(&to_the_end(&service, &completed, 1, 2), Stream::Out),
            b"a\xffb"
        );
        let lines_read = to_the_end(&service, &completed, 10, 11);
        let mut got = Vec::new();
        for delivered in &lines_read {
            if let Frames::Lines(lines) = &delivered.out {
                got.extend(lines.iter().cloned());
            }
        }
        assert_eq!(got, [b"x".to_vec(), b"y".to_vec()]);
        assert!(flushed(&service, &completed), "both are forgotten");
    }

    #[test]
    fn the_last_delivery_says_how_the_child_exited_only_after_every_frame_and_then_it_is_forgotten()
    {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(3)).stdout("a\nb").stderr("e\n")),
        )]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Closed, ROOMY),
        );

        let deliveries = to_the_end(&service, &completed, 1, 2);

        let (last, before) = deliveries.split_last().expect("a delivery");
        assert_eq!(last.ended, Some(End::Exited(Exit::Code(3))));
        assert!(before.iter().all(|delivered| delivered.ended.is_none()));
        assert_eq!(all_bytes(&deliveries, Stream::Out), b"a\nb\n");
        assert_eq!(all_bytes(&deliveries, Stream::Err), b"e\n");
        assert!(!service.read(1, 100), "the child is forgotten");
        assert!(flushed(&service, &completed));
        assert_eq!(service.held(1), None);
    }

    /// Asks for `ask` as the wait `wait` and takes its reply once it is
    /// completed.
    fn replied(
        service: &Service<FakeProcesses>,
        completed: &Receiver<u64>,
        wait: u64,
        ask: impl FnOnce() -> bool,
    ) -> Option<StreamReply> {
        assert!(ask(), "the request is taken");
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(wait));
        service.take_stream(wait)
    }

    #[test]
    fn a_write_reaches_the_childs_input_and_closing_it_ends_an_echoing_child() {
        let fake = FakeProcesses::scripted([(
            command("cat"),
            Ok(Script::ends(Exit::Code(0)).step(Step::EchoUntilClosed(Stream::Out))),
        )]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("cat"),
            lines_with(Input::Pipe, ROOMY),
        );

        assert_eq!(
            replied(&service, &completed, 2, || service.write(
                1,
                2,
                b"a\n".to_vec()
            )),
            Some(StreamReply::Written)
        );
        let child = fake.record().spawned[0].0;
        assert_eq!(
            fake.record().children[&child].input,
            Input::Pipe,
            "spawned with the streaming's input"
        );
        assert_eq!(fake.record().children[&child].received, b"a\n");
        assert_eq!(delivery(&service, &completed, 1, 3).out, lines(&["a"]));
        assert_eq!(
            replied(&service, &completed, 4, || service.close_input(1, 4)),
            Some(StreamReply::Written)
        );

        let last = to_the_end(&service, &completed, 1, 5);
        assert_eq!(
            last.last().and_then(|delivered| delivered.ended.clone()),
            Some(End::Exited(Exit::Code(0)))
        );
        assert!(flushed(&service, &completed));
    }

    // Seen to bite once by hand, on 2026-11-15: with `write_all` writing
    // from the start of the bytes each time, or moving its offset one byte
    // too far once, this fails at what the child received.
    #[test]
    fn a_write_many_times_the_input_pipe_arrives_whole_and_in_order() {
        let fake = FakeProcesses::scripted([(
            command("cat"),
            Ok(Script::ends(Exit::Code(0))
                .step(Step::EchoUntilClosed(Stream::Out))
                .pipe_capacity(4)),
        )]);
        let (service, completed) = service(&fake);
        let streaming = Streaming {
            input: Input::Pipe,
            out: Framing::Bytes,
            err: Framing::Bytes,
            bound: ROOMY,
        };
        opened(&service, &completed, 1, command("cat"), streaming);
        // 1,000 bytes, so at least 250 partial writes, and no run of them
        // repeats within 251 bytes: a resend or a wrong offset shows.
        let bytes: Vec<u8> = (0..1000_u32)
            .map(|at| u8::try_from(at % 251).expect("under 251"))
            .collect();

        assert_eq!(
            replied(&service, &completed, 2, || service.write(
                1,
                2,
                bytes.clone()
            )),
            Some(StreamReply::Written)
        );
        let child = fake.record().spawned[0].0;
        assert_eq!(fake.record().children[&child].received, bytes);
        assert_eq!(
            replied(&service, &completed, 3, || service.close_input(1, 3)),
            Some(StreamReply::Written)
        );

        let all = to_the_end(&service, &completed, 1, 4);
        assert_eq!(all_bytes(&all, Stream::Out), bytes, "echoed");
        assert_eq!(
            all.last().and_then(|delivered| delivered.ended.clone()),
            Some(End::Exited(Exit::Code(0)))
        );
        assert!(flushed(&service, &completed));
    }

    #[test]
    fn a_write_with_no_input_after_a_close_or_once_the_child_closed_it_is_input_closed() {
        let fake = FakeProcesses::scripted([
            (
                command("x"),
                Ok(Script::ends(Exit::Code(0)).hold(Hold::UntilKilled)),
            ),
            (
                command("closes"),
                Ok(Script::ends(Exit::Code(0))
                    .hold(Hold::UntilKilled)
                    .step(Step::CloseInput)),
            ),
        ]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Closed, ROOMY),
        );
        opened(
            &service,
            &completed,
            10,
            command("x"),
            lines_with(Input::Pipe, ROOMY),
        );
        opened(
            &service,
            &completed,
            20,
            command("closes"),
            lines_with(Input::Pipe, ROOMY),
        );

        let no_input = replied(&service, &completed, 2, || {
            service.write(1, 2, b"a".to_vec())
        });
        assert_eq!(refusal_kind(no_input), Some(RefusalKind::InputClosed));
        replied(&service, &completed, 11, || service.close_input(10, 11));
        let closed = replied(&service, &completed, 12, || {
            service.write(10, 12, b"a".to_vec())
        });
        assert_eq!(refusal_kind(closed), Some(RefusalKind::InputClosed));
        let by_the_child = replied(&service, &completed, 21, || {
            service.write(20, 21, b"a".to_vec())
        });
        let Some(StreamReply::Refused(refusal)) = by_the_child else {
            panic!("refused");
        };
        assert_eq!(refusal.kind, RefusalKind::InputClosed);
        assert!(refusal.detail.contains("/bin/sh"));
        assert!(!service.write(99, 30, b"a".to_vec()), "no such child");
        for child in [1, 10, 20] {
            assert!(service.cancel(child));
        }
    }

    /// Whether the readers of `child` come to be parked on its bound.
    fn comes_to_be_held(service: &Service<FakeProcesses>, child: u64) -> bool {
        let end = std::time::Instant::now() + DEADLINE;
        while std::time::Instant::now() < end {
            if service.held(child) == Some(true) {
                return true;
            }
            thread::yield_now();
        }
        false
    }

    /// `count` numbered lines, each `{n:05}` and a line feed.
    fn numbered(count: usize) -> Vec<u8> {
        (0..count)
            .flat_map(|n| format!("{n:05}\n").into_bytes())
            .collect()
    }

    #[test]
    fn a_child_at_the_bound_is_held_until_its_job_takes_a_delivery_then_goes_on_with_nothing_lost()
    {
        let script = numbered(16_667);
        assert!(script.len() >= 100_000);
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .stdout(script.clone())
                .pipe_capacity(100)),
        )]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Closed, 1000),
        );
        let child = fake.record().spawned[0].0;

        assert!(comes_to_be_held(&service, 1));
        let io = fake.record().children[&child].clone();
        assert_eq!(io.read[0], 1000, "read up to the bound, and no further");
        assert_eq!(io.written[0], 1100, "read plus the pipe's capacity");
        assert_eq!(io.blocked_on, Blocked::Pipe(Stream::Out));

        let first = delivery(&service, &completed, 1, 2);
        assert!(fake.until(DEADLINE, |record| record.children[&child].written[0] > 1100));
        let mut deliveries = vec![first];
        deliveries.extend(to_the_end(&service, &completed, 1, 3));

        assert_eq!(all_bytes(&deliveries, Stream::Out), script);
        assert_eq!(
            deliveries
                .last()
                .and_then(|delivered| delivered.ended.clone()),
            Some(End::Exited(Exit::Code(0)))
        );
    }

    #[test]
    fn output_faster_than_its_job_drains_it_arrives_complete_and_in_order_one_bound_at_a_time() {
        // The child outpaces the job: its pipe refills as soon as the
        // service reads, and the job takes one delivery of at most 16 bytes
        // for each read.
        let script = numbered(16_667);
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .stdout(script.clone())
                .pipe_capacity(8)),
        )]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Closed, 16),
        );

        let deliveries = to_the_end(&service, &completed, 1, 2);

        assert_eq!(all_bytes(&deliveries, Stream::Out), script);
        assert!(deliveries.len() >= script.len() / 16);
        assert!(deliveries.iter().all(|delivered| {
            let Frames::Lines(lines) = &delivered.out else {
                return false;
            };
            lines.iter().map(|line| line.len() + 1).sum::<usize>() <= 16
        }));
    }

    #[test]
    fn a_take_drains_everything_read_up_to_the_take_not_only_up_to_the_completion() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .stdout("a\nb\nc\n")
                .hold(Hold::UntilKilled)
                .pipe_capacity(2)),
        )]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Closed, 6),
        );
        assert!(service.read(1, 2));
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(2));

        // A bound of exactly the output: held once all of it is read.
        assert!(comes_to_be_held(&service, 1));
        let Some(StreamReply::Delivered(delivered)) = service.take_stream(2) else {
            panic!("a delivery");
        };

        assert_eq!(delivered.out, lines(&["a", "b", "c"]));
        assert!(completed.try_recv().is_err(), "one completion");
        assert!(service.cancel(1));
    }

    // Seen to bite once by hand, on 2026-11-15: with `Streamed::wake`
    // queueing a completion whatever `queued` says, so one for each chunk,
    // this fails at "exactly one completion".
    #[test]
    fn ten_thousand_chunks_while_a_read_is_pending_give_exactly_one_completion() {
        let lines_written = numbered(10_000);
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .steps(
                    lines_written
                        .chunks(6)
                        .map(|line| Step::Write(Stream::Out, line.to_vec())),
                )
                .pipe_capacity(6)),
        )]);
        let (service, completed) = service(&fake);
        let bound = lines_written.len() as u64;
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Closed, bound),
        );
        assert!(service.read(1, 2));
        assert!(!service.read(1, 3), "a second pending read is refused");

        assert!(comes_to_be_held(&service, 1), "every chunk is read");
        let child = fake.record().spawned[0].0;
        assert_eq!(fake.record().children[&child].read[0], lines_written.len());
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(2));
        assert!(completed.try_recv().is_err(), "exactly one completion");

        let Some(StreamReply::Delivered(first)) = service.take_stream(2) else {
            panic!("a delivery");
        };
        let Frames::Lines(first_lines) = &first.out else {
            panic!("lines");
        };
        assert_eq!(first_lines.len(), 10_000);
        let rest = to_the_end(&service, &completed, 1, 4);
        assert_eq!(rest.len(), 1, "one more read, one more completion");
        assert!(completed.try_recv().is_err(), "completions equal reads");
        let mut all = vec![first];
        all.extend(rest);
        assert_eq!(all_bytes(&all, Stream::Out), lines_written);
    }

    #[test]
    fn a_line_longer_than_the_bound_kills_the_group_and_ends_the_child_as_line_too_long() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .stdout(format!("whole\n{}", "x".repeat(5000)))
                .hold(Hold::UntilKilled)
                .members(1)),
        )]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Closed, 1024),
        );

        let deliveries = to_the_end(&service, &completed, 1, 2);

        let last = deliveries.last().expect("a delivery");
        assert_eq!(
            last.ended,
            Some(End::LineTooLong {
                stream: Stream::Out,
                bound: 1024
            })
        );
        assert_eq!(
            all_bytes(&deliveries, Stream::Out),
            b"whole\n",
            "intact before it"
        );
        let child = fake.record().spawned[0].0;
        assert!(fake.until(DEADLINE, |record| record.reaped == [child]));
        assert!(!fake.alive(child) && !fake.alive(child + 1));
        assert!(flushed(&service, &completed));
    }

    #[test]
    fn a_partial_line_exactly_the_bound_long_waits_for_the_stream_to_go_on_or_end() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).steps([
                Step::Write(Stream::Out, b"abcd".to_vec()),
                Step::AwaitInputClosed,
            ])),
        )]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Pipe, 4),
        );
        let child = fake.record().spawned[0].0;

        assert!(service.read(1, 2));
        assert!(fake.until(DEADLINE, |record| record.children[&child].read[0] == 4));
        assert!(
            completed.recv_timeout(Duration::from_millis(50)).is_err(),
            "not too long while the stream may yet end"
        );
        assert!(fake.record().killed.is_empty());
        assert!(service.close_input(1, 3));
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(3));

        assert_eq!(completed.recv_timeout(DEADLINE), Ok(2));
        let Some(StreamReply::Delivered(mut delivered)) = service.take_stream(2) else {
            panic!("a delivery");
        };
        if delivered.ended.is_none() {
            let rest = to_the_end(&service, &completed, 1, 4);
            delivered.ended = rest.last().and_then(|last| last.ended.clone());
            assert!(rest.iter().all(|more| more.out.is_empty()));
        }
        assert_eq!(delivered.out, lines(&["abcd"]));
        assert_eq!(delivered.ended, Some(End::Exited(Exit::Code(0))));
        assert!(fake.record().killed.is_empty());
    }

    // Seen to bite once by hand, on 2026-11-15: with a probe byte that is a
    // line feed taken into the outbox, so that it ends the line, "abcd" is
    // delivered and the child exits, and the test fails on the end.
    #[test]
    fn a_line_exactly_the_bound_long_then_its_line_feed_is_too_long_its_line_feed_counted() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).stdout("abcd\n")),
        )]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Closed, 4),
        );

        let deliveries = to_the_end(&service, &completed, 1, 2);

        let last = deliveries.last().expect("a delivery");
        assert_eq!(
            last.ended,
            Some(End::LineTooLong {
                stream: Stream::Out,
                bound: 4
            })
        );
        assert!(
            deliveries.iter().all(|delivered| delivered.out.is_empty()),
            "no line delivered"
        );
        let child = fake.record().spawned[0].0;
        assert!(fake.until(DEADLINE, |record| record.reaped == [child]));
    }

    // Seen to bite once by hand, on 2026-11-15: with the kill taken out of
    // `stream_reader`'s `Err` arm, the child held until it is killed is
    // never killed, and the test fails waiting for its reap; with the
    // `End::Failed` not kept, the failed stream never ends, and the test
    // fails waiting for the last delivery.
    #[test]
    fn a_read_that_fails_kills_the_group_and_ends_the_child_as_failed_the_frames_before_it_intact()
    {
        let refusal = Refusal::new(RefusalKind::Failed, "cannot read a child's stream: EIO");
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .stderr("e\n")
                .hold(Hold::UntilKilled)
                .members(1)
                .read_fails(Stream::Err, refusal.clone())),
        )]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Closed, ROOMY),
        );

        let deliveries = to_the_end(&service, &completed, 1, 2);

        let (last, before) = deliveries.split_last().expect("a delivery");
        assert_eq!(last.ended, Some(End::Failed(refusal)));
        assert!(before.iter().all(|delivered| delivered.ended.is_none()));
        assert_eq!(
            all_bytes(&deliveries, Stream::Err),
            b"e\n",
            "intact before it"
        );
        let child = fake.record().spawned[0].0;
        assert!(fake.until(DEADLINE, |record| record.reaped == [child]));
        assert_eq!(fake.record().killed, [child]);
        assert!(!fake.alive(child) && !fake.alive(child + 1));
        assert!(flushed(&service, &completed));
    }

    /// Flushes `service` and waits for the flush's completion, which must
    /// be the next on `completed`; then says whether nothing is pending. A
    /// live streaming child is not waited for, but a cancelled or forgotten
    /// one is, until it is reaped.
    fn flushed(service: &Service<FakeProcesses>, completed: &Receiver<u64>) -> bool {
        assert!(service.flush(FLUSH), "the flush's id is free");
        assert_eq!(completed.recv_timeout(DEADLINE), Ok(FLUSH));
        service.pending() == 0
    }

    /// The id of [`flushed`]'s flush: one no test names otherwise.
    const FLUSH: u64 = u64::MAX;

    /// Whether both readers of the child `child` come to let go of its
    /// streams. A reader completes a read before it lets go, so after this
    /// no reader can complete one.
    fn readers_done(fake: &FakeProcesses, child: u32) -> bool {
        fake.until(DEADLINE, |record| {
            record.children[&child].outputs_dropped == [true, true]
        })
    }

    #[test]
    fn a_cancel_of_a_held_child_kills_its_group_stops_its_readers_and_leaves_nothing_pending() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .stdout("y\n".repeat(1000))
                .hold(Hold::UntilKilled)
                .members(1)
                .pipe_capacity(4)),
        )]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Closed, 8),
        );
        assert!(comes_to_be_held(&service, 1));
        let child = fake.record().spawned[0].0;

        assert!(service.cancel(1));

        assert!(flushed(&service, &completed));
        assert!(!fake.alive(child) && !fake.alive(child + 1));
        assert_eq!(
            fake.record().children[&child].read[0],
            8,
            "no read after it"
        );
        assert_eq!(service.held(1), None);
        assert!(completed.recv_timeout(Duration::from_millis(50)).is_err());
    }

    #[test]
    fn a_cancel_of_a_child_in_a_pending_read_never_completes_the_read() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).step(Step::EchoLine(Stream::Out))),
        )]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Pipe, ROOMY),
        );
        assert!(service.read(1, 2));
        let child = fake.record().spawned[0].0;

        assert!(service.cancel(1));

        assert!(flushed(&service, &completed), "its waiter is done");
        assert!(readers_done(&fake, child));
        assert_eq!(completed.try_recv(), Err(TryRecvError::Empty));
        assert_eq!(service.take_stream(2), None);
    }

    #[test]
    fn a_cancel_with_its_readers_inside_a_read_never_completes_the_pending_read() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).step(Step::EchoLine(Stream::Out))),
        )]);
        let (service, completed) = service(&fake);
        fake.hold_reads();
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Pipe, ROOMY),
        );
        assert!(service.read(1, 2));
        assert!(fake.until(DEADLINE, |record| record.reads_parked == 2));
        let child = fake.record().spawned[0].0;

        assert!(service.cancel(1));
        fake.release_reads();

        assert!(flushed(&service, &completed), "its waiter is done");
        assert!(readers_done(&fake, child));
        assert_eq!(completed.try_recv(), Err(TryRecvError::Empty));
        assert_eq!(service.take_stream(2), None);
    }

    #[test]
    fn a_cancel_abandons_the_stream_before_the_kill_so_a_reader_back_from_a_read_reads_no_more() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .stdout("a\n")
                .step(Step::EchoLine(Stream::Out))),
        )]);
        let (service, completed) = service(&fake);
        fake.hold_reads();
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Pipe, ROOMY),
        );
        assert!(service.read(1, 2));
        assert!(fake.until(DEADLINE, |record| record.reads_parked == 2));
        let child = fake.record().spawned[0].0;
        fake.hold_kills();

        thread::scope(|scope| {
            let cancelling = scope.spawn(|| service.cancel(1));
            assert!(fake.until(DEADLINE, |record| record.kills_parked == 1));
            fake.release_reads();
            // The child is not killed yet, so its output is still open: a
            // reader back from its read that read again would block.
            let let_go = fake.until(DEADLINE, |record| {
                record.children[&child].read[0] == 2 && record.children[&child].outputs_dropped[0]
            });
            fake.release_kills();
            assert!(cancelling.join().expect("the cancel returns"));
            assert!(
                let_go,
                "the reader of out read what was there and let go, the kill still held"
            );
        });

        assert!(flushed(&service, &completed), "its waiter is done");
        assert!(readers_done(&fake, child));
        assert_eq!(completed.try_recv(), Err(TryRecvError::Empty));
        assert_eq!(service.take_stream(2), None);
    }

    #[test]
    fn shutdown_with_its_readers_inside_a_pending_read_never_completes_it() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).step(Step::EchoLine(Stream::Out))),
        )]);
        let (service, completed) = service(&fake);
        fake.hold_reads();
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Pipe, ROOMY),
        );
        assert!(service.read(1, 2));
        assert!(fake.until(DEADLINE, |record| record.reads_parked == 2));
        let child = fake.record().spawned[0].0;

        service.shutdown();
        fake.release_reads();

        assert!(readers_done(&fake, child));
        assert_eq!(completed.try_recv(), Err(TryRecvError::Empty));
    }

    #[test]
    fn a_cancelled_pending_read_is_never_completed_and_the_child_keeps_its_data() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .hold(Hold::UntilKilled)
                .step(Step::EchoLine(Stream::Out))),
        )]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Pipe, ROOMY),
        );
        assert!(service.read(1, 2));

        assert!(service.cancel(2));
        assert_eq!(service.pending(), 1, "the child alone");
        replied(&service, &completed, 3, || {
            service.write(1, 3, b"x\n".to_vec())
        });

        assert_eq!(delivery(&service, &completed, 1, 4).out, lines(&["x"]));
        assert!(completed.try_recv().is_err(), "the cancelled read never is");
        assert!(service.cancel(1));
        assert!(flushed(&service, &completed));
    }

    #[test]
    fn a_cancelled_write_blocked_on_a_child_that_does_not_read_is_never_completed() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .hold(Hold::UntilKilled)
                .pipe_capacity(2)),
        )]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Pipe, ROOMY),
        );
        assert!(service.write(1, 2, b"abc".to_vec()));
        assert!(fake.until(DEADLINE, |record| record.writes_blocked == 1));

        assert!(service.cancel(2));
        assert_eq!(service.pending(), 1, "the child alone");
        assert!(service.cancel(1));

        assert!(flushed(&service, &completed));
        assert!(fake.until(DEADLINE, |record| record.writes_blocked == 0));
        assert!(completed.recv_timeout(Duration::from_millis(50)).is_err());
    }

    #[test]
    fn shutdown_with_a_held_child_and_a_writer_blocked_on_a_child_that_does_not_read_returns_with_both_reaped()
     {
        let fake = FakeProcesses::scripted([
            (
                command("held"),
                Ok(Script::ends(Exit::Code(0))
                    .stdout("y\n".repeat(1000))
                    .hold(Hold::UntilKilled)
                    .members(1)
                    .pipe_capacity(4)),
            ),
            (
                command("deaf"),
                Ok(Script::ends(Exit::Code(0))
                    .hold(Hold::UntilKilled)
                    .pipe_capacity(2)),
            ),
        ]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("held"),
            lines_with(Input::Closed, 8),
        );
        opened(
            &service,
            &completed,
            2,
            command("deaf"),
            lines_with(Input::Pipe, ROOMY),
        );
        assert!(comes_to_be_held(&service, 1));
        assert!(service.write(2, 3, b"abc".to_vec()));
        assert!(fake.until(DEADLINE, |record| record.writes_blocked == 1));

        let (sender, returned) = mpsc::channel();
        let shutting = service.clone();
        thread::spawn(move || {
            shutting.shutdown();
            sender.send(()).ok();
        });

        assert_eq!(returned.recv_timeout(DEADLINE), Ok(()));
        let record = fake.record();
        assert_eq!(record.reaped.len(), 2);
        assert!(record.spawned.iter().all(|&(id, _)| !fake.alive(id)));
        assert_eq!(service.pending(), 0);
        assert!(completed.recv_timeout(Duration::from_millis(50)).is_err());
    }
}
