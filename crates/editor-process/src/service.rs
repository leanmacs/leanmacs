//! The service above the port: runs to their end, owned from spawn to
//! reap.
//!
//! [`Service`] is what the editor asks for a process. A run is started
//! with an id the caller chose ([`Service::start`]) and returns at once;
//! its thread does the rest and, when the run has come to something,
//! keeps the result under the id and calls the `complete` closure the
//! service was made with. The caller takes the result once
//! ([`Service::take`]).
//!
//! # A run
//!
//! The run's thread:
//!
//! 1. refuses a directory that is not absolute, or a program that names a
//!    directory without being absolute ([`refusal_before_spawn`]), before
//!    any spawn;
//! 2. spawns the command; a refusal is the run's result;
//! 3. takes both streams and starts a reader thread for each, which keeps
//!    up to `limit` bytes; a stream with more than that kills the group,
//!    and the run comes to [`RunResult::OutputTooLarge`], never to output
//!    cut short;
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
//! one reader for each stream.
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
//! ended: no portable mechanism reaches it.
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
//! - **[`Service::pending`]** counts the runs not over, a cancelled one
//!   being over once its child is reaped, and the results not taken: a
//!   readout for tests.

use std::collections::HashMap;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread;

use crate::{
    Child, Command, Exit, Output, Processes, Refusal, RefusalKind, Stream, refusal_before_spawn,
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
}

/// What the service holds.
struct State<C> {
    /// Whether it has shut down.
    shut: bool,
    /// Each run not yet over, by its id.
    runs: HashMap<u64, Run<C>>,
    /// How many runs' threads have not finished.
    active: usize,
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
    /// A read failed.
    Failed(Refusal),
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
struct Delivery {
    /// Where it goes.
    reads: Arc<Reads>,
    /// Which stream, out (0) or err (1).
    slot: usize,
    /// How the reading ended, once it has.
    read: Option<Read>,
}

impl Drop for Delivery {
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
    /// with a run's id when its result is kept.
    pub fn new(processes: P, complete: impl Fn(u64) + Send + Sync + 'static) -> Self {
        Self {
            inner: Arc::new(Inner {
                processes,
                complete: Box::new(complete),
                state: Mutex::new(State {
                    shut: false,
                    runs: HashMap::new(),
                    active: 0,
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
        let mut state = self.inner.state();
        if state.runs.contains_key(&id) {
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
            .spawn(move || inner.run(id, &command, limit))
            .is_ok();
        if !started {
            let mut state = self.inner.state();
            state.runs.remove(&id);
            state.active -= 1;
            drop(state);
            self.inner.finished.notify_all();
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

    /// Cancels the run `id`, and says whether there was anything to
    /// cancel: a run not over, or a result not taken.
    pub fn cancel(&self, id: u64) -> bool {
        let mut state = self.inner.state();
        let child = match state.runs.get_mut(&id) {
            None => return false,
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
        });
        drop(state);
        for (child, reads) in children {
            child.kill();
            reads.abandon();
        }
        let state = self.inner.state();
        drop(
            self.inner
                .finished
                .wait_while(state, |state| state.active > 0)
                .unwrap_or_else(PoisonError::into_inner),
        );
    }

    /// The runs not over, a cancelled one being over once its child is
    /// reaped, and the results not taken.
    pub fn pending(&self) -> usize {
        self.inner.state().runs.len()
    }
}

impl<P: Processes> Inner<P> {
    /// Locks the state. The lock is never held while other code runs, so a
    /// poisoned lock still guards a consistent state.
    fn state(&self) -> MutexGuard<'_, State<P::Child>> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The run `id`'s thread: the module docs' steps.
    fn run(&self, id: u64, command: &Command, limit: u64) {
        let result = match refusal_before_spawn(command) {
            Some(refusal) => RunResult::Refused(refusal),
            None => match self.processes.spawn(command) {
                Err(refusal) => RunResult::Refused(refusal),
                Ok(child) => match self.own(id, child, limit) {
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
    /// cancelled meanwhile, reads its streams, waits for it and says what
    /// the run came to: `None` if it was cancelled before its streams
    /// reached their end.
    fn own(&self, id: u64, mut child: P::Child, limit: u64) -> Option<RunResult> {
        let outputs = [
            child.take_output(Stream::Out),
            child.take_output(Stream::Err),
        ];
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
            // The reader's thread is detached: a run that stops waiting for
            // it leaves it to end when its stream closes.
            let spawned = thread::Builder::new()
                .name("editor-process-read".into())
                .spawn(move || {
                    let mut delivery = Delivery {
                        reads: delivered,
                        slot,
                        read: None,
                    };
                    delivery.read = Some(output.map_or(Read::Whole(Vec::new()), |output| {
                        read(output, limit, &*killed)
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
        let exit = child.wait();
        let streams = reads.wait()?;
        let streams = [Stream::Out, Stream::Err].into_iter().zip(streams);
        let mut whole = [Vec::new(), Vec::new()];
        let mut failed = None;
        for (stream, read) in streams {
            match read {
                Read::TooLarge => return Some(RunResult::OutputTooLarge { stream, limit }),
                Read::Failed(refusal) => {
                    failed.get_or_insert(refusal);
                }
                Read::Whole(bytes) => whole[usize::from(stream == Stream::Err)] = bytes,
            }
        }
        if let Some(refusal) = failed {
            return Some(RunResult::Refused(refusal));
        }
        let [stdout, stderr] = whole;
        Some(RunResult::Ran {
            exit,
            stdout,
            stderr,
        })
    }

    /// Ends the run `id` as `result`: kept and completed, or dropped if it
    /// was cancelled. `None` is a run cancelled before it came to anything.
    fn finish(&self, id: u64, result: Option<RunResult>) {
        let mut state = self.state();
        let cancelled = match state.runs.remove(&id) {
            Some(Run::Starting { cancelled } | Run::Running { cancelled, .. }) => cancelled,
            Some(Run::Kept(_)) | None => true,
        };
        let kept = result.filter(|_| !cancelled);
        let cancelled = kept.is_none();
        if let Some(result) = kept {
            state.runs.insert(id, Run::Kept(result));
        }
        state.active -= 1;
        drop(state);
        self.finished.notify_all();
        if !cancelled {
            (self.complete)(id);
        }
    }
}

/// Reads `output` to its end, keeping up to `limit` bytes. Past the limit,
/// or when a read fails, it kills `child`'s group and stops.
fn read(mut output: impl Output, limit: u64, child: &impl Child) -> Read {
    let mut kept = Vec::new();
    let mut buffer = [0; 8192];
    loop {
        match output.read(&mut buffer) {
            Ok(0) => return Read::Whole(kept),
            Ok(count) => {
                let count = count.min(buffer.len());
                if (kept.len() as u64).saturating_add(count as u64) > limit {
                    child.kill();
                    return Read::TooLarge;
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

    /// Waits for `pending` to come to `count`.
    fn pending_comes_to(service: &Service<FakeProcesses>, count: usize) -> bool {
        let end = std::time::Instant::now() + DEADLINE;
        while std::time::Instant::now() < end {
            if service.pending() == count {
                return true;
            }
            thread::yield_now();
        }
        false
    }

    fn ran(exit: Exit, stdout: &[u8], stderr: &[u8]) -> RunResult {
        RunResult::Ran {
            exit,
            stdout: stdout.to_vec(),
            stderr: stderr.to_vec(),
        }
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
        thread::spawn(move || inner.run(3, &command("x"), ROOMY))
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

        assert!(pending_comes_to(&service, 0));
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

        assert!(pending_comes_to(&service, 0));
        assert!(!fake.alive(child));
        assert!(
            service.start(1, command("held"), ROOMY),
            "the id is free again"
        );
        assert!(service.cancel(1));
        assert!(pending_comes_to(&service, 0));
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
}
