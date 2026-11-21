//! What the wiring tests of the watch service share: a start and a read
//! asked for through the C functions, a reply taken through them, a pull
//! from the completion queue bounded by a deadline, and the one write of a
//! file of the test's own temporary directory.

// Each test binary uses its own part of this module.
#![allow(dead_code)]

use std::mem::MaybeUninit;
use std::path::Path;
use std::sync::mpsc;
use std::time::Duration;
use std::{slice, thread};

use editor_ffi::events::{EventKind, QueueId, RawEvent, SourceKind, editor_ffi_events_next};
use editor_ffi::text::editor_ffi_text_free;
use editor_ffi::watches::{
    RawWatchReply, SERVICE, editor_ffi_watches_next, editor_ffi_watches_start,
    editor_ffi_watches_take,
};

/// hang guard: the next completion or event; only a hang reaches the bound, and the test then fails as a hang.
/// Each wait on it is for something that should happen at once.
pub const DEADLINE: Duration = Duration::from_secs(10);

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

/// The completion of the wait `id`, as it should arrive.
pub fn completion_of(id: u64) -> Seen {
    (
        Some(SourceKind::Library),
        SERVICE,
        Some(EventKind::Completion),
        id,
    )
}

/// Starts the watch `id` on `path`, a file (target 0), a directory's
/// entries (1) or its tree (2), through the C function, laying the start
/// out as Lean does.
pub fn start(id: u64, target: u64, window_ms: u64, bound: u64, path: &Path) -> bool {
    let path = path
        .to_str()
        .expect("the temporary directory's path is UTF-8");
    let words: Vec<u8> = [target, window_ms, bound]
        .iter()
        .flat_map(|word| word.to_le_bytes())
        .collect();
    // SAFETY: the pointers and lengths are those of `words` and `path`,
    // alive for the call.
    unsafe { editor_ffi_watches_start(id, words.as_ptr(), words.len(), path.as_ptr(), path.len()) }
}

/// Asks for the next delivery of `watch` under `wait`.
pub fn next(watch: u64, wait: u64) -> bool {
    editor_ffi_watches_next(watch, wait)
}

/// A reply, taken and copied out, with its buffers handed back.
#[derive(Debug, PartialEq, Eq)]
pub struct Taken {
    /// What the reply is.
    pub status: u64,
    /// The words the status came with.
    pub words: Vec<u64>,
    /// The detail.
    pub detail: String,
    /// The paths, end to end.
    pub paths: Vec<u8>,
}

impl Taken {
    /// Each change's path and kinds' bits.
    pub fn changes(&self) -> Vec<(Vec<u8>, u64)> {
        let mut changes = Vec::new();
        let mut at = 0;
        for pair in self.words[1..].chunks(2) {
            let len = usize::try_from(pair[0]).expect("a length");
            changes.push((self.paths[at..at + len].to_vec(), pair[1]));
            at += len;
        }
        changes
    }
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

/// The reply of the wait `id`, if the service keeps one.
pub fn take(id: u64) -> Option<Taken> {
    let mut raw = MaybeUninit::<RawWatchReply>::uninit();
    // SAFETY: `raw` is writable for one record.
    if !unsafe { editor_ffi_watches_take(id, raw.as_mut_ptr()) } {
        return None;
    }
    // SAFETY: the call returned true, so it filled the record.
    let raw = unsafe { raw.assume_init() };
    // SAFETY: each buffer came from the library in this record, with its
    // length, and is handed back once.
    let (words, detail, paths) = unsafe {
        (
            copied(raw.words, raw.words_len),
            copied(raw.detail, raw.detail_len),
            copied(raw.paths, raw.paths_len),
        )
    };
    Some(Taken {
        status: raw.status,
        words: words
            .as_chunks::<8>()
            .0
            .iter()
            .map(|word| u64::from_le_bytes(*word))
            .collect(),
        detail: String::from_utf8(detail).expect("the detail is UTF-8"),
        paths,
    })
}

/// Writes `bytes` to the file at `path`, in the test's own temporary
/// directory.
#[expect(
    clippy::disallowed_methods,
    reason = "the wiring test writes files of a temporary directory it owns; it writes no other file"
)]
pub fn write(path: &Path, bytes: &[u8]) {
    std::fs::write(path, bytes).expect("the test's file is written");
}
