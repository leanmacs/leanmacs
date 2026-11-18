//! The fake of the port: processes that are a script, published so that
//! everything above the port is tested with no real process.
//!
//! [`FakeProcesses`] holds a script for each [`Command`] a test expects:
//! what the child writes to each stream, how it ends, when it ends
//! ([`Hold`]), how many other processes it starts in its group, and which
//! of their ids it writes to which file. A command with no script is
//! refused as [`RefusalKind::NotFound`], as a program that is not there
//! would be; a script may also be a refusal of any kind.
//!
//! It keeps the port's rules, which `tests/contract.rs` holds it to:
//!
//! - a child and its members are alive from the spawn; the child's stream
//!   closes once the child has ended and no member is alive;
//! - [`Child::wait`] blocks until the child has ended, then ends its
//!   members, then reaps the child; asked again it answers the same;
//! - [`Child::kill`] ends the child, as signal 9, and every member, and
//!   does nothing once the child has been reaped.
//!
//! It records every spawn, every kill that ended something and every reap,
//! gives fake ids from 1000, and answers whether an id is alive, a child
//! that has ended and is not reaped counted as alive, as a zombie is. A
//! test can wait on what it records with a deadline ([`FakeProcesses::until`])
//! instead of sleeping, hold a child in its run until it lets go
//! ([`Hold::UntilLetGo`], [`FakeProcesses::let_go`]), and hold every read
//! of a stream ([`FakeProcesses::hold_reads`]), so it can act while a run
//! is in flight. A script can make a stream's read fail
//! ([`Script::read_fails`]), as a broken pipe would.
//!
//! # A child that runs in steps
//!
//! After what it writes at the spawn, a scripted child does its
//! [`Script::steps`] in order: it writes to a stream, echoes a line of its
//! input or all of it, waits for its input to end, closes its own input,
//! or makes an empty file ([`Step`]). Its standard input is a pipe when its
//! spawn asks for one ([`Input::Pipe`]): [`Child::take_input`] gives a
//! [`FakeInput`], whose writes the child receives, and whose drop ends the
//! child's input. Each of its pipes holds [`Script::pipe_capacity`] unread
//! bytes, no limit by default: a write step stops at a full pipe, as a
//! child blocked in `write(2)` does, and a write to its input blocks at a
//! full one. It ends as its [`Hold`] says only once its steps are done.
//!
//! The fake is passive: on every interaction (a spawn, a read, a write to
//! an input, its drop, a kill, a let go) it takes each child as far as it
//! can go, under its lock, until the child waits for input or for room in
//! a pipe. Its [`Record::children`] say, for each child, the input it was
//! spawned with, what it received, whether its input is closed, what it
//! has written and what has been read of each stream, and what it waits
//! for ([`Blocked`]).
//!
//! [`Flaws`] makes a fake that breaks a rule, for the contract's own tests:
//! that is how they show the contract bites.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use crate::contract::Ground;
use crate::{
    Child, ChildInput, Command, Exit, Input, Output, Processes, Refusal, RefusalKind, Stream,
};

/// When a scripted child ends.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Hold {
    /// At once: it has ended by the time `spawn` returns.
    Ends,
    /// When the test lets go of it ([`FakeProcesses::let_go`]), or when it is
    /// killed.
    UntilLetGo,
    /// Only when it is killed.
    UntilKilled,
}

/// Which process of a scripted child's group writes its id to a file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Writer {
    /// The child itself, as `echo $$` does.
    Child,
    /// The `n`th process it started in its group, from 0, as `echo $!` does.
    Member(usize),
    /// The `n`th process it started outside its group, from 0.
    Escaped(usize),
}

/// What a scripted child does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Script {
    /// What it writes to its standard output.
    pub stdout: Vec<u8>,
    /// What it writes to its standard error.
    pub stderr: Vec<u8>,
    /// How it ends, unless it is killed first.
    pub exit: Exit,
    /// When it ends.
    pub hold: Hold,
    /// How many processes it starts in its group, each alive until the group
    /// is ended.
    pub members: usize,
    /// How many processes it starts outside its group, as `setsid` does,
    /// each holding both streams. No kill of the group and no wait ends
    /// them: each is alive until the ground ends it ([`Ground::end`]).
    pub escaped: usize,
    /// The files it writes an id to, and whose id each holds.
    pub writes: Vec<(PathBuf, Writer)>,
    /// The streams whose read fails, each with its refusal, once the
    /// stream's bytes have been read.
    pub read_fails: Vec<(Stream, Refusal)>,
    /// What it does after writing `stdout` and `stderr`, in order. Its
    /// hold applies once they are done.
    pub steps: Vec<Step>,
    /// How many unread bytes each of its pipes holds, its standard input's
    /// among them: a write step stops while its pipe is full, and so does a
    /// write to its input. `None` is no limit.
    pub pipe_capacity: Option<usize>,
}

/// One thing a scripted child does, after what it writes at the spawn.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Step {
    /// Writes these bytes to the stream, as its pipe takes them.
    Write(Stream, Vec<u8>),
    /// Waits for one line of its input, then writes it with its `\n`; at
    /// the end of its input, writes what is left of it.
    EchoLine(Stream),
    /// Writes back everything it is written until its input ends, as `cat`
    /// does.
    EchoUntilClosed(Stream),
    /// Reads its input, and drops it, until it ends.
    AwaitInputClosed,
    /// Closes its own standard input: a later write to it is refused.
    CloseInput,
    /// Makes an empty file at this path, as `: > name` does.
    Touch(PathBuf),
}

/// What a scripted child is waiting for, if anything.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Blocked {
    /// Nothing: it is done with its steps, or it has ended.
    #[default]
    Nothing,
    /// Its standard input.
    Input,
    /// Room in the pipe of this stream.
    Pipe(Stream),
}

/// What the fake has seen of one child's streams and input.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ChildRecord {
    /// The standard input it was spawned with.
    pub input: Input,
    /// Every byte written to its standard input.
    pub received: Vec<u8>,
    /// Whether its standard input has been closed by the editor's side.
    pub input_closed: bool,
    /// How many bytes it has put into each pipe, out then err.
    pub written: [usize; 2],
    /// How many bytes of each pipe have been read, out then err.
    pub read: [usize; 2],
    /// What it is waiting for now.
    pub blocked_on: Blocked,
    /// Whether each stream's reader has let go of it, out then err: the
    /// stream was taken and its [`FakeOutput`] dropped. A reader is done
    /// with the stream once this is set.
    pub outputs_dropped: [bool; 2],
}

impl Script {
    /// A child that writes nothing, starts nothing and ends at once as
    /// `exit`.
    pub fn ends(exit: Exit) -> Self {
        Self {
            stdout: Vec::new(),
            stderr: Vec::new(),
            exit,
            hold: Hold::Ends,
            members: 0,
            escaped: 0,
            writes: Vec::new(),
            read_fails: Vec::new(),
            steps: Vec::new(),
            pipe_capacity: None,
        }
    }

    /// The same child, doing `step` after what it does already.
    #[must_use]
    pub fn step(mut self, step: Step) -> Self {
        self.steps.push(step);
        self
    }

    /// The same child, doing `steps` after what it does already.
    #[must_use]
    pub fn steps(mut self, steps: impl IntoIterator<Item = Step>) -> Self {
        self.steps.extend(steps);
        self
    }

    /// The same child, whose pipes each hold `bytes` unread bytes.
    #[must_use]
    pub const fn pipe_capacity(mut self, bytes: usize) -> Self {
        self.pipe_capacity = Some(bytes);
        self
    }

    /// The same child, writing `bytes` to its standard output.
    #[must_use]
    pub fn stdout(mut self, bytes: impl Into<Vec<u8>>) -> Self {
        self.stdout = bytes.into();
        self
    }

    /// The same child, writing `bytes` to its standard error.
    #[must_use]
    pub fn stderr(mut self, bytes: impl Into<Vec<u8>>) -> Self {
        self.stderr = bytes.into();
        self
    }

    /// The same child, ending when `hold` says.
    #[must_use]
    pub fn hold(mut self, hold: Hold) -> Self {
        self.hold = hold;
        self
    }

    /// The same child, starting `count` processes in its group.
    #[must_use]
    pub fn members(mut self, count: usize) -> Self {
        self.members = count;
        self
    }

    /// The same child, starting `count` processes outside its group.
    #[must_use]
    pub fn escaped(mut self, count: usize) -> Self {
        self.escaped = count;
        self
    }

    /// The same child, with `writer`'s id written to `file`.
    #[must_use]
    pub fn writes(mut self, file: impl Into<PathBuf>, writer: Writer) -> Self {
        self.writes.push((file.into(), writer));
        self
    }

    /// The same child, whose `stream` gives its bytes and then fails to be
    /// read, with `refusal`, instead of waiting to close.
    #[must_use]
    pub fn read_fails(mut self, stream: Stream, refusal: Refusal) -> Self {
        self.read_fails.push((stream, refusal));
        self
    }
}

/// The rules a flawed fake breaks, for the contract's own tests. The fake
/// keeps every rule with [`Flaws::default`].
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Flaws {
    /// A kill of the group ends the child and not its members: a kill, and
    /// the one a wait makes once the child has ended.
    pub kill_leader_only: bool,
    /// A wait does not reap: the child stays alive, a zombie, for ever.
    pub no_reap: bool,
    /// A wait leaves the members alive when the child has ended by itself.
    pub members_survive: bool,
    /// A write to a child's input is accepted and lost.
    pub drop_input: bool,
    /// A write to an input the child has closed says it succeeded.
    pub epipe_ok: bool,
}

/// What the fake has seen, as a test reads it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Record {
    /// Every spawn, oldest first: the child's id and the command.
    pub spawned: Vec<(u32, Command)>,
    /// Every kill that ended something, oldest first, by the child's id.
    pub killed: Vec<u32>,
    /// Every child reaped, oldest first.
    pub reaped: Vec<u32>,
    /// The children whose wait is blocked now.
    pub waiting: Vec<u32>,
    /// How many reads are parked on the hold now.
    pub reads_parked: usize,
    /// How many waits are parked on the hold of reaps now: their child has
    /// ended and is not yet reaped.
    pub reaps_parked: usize,
    /// How many kills are parked on the hold of kills now: nothing they
    /// end has ended yet.
    pub kills_parked: usize,
    /// Each child's streams and input, by its id.
    pub children: HashMap<u32, ChildRecord>,
    /// How many writes to a child's input are blocked now, on a full pipe.
    pub writes_blocked: usize,
}

/// One scripted child, its group, and where it is in its life.
#[derive(Debug)]
struct Group {
    /// What it was scripted to do.
    script: Script,
    /// How it ended, once it has.
    ended: Option<Exit>,
    /// Whether its members are alive.
    members_alive: bool,
    /// The processes it started outside its group, each with whether it
    /// is alive.
    escaped: Vec<(u32, bool)>,
    /// Whether it has been reaped.
    reaped: bool,
    /// Every byte it has put into each pipe, out then err.
    pipes: [Vec<u8>; 2],
    /// Its steps: what it writes at the spawn, then its script's.
    steps: Vec<Step>,
    /// How many of its steps it has done.
    step: usize,
    /// The write it is in the middle of: its stream, its bytes and how
    /// many it has written.
    writing: Option<(Stream, Vec<u8>, usize)>,
    /// How many bytes of its input it has read.
    consumed: usize,
    /// Whether its standard input is a pipe.
    piped: bool,
    /// Whether it has closed its own standard input.
    closed_its_input: bool,
    /// Whether the test let go of it ([`Hold::UntilLetGo`]).
    let_go: bool,
}

impl Group {
    /// Whether its streams have closed: it has ended and no member, and no
    /// process it started outside its group, holds them.
    fn closed(&self) -> bool {
        self.ended.is_some() && !self.members_alive && self.escaped.iter().all(|&(_, alive)| !alive)
    }

    /// Whether it is done with its steps.
    fn done(&self) -> bool {
        self.writing.is_none() && self.step == self.steps.len()
    }

    /// How many more unread bytes one of its pipes takes, when it holds
    /// `unread`.
    fn room(&self, unread: usize) -> usize {
        room(self.script.pipe_capacity, unread)
    }

    /// Goes on as far as it can: through its steps, until one waits for
    /// input or for room in a pipe, and then ends as its hold says. `io` is
    /// its record, and `touched` the files the fake's children made.
    fn advance(&mut self, io: &mut ChildRecord, touched: &mut HashSet<PathBuf>) {
        if self.ended.is_some() {
            io.blocked_on = Blocked::Nothing;
            return;
        }
        // Its input ends when the editor closes it, when it closes it
        // itself, or at once when it is not a pipe.
        let input_ended = io.input_closed || self.closed_its_input || !self.piped;
        let capacity = self.script.pipe_capacity;
        loop {
            if let Some((stream, bytes, at)) = &mut self.writing {
                let slot = usize::from(*stream == Stream::Err);
                let room = room(capacity, io.written[slot] - io.read[slot]);
                if room == 0 {
                    io.blocked_on = Blocked::Pipe(*stream);
                    return;
                }
                let count = room.min(bytes.len() - *at);
                self.pipes[slot].extend_from_slice(&bytes[*at..*at + count]);
                io.written[slot] += count;
                *at += count;
                if *at == bytes.len() {
                    self.writing = None;
                }
                continue;
            }
            let Some(step) = self.steps.get(self.step).cloned() else {
                break;
            };
            let unread = &io.received[self.consumed..];
            match step {
                Step::Write(stream, bytes) => self.writing = Some((stream, bytes, 0)),
                Step::EchoLine(stream) => {
                    let line = match unread.iter().position(|&byte| byte == b'\n') {
                        Some(end) => unread[..=end].to_vec(),
                        None if input_ended => unread.to_vec(),
                        None => {
                            io.blocked_on = Blocked::Input;
                            return;
                        }
                    };
                    self.consumed += line.len();
                    self.writing = Some((stream, line, 0));
                }
                Step::EchoUntilClosed(stream) => {
                    if !unread.is_empty() {
                        let bytes = unread.to_vec();
                        self.consumed += bytes.len();
                        self.writing = Some((stream, bytes, 0));
                        continue;
                    }
                    if !input_ended {
                        io.blocked_on = Blocked::Input;
                        return;
                    }
                }
                Step::AwaitInputClosed => {
                    self.consumed = io.received.len();
                    if !input_ended {
                        io.blocked_on = Blocked::Input;
                        return;
                    }
                }
                Step::CloseInput => self.closed_its_input = true,
                Step::Touch(path) => {
                    touched.insert(path);
                }
            }
            self.step += 1;
        }
        io.blocked_on = Blocked::Nothing;
        let ends = match self.script.hold {
            Hold::Ends => true,
            Hold::UntilLetGo => self.let_go,
            Hold::UntilKilled => false,
        };
        if ends {
            self.ended = Some(self.script.exit);
        }
    }
}

/// What the fake holds.
#[derive(Debug, Default)]
struct State {
    /// The script of each command it expects.
    scripts: HashMap<Command, Result<Script, Refusal>>,
    /// The next id it gives.
    next_id: u32,
    /// Each child it started, by its id.
    groups: HashMap<u32, Group>,
    /// The group each member is in, by the member's id.
    member_of: HashMap<u32, u32>,
    /// The child that started each process outside its group, by the
    /// process's id.
    escaped_from: HashMap<u32, u32>,
    /// The ids the children wrote, by file.
    files: HashMap<PathBuf, u32>,
    /// The files the ground made.
    made: Vec<PathBuf>,
    /// The empty files the children made ([`Step::Touch`]).
    touched: HashSet<PathBuf>,
    /// Whether reads are held.
    reads_held: bool,
    /// Whether reaps are held.
    reaps_held: bool,
    /// Whether kills are held.
    kills_held: bool,
    /// What a test reads.
    record: Record,
    /// The rules it breaks.
    flaws: Flaws,
}

impl State {
    /// Takes every child as far as it can go now.
    fn advance(&mut self) {
        let Self {
            groups,
            record,
            touched,
            ..
        } = self;
        for (id, group) in groups.iter_mut() {
            if let Some(io) = record.children.get_mut(id) {
                group.advance(io, touched);
            }
        }
    }
}

/// How many more unread bytes a pipe of `capacity` takes, when it holds
/// `unread`: no limit for no capacity.
fn room(capacity: Option<usize>, unread: usize) -> usize {
    capacity.map_or(usize::MAX, |capacity| capacity.saturating_sub(unread))
}

/// What the fake's handles share.
#[derive(Debug, Default)]
struct Shared {
    /// The state. The lock is held only to look and to change, never while
    /// a caller's code runs.
    state: Mutex<State>,
    /// Told whenever the state changes.
    changed: Condvar,
}

impl Shared {
    /// Locks the state.
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Blocks on `state` until `ready` holds of it.
    fn wait_until<'a>(
        &self,
        mut state: MutexGuard<'a, State>,
        mut ready: impl FnMut(&State) -> bool,
    ) -> MutexGuard<'a, State> {
        while !ready(&state) {
            state = self
                .changed
                .wait(state)
                .unwrap_or_else(PoisonError::into_inner);
        }
        state
    }
}

/// Processes that are a script: the port's fake. A cheap handle: clones
/// share one state, so a test keeps one and hands the other to what it
/// tests.
#[derive(Debug, Clone, Default)]
pub struct FakeProcesses {
    /// The state its handles share.
    shared: Arc<Shared>,
}

/// The first id the fake gives.
const FIRST_ID: u32 = 1000;

impl FakeProcesses {
    /// A fake that expects no command: every spawn is refused as not found.
    pub fn new() -> Self {
        Self::flawed(Flaws::default())
    }

    /// A fake that breaks the rules `flaws` names, for the contract's own
    /// tests.
    pub fn flawed(flaws: Flaws) -> Self {
        let fake = Self::default();
        {
            let mut state = fake.shared.state();
            state.next_id = FIRST_ID;
            state.flaws = flaws;
        }
        fake
    }

    /// A fake that expects each of `scripts`.
    pub fn scripted(scripts: impl IntoIterator<Item = (Command, Result<Script, Refusal>)>) -> Self {
        let fake = Self::new();
        for (command, script) in scripts {
            fake.script(command, script);
        }
        fake
    }

    /// Expects `command`: each spawn of it does what `script` says.
    pub fn script(&self, command: Command, script: Result<Script, Refusal>) {
        self.shared.state().scripts.insert(command, script);
    }

    /// What the fake has seen so far.
    pub fn record(&self) -> Record {
        self.shared.state().record.clone()
    }

    /// Blocks until `ready` holds of what the fake has seen, or until
    /// `deadline` has passed, and says whether it held.
    pub fn until(&self, deadline: Duration, ready: impl Fn(&Record) -> bool) -> bool {
        let end = Instant::now() + deadline;
        let mut state = self.shared.state();
        loop {
            if ready(&state.record) {
                return true;
            }
            let left = end.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return false;
            }
            state = self
                .shared
                .changed
                .wait_timeout(state, left)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }

    /// Ends the child `id`, held by [`Hold::UntilLetGo`], as its script says,
    /// once it is done with its steps. Nothing for a child that has ended or
    /// is held only by a kill.
    pub fn let_go(&self, id: u32) {
        let mut state = self.shared.state();
        if let Some(group) = state.groups.get_mut(&id) {
            group.let_go = true;
        }
        state.advance();
        drop(state);
        self.shared.changed.notify_all();
    }

    /// Lets go of every child held by [`Hold::UntilLetGo`].
    pub fn let_go_all(&self) {
        let ids: Vec<u32> = self.shared.state().groups.keys().copied().collect();
        for id in ids {
            self.let_go(id);
        }
    }

    /// Holds every read of a stream from now on: a read parks before it
    /// reads, until [`FakeProcesses::release_reads`].
    pub fn hold_reads(&self) {
        self.shared.state().reads_held = true;
    }

    /// Lets every parked read go, and holds none from now on.
    pub fn release_reads(&self) {
        self.shared.state().reads_held = false;
        self.shared.changed.notify_all();
    }

    /// Holds every reap from now on: a wait whose child has ended parks
    /// before it reaps, until [`FakeProcesses::release_reaps`]. The child
    /// stays alive, as a zombie would, while its wait is parked.
    pub fn hold_reaps(&self) {
        self.shared.state().reaps_held = true;
    }

    /// Lets every parked wait reap, and holds none from now on.
    pub fn release_reaps(&self) {
        self.shared.state().reaps_held = false;
        self.shared.changed.notify_all();
    }

    /// Holds every kill from now on: a kill parks before it ends anything,
    /// until [`FakeProcesses::release_kills`].
    pub fn hold_kills(&self) {
        self.shared.state().kills_held = true;
    }

    /// Lets every parked kill go on, and holds none from now on.
    pub fn release_kills(&self) {
        self.shared.state().kills_held = false;
        self.shared.changed.notify_all();
    }

    /// Whether the process `id` is alive: a child until it is reaped, a
    /// member until its group is ended, a process started outside the group
    /// until the ground ends it. An id the fake never gave is not.
    pub fn alive(&self, id: u32) -> bool {
        let state = self.shared.state();
        if let Some(group) = state.groups.get(&id) {
            return !group.reaped;
        }
        if let Some(leader) = state.escaped_from.get(&id) {
            return state.groups.get(leader).is_some_and(|group| {
                group
                    .escaped
                    .iter()
                    .any(|&(escaped, alive)| escaped == id && alive)
            });
        }
        state
            .member_of
            .get(&id)
            .and_then(|leader| state.groups.get(leader))
            .is_some_and(|group| group.members_alive)
    }

    /// Ends the process `id`, one a child started outside its group, which
    /// nothing else ends; its streams close once nothing else holds them.
    /// Nothing for any other id.
    pub fn end(&self, id: u32) {
        let mut state = self.shared.state();
        let Some(&leader) = state.escaped_from.get(&id) else {
            return;
        };
        if let Some(group) = state.groups.get_mut(&leader) {
            for (escaped, alive) in &mut group.escaped {
                if *escaped == id {
                    *alive = false;
                }
            }
        }
        drop(state);
        self.shared.changed.notify_all();
    }

    /// The files the ground made, oldest first.
    pub fn made(&self) -> Vec<PathBuf> {
        self.shared.state().made.clone()
    }

    /// The ground the contract needs, over this fake: the ids its children
    /// wrote, and which are alive.
    pub fn ground(&self) -> FakeGround {
        FakeGround { fake: self.clone() }
    }

    /// Ends the group `id`: the child as signal 9 unless it has ended, and
    /// every member, unless the flaws say otherwise. Nothing once the child
    /// has been reaped.
    fn kill(&self, id: u32) {
        let mut state = self.shared.state();
        if state.kills_held {
            state.record.kills_parked += 1;
            self.shared.changed.notify_all();
            state = self.shared.wait_until(state, |state| !state.kills_held);
            state.record.kills_parked -= 1;
        }
        let leader_only = state.flaws.kill_leader_only;
        let Some(group) = state.groups.get_mut(&id) else {
            return;
        };
        if group.reaped {
            return;
        }
        let mut ended = false;
        if group.ended.is_none() {
            group.ended = Some(Exit::Signal(9));
            ended = true;
        }
        if !leader_only && group.members_alive {
            group.members_alive = false;
            ended = true;
        }
        if ended {
            state.record.killed.push(id);
        }
        state.advance();
        drop(state);
        self.shared.changed.notify_all();
    }

    /// The port's wait, for the child `id`.
    fn wait(&self, id: u32) -> Exit {
        let mut state = self.shared.state();
        if let Some(exit) = state
            .groups
            .get(&id)
            .filter(|g| g.reaped)
            .and_then(|g| g.ended)
        {
            return exit;
        }
        state.record.waiting.push(id);
        self.shared.changed.notify_all();
        state = self.shared.wait_until(state, |state| {
            state
                .groups
                .get(&id)
                .is_none_or(|group| group.ended.is_some())
        });
        state.record.waiting.retain(|&waiting| waiting != id);
        if state.reaps_held {
            state.record.reaps_parked += 1;
            self.shared.changed.notify_all();
            state = self.shared.wait_until(state, |state| !state.reaps_held);
            state.record.reaps_parked -= 1;
        }
        let flaws = state.flaws;
        let exit = match state.groups.get_mut(&id) {
            Some(group) => {
                if !flaws.members_survive && !flaws.kill_leader_only {
                    group.members_alive = false;
                }
                let first_reap = !flaws.no_reap && !group.reaped;
                if first_reap {
                    group.reaped = true;
                }
                let exit = group.ended.unwrap_or(Exit::Signal(9));
                if first_reap {
                    state.record.reaped.push(id);
                }
                exit
            }
            None => Exit::Signal(9),
        };
        drop(state);
        self.shared.changed.notify_all();
        exit
    }

    /// The port's read, of the stream `stream` of the child `id`: the next
    /// bytes in its pipe, waiting for the child to write some; or 0 once
    /// they have all been read and the stream has closed; or the refusal
    /// the script gives once they have all been read and the child is done
    /// with its steps.
    fn read(&self, id: u32, stream: Stream, buffer: &mut [u8]) -> Result<usize, Refusal> {
        let slot = usize::from(stream == Stream::Err);
        let mut state = self.shared.state();
        if state.reads_held {
            state.record.reads_parked += 1;
            self.shared.changed.notify_all();
            state = self.shared.wait_until(state, |state| !state.reads_held);
            state.record.reads_parked -= 1;
        }
        loop {
            let State { groups, record, .. } = &mut *state;
            let (Some(group), Some(io)) = (groups.get(&id), record.children.get_mut(&id)) else {
                return Ok(0);
            };
            let at = io.read[slot];
            let unread = &group.pipes[slot][at..];
            if !unread.is_empty() {
                let count = buffer.len().min(unread.len());
                buffer[..count].copy_from_slice(&unread[..count]);
                io.read[slot] += count;
                state.advance();
                drop(state);
                self.shared.changed.notify_all();
                return Ok(count);
            }
            if group.done()
                && let Some((_, refusal)) = group
                    .script
                    .read_fails
                    .iter()
                    .find(|(failing, _)| *failing == stream)
            {
                return Err(refusal.clone());
            }
            if group.closed() {
                return Ok(0);
            }
            state = self
                .shared
                .changed
                .wait(state)
                .unwrap_or_else(PoisonError::into_inner);
        }
    }

    /// The port's write, to the input of the child `id`: as many of
    /// `bytes` as its pipe has room for, waiting for room; or a refusal
    /// once the child has closed its input or ended.
    fn write(&self, id: u32, program: &str, bytes: &[u8]) -> Result<usize, Refusal> {
        let mut state = self.shared.state();
        let mut blocked = false;
        let written = loop {
            let flaws = state.flaws;
            let State { groups, record, .. } = &mut *state;
            let (Some(group), Some(io)) = (groups.get(&id), record.children.get_mut(&id)) else {
                break Ok(0);
            };
            if group.ended.is_some() || group.closed_its_input {
                break if flaws.epipe_ok {
                    Ok(bytes.len())
                } else {
                    Err(Refusal::new(
                        RefusalKind::InputClosed,
                        format!(
                            "cannot write to the standard input of `{program}`: the fake's child has closed it"
                        ),
                    ))
                };
            }
            let room = group.room(io.received.len() - group.consumed);
            if room > 0 || bytes.is_empty() {
                let count = room.min(bytes.len());
                if !flaws.drop_input {
                    io.received.extend_from_slice(&bytes[..count]);
                }
                state.advance();
                break Ok(count);
            }
            if !blocked {
                blocked = true;
                state.record.writes_blocked += 1;
                self.shared.changed.notify_all();
            }
            state = self
                .shared
                .changed
                .wait(state)
                .unwrap_or_else(PoisonError::into_inner);
        };
        if blocked {
            state.record.writes_blocked -= 1;
        }
        drop(state);
        self.shared.changed.notify_all();
        written
    }

    /// Closes the input of the child `id`, from the editor's side.
    fn close_input(&self, id: u32) {
        let mut state = self.shared.state();
        if let Some(io) = state.record.children.get_mut(&id) {
            io.input_closed = true;
        }
        state.advance();
        drop(state);
        self.shared.changed.notify_all();
    }

    /// Records that the reader of child `id`'s `stream` has let go of it.
    fn drop_output(&self, id: u32, stream: Stream) {
        let slot = match stream {
            Stream::Out => 0,
            Stream::Err => 1,
        };
        let mut state = self.shared.state();
        if let Some(io) = state.record.children.get_mut(&id) {
            io.outputs_dropped[slot] = true;
        }
        drop(state);
        self.shared.changed.notify_all();
    }
}

impl Processes for FakeProcesses {
    type Child = FakeChild;

    fn spawn(&self, command: &Command, input: Input) -> Result<FakeChild, Refusal> {
        let mut state = self.shared.state();
        let script = state.scripts.get(command).cloned().unwrap_or_else(|| {
            Err(Refusal::new(
                RefusalKind::NotFound,
                format!(
                    "cannot start `{}` in {}: the fake has no script for it",
                    command.program,
                    command.directory.display()
                ),
            ))
        })?;
        let id = state.next_id;
        let after = |n: usize| id + u32::try_from(n).unwrap_or(u32::MAX);
        let members: Vec<u32> = (1..=script.members).map(after).collect();
        let escaped: Vec<u32> = (1..=script.escaped)
            .map(|n| after(script.members + n))
            .collect();
        state.next_id = after(script.members + script.escaped + 1);
        for &member in &members {
            state.member_of.insert(member, id);
        }
        for &process in &escaped {
            state.escaped_from.insert(process, id);
        }
        for (file, writer) in &script.writes {
            let written = match writer {
                Writer::Child => Some(id),
                Writer::Member(n) => members.get(*n).copied(),
                Writer::Escaped(n) => escaped.get(*n).copied(),
            };
            if let Some(written) = written {
                state.files.insert(file.clone(), written);
            }
        }
        // What it writes at the spawn is its first steps.
        let mut steps = Vec::new();
        for (stream, bytes) in [(Stream::Out, &script.stdout), (Stream::Err, &script.stderr)] {
            if !bytes.is_empty() {
                steps.push(Step::Write(stream, bytes.clone()));
            }
        }
        steps.extend(script.steps.iter().cloned());
        let piped = input == Input::Pipe;
        state.groups.insert(
            id,
            Group {
                script,
                members_alive: !members.is_empty(),
                escaped: escaped.iter().map(|&process| (process, true)).collect(),
                ended: None,
                reaped: false,
                pipes: [Vec::new(), Vec::new()],
                steps,
                step: 0,
                writing: None,
                consumed: 0,
                piped,
                closed_its_input: false,
                let_go: false,
            },
        );
        state.record.children.insert(
            id,
            ChildRecord {
                input,
                ..ChildRecord::default()
            },
        );
        state.record.spawned.push((id, command.clone()));
        state.advance();
        drop(state);
        self.shared.changed.notify_all();
        Ok(FakeChild {
            fake: self.clone(),
            id,
            program: command.program.clone(),
            taken: [false; 2],
            input: piped,
        })
    }
}

/// A child the fake started.
#[derive(Debug)]
pub struct FakeChild {
    /// The fake that started it.
    fake: FakeProcesses,
    /// Its id.
    id: u32,
    /// Its program, which a refusal of its input names.
    program: String,
    /// Whether each stream, out then err, has been taken.
    taken: [bool; 2],
    /// Whether its input is there to take.
    input: bool,
}

impl Child for FakeChild {
    type Output = FakeOutput;
    type Input = FakeInput;

    fn id(&self) -> u32 {
        self.id
    }

    fn take_output(&mut self, stream: Stream) -> Option<FakeOutput> {
        let slot = match stream {
            Stream::Out => 0,
            Stream::Err => 1,
        };
        if self.taken[slot] {
            return None;
        }
        self.taken[slot] = true;
        Some(FakeOutput {
            fake: self.fake.clone(),
            id: self.id,
            stream,
        })
    }

    fn take_input(&mut self) -> Option<FakeInput> {
        if !std::mem::take(&mut self.input) {
            return None;
        }
        Some(FakeInput {
            fake: self.fake.clone(),
            id: self.id,
            program: self.program.clone(),
        })
    }

    fn wait(&self) -> Exit {
        self.fake.wait(self.id)
    }

    fn kill(&self) {
        self.fake.kill(self.id);
    }
}

/// A stream of a child the fake started.
#[derive(Debug)]
pub struct FakeOutput {
    /// The fake that started the child.
    fake: FakeProcesses,
    /// The child's id.
    id: u32,
    /// Which of its streams this is.
    stream: Stream,
}

impl Output for FakeOutput {
    fn read(&mut self, buffer: &mut [u8]) -> Result<usize, Refusal> {
        self.fake.read(self.id, self.stream, buffer)
    }
}

impl Drop for FakeOutput {
    fn drop(&mut self) {
        self.fake.drop_output(self.id, self.stream);
    }
}

/// The standard input of a child the fake started. Dropping it closes it.
#[derive(Debug)]
pub struct FakeInput {
    /// The fake that started the child.
    fake: FakeProcesses,
    /// The child's id.
    id: u32,
    /// The child's program, which a refusal names.
    program: String,
}

impl ChildInput for FakeInput {
    fn write(&mut self, bytes: &[u8]) -> Result<usize, Refusal> {
        self.fake.write(self.id, &self.program, bytes)
    }
}

impl Drop for FakeInput {
    fn drop(&mut self) {
        self.fake.close_input(self.id);
    }
}

/// The ground of the contract over a fake: the ids its children wrote to
/// files, and which ids are alive.
#[derive(Debug, Clone)]
pub struct FakeGround {
    /// The fake.
    fake: FakeProcesses,
}

/// How long the fake's ground waits for something that should happen at
/// once. The fake is synchronous, so only a fake that breaks a rule waits
/// this long.
const FAKE_DEADLINE: Duration = Duration::from_secs(2);

impl Ground for FakeGround {
    fn make_file(&self, path: &Path) -> Result<(), String> {
        self.fake.shared.state().made.push(path.to_path_buf());
        Ok(())
    }

    fn written(&self, path: &Path) -> Option<u32> {
        let end = Instant::now() + FAKE_DEADLINE;
        let mut state = self.fake.shared.state();
        loop {
            if let Some(&id) = state.files.get(path) {
                return Some(id);
            }
            let left = end.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return None;
            }
            state = self
                .fake
                .shared
                .changed
                .wait_timeout(state, left)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }

    fn exists(&self, path: &Path) -> bool {
        let state = self.fake.shared.state();
        state.touched.contains(path)
            || state.files.contains_key(path)
            || state.made.iter().any(|made| made == path)
    }

    fn alive(&self, id: u32) -> bool {
        self.fake.alive(id)
    }

    fn end(&self, id: u32) {
        self.fake.end(id);
    }

    fn escapes(&self) -> bool {
        true
    }

    fn deadline(&self) -> Duration {
        FAKE_DEADLINE
    }
}

#[cfg(test)]
mod tests {
    use std::thread;

    use super::*;

    const DEADLINE: Duration = Duration::from_secs(5);

    fn command(script: &str) -> Command {
        Command::new("/bin/sh", ["-c", script], "/dir")
    }

    fn read_all(output: &mut FakeOutput) -> Vec<u8> {
        let mut all = Vec::new();
        let mut buffer = [0; 3];
        loop {
            let count = output.read(&mut buffer).expect("the fake reads");
            if count == 0 {
                return all;
            }
            all.extend_from_slice(&buffer[..count]);
        }
    }

    #[test]
    fn an_unscripted_command_is_refused_as_not_found_naming_the_program_and_the_directory() {
        let fake = FakeProcesses::new();

        let refusal = fake
            .spawn(&command("true"), Input::Closed)
            .expect_err("refused");

        assert_eq!(refusal.kind, RefusalKind::NotFound);
        assert!(refusal.detail.contains("/bin/sh") && refusal.detail.contains("/dir"));
        assert_eq!(fake.record().spawned, []);
    }

    #[test]
    fn a_script_may_be_a_refusal() {
        let refusal = Refusal::new(RefusalKind::Denied, "no");
        let fake = FakeProcesses::scripted([(command("x"), Err(refusal.clone()))]);

        assert_eq!(
            fake.spawn(&command("x"), Input::Closed)
                .expect_err("refused"),
            refusal
        );
    }

    #[test]
    fn a_child_that_ends_at_once_gives_its_streams_and_its_exit_and_is_reaped_by_its_wait() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(3)).stdout("out\n").stderr("err")),
        )]);
        let mut child = fake.spawn(&command("x"), Input::Closed).expect("spawned");
        let id = child.id();
        let mut out = child.take_output(Stream::Out).expect("out");
        let mut err = child.take_output(Stream::Err).expect("err");
        assert!(child.take_output(Stream::Out).is_none());

        assert_eq!(read_all(&mut out), b"out\n");
        assert_eq!(read_all(&mut err), b"err");
        assert!(
            fake.alive(id),
            "a child that ended and is not reaped is alive"
        );
        assert_eq!(child.wait(), Exit::Code(3));
        assert!(!fake.alive(id));
        assert_eq!(child.wait(), Exit::Code(3), "asked again, the same");
        assert_eq!(fake.record().reaped, [id]);
        assert_eq!(fake.record().spawned, [(id, command("x"))]);
        assert_eq!(id, FIRST_ID);
    }

    #[test]
    fn a_kill_ends_the_child_as_signal_9_and_its_members_and_does_nothing_after_the_reap() {
        let fake = FakeProcesses::scripted([(
            command("family"),
            Ok(Script::ends(Exit::Code(0))
                .hold(Hold::UntilKilled)
                .members(1)
                .writes("/dir/grandchild", Writer::Member(0))),
        )]);
        let child = fake
            .spawn(&command("family"), Input::Closed)
            .expect("spawned");
        let grandchild = fake
            .ground()
            .written(Path::new("/dir/grandchild"))
            .expect("written");
        assert!(fake.alive(grandchild));

        let waiter = thread::scope(|scope| {
            let waiting = scope.spawn(|| child.wait());
            assert!(fake.until(DEADLINE, |record| record.waiting == [child.id()]));
            child.kill();
            waiting.join().expect("the wait returns")
        });

        assert_eq!(waiter, Exit::Signal(9));
        assert!(!fake.alive(child.id()) && !fake.alive(grandchild));
        child.kill();
        assert_eq!(
            fake.record().killed,
            [child.id()],
            "a kill after the reap ends nothing"
        );
    }

    #[test]
    fn a_wait_ends_the_members_of_a_child_that_ended_by_itself_and_its_streams_close() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).stdout("a").members(2)),
        )]);
        let mut child = fake.spawn(&command("x"), Input::Closed).expect("spawned");
        let mut out = child.take_output(Stream::Out).expect("out");
        let members = [child.id() + 1, child.id() + 2];
        assert!(members.iter().all(|&member| fake.alive(member)));

        let reading = thread::spawn(move || read_all(&mut out));
        assert_eq!(child.wait(), Exit::Code(0));

        assert!(members.iter().all(|&member| !fake.alive(member)));
        assert_eq!(reading.join().expect("the read ends"), b"a");
    }

    #[test]
    fn a_child_held_until_let_go_ends_as_scripted_when_let_go() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(4)).hold(Hold::UntilLetGo)),
        )]);
        let child = fake.spawn(&command("x"), Input::Closed).expect("spawned");

        let exit = thread::scope(|scope| {
            let waiting = scope.spawn(|| child.wait());
            assert!(fake.until(DEADLINE, |record| record.waiting.len() == 1));
            fake.let_go_all();
            waiting.join().expect("the wait returns")
        });

        assert_eq!(exit, Exit::Code(4));
    }

    #[test]
    fn a_stream_scripted_to_fail_gives_its_bytes_then_the_refusal_while_the_child_runs() {
        let refusal = Refusal::new(RefusalKind::Failed, "cannot read a child's stream: EIO");
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .stderr("e")
                .hold(Hold::UntilKilled)
                .read_fails(Stream::Err, refusal.clone())),
        )]);
        let mut child = fake.spawn(&command("x"), Input::Closed).expect("spawned");
        let mut err = child.take_output(Stream::Err).expect("err");
        let mut buffer = [0; 3];

        assert_eq!(err.read(&mut buffer), Ok(1));
        assert_eq!(err.read(&mut buffer), Err(refusal));
        assert!(fake.alive(child.id()), "the failure ends nothing");
        child.kill();
        child.wait();
    }

    #[test]
    fn an_escaped_process_outlives_the_group_kill_and_holds_the_streams_until_the_ground_ends_it() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .stdout("a")
                .hold(Hold::UntilKilled)
                .members(1)
                .escaped(1)
                .writes("/dir/escaped", Writer::Escaped(0))),
        )]);
        let mut child = fake.spawn(&command("x"), Input::Closed).expect("spawned");
        let mut out = child.take_output(Stream::Out).expect("out");
        let ground = fake.ground();
        let escaped = ground.written(Path::new("/dir/escaped")).expect("written");
        assert_eq!(escaped, child.id() + 2, "after the child and its member");
        assert!(fake.alive(escaped));
        let reading = thread::spawn(move || read_all(&mut out));

        child.kill();
        assert_eq!(child.wait(), Exit::Signal(9));

        assert!(!fake.alive(child.id()) && !fake.alive(child.id() + 1));
        assert!(fake.alive(escaped), "the group kill does not reach it");
        assert!(!reading.is_finished(), "it holds the stream open");
        ground.end(escaped);
        assert!(!fake.alive(escaped));
        assert_eq!(reading.join().expect("the read ends"), b"a");
    }

    #[test]
    fn a_held_reap_parks_a_wait_after_the_child_has_ended_until_released() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).hold(Hold::UntilKilled)),
        )]);
        let child = fake.spawn(&command("x"), Input::Closed).expect("spawned");
        fake.hold_reaps();

        thread::scope(|scope| {
            let waiting = scope.spawn(|| child.wait());
            child.kill();
            assert!(fake.until(DEADLINE, |record| record.reaps_parked == 1));
            assert!(fake.alive(child.id()), "ended, not reaped");
            fake.release_reaps();
            assert_eq!(waiting.join().expect("the wait returns"), Exit::Signal(9));
        });

        assert!(!fake.alive(child.id()));
        assert_eq!(fake.record().reaps_parked, 0);
    }

    #[test]
    fn a_held_kill_parks_before_it_ends_anything_until_released() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).hold(Hold::UntilKilled)),
        )]);
        let child = fake.spawn(&command("x"), Input::Closed).expect("spawned");
        fake.hold_kills();

        thread::scope(|scope| {
            let killing = scope.spawn(|| child.kill());
            assert!(fake.until(DEADLINE, |record| record.kills_parked == 1));
            assert_eq!(fake.record().killed, Vec::<u32>::new(), "nothing ended yet");
            fake.release_kills();
            killing.join().expect("the kill returns");
        });

        assert_eq!(fake.record().killed, vec![child.id()]);
        assert_eq!(fake.record().kills_parked, 0);
    }

    #[test]
    fn held_reads_park_until_released() {
        let fake =
            FakeProcesses::scripted([(command("x"), Ok(Script::ends(Exit::Code(0)).stdout("a")))]);
        let mut child = fake.spawn(&command("x"), Input::Closed).expect("spawned");
        let mut out = child.take_output(Stream::Out).expect("out");
        fake.hold_reads();

        let reading = thread::spawn(move || read_all(&mut out));
        assert!(fake.until(DEADLINE, |record| record.reads_parked == 1));
        fake.release_reads();
        child.wait();

        assert_eq!(reading.join().expect("the read ends"), b"a");
    }

    fn read_some(output: &mut FakeOutput) -> Vec<u8> {
        let mut buffer = [0; 64];
        let count = output.read(&mut buffer).expect("the fake reads");
        buffer[..count].to_vec()
    }

    fn io(fake: &FakeProcesses, id: u32) -> ChildRecord {
        fake.record().children.get(&id).cloned().expect("a child")
    }

    #[test]
    fn dropping_a_childs_stream_is_recorded_for_that_stream_alone() {
        let fake = FakeProcesses::scripted([(command("x"), Ok(Script::ends(Exit::Code(0))))]);
        let mut child = fake.spawn(&command("x"), Input::Closed).expect("spawned");
        let out = child.take_output(Stream::Out).expect("out");
        let err = child.take_output(Stream::Err).expect("err");
        assert_eq!(io(&fake, child.id()).outputs_dropped, [false, false]);

        drop(err);

        assert_eq!(io(&fake, child.id()).outputs_dropped, [false, true]);
        drop(out);
        assert_eq!(io(&fake, child.id()).outputs_dropped, [true, true]);
    }

    #[test]
    fn a_command_with_no_input_has_none_to_take_and_a_piped_one_gives_it_once() {
        let fake = FakeProcesses::scripted([(command("x"), Ok(Script::ends(Exit::Code(0))))]);

        let mut closed = fake.spawn(&command("x"), Input::Closed).expect("spawned");
        let mut open = fake.spawn(&command("x"), Input::Pipe).expect("spawned");

        assert!(closed.take_input().is_none());
        assert!(open.take_input().is_some());
        assert!(open.take_input().is_none(), "taken once");
    }

    #[test]
    fn a_child_that_echoes_until_closed_gives_back_what_it_was_written_and_ends_at_the_close() {
        let fake = FakeProcesses::scripted([(
            command("cat"),
            Ok(Script::ends(Exit::Code(0)).step(Step::EchoUntilClosed(Stream::Out))),
        )]);
        let mut child = fake.spawn(&command("cat"), Input::Pipe).expect("spawned");
        let mut input = child.take_input().expect("an input");
        let mut out = child.take_output(Stream::Out).expect("out");
        assert_eq!(io(&fake, child.id()).blocked_on, Blocked::Input);

        assert_eq!(input.write(b"a\n\xff"), Ok(3));
        assert_eq!(read_some(&mut out), b"a\n\xff");
        assert_eq!(io(&fake, child.id()).received, b"a\n\xff");
        assert!(fake.alive(child.id()));
        drop(input);

        assert!(io(&fake, child.id()).input_closed);
        assert_eq!(child.wait(), Exit::Code(0));
        assert_eq!(read_all(&mut out), b"");
    }

    #[test]
    fn a_stepped_child_writes_waits_for_a_line_echoes_it_and_ends_once_its_input_closes() {
        let fake = FakeProcesses::scripted([(
            command("steps"),
            Ok(Script::ends(Exit::Code(4)).steps([
                Step::Write(Stream::Out, b"one\n".to_vec()),
                Step::EchoLine(Stream::Out),
                Step::Write(Stream::Err, b"err\n".to_vec()),
                Step::AwaitInputClosed,
            ])),
        )]);
        let mut child = fake.spawn(&command("steps"), Input::Pipe).expect("spawned");
        let id = child.id();
        let mut input = child.take_input().expect("an input");
        let mut out = child.take_output(Stream::Out).expect("out");
        let mut err = child.take_output(Stream::Err).expect("err");

        assert_eq!(read_some(&mut out), b"one\n");
        let record = io(&fake, id);
        assert_eq!(record.blocked_on, Blocked::Input);
        assert_eq!(record.written, [4, 0]);
        assert_eq!(record.read, [4, 0]);
        assert!(fake.alive(id));

        assert_eq!(input.write(b"tw"), Ok(2));
        assert_eq!(io(&fake, id).blocked_on, Blocked::Input, "half a line");
        assert_eq!(input.write(b"o\n"), Ok(2));
        assert_eq!(read_some(&mut out), b"two\n");
        assert_eq!(read_some(&mut err), b"err\n");
        assert_eq!(io(&fake, id).blocked_on, Blocked::Input);
        drop(input);

        assert_eq!(child.wait(), Exit::Code(4));
    }

    #[test]
    fn a_child_that_closes_its_input_refuses_a_later_write_as_input_closed() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).hold(Hold::UntilKilled).steps([
                Step::CloseInput,
                Step::Write(Stream::Out, b"closed\n".to_vec()),
            ])),
        )]);
        let mut child = fake.spawn(&command("x"), Input::Pipe).expect("spawned");
        let mut input = child.take_input().expect("an input");

        let refusal = input.write(b"x").expect_err("refused");

        assert_eq!(refusal.kind, RefusalKind::InputClosed);
        child.kill();
        child.wait();
    }

    #[test]
    fn a_full_pipe_holds_the_child_until_it_is_read() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .stdout("0123456789")
                .pipe_capacity(4)
                .step(Step::Touch(PathBuf::from("/dir/finished")))),
        )]);
        let mut child = fake.spawn(&command("x"), Input::Closed).expect("spawned");
        let id = child.id();
        let mut out = child.take_output(Stream::Out).expect("out");
        let ground = fake.ground();

        let record = io(&fake, id);
        assert_eq!(record.written, [4, 0]);
        assert_eq!(record.blocked_on, Blocked::Pipe(Stream::Out));
        assert!(!ground.exists(Path::new("/dir/finished")));
        assert!(fake.alive(id));

        let mut buffer = [0; 3];
        assert_eq!(out.read(&mut buffer), Ok(3));
        assert_eq!(io(&fake, id).written, [7, 0], "read plus the capacity");
        assert_eq!(read_all(&mut out), b"3456789");

        assert!(ground.exists(Path::new("/dir/finished")));
        assert_eq!(io(&fake, id).blocked_on, Blocked::Nothing);
        assert_eq!(child.wait(), Exit::Code(0));
    }

    #[test]
    fn a_write_to_a_child_that_does_not_read_blocks_at_the_capacity_until_the_child_is_killed() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .hold(Hold::UntilKilled)
                .pipe_capacity(2)),
        )]);
        let mut child = fake.spawn(&command("x"), Input::Pipe).expect("spawned");
        let mut input = child.take_input().expect("an input");
        assert_eq!(input.write(b"abc"), Ok(2), "a partial write");

        let writing = thread::spawn(move || input.write(b"c"));
        assert!(fake.until(DEADLINE, |record| record.writes_blocked == 1));
        child.kill();

        let refusal = writing
            .join()
            .expect("the write returns")
            .expect_err("refused");
        assert_eq!(refusal.kind, RefusalKind::InputClosed);
        child.wait();
    }

    #[test]
    fn a_child_left_by_let_go_ends_only_once_its_steps_are_done() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(5))
                .hold(Hold::UntilLetGo)
                .step(Step::AwaitInputClosed)),
        )]);
        let mut child = fake.spawn(&command("x"), Input::Pipe).expect("spawned");
        let input = child.take_input().expect("an input");

        fake.let_go(child.id());
        let exit = thread::scope(|scope| {
            let waiting = scope.spawn(|| child.wait());
            assert!(fake.until(DEADLINE, |record| record.waiting.len() == 1));
            assert!(!waiting.is_finished(), "held by its step");
            drop(input);
            waiting.join().expect("the wait returns")
        });
        assert_eq!(exit, Exit::Code(5));
    }

    #[test]
    fn a_fake_that_drops_input_accepts_writes_and_loses_them() {
        let fake = FakeProcesses::flawed(Flaws {
            drop_input: true,
            ..Flaws::default()
        });
        fake.script(
            command("cat"),
            Ok(Script::ends(Exit::Code(0)).step(Step::EchoUntilClosed(Stream::Out))),
        );
        let mut child = fake.spawn(&command("cat"), Input::Pipe).expect("spawned");
        let mut input = child.take_input().expect("an input");

        assert_eq!(input.write(b"lost"), Ok(4));
        assert_eq!(io(&fake, child.id()).received, b"");
        drop(input);
        child.wait();
    }

    #[test]
    fn a_fake_that_says_a_write_to_a_closed_input_succeeded_is_flawed() {
        let fake = FakeProcesses::flawed(Flaws {
            epipe_ok: true,
            ..Flaws::default()
        });
        fake.script(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .hold(Hold::UntilKilled)
                .step(Step::CloseInput)),
        );
        let mut child = fake.spawn(&command("x"), Input::Pipe).expect("spawned");
        let mut input = child.take_input().expect("an input");

        assert_eq!(input.write(b"x"), Ok(1));
        child.kill();
        child.wait();
    }

    #[test]
    fn an_id_the_fake_never_gave_is_not_alive_and_the_ground_records_what_it_made() {
        let fake = FakeProcesses::new();
        assert!(!fake.alive(7));
        fake.ground()
            .make_file(Path::new("/dir/made"))
            .expect("made");
        assert_eq!(fake.made(), [PathBuf::from("/dir/made")]);
    }
}
