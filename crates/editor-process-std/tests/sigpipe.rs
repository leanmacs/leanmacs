//! A write to an input its child has closed is a refusal, not `SIGPIPE`,
//! in a process whose `SIGPIPE` is at its default, as a Lean executable's
//! is: std's start-up, which ignores the signal, never runs there.
//!
//! It is a test binary of its own, with one test, because it sets the
//! process's disposition of `SIGPIPE`. The child runs in a temporary
//! directory the test makes and removes, and is killed and reaped before
//! the test returns. By returning at all, the test shows the process was
//! not ended by the signal.

use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use editor_wait::HangGuard;

use editor_process::{Child, ChildInput, Command, Input, Output, Processes, RefusalKind, Stream};
use editor_process_std::StdProcesses;

/// hang guard: the child's saying it has closed its input, which must come;
/// only a hang reaches the bound, and the check then fails as a hang.
const DEADLINE: HangGuard = HangGuard::on(
    "the child's saying it has closed its input",
    Duration::from_secs(10),
);

#[test]
#[expect(
    clippy::disallowed_methods,
    reason = "the adapter's own test on a real child process"
)]
fn a_write_to_an_input_the_child_closed_is_refused_with_sigpipe_at_its_default() {
    // SAFETY: setting a signal's disposition to its default is sound; no
    // handler is installed, and nothing else in this binary relies on it.
    let previous = unsafe { libc::signal(libc::SIGPIPE, libc::SIG_DFL) };
    assert_ne!(previous, libc::SIG_ERR);
    let directory = tempfile::tempdir().expect("a temporary directory can be made");
    let command = Command::new(
        "/bin/sh",
        ["-c", "exec 0<&-; echo closed; exec /bin/sleep 600"],
        directory.path(),
    );
    let mut child = StdProcesses::system()
        .spawn(&command, Input::Pipe)
        .expect("the child starts");
    let mut input = child.take_input().expect("an input");
    let mut out = child.take_output(Stream::Out).expect("its output");

    // The reader sends what it read once the child has said it, or once
    // the child's output ends.
    let (sender, said) = mpsc::channel();
    let reader = thread::spawn(move || {
        let mut all = Vec::new();
        let mut buffer = [0; 64];
        while !all.ends_with(b"closed\n") {
            match out.read(&mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(count) => all.extend_from_slice(&buffer[..count]),
            }
        }
        sender.send(all).ok();
    });
    let said = editor_wait::recv(&said, DEADLINE);
    let wrote = said.is_ok().then(|| input.write(b"x"));
    // Killed whatever was seen, so a reader still waiting ends and is
    // joined.
    child.kill();
    child.wait();
    reader.join().expect("the reader ends");

    assert_eq!(
        said,
        Ok(b"closed\n".to_vec()),
        "the child said it closed its input"
    );
    let refusal = wrote
        .expect("written once it was said")
        .expect_err("refused");
    assert_eq!(refusal.kind, RefusalKind::InputClosed);
}
