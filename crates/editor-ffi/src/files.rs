//! The file service: loads, saves, stamps, listings, directories made,
//! appends and removes, completed through the completion queue, and
//! appends, removes and saves asked unobserved.
//!
//! This is the second service behind the completion queue, in the timer
//! service's shape (the crate docs, "Services and completions"). A job in
//! Lean asks for a load, a save, a stamp, a listing, a directory made, an
//! append or a remove with an id. [`Files::start_load`],
//! [`Files::start_save`], [`Files::start_stamp`], [`Files::start_list`],
//! [`Files::start_make_directory`], [`Files::start_append`] and
//! [`Files::start_remove`] return at once; the service's thread does the
//! work, keeps the result under the request's id and completes the
//! request: for the process's instance, by queueing an
//! [`EventKind::Completion`](crate::events::EventKind::Completion) whose
//! code is the id. The caller then takes the result ([`Files::take`]),
//! once. Rust never calls Lean.
//!
//! An append, a remove and a save (expecting whatever is there) may also
//! be asked **unobserved**, with no id ([`Files::append_unobserved`],
//! [`Files::remove_unobserved`], [`Files::save_unobserved`]): for what the
//! editor writes as it goes, such as a record of the session, where no
//! job waits on each write. One is worked in order with every other
//! request, is never completed and keeps no result. If it fails, its path
//! and why are kept as a [`Failure`], oldest first, until they are taken,
//! once ([`Files::take_failure`]).
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
//! - [`Requests`] is the requests not yet worked, observed and unobserved,
//!   and the flushes among them ([`Queued`]), in the order they were
//!   started. It is pure, as the timers' `Schedule` is.
//! - [`Files`] is the service over a file system, the port
//!   [`editor_text::fs::Fs`]. Its loop, [`Files::run`], takes the oldest
//!   request, works it with no lock held, and for an observed one keeps
//!   the result and completes the request through a closure it is given;
//!   for an unobserved one that failed, it keeps the [`Failure`].
//! - [`FileResult`] is what a request came to, [`FileResult::encoded`]
//!   how it crosses: a status, words and a detail string, and
//!   [`FileResult::failure`] what a failed one says for a person.
//!
//! The rules:
//!
//! - **One thread, in order.** Two saves of one file land in the order
//!   they were asked for, which a thread for each request could not
//!   promise, and so do unobserved requests among observed ones. The cost
//!   is that a load stuck on a slow file system holds up the requests
//!   behind it.
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
//!   after it. An unobserved request has no id, so it is never cancelled.
//! - **A flush is a barrier** ([`Files::flush`]): a marker on the queue,
//!   completed when the worker reaches it, so every request started
//!   before it, observed or unobserved, has been worked by then, and its
//!   completion is queued behind theirs. It keeps no result, its id is in
//!   use while it waits, and cancelling it withdraws it. It is how a caller
//!   waits for unobserved requests to be worked.
//! - **A hold parks the worker, for tests** ([`Files::hold`]): a request
//!   that, once the worker reaches it, is completed and then holds the
//!   worker until it is cancelled or the service is stopped, so a test can
//!   queue work behind a worker it knows is parked, in process, with no
//!   file. It is counted while it waits or holds, keeps no result, and is
//!   never asked for by the editor.
//! - **An unobserved request is counted while it waits or is worked**
//!   ([`Files::pending`]), so the count falls to 0 once the queue has
//!   drained; a failure kept is not counted. The count is a readout; a
//!   flush is what to wait on. Failures are kept until they
//!   are taken, with no bound: the caller takes them as it goes.
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
//! | Stamped | 0 | present (0 or 1), seconds, nanoseconds, size |
//! | A directory made | 0 | (none) |
//! | Appended | 0 | (none) |
//! | Removed, or nothing was there | 0 | (none) |
//! | The path is not absolute | 1 | |
//! | Not found | 2 | |
//! | Not a file | 3 | |
//! | Denied | 4 | (none; the detail is the platform's words) |
//! | Binary | 5 | the offset of the first NUL byte |
//! | Too large | 6 | size, limit |
//! | Changed | 7 | present (0 or 1), seconds, nanoseconds, size |
//! | No temporary name | 8 | |
//! | Failed | 9 | (none; the detail says what failed) |
//! | Not a directory | 10 | |
//! | Listed | 11 | the count, then for each entry its kind (0 file, 1 directory, 2 other) and the byte length of its name; the detail is the names, joined |
//!
//! **A name that is not UTF-8 is left out of a listing**, because Lean
//! cannot name such a file, and the count covers only the entries kept. A
//! listing that is refused crosses as a load's refusal does: not absolute
//! 1, not found 2, denied 4 and anything else 9, with not a directory its
//! own status. A directory that is not made crosses the same way: not
//! absolute 1, not a directory 10 (a file at the path or on the way to
//! it), denied 4 and anything else 9. An append or a remove that is refused
//! crosses as a load's refusal does: not absolute 1, not found 2 (for an
//! append, the directory the file is in is not there), not a file 3 (a
//! directory at the path, or for an append a file on the way to it),
//! denied 4 and anything else 9.
//!
//! [`editor_ffi_files_failure`] fills a [`RawFileFailure`]: the path the
//! unobserved request was about, as the bytes it was asked with, and why
//! it failed, a string for a person (the refusal's own words, as
//! [`FileResult::failure`] gives them). Both are buffers the caller owns
//! and hands back with
//! [`editor_ffi_text_free`](crate::text::editor_ffi_text_free), each once,
//! as a [`RawFileResult`]'s detail is.
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
//! | [`editor_ffi_files_stamp`] | Starts a stamp request: the stamp of the file at a path, or none. False, starting nothing, as for a load |
//! | [`editor_ffi_files_list`] | Starts a listing of the directory at a path. False, starting nothing, as for a load |
//! | [`editor_ffi_files_make_directory`] | Starts making the directory at a path, with every directory on the way to it. False, starting nothing, as for a load |
//! | [`editor_ffi_files_append`] | Starts adding bytes, which it copies, to the end of the file at a path, making the file where nothing is. False, starting nothing, as for a load |
//! | [`editor_ffi_files_remove`] | Starts removing the file at a path; nothing there is done. False, starting nothing, as for a load |
//! | [`editor_ffi_files_append_unobserved`] | Asks for an append with no id: never completed, kept only if it fails. False, asking nothing, only when the service has no thread |
//! | [`editor_ffi_files_remove_unobserved`] | Asks for a remove with no id, as for an unobserved append |
//! | [`editor_ffi_files_save_unobserved`] | Asks for a save of the snapshot behind a handle, which it clones, expecting whatever is there, with no id, as for an unobserved append |
//! | [`editor_ffi_files_take`] | Fills a [`RawFileResult`] and returns true, or returns false when the service keeps no result for the id |
//! | [`editor_ffi_files_failure`] | Fills a [`RawFileFailure`] with the oldest failure of an unobserved request and returns true, taking it, or returns false when none is kept |
//! | [`editor_ffi_files_flush`] | Asks for an id to be completed once every request started before it is worked; keeps no result. False, starting nothing, as for a load |
//! | [`editor_ffi_files_hold`] | For tests: asks for an id to be completed when the worker reaches it, and for the worker to work nothing more until the id is cancelled. False, starting nothing, as for a load |
//! | [`editor_ffi_files_cancel`] | Cancels, and says whether there was anything to cancel; a hold's cancel lets the worker go |
//! | [`editor_ffi_files_pending`] | Requests waiting or being worked, unobserved ones included, and results not taken |

use std::collections::{BTreeMap, VecDeque};
use std::ffi::OsStr;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, PoisonError};
use std::{ptr, slice, thread};

use editor_fs_std::StdFs;
use editor_text::file::{
    self, AppendError, Expect, LineEndings, ListError, LoadError, Loaded, MakeDirectoryError,
    RemoveError, SaveError, Stamp,
};
use editor_text::fs::{Entry, Fs, FsError, FsErrorKind, Kind, Modified};

use crate::snapshot::Snapshot;
use crate::words::{self, Writer};
use crate::{events, text};

/// The requests that are not yet worked, each an id and what is asked, in
/// the order they were started. An unobserved request has no id. A flush
/// ([`start_flush`](Self::start_flush)) waits among them as a marker.
#[derive(Debug)]
pub struct Requests<T> {
    /// The requests, oldest first, each with its id if it is observed.
    waiting: VecDeque<(Option<u64>, Queued<T>)>,
}

/// What waits in [`Requests`]: a piece of work, or a flush, which is no
/// work at all and is completed when the worker reaches it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Queued<T> {
    /// A request to be worked.
    Work(T),
    /// A flush: once it is taken, every request started before it has been
    /// taken too.
    Flush,
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
        self.push(id, Queued::Work(request))
    }

    /// Adds a flush as `id`, behind every request already waiting, observed
    /// or not, and returns whether it was added. An id that is already
    /// waiting is refused. It comes out of [`take_next`](Self::take_next)
    /// once everything before it has, and is cancelled as a request is.
    pub fn start_flush(&mut self, id: u64) -> bool {
        self.push(id, Queued::Flush)
    }

    /// Adds `queued` as `id`, unless the id is waiting.
    fn push(&mut self, id: u64, queued: Queued<T>) -> bool {
        if self.holds(id) {
            return false;
        }
        self.waiting.push_back((Some(id), queued));
        true
    }

    /// Adds a request that has no id, behind those already waiting. It
    /// takes no id, and no cancel names it.
    pub fn start_unobserved(&mut self, request: T) {
        self.waiting.push_back((None, Queued::Work(request)));
    }

    /// Removes the request or flush `id`, and returns whether it was
    /// waiting.
    pub fn cancel(&mut self, id: u64) -> bool {
        let before = self.waiting.len();
        self.waiting.retain(|(waiting, _)| *waiting != Some(id));
        self.waiting.len() != before
    }

    /// Removes and returns what has waited longest, a request or a flush,
    /// with its id if it is observed, if anything is waiting.
    pub fn take_next(&mut self) -> Option<(Option<u64>, Queued<T>)> {
        self.waiting.pop_front()
    }

    /// Whether the request or flush `id` is waiting.
    pub fn holds(&self, id: u64) -> bool {
        self.waiting.iter().any(|(waiting, _)| *waiting == Some(id))
    }

    /// How many requests and flushes are waiting.
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
    /// Read the stamp of the file at `path`.
    Stamp {
        /// Where the file is.
        path: PathBuf,
    },
    /// List the directory at `path`.
    List {
        /// Where the directory is.
        path: PathBuf,
    },
    /// Make the directory at `path`, and every directory on the way to it.
    MakeDirectory {
        /// Where the directory is to be.
        path: PathBuf,
    },
    /// Add `bytes` to the end of the file at `path`, making the file where
    /// nothing is.
    Append {
        /// Where the file is.
        path: PathBuf,
        /// What to add.
        bytes: Vec<u8>,
    },
    /// Remove the file at `path`; nothing there is no error.
    Remove {
        /// Where the file is.
        path: PathBuf,
    },
    /// Park the worker, once it reaches this, until the request is
    /// cancelled ([`Files::hold`]): a control for tests, which the editor
    /// never asks for.
    Hold,
}

impl Request {
    /// The path the request is about: what an unobserved request's failure
    /// is kept with. A hold is about none.
    fn path(&self) -> Option<&Path> {
        match self {
            Self::Load { path, .. }
            | Self::Save { path, .. }
            | Self::Stamp { path }
            | Self::List { path }
            | Self::MakeDirectory { path }
            | Self::Append { path, .. }
            | Self::Remove { path } => Some(path),
            Self::Hold => None,
        }
    }
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
    /// A stamp was read: the file's, or none when nothing is there.
    Stamped(Option<Stamp>),
    /// A load was refused.
    NotLoaded(LoadError),
    /// A save was refused.
    NotSaved(SaveError),
    /// A directory was listed: its entries, sorted by name.
    Listed(Vec<Entry>),
    /// A listing was refused.
    NotListed(ListError),
    /// A directory was made, or was there.
    Made,
    /// A directory was not made.
    NotMade(MakeDirectoryError),
    /// Bytes were added to a file.
    Appended,
    /// Bytes were not added.
    NotAppended(AppendError),
    /// A file was removed, or nothing was there.
    Removed,
    /// A file was not removed.
    NotRemoved(RemoveError),
}

impl FileResult {
    /// What a request that failed says of why, for a person: the refusal's
    /// own words. `None` for a request that did what it was asked.
    pub fn failure(&self) -> Option<String> {
        match self {
            Self::Loaded { .. }
            | Self::Saved(_)
            | Self::Stamped(_)
            | Self::Listed(_)
            | Self::Made
            | Self::Appended
            | Self::Removed => None,
            Self::NotLoaded(error) => Some(error.to_string()),
            Self::NotSaved(error) => Some(error.to_string()),
            Self::NotListed(error) => Some(error.to_string()),
            Self::NotMade(error) => Some(error.to_string()),
            Self::NotAppended(error) => Some(error.to_string()),
            Self::NotRemoved(error) => Some(error.to_string()),
        }
    }
}

impl From<Result<(), AppendError>> for FileResult {
    fn from(appended: Result<(), AppendError>) -> Self {
        match appended {
            Ok(()) => Self::Appended,
            Err(error) => Self::NotAppended(error),
        }
    }
}

impl From<Result<(), RemoveError>> for FileResult {
    fn from(removed: Result<(), RemoveError>) -> Self {
        match removed {
            Ok(()) => Self::Removed,
            Err(error) => Self::NotRemoved(error),
        }
    }
}

impl From<Result<(), MakeDirectoryError>> for FileResult {
    fn from(made: Result<(), MakeDirectoryError>) -> Self {
        match made {
            Ok(()) => Self::Made,
            Err(error) => Self::NotMade(error),
        }
    }
}

impl From<Result<Vec<Entry>, ListError>> for FileResult {
    fn from(listed: Result<Vec<Entry>, ListError>) -> Self {
        match listed {
            Ok(entries) => Self::Listed(entries),
            Err(error) => Self::NotListed(error),
        }
    }
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

impl From<Result<Option<Stamp>, LoadError>> for FileResult {
    fn from(stamped: Result<Option<Stamp>, LoadError>) -> Self {
        match stamped {
            Ok(stamp) => Self::Stamped(stamp),
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
    /// The file was loaded, saved, added to or removed, its stamp read, or
    /// the directory made.
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
    /// What is at the path is not a directory.
    NotADirectory = 10,
    /// A directory was listed.
    Listed = 11,
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
    /// The matches on `editor-text`'s [`LoadError`], [`SaveError`],
    /// [`ListError`], [`MakeDirectoryError`], [`AppendError`] and
    /// [`RemoveError`] are exhaustive on purpose. This crate must act on
    /// every variant of all six: a refusal with no status and no words of
    /// its own would not reach Lean as what it is, so a new variant has to
    /// be given its row of the table here before the crate builds.
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
            Self::Stamped(found) => {
                let mut words = vec![u64::from(found.is_some())];
                words.extend(found.map_or([0; 3], stamp_words));
                Encoded {
                    words,
                    ..Encoded::bare(FileStatus::Done)
                }
            }
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
            Self::Listed(entries) => listed(entries),
            Self::NotListed(error) => match error {
                ListError::Relative => Encoded::bare(FileStatus::Relative),
                ListError::NotFound => Encoded::bare(FileStatus::NotFound),
                ListError::NotADirectory => Encoded::bare(FileStatus::NotADirectory),
                ListError::Fs(error) => refused(error),
            },
            Self::Made => Encoded::bare(FileStatus::Done),
            Self::NotMade(error) => match error {
                MakeDirectoryError::Relative => Encoded::bare(FileStatus::Relative),
                MakeDirectoryError::NotADirectory => Encoded::bare(FileStatus::NotADirectory),
                MakeDirectoryError::Fs(error) => refused(error),
            },
            Self::Appended | Self::Removed => Encoded::bare(FileStatus::Done),
            Self::NotAppended(error) => match error {
                AppendError::Relative => Encoded::bare(FileStatus::Relative),
                AppendError::NotFound => Encoded::bare(FileStatus::NotFound),
                AppendError::NotAFile => Encoded::bare(FileStatus::NotAFile),
                AppendError::Fs(error) => refused(error),
            },
            Self::NotRemoved(error) => match error {
                RemoveError::Relative => Encoded::bare(FileStatus::Relative),
                RemoveError::NotAFile => Encoded::bare(FileStatus::NotAFile),
                RemoveError::Fs(error) => refused(error),
            },
        }
    }
}

/// A listing as it crosses: the count, each entry's kind and name length,
/// and the names joined as the detail. A name that is not UTF-8 is left
/// out, since Lean cannot name it.
fn listed(entries: &[Entry]) -> Encoded {
    let named: Vec<(&str, Kind)> = entries
        .iter()
        .filter_map(|entry| Some((entry.name.to_str()?, entry.kind)))
        .collect();
    let mut words = vec![named.len() as u64];
    let mut detail = String::new();
    for (name, kind) in named {
        let code = match kind {
            Kind::File => 0,
            Kind::Directory => 1,
            Kind::Other => 2,
        };
        words.extend([code, name.len() as u64]);
        detail.push_str(name);
    }
    Encoded {
        status: FileStatus::Listed,
        words,
        detail,
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
    /// The failures of unobserved requests not yet taken, oldest first.
    failures: VecDeque<Failure>,
    /// Whether [`Files::stop`] has been called.
    stopped: bool,
}

/// An unobserved request that failed ([`Files::take_failure`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Failure {
    /// The path the request was about.
    pub path: PathBuf,
    /// Why it failed, for a person: the refusal's own words.
    pub detail: String,
}

/// The request the service's thread is working.
struct Working {
    /// Its id, or none for an unobserved request.
    id: Option<u64>,
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
                failures: VecDeque::new(),
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

    /// Asks for the stamp of the file at `path`, as the request `id`, and
    /// returns whether it was accepted. It returns at once and touches no
    /// file. An id in use is refused.
    pub fn start_stamp(&self, id: u64, path: PathBuf) -> bool {
        self.start(id, Request::Stamp { path })
    }

    /// Asks for the directory at `path` to be listed, as the request `id`,
    /// and returns whether it was accepted. It returns at once and touches
    /// no file. An id in use is refused.
    pub fn start_list(&self, id: u64, path: PathBuf) -> bool {
        self.start(id, Request::List { path })
    }

    /// Asks for the directory at `path` to be made, with every directory on
    /// the way to it, as the request `id`, and returns whether it was
    /// accepted. It returns at once and touches no file. An id in use is
    /// refused.
    pub fn start_make_directory(&self, id: u64, path: PathBuf) -> bool {
        self.start(id, Request::MakeDirectory { path })
    }

    /// Asks for `bytes` to be added to the end of the file at `path`, which
    /// is made where nothing is, as the request `id`, and returns whether
    /// it was accepted. It returns at once and touches no file. An id in
    /// use is refused.
    pub fn start_append(&self, id: u64, path: PathBuf, bytes: Vec<u8>) -> bool {
        self.start(id, Request::Append { path, bytes })
    }

    /// Asks for the file at `path` to be removed, as the request `id`, and
    /// returns whether it was accepted. It returns at once and touches no
    /// file. An id in use is refused.
    pub fn start_remove(&self, id: u64, path: PathBuf) -> bool {
        self.start(id, Request::Remove { path })
    }

    /// Asks, unobserved, for `bytes` to be added to the end of the file at
    /// `path`: worked in order with every other request, never completed,
    /// and kept only if it fails ([`take_failure`](Self::take_failure)).
    pub fn append_unobserved(&self, path: PathBuf, bytes: Vec<u8>) {
        self.start_unobserved(Request::Append { path, bytes });
    }

    /// Asks, unobserved, for the file at `path` to be removed, as
    /// [`append_unobserved`](Self::append_unobserved) asks.
    pub fn remove_unobserved(&self, path: PathBuf) {
        self.start_unobserved(Request::Remove { path });
    }

    /// Asks, unobserved, for `snapshot` to be saved as the file at `path`,
    /// expecting whatever is there, as
    /// [`append_unobserved`](Self::append_unobserved) asks. It is a save
    /// like any other: a temporary file renamed over the file.
    pub fn save_unobserved(&self, snapshot: editor_text::Snapshot, path: PathBuf) {
        self.start_unobserved(Request::Save {
            snapshot,
            path,
            expect: Expect::Whatever,
        });
    }

    /// Hands over the oldest failure of an unobserved request, once, or
    /// `None` when none is kept.
    pub fn take_failure(&self) -> Option<Failure> {
        self.state().failures.pop_front()
    }

    /// Adds `request` as `id`, unless the id is in use.
    fn start(&self, id: u64, request: Request) -> bool {
        let mut state = self.state();
        let started = !Self::in_use(&state, id) && state.requests.start(id, request);
        drop(state);
        self.changed.notify_all();
        started
    }

    /// Asks for the worker to be held, as the request `id`, and returns
    /// whether it was accepted: once the worker reaches it, behind every
    /// request started before it, `id` is completed and the worker parks,
    /// working nothing behind it, until `id` is cancelled or the service is
    /// stopped. While it holds it is counted in [`pending`](Self::pending)
    /// and its id is in use; it keeps no result. It returns at once. A
    /// control for tests, which the editor never asks for: a test holds the
    /// worker to see what waits behind it.
    pub fn hold(&self, id: u64) -> bool {
        self.start(id, Request::Hold)
    }

    /// Asks for the request `id` to be completed once every request started
    /// before this call, observed or unobserved, has been worked, and
    /// returns whether it was accepted. It returns at once. An id in use is
    /// refused. It keeps no result: its completion is the whole answer.
    /// Cancelling it while it waits withdraws it.
    pub fn flush(&self, id: u64) -> bool {
        let mut state = self.state();
        let started = !Self::in_use(&state, id) && state.requests.start_flush(id);
        drop(state);
        self.changed.notify_all();
        started
    }

    /// Whether `id` is being worked or has a result not taken. One waiting
    /// is the queue's to refuse.
    fn in_use(state: &State, id: u64) -> bool {
        state.results.contains_key(&id)
            || state
                .working
                .as_ref()
                .is_some_and(|working| working.id == Some(id))
    }

    /// Adds `request` with no id, behind those already waiting.
    fn start_unobserved(&self, request: Request) {
        self.state().requests.start_unobserved(request);
        self.changed.notify_all();
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
            && working.id == Some(id)
        {
            // Set under the lock, which the loop holds when it reads it
            // for the last time. True only for the cancel that set it.
            let first = !working.cancelled.swap(true, Ordering::SeqCst);
            drop(state);
            // A hold waits for the flag.
            self.changed.notify_all();
            return first;
        }
        state.results.remove(&id).is_some()
    }

    /// How many requests are waiting or being worked, unobserved ones
    /// included, and how many results have not been taken, together. A
    /// failure kept is not counted.
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
    /// is not completed. An unobserved request keeps no result and is not
    /// completed either: if it failed, its path and why are kept as a
    /// [`Failure`].
    pub fn run(&self, complete: impl Fn(u64)) {
        let mut state = self.state();
        loop {
            if state.stopped {
                return;
            }
            let Some((id, queued)) = state.requests.take_next() else {
                state = self
                    .changed
                    .wait(state)
                    .unwrap_or_else(PoisonError::into_inner);
                continue;
            };
            let request = match queued {
                Queued::Work(Request::Hold) => {
                    if let Some(id) = id {
                        state = self.park(id, state, &complete);
                    }
                    continue;
                }
                Queued::Work(request) => request,
                // Everything started before it has been worked: it is
                // completed now, and keeps no result.
                Queued::Flush => {
                    drop(state);
                    if let Some(id) = id {
                        complete(id);
                    }
                    state = self.state();
                    continue;
                }
            };
            let cancelled = Arc::new(AtomicBool::new(false));
            state.working = Some(Working {
                id,
                cancelled: Arc::clone(&cancelled),
            });
            drop(state);
            // Kept for an unobserved request, whose failure names it.
            let path = id
                .is_none()
                .then(|| request.path().map(Path::to_path_buf))
                .flatten();
            let result = self.work(request, &cancelled);
            state = self.state();
            state.working = None;
            let Some(id) = id else {
                if let (Some(path), Some(detail)) = (path, result.failure()) {
                    state.failures.push_back(Failure { path, detail });
                }
                continue;
            };
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

    /// Parks the worker on the hold `id`: marks it as the request being
    /// worked, completes it with no lock held, so the holder knows the
    /// worker has reached it, then waits until it is cancelled or the
    /// service is stopped. It keeps no result.
    fn park<'a>(
        &'a self,
        id: u64,
        mut state: MutexGuard<'a, State>,
        complete: &impl Fn(u64),
    ) -> MutexGuard<'a, State> {
        let cancelled = Arc::new(AtomicBool::new(false));
        state.working = Some(Working {
            id: Some(id),
            cancelled: Arc::clone(&cancelled),
        });
        drop(state);
        complete(id);
        // The flag is set under the lock, and the cancel that sets it
        // notifies, so the wait cannot miss it.
        state = self
            .changed
            .wait_while(self.state(), |state| {
                !state.stopped && !cancelled.load(Ordering::SeqCst)
            })
            .unwrap_or_else(PoisonError::into_inner);
        state.working = None;
        state
    }

    /// Works `request` on the file system, with no lock held. A save is
    /// told it is cancelled once `cancelled` is set. A hold is never
    /// worked: the loop parks on it ([`park`](Self::park)).
    fn work(&self, request: Request, cancelled: &AtomicBool) -> FileResult {
        match request {
            Request::Hold => unreachable!("a hold is parked on by the loop, never worked"),
            Request::Load { path, limit } => file::load(&self.fs, &path, limit).into(),
            Request::Save {
                snapshot,
                path,
                expect,
            } => file::save(&self.fs, &path, &snapshot, expect, &|| {
                cancelled.load(Ordering::SeqCst)
            })
            .into(),
            Request::Stamp { path } => file::stamp(&self.fs, &path).into(),
            Request::List { path } => file::list(&self.fs, &path).into(),
            Request::MakeDirectory { path } => file::make_directory(&self.fs, &path).into(),
            Request::Append { path, bytes } => file::append(&self.fs, &path, &bytes).into(),
            Request::Remove { path } => file::remove(&self.fs, &path).into(),
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

/// Asks the process's file service for the stamp of the file whose path is
/// the `path_len` bytes at `path`, as the request `id`, and returns whether
/// it was accepted. It returns at once and never blocks. Nothing of the file
/// is read.
///
/// The completion and the result are as [`editor_ffi_files_load`]'s.
///
/// Returns false, starting nothing, if `id` is in use, or if the operating
/// system refused the service its thread.
///
/// # Safety
///
/// `path` points to `path_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_files_stamp(id: u64, path: *const u8, path_len: usize) -> bool {
    // SAFETY: the caller guarantees the pointer and the length.
    let path = unsafe { path_of(path, path_len) };
    service_started() && FILES.start_stamp(id, path)
}

/// Asks the process's file service to list the directory whose path is the
/// `path_len` bytes at `path`, as the request `id`, and returns whether it
/// was accepted. It returns at once and never blocks.
///
/// The completion and the result are as [`editor_ffi_files_load`]'s.
///
/// Returns false, starting nothing, if `id` is in use, or if the operating
/// system refused the service its thread.
///
/// # Safety
///
/// `path` points to `path_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_files_list(id: u64, path: *const u8, path_len: usize) -> bool {
    // SAFETY: the caller guarantees the pointer and the length.
    let path = unsafe { path_of(path, path_len) };
    service_started() && FILES.start_list(id, path)
}

/// Asks the process's file service to make the directory whose path is the
/// `path_len` bytes at `path`, with every directory on the way to it, as the
/// request `id`, and returns whether it was accepted. It returns at once and
/// never blocks.
///
/// The completion and the result are as [`editor_ffi_files_load`]'s.
///
/// Returns false, starting nothing, if `id` is in use, or if the operating
/// system refused the service its thread.
///
/// # Safety
///
/// `path` points to `path_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_files_make_directory(
    id: u64,
    path: *const u8,
    path_len: usize,
) -> bool {
    // SAFETY: the caller guarantees the pointer and the length.
    let path = unsafe { path_of(path, path_len) };
    service_started() && FILES.start_make_directory(id, path)
}

/// The `len` bytes at `bytes`, copied.
///
/// # Safety
///
/// `bytes` points to `len` readable bytes, unless `len` is 0.
unsafe fn bytes_of(bytes: *const u8, len: usize) -> Vec<u8> {
    if len == 0 {
        return Vec::new();
    }
    // SAFETY: the caller guarantees the pointer and the length.
    unsafe { slice::from_raw_parts(bytes, len) }.to_vec()
}

/// Asks the process's file service to add the `bytes_len` bytes at `bytes`
/// to the end of the file whose path is the `path_len` bytes at `path`,
/// making the file where nothing is, as the request `id`, and returns
/// whether it was accepted. It returns at once and never blocks; the bytes
/// are copied.
///
/// The completion and the result are as [`editor_ffi_files_load`]'s.
///
/// Returns false, starting nothing, if `id` is in use, or if the operating
/// system refused the service its thread.
///
/// # Safety
///
/// `path` points to `path_len` readable bytes, and `bytes` to `bytes_len`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_files_append(
    id: u64,
    path: *const u8,
    path_len: usize,
    bytes: *const u8,
    bytes_len: usize,
) -> bool {
    // SAFETY: the caller guarantees the pointers and the lengths.
    let (path, bytes) = unsafe { (path_of(path, path_len), bytes_of(bytes, bytes_len)) };
    service_started() && FILES.start_append(id, path, bytes)
}

/// Asks the process's file service to remove the file whose path is the
/// `path_len` bytes at `path`, as the request `id`, and returns whether it
/// was accepted. It returns at once and never blocks. Nothing there is done
/// all the same.
///
/// The completion and the result are as [`editor_ffi_files_load`]'s.
///
/// Returns false, starting nothing, if `id` is in use, or if the operating
/// system refused the service its thread.
///
/// # Safety
///
/// `path` points to `path_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_files_remove(
    id: u64,
    path: *const u8,
    path_len: usize,
) -> bool {
    // SAFETY: the caller guarantees the pointer and the length.
    let path = unsafe { path_of(path, path_len) };
    service_started() && FILES.start_remove(id, path)
}

/// Asks the process's file service, unobserved, to add the `bytes_len`
/// bytes at `bytes` to the end of the file whose path is the `path_len`
/// bytes at `path`, as [`editor_ffi_files_append`] does, and returns
/// whether it was accepted. It returns at once and never blocks.
///
/// It is worked in order with every other file request, is never completed
/// and keeps no result: if it fails, its path and why are kept for
/// [`editor_ffi_files_failure`].
///
/// Returns false, starting nothing, only if the operating system refused
/// the service its thread.
///
/// # Safety
///
/// `path` points to `path_len` readable bytes, and `bytes` to `bytes_len`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_files_append_unobserved(
    path: *const u8,
    path_len: usize,
    bytes: *const u8,
    bytes_len: usize,
) -> bool {
    // SAFETY: the caller guarantees the pointers and the lengths.
    let (path, bytes) = unsafe { (path_of(path, path_len), bytes_of(bytes, bytes_len)) };
    if !service_started() {
        return false;
    }
    FILES.append_unobserved(path, bytes);
    true
}

/// Asks the process's file service, unobserved, to remove the file whose
/// path is the `path_len` bytes at `path`, as [`editor_ffi_files_remove`]
/// does; otherwise as [`editor_ffi_files_append_unobserved`].
///
/// # Safety
///
/// `path` points to `path_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_files_remove_unobserved(
    path: *const u8,
    path_len: usize,
) -> bool {
    // SAFETY: the caller guarantees the pointer and the length.
    let path = unsafe { path_of(path, path_len) };
    if !service_started() {
        return false;
    }
    FILES.remove_unobserved(path);
    true
}

/// Asks the process's file service, unobserved, to save what `snapshot`
/// holds as the file whose path is the `path_len` bytes at `path`,
/// expecting whatever is there: a save as [`editor_ffi_files_save`] makes
/// one, a temporary file renamed over the file. The snapshot is cloned, as
/// that function clones it. Otherwise as
/// [`editor_ffi_files_append_unobserved`].
///
/// # Safety
///
/// `snapshot` is a snapshot handle this library handed out and has not
/// taken back, and `path` points to `path_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_files_save_unobserved(
    snapshot: *const Snapshot,
    path: *const u8,
    path_len: usize,
) -> bool {
    // SAFETY: the caller guarantees the pointer and the length.
    let path = unsafe { path_of(path, path_len) };
    // SAFETY: the caller guarantees `snapshot` points to a live snapshot.
    let snapshot = unsafe { &*snapshot }.text().clone();
    if !service_started() {
        return false;
    }
    FILES.save_unobserved(snapshot, path);
    true
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
        FileResult::Loaded { snapshot, .. } => Snapshot::hand_out(Snapshot::loaded(snapshot)),
        FileResult::Saved(_)
        | FileResult::Stamped(_)
        | FileResult::NotLoaded(_)
        | FileResult::NotSaved(_)
        | FileResult::Listed(_)
        | FileResult::NotListed(_)
        | FileResult::Made
        | FileResult::NotMade(_)
        | FileResult::Appended
        | FileResult::NotAppended(_)
        | FileResult::Removed
        | FileResult::NotRemoved(_) => ptr::null_mut(),
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

/// The failure of an unobserved file request as it crosses the boundary:
/// one record, filled in one call ([`editor_ffi_files_failure`]).
#[repr(C)]
pub struct RawFileFailure {
    /// The path the request was about: a buffer of `path_len` bytes, as it
    /// was asked for, with no encoding, owned by the caller until it is
    /// handed back with
    /// [`editor_ffi_text_free`](crate::text::editor_ffi_text_free).
    pub path: *mut u8,
    /// The length of `path` in bytes.
    pub path_len: usize,
    /// Why it failed, for a person: a buffer of `detail_len` bytes of
    /// UTF-8, owned by the caller until it is handed back the same way.
    pub detail: *mut u8,
    /// The length of `detail` in bytes.
    pub detail_len: usize,
}

/// Hands over the oldest failure of an unobserved file request, once:
/// fills `out` and returns true, or returns false, with `out` untouched,
/// when none is kept.
///
/// # Safety
///
/// `out` points to a writable [`RawFileFailure`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_files_failure(out: *mut RawFileFailure) -> bool {
    let Some(failure) = FILES.take_failure() else {
        return false;
    };
    let (path, path_len) = words::lend(failure.path.into_os_string().into_vec());
    let (detail, detail_len) = text::lend(failure.detail);
    let raw = RawFileFailure {
        path,
        path_len,
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

/// Asks the process's file service for the request `id` to be completed
/// once every file request started before this call, observed or
/// unobserved, has been worked, and returns whether it was accepted. It
/// returns at once and never blocks.
///
/// The completion is one [`EventKind::Completion`] on the completion queue,
/// from the library source [`SERVICE`], whose code is `id`, queued behind
/// the completions of the requests it waited for. It keeps no result:
/// there is nothing to take. Cancelling it with [`editor_ffi_files_cancel`]
/// while it waits withdraws it.
///
/// Returns false, starting nothing, if `id` is in use, or if the operating
/// system refused the service its thread.
///
/// [`EventKind::Completion`]: crate::events::EventKind::Completion
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_files_flush(id: u64) -> bool {
    service_started() && FILES.flush(id)
}

/// Asks the process's file service to hold its worker, as the request
/// `id`, and returns whether it was accepted ([`Files::hold`]): once the
/// worker reaches it, behind every file request started before it, `id` is
/// completed on the completion queue as [`editor_ffi_files_flush`]'s is,
/// and the worker works nothing more until [`editor_ffi_files_cancel`] is
/// called with `id`. It returns at once and never blocks. A control for
/// tests, which the editor never asks for.
///
/// Returns false, starting nothing, if `id` is in use, or if the operating
/// system refused the service its thread.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_files_hold(id: u64) -> bool {
    service_started() && FILES.hold(id)
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
    use std::thread::ThreadId;
    use std::time::Duration;

    use editor_service::Worker;

    use editor_text::Text;
    use editor_text::fs::{Entry, FakeFs, Kind};

    use super::*;

    /// hang guard: the next completion of the service, or the release a held test gives; only a hang reaches the bound, and the test then fails as a hang. Each wait on it is for something that
    /// should happen at once.
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
        /// The thread the loop runs on, stopped and joined when the rig is
        /// dropped, a panicking test's rig included.
        service: Worker,
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
            let service = Worker::spawn(
                "editor-files-test",
                {
                    let files = Arc::clone(&files);
                    move || files.stop()
                },
                {
                    let files = Arc::clone(&files);
                    move || {
                        files.run(|id| {
                            let _ = done.send(id);
                        });
                    }
                },
            )
            .expect("the service's thread starts");
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

        /// Stops the service and joins its loop's thread; panics if the
        /// loop panicked. A rig that is dropped does the same, and ignores
        /// a panic.
        fn stop(self) {
            self.service.join().expect("the service loop returns");
        }
    }

    #[test]
    fn requests_come_out_in_the_order_they_were_started() {
        let mut requests = Requests::new();

        assert!(requests.start(7, "seven"));
        assert!(requests.start(3, "three"));
        assert!(requests.start(5, "five"));

        assert_eq!(requests.pending(), 3);
        assert_eq!(requests.take_next(), Some((Some(7), Queued::Work("seven"))));
        assert_eq!(requests.take_next(), Some((Some(3), Queued::Work("three"))));
        assert_eq!(requests.take_next(), Some((Some(5), Queued::Work("five"))));
        assert_eq!(requests.take_next(), None);
        assert_eq!(requests.pending(), 0);
    }

    #[test]
    fn unobserved_requests_come_out_in_order_with_observed_ones_and_hold_no_id() {
        let mut requests = Requests::new();

        assert!(requests.start(7, "seven"));
        requests.start_unobserved("first unobserved");
        assert!(requests.start(3, "three"));
        requests.start_unobserved("second unobserved");

        assert_eq!(requests.pending(), 4);
        // No id is taken by one, and none cancels one.
        assert!(!requests.cancel(0));
        assert_eq!(requests.take_next(), Some((Some(7), Queued::Work("seven"))));
        assert_eq!(
            requests.take_next(),
            Some((None, Queued::Work("first unobserved")))
        );
        assert_eq!(requests.take_next(), Some((Some(3), Queued::Work("three"))));
        assert_eq!(
            requests.take_next(),
            Some((None, Queued::Work("second unobserved")))
        );
        assert_eq!(requests.take_next(), None);
    }

    #[test]
    fn a_request_whose_id_is_waiting_is_refused_and_the_one_waiting_is_as_it_was() {
        let mut requests = Requests::new();
        assert!(requests.start(7, "first"));

        assert!(!requests.start(7, "second"));

        assert!(requests.holds(7));
        assert_eq!(requests.take_next(), Some((Some(7), Queued::Work("first"))));
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
        assert_eq!(requests.take_next(), Some((Some(1), Queued::Work("one"))));
        assert_eq!(requests.take_next(), Some((Some(3), Queued::Work("three"))));
        assert_eq!(requests.take_next(), None);
    }

    #[test]
    fn a_flush_comes_out_of_the_requests_in_order_with_work_and_holds_its_id() {
        let mut requests = Requests::new();

        assert!(requests.start(7, "seven"));
        requests.start_unobserved("unobserved");
        assert!(requests.start_flush(1));
        assert!(requests.start(3, "three"));

        // Its id is in use while it waits, for a flush and a request alike.
        assert!(requests.holds(1));
        assert!(!requests.start_flush(1));
        assert!(!requests.start(1, "one"));
        assert!(!requests.start_flush(7));
        assert_eq!(requests.pending(), 4);
        assert_eq!(requests.take_next(), Some((Some(7), Queued::Work("seven"))));
        assert_eq!(
            requests.take_next(),
            Some((None, Queued::Work("unobserved")))
        );
        assert_eq!(requests.take_next(), Some((Some(1), Queued::Flush)));
        assert_eq!(requests.take_next(), Some((Some(3), Queued::Work("three"))));
        assert_eq!(requests.take_next(), None);
    }

    #[test]
    fn a_flush_cancelled_while_it_waits_is_never_completed() {
        let mut requests = Requests::new();
        assert!(requests.start(7, "seven"));
        assert!(requests.start_flush(1));

        assert!(requests.cancel(1));
        assert!(!requests.cancel(1));

        assert_eq!(requests.take_next(), Some((Some(7), Queued::Work("seven"))));
        assert_eq!(requests.take_next(), None);
    }

    /// The worker is held inside load 1 while an unobserved append, a stamp
    /// and a flush are queued behind it. The held worker is the only thing
    /// that completes anything, so a flush completed at its call, or ahead
    /// of the work queued before it, is seen every time.
    #[test]
    fn a_flush_is_completed_only_once_every_request_started_before_it_is_worked() {
        let rig = Rig::over(fake());
        let parked = rig.park();
        assert!(rig.files.start_load(1, FILE.into(), NO_LIMIT));
        parked.entered();
        rig.files.append_unobserved(OTHER.into(), b"more".to_vec());
        assert!(rig.files.start_stamp(2, FILE.into()));
        assert!(rig.files.flush(3));
        // Its id is in use while it waits.
        assert!(!rig.files.flush(3));
        assert!(!rig.files.start_load(3, FILE.into(), NO_LIMIT));

        assert!(rig.completed.try_recv().is_err());
        parked.release();

        assert_eq!([rig.next(), rig.next()], [1, 2]);
        // The flush's completion is the next; the append was worked by then.
        assert_eq!(rig.next(), 3);
        assert_eq!(
            rig.fs().bytes(OTHER).as_deref(),
            Some(&b"the other file\nmore"[..])
        );
        // It keeps no result, and once completed its id is free.
        assert!(rig.files.take(3).is_none());
        assert!(rig.files.take(1).is_some());
        assert!(rig.files.take(2).is_some());
        assert_eq!(rig.files.pending(), 0);
        assert!(rig.files.flush(3));
        assert_eq!(rig.next(), 3);
        rig.stop();
    }

    #[test]
    fn a_flush_cancelled_while_it_waits_behind_work_is_never_completed() {
        let rig = Rig::over(fake());
        let parked = rig.park();
        assert!(rig.files.start_load(1, FILE.into(), NO_LIMIT));
        parked.entered();
        assert!(rig.files.flush(2));

        assert_eq!(rig.files.pending(), 2);
        assert!(rig.files.cancel(2));
        assert!(!rig.files.cancel(2));
        parked.release();

        assert_eq!(rig.next(), 1);
        rig.nothing_else_completed(3);
        assert!(rig.files.take(1).is_some());
        assert_eq!(rig.files.pending(), 0);
        rig.stop();
    }

    /// The worker is parked in load 1 while a hold, a stamp and a flush are
    /// queued behind it. Once the load is let go, the worker reaches the
    /// hold, completes it, and parks: the stamp's hook, run when the stamp
    /// reaches the file system, records whether the hold had been cancelled
    /// by then. The order of completions is forced by the parked load. That
    /// the stamp waits for the cancel was seen to bite once by hand, with a
    /// hold that completed and did not park: a broken hold lets the stamp
    /// run at a time no test can order, so it fails only most times.
    #[test]
    fn a_hold_is_completed_when_the_worker_reaches_it_and_nothing_behind_it_is_worked_until_it_is_cancelled()
     {
        let rig = Rig::over(fake());
        let parked = rig.park();
        assert!(rig.files.start_load(1, FILE.into(), NO_LIMIT));
        parked.entered();
        assert!(rig.files.hold(2));
        // Its id is in use while it waits and while it holds.
        assert!(!rig.files.hold(2));
        assert!(!rig.files.start_load(2, FILE.into(), NO_LIMIT));
        assert!(rig.files.start_stamp(3, FILE.into()));
        assert!(rig.files.flush(4));
        parked.release();
        assert_eq!([rig.next(), rig.next()], [1, 2]);

        let released = Arc::new(AtomicBool::new(false));
        let (seen, saw) = mpsc::channel();
        rig.fs().on_next_call({
            let released = Arc::clone(&released);
            move |_| {
                let _ = seen.send(released.load(Ordering::SeqCst));
            }
        });
        assert!(!rig.files.flush(2));
        // The hold, the stamp and the flush, and the load's result.
        assert_eq!(rig.files.pending(), 4);
        released.store(true, Ordering::SeqCst);
        assert!(rig.files.cancel(2));
        assert!(!rig.files.cancel(2));

        assert_eq!([rig.next(), rig.next()], [3, 4]);
        assert_eq!(saw.recv_timeout(DEADLINE), Ok(true));
        // A hold keeps no result, and once let go its id is free.
        assert!(rig.files.take(2).is_none());
        assert!(rig.files.take(1).is_some());
        assert!(rig.files.take(3).is_some());
        assert_eq!(rig.files.pending(), 0);
        rig.nothing_else_completed(2);
        rig.stop();
    }

    #[test]
    fn a_hold_cancelled_while_it_waits_is_never_completed_and_holds_nothing() {
        let rig = Rig::over(fake());
        let parked = rig.park();
        assert!(rig.files.start_load(1, FILE.into(), NO_LIMIT));
        parked.entered();
        assert!(rig.files.hold(2));
        assert!(rig.files.cancel(2));
        parked.release();

        assert_eq!(rig.next(), 1);
        rig.nothing_else_completed(3);
        assert!(rig.files.take(1).is_some());
        assert_eq!(rig.files.pending(), 0);
        rig.stop();
    }

    #[test]
    fn stop_ends_a_hold() {
        let rig = Rig::over(fake());
        assert!(rig.files.hold(1));
        assert_eq!(rig.next(), 1);

        // The loop returns: the hold does not keep it past a stop.
        rig.stop();
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
    fn a_stamp_answers_what_editor_text_answers_for_that_path() {
        let asked = [FILE, OTHER, MISSING, "/dir", "relative.txt"];
        let mut answers = Vec::new();
        for path in asked {
            let fs = fake();
            fs.directory("/dir");
            let rig = Rig::over(fs);

            assert!(rig.files.start_stamp(1, path.into()));
            assert_eq!(rig.next(), 1);
            let Some(answer) = rig.files.take(1) else {
                panic!("no result was kept for {path}");
            };

            let reference = fake();
            reference.directory("/dir");
            let expected = FileResult::from(file::stamp(&reference, Path::new(path)));
            assert_eq!(said(&answer), said(&expected), "{path}");
            assert!(
                rig.files
                    .fs()
                    .calls()
                    .iter()
                    .all(|call| call.op() == editor_text::fs::Op::Stat),
                "{path}"
            );
            answers.push(said(&answer));
            rig.stop();
        }
        // The five answers differ, so the path was the one forwarded.
        for (index, one) in answers.iter().enumerate() {
            for other in &answers[index + 1..] {
                assert_ne!(one, other);
            }
        }
    }

    #[test]
    fn a_stamp_is_worked_in_order_with_loads_and_saves() {
        let rig = Rig::over(fake());
        let parked = rig.park();
        assert!(rig.files.start_load(1, OTHER.into(), NO_LIMIT));
        parked.entered();
        assert!(
            rig.files
                .start_save(2, snapshot("saved first\n"), FILE.into(), Expect::Whatever)
        );
        assert!(rig.files.start_stamp(3, FILE.into()));
        parked.release();

        assert_eq!([rig.next(), rig.next(), rig.next()], [1, 2, 3]);
        let Some(FileResult::Saved(saved)) = rig.files.take(2) else {
            panic!("the save did not save");
        };
        // The stamp is the saved file's: it was worked after the save.
        let Some(FileResult::Stamped(stamped)) = rig.files.take(3) else {
            panic!("the stamp did not answer one");
        };
        assert_eq!(stamped, Some(saved));
        rig.stop();
    }

    #[test]
    fn a_stamp_cancelled_while_it_waits_is_never_worked_and_never_completed() {
        let rig = Rig::over(fake());
        let parked = rig.park();
        assert!(rig.files.start_load(1, OTHER.into(), NO_LIMIT));
        parked.entered();
        assert!(rig.files.start_stamp(2, FILE.into()));

        assert!(rig.files.cancel(2));
        parked.release();

        assert_eq!(rig.next(), 1);
        rig.nothing_else_completed(3);
        assert!(rig.files.take(2).is_none());
        rig.stop();
    }

    #[test]
    fn a_directory_made_answers_what_editor_text_answers_for_that_path() {
        let asked = ["/dir/made/deep", FILE, "relative"];
        let mut answers = Vec::new();
        for path in asked {
            let rig = Rig::over(fake());

            assert!(rig.files.start_make_directory(1, path.into()));
            assert_eq!(rig.next(), 1);
            let Some(answer) = rig.files.take(1) else {
                panic!("no result was kept for {path}");
            };

            let expected = FileResult::from(file::make_directory(&fake(), Path::new(path)));
            assert_eq!(said(&answer), said(&expected), "{path}");
            answers.push(said(&answer));
            rig.stop();
        }
        // The three answers differ, so the path was the one forwarded.
        for (index, one) in answers.iter().enumerate() {
            for other in &answers[index + 1..] {
                assert_ne!(one, other);
            }
        }
    }

    #[test]
    fn a_directory_made_crosses_as_done_with_no_words_and_a_refused_one_as_its_status() {
        assert_eq!(FileResult::Made.encoded(), Encoded::bare(FileStatus::Done));
        let denied = FsError::new(FsErrorKind::Denied, "os error 13");
        let other = FsError::new(FsErrorKind::Other, "the disk is on fire");
        let table = [
            (
                MakeDirectoryError::Relative,
                Encoded::bare(FileStatus::Relative),
            ),
            (
                MakeDirectoryError::NotADirectory,
                Encoded::bare(FileStatus::NotADirectory),
            ),
            (
                MakeDirectoryError::Fs(denied),
                Encoded {
                    detail: String::from("os error 13"),
                    ..Encoded::bare(FileStatus::Denied)
                },
            ),
            (
                MakeDirectoryError::Fs(other.clone()),
                Encoded {
                    detail: other.to_string(),
                    ..Encoded::bare(FileStatus::Failed)
                },
            ),
        ];

        for (error, expected) in table {
            assert_eq!(FileResult::NotMade(error).encoded(), expected);
        }
    }

    #[test]
    fn a_listing_answers_what_editor_text_answers_for_that_path() {
        let asked = ["/dir", FILE, MISSING, "relative"];
        let mut answers = Vec::new();
        for path in asked {
            let rig = Rig::over(fake());

            assert!(rig.files.start_list(1, path.into()));
            assert_eq!(rig.next(), 1);
            let Some(answer) = rig.files.take(1) else {
                panic!("no result was kept for {path}");
            };

            let expected = FileResult::from(file::list(&fake(), Path::new(path)));
            assert_eq!(said(&answer), said(&expected), "{path}");
            answers.push(said(&answer));
            rig.stop();
        }
        // The four answers differ, so the path was the one forwarded.
        for (index, one) in answers.iter().enumerate() {
            for other in &answers[index + 1..] {
                assert_ne!(one, other);
            }
        }
    }

    #[test]
    fn a_listing_crosses_as_its_count_each_kind_and_name_length_and_the_names() {
        let entry = |name: &[u8], kind| Entry {
            name: OsStr::from_bytes(name).to_os_string(),
            kind,
        };
        let listed = FileResult::Listed(vec![
            entry(b"notes", Kind::Directory),
            entry("caf\u{e9}.txt".as_bytes(), Kind::File),
            // Not UTF-8: Lean cannot name it, so it is left out.
            entry(b"bad\xFF", Kind::File),
            entry(b"fifo", Kind::Other),
        ]);

        assert_eq!(
            listed.encoded(),
            Encoded {
                status: FileStatus::Listed,
                words: vec![3, 1, 5, 0, 9, 2, 4],
                detail: String::from("notescaf\u{e9}.txtfifo"),
            }
        );
        assert_eq!(
            FileResult::Listed(Vec::new()).encoded(),
            Encoded {
                words: vec![0],
                ..Encoded::bare(FileStatus::Listed)
            }
        );
    }

    #[test]
    fn a_refused_listing_crosses_as_its_status() {
        let denied = FsError::new(FsErrorKind::Denied, "os error 13");
        let other = FsError::new(FsErrorKind::Other, "the disk is on fire");
        let table = [
            (ListError::Relative, Encoded::bare(FileStatus::Relative)),
            (ListError::NotFound, Encoded::bare(FileStatus::NotFound)),
            (
                ListError::NotADirectory,
                Encoded::bare(FileStatus::NotADirectory),
            ),
            (
                ListError::Fs(denied),
                Encoded {
                    detail: String::from("os error 13"),
                    ..Encoded::bare(FileStatus::Denied)
                },
            ),
            (
                ListError::Fs(other.clone()),
                Encoded {
                    detail: other.to_string(),
                    ..Encoded::bare(FileStatus::Failed)
                },
            ),
        ];

        for (error, expected) in table {
            assert_eq!(FileResult::NotListed(error).encoded(), expected);
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
                FileResult::Stamped(Some(stamp)),
                FileStatus::Done,
                vec![1, before_1970, 999_999_999, 42],
                String::new(),
            ),
            (
                FileResult::Stamped(None),
                FileStatus::Done,
                vec![0, 0, 0, 0],
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
            FileStatus::NotADirectory,
            FileStatus::Listed,
        ]
        .map(FileStatus::code);

        assert_eq!(codes, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
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
    fn an_append_answers_what_editor_text_answers_for_that_path_and_those_bytes() {
        let asked = [FILE, "/dir/new.txt", "/nowhere/log", "/dir", "relative"];
        for bytes in [&b"more\r\n"[..], b"\xFFother"] {
            for path in asked {
                let rig = Rig::over(fake());

                assert!(rig.files.start_append(1, path.into(), bytes.to_vec()));
                assert_eq!(rig.next(), 1);
                let Some(answer) = rig.files.take(1) else {
                    panic!("no result was kept for {path}");
                };

                let reference = fake();
                let expected = FileResult::from(file::append(&reference, Path::new(path), bytes));
                assert_eq!(said(&answer), said(&expected), "{path}");
                // The path and the bytes were the ones forwarded.
                assert_eq!(rig.fs().paths(), reference.paths(), "{path}");
                for held in reference.paths() {
                    assert_eq!(rig.fs().bytes(&held), reference.bytes(&held), "{path}");
                }
                rig.stop();
            }
        }
    }

    #[test]
    fn a_remove_answers_what_editor_text_answers_for_that_path() {
        for path in [FILE, OTHER, MISSING, "/dir", "relative"] {
            let rig = Rig::over(fake());

            assert!(rig.files.start_remove(1, path.into()));
            assert_eq!(rig.next(), 1);
            let Some(answer) = rig.files.take(1) else {
                panic!("no result was kept for {path}");
            };

            let reference = fake();
            let expected = FileResult::from(file::remove(&reference, Path::new(path)));
            assert_eq!(said(&answer), said(&expected), "{path}");
            assert_eq!(rig.fs().paths(), reference.paths(), "{path}");
            rig.stop();
        }
    }

    #[test]
    fn an_append_and_a_remove_cross_as_done_with_no_words_and_a_refusal_as_its_status() {
        assert_eq!(
            FileResult::Appended.encoded(),
            Encoded::bare(FileStatus::Done)
        );
        assert_eq!(
            FileResult::Removed.encoded(),
            Encoded::bare(FileStatus::Done)
        );
        let denied = FsError::new(FsErrorKind::Denied, "os error 13");
        let other = FsError::new(FsErrorKind::Other, "the disk is on fire");
        let failed = Encoded {
            detail: other.to_string(),
            ..Encoded::bare(FileStatus::Failed)
        };
        let not_allowed = Encoded {
            detail: String::from("os error 13"),
            ..Encoded::bare(FileStatus::Denied)
        };
        let appends = [
            (AppendError::Relative, Encoded::bare(FileStatus::Relative)),
            (AppendError::NotFound, Encoded::bare(FileStatus::NotFound)),
            (AppendError::NotAFile, Encoded::bare(FileStatus::NotAFile)),
            (AppendError::Fs(denied.clone()), not_allowed.clone()),
            (AppendError::Fs(other.clone()), failed.clone()),
        ];
        for (error, expected) in appends {
            assert_eq!(FileResult::NotAppended(error).encoded(), expected);
        }
        let removes = [
            (RemoveError::Relative, Encoded::bare(FileStatus::Relative)),
            (RemoveError::NotAFile, Encoded::bare(FileStatus::NotAFile)),
            (RemoveError::Fs(denied), not_allowed),
            (RemoveError::Fs(other), failed),
        ];
        for (error, expected) in removes {
            assert_eq!(FileResult::NotRemoved(error).encoded(), expected);
        }
    }

    #[test]
    fn unobserved_requests_are_worked_in_order_with_observed_ones_and_never_completed() {
        let rig = Rig::over(fake());
        let parked = rig.park();
        assert!(rig.files.start_load(1, OTHER.into(), NO_LIMIT));
        parked.entered();
        rig.files.append_unobserved(FILE.into(), b"more".to_vec());
        assert!(rig.files.start_stamp(2, FILE.into()));
        rig.files.remove_unobserved(FILE.into());
        assert!(rig.files.start_stamp(3, FILE.into()));
        parked.release();

        // Only the observed ones are completed, in order.
        assert_eq!([rig.next(), rig.next(), rig.next()], [1, 2, 3]);
        rig.nothing_else_completed(4);
        // The stamp asked after the append is of the file with the bytes
        // added, and the one asked after the remove finds nothing.
        let Some(FileResult::Stamped(appended)) = rig.files.take(2) else {
            panic!("the stamp after the append did not answer one");
        };
        assert_eq!(
            appended.map(|stamp| stamp.size),
            Some(BYTES.len() as u64 + 4)
        );
        assert!(matches!(rig.files.take(3), Some(FileResult::Stamped(None))));
        assert!(rig.files.take_failure().is_none());
        rig.stop();
    }

    #[test]
    fn an_unobserved_request_that_fails_is_kept_as_its_path_and_detail_and_taken_once() {
        let rig = Rig::over(fake());

        rig.files
            .append_unobserved("/nowhere/log".into(), b"lost".to_vec());
        rig.files.remove_unobserved("relative".into());
        rig.files
            .save_unobserved(snapshot("never saved"), "/dir".into());
        // One that does not fail keeps nothing.
        rig.files.remove_unobserved(MISSING.into());
        rig.nothing_else_completed(1);

        let failures: Vec<Failure> = std::iter::from_fn(|| rig.files.take_failure()).collect();
        let reference = fake();
        let saved = file::save(
            &reference,
            Path::new("/dir"),
            &snapshot("never saved"),
            Expect::Whatever,
            &never,
        );
        let Err(not_saved) = saved else {
            panic!("a save over a directory saved");
        };
        assert_eq!(
            failures,
            [
                Failure {
                    path: "/nowhere/log".into(),
                    detail: AppendError::NotFound.to_string(),
                },
                Failure {
                    path: "relative".into(),
                    detail: RemoveError::Relative.to_string(),
                },
                Failure {
                    path: "/dir".into(),
                    detail: not_saved.to_string(),
                },
            ]
        );
        // Taken once.
        assert!(rig.files.take_failure().is_none());
        rig.stop();
    }

    #[test]
    fn pending_counts_an_unobserved_request_while_it_waits_or_is_worked_and_falls_to_0() {
        let rig = Rig::over(fake());
        let parked = rig.park();
        rig.files.append_unobserved(FILE.into(), b"more".to_vec());
        parked.entered();

        assert_eq!(rig.files.pending(), 1);
        rig.files.remove_unobserved(OTHER.into());
        assert_eq!(rig.files.pending(), 2);
        parked.release();

        rig.nothing_else_completed(1);
        assert_eq!(rig.files.pending(), 0);
        rig.stop();
    }

    #[test]
    fn an_unobserved_save_writes_what_editor_text_writes_expecting_whatever() {
        let rig = Rig::over(fake());
        let new = snapshot("the session, saved\n");

        rig.files.save_unobserved(new.clone(), FILE.into());
        rig.nothing_else_completed(1);

        let reference = fake();
        let _ = file::save(&reference, Path::new(FILE), &new, Expect::Whatever, &never);
        assert_eq!(rig.fs().bytes(FILE), reference.bytes(FILE));
        assert_ne!(rig.fs().bytes(FILE).as_deref(), Some(BYTES));
        assert_eq!(rig.fs().paths(), reference.paths());
        assert!(rig.files.take_failure().is_none());
        rig.stop();
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

    #[test]
    fn a_rig_left_by_a_panicking_test_stops_and_joins_its_loop() {
        let mut kept = None;
        let unwound = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let rig = Rig::over(fake());
            kept = Some(Arc::downgrade(&rig.files));
            panic!("a test failed with its rig running");
        }));
        assert!(unwound.is_err());

        // The loop's thread held the other owner of the service: it has
        // returned once the rig is dropped.
        let kept = kept.expect("the rig was built");
        assert!(
            kept.upgrade().is_none(),
            "the rig's loop was still running after the test unwound"
        );
    }
}
