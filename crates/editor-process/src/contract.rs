//! The contract of the process port: the rules every [`Processes`] keeps,
//! and the service's rules that only a real process can show, as a check
//! that runs one.
//!
//! [`check`] runs every property in a directory its caller owns and
//! returns the names of those that fail. Every program it starts is
//! `/bin/sh -c` with a script held here, or another absolute path, and
//! each writes only inside the directory, under a name of its own
//! property's.
//!
//! The port's properties are [`RUN`] to [`AFTER_REAP`]; the service's,
//! [`CANCEL`] to [`TOO_LARGE`], run [`Service`] over the processes the check
//! is given, so a real adapter shows them on real processes. A child that
//! starts a grandchild (`/bin/sleep 600 &`) is how the group's rules are
//! seen: the script writes its own id (`$$`) and the grandchild's (`$!`) to
//! files, and [`Ground::written`] reads them.
//!
//! [`scripts`] is what each of the check's commands does, as the fake's
//! scripts: so the fake runs the same check, and a real adapter's run is
//! what shows those claims true.
//!
//! # The ground
//!
//! The port has no way to make a file, to read a file a child wrote, or to
//! ask whether a process is alive. The check needs each, so its caller
//! supplies them as a [`Ground`]: for the fake, the fake itself
//! ([`FakeProcesses::ground`](crate::fake::FakeProcesses::ground)); for a
//! real adapter, the system, asked directly.
//!
//! A process that has ended and is not reaped, a zombie, is alive to the
//! ground. So "not alive" of a child the check started means ended and
//! reaped. A grandchild is reaped by whatever adopts it (launchd, init, or
//! the container's init), so its end is waited for, up to
//! [`Ground::deadline`]; the check accepts the small risk that its id is
//! given to another process inside that time.
//!
//! # Where an addition goes
//!
//! A new rule is a named `pub const`, an entry of [`PROPERTIES`], a step of
//! [`check`], a script in [`scripts`] for each command it starts, and in
//! `tests/contract.rs` a fake written to break that one rule.

use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::thread;
use std::time::{Duration, Instant};

use crate::fake::{Hold, Script, Writer};
use crate::service::{RunResult, Service};
use crate::{Child, Command, Environment, Exit, Output, Processes, Refusal, RefusalKind, Stream};

/// What [`check`] needs done, or read, that the port has no method for. It
/// is the truth the port's answers are compared with, so it must not be
/// built on the [`Processes`] being checked.
pub trait Ground {
    /// Makes an empty file at `path`, which is in the check's directory.
    fn make_file(&self, path: &Path) -> Result<(), String>;

    /// The process id a child wrote to the file at `path`, as `echo` writes
    /// it, waiting for it up to [`Ground::deadline`]: `None` if it was not
    /// written by then.
    fn written(&self, path: &Path) -> Option<u32>;

    /// Whether a process with the id `id` exists, a zombie counted as
    /// alive.
    fn alive(&self, id: u32) -> bool;

    /// How long the check waits for what should happen at once. Only an
    /// implementation that breaks a rule takes this long.
    fn deadline(&self) -> Duration;
}

/// A run to its end gives the child's exit status and every byte of both
/// streams, a byte that is not UTF-8 among them.
pub const RUN: &str = "a run to its end gives its exit status and both streams, byte for byte";
/// A child ended by a signal says which.
pub const SIGNAL: &str = "a child ended by a signal says which";
/// The child runs in the command's directory.
pub const DIRECTORY: &str = "the child runs in the command's directory";
/// The child's environment is the editor's, emptied first if asked, then
/// with the variables unset removed and those set applied; and a bare
/// program name is looked up on the `PATH` the child is given.
pub const ENVIRONMENT: &str = "the environment is cleared, unset and set in that order, and a bare name is found on the child's PATH";
/// A program that is not there, a directory given as the program, and a
/// directory that is not there are each a refusal, naming the program.
pub const REFUSALS: &str = "a program that cannot be started is a refusal that names it";
/// A kill ends the child and the grandchild it started: the child's wait
/// gives signal 9, the child is reaped by then, and the grandchild ends.
pub const KILL: &str = "a kill ends the child and every process it started";
/// When the child ends by itself, its wait ends what is still in its group,
/// and the streams a grandchild held close.
pub const STRAGGLERS: &str =
    "a child's wait ends what is left of its group, and the streams it held close";
/// A kill after the child has been reaped does nothing, and its wait
/// answers again as it did.
pub const AFTER_REAP: &str = "a kill after the reap does nothing, and a wait answers again";
/// A cancelled run's child and grandchild end, the child is reaped, and the
/// run is never completed.
pub const CANCEL: &str = "a cancelled run's child and grandchild end, and it is never completed";
/// Once shutdown returns, every child the service started has been reaped,
/// and every grandchild ends.
pub const SHUTDOWN: &str = "after shutdown every child is reaped and every grandchild ends";
/// A start after shutdown comes to a refusal as shut down.
pub const AFTER_SHUTDOWN: &str = "a start after shutdown is refused as shut down";
/// A spawn refusal reaches the run's result as a value, with its kind and
/// its detail, and the run is completed once.
pub const SPAWN_REFUSAL: &str = "a spawn refusal is the run's result, completed once";
/// A stream past the run's limit ends the run as too large, and kills the
/// group.
pub const TOO_LARGE: &str = "output past the limit is too large, and kills the group";

/// Every property, by name, in the order [`check`] runs them.
pub const PROPERTIES: [&str; 13] = [
    RUN,
    SIGNAL,
    DIRECTORY,
    ENVIRONMENT,
    REFUSALS,
    KILL,
    STRAGGLERS,
    AFTER_REAP,
    CANCEL,
    SHUTDOWN,
    AFTER_SHUTDOWN,
    SPAWN_REFUSAL,
    TOO_LARGE,
];

/// The script of [`RUN`]: `out` and a line feed on standard output, `err`
/// and the byte `FF` on standard error, and the status 3.
const RUN_SCRIPT: &str = r"printf 'out\n'; printf 'err\377' >&2; exit 3";
/// The script of [`SIGNAL`].
const SIGNAL_SCRIPT: &str = "kill -9 $$";
/// The file [`DIRECTORY`]'s ground makes.
const MADE: &str = "made";
/// A variable [`ENVIRONMENT`] sets.
const SET: &str = "EDITOR_PROCESS_SET";
/// A program that is not there.
const MISSING_PROGRAM: &str = "/nonexistent/editor-process-contract";
/// The `PATH` that holds `sh`.
const SH_PATH: &str = "/bin:/usr/bin";
/// A limit no output of the service's properties is over, but
/// [`TOO_LARGE`]'s.
const ROOMY: u64 = 1 << 20;

/// The script of a child that writes its id to `child`, starts a
/// grandchild in its group that writes its id to `grandchild` and holds
/// both streams, does `then`, and then waits for the grandchild, which
/// sleeps for ten minutes.
fn family(child: &str, grandchild: &str, then: &str) -> String {
    format!("echo $$ > {child}; /bin/sleep 600 & echo $! > {grandchild}; {then}")
}

/// `/bin/sh -c script` in `dir`.
fn sh(dir: &Path, script: &str) -> Command {
    Command::new("/bin/sh", ["-c", script], dir)
}

/// The commands of [`ENVIRONMENT`], each with what it writes to standard
/// output or how it is refused.
fn environment_commands(dir: &Path) -> Vec<(Command, Result<Script, Refusal>)> {
    let ends = |stdout: &str| Ok(Script::ends(Exit::Code(0)).stdout(stdout));
    let env = |environment: Environment| {
        Command::new("/usr/bin/env", [""; 0], dir).with_environment(environment)
    };
    vec![
        (
            sh(dir, &format!("printf %s \"${SET}\"")).with_environment(Environment {
                set: vec![(SET.into(), "given".into())],
                ..Environment::default()
            }),
            ends("given"),
        ),
        (
            env(Environment {
                clear: true,
                set: vec![("ONLY".into(), "x".into())],
                unset: Vec::new(),
            }),
            ends("ONLY=x\n"),
        ),
        (
            env(Environment {
                unset: vec!["PATH".into()],
                ..Environment::default()
            }),
            ends("EDITOR_PROCESS_FAKE=1\n"),
        ),
        (
            env(Environment {
                clear: true,
                set: vec![("A".into(), "1".into())],
                unset: vec!["A".into()],
            }),
            ends("A=1\n"),
        ),
        (
            Command::new("sh", ["-c", "printf found"], dir).with_environment(Environment {
                set: vec![("PATH".into(), SH_PATH.into())],
                ..Environment::default()
            }),
            ends("found"),
        ),
        (
            Command::new("sh", ["-c", "printf found"], dir).with_environment(Environment {
                set: vec![("PATH".into(), "/nonexistent".into())],
                ..Environment::default()
            }),
            Err(Refusal::new(
                RefusalKind::NotFound,
                "cannot start `sh`: not on the PATH /nonexistent",
            )),
        ),
    ]
}

/// The script of a family whose grandchild is still running when it is
/// killed.
fn held_family() -> Script {
    Script::ends(Exit::Code(0))
        .hold(Hold::UntilKilled)
        .members(1)
}

/// What each command [`check`] starts in `dir` does, as the fake's scripts.
/// A command left out, the program that is not there, is not found.
pub fn scripts(dir: &Path) -> Vec<(Command, Result<Script, Refusal>)> {
    let at = |name: &str| dir.join(name);
    let mut scripts = vec![
        (
            sh(dir, RUN_SCRIPT),
            Ok(Script::ends(Exit::Code(3))
                .stdout("out\n")
                .stderr(b"err\xff".to_vec())),
        ),
        (sh(dir, SIGNAL_SCRIPT), Ok(Script::ends(Exit::Signal(9)))),
        (
            Command::new("/bin/ls", [MADE], dir),
            Ok(Script::ends(Exit::Code(0)).stdout(format!("{MADE}\n"))),
        ),
        (
            Command::new(dir.display().to_string(), [""; 0], dir),
            Err(Refusal::new(
                RefusalKind::Denied,
                format!("cannot start `{}`: it is a directory", dir.display()),
            )),
        ),
        (
            sh(&dir.join("missing"), "true"),
            Err(Refusal::new(
                RefusalKind::NotFound,
                "cannot start `/bin/sh`: no such directory",
            )),
        ),
        (sh(dir, "exit 0"), Ok(Script::ends(Exit::Code(0)))),
    ];
    scripts.extend(environment_commands(dir));
    for name in ["f", "s1", "s2a", "s2b"] {
        let (child, grandchild) = (format!("{name}-child"), format!("{name}-grandchild"));
        scripts.push((
            sh(dir, &family(&child, &grandchild, "wait")),
            Ok(held_family()
                .writes(at(&child), Writer::Child)
                .writes(at(&grandchild), Writer::Member(0))),
        ));
    }
    scripts.push((
        sh(dir, &family("g-child", "g-grandchild", "exit 0")),
        Ok(Script::ends(Exit::Code(0))
            .members(1)
            .writes(at("g-child"), Writer::Child)
            .writes(at("g-grandchild"), Writer::Member(0))),
    ));
    scripts.push((
        sh(
            dir,
            &family("s5-child", "s5-grandchild", "printf 0123456789; wait"),
        ),
        Ok(held_family()
            .stdout("0123456789")
            .writes(at("s5-child"), Writer::Child)
            .writes(at("s5-grandchild"), Writer::Member(0))),
    ));
    scripts
}

/// Holds `processes` to the contract in `dir`, a directory that exists, is
/// empty and is the caller's, written with every link in its path
/// followed, and returns the names of the properties that fail: none when
/// it keeps them all.
pub fn check<P: Processes + Clone + 'static>(
    processes: &P,
    ground: &impl Ground,
    dir: &Path,
) -> Vec<&'static str> {
    let check = Check { ground, dir };
    let results = [
        (RUN, check.run(processes)),
        (SIGNAL, check.signal(processes)),
        (DIRECTORY, check.directory(processes)),
        (ENVIRONMENT, check.environment(processes)),
        (REFUSALS, check.refusals(processes)),
        (KILL, check.kill(processes)),
        (STRAGGLERS, check.stragglers(processes)),
        (AFTER_REAP, check.after_reap(processes)),
        (CANCEL, check.cancel(processes)),
        (SHUTDOWN, check.shutdown(processes)),
        (AFTER_SHUTDOWN, check.after_shutdown(processes)),
        (SPAWN_REFUSAL, check.spawn_refusal(processes)),
        (TOO_LARGE, check.too_large(processes)),
    ];
    results
        .into_iter()
        .filter_map(|(name, holds)| (!holds).then_some(name))
        .collect()
}

/// A child of the check's, shared with the threads that wait for it.
struct Started<C: Child> {
    /// The child.
    child: Arc<C>,
    /// Its streams, out then err, each read to its end on a thread of its
    /// own: what it read arrives on the channel.
    streams: [mpsc::Receiver<Vec<u8>>; 2],
}

/// The ids a service completed, as the check reads them.
#[derive(Default)]
struct Completions {
    /// The ids, oldest first.
    ids: Mutex<Vec<u64>>,
    /// Told whenever an id arrives.
    arrived: Condvar,
}

impl Completions {
    /// The ids so far.
    fn ids(&self) -> Vec<u64> {
        self.ids
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// Whether `id` arrives within `deadline`.
    fn arrives(&self, id: u64, deadline: Duration) -> bool {
        let ids = self.ids.lock().unwrap_or_else(PoisonError::into_inner);
        let (ids, _) = self
            .arrived
            .wait_timeout_while(ids, deadline, |ids| !ids.contains(&id))
            .unwrap_or_else(PoisonError::into_inner);
        ids.contains(&id)
    }
}

/// A check in progress: its ground and its directory.
struct Check<'a, G> {
    /// The ground.
    ground: &'a G,
    /// The directory.
    dir: &'a Path,
}

impl<G: Ground> Check<'_, G> {
    /// The file `name` in the directory.
    fn at(&self, name: &str) -> PathBuf {
        self.dir.join(name)
    }

    /// Whether `ready` holds within the deadline, asked again until it
    /// does.
    fn soon(&self, ready: impl Fn() -> bool) -> bool {
        let end = Instant::now() + self.ground.deadline();
        loop {
            if ready() {
                return true;
            }
            if Instant::now() >= end {
                return false;
            }
            thread::sleep(Duration::from_millis(2));
        }
    }

    /// Starts `command` and a reader for each of its streams.
    fn start<P: Processes>(processes: &P, command: &Command) -> Result<Started<P::Child>, Refusal> {
        let mut child = processes.spawn(command)?;
        let streams = [Stream::Out, Stream::Err].map(|stream| {
            let (sender, received) = mpsc::channel();
            if let Some(mut output) = child.take_output(stream) {
                thread::spawn(move || {
                    let mut all = Vec::new();
                    let mut buffer = [0; 4096];
                    while let Ok(count) = output.read(&mut buffer) {
                        if count == 0 {
                            sender.send(all).ok();
                            return;
                        }
                        all.extend_from_slice(&buffer[..count.min(buffer.len())]);
                    }
                });
            }
            received
        });
        Ok(Started {
            child: Arc::new(child),
            streams,
        })
    }

    /// How `child` ended, if its wait returns within the deadline.
    fn wait<C: Child>(&self, child: &Arc<C>) -> Option<Exit> {
        let (sender, exit) = mpsc::channel();
        let child = Arc::clone(child);
        thread::spawn(move || {
            sender.send(child.wait()).ok();
        });
        exit.recv_timeout(self.ground.deadline()).ok()
    }

    /// Both streams of `started`, if each reaches its end within the
    /// deadline.
    fn streams<C: Child>(&self, started: &Started<C>) -> Option<(Vec<u8>, Vec<u8>)> {
        let deadline = self.ground.deadline();
        let [out, err] = &started.streams;
        Some((
            out.recv_timeout(deadline).ok()?,
            err.recv_timeout(deadline).ok()?,
        ))
    }

    /// How `command` ended and both its streams, if it ran to its end
    /// within the deadline.
    fn ran<P: Processes>(
        &self,
        processes: &P,
        command: &Command,
    ) -> Option<(Exit, Vec<u8>, Vec<u8>)> {
        let started = Self::start(processes, command).ok()?;
        let exit = self.wait(&started.child)?;
        let (stdout, stderr) = self.streams(&started)?;
        Some((exit, stdout, stderr))
    }

    /// Whether the spawn of `command` is refused as `kind`, naming its
    /// program.
    fn refused_as<P: Processes>(
        processes: &P,
        command: &Command,
        kind: Option<RefusalKind>,
    ) -> bool {
        match processes.spawn(command) {
            Ok(child) => {
                child.kill();
                child.wait();
                false
            }
            Err(refusal) => {
                kind.is_none_or(|kind| refusal.kind == kind)
                    && refusal.detail.contains(&command.program)
            }
        }
    }

    /// [`RUN`].
    fn run<P: Processes>(&self, processes: &P) -> bool {
        self.ran(processes, &sh(self.dir, RUN_SCRIPT))
            == Some((Exit::Code(3), b"out\n".to_vec(), b"err\xff".to_vec()))
    }

    /// [`SIGNAL`].
    fn signal<P: Processes>(&self, processes: &P) -> bool {
        self.ran(processes, &sh(self.dir, SIGNAL_SCRIPT))
            .is_some_and(|(exit, ..)| exit == Exit::Signal(9))
    }

    /// [`DIRECTORY`].
    fn directory<P: Processes>(&self, processes: &P) -> bool {
        self.ground.make_file(&self.at(MADE)).is_ok()
            && self.ran(processes, &Command::new("/bin/ls", [MADE], self.dir))
                == Some((Exit::Code(0), format!("{MADE}\n").into_bytes(), Vec::new()))
    }

    /// [`ENVIRONMENT`].
    fn environment<P: Processes>(&self, processes: &P) -> bool {
        let commands = environment_commands(self.dir);
        let stdout = |index: usize| {
            let (command, _) = &commands[index];
            self.ran(processes, command)
                .filter(|(exit, ..)| *exit == Exit::Code(0))
                .map(|(_, stdout, _)| stdout)
        };
        let set = stdout(0).as_deref() == Some(&b"given"[..]);
        let cleared = stdout(1).as_deref() == Some(&b"ONLY=x\n"[..]);
        let unset = stdout(2).is_some_and(|stdout| {
            !String::from_utf8_lossy(&stdout)
                .lines()
                .any(|line| line.starts_with("PATH="))
        });
        let in_order = stdout(3).as_deref() == Some(&b"A=1\n"[..]);
        let found = stdout(4).as_deref() == Some(&b"found"[..]);
        let not_found = Self::refused_as(processes, &commands[5].0, Some(RefusalKind::NotFound));
        set && cleared && unset && in_order && found && not_found
    }

    /// [`REFUSALS`].
    fn refusals<P: Processes>(&self, processes: &P) -> bool {
        let missing = Self::refused_as(
            processes,
            &Command::new(MISSING_PROGRAM, [""; 0], self.dir),
            Some(RefusalKind::NotFound),
        );
        let directory = Self::refused_as(
            processes,
            &Command::new(self.dir.display().to_string(), [""; 0], self.dir),
            Some(RefusalKind::Denied),
        );
        let no_directory =
            Self::refused_as(processes, &sh(&self.dir.join("missing"), "true"), None);
        missing && directory && no_directory
    }

    /// The ids a family whose files are named after `name` wrote: the
    /// child's and the grandchild's.
    fn family_ids(&self, name: &str) -> Option<(u32, u32)> {
        Some((
            self.ground.written(&self.at(&format!("{name}-child")))?,
            self.ground
                .written(&self.at(&format!("{name}-grandchild")))?,
        ))
    }

    /// [`KILL`].
    fn kill<P: Processes>(&self, processes: &P) -> bool {
        let Ok(started) = Self::start(
            processes,
            &sh(self.dir, &family("f-child", "f-grandchild", "wait")),
        ) else {
            return false;
        };
        let child = &started.child;
        let Some((written, grandchild)) = self.family_ids("f") else {
            child.kill();
            return false;
        };
        let before =
            written == child.id() && self.ground.alive(child.id()) && self.ground.alive(grandchild);
        child.kill();
        let exit = self.wait(child);
        before
            && exit == Some(Exit::Signal(9))
            && !self.ground.alive(child.id())
            && self.soon(|| !self.ground.alive(grandchild))
    }

    /// [`STRAGGLERS`].
    fn stragglers<P: Processes>(&self, processes: &P) -> bool {
        let Ok(started) = Self::start(
            processes,
            &sh(self.dir, &family("g-child", "g-grandchild", "exit 0")),
        ) else {
            return false;
        };
        let child = &started.child;
        let Some((_, grandchild)) = self.family_ids("g") else {
            child.kill();
            return false;
        };
        let exit = self.wait(child);
        let streams = self.streams(&started);
        exit == Some(Exit::Code(0))
            && !self.ground.alive(child.id())
            && self.soon(|| !self.ground.alive(grandchild))
            && streams == Some((Vec::new(), Vec::new()))
    }

    /// [`AFTER_REAP`].
    fn after_reap<P: Processes>(&self, processes: &P) -> bool {
        let Ok(started) = Self::start(processes, &sh(self.dir, "exit 0")) else {
            return false;
        };
        let first = self.wait(&started.child);
        started.child.kill();
        first == Some(Exit::Code(0)) && self.wait(&started.child) == first
    }

    /// A service over `processes` that records what it completes.
    fn service<P: Processes + Clone + 'static>(processes: &P) -> (Service<P>, Arc<Completions>) {
        let completions = Arc::new(Completions::default());
        let recorded = Arc::clone(&completions);
        let service = Service::new(processes.clone(), move |id| {
            recorded
                .ids
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(id);
            recorded.arrived.notify_all();
        });
        (service, completions)
    }

    /// Shuts `service` down, and says whether that returned within the
    /// deadline: a service whose children are not all reaped would hold the
    /// check for ever.
    fn shut<P: Processes + 'static>(&self, service: &Service<P>) -> bool {
        let (sender, returned) = mpsc::channel();
        let service = service.clone();
        thread::spawn(move || {
            service.shutdown();
            sender.send(()).ok();
        });
        returned.recv_timeout(self.ground.deadline()).is_ok()
    }

    /// Whether the family whose files are named after `name` both started:
    /// its ids, if they are written and alive.
    fn family_alive(&self, name: &str) -> Option<(u32, u32)> {
        self.family_ids(name).filter(|&(child, grandchild)| {
            self.ground.alive(child) && self.ground.alive(grandchild)
        })
    }

    /// [`CANCEL`].
    fn cancel<P: Processes + Clone + 'static>(&self, processes: &P) -> bool {
        let (service, completions) = Self::service(processes);
        if !service.start(
            1,
            sh(self.dir, &family("s1-child", "s1-grandchild", "wait")),
            ROOMY,
        ) {
            return false;
        }
        let Some((child, grandchild)) = self.family_alive("s1") else {
            self.shut(&service);
            return false;
        };
        let cancelled = service.cancel(1);
        let reaped = self.soon(|| service.pending() == 0);
        cancelled
            && reaped
            && !self.ground.alive(child)
            && self.soon(|| !self.ground.alive(grandchild))
            && completions.ids().is_empty()
    }

    /// [`SHUTDOWN`].
    fn shutdown<P: Processes + Clone + 'static>(&self, processes: &P) -> bool {
        let (service, completions) = Self::service(processes);
        let started = ["s2a", "s2b"].into_iter().zip(1..).all(|(name, id)| {
            let script = family(
                &format!("{name}-child"),
                &format!("{name}-grandchild"),
                "wait",
            );
            service.start(id, sh(self.dir, &script), ROOMY)
        });
        let families: Option<Vec<(u32, u32)>> = ["s2a", "s2b"]
            .into_iter()
            .map(|name| self.family_alive(name))
            .collect();
        let shut = self.shut(&service);
        let Some(families) = families else {
            return false;
        };
        started
            && shut
            && families.iter().all(|&(child, _)| !self.ground.alive(child))
            && families
                .iter()
                .all(|&(_, grandchild)| self.soon(|| !self.ground.alive(grandchild)))
            && service.pending() == 0
            && completions.ids().is_empty()
    }

    /// [`AFTER_SHUTDOWN`].
    fn after_shutdown<P: Processes + Clone + 'static>(&self, processes: &P) -> bool {
        let (service, completions) = Self::service(processes);
        let shut = self.shut(&service);
        let started = service.start(1, sh(self.dir, "exit 0"), ROOMY);
        shut && started
            && completions.arrives(1, self.ground.deadline())
            && matches!(
                service.take(1),
                Some(RunResult::Refused(Refusal {
                    kind: RefusalKind::ShutDown,
                    ..
                }))
            )
    }

    /// [`SPAWN_REFUSAL`].
    fn spawn_refusal<P: Processes + Clone + 'static>(&self, processes: &P) -> bool {
        let (service, completions) = Self::service(processes);
        let command = Command::new(MISSING_PROGRAM, [""; 0], self.dir);
        if !service.start(1, command, ROOMY) || !completions.arrives(1, self.ground.deadline()) {
            return false;
        }
        let refused = match service.take(1) {
            Some(RunResult::Refused(refusal)) => {
                refusal.kind == RefusalKind::NotFound
                    && refusal.detail.contains(MISSING_PROGRAM)
                    && refusal.detail.contains(&self.dir.display().to_string())
            }
            _ => false,
        };
        refused && completions.ids() == [1] && service.pending() == 0
    }

    /// [`TOO_LARGE`].
    fn too_large<P: Processes + Clone + 'static>(&self, processes: &P) -> bool {
        let (service, completions) = Self::service(processes);
        let script = family("s5-child", "s5-grandchild", "printf 0123456789; wait");
        if !service.start(1, sh(self.dir, &script), 4) {
            return false;
        }
        let Some((child, grandchild)) = self.family_ids("s5") else {
            self.shut(&service);
            return false;
        };
        let arrived = completions.arrives(1, self.ground.deadline());
        if !arrived {
            self.shut(&service);
        }
        arrived
            && service.take(1)
                == Some(RunResult::OutputTooLarge {
                    stream: Stream::Out,
                    limit: 4,
                })
            && !self.ground.alive(child)
            && self.soon(|| !self.ground.alive(grandchild))
    }
}

#[cfg(test)]
mod tests {
    use super::PROPERTIES;

    #[test]
    fn the_properties_are_thirteen_and_each_is_named_once() {
        let mut names = PROPERTIES.to_vec();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), 13);
    }
}
