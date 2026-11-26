//! The stream port's contract over the real service: [`ServiceGround`],
//! `editor-service`'s [`Ground`] over a [`Service`], and [`scripts`], what
//! each of the contract's scenarios is as a command and as the fake's
//! script.
//!
//! `editor_service::stream::contract::check` holds a stream source to the
//! port's rules, the same check its fake passes. Here the source is the
//! process service itself ([`Service`] is a
//! [`editor_service::stream::StreamSource`]), over whatever
//! [`Processes`] it is given: `tests/stream_contract.rs` runs it over
//! [`FakeProcesses`](crate::fake::FakeProcesses), each scenario scripted
//! with [`scripts`], and `editor-process-std`'s over real processes, where
//! each scenario is the `/bin/sh -c` script [`scripts`] gives beside it.
//!
//! The ground opens a scenario's child as a job does ([`Service::open`],
//! waiting for the open's completion on its event), makes a job's read
//! pending with [`Service::read`] and withdraws it with
//! [`Service::cancel`], and waits for a reader's park with
//! [`Service::wait_held`]. Dropping it shuts the service down, so a check
//! leaves nothing running, a consumer a failed property left in a pull
//! among it.
//!
//! # Where an addition goes
//!
//! A new scenario of the contract's is a `/bin/sh -c` script and a fake's
//! script in [`scripts`], one each, written to do the same.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, PoisonError};

use editor_service::stream::StreamSource;
use editor_service::stream::contract::{
    AT_BOUND_MESSAGE, Ground, MALFORMED_WRITTEN, MEGABYTE_LINE, MESSAGES_WRITTEN, NUMBERED,
    Scenario, TOO_LONG_WRITTEN, megabyte_line, numbered,
};
use editor_wait::HangGuard;

use crate::fake::{Hold, Script, Step};
use crate::service::{Service, StreamReply, Streaming};
use crate::{Command, Exit, Input, Processes, Stream};

/// The ids the service completed, as the ground reads them.
#[derive(Default)]
struct Completions {
    /// The ids, oldest first.
    ids: Mutex<Vec<u64>>,
    /// Told whenever an id arrives.
    arrived: Condvar,
}

impl Completions {
    /// Whether `id` arrives within `guard`.
    fn arrives(&self, id: u64, guard: HangGuard) -> bool {
        let ids = self.ids.lock().unwrap_or_else(PoisonError::into_inner);
        editor_wait::wait_while(&self.arrived, ids, guard, |ids| !ids.contains(&id)).1
    }
}

/// The stream contract's ground over a process service: the scenarios'
/// children are opened in it as a job opens them.
pub struct ServiceGround<P: Processes + 'static> {
    /// The service, which is the source checked.
    service: Service<P>,
    /// What it completed.
    completions: Arc<Completions>,
    /// The directory every child runs in.
    dir: PathBuf,
    /// The next id the ground gives a child or a wait.
    next: AtomicU64,
    /// The pending read of each child that has one, by the child.
    reads: Mutex<HashMap<u64, u64>>,
    /// hang guard: each event the ground and the check wait for.
    deadline: HangGuard,
}

impl<P: Processes + 'static> ServiceGround<P> {
    /// A ground over a new service of `processes`, whose children run in
    /// `dir`, an absolute directory that exists and is the caller's; every
    /// wait bounded by `deadline`, a hang guard.
    pub fn new(processes: P, dir: &Path, deadline: HangGuard) -> Self {
        let completions = Arc::new(Completions::default());
        let completing = Arc::clone(&completions);
        let service = Service::new(processes, move |id| {
            completing
                .ids
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(id);
            completing.arrived.notify_all();
        });
        Self {
            service,
            completions,
            dir: dir.to_path_buf(),
            next: AtomicU64::new(1),
            reads: Mutex::new(HashMap::new()),
            deadline,
        }
    }

    /// The service.
    pub const fn service(&self) -> &Service<P> {
        &self.service
    }

    /// A fresh id.
    fn id(&self) -> u64 {
        self.next.fetch_add(1, Ordering::Relaxed)
    }
}

impl<P: Processes + 'static> Drop for ServiceGround<P> {
    fn drop(&mut self) {
        self.service.shutdown();
    }
}

impl<P: Processes + 'static> Ground for ServiceGround<P> {
    fn source(&self) -> &dyn StreamSource {
        &self.service
    }

    fn open(&self, scenario: Scenario) -> Option<u64> {
        let id = self.id();
        let opened = self
            .service
            .open(id, command(&self.dir, scenario), streaming(scenario))
            && self.completions.arrives(id, self.deadline)
            && self.service.take_stream(id) == Some(StreamReply::Opened);
        opened.then_some(id)
    }

    fn wait_held(&self, child: u64) -> bool {
        #[expect(
            clippy::disallowed_methods,
            reason = "the stream contract over the real service knows a child is held by the service's readout `Service::wait_held`, bounded by the ground's hang guard"
        )]
        let held = self.service.wait_held(child, self.deadline);
        held
    }

    fn pend_read(&self, child: u64) -> bool {
        let wait = self.id();
        let pending = self.service.read(child, wait);
        if pending {
            self.reads
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .insert(child, wait);
        }
        pending
    }

    fn withdraw_read(&self, child: u64) {
        let wait = self
            .reads
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&child);
        if let Some(wait) = wait {
            self.service.cancel(wait);
        }
    }

    fn deadline(&self) -> HangGuard {
        self.deadline
    }
}

/// How `scenario`'s child is opened.
fn streaming(scenario: Scenario) -> Streaming {
    let shape = scenario.shape();
    Streaming {
        input: if shape.input {
            Input::Pipe
        } else {
            Input::Closed
        },
        out: shape.out,
        err: shape.err,
        bound: shape.bound,
    }
}

/// `scenario`'s command: `/bin/sh -c` its script, in `dir`.
fn command(dir: &Path, scenario: Scenario) -> Command {
    Command::new("/bin/sh", ["-c", &shell(scenario)], dir)
}

/// `bytes` as a `printf` format that writes them: the line feeds and
/// carriage returns escaped, between single quotes. The contract's chunks
/// hold no quote and no `%` or backslash.
fn printf(bytes: &[u8]) -> String {
    let text = String::from_utf8_lossy(bytes)
        .replace('\r', "\\r")
        .replace('\n', "\\n");
    format!("printf '{text}'")
}

/// `printf`s of each chunk, then `then`.
fn printfs(chunks: &[&[u8]], then: &str) -> String {
    let mut script: Vec<String> = chunks.iter().map(|chunk| printf(chunk)).collect();
    script.push(then.to_owned());
    script.join("; ")
}

/// The `/bin/sh -c` script of `scenario`, which does what the contract
/// says it does.
fn shell(scenario: Scenario) -> String {
    match scenario {
        Scenario::Echo => r#"echo one; read x; echo "got $x"; exit 3"#.to_owned(),
        Scenario::Numbered => {
            format!("i=0; while [ $i -lt {NUMBERED} ]; do echo $i; i=$((i+1)); done")
        }
        Scenario::Megabytes => format!(r"printf '%{MEGABYTE_LINE}s\n' x"),
        Scenario::OneLine => "echo taken".to_owned(),
        Scenario::AwaitsLine => r#"read x; echo "$x""#.to_owned(),
        Scenario::Messages => printfs(&MESSAGES_WRITTEN, "exit 0"),
        Scenario::MessageAtBound => printfs(&[AT_BOUND_MESSAGE], "exit 0"),
        Scenario::MessageTooLong => printfs(&TOO_LONG_WRITTEN, "read x"),
        Scenario::MessageMalformed => printfs(&MALFORMED_WRITTEN, "read x"),
    }
}

/// The fake's script of `scenario`: what its `/bin/sh -c` script does.
fn fake_script(scenario: Scenario) -> Script {
    let writes = |chunks: &[&[u8]]| {
        chunks
            .iter()
            .map(|chunk| Step::Write(Stream::Out, chunk.to_vec()))
            .collect::<Vec<_>>()
    };
    let ends = Script::ends(Exit::Code(0));
    match scenario {
        Scenario::Echo => Script::ends(Exit::Code(3)).steps([
            Step::Write(Stream::Out, b"one\n".to_vec()),
            Step::Write(Stream::Out, b"got ".to_vec()),
            Step::EchoLine(Stream::Out),
        ]),
        // A pipe's capacity, so the child blocks in its write while held.
        Scenario::Numbered => ends.stdout(numbered()).pipe_capacity(1 << 16),
        Scenario::Megabytes => ends.stdout(megabyte_line()),
        Scenario::OneLine => ends.stdout("taken\n"),
        Scenario::AwaitsLine => ends.step(Step::EchoLine(Stream::Out)),
        Scenario::Messages => ends.steps(writes(&MESSAGES_WRITTEN)),
        Scenario::MessageAtBound => ends.stdout(AT_BOUND_MESSAGE),
        Scenario::MessageTooLong => ends
            .steps(writes(&TOO_LONG_WRITTEN))
            .step(Step::AwaitInputClosed)
            .hold(Hold::UntilKilled),
        Scenario::MessageMalformed => ends
            .steps(writes(&MALFORMED_WRITTEN))
            .step(Step::AwaitInputClosed)
            .hold(Hold::UntilKilled),
    }
}

/// Each scenario's command in `dir`, and the fake's script that does what
/// it does: so the fake runs the same check, and a real adapter's run is
/// what shows those claims true.
pub fn scripts(dir: &Path) -> Vec<(Command, Script)> {
    Scenario::ALL
        .into_iter()
        .map(|scenario| (command(dir, scenario), fake_script(scenario)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_scenarios_script_writes_its_chunks_as_printf_formats() {
        assert_eq!(
            printf(b"Content-Length: 2\r\n\r\nok"),
            r"printf 'Content-Length: 2\r\n\r\nok'"
        );
        assert_eq!(scripts(Path::new("/d")).len(), Scenario::ALL.len());
    }
}
