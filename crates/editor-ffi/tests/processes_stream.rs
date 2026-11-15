//! The C functions over the process's process service's streaming
//! children, called the way the C glue calls them, with completions pulled
//! from the process's completion queue, on real processes.
//!
//! This is the wiring test of streaming: the C functions, the process's
//! service, the service of `editor-process` and the real adapter. It
//! asserts wiring: a child opened through C streams its lines as it writes
//! them and takes what is written to its input; a read is completed on the
//! real completion queue once however much its child writes; and a
//! cancel of a held child leaves nothing pending. The rules are
//! `editor-process`'s, pinned there on the fake and by the contract.
//!
//! It is a test binary of its own, with one test function, because the
//! service and the completion queue are process-wide. Every child runs in a
//! temporary directory the test makes and removes, and writes nothing
//! there. The check that no further completion arrives pulls the queue on
//! a detached thread bounded by a short deadline; that thread may wait on
//! past the test, so it comes last.

#[path = "common/processes.rs"]
mod common;
#[path = "common/open.rs"]
mod open;

use std::mem::MaybeUninit;
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use common::{DEADLINE, completion_of, next_completion};
use editor_ffi::events::{QueueId, RawEvent, editor_ffi_events_next};
use editor_ffi::processes::{
    RawStreamReply, editor_ffi_processes_cancel, editor_ffi_processes_close_input,
    editor_ffi_processes_pending, editor_ffi_processes_read, editor_ffi_processes_take_stream,
    editor_ffi_processes_write,
};
use editor_ffi::text::editor_ffi_text_free;
use open::{comes_to_be_held, open};

/// A reply taken through C: its status, its words and its standard output
/// and error, the buffers handed back.
#[derive(Debug, PartialEq, Eq)]
struct Reply {
    /// The status.
    status: u64,
    /// The words.
    words: Vec<u64>,
    /// The standard output's bytes, end to end.
    out: Vec<u8>,
    /// The standard error's bytes, end to end.
    err: Vec<u8>,
}

impl Reply {
    /// The lines of standard output, as its words count them.
    fn out_lines(&self) -> Vec<Vec<u8>> {
        assert_eq!(self.words[0], 0, "lines framing");
        let count = usize::try_from(self.words[1]).expect("a count");
        let mut at = 0;
        self.words[2..2 + count]
            .iter()
            .map(|&len| {
                let len = usize::try_from(len).expect("a length");
                let line = self.out[at..at + len].to_vec();
                at += len;
                line
            })
            .collect()
    }

    /// The last words: how the child ended, `[0]` for not yet.
    fn end(&self) -> &[u64] {
        let out = usize::try_from(self.words[1]).expect("a count");
        let err = usize::try_from(self.words[3 + out]).expect("a count");
        &self.words[4 + out + err..]
    }
}

/// The `len` bytes at `bytes`, copied, and the buffer handed back.
///
/// # Safety
///
/// The buffer was lent by the library with that length.
unsafe fn copied(bytes: *mut u8, len: usize) -> Vec<u8> {
    // SAFETY: the caller guarantees the buffer.
    unsafe {
        let copy = if len == 0 {
            Vec::new()
        } else {
            std::slice::from_raw_parts(bytes, len).to_vec()
        };
        editor_ffi_text_free(bytes, len);
        copy
    }
}

/// The reply of the wait `wait`, once it has been completed.
fn take(wait: u64) -> Option<Reply> {
    let mut raw = MaybeUninit::<RawStreamReply>::uninit();
    // SAFETY: `raw` is writable for one record.
    if !unsafe { editor_ffi_processes_take_stream(wait, raw.as_mut_ptr()) } {
        return None;
    }
    // SAFETY: the call returned true, so it filled the record.
    let raw = unsafe { raw.assume_init() };
    // SAFETY: each buffer is this caller's, handed back once.
    let (words, _, out, err) = unsafe {
        (
            copied(raw.words, raw.words_len),
            copied(raw.detail, raw.detail_len),
            copied(raw.stdout, raw.stdout_len),
            copied(raw.stderr, raw.stderr_len),
        )
    };
    let (words, rest) = words.as_chunks::<8>();
    assert!(rest.is_empty());
    Some(Reply {
        status: raw.status,
        words: words.iter().copied().map(u64::from_le_bytes).collect(),
        out,
        err,
    })
}

/// Waits for the completion of `wait` and takes its reply.
fn completed(wait: u64) -> Reply {
    assert_eq!(next_completion(), completion_of(wait));
    take(wait).expect("a reply")
}

/// Whether `pending` comes to `count` within the deadline.
fn pending_comes_to(count: u64) -> bool {
    let end = Instant::now() + DEADLINE;
    while Instant::now() < end {
        if editor_ffi_processes_pending() == count {
            return true;
        }
        thread::yield_now();
    }
    false
}

/// `count` numbered lines, as `sh`'s loop writes them.
fn counted(count: usize) -> Vec<u8> {
    (0..count)
        .flat_map(|n| format!("{n}\n").into_bytes())
        .collect()
}

#[test]
fn a_streaming_child_is_read_written_closed_and_cancelled_through_c_one_completion_per_read() {
    let directory = tempfile::tempdir().expect("a temporary directory can be made");
    let dir = directory.path();
    let before = editor_ffi_processes_pending();

    // Lines as the child writes them, and a line written to its input.
    let script = r#"echo one; read x; echo "$x"; echo err >&2; read y; exit 4"#;
    assert!(open(1, script, dir, true, 1 << 20));
    assert_eq!(completed(1).status, 10, "opened");
    assert!(editor_ffi_processes_read(1, 2));
    let first = completed(2);
    assert_eq!(first.out_lines(), [b"one".to_vec()]);
    assert_eq!(first.end(), [0]);
    // SAFETY: the pointer and length are the slice's.
    assert!(unsafe { editor_ffi_processes_write(1, 3, b"two\n".as_ptr(), 4) });
    assert_eq!(completed(3).status, 12, "written");
    let mut out = Vec::new();
    let mut err = Vec::new();
    let mut wait = 4;
    while !(out.ends_with(b"two") && err.ends_with(b"err")) {
        assert!(editor_ffi_processes_read(1, wait));
        let reply = completed(wait);
        out.extend(reply.out);
        err.extend(reply.err);
        wait += 1;
    }
    assert!(editor_ffi_processes_close_input(1, wait));
    assert_eq!(completed(wait).status, 12);
    let end = loop {
        wait += 1;
        assert!(editor_ffi_processes_read(1, wait));
        let reply = completed(wait);
        if reply.end() != [0] {
            break reply.end().to_vec();
        }
    };
    assert_eq!(end, [1, 0, 4], "exited with a status of 4");

    // A held child, cancelled, leaves nothing pending.
    assert!(open(20, "while :; do echo y; done", dir, false, 64));
    assert_eq!(completed(20).status, 10);
    assert!(comes_to_be_held(20, DEADLINE));
    assert!(editor_ffi_processes_cancel(20));
    assert!(pending_comes_to(before), "the cancelled child is reaped");

    // One completion for a read however much its child writes, on the real
    // queue. The bound is all the child writes, so it is held once every
    // line has been read while the read was pending.
    let lines = counted(10_000);
    let script = "i=0; while [ $i -lt 10000 ]; do echo $i; i=$((i+1)); done; read x";
    assert!(open(30, script, dir, true, lines.len() as u64));
    assert_eq!(completed(30).status, 10);
    assert!(editor_ffi_processes_read(30, 31));
    assert!(comes_to_be_held(30, DEADLINE));
    assert_eq!(next_completion(), completion_of(31));
    let (sender, pulled) = mpsc::channel();
    thread::spawn(move || {
        let mut raw = MaybeUninit::<RawEvent>::uninit();
        // SAFETY: `raw` is writable for one record.
        let got = unsafe { editor_ffi_events_next(QueueId::Completion.tag(), raw.as_mut_ptr()) };
        sender.send(got).ok();
    });
    assert!(
        pulled.recv_timeout(Duration::from_millis(200)).is_err(),
        "no further completion"
    );
    let reply = take(31).expect("the delivery");
    assert_eq!(reply.out_lines().len(), 10_000);
    let mut whole = Vec::new();
    for line in reply.out_lines() {
        whole.extend(line);
        whole.push(b'\n');
    }
    assert_eq!(whole, lines);
    assert!(editor_ffi_processes_cancel(30));
    assert!(pending_comes_to(before));
}
