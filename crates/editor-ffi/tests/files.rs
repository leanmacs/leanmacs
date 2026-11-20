//! The C functions over the process's file service, called the way the C
//! glue calls them, with its completions pulled from the process's
//! completion queue, on real files.
//!
//! This is the one Rust test that runs the real logic (`editor_text::file`)
//! over the real adapter (`editor_fs_std::StdFs`): `editor-ffi` is the
//! crate that links the two, so it is where their wiring is tested. It
//! asserts wiring only: **the bytes that went in are the bytes that came
//! out**, and each request is completed on the queue. It says nothing of
//! what else is in the directory, of a file's mode, or of what the file
//! port was asked: those are `editor-text`'s rules, pinned there on the
//! fake, and the adapter's own, pinned by the port's contract.
//!
//! It is an integration test of its own, and one test function, because the
//! service, the completion queue and the counts of live handles are
//! process-wide.
//!
//! Every file is in a temporary directory the test makes, which is removed
//! when it ends, and every path is passed in explicitly. The fixtures are
//! written and read back with `std::fs`, which the crate's `clippy.toml`
//! refuses everywhere else in this crate: hence the `expect` below.

#![expect(
    clippy::disallowed_methods,
    reason = "the wiring test writes its fixtures into, and reads the saved files back from, a temporary directory it owns; it is the one test of this crate on real files"
)]

use std::mem::MaybeUninit;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::sync::mpsc;
use std::time::Duration;
use std::{slice, thread};

use editor_ffi::document::{
    RawText, editor_ffi_document_free, editor_ffi_document_from_snapshot, editor_ffi_document_live,
    editor_ffi_document_read,
};
use editor_ffi::events::{
    EventKind, QueueId, RawEvent, SourceKind, editor_ffi_events_next, editor_ffi_events_waiting,
};
use editor_ffi::files::{
    FileStatus, RawExpect, RawFileFailure, RawFileResult, SERVICE, editor_ffi_files_append,
    editor_ffi_files_append_unobserved, editor_ffi_files_cancel, editor_ffi_files_failure,
    editor_ffi_files_flush, editor_ffi_files_list, editor_ffi_files_load,
    editor_ffi_files_make_directory, editor_ffi_files_pending, editor_ffi_files_remove,
    editor_ffi_files_remove_unobserved, editor_ffi_files_save, editor_ffi_files_save_unobserved,
    editor_ffi_files_take,
};
use editor_ffi::snapshot::{Snapshot, editor_ffi_snapshot_free, editor_ffi_snapshot_live};
use editor_ffi::text::editor_ffi_text_free;
use editor_text::file::FIXTURES;

/// How long the test waits for something that should happen at once. Only
/// broken code takes this long, and the test then fails instead of hanging.
const DEADLINE: Duration = Duration::from_secs(10);

/// The tag of the completion queue.
const COMPLETION: u8 = QueueId::Completion.tag();

/// A limit no fixture is over.
const NO_LIMIT: u64 = u64::MAX;

/// A save that expects whatever is there.
const WHATEVER: RawExpect = RawExpect {
    tag: 0,
    seconds: 0,
    nanoseconds: 0,
    size: 0,
};

/// A save that expects no file.
const ABSENT: RawExpect = RawExpect {
    tag: 1,
    seconds: 0,
    nanoseconds: 0,
    size: 0,
};

/// What one event of the completion queue says: its source's kind and id,
/// its kind and its code.
type Seen = (Option<SourceKind>, u64, Option<EventKind>, u64);

/// One pull from the completion queue, bounded by the deadline: the pull
/// runs on a detached thread, so one that never returns fails the test
/// instead of hanging it.
fn next_completion() -> Seen {
    let (done, result) = mpsc::channel();
    thread::spawn(move || {
        let mut raw = MaybeUninit::<RawEvent>::uninit();
        // SAFETY: `raw` is writable for one record.
        assert!(unsafe { editor_ffi_events_next(COMPLETION, raw.as_mut_ptr()) });
        // SAFETY: the call returned true, so it filled the record.
        let raw = unsafe { raw.assume_init() };
        // SAFETY: the buffer came from the library in this record, and is
        // handed back once.
        unsafe { editor_ffi_text_free(raw.text, raw.text_len) };
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

/// The completion of the file request `id`, as it should arrive.
fn completion_of(id: u64) -> Seen {
    (
        Some(SourceKind::Library),
        SERVICE,
        Some(EventKind::Completion),
        id,
    )
}

/// The result of a file request, taken and copied out, with its buffers
/// handed back. The snapshot, if there is one, is the caller's to free.
struct Taken {
    /// How the request ended.
    status: u64,
    /// The loaded text, or null.
    snapshot: *mut Snapshot,
    /// The words the status came with.
    words: Vec<u64>,
    /// The detail.
    detail: String,
}

/// Starts a load of `path` as the request `id`.
fn load(id: u64, path: &Path) -> bool {
    let bytes = path.as_os_str().as_bytes();
    // SAFETY: the pointer and length are those of `bytes`, alive for the
    // call.
    unsafe { editor_ffi_files_load(id, bytes.as_ptr(), bytes.len(), NO_LIMIT) }
}

/// Starts making the directory at `path` as the request `id`.
fn make_directory(id: u64, path: &Path) -> bool {
    let bytes = path.as_os_str().as_bytes();
    // SAFETY: the pointer and length are those of `bytes`, alive for the
    // call.
    unsafe { editor_ffi_files_make_directory(id, bytes.as_ptr(), bytes.len()) }
}

/// Starts a listing of `path` as the request `id`.
fn list(id: u64, path: &Path) -> bool {
    let bytes = path.as_os_str().as_bytes();
    // SAFETY: the pointer and length are those of `bytes`, alive for the
    // call.
    unsafe { editor_ffi_files_list(id, bytes.as_ptr(), bytes.len()) }
}

/// Starts a save of `snapshot` to `path` as the request `id`.
///
/// # Safety
///
/// `snapshot` is a live snapshot handle.
unsafe fn save(id: u64, snapshot: *const Snapshot, path: &Path, expect: RawExpect) -> bool {
    let bytes = path.as_os_str().as_bytes();
    // SAFETY: the caller guarantees `snapshot`; the pointer and length are
    // those of `bytes`, and `expect` is readable, for the call.
    unsafe { editor_ffi_files_save(id, snapshot, bytes.as_ptr(), bytes.len(), &raw const expect) }
}

/// Starts adding `bytes` to the end of the file at `path`: as the request
/// `id`, or unobserved with none.
fn append(id: Option<u64>, path: &Path, bytes: &[u8]) -> bool {
    let path = path.as_os_str().as_bytes();
    // SAFETY: the pointers and lengths are those of `path` and `bytes`,
    // alive for the call.
    unsafe {
        match id {
            Some(id) => {
                editor_ffi_files_append(id, path.as_ptr(), path.len(), bytes.as_ptr(), bytes.len())
            }
            None => editor_ffi_files_append_unobserved(
                path.as_ptr(),
                path.len(),
                bytes.as_ptr(),
                bytes.len(),
            ),
        }
    }
}

/// Starts removing the file at `path`: as the request `id`, or unobserved
/// with none.
fn remove(id: Option<u64>, path: &Path) -> bool {
    let path = path.as_os_str().as_bytes();
    // SAFETY: the pointer and length are those of `path`, alive for the
    // call.
    unsafe {
        match id {
            Some(id) => editor_ffi_files_remove(id, path.as_ptr(), path.len()),
            None => editor_ffi_files_remove_unobserved(path.as_ptr(), path.len()),
        }
    }
}

/// The oldest failure of an unobserved request, as its path's bytes and
/// its detail, with its buffers handed back; none when none is kept.
fn failure() -> Option<(Vec<u8>, String)> {
    let mut raw = MaybeUninit::<RawFileFailure>::uninit();
    // SAFETY: `raw` is writable for one record.
    if !unsafe { editor_ffi_files_failure(raw.as_mut_ptr()) } {
        return None;
    }
    // SAFETY: the call returned true, so it filled the record.
    let raw = unsafe { raw.assume_init() };
    // SAFETY: the record's buffers are `path_len` and `detail_len` bytes,
    // owned by this caller until they are handed back, each once.
    unsafe {
        let path = if raw.path_len == 0 {
            Vec::new()
        } else {
            slice::from_raw_parts(raw.path, raw.path_len).to_vec()
        };
        let detail = if raw.detail_len == 0 {
            String::new()
        } else {
            String::from_utf8(slice::from_raw_parts(raw.detail, raw.detail_len).to_vec())
                .expect("the detail is UTF-8")
        };
        editor_ffi_text_free(raw.path, raw.path_len);
        editor_ffi_text_free(raw.detail, raw.detail_len);
        Some((path, detail))
    }
}

/// The result of the request `id`, if the service keeps one.
fn take(id: u64) -> Option<Taken> {
    let mut raw = MaybeUninit::<RawFileResult>::uninit();
    // SAFETY: `raw` is writable for one record.
    if !unsafe { editor_ffi_files_take(id, raw.as_mut_ptr()) } {
        return None;
    }
    // SAFETY: the call returned true, so it filled the record.
    let raw = unsafe { raw.assume_init() };
    // SAFETY: the record's buffers are `words_len` and `detail_len` bytes,
    // owned by this caller until they are handed back, each once.
    let (words, detail) = unsafe {
        let words = if raw.words_len == 0 {
            Vec::new()
        } else {
            let (words, rest) = slice::from_raw_parts(raw.words, raw.words_len).as_chunks::<8>();
            assert!(rest.is_empty(), "the words are whole words");
            words.iter().copied().map(u64::from_le_bytes).collect()
        };
        let detail = if raw.detail_len == 0 {
            String::new()
        } else {
            String::from_utf8(slice::from_raw_parts(raw.detail, raw.detail_len).to_vec())
                .expect("the detail is UTF-8")
        };
        editor_ffi_text_free(raw.words, raw.words_len);
        editor_ffi_text_free(raw.detail, raw.detail_len);
        (words, detail)
    };
    Some(Taken {
        status: raw.status,
        snapshot: raw.snapshot,
        words,
        detail,
    })
}

/// The request `id`, once its completion has been pulled from the queue.
fn completed(id: u64) -> Taken {
    assert_eq!(next_completion(), completion_of(id));
    take(id).unwrap_or_else(|| panic!("the service kept no result for the request {id}"))
}

/// The text of a document made from `snapshot`, which is freed again.
///
/// # Safety
///
/// `snapshot` is a live snapshot handle.
unsafe fn text_of_a_document_from(snapshot: *const Snapshot) -> String {
    // SAFETY: the caller guarantees `snapshot`; the document is this
    // function's own and is freed once; `raw` is writable for one record,
    // whose buffer is handed back once.
    unsafe {
        let document = editor_ffi_document_from_snapshot(snapshot);
        let mut raw = MaybeUninit::<RawText>::uninit();
        editor_ffi_document_read(document, raw.as_mut_ptr());
        let raw = raw.assume_init();
        let text = slice::from_raw_parts(raw.text, raw.text_len).to_vec();
        editor_ffi_text_free(raw.text, raw.text_len);
        editor_ffi_document_free(document);
        String::from_utf8(text).expect("a document's text is UTF-8")
    }
}

/// The whole life of the process's file service, in order.
#[test]
fn files_are_loaded_and_saved_through_c_and_completed_on_the_completion_queue() {
    let directory = tempfile::tempdir().expect("a temporary directory can be made");
    let snapshots = editor_ffi_snapshot_live();
    let documents = editor_ffi_document_live();
    assert_eq!(editor_ffi_files_pending(), 0);
    let mut id = 0;
    let mut next_id = || {
        id += 1;
        id
    };

    for (index, (name, bytes)) in FIXTURES.iter().enumerate() {
        let original = directory.path().join(format!("fixture-{index}.txt"));
        let copy = directory.path().join(format!("copy-{index}.txt"));
        std::fs::write(&original, bytes).expect("the fixture can be written");

        // A load is started, completed on the queue, and its result taken.
        let loading = next_id();
        assert!(load(loading, &original), "{name}");
        let loaded = completed(loading);
        assert_eq!(loaded.status, FileStatus::Done.code(), "{name}");
        assert!(!loaded.snapshot.is_null(), "{name}");
        assert_eq!(editor_ffi_snapshot_live(), snapshots + 1, "{name}");
        // The result is taken once.
        assert!(take(loading).is_none(), "{name}");
        // The stamp the load came with, for a save to expect.
        let unchanged = RawExpect {
            tag: 2,
            seconds: loaded.words[0],
            nanoseconds: loaded.words[1],
            size: loaded.words[2],
        };

        // SAFETY: the snapshot came from the library in the result just
        // taken, and is not used after the call below that frees it.
        unsafe {
            // A document made from what was loaded reads what
            // `editor-text` makes of the fixture's bytes.
            assert_eq!(
                text_of_a_document_from(loaded.snapshot),
                editor_text::Text::from_bytes(bytes).current().to_string(),
                "{name}"
            );

            // Saved to a second path, where no file is.
            let saving = next_id();
            assert!(save(saving, loaded.snapshot, &copy, ABSENT), "{name}");
            assert_eq!(completed(saving).status, FileStatus::Done.code(), "{name}");

            // And saved over the file it came from, with the stamp it was
            // loaded with.
            let saving = next_id();
            assert!(
                save(saving, loaded.snapshot, &original, unchanged),
                "{name}"
            );
            assert_eq!(completed(saving).status, FileStatus::Done.code(), "{name}");

            editor_ffi_snapshot_free(loaded.snapshot);
        }

        // Bytes in, bytes out.
        assert_eq!(
            std::fs::read(&copy).expect("the copy reads"),
            *bytes,
            "{name}"
        );
        assert_eq!(
            std::fs::read(&original).expect("the original reads"),
            *bytes,
            "{name}"
        );
        assert_eq!(editor_ffi_snapshot_live(), snapshots, "{name}");
    }

    // A load of nothing is completed too, with the status for it and no
    // snapshot.
    let nothing = next_id();
    assert!(load(nothing, &directory.path().join("no such file")));
    let refused = completed(nothing);
    assert_eq!(refused.status, FileStatus::NotFound.code());
    assert!(refused.snapshot.is_null());

    // A directory with a file and a directory lists both, with their kinds
    // (0 a file, 1 a directory) and the lengths of their names.
    let listed = directory.path().join("listed");
    std::fs::create_dir_all(listed.join("sub")).expect("the directories can be made");
    std::fs::write(listed.join("a.txt"), b"a").expect("the file can be written");
    let listing = next_id();
    assert!(list(listing, &listed));
    let entries = completed(listing);
    assert_eq!(entries.status, FileStatus::Listed.code());
    assert_eq!(entries.words, [2, 0, 5, 1, 3]);
    assert_eq!(entries.detail, "a.txtsub");
    assert!(entries.snapshot.is_null());

    // A directory two levels below one that is there is made, with the one
    // on the way, and crosses as done with no words.
    let made = directory.path().join("made").join("deep");
    let making = next_id();
    assert!(make_directory(making, &made));
    let answer = completed(making);
    assert_eq!(answer.status, FileStatus::Done.code());
    assert_eq!(answer.words, [0_u64; 0]);
    assert!(made.is_dir());

    // An append where nothing is makes the file, and the next adds to its
    // end; each is done with no words.
    let log = directory.path().join("log");
    for bytes in [&b"one\r\n"[..], b"\xFFtwo\n"] {
        let appending = next_id();
        assert!(append(Some(appending), &log, bytes));
        let answer = completed(appending);
        assert_eq!(answer.status, FileStatus::Done.code());
        assert_eq!(answer.words, [0_u64; 0]);
    }
    assert_eq!(
        std::fs::read(&log).expect("the log reads"),
        b"one\r\n\xFFtwo\n"
    );
    // A remove removes it, and a remove of nothing is done as well.
    for _ in 0..2 {
        let removing = next_id();
        assert!(remove(Some(removing), &log));
        assert_eq!(completed(removing).status, FileStatus::Done.code());
        assert!(!log.exists());
    }
    // An append into a directory that is not there is not found.
    let lost = directory.path().join("no such directory").join("log");
    let appending = next_id();
    assert!(append(Some(appending), &lost, b"x"));
    assert_eq!(completed(appending).status, FileStatus::NotFound.code());

    // Unobserved requests are worked in order with the rest and never
    // completed: an append, a save of a snapshot loaded, and an append
    // that fails, then a stamp, observed, whose completion is the next on
    // the queue and comes once all three were worked.
    let unobserved = directory.path().join("unobserved");
    let session = directory.path().join("session");
    let loading = next_id();
    assert!(load(loading, &directory.path().join("fixture-0.txt")));
    let source = completed(loading);
    assert!(append(None, &unobserved, b"kept\n"));
    // SAFETY: the snapshot came from the library in the result just taken,
    // and is freed once, here, after the call that clones it.
    unsafe {
        let path = session.as_os_str().as_bytes();
        assert!(editor_ffi_files_save_unobserved(
            source.snapshot,
            path.as_ptr(),
            path.len()
        ));
        editor_ffi_snapshot_free(source.snapshot);
    }
    assert!(append(None, &lost, b"lost"));
    assert!(remove(None, &directory.path().join("never there")));
    let marker = next_id();
    assert!(remove(Some(marker), &directory.path().join("never there")));
    assert_eq!(completed(marker).status, FileStatus::Done.code());
    assert_eq!(
        std::fs::read(&unobserved).expect("the unobserved append made the file"),
        b"kept\n"
    );
    assert_eq!(
        std::fs::read(&session).expect("the unobserved save made the file"),
        FIXTURES[0].1
    );
    // A flush asked behind a load and an unobserved append is completed
    // after the load, with the append on disk by then, and keeps no result.
    let flushed = directory.path().join("flushed");
    let loading = next_id();
    assert!(load(loading, &directory.path().join("fixture-0.txt")));
    assert!(append(None, &flushed, b"flushed\n"));
    let flush = next_id();
    assert!(editor_ffi_files_flush(flush));
    let loaded = completed(loading);
    assert_eq!(next_completion(), completion_of(flush));
    assert_eq!(
        std::fs::read(&flushed).expect("the append before the flush made the file"),
        b"flushed\n"
    );
    assert!(take(flush).is_none());
    // SAFETY: the snapshot came from the library in the result just taken,
    // and is freed once, here.
    unsafe { editor_ffi_snapshot_free(loaded.snapshot) };

    // The failure is kept with its path, and taken once.
    let Some((path, detail)) = failure() else {
        panic!("the unobserved append that failed kept no failure");
    };
    assert_eq!(path, lost.as_os_str().as_bytes());
    assert!(!detail.is_empty());
    assert!(failure().is_none());

    // A save that expects nothing a save can expect starts nothing.
    let unknown = RawExpect { tag: 9, ..WHATEVER };
    let another = directory.path().join("fixture-0.txt");
    let asked = next_id();
    assert!(load(asked, &another));
    let held = completed(asked);
    // SAFETY: the snapshot came from the library in the result just taken,
    // and is freed once, below.
    unsafe {
        let refused = next_id();
        assert!(!save(refused, held.snapshot, &another, unknown));
        assert!(take(refused).is_none());
        // An id in use is refused: this one's result has not been taken.
        let kept = next_id();
        assert!(save(kept, held.snapshot, &another, WHATEVER));
        assert_eq!(next_completion(), completion_of(kept));
        assert!(!load(kept, &another));

        // A cancelled request keeps no result, whichever state the cancel
        // found it in.
        assert!(editor_ffi_files_cancel(kept));
        assert!(take(kept).is_none());
        assert!(!editor_ffi_files_cancel(kept));
        editor_ffi_snapshot_free(held.snapshot);
    }

    // Nothing is left: no request, no result, no handle, and no completion
    // that was not pulled. An id the service never saw has nothing to take
    // or to cancel.
    assert!(take(u64::MAX).is_none());
    assert!(!editor_ffi_files_cancel(u64::MAX));
    assert_eq!(editor_ffi_files_pending(), 0);
    assert_eq!(editor_ffi_snapshot_live(), snapshots);
    assert_eq!(editor_ffi_document_live(), documents);
    assert_eq!(editor_ffi_events_waiting(COMPLETION), 0);
}
