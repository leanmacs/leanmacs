//! Child processes: what the editor needs of them, in its own terms, and
//! the service that owns every child it starts.
//!
//! [`Processes`] is the port: start a [`Command`] as a child in a process
//! group of its own, and then, through the [`Child`] it gives, read its
//! output, wait for it and kill it. The crate defines it, publishes a fake
//! of it ([`fake::FakeProcesses`]) and the contract every implementation
//! keeps ([`contract::check`]); the real adapter, over `std::process`, is
//! another crate (`editor-process-std`). [`service::Service`] is what the
//! editor asks, above the port: a run to its end, or a streaming child read
//! and written a request at a time, framed and bounded ([`frame`]), each
//! completed through a closure it is given, cancelled by killing the
//! child's group, and every child killed and reaped at shutdown. The crate
//! has no dependencies and knows nothing about Lean.
//!
//! # The rules of the port
//!
//! - **A command** is a program, its arguments, the environment the child
//!   gets and an absolute directory it runs in. The program is a bare name,
//!   looked up on the `PATH` of the environment the child gets, or an
//!   absolute path. The editor has no working directory, so a directory
//!   that is not absolute, and a program that names a directory without
//!   being absolute, are refused, by the service and before any spawn
//!   ([`RefusalKind::RelativeDirectory`], [`RefusalKind::RelativeProgram`]).
//! - **The environment** ([`Environment`]) is the editor's own, emptied
//!   first if `clear` is set, then with `unset` removed, then with `set`
//!   applied.
//! - **[`Processes::spawn`]** starts the child in a new process group whose
//!   id is the child's, with its standard output and error piped, and its
//!   standard input closed, or a pipe when the spawn asks for one
//!   ([`Input`]). The input is the spawn's, not the command's: the service
//!   decides it, a run's child always closed and a streaming child's as
//!   its [`service::Streaming`] says. A program that cannot be started is a
//!   [`Refusal`], a value: its kind is what the editor decides on, and its
//!   detail the platform's words, naming the program and the directory.
//! - **[`Child::wait`]** blocks until the child has ended; then ends every
//!   process still in its group; then reaps the child; then returns how it
//!   ended ([`Exit`]). Asked again, it answers the same at once.
//! - **[`Child::kill`]** ends the child's whole group. It can be called from
//!   another thread while `wait` blocks, and does nothing once the child
//!   has been reaped, so it never signals a group id that may have been
//!   given to another process since.
//! - **[`Output::read`]** reads a stream of the child's, blocking until
//!   there is something to read; 0 means the stream has closed, which it
//!   does once every process that held it has ended.
//! - **[`Child::take_input`]** gives the child's standard input once, when
//!   the spawn asked for a pipe ([`Input::Pipe`]), and `None` otherwise.
//! - **[`ChildInput::write`]** writes to it, blocking while the pipe is
//!   full, and says how many bytes it took, which may be fewer than it was
//!   given. A write after the child has closed its end, or has ended, is
//!   [`RefusalKind::InputClosed`]: a value, never a signal that ends the
//!   editor. Dropping the input closes it, and the child reads its end.
//!
//! The port is pull-based and blocking on purpose: a reader that stops
//! reading is backpressure, and a writer is held by the pipe it writes
//! to. The child's standard input is one more half to take, beside its
//! outputs.
//!
//! What the group kill does not reach: a descendant that leaves the group
//! (`setsid`, `setpgid`) or forks into a session of its own. No portable
//! mechanism reaches those; the design docs keep it as an open question
//! (`docs/design/rust-library.md`, "Processes"). One that holds a child's
//! stream keeps it open after the child is reaped; the service does not
//! let that hold a cancel or shutdown ([`service`], "A stream held open
//! after the reap").
//!
//! # Where an addition goes
//!
//! | Addition | Where | Pinned by |
//! |---|---|---|
//! | Something more a child is started with | A field of [`Command`], with a default that keeps today's behaviour; or, when the service decides it for each kind of child, as it does the standard input, an argument of [`Processes::spawn`] | A property of [`contract`], and the fake's tests |
//! | Something more a running child is asked | A method of [`Child`], with its rule in the list above | Its property in [`contract::check`], with a fake written to break it in `tests/contract.rs` |
//! | Another failure the editor decides on | A variant of [`RefusalKind`] | The property that asks for it |
//! | A rule of the service (what a run comes to, what cancelling means) | [`service::Service`] | The service's unit tests, on the fake, and a service property of [`contract`] where a real process must show it |
//! | Another way for a test to set the fake up | A method of [`fake::FakeProcesses`] | The fake's tests |

use std::path::PathBuf;

pub mod contract;
pub mod fake;
pub mod frame;
pub mod service;

/// What to start: a program, its arguments, its environment and the
/// directory it runs in. The module docs have the rules.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Command {
    /// A bare name, looked up on the `PATH` the child gets, or an absolute
    /// path.
    pub program: String,
    /// The arguments, after the program's own name.
    pub arguments: Vec<String>,
    /// The environment the child gets.
    pub environment: Environment,
    /// The directory the child runs in: an absolute path.
    pub directory: PathBuf,
}

/// What a child's standard input is.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub enum Input {
    /// Closed: the child reads end of file at once.
    #[default]
    Closed,
    /// A pipe, taken with [`Child::take_input`].
    Pipe,
}

impl Command {
    /// The command that runs `program` with `arguments` in `directory`, with
    /// the editor's environment as it is.
    pub fn new(
        program: impl Into<String>,
        arguments: impl IntoIterator<Item = impl Into<String>>,
        directory: impl Into<PathBuf>,
    ) -> Self {
        Self {
            program: program.into(),
            arguments: arguments.into_iter().map(Into::into).collect(),
            environment: Environment::default(),
            directory: directory.into(),
        }
    }

    /// The same command with `environment`.
    #[must_use]
    pub fn with_environment(mut self, environment: Environment) -> Self {
        self.environment = environment;
        self
    }
}

/// The environment a child gets: the editor's own, emptied first if
/// `clear` is set, then with `unset` removed, then with `set` applied.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub struct Environment {
    /// Whether the editor's environment is emptied first.
    pub clear: bool,
    /// Each variable and the value it is given, applied last.
    pub set: Vec<(String, String)>,
    /// Each variable removed, before `set` is applied.
    pub unset: Vec<String>,
}

/// How a child ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Exit {
    /// It exited with this status.
    Code(i32),
    /// It was ended by this signal.
    Signal(i32),
}

/// One of a child's output streams.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Stream {
    /// Its standard output.
    Out,
    /// Its standard error.
    Err,
}

/// Why something was not done: a kind the editor decides on, and the
/// platform's words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    /// What the editor decides on.
    pub kind: RefusalKind,
    /// The platform's words, for a person. A refusal to start names the
    /// program and the directory.
    pub detail: String,
}

impl Refusal {
    /// A refusal of `kind` that says `detail`.
    pub fn new(kind: RefusalKind, detail: impl Into<String>) -> Self {
        Self {
            kind,
            detail: detail.into(),
        }
    }
}

/// What a refusal is, as the editor decides on it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RefusalKind {
    /// The directory is not absolute. The service refuses it before any
    /// spawn.
    RelativeDirectory,
    /// The program names a directory without being absolute. The service
    /// refuses it before any spawn.
    RelativeProgram,
    /// The program, or the directory, is not there. The platform does not
    /// say which, so the detail names both.
    NotFound,
    /// The platform does not allow it: a program that is not executable, a
    /// directory given as the program.
    Denied,
    /// The service has shut down, and starts nothing more.
    ShutDown,
    /// The child's standard input is closed: none was asked for, the job
    /// closed it, or the child closed it or ended.
    InputClosed,
    /// Anything else; the detail says what.
    Failed,
}

/// Processes, as far as the editor needs them. The module docs have the
/// rules; [`contract::check`] holds an implementation to them.
///
/// It is `Send + Sync`: each run starts its child on a thread of its own.
pub trait Processes: Send + Sync {
    /// A child it started.
    type Child: Child;

    /// Starts `command` as a child in a new process group of its own, with
    /// its standard output and error piped and `input` as its standard
    /// input. A program that cannot be started is a refusal, never a
    /// panic.
    fn spawn(&self, command: &Command, input: Input) -> Result<Self::Child, Refusal>;
}

/// A child a [`Processes`] started. It is shared between the thread that
/// waits for it and whoever kills it, so its methods but
/// [`Child::take_output`] and [`Child::take_input`] take `&self`.
pub trait Child: Send + Sync + 'static {
    /// One of its output streams, taken from it.
    type Output: Output;

    /// Its standard input, taken from it.
    type Input: ChildInput;

    /// The child's process id, which is also its group's.
    fn id(&self) -> u32;

    /// The stream `stream`, once: `None` when it was taken already.
    fn take_output(&mut self, stream: Stream) -> Option<Self::Output>;

    /// Its standard input, once: `None` when it was spawned with
    /// [`Input::Closed`], or when it was taken already.
    fn take_input(&mut self) -> Option<Self::Input>;

    /// Blocks until the child has ended, ends every process still in its
    /// group, reaps the child and returns how it ended. Asked again, it
    /// answers the same at once.
    fn wait(&self) -> Exit;

    /// Ends the child's whole group. It does nothing once the child has
    /// been reaped. It may be called from any thread, while
    /// [`Child::wait`] blocks among them.
    fn kill(&self);
}

/// One of a child's output streams.
pub trait Output: Send + 'static {
    /// Reads into `buffer`, blocking until there is something to read, and
    /// says how many bytes it read: 0 once the stream has closed.
    fn read(&mut self, buffer: &mut [u8]) -> Result<usize, Refusal>;
}

/// A child's standard input. Dropping it closes it.
pub trait ChildInput: Send + 'static {
    /// Writes from `bytes`, blocking while the pipe is full, and says how
    /// many it wrote: at least one, and maybe fewer than all. A child that
    /// has closed its end, or ended, is [`RefusalKind::InputClosed`], and
    /// never a signal.
    fn write(&mut self, bytes: &[u8]) -> Result<usize, Refusal>;
}

/// Why `command` may not be started at all, if it may not: a directory
/// that is not absolute, or a program that names a directory without being
/// absolute. It is the core's rule, so no adapter is asked such a command.
pub fn refusal_before_spawn(command: &Command) -> Option<Refusal> {
    if !command.directory.is_absolute() {
        return Some(Refusal::new(
            RefusalKind::RelativeDirectory,
            format!(
                "cannot start `{}` in {}: the directory is not absolute",
                command.program,
                command.directory.display()
            ),
        ));
    }
    if command.program.contains('/') && !command.program.starts_with('/') {
        return Some(Refusal::new(
            RefusalKind::RelativeProgram,
            format!(
                "cannot start `{}` in {}: the program names a directory and is not absolute",
                command.program,
                command.directory.display()
            ),
        ));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::{Command, RefusalKind, refusal_before_spawn};

    fn kind(command: &Command) -> Option<RefusalKind> {
        refusal_before_spawn(command).map(|refusal| refusal.kind)
    }

    #[test]
    fn a_directory_that_is_not_absolute_is_refused_and_names_the_program_and_the_directory() {
        let command = Command::new("/bin/sh", ["-c", "true"], "relative/dir");

        let refusal = refusal_before_spawn(&command).expect("refused");

        assert_eq!(refusal.kind, RefusalKind::RelativeDirectory);
        assert!(refusal.detail.contains("/bin/sh"));
        assert!(refusal.detail.contains("relative/dir"));
        assert_eq!(
            kind(&Command::new("sh", [""; 0], "")),
            Some(RefusalKind::RelativeDirectory)
        );
    }

    #[test]
    fn a_program_that_names_a_directory_without_being_absolute_is_refused() {
        assert_eq!(
            kind(&Command::new("bin/sh", [""; 0], "/tmp")),
            Some(RefusalKind::RelativeProgram)
        );
        assert_eq!(
            kind(&Command::new("./sh", [""; 0], "/tmp")),
            Some(RefusalKind::RelativeProgram)
        );
    }

    #[test]
    fn the_directory_is_looked_at_before_the_program() {
        assert_eq!(
            kind(&Command::new("bin/sh", [""; 0], "relative")),
            Some(RefusalKind::RelativeDirectory)
        );
    }

    #[test]
    fn a_bare_name_and_an_absolute_program_in_an_absolute_directory_are_not_refused() {
        assert_eq!(kind(&Command::new("sh", [""; 0], "/tmp")), None);
        assert_eq!(kind(&Command::new("/bin/sh", [""; 0], "/")), None);
    }
}
