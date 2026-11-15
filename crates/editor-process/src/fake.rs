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
//! is in flight.
//!
//! [`Flaws`] makes a fake that breaks a rule, for the contract's own tests:
//! that is how they show the contract bites.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use crate::contract::Ground;
use crate::{Child, Command, Exit, Output, Processes, Refusal, RefusalKind, Stream};

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
    /// The files it writes an id to, and whose id each holds.
    pub writes: Vec<(PathBuf, Writer)>,
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
            writes: Vec::new(),
        }
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

    /// The same child, with `writer`'s id written to `file`.
    #[must_use]
    pub fn writes(mut self, file: impl Into<PathBuf>, writer: Writer) -> Self {
        self.writes.push((file.into(), writer));
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
    /// Whether it has been reaped.
    reaped: bool,
}

impl Group {
    /// Whether its streams have closed: it has ended and no member holds
    /// them.
    fn closed(&self) -> bool {
        self.ended.is_some() && !self.members_alive
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
    /// The ids the children wrote, by file.
    files: HashMap<PathBuf, u32>,
    /// The files the ground made.
    made: Vec<PathBuf>,
    /// Whether reads are held.
    reads_held: bool,
    /// What a test reads.
    record: Record,
    /// The rules it breaks.
    flaws: Flaws,
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

    /// Ends the child `id`, held by [`Hold::UntilLetGo`], as its script says.
    /// Nothing for a child that has ended or is held only by a kill.
    pub fn let_go(&self, id: u32) {
        let mut state = self.shared.state();
        if let Some(group) = state.groups.get_mut(&id)
            && group.ended.is_none()
            && group.script.hold == Hold::UntilLetGo
        {
            group.ended = Some(group.script.exit);
        }
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

    /// Whether the process `id` is alive: a child until it is reaped, a
    /// member until its group is ended. An id the fake never gave is not.
    pub fn alive(&self, id: u32) -> bool {
        let state = self.shared.state();
        if let Some(group) = state.groups.get(&id) {
            return !group.reaped;
        }
        state
            .member_of
            .get(&id)
            .and_then(|leader| state.groups.get(leader))
            .is_some_and(|group| group.members_alive)
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

    /// The port's read, of the stream `stream` of the child `id`, from
    /// `at`: the next bytes, or 0 once they have all been read and the
    /// stream has closed.
    fn read(&self, id: u32, stream: Stream, at: usize, buffer: &mut [u8]) -> usize {
        let mut state = self.shared.state();
        if state.reads_held {
            state.record.reads_parked += 1;
            self.shared.changed.notify_all();
            state = self.shared.wait_until(state, |state| !state.reads_held);
            state.record.reads_parked -= 1;
        }
        let Some(bytes) = state.groups.get(&id).map(|group| match stream {
            Stream::Out => group.script.stdout.clone(),
            Stream::Err => group.script.stderr.clone(),
        }) else {
            return 0;
        };
        if at < bytes.len() {
            let count = buffer.len().min(bytes.len() - at);
            buffer[..count].copy_from_slice(&bytes[at..at + count]);
            return count;
        }
        drop(self.shared.wait_until(state, |state| {
            state.groups.get(&id).is_none_or(Group::closed)
        }));
        0
    }
}

impl Processes for FakeProcesses {
    type Child = FakeChild;

    fn spawn(&self, command: &Command) -> Result<FakeChild, Refusal> {
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
        let members: Vec<u32> = (1..=script.members)
            .map(|n| id + u32::try_from(n).unwrap_or(u32::MAX))
            .collect();
        state.next_id = id + 1 + u32::try_from(script.members).unwrap_or(0);
        for &member in &members {
            state.member_of.insert(member, id);
        }
        for (file, writer) in &script.writes {
            let written = match writer {
                Writer::Child => Some(id),
                Writer::Member(n) => members.get(*n).copied(),
            };
            if let Some(written) = written {
                state.files.insert(file.clone(), written);
            }
        }
        let ended = (script.hold == Hold::Ends).then_some(script.exit);
        state.groups.insert(
            id,
            Group {
                script,
                members_alive: !members.is_empty(),
                ended,
                reaped: false,
            },
        );
        state.record.spawned.push((id, command.clone()));
        drop(state);
        self.shared.changed.notify_all();
        Ok(FakeChild {
            fake: self.clone(),
            id,
            taken: [false; 2],
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
    /// Whether each stream, out then err, has been taken.
    taken: [bool; 2],
}

impl Child for FakeChild {
    type Output = FakeOutput;

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
            at: 0,
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
    /// How many of its bytes have been read.
    at: usize,
}

impl Output for FakeOutput {
    fn read(&mut self, buffer: &mut [u8]) -> Result<usize, Refusal> {
        let count = self.fake.read(self.id, self.stream, self.at, buffer);
        self.at += count;
        Ok(count)
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

    fn alive(&self, id: u32) -> bool {
        self.fake.alive(id)
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

        let refusal = fake.spawn(&command("true")).expect_err("refused");

        assert_eq!(refusal.kind, RefusalKind::NotFound);
        assert!(refusal.detail.contains("/bin/sh") && refusal.detail.contains("/dir"));
        assert_eq!(fake.record().spawned, []);
    }

    #[test]
    fn a_script_may_be_a_refusal() {
        let refusal = Refusal::new(RefusalKind::Denied, "no");
        let fake = FakeProcesses::scripted([(command("x"), Err(refusal.clone()))]);

        assert_eq!(fake.spawn(&command("x")).expect_err("refused"), refusal);
    }

    #[test]
    fn a_child_that_ends_at_once_gives_its_streams_and_its_exit_and_is_reaped_by_its_wait() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(3)).stdout("out\n").stderr("err")),
        )]);
        let mut child = fake.spawn(&command("x")).expect("spawned");
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
        let child = fake.spawn(&command("family")).expect("spawned");
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
        let mut child = fake.spawn(&command("x")).expect("spawned");
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
        let child = fake.spawn(&command("x")).expect("spawned");

        let exit = thread::scope(|scope| {
            let waiting = scope.spawn(|| child.wait());
            assert!(fake.until(DEADLINE, |record| record.waiting.len() == 1));
            fake.let_go_all();
            waiting.join().expect("the wait returns")
        });

        assert_eq!(exit, Exit::Code(4));
    }

    #[test]
    fn held_reads_park_until_released() {
        let fake =
            FakeProcesses::scripted([(command("x"), Ok(Script::ends(Exit::Code(0)).stdout("a")))]);
        let mut child = fake.spawn(&command("x")).expect("spawned");
        let mut out = child.take_output(Stream::Out).expect("out");
        fake.hold_reads();

        let reading = thread::spawn(move || read_all(&mut out));
        assert!(fake.until(DEADLINE, |record| record.reads_parked == 1));
        fake.release_reads();
        child.wait();

        assert_eq!(reading.join().expect("the read ends"), b"a");
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
