//! The file service: loads and saves, completed through the completion
//! queue.
//!
//! This is the second service behind the completion queue, in the timer
//! service's shape (the crate docs, "Services and completions"). A job in
//! Lean asks for a load or a save with an id. [`Files::start_load`] and
//! [`Files::start_save`] return at once; the service's thread does the
//! work, keeps the result under the request's id and completes the
//! request: for the process's instance, by queueing an
//! [`EventKind::Completion`](crate::events::EventKind::Completion) whose
//! code is the id. The caller then takes the result ([`Files::take`]),
//! once. Rust never calls Lean.
//!
//! What a load and a save do (what is refused, what is checked, what is
//! kept, in what order the file system is asked) is `editor-text`'s
//! ([`editor_text::file`]), pinned there on the file port's fake. This
//! module decides only what a *service* decides, and its tests assert only
//! that: which request is worked when, what cancelling means, that a
//! request's arguments reach the logic, and how a result crosses.
//!
//! The pieces:
//!
//! - [`Requests`] is the requests not yet worked, in the order they were
//!   started. It is pure, as the timers' `Schedule` is.
//! - [`Files`] is the service over a file system, the port
//!   [`editor_text::fs::Fs`]. Its loop, [`Files::run`], takes the oldest
//!   request, works it with no lock held, keeps the result and completes
//!   the request through a closure it is given.
//! - [`FileResult`] is what a request came to, and [`FileResult::encoded`]
//!   how it crosses: a status, words and a detail string.
//!
//! The rules:
//!
//! - **One thread, in order.** Two saves of one file land in the order
//!   they were asked for, which a thread for each request could not
//!   promise. The cost is that a load stuck on a slow file system holds up
//!   the requests behind it.
//! - **Which thread does the I/O**: the service's, and no other. A start
//!   never touches the file system.
//! - **An id in use is refused**: one that is waiting, being worked, or
//!   whose result has not been taken.
//! - **Cancelling.** A request still waiting is never worked and never
//!   completed. One being worked has a flag set, which a save reads before
//!   it replaces the file: the file is then not replaced. Its result is
//!   dropped and it is not completed. A read cannot be interrupted; its
//!   result is dropped too. A result already kept is dropped. So a
//!   cancelled save has either replaced the file whole or not touched it,
//!   and a completion that was queued before the cancel still arrives
//!   after it.
//! - **A loaded text is kept as a snapshot**, which is `Send + Sync`. The
//!   handle Lean gets is made when the result is taken
//!   ([`editor_ffi_files_take`]), and is counted live from then: a result
//!   that is cancelled, or never taken, was never a handle.
//!
//! The process has one instance, over the machine's file system
//! (`editor_fs_std::StdFs`), a `const`-initialised static like the timers'.
//! That static is the one place in this crate's sources that makes the
//! real file system: the crate's `clippy.toml` refuses its constructor
//! everywhere else, so the unit tests below run on the fake and make no
//! file. Its thread, `editor-files`, starts with the first request.
//!
//! # How a result crosses
//!
//! [`editor_ffi_files_take`] fills a [`RawFileResult`]: a status, a
//! snapshot handle that is non-null only for a load that succeeded, words
//! (64-bit numbers, each as eight bytes, least significant first, as the
//! private module `words` has them) and a detail string.
//!
//! | Result | Status | Words |
//! |---|---|---|
//! | Loaded | 0 | seconds, nanoseconds, size, lone line feeds, CRLF pairs |
//! | Saved | 0 | seconds, nanoseconds, size |
//! | The path is not absolute | 1 | |
//! | Not found | 2 | |
//! | Not a file | 3 | |
//! | Denied | 4 | (none; the detail is the platform's words) |
//! | Binary | 5 | the offset of the first NUL byte |
//! | Too large | 6 | size, limit |
//! | Changed | 7 | present (0 or 1), seconds, nanoseconds, size |
//! | No temporary name | 8 | |
//! | Failed | 9 | (none; the detail says what failed) |
//!
//! The seconds of a stamp cross as a 64-bit two's complement word, so an
//! instant before 1970 is a word above 2^63. A path crosses as its bytes
//! and a length and becomes a path with no decoding.
//!
//! # The C functions
//!
//! | Function | Does |
//! |---|---|
//! | [`editor_ffi_files_load`] | Starts a load. False, starting nothing, for an id in use, or when the service has no thread |
//! | [`editor_ffi_files_save`] | Starts a save of the snapshot behind a handle, which it clones. What it expects on disk is a [`RawExpect`] |
//! | [`editor_ffi_files_take`] | Fills a [`RawFileResult`] and returns true, or returns false when the service keeps no result for the id |
//! | [`editor_ffi_files_cancel`] | Cancels, and says whether there was anything to cancel |
//! | [`editor_ffi_files_pending`] | Requests waiting or being worked, and results not taken |

use std::collections::{BTreeMap, VecDeque};
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, PoisonError};
use std::{ptr, slice, thread};

use editor_fs_std::StdFs;
use editor_text::file::{self, Expect, LineEndings, LoadError, Loaded, SaveError, Stamp};
use editor_text::fs::{Fs, FsError, FsErrorKind, Modified};

use crate::snapshot::Snapshot;
use crate::words::{self, Writer};
use crate::{events, text};

/// The requests that are not yet worked, each an id and what is asked, in
/// the order they were started.
#[derive(Debug)]
pub struct Requests<T> {
    /// The requests, oldest first.
    waiting: VecDeque<(u64, T)>,
}

impl<T> Default for Requests<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T> Requests<T> {
    /// No requests.
    pub const fn new() -> Self {
        Self {
            waiting: VecDeque::new(),
        }
    }

    /// Adds the request `id`, behind those already waiting, and returns
    /// whether it was added. An id that is already waiting is refused, and
    /// the request it names is as it was.
    pub fn start(&mut self, id: u64, request: T) -> bool {
        if self.holds(id) {
            return false;
        }
        self.waiting.push_back((id, request));
        true
    }

    /// Removes the request `id`, and returns whether it was waiting.
    pub fn cancel(&mut self, id: u64) -> bool {
        let before = self.waiting.len();
        self.waiting.retain(|(waiting, _)| *waiting != id);
        self.waiting.len() != before
    }

    /// Removes and returns the request that has waited longest, if any is
    /// waiting.
    pub fn take_next(&mut self) -> Option<(u64, T)> {
        self.waiting.pop_front()
    }

    /// Whether the request `id` is waiting.
    pub fn holds(&self, id: u64) -> bool {
        self.waiting.iter().any(|(waiting, _)| *waiting == id)
    }

    /// How many requests are waiting.
    pub fn pending(&self) -> usize {
        self.waiting.len()
    }
}

/// What is asked of the file service.
pub enum Request {
    /// Load the file at `path`, unless it is longer than `limit` bytes.
    Load {
        /// Where the file is.
        path: PathBuf,
        /// The longest file to load, in bytes.
        limit: u64,
    },
    /// Save what `snapshot` holds as the file at `path`, if what is there
    /// is what `expect` says.
    Save {
        /// What to save.
        snapshot: editor_text::Snapshot,
        /// Where to save it.
        path: PathBuf,
        /// What the save expects to find there.
        expect: Expect,
    },
}

/// What a request came to.
pub enum FileResult {
    /// A file was loaded.
    Loaded {
        /// The file's text.
        snapshot: editor_text::Snapshot,
        /// What a save is to expect on disk if the file has not changed.
        stamp: Stamp,
        /// The file's line endings.
        endings: LineEndings,
    },
    /// A file was saved, and has this stamp.
    Saved(Stamp),
    /// A load was refused.
    NotLoaded(LoadError),
    /// A save was refused.
    NotSaved(SaveError),
}

impl From<Result<Loaded, LoadError>> for FileResult {
    fn from(loaded: Result<Loaded, LoadError>) -> Self {
        match loaded {
            Ok(loaded) => Self::Loaded {
                snapshot: loaded.text.snapshot(),
                stamp: loaded.stamp,
                endings: loaded.endings,
            },
            Err(error) => Self::NotLoaded(error),
        }
    }
}

impl From<Result<Stamp, SaveError>> for FileResult {
    fn from(saved: Result<Stamp, SaveError>) -> Self {
        match saved {
            Ok(stamp) => Self::Saved(stamp),
            Err(error) => Self::NotSaved(error),
        }
    }
}

/// How a request ended, as the number that crosses the boundary. The
/// module docs have the table.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileStatus {
    /// The file was loaded or saved.
    Done = 0,
    /// The path is not absolute.
    Relative = 1,
    /// Nothing is at the path, or at a directory on the way to it.
    NotFound = 2,
    /// What is at the path is not a file.
    NotAFile = 3,
    /// The file system does not allow it.
    Denied = 4,
    /// The file is binary.
    Binary = 5,
    /// The file is longer than the limit.
    TooLarge = 6,
    /// The file on disk is not the one the save expected.
    Changed = 7,
    /// No name was free for the save's temporary file.
    NoTemporaryName = 8,
    /// Anything else. The detail says what.
    Failed = 9,
}

impl FileStatus {
    /// The number that stands for this status across the boundary.
    pub const fn code(self) -> u64 {
        self as u64
    }
}

/// A result as it crosses the boundary, but for the snapshot of a load.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Encoded {
    /// How the request ended.
    pub status: FileStatus,
    /// The numbers the status comes with, as the module docs' table says.
    pub words: Vec<u64>,
    /// Words for a person, for the statuses that have them.
    pub detail: String,
}

impl Encoded {
    /// A result with no words and no detail.
    fn bare(status: FileStatus) -> Self {
        Self {
            status,
            words: Vec::new(),
            detail: String::new(),
        }
    }
}

impl FileResult {
    /// The result as it crosses the boundary: its status, its words and its
    /// detail, by the table in the module docs.
    ///
    /// The matches on `editor-text`'s [`LoadError`] and [`SaveError`] are
    /// exhaustive on purpose. This crate must act on every variant of
    /// both: a refusal with no status and no words of its own would not
    /// reach Lean as what it is, so a new variant has to be given its row
    /// of the table here before the crate builds.
    pub fn encoded(&self) -> Encoded {
        match self {
            Self::Loaded { stamp, endings, .. } => {
                let mut words = stamp_words(*stamp).to_vec();
                words.extend([endings.lf, endings.crlf]);
                Encoded {
                    words,
                    ..Encoded::bare(FileStatus::Done)
                }
            }
            Self::Saved(stamp) => Encoded {
                words: stamp_words(*stamp).to_vec(),
                ..Encoded::bare(FileStatus::Done)
            },
            Self::NotLoaded(error) => match error {
                LoadError::Relative => Encoded::bare(FileStatus::Relative),
                LoadError::NotFound => Encoded::bare(FileStatus::NotFound),
                LoadError::NotAFile => Encoded::bare(FileStatus::NotAFile),
                LoadError::TooLarge { size, limit } => Encoded {
                    words: vec![*size, *limit],
                    ..Encoded::bare(FileStatus::TooLarge)
                },
                LoadError::Binary { offset } => Encoded {
                    words: vec![*offset],
                    ..Encoded::bare(FileStatus::Binary)
                },
                LoadError::Fs(error) => refused(error),
            },
            Self::NotSaved(error) => match error {
                SaveError::Relative => Encoded::bare(FileStatus::Relative),
                SaveError::NotAFile => Encoded::bare(FileStatus::NotAFile),
                SaveError::Changed { found } => {
                    let mut words = vec![u64::from(found.is_some())];
                    words.extend(found.map_or([0; 3], stamp_words));
                    Encoded {
                        words,
                        ..Encoded::bare(FileStatus::Changed)
                    }
                }
                SaveError::NoTemporaryName => Encoded::bare(FileStatus::NoTemporaryName),
                // A cancelled save keeps no result, so this does not cross;
                // it is answered all the same, and not with a panic.
                SaveError::Cancelled => Encoded {
                    detail: error.to_string(),
                    ..Encoded::bare(FileStatus::Failed)
                },
                SaveError::Fs(error) => refused(error),
            },
        }
    }
}

/// A stamp as three words: its seconds as a two's complement word, its
/// nanoseconds and its size.
fn stamp_words(stamp: Stamp) -> [u64; 3] {
    [
        stamp.modified.seconds.cast_unsigned(),
        u64::from(stamp.modified.nanoseconds),
        stamp.size,
    ]
}

/// A refusal by the file system as it crosses: its kind as a status, and
/// for the kinds that are not a status of their own, what it says.
///
/// The match on `editor-text`'s [`FsErrorKind`] is exhaustive on purpose.
/// This crate must act on every kind: each crosses as a status this
/// function chooses, so a new kind has to be given its status here before
/// the crate builds, and is not sent as a failure without anyone deciding.
fn refused(error: &FsError) -> Encoded {
    match error.kind {
        FsErrorKind::NotFound => Encoded::bare(FileStatus::NotFound),
        FsErrorKind::NotAFile => Encoded::bare(FileStatus::NotAFile),
        FsErrorKind::Denied => Encoded {
            detail: error.detail.clone(),
            ..Encoded::bare(FileStatus::Denied)
        },
        FsErrorKind::Exists | FsErrorKind::Other => Encoded {
            detail: error.to_string(),
            ..Encoded::bare(FileStatus::Failed)
        },
    }
}

/// What a save expects on disk as it crosses the boundary
/// ([`editor_ffi_files_save`]).
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RawExpect {
    /// 0 whatever is there, 1 no file, 2 the file unchanged since the stamp
    /// in the three numbers below, which are read only then.
    pub tag: u64,
    /// The stamp's seconds since the epoch, as a two's complement word.
    pub seconds: u64,
    /// The stamp's nanoseconds.
    pub nanoseconds: u64,
    /// The stamp's size in bytes.
    pub size: u64,
}

impl RawExpect {
    /// What the record says a save expects. `None` for a tag no one
    /// defined, and for nanoseconds no stamp holds.
    pub fn expect(self) -> Option<Expect> {
        match self.tag {
            0 => Some(Expect::Whatever),
            1 => Some(Expect::Absent),
            2 => Some(Expect::Unchanged(Stamp {
                modified: Modified {
                    seconds: self.seconds.cast_signed(),
                    nanoseconds: u32::try_from(self.nanoseconds).ok()?,
                },
                size: self.size,
            })),
            _ => None,
        }
    }
}

/// The file service over the file system `F`: loads and saves that
/// [`run`](Self::run) works one at a time, in the order they were started.
pub struct Files<F> {
    /// The file system the requests are worked on.
    fs: F,
    /// The requests, the results, and whether the service has been stopped.
    state: Mutex<State>,
    /// Signalled when a request is added or the service is stopped.
    changed: Condvar,
}

/// What [`Files::state`] guards.
struct State {
    /// The requests not yet worked.
    requests: Requests<Request>,
    /// The request being worked, if one is.
    working: Option<Working>,
    /// The results not yet taken, by request id.
    results: BTreeMap<u64, FileResult>,
    /// Whether [`Files::stop`] has been called.
    stopped: bool,
}

/// The request the service's thread is working.
struct Working {
    /// Its id.
    id: u64,
    /// Whether it has been cancelled since it was taken up.
    cancelled: Arc<AtomicBool>,
}

impl<F: Fs> Files<F> {
    /// A service with no requests, whose loop is not running.
    pub const fn new(fs: F) -> Self {
        Self {
            fs,
            state: Mutex::new(State {
                requests: Requests::new(),
                working: None,
                results: BTreeMap::new(),
                stopped: false,
            }),
            changed: Condvar::new(),
        }
    }

    /// The file system the service works on: for a test to reach its fake.
    pub fn fs(&self) -> &F {
        &self.fs
    }

    /// Asks for the file at `path` to be loaded unless it is longer than
    /// `limit` bytes, as the request `id`, and returns whether it was
    /// accepted. It returns at once and touches no file. An id in use is
    /// refused.
    pub fn start_load(&self, id: u64, path: PathBuf, limit: u64) -> bool {
        self.start(id, Request::Load { path, limit })
    }

    /// Asks for `snapshot` to be saved as the file at `path` if what is
    /// there is what `expect` says, as the request `id`, and returns
    /// whether it was accepted. It returns at once and touches no file. An
    /// id in use is refused.
    pub fn start_save(
        &self,
        id: u64,
        snapshot: editor_text::Snapshot,
        path: PathBuf,
        expect: Expect,
    ) -> bool {
        self.start(
            id,
            Request::Save {
                snapshot,
                path,
                expect,
            },
        )
    }

    /// Adds `request` as `id`, unless the id is in use.
    fn start(&self, id: u64, request: Request) -> bool {
        let mut state = self.state();
        let in_use = state.results.contains_key(&id)
            || state
                .working
                .as_ref()
                .is_some_and(|working| working.id == id);
        let started = !in_use && state.requests.start(id, request);
        drop(state);
        self.changed.notify_all();
        started
    }

    /// Hands over the result of the request `id`, once. `None` when the
    /// service keeps none for it: it is not finished, it was cancelled, its
    /// result was taken already, or it never was.
    pub fn take(&self, id: u64) -> Option<FileResult> {
        self.state().results.remove(&id)
    }

    /// Cancels the request `id`, and returns whether there was anything to
    /// cancel. The module docs say what cancelling means in each state a
    /// request can be in. It is safe for an id that is unknown.
    pub fn cancel(&self, id: u64) -> bool {
        let mut state = self.state();
        if state.requests.cancel(id) {
            return true;
        }
        if let Some(working) = &state.working
            && working.id == id
        {
            // Set under the lock, which the loop holds when it reads it
            // for the last time. True only for the cancel that set it.
            return !working.cancelled.swap(true, Ordering::SeqCst);
        }
        state.results.remove(&id).is_some()
    }

    /// How many requests are waiting or being worked, and how many results
    /// have not been taken, together.
    pub fn pending(&self) -> usize {
        let state = self.state();
        state.requests.pending() + usize::from(state.working.is_some()) + state.results.len()
    }

    /// Ends [`run`](Self::run), for good, once the request it is working is
    /// done. The requests that are left are never worked.
    pub fn stop(&self) {
        self.state().stopped = true;
        self.changed.notify_all();
    }

    /// The service loop: works each request in the order they were
    /// started, keeps its result, and calls `complete` with its id; and
    /// otherwise parks the calling thread until a request is started. It
    /// returns after [`stop`](Self::stop).
    ///
    /// The file system is asked, and `complete` is called, with no lock
    /// held. A request cancelled while it was worked keeps no result and
    /// is not completed.
    pub fn run(&self, complete: impl Fn(u64)) {
        let mut state = self.state();
        loop {
            if state.stopped {
                return;
            }
            let Some((id, request)) = state.requests.take_next() else {
                state = self
                    .changed
                    .wait(state)
                    .unwrap_or_else(PoisonError::into_inner);
                continue;
            };
            let cancelled = Arc::new(AtomicBool::new(false));
            state.working = Some(Working {
                id,
                cancelled: Arc::clone(&cancelled),
            });
            drop(state);
            let result = self.work(request, &cancelled);
            state = self.state();
            state.working = None;
            // The flag is set under the lock, so it is read here for good:
            // a cancel that comes later finds a result to drop.
            if cancelled.load(Ordering::SeqCst) {
                continue;
            }
            state.results.insert(id, result);
            drop(state);
            complete(id);
            state = self.state();
        }
    }

    /// Works `request` on the file system, with no lock held. A save is
    /// told it is cancelled once `cancelled` is set.
    fn work(&self, request: Request, cancelled: &AtomicBool) -> FileResult {
        match request {
            Request::Load { path, limit } => file::load(&self.fs, &path, limit).into(),
            Request::Save {
                snapshot,
                path,
                expect,
            } => file::save(&self.fs, &path, &snapshot, expect, &|| {
                cancelled.load(Ordering::SeqCst)
            })
            .into(),
        }
    }

    /// Locks the state. The lock is never held while other code runs, so a
    /// poisoned lock still guards a consistent state.
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// The id of the file service as an event's source: a completion of a file
/// request comes from the library source with this id.
pub const SERVICE: u64 = 2;

/// The process's file service, over the machine's file system.
#[expect(
    clippy::disallowed_methods,
    reason = "the process's file service is over the real file system; this static is the one place in the crate's sources that makes the adapter"
)]
static FILES: Files<StdFs> = Files::new(StdFs::system());

/// Whether the thread that runs the process's service loop was started:
/// set once, by the first request.
static STARTED: OnceLock<bool> = OnceLock::new();

/// Starts the thread that runs the process's service loop, if no earlier
/// call has, and returns whether there is one. The thread completes a
/// request by queueing its completion, and never ends: nothing in this
/// crate joins a thread, and once the queues are quit its completions are
/// dropped.
fn service_started() -> bool {
    *STARTED.get_or_init(|| {
        thread::Builder::new()
            .name("editor-files".into())
            .spawn(|| {
                FILES.run(|id| {
                    events::complete(SERVICE, id);
                });
            })
            .is_ok()
    })
}

/// The path the `len` bytes at `path` spell, with no decoding.
///
/// # Safety
///
/// `path` points to `len` readable bytes, unless `len` is 0.
unsafe fn path_of(path: *const u8, len: usize) -> PathBuf {
    if len == 0 {
        return PathBuf::new();
    }
    // SAFETY: the caller guarantees the pointer and the length.
    let bytes = unsafe { slice::from_raw_parts(path, len) };
    PathBuf::from(OsStr::from_bytes(bytes))
}

/// Asks the process's file service to load the file whose path is the
/// `path_len` bytes at `path`, unless it is longer than `limit` bytes, as
/// the request `id`, and returns whether it was accepted. It returns at
/// once and never blocks.
///
/// The completion is one [`EventKind::Completion`] on the completion queue,
/// from the library source [`SERVICE`], whose code is `id`; there is none
/// if the request is cancelled first. The result is then taken with
/// [`editor_ffi_files_take`].
///
/// Returns false, starting nothing, if `id` is in use, or if the operating
/// system refused the service its thread.
///
/// [`EventKind::Completion`]: crate::events::EventKind::Completion
///
/// # Safety
///
/// `path` points to `path_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_files_load(
    id: u64,
    path: *const u8,
    path_len: usize,
    limit: u64,
) -> bool {
    // SAFETY: the caller guarantees the pointer and the length.
    let path = unsafe { path_of(path, path_len) };
    service_started() && FILES.start_load(id, path, limit)
}

/// Asks the process's file service to save what `snapshot` holds as the
/// file whose path is the `path_len` bytes at `path`, if what is on disk is
/// what `expect` says, as the request `id`, and returns whether it was
/// accepted. It returns at once and never blocks. The snapshot is cloned,
/// which copies none of its text: the handle is still the caller's, and
/// may be freed before the save is worked.
///
/// The completion and the result are as [`editor_ffi_files_load`]'s.
///
/// Returns false, starting nothing, if `id` is in use, if `expect` says
/// nothing a save can expect ([`RawExpect::expect`]), or if the operating
/// system refused the service its thread.
///
/// # Safety
///
/// `snapshot` is a snapshot handle this library handed out and has not
/// taken back; `path` points to `path_len` readable bytes; and `expect`
/// points to a readable [`RawExpect`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_files_save(
    id: u64,
    snapshot: *const Snapshot,
    path: *const u8,
    path_len: usize,
    expect: *const RawExpect,
) -> bool {
    // SAFETY: the caller guarantees `expect` is readable.
    let Some(expect) = unsafe { expect.read() }.expect() else {
        return false;
    };
    // SAFETY: the caller guarantees the pointer and the length.
    let path = unsafe { path_of(path, path_len) };
    // SAFETY: the caller guarantees `snapshot` points to a live snapshot.
    let snapshot = unsafe { &*snapshot }.text().clone();
    service_started() && FILES.start_save(id, snapshot, path, expect)
}

/// The result of a file request as it crosses the boundary: one record,
/// filled in one call. The module docs have the table of statuses and
/// words.
#[repr(C)]
pub struct RawFileResult {
    /// How the request ended: a [`FileStatus`]'s code.
    pub status: u64,
    /// The loaded text: a snapshot handle the caller owns and must hand to
    /// [`editor_ffi_snapshot_free`](crate::snapshot::editor_ffi_snapshot_free)
    /// exactly once. Null unless the request was a load that succeeded.
    pub snapshot: *mut Snapshot,
    /// The words: a buffer of `words_len` bytes, owned by the caller until
    /// it is handed back with
    /// [`editor_ffi_text_free`](crate::text::editor_ffi_text_free).
    pub words: *mut u8,
    /// The length of `words` in bytes.
    pub words_len: usize,
    /// The detail: a buffer of `detail_len` bytes of UTF-8, owned by the
    /// caller until it is handed back the same way.
    pub detail: *mut u8,
    /// The length of `detail` in bytes.
    pub detail_len: usize,
}

/// Hands over the result of the file request `id`, once: fills `out` and
/// returns true, or returns false, with `out` untouched, when the service
/// keeps no result for `id` (it is not finished, it was cancelled, its
/// result was taken already, or it was another service's id).
///
/// A snapshot in the record is handed out here, and is counted live from
/// this call.
///
/// # Safety
///
/// `out` points to a writable [`RawFileResult`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_files_take(id: u64, out: *mut RawFileResult) -> bool {
    let Some(result) = FILES.take(id) else {
        return false;
    };
    let encoded = result.encoded();
    let snapshot = match result {
        FileResult::Loaded { snapshot, .. } => Snapshot::hand_out(snapshot),
        FileResult::Saved(_) | FileResult::NotLoaded(_) | FileResult::NotSaved(_) => {
            ptr::null_mut()
        }
    };
    let mut writer = Writer::with_capacity(encoded.words.len());
    for word in encoded.words {
        writer.word(word);
    }
    let (words, words_len) = words::lend(writer.finish());
    let (detail, detail_len) = text::lend(encoded.detail);
    let raw = RawFileResult {
        status: encoded.status.code(),
        snapshot,
        words,
        words_len,
        detail,
        detail_len,
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
    true
}

/// Cancels the file request `id`, and returns whether there was anything
/// to cancel: a request waiting or being worked, or a result not taken. It
/// is safe for an id that is unknown, and returns false for one.
///
/// A request that was waiting is never worked and never completed. One
/// whose completion is already on the queue is still delivered, and the
/// caller ignores it; its result is gone.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_files_cancel(id: u64) -> bool {
    FILES.cancel(id)
}

/// How many file requests are waiting or being worked, and how many
/// results have not been taken, together. A readout for tests, which use
/// it to see that a cancel left nothing behind.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_files_pending() -> u64 {
    FILES.pending() as u64
}

#[cfg(test)]
mod tests {
    use std::path::Path;
    use std::sync::mpsc::{self, Receiver, Sender};
    use std::thread::{JoinHandle, ThreadId};
    use std::time::{Duration, Instant};

    use editor_text::Text;
    use editor_text::fs::FakeFs;

    use super::*;

    /// How long a test waits for something that should happen at once. Only
    /// a broken service takes this long, and the test then fails instead of
    /// hanging.
    const DEADLINE: Duration = Duration::from_secs(5);

    /// The file the tests' fake holds.
    const FILE: &str = "/dir/file.txt";

    /// What it holds: a CRLF, a two-byte character and a byte that is not
    /// UTF-8.
    const BYTES: &[u8] = b"h\xC3\xA9llo\r\nw\xFFrld\n";

    /// A second file the fake holds, with other bytes.
    const OTHER: &str = "/dir/other.txt";

    /// A path the fake holds nothing at.
    const MISSING: &str = "/dir/missing.txt";

    /// When the fake's files were written.
    const THEN: Modified = Modified {
        seconds: 1_700_000_000,
        nanoseconds: 7,
    };

    /// A limit no test file is over.
    const NO_LIMIT: u64 = u64::MAX;

    /// The tests' file system. Two of these are alike, so what the service
    /// does to one is compared with what `editor_text::file` does to
    /// another.
    fn fake() -> FakeFs {
        let fs = FakeFs::new();
        fs.set_now(THEN);
        fs.file(FILE, BYTES);
        fs.file(OTHER, b"the other file\n");
        fs
    }

    /// A snapshot holding `text`.
    fn snapshot(text: &str) -> editor_text::Snapshot {
        Text::from(text).snapshot()
    }

    /// A save that is never cancelled.
    fn never() -> bool {
        false
    }

    /// Everything a result says: how it crosses, and the text of a load.
    fn said(result: &FileResult) -> (Encoded, Option<String>) {
        let text = match result {
            FileResult::Loaded { snapshot, .. } => Some(snapshot.to_string()),
            _ => None,
        };
        (result.encoded(), text)
    }

    /// A file service with its loop on a thread of the test's own and its
    /// completions on a channel.
    struct Rig {
        /// The service, over a fake file system.
        files: Arc<Files<FakeFs>>,
        /// The ids the service completed, in order.
        completed: Receiver<u64>,
        /// The thread the loop runs on.
        service: JoinHandle<()>,
    }

    /// The service's thread, held inside a call to the file system until
    /// the test lets go.
    struct Parked {
        /// Receives the thread that made the call, once it is held.
        entered: Receiver<ThreadId>,
        /// Lets the thread go.
        release: Sender<()>,
    }

    impl Parked {
        /// Waits until the service's thread is held in its call, and
        /// returns which thread it is; panics if no call is made by the
        /// deadline.
        fn entered(&self) -> ThreadId {
            self.entered
                .recv_timeout(DEADLINE)
                .unwrap_or_else(|_| panic!("the file system was not asked within {DEADLINE:?}"))
        }

        /// Lets the service's thread go on.
        fn release(self) {
            let _ = self.release.send(());
        }
    }

    impl Rig {
        /// Starts the loop of a service over `fs`.
        fn over(fs: FakeFs) -> Self {
            let files = Arc::new(Files::new(fs));
            let (done, completed) = mpsc::channel();
            let service = thread::spawn({
                let files = Arc::clone(&files);
                move || {
                    files.run(|id| {
                        let _ = done.send(id);
                    });
                }
            });
            Self {
                files,
                completed,
                service,
            }
        }

        /// The service's fake file system.
        fn fs(&self) -> &FakeFs {
            self.files.fs()
        }

        /// Holds the thread that makes the next call to the file system
        /// inside that call, whichever call it is, until the test lets go
        /// or the deadline passes: the test does not say which call
        /// `editor-text` makes first.
        fn park(&self) -> Parked {
            let (enter, entered) = mpsc::channel();
            let (release, released) = mpsc::channel::<()>();
            self.fs().on_next_call(move |_| {
                let _ = enter.send(thread::current().id());
                let _ = released.recv_timeout(DEADLINE);
            });
            Parked { entered, release }
        }

        /// The next request the service completes; panics if it completes
        /// none by the deadline.
        fn next(&self) -> u64 {
            self.completed
                .recv_timeout(DEADLINE)
                .unwrap_or_else(|_| panic!("no request was completed within {DEADLINE:?}"))
        }

        /// Shows that the service has completed nothing that has not been
        /// taken with [`next`](Self::next): starts the request `marker`,
        /// and requires it to be the next completion. The service works
        /// in order, so a request it was still to complete would come
        /// first. A test never sleeps to see that something did not happen.
        fn nothing_else_completed(&self, marker: u64) {
            assert!(self.files.start_load(marker, MISSING.into(), NO_LIMIT));
            assert_eq!(self.next(), marker);
            assert!(self.files.take(marker).is_some());
        }

        /// Stops the service and waits for its loop to return; panics if it
        /// has not by the deadline.
        fn stop(self) {
            self.files.stop();
            let deadline = Instant::now() + DEADLINE;
            while !self.service.is_finished() {
                assert!(
                    Instant::now() < deadline,
                    "the service loop was still running {DEADLINE:?} after stop"
                );
                thread::sleep(Duration::from_millis(1));
            }
        }
    }

    #[test]
    fn requests_come_out_in_the_order_they_were_started() {
        let mut requests = Requests::new();

        assert!(requests.start(7, "seven"));
        assert!(requests.start(3, "three"));
        assert!(requests.start(5, "five"));

        assert_eq!(requests.pending(), 3);
        assert_eq!(requests.take_next(), Some((7, "seven")));
        assert_eq!(requests.take_next(), Some((3, "three")));
        assert_eq!(requests.take_next(), Some((5, "five")));
        assert_eq!(requests.take_next(), None);
        assert_eq!(requests.pending(), 0);
    }

    #[test]
    fn a_request_whose_id_is_waiting_is_refused_and_the_one_waiting_is_as_it_was() {
        let mut requests = Requests::new();
        assert!(requests.start(7, "first"));

        assert!(!requests.start(7, "second"));

        assert!(requests.holds(7));
        assert_eq!(requests.take_next(), Some((7, "first")));
        assert_eq!(requests.take_next(), None);
        // Once it has come out, the id is free again.
        assert!(!requests.holds(7));
        assert!(requests.start(7, "third"));
    }

    #[test]
    fn a_cancelled_request_never_comes_out() {
        let mut requests = Requests::new();
        assert!(requests.start(1, "one"));
        assert!(requests.start(2, "two"));
        assert!(requests.start(3, "three"));

        assert!(requests.cancel(2));
        assert!(!requests.cancel(2));
        assert!(!requests.cancel(9));

        assert_eq!(requests.pending(), 2);
        assert_eq!(requests.take_next(), Some((1, "one")));
        assert_eq!(requests.take_next(), Some((3, "three")));
        assert_eq!(requests.take_next(), None);
    }

    #[test]
    fn a_request_is_completed_once_and_its_result_is_taken_once() {
        let rig = Rig::over(fake());

        assert!(rig.files.start_load(1, FILE.into(), NO_LIMIT));

        assert_eq!(rig.next(), 1);
        assert_eq!(rig.files.pending(), 1);
        assert!(matches!(rig.files.take(1), Some(FileResult::Loaded { .. })));
        assert!(rig.files.take(1).is_none());
        assert_eq!(rig.files.pending(), 0);
        // It was completed once.
        rig.nothing_else_completed(2);
        rig.stop();
    }

    #[test]
    fn start_returns_while_the_request_is_still_being_worked() {
        let rig = Rig::over(fake());
        let parked = rig.park();

        // The start returned: this thread goes on while the service's is
        // held inside the file system.
        assert!(rig.files.start_load(1, FILE.into(), NO_LIMIT));
        parked.entered();

        assert_eq!(rig.files.pending(), 1);
        assert!(rig.files.take(1).is_none());
        assert!(rig.completed.try_recv().is_err());
        parked.release();
        assert_eq!(rig.next(), 1);
        rig.stop();
    }

    #[test]
    fn the_file_system_is_asked_on_the_services_thread() {
        let rig = Rig::over(fake());
        let parked = rig.park();

        assert!(rig.files.start_load(1, FILE.into(), NO_LIMIT));
        let asked_on = parked.entered();

        assert_ne!(asked_on, thread::current().id());
        assert_eq!(asked_on, rig.service.thread().id());
        parked.release();
        assert_eq!(rig.next(), 1);
        rig.stop();
    }

    #[test]
    fn a_start_asks_the_file_system_nothing() {
        // No loop runs: only what a start itself does can reach the fake.
        let files = Files::new(fake());

        assert!(files.start_load(1, FILE.into(), NO_LIMIT));
        assert!(files.start_save(2, snapshot("new"), FILE.into(), Expect::Whatever));

        assert_eq!(files.fs().bytes(FILE).as_deref(), Some(BYTES));
        assert!(files.fs().calls().is_empty());
        assert_eq!(files.pending(), 2);
    }

    #[test]
    fn an_id_in_use_is_refused_while_it_waits_is_worked_and_has_a_result_not_taken() {
        let rig = Rig::over(fake());
        let parked = rig.park();
        assert!(rig.files.start_load(1, FILE.into(), NO_LIMIT));
        parked.entered();
        assert!(rig.files.start_load(2, FILE.into(), NO_LIMIT));

        // 1 is being worked and 2 is waiting.
        assert!(!rig.files.start_load(1, OTHER.into(), NO_LIMIT));
        assert!(!rig.files.start_load(2, OTHER.into(), NO_LIMIT));
        parked.release();
        assert_eq!([rig.next(), rig.next()], [1, 2]);
        // Both have results that were not taken.
        assert!(!rig.files.start_load(1, OTHER.into(), NO_LIMIT));
        assert!(rig.files.take(1).is_some());
        // Taken, the id is free.
        assert!(rig.files.start_load(1, OTHER.into(), NO_LIMIT));
        assert_eq!(rig.next(), 1);
        rig.stop();
    }

    #[test]
    fn saves_are_completed_in_the_order_they_were_started_and_the_later_one_is_what_is_left() {
        let rig = Rig::over(fake());
        let (first, second) = (snapshot("the first save\n"), snapshot("the second\r\n"));
        // Both saves are queued behind a request the service is held in.
        let parked = rig.park();
        assert!(rig.files.start_load(1, OTHER.into(), NO_LIMIT));
        parked.entered();
        assert!(
            rig.files
                .start_save(2, first.clone(), FILE.into(), Expect::Whatever)
        );
        assert!(
            rig.files
                .start_save(3, second.clone(), FILE.into(), Expect::Whatever)
        );
        parked.release();

        assert_eq!([rig.next(), rig.next(), rig.next()], [1, 2, 3]);

        // The file holds what it holds when `editor-text` saves the first
        // and then the second: the order is seen by what it leaves.
        let reference = fake();
        let path = Path::new(FILE);
        let _ = file::save(&reference, path, &first, Expect::Whatever, &never);
        let _ = file::save(&reference, path, &second, Expect::Whatever, &never);
        assert_eq!(rig.fs().bytes(FILE), reference.bytes(FILE));
        assert_ne!(rig.fs().bytes(FILE).as_deref(), Some(BYTES));
        rig.stop();
    }

    #[test]
    fn a_request_cancelled_while_it_waits_is_never_worked_and_never_completed() {
        let rig = Rig::over(fake());
        let parked = rig.park();
        assert!(rig.files.start_load(1, OTHER.into(), NO_LIMIT));
        parked.entered();
        assert!(
            rig.files
                .start_save(2, snapshot("never saved"), FILE.into(), Expect::Whatever)
        );

        assert!(rig.files.cancel(2));
        assert!(!rig.files.cancel(2));
        parked.release();

        assert_eq!(rig.next(), 1);
        // The next completion is the marker's, so none was queued for 2.
        rig.nothing_else_completed(3);
        assert!(rig.files.take(2).is_none());
        // It was never worked: the file is as it was.
        assert_eq!(rig.fs().bytes(FILE).as_deref(), Some(BYTES));
        assert_eq!(rig.files.pending(), 1);
        rig.stop();
    }

    #[test]
    fn a_save_cancelled_while_it_is_worked_does_not_replace_the_file_and_keeps_no_result() {
        let rig = Rig::over(fake());
        let new = snapshot("cancelled before it replaced the file\n");
        // The service is held in the save's first call to the file system.
        let parked = rig.park();
        assert!(
            rig.files
                .start_save(1, new.clone(), FILE.into(), Expect::Whatever)
        );
        parked.entered();

        assert!(rig.files.cancel(1));
        parked.release();

        // It is not completed, and no result is kept.
        rig.nothing_else_completed(2);
        assert!(rig.files.take(1).is_none());
        assert_eq!(rig.files.pending(), 0);
        // The file system is as `editor-text` leaves it after a save that
        // was told it is cancelled, the paths it holds included.
        let reference = fake();
        let _ = file::save(&reference, Path::new(FILE), &new, Expect::Whatever, &|| {
            true
        });
        assert_eq!(rig.fs().bytes(FILE), reference.bytes(FILE));
        assert_eq!(rig.fs().paths(), reference.paths());
        // And that is not what a save that goes through leaves.
        let saved = fake();
        let _ = file::save(&saved, Path::new(FILE), &new, Expect::Whatever, &never);
        assert_ne!(rig.fs().bytes(FILE), saved.bytes(FILE));
        rig.stop();
    }

    #[test]
    fn cancelling_a_finished_request_drops_its_result() {
        let rig = Rig::over(fake());
        let before = rig.files.pending();
        assert!(rig.files.start_load(1, FILE.into(), NO_LIMIT));
        assert_eq!(rig.next(), 1);
        assert_eq!(rig.files.pending(), before + 1);

        assert!(rig.files.cancel(1));

        assert!(rig.files.take(1).is_none());
        assert_eq!(rig.files.pending(), before);
        assert!(!rig.files.cancel(1));
        // An id the service never saw has nothing to cancel.
        assert!(!rig.files.cancel(99));
        rig.stop();
    }

    #[test]
    fn a_load_answers_what_editor_text_answers_for_that_path_and_limit() {
        // A limit below the file's size and one above it, another file,
        // and nothing: each changes the answer.
        let asked = [
            (FILE, 3),
            (FILE, 1_000),
            (OTHER, 1_000),
            (MISSING, 1_000),
            ("relative.txt", 1_000),
        ];
        let mut answers = Vec::new();
        for (path, limit) in asked {
            let rig = Rig::over(fake());

            assert!(rig.files.start_load(1, path.into(), limit));
            assert_eq!(rig.next(), 1);
            let Some(answer) = rig.files.take(1) else {
                panic!("no result was kept for {path} at {limit}");
            };

            let expected = FileResult::from(file::load(&fake(), Path::new(path), limit));
            assert_eq!(said(&answer), said(&expected), "{path} at {limit}");
            answers.push(said(&answer));
            rig.stop();
        }
        // The five answers differ, so each argument was the one forwarded.
        for (index, one) in answers.iter().enumerate() {
            for other in &answers[index + 1..] {
                assert_ne!(one, other);
            }
        }
    }

    #[test]
    fn a_save_answers_what_editor_text_answers_for_that_snapshot_path_and_expectation() {
        let on_disk = Stamp {
            modified: THEN,
            size: BYTES.len() as u64,
        };
        let stale = Stamp {
            modified: Modified {
                seconds: THEN.seconds - 1,
                nanoseconds: THEN.nanoseconds,
            },
            size: on_disk.size,
        };
        let asked = [
            (FILE, Expect::Absent, "absent over a file"),
            (FILE, Expect::Unchanged(stale), "a stale stamp"),
            (FILE, Expect::Unchanged(on_disk), "the stamp on disk"),
            (FILE, Expect::Whatever, "whatever"),
            (MISSING, Expect::Absent, "a new file"),
        ];
        for text in ["one text\n", "another, longer text \u{10DCFF}\r\n"] {
            let new = snapshot(text);
            for (path, expect, name) in asked {
                let rig = Rig::over(fake());

                assert!(rig.files.start_save(1, new.clone(), path.into(), expect));
                assert_eq!(rig.next(), 1);
                let Some(answer) = rig.files.take(1) else {
                    panic!("no result was kept for {name}");
                };

                let reference = fake();
                let expected = FileResult::from(file::save(
                    &reference,
                    Path::new(path),
                    &new,
                    expect,
                    &never,
                ));
                assert_eq!(said(&answer), said(&expected), "{name}");
                // The snapshot and the path were the ones forwarded: both
                // file systems hold the same bytes at the same paths.
                assert_eq!(rig.fs().paths(), reference.paths(), "{name}");
                for held in reference.paths() {
                    assert_eq!(rig.fs().bytes(&held), reference.bytes(&held), "{name}");
                }
                rig.stop();
            }
        }
    }

    #[test]
    fn each_result_is_its_status_and_its_words() {
        // Seconds before 1970 cross as a two's complement word.
        let stamp = Stamp {
            modified: Modified {
                seconds: -5,
                nanoseconds: 999_999_999,
            },
            size: 42,
        };
        let before_1970 = u64::MAX - 4;
        let denied = FsError::new(FsErrorKind::Denied, "os error 13");
        let other = FsError::new(FsErrorKind::Other, "the disk is on fire");
        let exists = FsError::new(FsErrorKind::Exists, "os error 17");
        let fs = |kind| FsError::new(kind, "os error");
        let table = [
            (
                FileResult::Loaded {
                    snapshot: snapshot("text"),
                    stamp,
                    endings: LineEndings { lf: 3, crlf: 4 },
                },
                FileStatus::Done,
                vec![before_1970, 999_999_999, 42, 3, 4],
                String::new(),
            ),
            (
                FileResult::Saved(stamp),
                FileStatus::Done,
                vec![before_1970, 999_999_999, 42],
                String::new(),
            ),
            (
                FileResult::NotLoaded(LoadError::Relative),
                FileStatus::Relative,
                vec![],
                String::new(),
            ),
            (
                FileResult::NotLoaded(LoadError::NotFound),
                FileStatus::NotFound,
                vec![],
                String::new(),
            ),
            (
                FileResult::NotLoaded(LoadError::NotAFile),
                FileStatus::NotAFile,
                vec![],
                String::new(),
            ),
            (
                FileResult::NotLoaded(LoadError::Binary { offset: 7 }),
                FileStatus::Binary,
                vec![7],
                String::new(),
            ),
            (
                FileResult::NotLoaded(LoadError::TooLarge {
                    size: 11,
                    limit: 10,
                }),
                FileStatus::TooLarge,
                vec![11, 10],
                String::new(),
            ),
            (
                FileResult::NotLoaded(LoadError::Fs(denied.clone())),
                FileStatus::Denied,
                vec![],
                String::from("os error 13"),
            ),
            (
                FileResult::NotLoaded(LoadError::Fs(other.clone())),
                FileStatus::Failed,
                vec![],
                other.to_string(),
            ),
            (
                FileResult::NotSaved(SaveError::Relative),
                FileStatus::Relative,
                vec![],
                String::new(),
            ),
            (
                FileResult::NotSaved(SaveError::NotAFile),
                FileStatus::NotAFile,
                vec![],
                String::new(),
            ),
            (
                FileResult::NotSaved(SaveError::Changed { found: Some(stamp) }),
                FileStatus::Changed,
                vec![1, before_1970, 999_999_999, 42],
                String::new(),
            ),
            (
                FileResult::NotSaved(SaveError::Changed { found: None }),
                FileStatus::Changed,
                vec![0, 0, 0, 0],
                String::new(),
            ),
            (
                FileResult::NotSaved(SaveError::NoTemporaryName),
                FileStatus::NoTemporaryName,
                vec![],
                String::new(),
            ),
            (
                FileResult::NotSaved(SaveError::Cancelled),
                FileStatus::Failed,
                vec![],
                SaveError::Cancelled.to_string(),
            ),
            (
                FileResult::NotSaved(SaveError::Fs(fs(FsErrorKind::NotFound))),
                FileStatus::NotFound,
                vec![],
                String::new(),
            ),
            (
                FileResult::NotSaved(SaveError::Fs(fs(FsErrorKind::NotAFile))),
                FileStatus::NotAFile,
                vec![],
                String::new(),
            ),
            (
                FileResult::NotSaved(SaveError::Fs(denied)),
                FileStatus::Denied,
                vec![],
                String::from("os error 13"),
            ),
            (
                FileResult::NotSaved(SaveError::Fs(exists.clone())),
                FileStatus::Failed,
                vec![],
                exists.to_string(),
            ),
            (
                FileResult::NotSaved(SaveError::Fs(other.clone())),
                FileStatus::Failed,
                vec![],
                other.to_string(),
            ),
        ];

        for (index, (result, status, words, detail)) in table.into_iter().enumerate() {
            assert_eq!(
                result.encoded(),
                Encoded {
                    status,
                    words,
                    detail
                },
                "row {index}"
            );
        }
    }

    #[test]
    fn each_status_has_the_code_the_table_gives_it() {
        let codes = [
            FileStatus::Done,
            FileStatus::Relative,
            FileStatus::NotFound,
            FileStatus::NotAFile,
            FileStatus::Denied,
            FileStatus::Binary,
            FileStatus::TooLarge,
            FileStatus::Changed,
            FileStatus::NoTemporaryName,
            FileStatus::Failed,
        ]
        .map(FileStatus::code);

        assert_eq!(codes, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    }

    #[test]
    fn what_a_save_expects_crosses_as_a_tag_and_a_stamp() {
        let raw = |tag, seconds, nanoseconds, size| RawExpect {
            tag,
            seconds,
            nanoseconds,
            size,
        };

        // The stamp is read only for the tag that has one.
        assert_eq!(raw(0, 9, 9, 9).expect(), Some(Expect::Whatever));
        assert_eq!(raw(1, 9, 9, 9).expect(), Some(Expect::Absent));
        assert_eq!(
            raw(2, u64::MAX - 4, 999_999_999, 42).expect(),
            Some(Expect::Unchanged(Stamp {
                modified: Modified {
                    seconds: -5,
                    nanoseconds: 999_999_999
                },
                size: 42
            }))
        );
        // A tag no one defined, and nanoseconds no stamp holds.
        assert_eq!(raw(3, 0, 0, 0).expect(), None);
        assert_eq!(raw(u64::MAX, 0, 0, 0).expect(), None);
        assert_eq!(raw(2, 0, u64::from(u32::MAX) + 1, 0).expect(), None);
    }

    #[test]
    fn stop_ends_the_loop_with_requests_left() {
        let rig = Rig::over(fake());
        let parked = rig.park();
        assert!(rig.files.start_load(1, FILE.into(), NO_LIMIT));
        parked.entered();
        assert!(
            rig.files
                .start_save(2, snapshot("never saved"), FILE.into(), Expect::Whatever)
        );
        let files = Arc::clone(&rig.files);

        files.stop();
        parked.release();
        rig.stop();

        // The request that waited was never worked.
        assert_eq!(files.fs().bytes(FILE).as_deref(), Some(BYTES));
        assert!(files.take(2).is_none());
    }
}
