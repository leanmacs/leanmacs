//! What the streaming tests of [`super`] share: [`super::streaming`]'s
//! and [`super::hand_off`]'s, each over the port's fake. One copy, so the
//! two modules wait the same way and on the same events.

use std::sync::mpsc::{self, Receiver};
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

use editor_wait::HangGuard;

use super::{Service, StreamReply, Streaming};
use crate::fake::FakeProcesses;
use crate::frame::{Frames, Framing};
use crate::{Command, Input};

/// hang guard: each event a test waits for with it, a completion, a
/// reader's park, a reading, a pull's or a write's return, a consumer's
/// wait or the fake reaching a state, which must come; only a hang reaches
/// the bound, and the check then fails as a hang.
pub(super) const DEADLINE: HangGuard = HangGuard::on(
    "a completion, a reader's park, a reading, a pull's or a write's return, a consumer's wait or the fake reaching a state",
    Duration::from_secs(5),
);

/// A bound no test's output reaches.
pub(super) const ROOMY: u64 = 1 << 20;

/// `/bin/sh -c script` in a made-up directory: a command the fake is
/// scripted with.
pub(super) fn command(script: &str) -> Command {
    Command::new("/bin/sh", ["-c", script], "/dir")
}

/// Lines framing for both streams, with `input` and `bound`.
pub(super) const fn lines_with(input: Input, bound: u64) -> Streaming {
    Streaming {
        input,
        out: Framing::Lines,
        err: Framing::Lines,
        bound,
    }
}

/// A service over `fake`, and the ids it completes, in order.
pub(super) fn service(fake: &FakeProcesses) -> (Service<FakeProcesses>, Receiver<u64>) {
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

/// `lines` as frames.
pub(super) fn lines(lines: &[&str]) -> Frames {
    Frames::Lines(lines.iter().map(|line| line.as_bytes().to_vec()).collect())
}

/// Opens `command` as the child `id` and takes the open's reply.
pub(super) fn opened(
    service: &Service<FakeProcesses>,
    completed: &Receiver<u64>,
    id: u64,
    command: Command,
    streaming: Streaming,
) -> Option<StreamReply> {
    assert!(service.open(id, command, streaming));
    assert_eq!(editor_wait::recv(completed, DEADLINE), Ok(id));
    service.take_stream(id)
}

/// [`Service::wait_held`], the readout these tests are of: the one place
/// they call it.
pub(super) fn wait_held(service: &Service<FakeProcesses>, child: u64, guard: HangGuard) -> bool {
    #[expect(
        clippy::disallowed_methods,
        reason = "waits for the child's readers to park on its bound, on `Service::wait_held`, the readout these tests are of"
    )]
    service.wait_held(child, guard)
}

/// Whether the readers of `child` come to be parked on its bound, on the
/// park itself ([`Service::wait_held`]).
pub(super) fn comes_to_be_held(service: &Service<FakeProcesses>, child: u64) -> bool {
    // hang guard: a reader's park on the bound; only a hang reaches the
    // bound, and the check then fails as a hang.
    wait_held(service, child, DEADLINE)
}

/// `count` numbered lines, each `{n:05}` and a line feed.
pub(super) fn numbered(count: usize) -> Vec<u8> {
    (0..count)
        .flat_map(|n| format!("{n:05}\n").into_bytes())
        .collect()
}

/// Flushes `service` and waits for the flush's completion, which must be
/// the next on `completed`; then says whether nothing is pending. A live
/// streaming child is not waited for, but a cancelled or forgotten one is,
/// until it is reaped.
pub(super) fn flushed(service: &Service<FakeProcesses>, completed: &Receiver<u64>) -> bool {
    assert!(service.flush(FLUSH), "the flush's id is free");
    assert_eq!(editor_wait::recv(completed, DEADLINE), Ok(FLUSH));
    service.pending() == 0
}

/// The id of [`flushed`]'s flush: one no test names otherwise.
pub(super) const FLUSH: u64 = u64::MAX;

/// Whether both readers of the child `child` come to let go of its
/// streams. A reader completes a read before it lets go, so after this no
/// reader can complete one.
pub(super) fn readers_done(fake: &FakeProcesses, child: u32) -> bool {
    fake.until(DEADLINE, |record| {
        record.children[&child].outputs_dropped == [true, true]
    })
}
