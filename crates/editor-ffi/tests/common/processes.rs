//! What the wiring tests of the process service share: a run asked for
//! through the C function, a result taken through it, and a pull from the
//! completion queue bounded by a deadline.

// Each test binary uses its own part of this module: the streaming test
// pulls the queue and takes no run's result.
#![allow(dead_code)]

use std::mem::MaybeUninit;
use std::path::Path;
use std::sync::mpsc;
use std::time::Duration;
use std::{slice, thread};

use editor_ffi::events::{EventKind, QueueId, RawEvent, SourceKind, editor_ffi_events_next};
use editor_ffi::processes::{
    RawProcessResult, SERVICE, editor_ffi_processes_run, editor_ffi_processes_run_input,
    editor_ffi_processes_take,
};
use editor_ffi::text::editor_ffi_text_free;

/// How long a test waits for something that should happen at once. Only
/// broken code takes this long, and the test then fails instead of hanging.
pub const DEADLINE: Duration = Duration::from_secs(10);

/// A limit no output of the tests is over.
pub const ROOMY: u64 = 1 << 20;

/// What one event of the completion queue says: its source's kind and id,
/// its kind and its code.
pub type Seen = (Option<SourceKind>, u64, Option<EventKind>, u64);

/// One pull from the completion queue, bounded by the deadline: the pull
/// runs on a detached thread, so one that never returns fails the test
/// instead of hanging it.
pub fn next_completion() -> Seen {
    let (done, result) = mpsc::channel();
    thread::spawn(move || {
        let mut raw = MaybeUninit::<RawEvent>::uninit();
        // SAFETY: `raw` is writable for one record.
        assert!(unsafe { editor_ffi_events_next(QueueId::Completion.tag(), raw.as_mut_ptr()) });
        // SAFETY: the call returned true, so it filled the record.
        let raw = unsafe { raw.assume_init() };
        // SAFETY: the buffers came from the library in this record, and are
        // handed back once.
        unsafe {
            editor_ffi_text_free(raw.text, raw.text_len);
            editor_ffi_text_free(raw.words, raw.words_len);
        }
        let _ = done.send((
            SourceKind::from_tag(raw.source_kind),
            raw.source_id,
            EventKind::from_tag(raw.kind),
            raw.code,
        ));
    });
    result
        .recv_timeout(DEADLINE)
        .unwrap_or_else(|_| panic!("no event reached the completion queue within {DEADLINE:?}"))
}

/// The completion of the run `id`, as it should arrive.
pub fn completion_of(id: u64) -> Seen {
    (
        Some(SourceKind::Library),
        SERVICE,
        Some(EventKind::Completion),
        id,
    )
}

/// The words and the string of `program` with `arguments` in `directory`,
/// with `limit`, laid out as Lean lays a command out.
fn laid_out(program: &str, arguments: &[&str], directory: &Path, limit: u64) -> (Vec<u8>, String) {
    let directory = directory
        .to_str()
        .expect("the temporary directory's path is UTF-8");
    let mut words = vec![limit, 0, arguments.len() as u64];
    words.extend(arguments.iter().map(|text| text.len() as u64));
    // No variable set and none unset.
    words.extend([0, 0, program.len() as u64, directory.len() as u64]);
    let words: Vec<u8> = words.iter().flat_map(|word| word.to_le_bytes()).collect();
    let strings = format!("{}{program}{directory}", arguments.concat());
    (words, strings)
}

/// Starts `/bin/sh -c script` in `directory` as the run `id`, through the
/// C function, laying the command out as Lean does.
pub fn run(id: u64, script: &str, directory: &Path, limit: u64) -> bool {
    let (words, strings) = laid_out("/bin/sh", &["-c", script], directory, limit);
    // SAFETY: the pointers and lengths are those of `words` and `strings`,
    // alive for the call.
    unsafe {
        editor_ffi_processes_run(
            id,
            words.as_ptr(),
            words.len(),
            strings.as_ptr(),
            strings.len(),
        )
    }
}

/// Starts `program`, with no arguments, in `directory` as the run `id`, fed
/// `input`, through the C function, laying the command out as Lean does.
pub fn run_input(id: u64, program: &str, directory: &Path, input: &[u8], limit: u64) -> bool {
    let (words, strings) = laid_out(program, &[], directory, limit);
    // SAFETY: the pointers and lengths are those of `words`, `strings` and
    // `input`, alive for the call.
    unsafe {
        editor_ffi_processes_run_input(
            id,
            words.as_ptr(),
            words.len(),
            strings.as_ptr(),
            strings.len(),
            input.as_ptr(),
            input.len(),
        )
    }
}

/// A run's result, taken and copied out, with its buffers handed back.
#[derive(Debug, PartialEq, Eq)]
pub struct Taken {
    /// How the run ended.
    pub status: u64,
    /// The words the status came with.
    pub words: Vec<u64>,
    /// The detail.
    pub detail: String,
    /// The standard output.
    pub stdout: Vec<u8>,
    /// The standard error.
    pub stderr: Vec<u8>,
}

/// The `len` bytes at `bytes`, copied, and the buffer handed back.
///
/// # Safety
///
/// The buffer was lent by the library with that length, and is not used
/// again.
unsafe fn copied(bytes: *mut u8, len: usize) -> Vec<u8> {
    // SAFETY: the caller guarantees the buffer.
    unsafe {
        let copy = if len == 0 {
            Vec::new()
        } else {
            slice::from_raw_parts(bytes, len).to_vec()
        };
        editor_ffi_text_free(bytes, len);
        copy
    }
}

/// The result of the run `id`, if the service keeps one.
pub fn take(id: u64) -> Option<Taken> {
    let mut raw = MaybeUninit::<RawProcessResult>::uninit();
    // SAFETY: `raw` is writable for one record.
    if !unsafe { editor_ffi_processes_take(id, raw.as_mut_ptr()) } {
        return None;
    }
    // SAFETY: the call returned true, so it filled the record.
    let raw = unsafe { raw.assume_init() };
    // SAFETY: the record's buffers are this caller's until they are handed
    // back, each once.
    let (words, detail, stdout, stderr) = unsafe {
        (
            copied(raw.words, raw.words_len),
            copied(raw.detail, raw.detail_len),
            copied(raw.stdout, raw.stdout_len),
            copied(raw.stderr, raw.stderr_len),
        )
    };
    let (words, rest) = words.as_chunks::<8>();
    assert!(rest.is_empty(), "the words are whole words");
    Some(Taken {
        status: raw.status,
        words: words.iter().copied().map(u64::from_le_bytes).collect(),
        detail: String::from_utf8(detail).expect("the detail is UTF-8"),
        stdout,
        stderr,
    })
}
