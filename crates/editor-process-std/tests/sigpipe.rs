//! A write to an input its child has closed is a refusal, not `SIGPIPE`,
//! in a process whose `SIGPIPE` is at its default, as a Lean executable's
//! is: std's start-up, which ignores the signal, never runs there.
//!
//! It is a test binary of its own, with one test, because it sets the
//! process's disposition of `SIGPIPE`. The child runs in a temporary
//! directory the test makes and removes, and is killed and reaped before
//! the test returns. By returning at all, the test shows the process was
//! not ended by the signal.

use std::thread;
use std::time::Duration;

use editor_process::{Child, ChildInput, Command, Input, Output, Processes, RefusalKind, Stream};
use editor_process_std::StdProcesses;

/// How long the child is given to say it has closed its input.
const DEADLINE: Duration = Duration::from_secs(10);

#[test]
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
    )
    .with_input(Input::Pipe);
    let mut child = StdProcesses::system()
        .spawn(&command)
        .expect("the child starts");
    let mut input = child.take_input().expect("an input");
    let mut out = child.take_output(Stream::Out).expect("its output");

    let said = thread::spawn(move || {
        let mut all = Vec::new();
        let mut buffer = [0; 64];
        while !all.ends_with(b"closed\n") {
            match out.read(&mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(count) => all.extend_from_slice(&buffer[..count]),
            }
        }
        all
    });
    let end = std::time::Instant::now() + DEADLINE;
    while !said.is_finished() && std::time::Instant::now() < end {
        thread::sleep(Duration::from_millis(2));
    }
    assert!(said.is_finished(), "the child said it closed its input");
    assert_eq!(said.join().expect("the reader ends"), b"closed\n");

    let refusal = input.write(b"x").expect_err("refused");

    assert_eq!(refusal.kind, RefusalKind::InputClosed);
    child.kill();
    child.wait();
}
