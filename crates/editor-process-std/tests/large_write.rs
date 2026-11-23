//! A write larger than a pipe holds reaches a real child whole and in
//! order: the service writes it to `/bin/cat`, and reads all of it back.
//!
//! A blocking write to a pipe is taken whole by the kernel, so here the
//! service's loop over partial writes runs once: with it resending from the
//! start, or keeping a wrong offset, this test still passes (seen by hand
//! on 2026-11-15). That loop is pinned on the fake, whose input pipe takes
//! a few bytes a write (`editor-process`'s service test
//! `a_write_many_times_the_input_pipe_arrives_whole_and_in_order`).
//!
//! The child runs in a temporary directory the test makes and removes, and
//! the service is shut down before the test returns, even when it fails,
//! which kills and reaps the child.

use std::sync::mpsc::{self, Receiver};
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

use editor_wait::HangGuard;

use editor_process::frame::{Frames, Framing};
use editor_process::service::{Delivery, End, Service, StreamReply, Streaming};
use editor_process::{Command, Exit, Input};
use editor_process_std::StdProcesses;

/// hang guard: each reply the test waits for, which must come; only a hang
/// reaches the bound, and the check then fails as a hang.
const DEADLINE: HangGuard = HangGuard::on("each reply the test waits for", Duration::from_secs(10));

/// What the test writes: 256 KiB, four times the 64 KiB a pipe holds on
/// Linux and the most macOS grows one to. No run of it repeats within 251
/// bytes, so a resend or a wrong offset shows.
fn written() -> Vec<u8> {
    (0..256 * 1024_u32)
        .map(|at| u8::try_from(at % 251).expect("under 251"))
        .collect()
}

/// Shuts its service down when dropped, so a failing test leaves nothing
/// running.
struct ShutAtDrop<'a>(&'a Service<StdProcesses>);

impl Drop for ShutAtDrop<'_> {
    fn drop(&mut self) {
        self.0.shutdown();
    }
}

/// Asks for `ask` as the wait `wait`, and takes its reply once it is
/// completed.
fn replied(
    service: &Service<StdProcesses>,
    completed: &Receiver<u64>,
    wait: u64,
    ask: impl FnOnce() -> bool,
) -> Option<StreamReply> {
    assert!(ask(), "the request is taken");
    assert_eq!(editor_wait::recv(completed, DEADLINE), Ok(wait));
    service.take_stream(wait)
}

#[test]
fn a_write_four_times_a_pipe_reaches_cat_whole_and_comes_back_in_order() {
    let directory = tempfile::tempdir().expect("a temporary directory can be made");
    let (sender, completed) = mpsc::channel();
    let sender = Mutex::new(sender);
    let service = Service::new(StdProcesses::system(), move |id| {
        sender
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .send(id)
            .ok();
    });
    let shut = ShutAtDrop(&service);
    let streaming = Streaming {
        input: Input::Pipe,
        out: Framing::Bytes,
        err: Framing::Bytes,
        bound: 1 << 20,
    };
    let bytes = written();

    let opened = replied(&service, &completed, 1, || {
        service.open(
            1,
            Command::new("/bin/cat", [""; 0], directory.path()),
            streaming,
        )
    });
    let wrote = replied(&service, &completed, 2, || {
        service.write(1, 2, bytes.clone())
    });
    let closed = replied(&service, &completed, 3, || service.close_input(1, 3));
    let mut all = Vec::new();
    let mut ended = None;
    for wait in 4.. {
        let Some(StreamReply::Delivered(delivery)) =
            replied(&service, &completed, wait, || service.read(1, wait))
        else {
            panic!("a delivery");
        };
        let Delivery {
            out, ended: end, ..
        } = delivery;
        if let Frames::Bytes(out) = out {
            all.extend_from_slice(&out);
        }
        if end.is_some() {
            ended = end;
            break;
        }
    }
    drop(shut);

    assert_eq!(opened, Some(StreamReply::Opened));
    assert_eq!(wrote, Some(StreamReply::Written));
    assert_eq!(closed, Some(StreamReply::Written));
    assert!(
        all == bytes,
        "cat gave back {} bytes, not the {} written, in order",
        all.len(),
        bytes.len()
    );
    assert_eq!(ended, Some(End::Exited(Exit::Code(0))));
}
