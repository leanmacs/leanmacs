//! The process's process service as `editor-service`'s stream source, on
//! real processes: what a package's crate reaches through
//! `editor_service::stream::take_over` once the library has started
//! (`editor_ffi_library_start`, which the entry point calls before Lean
//! runs).
//!
//! This is the wiring test of the hand-off: the C function that provides
//! the source, the process's one service, `editor-process`'s hand-off and
//! the real adapter. It asserts wiring: once the library has started a
//! take-over is answered by the service, not refused as no service; a
//! child opened through the C function is taken over, read and written to
//! and its exit seen; and the job's read of it is then refused. The rules
//! are `editor-process`'s and `editor-service`'s, pinned there on the fakes
//! and by the stream contract on real processes.
//!
//! It is a test binary of its own, with one test function, because the
//! source, the service and the completion queue are process-wide. Every
//! child runs in a temporary directory the test makes and removes, and
//! writes nothing there.

#[path = "common/processes.rs"]
mod common;
#[path = "common/open.rs"]
#[expect(
    dead_code,
    reason = "this test opens a child and never waits for one to be held, which the module's other half is for"
)]
mod open;

use std::mem::MaybeUninit;

use common::{completion_of, flushed, next_completion};
use editor_ffi::processes::{
    RawStreamReply, editor_ffi_library_start, editor_ffi_processes_pending,
    editor_ffi_processes_read, editor_ffi_processes_take_stream,
};
use editor_ffi::text::editor_ffi_text_free;
use editor_service::frame::Frames;
use editor_service::stream::{self, Ended, Pulled, Refused};
use open::open;

/// The status of the reply to the wait `wait`, once it is completed, its
/// buffers handed back.
fn completed_status(wait: u64) -> u64 {
    assert_eq!(next_completion(), completion_of(wait));
    let mut raw = MaybeUninit::<RawStreamReply>::uninit();
    // SAFETY: `raw` is writable for one record.
    assert!(unsafe { editor_ffi_processes_take_stream(wait, raw.as_mut_ptr()) });
    // SAFETY: the call returned true, so it filled the record.
    let raw = unsafe { raw.assume_init() };
    // SAFETY: each buffer is this caller's, handed back once.
    unsafe {
        editor_ffi_text_free(raw.words, raw.words_len);
        editor_ffi_text_free(raw.detail, raw.detail_len);
        editor_ffi_text_free(raw.stdout, raw.stdout_len);
        editor_ffi_text_free(raw.stderr, raw.stderr_len);
    }
    raw.status
}

#[test]
fn a_child_opened_through_c_is_taken_over_read_and_written_once_the_library_has_started() {
    let directory = tempfile::tempdir().expect("a temporary directory can be made");
    let before = editor_ffi_processes_pending();

    editor_ffi_library_start();
    editor_ffi_library_start();
    let unknown = stream::take_over(u64::MAX - 7).err();

    let script = r#"echo one; echo ping-me; read x; echo "got $x"; echo three; exit 2"#;
    assert!(open(1, script, directory.path(), true, 4 << 20));
    assert_eq!(completed_status(1), 10, "opened");
    let streams = stream::take_over(1).expect("taken over");
    let job_read = editor_ffi_processes_read(1, 2);

    let mut lines = Vec::new();
    let ended = loop {
        let Pulled::Delivered(delivery) = streams.pull() else {
            panic!("a delivery, not a cancel");
        };
        let Frames::Lines(out) = delivery.out else {
            panic!("lines");
        };
        for line in out {
            if line == b"ping-me" {
                assert_eq!(streams.write(b"pong\n".to_vec()), Ok(()));
            }
            lines.push(String::from_utf8(line).expect("UTF-8"));
        }
        if let Some(ended) = delivery.ended {
            break ended;
        }
    };
    let again = stream::take_over(1).err();

    assert_eq!(
        unknown,
        Some(Refused::NoSuchChild),
        "the service answers, not no service"
    );
    assert!(!job_read, "the job reads a child taken over no more");
    assert_eq!(lines, ["one", "ping-me", "got pong", "three"]);
    assert_eq!(ended, Ended::Exited { code: 2 });
    assert_eq!(again, Some(Refused::NoSuchChild), "forgotten");
    flushed(3);
    assert_eq!(editor_ffi_processes_pending(), before, "reaped");
}
