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
//! The port's properties are [`RUN`] to [`AFTER_REAP`], and [`INPUT`] to
//! [`NO_INPUT`] for a child's standard input; the service's, [`CANCEL`] to
//! [`RUN_INPUT_IGNORED`] for runs and [`STREAM_LINES`] to
//! [`STREAM_SHUTDOWN`] for streaming children, and [`FLUSH`] and
//! [`FLUSH_LIVE_STREAM`] for the flush, run [`Service`] over the processes the check is
//! given, so a real adapter shows them on real processes. A child that
//! starts a grandchild (`/bin/sleep 600 &`) is how the group's rules are
//! seen: the script writes its own id (`$$`) and the grandchild's (`$!`) to
//! files, and [`Ground::written`] reads them.
//!
//! [`ESCAPED`] starts, with [`ESCAPE`], a process that leaves the child's
//! group and holds both streams, which no kill of the port's ends. The
//! check ends it itself, through [`Ground::end`], so it leaves nothing
//! running. Seen to bite once by hand, on 2026-11-15: over the service as
//! it was before it stopped waiting for a cancelled run's readers, the
//! property fails on the fake (`tests/contract.rs`) and on real processes
//! (`editor-process-std`'s `tests/contract.rs`), the cancelled run never
//! leaving `pending` and shutdown not returning within the deadline.
//!
//! A property that needs the service to have finished what it was handed,
//! a cancelled run reaped among it, waits on a flush ([`Service::flush`]),
//! never on the pending count.
//!
//! Every wait of the check returns on its event, a completion, a child's
//! wait, a stream's end, a reader's park ([`Service::wait_held`]) or a
//! process's end ([`Ground::ends`]), and is bounded only by
//! [`Ground::deadline`], a hang guard: no property is decided by a time
//! running out, and none asks again until a time is up. A marker file a
//! child makes (`: > finished`) is read once with [`Ground::exists`], where
//! what it shows is already settled. [`STREAM_COALESCED`]'s bound is
//! exactly what its child writes, so its readers are held once every
//! chunk has been read while its one read was pending. Seen to bite once
//! by hand, on 2026-11-15, on the fake: with the reader's room check taken
//! out, [`STREAM_HELD`] fails (and [`STREAM_ORDER`], [`STREAM_COALESCED`],
//! [`STREAM_CANCEL`] and [`STREAM_SHUTDOWN`] with it, none of which is
//! then held); with a completion queued for each chunk, [`STREAM_COALESCED`]
//! alone fails.
//!
//! [`scripts`] is what each of the check's commands does, as the fake's
//! scripts: so the fake runs the same check, and a real adapter's run is
//! what shows those claims true.
//!
//! # The ground
//!
//! The port has no way to make a file, to read a file a child wrote, to
//! ask whether a marker file is there, to ask whether a process is alive,
//! or to end a process outside a child's group. The check needs each, so its caller
//! supplies them as a [`Ground`]: for the fake, the fake itself
//! ([`FakeProcesses::ground`](crate::fake::FakeProcesses::ground)); for a
//! real adapter, the system, asked directly.
//!
//! A process that has ended and is not reaped, a zombie, is alive to the
//! ground. So "not alive" of a child the check started means ended and
//! reaped. A grandchild is reaped by whatever adopts it (launchd, init, or
//! the container's init), so its end, its exit, is waited for with
//! [`Ground::ends`], up to [`Ground::deadline`]; the check accepts the
//! small risk that its id is given to another process inside that time.
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

use editor_wait::{self as wait, HangGuard};

use crate::fake::{Hold, Script, Step, Writer};
use crate::frame::{Frames, Framing};
use crate::service::{Delivery, End, RunResult, Service, StreamReply, Streaming};
use crate::{
    Child, ChildInput, Command, Environment, Exit, Input, Output, Processes, Refusal, RefusalKind,
    Stream,
};

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

    /// Whether a file is at `path` now, empty or not: a marker a child
    /// made (`: > name`). It does not wait, and the check reads it only
    /// where what it shows is already settled.
    fn exists(&self, path: &Path) -> bool;

    /// Whether a process with the id `id` exists, a zombie counted as
    /// alive.
    fn alive(&self, id: u32) -> bool;

    /// Waits until the process `id` has ended, up to [`Ground::deadline`];
    /// true if it did. It returns on the end itself, an event of the
    /// system's (or of the fake's state), never by asking again: its end
    /// is its exit, so a zombie has ended though [`Ground::alive`] still
    /// counts it, and an id no process has has ended. Its twin is
    /// `editor-launch-std`'s `StdPids::wait_exit`, the launcher's real
    /// exit wait, over the same system calls; a fix to one is looked for
    /// in the other.
    fn ends(&self, id: u32) -> bool;

    /// Ends the process with the id `id`, which a child of the check's
    /// started outside its group: nothing the port does ends it, and the
    /// check leaves nothing running.
    fn end(&self, id: u32);

    /// Whether the machine has [`ESCAPE`]'s program, with which a child of
    /// the check's starts a process outside its group. Without it,
    /// [`ESCAPED`] is not checked, and the ground says so where it answers.
    fn escapes(&self) -> bool;

    /// hang guard: each event the check waits for with it, a completion, a
    /// child's wait, a stream's end, a reader's park or a process's end,
    /// which must come; only a hang reaches the bound, and the property
    /// then fails as a hang. Only an implementation that breaks a rule
    /// takes this long.
    fn deadline(&self) -> HangGuard;
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
/// A run whose child started a process outside its group, which holds both
/// streams open after the child has ended, still ends at a cancel and at
/// shutdown: once its child is reaped, the service stops waiting for its
/// streams. The escaped process is not ended by the service. Checked only
/// when the ground has [`ESCAPE`]'s program ([`Ground::escapes`]).
pub const ESCAPED: &str =
    "a run whose descendant left its group holding its streams ends at a cancel and at shutdown";
/// What a run is fed reaches its child whole, then end of file: `/bin/cat`
/// fed more than a pipe holds, a NUL and a byte that is not UTF-8 among
/// it, answers exactly those bytes on its standard output, and exits 0.
pub const RUN_INPUT: &str = "what a run is fed reaches its child whole, then end of file";
/// A run whose child ends without reading what it is fed still comes to
/// what the child did: `/usr/bin/true` fed a mebibyte exits 0, and the
/// broken pipe is no refusal.
pub const RUN_INPUT_IGNORED: &str =
    "a run whose child does not read what it is fed comes to what the child did";
/// A run that keeps its head ([`Service::start_head`]), fed a few bytes,
/// of a child that never stops writing to its standard output, answers
/// exactly the first `limit` bytes of it as [`RunResult::Cut`], and its
/// child and grandchild end.
pub const RUN_HEAD: &str =
    "a run that keeps its head answers the first limit bytes of its output and ends its group";

/// A child's standard input reaches it: `/bin/cat` given a line, a byte
/// that is not UTF-8 and bytes with no line feed gives them back, and ends
/// when its input is closed.
pub const INPUT: &str = "what is written to a child's standard input reaches it, byte for byte";
/// A write to an input the child has closed is a refusal as input closed,
/// not a signal.
pub const INPUT_CLOSED: &str = "a write to an input the child closed is refused as input closed";
/// A child spawned with its input closed has no input to take.
pub const NO_INPUT: &str = "a child spawned with its input closed has none to take";
/// A job that asked for lines receives each line as the child writes it,
/// a line written to the child's input reaches it, and the last delivery
/// says how the child exited.
pub const STREAM_LINES: &str =
    "a streaming child's lines arrive as it writes them, and a line written reaches its input";
/// Bytes framing delivers every byte, and lines framing gives the
/// unterminated last line.
pub const STREAM_BYTES: &str =
    "bytes are delivered byte for byte, and a last line needs no line feed";
/// Output faster than its job drains it arrives complete and in order, no
/// delivery over the bound.
pub const STREAM_ORDER: &str =
    "output faster than its job drains it arrives complete and in order, a bound at a time";
/// However fast the child writes, a pending read is completed once.
pub const STREAM_COALESCED: &str = "a pending read is completed once however fast its child writes";
/// A child at the bound is held, and goes on once its job reads, with
/// nothing lost.
pub const STREAM_HELD: &str = "a child at the bound is held until its job reads, and loses nothing";
/// A line longer than the bound ends the child as line too long, and kills
/// its group.
pub const STREAM_LINE_TOO_LONG: &str =
    "a line longer than the bound ends the child, and kills its group";
/// An unterminated last line exactly the bound long is delivered whole,
/// and the child exits as it does; one byte more ends it as line too long,
/// and so does the line's own line feed, which counts against the bound.
/// Seen to bite once by hand, on 2026-11-15: over the service as it was
/// before its reader looked one byte past a partial line that fills the
/// bound, it fails on the fake and on real processes, the line at the
/// bound ending its child as line too long.
pub const STREAM_LINE_AT_BOUND: &str =
    "a last line exactly the bound long is delivered whole, and one a byte longer is too long";
/// A cancelled streaming child, held at the bound, ends with the process it
/// started, and nothing is left pending.
pub const STREAM_CANCEL: &str =
    "a cancelled streaming child ends with its group, and nothing is pending";
/// Shutdown ends a streaming child held at the bound and one waiting for
/// input.
pub const STREAM_SHUTDOWN: &str =
    "after shutdown a held streaming child and one waiting for input are reaped";
/// A flush asked while a run's child is held until it is cancelled is not
/// completed; once the run is cancelled, the flush's is the next
/// completion, and by then the child has been reaped and nothing is
/// pending. The held child forces the order: a flush completed at its call
/// is seen every time.
pub const FLUSH: &str =
    "a flush is completed once the run before it has ended and its child is reaped";
/// A flush does not wait for a live streaming child or its pending read,
/// which wait on the child and not on the service: it is completed with
/// the child still alive.
pub const FLUSH_LIVE_STREAM: &str =
    "a flush is completed with a streaming child alive and its read pending";

/// The program with which a child of the check's starts a process outside
/// its group: Perl's `setpgrp`, which puts it in a group of its own, then
/// `exec`s the rest of its arguments. macOS has no `setsid` command; both
/// macOS and Debian ship this Perl (on Debian in `perl-base`, which every
/// system has).
pub const ESCAPE: &str = "/usr/bin/perl";

/// Every property, by name, in the order [`check`] runs them.
pub const PROPERTIES: [&str; 31] = [
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
    ESCAPED,
    RUN_INPUT,
    RUN_INPUT_IGNORED,
    RUN_HEAD,
    INPUT,
    INPUT_CLOSED,
    NO_INPUT,
    STREAM_LINES,
    STREAM_BYTES,
    STREAM_ORDER,
    STREAM_COALESCED,
    STREAM_HELD,
    STREAM_LINE_TOO_LONG,
    STREAM_LINE_AT_BOUND,
    STREAM_CANCEL,
    STREAM_SHUTDOWN,
    FLUSH,
    FLUSH_LIVE_STREAM,
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

/// The script of a child that writes its id to `{name}-child`, starts a
/// process that leaves its group, holding both streams, and waits for it.
/// That process writes its own id to `{name}-escaped` only once it has left
/// the group, so the check never acts on one still in it, and then sleeps
/// for ten minutes.
fn escaping(name: &str) -> String {
    format!(
        r#"echo $$ > {name}-child; {ESCAPE} -e 'setpgrp(0, 0) or die; open(F, ">", shift) or die; print F $$, qq(\n); close(F); exec @ARGV' {name}-escaped /bin/sleep 600 & wait"#
    )
}

/// The script of [`INPUT_CLOSED`]: a child that closes its input, says so,
/// and sleeps.
const INPUT_CLOSED_SCRIPT: &str = "exec 0<&-; echo closed; exec /bin/sleep 600";
/// The script of [`STREAM_LINES`].
const LINES_SCRIPT: &str = r#"echo one; read x; echo "$x"; echo err >&2; read y; exit 4"#;
/// The scripts of [`STREAM_LINE_AT_BOUND`]: a last line of exactly
/// [`AT_BOUND`] bytes, one a byte longer, and one of exactly [`AT_BOUND`]
/// bytes and its line feed.
const AT_BOUND_SCRIPTS: [&str; 3] = ["printf abcd", "printf abcde", r"printf 'abcd\n'"];
/// [`STREAM_LINE_AT_BOUND`]'s bound.
const AT_BOUND: u64 = 4;
/// How many lines [`STREAM_ORDER`]'s child writes, and its bound.
const ORDER: (usize, u64) = (20_000, 256);
/// How many lines [`STREAM_COALESCED`]'s child writes.
const COALESCED: usize = 10_000;
/// How many lines [`STREAM_HELD`]'s child writes, and its bound.
const HELD: (usize, u64) = (100_000, 4096);
/// The capacity of a pipe, as the fake's scripts give it: 64 KiB, Linux's
/// and the most macOS grows one to.
const PIPE: usize = 1 << 16;
/// A script that never stops writing `y` lines.
const YES: &str = "while :; do echo y; done";
/// How many bytes [`RUN_INPUT`] feeds its child: four times a pipe.
const FED: usize = 4 * PIPE;
/// The script of [`RUN_HEAD`]'s family: a child that never stops writing
/// `0123456789` to its standard output.
fn head_family() -> String {
    family(
        "s-head-child",
        "s-head-grandchild",
        "while :; do printf 0123456789; done",
    )
}
/// How many bytes [`RUN_INPUT_IGNORED`] feeds its child: a mebibyte.
const FED_IGNORED: usize = 1 << 20;
/// The program [`RUN_INPUT_IGNORED`] runs, which reads nothing.
const TRUE: &str = "/usr/bin/true";

/// What [`RUN_INPUT`] feeds its child: [`FED`] bytes, a NUL and the byte
/// `FF`, which is not UTF-8, among them.
fn fed() -> Vec<u8> {
    let mut bytes: Vec<u8> = (0..FED).map(|at| b"fed\n"[at % 4]).collect();
    bytes[1] = 0;
    bytes[FED / 2] = 0xff;
    bytes
}

/// The script that writes the numbers from 0 below `count`, a line each,
/// then does `then`.
fn counting(count: usize, then: &str) -> String {
    format!("i=0; while [ $i -lt {count} ]; do echo $i; i=$((i+1)); done; {then}")
}

/// What [`counting`] writes.
fn counted(count: usize) -> Vec<u8> {
    (0..count)
        .flat_map(|n| format!("{n}\n").into_bytes())
        .collect()
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
    scripts.push((
        sh(dir, &head_family()),
        Ok(held_family()
            .stdout("0123456789")
            .writes(at("s-head-child"), Writer::Child)
            .writes(at("s-head-grandchild"), Writer::Member(0))),
    ));
    for name in ["e1", "e2"] {
        scripts.push((
            sh(dir, &escaping(name)),
            Ok(Script::ends(Exit::Code(0))
                .hold(Hold::UntilKilled)
                .escaped(1)
                .writes(at(&format!("{name}-child")), Writer::Child)
                .writes(at(&format!("{name}-escaped")), Writer::Escaped(0))),
        ));
    }
    scripts.extend(stream_scripts(dir));
    scripts
}

/// The scripts of the input's and the streaming child's properties.
fn stream_scripts(dir: &Path) -> Vec<(Command, Result<Script, Refusal>)> {
    let at = |name: &str| dir.join(name);
    vec![
        (
            Command::new("/bin/cat", [""; 0], dir),
            Ok(Script::ends(Exit::Code(0)).step(Step::EchoUntilClosed(Stream::Out))),
        ),
        (
            Command::new(TRUE, [""; 0], dir),
            Ok(Script::ends(Exit::Code(0))),
        ),
        (
            sh(dir, INPUT_CLOSED_SCRIPT),
            Ok(Script::ends(Exit::Code(0)).hold(Hold::UntilKilled).steps([
                Step::CloseInput,
                Step::Write(Stream::Out, b"closed\n".to_vec()),
            ])),
        ),
        (
            sh(dir, LINES_SCRIPT),
            Ok(Script::ends(Exit::Code(4)).steps([
                Step::Write(Stream::Out, b"one\n".to_vec()),
                Step::EchoLine(Stream::Out),
                Step::Write(Stream::Err, b"err\n".to_vec()),
                Step::AwaitInputClosed,
            ])),
        ),
        (
            sh(dir, r"printf 'a\377b'"),
            Ok(Script::ends(Exit::Code(0)).stdout(b"a\xffb".to_vec())),
        ),
        (
            sh(dir, r"printf 'x\ny'"),
            Ok(Script::ends(Exit::Code(0)).stdout("x\ny")),
        ),
        (
            sh(dir, AT_BOUND_SCRIPTS[0]),
            Ok(Script::ends(Exit::Code(0)).stdout("abcd")),
        ),
        (
            sh(dir, AT_BOUND_SCRIPTS[1]),
            Ok(Script::ends(Exit::Code(0)).stdout("abcde")),
        ),
        (
            sh(dir, AT_BOUND_SCRIPTS[2]),
            Ok(Script::ends(Exit::Code(0)).stdout("abcd\n")),
        ),
        (
            sh(dir, &counting(ORDER.0, "exit 0")),
            Ok(Script::ends(Exit::Code(0))
                .stdout(counted(ORDER.0))
                .pipe_capacity(PIPE)),
        ),
        (
            sh(dir, &counting(COALESCED, ": > written; read x")),
            Ok(Script::ends(Exit::Code(0))
                .stdout(counted(COALESCED))
                .pipe_capacity(PIPE)
                .hold(Hold::UntilKilled)
                .steps([Step::Touch(at("written")), Step::AwaitInputClosed])),
        ),
        (
            sh(dir, &counting(HELD.0, ": > finished")),
            Ok(Script::ends(Exit::Code(0))
                .stdout(counted(HELD.0))
                .pipe_capacity(PIPE)
                .step(Step::Touch(at("finished")))),
        ),
        (
            sh(
                dir,
                &family("t-child", "t-grandchild", "printf '%5000s' x; wait"),
            ),
            Ok(held_family()
                .stdout(format!("{:>5000}", "x"))
                .writes(at("t-child"), Writer::Child)
                .writes(at("t-grandchild"), Writer::Member(0))),
        ),
        (
            sh(
                dir,
                &family("c-child", "c-grandchild", &format!("{YES}; wait"))
                    .replace("/bin/sleep 600 &", &format!("{YES} &")),
            ),
            Ok(held_family()
                .stdout("y\n".repeat(PIPE))
                .pipe_capacity(PIPE)
                .writes(at("c-child"), Writer::Child)
                .writes(at("c-grandchild"), Writer::Member(0))),
        ),
        (
            sh(dir, &format!("echo $$ > h-child; {YES}")),
            Ok(Script::ends(Exit::Code(0))
                .hold(Hold::UntilKilled)
                .stdout("y\n".repeat(PIPE))
                .pipe_capacity(PIPE)
                .writes(at("h-child"), Writer::Child)),
        ),
        (
            sh(dir, "echo $$ > w-child; read x"),
            Ok(Script::ends(Exit::Code(0))
                .hold(Hold::UntilKilled)
                .step(Step::AwaitInputClosed)
                .writes(at("w-child"), Writer::Child)),
        ),
        (
            sh(dir, FLUSH_SCRIPT),
            Ok(Script::ends(Exit::Code(0))
                .hold(Hold::UntilKilled)
                .writes(at("fl-child"), Writer::Child)),
        ),
        (
            sh(dir, FLUSH_STREAM_SCRIPT),
            Ok(Script::ends(Exit::Code(0))
                .hold(Hold::UntilKilled)
                .step(Step::AwaitInputClosed)
                .writes(at("fs-child"), Writer::Child)),
        ),
    ]
}

/// The wait id of the flush a property waits on to know the service has
/// finished what it was handed: one no property names otherwise.
const FLUSHED: u64 = u64::MAX;

/// The script of [`FLUSH`]'s run: a child that writes its id and is held
/// until it is killed.
const FLUSH_SCRIPT: &str = "echo $$ > fl-child; /bin/sleep 600";
/// The script of [`FLUSH_LIVE_STREAM`]'s streaming child: one that writes
/// its id and waits for input it is never given.
const FLUSH_STREAM_SCRIPT: &str = "echo $$ > fs-child; read x";

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
        (ESCAPED, check.escaped(processes)),
        (RUN_INPUT, check.run_input(processes)),
        (RUN_INPUT_IGNORED, check.run_input_ignored(processes)),
        (RUN_HEAD, check.run_head(processes)),
        (INPUT, check.input(processes)),
        (INPUT_CLOSED, check.input_closed(processes)),
        (NO_INPUT, check.no_input(processes)),
        (STREAM_LINES, check.stream_lines(processes)),
        (STREAM_BYTES, check.stream_bytes(processes)),
        (STREAM_ORDER, check.stream_order(processes)),
        (STREAM_COALESCED, check.stream_coalesced(processes)),
        (STREAM_HELD, check.stream_held(processes)),
        (STREAM_LINE_TOO_LONG, check.stream_line_too_long(processes)),
        (STREAM_LINE_AT_BOUND, check.stream_line_at_bound(processes)),
        (STREAM_CANCEL, check.stream_cancel(processes)),
        (STREAM_SHUTDOWN, check.stream_shutdown(processes)),
        (FLUSH, check.flush(processes)),
        (FLUSH_LIVE_STREAM, check.flush_live_stream(processes)),
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

    /// Whether `id` arrives within `guard`.
    fn arrives(&self, id: u64, guard: HangGuard) -> bool {
        let ids = self.ids.lock().unwrap_or_else(PoisonError::into_inner);
        wait::wait_while(&self.arrived, ids, guard, |ids| !ids.contains(&id)).1
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

    /// Starts `command`, its input closed, and a reader for each of its
    /// streams.
    fn start<P: Processes>(processes: &P, command: &Command) -> Result<Started<P::Child>, Refusal> {
        Ok(Self::reading(processes.spawn(command, Input::Closed)?))
    }

    /// How `child` ended, if its wait returns within the deadline.
    fn wait<C: Child>(&self, child: &Arc<C>) -> Option<Exit> {
        let (sender, exit) = mpsc::channel();
        let child = Arc::clone(child);
        thread::spawn(move || {
            sender.send(child.wait()).ok();
        });
        wait::recv(&exit, self.ground.deadline()).ok()
    }

    /// Both streams of `started`, if each reaches its end within the
    /// deadline.
    fn streams<C: Child>(&self, started: &Started<C>) -> Option<(Vec<u8>, Vec<u8>)> {
        let deadline = self.ground.deadline();
        let [out, err] = &started.streams;
        Some((
            wait::recv(out, deadline).ok()?,
            wait::recv(err, deadline).ok()?,
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
        match processes.spawn(command, Input::Closed) {
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
            && self.ground.ends(grandchild)
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
            && self.ground.ends(grandchild)
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

    /// Flushes `service` as the wait [`FLUSHED`], and says whether its
    /// completion arrives within the deadline with nothing pending then:
    /// the service has finished what was handed to it before.
    fn flushed<P: Processes + 'static>(
        &self,
        service: &Service<P>,
        completions: &Completions,
    ) -> bool {
        service.flush(FLUSHED)
            && completions.arrives(FLUSHED, self.ground.deadline())
            && service.pending() == 0
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
        wait::recv(&returned, self.ground.deadline()).is_ok()
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
        let reaped = self.flushed(&service, &completions);
        cancelled
            && reaped
            && !self.ground.alive(child)
            && self.ground.ends(grandchild)
            && completions.ids() == [FLUSHED]
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
                .all(|&(_, grandchild)| self.ground.ends(grandchild))
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
            && self.ground.ends(grandchild)
    }

    /// Starts the escaping run `name` as `id` on `service`: the ids of its
    /// child and of the process it started outside its group, if both were
    /// written.
    fn start_escaping<P: Processes + 'static>(
        &self,
        service: &Service<P>,
        id: u64,
        name: &str,
    ) -> Option<(u32, u32)> {
        if !service.start(id, sh(self.dir, &escaping(name)), ROOMY) {
            return None;
        }
        Some((
            self.ground.written(&self.at(&format!("{name}-child")))?,
            self.ground.written(&self.at(&format!("{name}-escaped")))?,
        ))
    }

    /// [`ESCAPED`].
    fn escaped<P: Processes + Clone + 'static>(&self, processes: &P) -> bool {
        if !self.ground.escapes() {
            return true;
        }
        let (service, completions) = Self::service(processes);
        let first = self.start_escaping(&service, 1, "e1");
        let cancelled = first.is_some_and(|(child, escaped)| {
            self.ground.alive(child)
                && self.ground.alive(escaped)
                && service.cancel(1)
                && self.flushed(&service, &completions)
                && !self.ground.alive(child)
        });
        let second = self.start_escaping(&service, 2, "e2");
        let started = second
            .is_some_and(|(child, escaped)| self.ground.alive(child) && self.ground.alive(escaped));
        let shut = self.shut(&service);
        let reaped = second.is_some_and(|(child, _)| !self.ground.alive(child));
        // The escaped processes are alive still: the runs ended with their
        // streams held open, which is what the property is about.
        let escaped: Vec<u32> = [first, second]
            .into_iter()
            .flatten()
            .map(|(_, escaped)| escaped)
            .collect();
        let held = escaped.len() == 2 && escaped.iter().all(|&id| self.ground.alive(id));
        for &id in &escaped {
            self.ground.end(id);
        }
        cancelled
            && started
            && shut
            && reaped
            && held
            && service.pending() == 0
            && completions.ids() == [FLUSHED]
    }

    /// What the run of `command`, fed `input`, comes to on a service of its
    /// own, if it is completed within the deadline, with nothing left
    /// pending once its result is taken.
    fn fed<P: Processes + Clone + 'static>(
        &self,
        processes: &P,
        command: Command,
        input: Vec<u8>,
    ) -> Option<RunResult> {
        let (service, completions) = Self::service(processes);
        if !service.start_with_input(1, command, Some(input), ROOMY) {
            return None;
        }
        if !completions.arrives(1, self.ground.deadline()) {
            self.shut(&service);
            return None;
        }
        let result = service.take(1)?;
        (completions.ids() == [1] && self.flushed(&service, &completions)).then_some(result)
    }

    /// [`RUN_INPUT`].
    fn run_input<P: Processes + Clone + 'static>(&self, processes: &P) -> bool {
        let command = Command::new("/bin/cat", [""; 0], self.dir);
        self.fed(processes, command, fed())
            == Some(RunResult::Ran {
                exit: Exit::Code(0),
                stdout: fed(),
                stderr: Vec::new(),
            })
    }

    /// [`RUN_INPUT_IGNORED`].
    fn run_input_ignored<P: Processes + Clone + 'static>(&self, processes: &P) -> bool {
        let command = Command::new(TRUE, [""; 0], self.dir);
        self.fed(processes, command, vec![b'x'; FED_IGNORED])
            == Some(RunResult::Ran {
                exit: Exit::Code(0),
                stdout: Vec::new(),
                stderr: Vec::new(),
            })
    }

    /// [`RUN_HEAD`].
    fn run_head<P: Processes + Clone + 'static>(&self, processes: &P) -> bool {
        let (service, completions) = Self::service(processes);
        if !service.start_head(1, sh(self.dir, &head_family()), Some(b"fed".to_vec()), 4) {
            return false;
        }
        let Some((child, grandchild)) = self.family_ids("s-head") else {
            self.shut(&service);
            return false;
        };
        let arrived = completions.arrives(1, self.ground.deadline());
        if !arrived {
            self.shut(&service);
        }
        arrived
            && service.take(1)
                == Some(RunResult::Cut {
                    stdout: b"0123".to_vec(),
                    stderr: Vec::new(),
                })
            && !self.ground.alive(child)
            && self.ground.ends(grandchild)
    }

    /// Writes every byte of `bytes` to `input`.
    fn write_all(input: &mut impl ChildInput, bytes: &[u8]) -> Result<(), Refusal> {
        let mut at = 0;
        while at < bytes.len() {
            match input.write(&bytes[at..])? {
                0 => return Err(Refusal::new(RefusalKind::Failed, "a write wrote nothing")),
                count => at += count.min(bytes.len() - at),
            }
        }
        Ok(())
    }

    /// [`INPUT`].
    fn input<P: Processes>(&self, processes: &P) -> bool {
        let command = Command::new("/bin/cat", [""; 0], self.dir);
        let Ok(mut child) = processes.spawn(&command, Input::Pipe) else {
            return false;
        };
        let input = child.take_input();
        let started = Self::reading(child);
        let written = input.is_some_and(|mut input| {
            let written = Self::write_all(&mut input, b"a\n\xffb").is_ok();
            drop(input);
            written
        });
        if !written {
            started.child.kill();
        }
        let exit = self.wait(&started.child);
        let streams = self.streams(&started);
        written
            && exit == Some(Exit::Code(0))
            && streams.is_some_and(|(stdout, _)| stdout == b"a\n\xffb")
    }

    /// Takes the streams of `child` and starts a reader for each.
    fn reading<C: Child>(mut child: C) -> Started<C> {
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
        Started {
            child: Arc::new(child),
            streams,
        }
    }

    /// [`INPUT_CLOSED`].
    fn input_closed<P: Processes>(&self, processes: &P) -> bool {
        let command = sh(self.dir, INPUT_CLOSED_SCRIPT);
        let Ok(mut child) = processes.spawn(&command, Input::Pipe) else {
            return false;
        };
        let (Some(mut input), Some(mut out)) = (child.take_input(), child.take_output(Stream::Out))
        else {
            child.kill();
            child.wait();
            return false;
        };
        // Read until the child says it has closed its input, on a thread of
        // its own so that a child that never says so cannot hold the check.
        let (sender, said) = mpsc::channel();
        thread::spawn(move || {
            let mut all = Vec::new();
            let mut buffer = [0; 64];
            while !all.ends_with(b"closed\n") {
                match out.read(&mut buffer) {
                    Ok(0) | Err(_) => break,
                    Ok(count) => all.extend_from_slice(&buffer[..count.min(buffer.len())]),
                }
            }
            sender.send(all.ends_with(b"closed\n")).ok();
        });
        let closed = wait::recv(&said, self.ground.deadline()) == Ok(true);
        let refused = closed
            && matches!(
                input.write(b"x"),
                Err(Refusal {
                    kind: RefusalKind::InputClosed,
                    ..
                })
            );
        let child = Arc::new(child);
        child.kill();
        refused && self.wait(&child).is_some()
    }

    /// [`NO_INPUT`].
    fn no_input<P: Processes>(&self, processes: &P) -> bool {
        let Ok(mut child) = processes.spawn(&sh(self.dir, "exit 0"), Input::Closed) else {
            return false;
        };
        let none = child.take_input().is_none();
        let child = Arc::new(child);
        none && self.wait(&child) == Some(Exit::Code(0))
    }

    /// Opens `command` on `service` as the child `id` with `streaming`, and
    /// says whether it was opened.
    fn open<P: Processes + 'static>(
        &self,
        (service, completions): &(Service<P>, Arc<Completions>),
        id: u64,
        command: Command,
        streaming: Streaming,
    ) -> bool {
        service.open(id, command, streaming)
            && completions.arrives(id, self.ground.deadline())
            && service.take_stream(id) == Some(StreamReply::Opened)
    }

    /// Asks `service` for `ask` as the wait `wait`, and takes its reply
    /// once it is completed within the deadline.
    fn ask<P: Processes + 'static>(
        &self,
        (service, completions): &(Service<P>, Arc<Completions>),
        wait: u64,
        ask: impl FnOnce(&Service<P>) -> bool,
    ) -> Option<StreamReply> {
        if !ask(service) || !completions.arrives(wait, self.ground.deadline()) {
            return None;
        }
        service.take_stream(wait)
    }

    /// The next delivery of the child `child`, read as the wait `wait`.
    fn delivery<P: Processes + 'static>(
        &self,
        service: &(Service<P>, Arc<Completions>),
        child: u64,
        wait: u64,
    ) -> Option<Delivery> {
        match self.ask(service, wait, |service| service.read(child, wait))? {
            StreamReply::Delivered(delivery) => Some(delivery),
            _ => None,
        }
    }

    /// Every delivery of the child `child` to its last, read with waits
    /// counted up from `*wait`; `None` if a read is not answered within the
    /// deadline.
    fn to_the_end<P: Processes + 'static>(
        &self,
        service: &(Service<P>, Arc<Completions>),
        child: u64,
        wait: &mut u64,
    ) -> Option<Vec<Delivery>> {
        let mut deliveries = Vec::new();
        loop {
            *wait += 1;
            let delivery = self.delivery(service, child, *wait)?;
            let ended = delivery.ended.is_some();
            deliveries.push(delivery);
            if ended {
                return Some(deliveries);
            }
        }
    }

    /// Shuts the service of a streaming property down, and passes on
    /// whether the property held: a property leaves nothing running.
    fn done<P: Processes + 'static>(
        &self,
        (service, _): &(Service<P>, Arc<Completions>),
        held: bool,
    ) -> bool {
        self.shut(service) && held
    }

    /// [`STREAM_LINES`].
    fn stream_lines<P: Processes + Clone + 'static>(&self, processes: &P) -> bool {
        let service = Self::service(processes);
        let command = sh(self.dir, LINES_SCRIPT);
        let streaming = lines(Input::Pipe, ROOMY);
        if !self.open(&service, 1, command, streaming) {
            return self.done(&service, false);
        }
        let first = self.delivery(&service, 1, 2);
        let as_written = first.is_some_and(|first| {
            first.out == framed(&["one"]) && first.err == framed(&[]) && first.ended.is_none()
        });
        let written = self.ask(&service, 3, |service| {
            service.write(1, 3, b"two\n".to_vec())
        }) == Some(StreamReply::Written);
        // `two` and `err` may come in one delivery or in two.
        let mut wait = 3;
        let mut deliveries = Vec::new();
        while written && deliveries.len() < 2 {
            wait += 1;
            let Some(delivery) = self.delivery(&service, 1, wait) else {
                break;
            };
            deliveries.push(delivery);
            if lines_of(&deliveries, Stream::Out) == [b"two".to_vec()]
                && lines_of(&deliveries, Stream::Err) == [b"err".to_vec()]
            {
                break;
            }
        }
        let echoed = lines_of(&deliveries, Stream::Out) == [b"two".to_vec()]
            && lines_of(&deliveries, Stream::Err) == [b"err".to_vec()];
        wait += 1;
        let closed = echoed
            && self.ask(&service, wait, |service| service.close_input(1, wait))
                == Some(StreamReply::Written);
        let ended = closed
            && self
                .to_the_end(&service, 1, &mut wait)
                .and_then(|rest| rest.last().and_then(|last| last.ended.clone()))
                == Some(End::Exited(Exit::Code(4)));
        self.done(&service, as_written && echoed && ended)
    }

    /// [`STREAM_BYTES`].
    fn stream_bytes<P: Processes + Clone + 'static>(&self, processes: &P) -> bool {
        let service = Self::service(processes);
        let bytes = Streaming {
            input: Input::Closed,
            out: Framing::Bytes,
            err: Framing::Bytes,
            bound: ROOMY,
        };
        let mut wait = 10;
        let raw = self.open(&service, 1, sh(self.dir, r"printf 'a\377b'"), bytes)
            && self
                .to_the_end(&service, 1, &mut wait)
                .is_some_and(|all| bytes_of(&all, Stream::Out) == b"a\xffb");
        let last_line = self.open(
            &service,
            2,
            sh(self.dir, r"printf 'x\ny'"),
            lines(Input::Closed, ROOMY),
        ) && self
            .to_the_end(&service, 2, &mut wait)
            .is_some_and(|all| lines_of(&all, Stream::Out) == [b"x".to_vec(), b"y".to_vec()]);
        self.done(&service, raw && last_line)
    }

    /// [`STREAM_ORDER`].
    fn stream_order<P: Processes + Clone + 'static>(&self, processes: &P) -> bool {
        let service = Self::service(processes);
        let (count, bound) = ORDER;
        let mut wait = 1;
        let all = self
            .open(
                &service,
                1,
                sh(self.dir, &counting(count, "exit 0")),
                lines(Input::Closed, bound),
            )
            .then(|| self.to_the_end(&service, 1, &mut wait))
            .flatten();
        let held = all.is_some_and(|all| {
            bytes_of(&all, Stream::Out) == counted(count)
                && all.len() >= 400
                && all
                    .iter()
                    .all(|delivery| frame_bytes(&delivery.out) <= bound as usize)
                && all.last().and_then(|last| last.ended.clone())
                    == Some(End::Exited(Exit::Code(0)))
        });
        self.done(&service, held)
    }

    /// [`STREAM_COALESCED`]. Its bound is exactly what the child writes, so
    /// the child's readers are held once all of it has been read: then
    /// every chunk has been read while the one read was pending.
    #[expect(
        clippy::disallowed_methods,
        reason = "the process contract drives the service's streams on the adapter: it knows a child is held by the service's readout `Service::wait_held`"
    )]
    fn stream_coalesced<P: Processes + Clone + 'static>(&self, processes: &P) -> bool {
        let service = Self::service(processes);
        let script = counting(COALESCED, ": > written; read x");
        let output = counted(COALESCED);
        let opened = self.open(
            &service,
            1,
            sh(self.dir, &script),
            lines(Input::Pipe, output.len() as u64),
        );
        let (streams, completions) = &service;
        let read = opened && streams.read(1, 2);
        // The bound is exactly what the child writes, so its readers are
        // held only once all of it is written and read.
        let all_read = read && streams.wait_held(1, self.ground.deadline());
        let once = all_read && completions.ids() == [1, 2];
        let whole = once
            && matches!(
                streams.take_stream(2),
                Some(StreamReply::Delivered(delivery))
                    if bytes_of(std::slice::from_ref(&delivery), Stream::Out) == output
            );
        streams.cancel(1);
        self.done(&service, whole)
    }

    /// [`STREAM_HELD`]. The child cannot finish while it is held: what is
    /// outside it is at most the bound and a pipe's capacity.
    #[expect(
        clippy::disallowed_methods,
        reason = "the process contract drives the service's streams on the adapter: it knows a child is held by the service's readout `Service::wait_held`"
    )]
    fn stream_held<P: Processes + Clone + 'static>(&self, processes: &P) -> bool {
        let service = Self::service(processes);
        let (count, bound) = HELD;
        let finished = self.at("finished");
        let opened = self.open(
            &service,
            1,
            sh(self.dir, &counting(count, ": > finished")),
            lines(Input::Closed, bound),
        );
        let held = opened
            && service.0.wait_held(1, self.ground.deadline())
            && !self.ground.exists(&finished);
        let mut wait = 1;
        let went_on =
            held && self.to_the_end(&service, 1, &mut wait).is_some_and(|all| {
                bytes_of(&all, Stream::Out) == counted(count)
                    && all.last().and_then(|last| last.ended.clone())
                        == Some(End::Exited(Exit::Code(0)))
            }) && self.ground.exists(&finished);
        self.done(&service, went_on)
    }

    /// [`STREAM_LINE_TOO_LONG`].
    fn stream_line_too_long<P: Processes + Clone + 'static>(&self, processes: &P) -> bool {
        let service = Self::service(processes);
        let script = family("t-child", "t-grandchild", "printf '%5000s' x; wait");
        if !self.open(
            &service,
            1,
            sh(self.dir, &script),
            lines(Input::Closed, 1024),
        ) {
            return self.done(&service, false);
        }
        let Some((child, grandchild)) = self.family_ids("t") else {
            return self.done(&service, false);
        };
        let mut wait = 1;
        let ended = self
            .to_the_end(&service, 1, &mut wait)
            .and_then(|all| all.last().and_then(|last| last.ended.clone()));
        let held = ended
            == Some(End::LineTooLong {
                stream: Stream::Out,
                bound: 1024,
            })
            && self.flushed(&service.0, &service.1)
            && !self.ground.alive(child)
            && self.ground.ends(grandchild);
        self.done(&service, held)
    }

    /// [`STREAM_LINE_AT_BOUND`].
    fn stream_line_at_bound<P: Processes + Clone + 'static>(&self, processes: &P) -> bool {
        let service = Self::service(processes);
        let [at, over, terminated] = AT_BOUND_SCRIPTS;
        let mut wait = 10;
        let whole = self.open(
            &service,
            1,
            sh(self.dir, at),
            lines(Input::Closed, AT_BOUND),
        ) && self.to_the_end(&service, 1, &mut wait).is_some_and(|all| {
            lines_of(&all, Stream::Out) == [b"abcd".to_vec()]
                && all.last().and_then(|last| last.ended.clone())
                    == Some(End::Exited(Exit::Code(0)))
        });
        let mut too_long = |id, script| {
            self.open(
                &service,
                id,
                sh(self.dir, script),
                lines(Input::Closed, AT_BOUND),
            ) && self.to_the_end(&service, id, &mut wait).is_some_and(|all| {
                lines_of(&all, Stream::Out).is_empty()
                    && all.last().and_then(|last| last.ended.clone())
                        == Some(End::LineTooLong {
                            stream: Stream::Out,
                            bound: AT_BOUND,
                        })
            })
        };
        let over = too_long(2, over);
        let terminated = too_long(3, terminated);
        self.done(&service, whole && over && terminated)
    }

    /// [`STREAM_CANCEL`].
    #[expect(
        clippy::disallowed_methods,
        reason = "the process contract drives the service's streams on the adapter: it knows a child is held by the service's readout `Service::wait_held`"
    )]
    fn stream_cancel<P: Processes + Clone + 'static>(&self, processes: &P) -> bool {
        let service = Self::service(processes);
        let script = family("c-child", "c-grandchild", &format!("{YES}; wait"))
            .replace("/bin/sleep 600 &", &format!("{YES} &"));
        if !self.open(&service, 1, sh(self.dir, &script), lines(Input::Closed, 64)) {
            return self.done(&service, false);
        }
        let (streams, completions) = &service;
        let Some((child, grandchild)) = self.family_alive("c") else {
            streams.cancel(1);
            return self.done(&service, false);
        };
        let held = streams.wait_held(1, self.ground.deadline());
        let cancelled = streams.cancel(1);
        let ended = held
            && cancelled
            && self.flushed(streams, completions)
            && !self.ground.alive(child)
            && self.ground.ends(grandchild)
            && completions.ids() == [1, FLUSHED];
        self.done(&service, ended)
    }

    /// [`FLUSH`].
    fn flush<P: Processes + Clone + 'static>(&self, processes: &P) -> bool {
        let (service, completions) = Self::service(processes);
        if !service.start(1, sh(self.dir, FLUSH_SCRIPT), ROOMY) {
            return false;
        }
        let Some(child) = self.ground.written(&self.at("fl-child")) else {
            self.shut(&service);
            return false;
        };
        let asked = service.flush(2);
        // The child cannot end until it is cancelled, so nothing the flush
        // waits for is done: a flush completed at its call is here now.
        let waited = asked && completions.ids().is_empty() && self.ground.alive(child);
        let cancelled = service.cancel(1);
        let flushed = completions.arrives(2, self.ground.deadline());
        let then = flushed && !self.ground.alive(child) && service.pending() == 0;
        let shut = self.shut(&service);
        waited && cancelled && then && shut && completions.ids() == [2]
    }

    /// [`FLUSH_LIVE_STREAM`].
    fn flush_live_stream<P: Processes + Clone + 'static>(&self, processes: &P) -> bool {
        let service = Self::service(processes);
        if !self.open(
            &service,
            1,
            sh(self.dir, FLUSH_STREAM_SCRIPT),
            lines(Input::Pipe, ROOMY),
        ) {
            return self.done(&service, false);
        }
        let (streams, completions) = &service;
        let Some(child) = self.ground.written(&self.at("fs-child")) else {
            return self.done(&service, false);
        };
        let reading = streams.read(1, 2);
        let flushed = streams.flush(3) && completions.arrives(3, self.ground.deadline());
        let alive = flushed && self.ground.alive(child) && completions.ids() == [1, 3];
        streams.cancel(1);
        self.done(&service, reading && alive)
    }

    /// [`STREAM_SHUTDOWN`].
    #[expect(
        clippy::disallowed_methods,
        reason = "the process contract drives the service's streams on the adapter: it knows a child is held by the service's readout `Service::wait_held`"
    )]
    fn stream_shutdown<P: Processes + Clone + 'static>(&self, processes: &P) -> bool {
        let service = Self::service(processes);
        let held_open = self.open(
            &service,
            1,
            sh(self.dir, &format!("echo $$ > h-child; {YES}")),
            lines(Input::Closed, 64),
        );
        let waiting_open = self.open(
            &service,
            2,
            sh(self.dir, "echo $$ > w-child; read x"),
            lines(Input::Pipe, ROOMY),
        );
        let ids = (
            self.ground.written(&self.at("h-child")),
            self.ground.written(&self.at("w-child")),
        );
        let held = held_open && waiting_open && service.0.wait_held(1, self.ground.deadline());
        let shut = self.shut(&service.0);
        let (Some(held_child), Some(waiting_child)) = ids else {
            return false;
        };
        held && shut
            && !self.ground.alive(held_child)
            && !self.ground.alive(waiting_child)
            && service.0.pending() == 0
    }
}

/// Lines framing for both streams, with `input` and `bound`.
const fn lines(input: Input, bound: u64) -> Streaming {
    Streaming {
        input,
        out: Framing::Lines,
        err: Framing::Lines,
        bound,
    }
}

/// `lines` as frames.
fn framed(lines: &[&str]) -> Frames {
    Frames::Lines(lines.iter().map(|line| line.as_bytes().to_vec()).collect())
}

/// The frames of `stream` in `delivery`.
const fn frames_of(delivery: &Delivery, stream: Stream) -> &Frames {
    match stream {
        Stream::Out => &delivery.out,
        Stream::Err => &delivery.err,
    }
}

/// Every line of `stream` in `deliveries`, in order.
fn lines_of(deliveries: &[Delivery], stream: Stream) -> Vec<Vec<u8>> {
    deliveries
        .iter()
        .flat_map(|delivery| match frames_of(delivery, stream) {
            Frames::Lines(lines) => lines.clone(),
            Frames::Bytes(_) | Frames::Messages(_) => Vec::new(),
        })
        .collect()
}

/// How many bytes `frames` stand for, a line feed counted for each line
/// and a message's body alone for each message.
fn frame_bytes(frames: &Frames) -> usize {
    match frames {
        Frames::Lines(lines) => lines.iter().map(|line| line.len() + 1).sum(),
        Frames::Bytes(bytes) => bytes.len(),
        Frames::Messages(bodies) => bodies.iter().map(Vec::len).sum(),
    }
}

/// The bytes of `stream` in `deliveries`, end to end, a line feed after
/// each line and each message's body alone.
fn bytes_of(deliveries: &[Delivery], stream: Stream) -> Vec<u8> {
    let mut all = Vec::new();
    for delivery in deliveries {
        match frames_of(delivery, stream) {
            Frames::Bytes(bytes) => all.extend_from_slice(bytes),
            Frames::Lines(lines) => {
                for line in lines {
                    all.extend_from_slice(line);
                    all.push(b'\n');
                }
            }
            Frames::Messages(bodies) => all.extend(bodies.iter().flatten()),
        }
    }
    all
}

#[cfg(test)]
mod tests {
    use super::PROPERTIES;

    #[test]
    fn the_properties_are_thirty_one_and_each_is_named_once() {
        let mut names = PROPERTIES.to_vec();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), 31);
    }
}
