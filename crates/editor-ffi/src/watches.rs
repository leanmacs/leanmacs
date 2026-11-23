//! The watch service: watches on files and directories, their changes
//! coalesced and delivered a read at a time through the completion queue.
//!
//! This is the fourth service behind the completion queue, in the shape of
//! the process service (the crate docs, "Services and completions"). A job
//! in Lean starts a watch with an id ([`editor_ffi_watches_start`]); it
//! returns at once, and once the watch is registered, or refused, the
//! service queues an
//! [`EventKind::Completion`](crate::events::EventKind::Completion) whose code
//! is the id, and the job takes the reply once
//! ([`editor_ffi_watches_take`]). The id names the watch from then on: each
//! [`editor_ffi_watches_next`] is a wait with an id of its own, completed
//! once, when a delivery can be taken. Rust never calls Lean.
//!
//! Every rule of the service (a file watched through its directory, the
//! coalescing window and the bound, what cancelling means, that shutdown
//! drops every registration) is `editor-watch`'s
//! ([`editor_watch::service::Service`]), pinned there on the port's fake
//! and, by the contract, on real files. This module only reads a start,
//! forwards, and lays a reply out.
//!
//! The process has one service, over the machine's watch
//! (`editor_watch_notify::NotifyWatch`) and the job clock
//! ([`Monotonic`]), in a static made on its first use. That static is the
//! one place in this crate's sources that makes the adapter: the crate's
//! `clippy.toml` refuses its constructor everywhere else, so the unit tests
//! below run on the fake and watch no file.
//!
//! # How a start crosses
//!
//! Three words, then the path's bytes, UTF-8:
//!
//! | Word | Is |
//! |---|---|
//! | the target | 0 a file, 1 a directory's entries, 2 a directory's tree |
//! | the window | in milliseconds |
//! | the bound | how many distinct paths a delivery may hold |
//!
//! Words that are not exactly three, a target that is none of these, a
//! bound no `usize` holds and a path that is not UTF-8 are refused: the
//! watch is not started and the call returns false.
//!
//! # How a reply crosses
//!
//! [`editor_ffi_watches_take`] fills a [`RawWatchReply`]: a status, words,
//! a detail and one buffer of paths, each a buffer the caller hands back
//! with [`editor_ffi_text_free`](crate::text::editor_ffi_text_free).
//!
//! | Reply | Status | Words | Paths |
//! |---|---|---|---|
//! | Started | 0 | | |
//! | Not absolute | 1 | | |
//! | Not found | 2 | | |
//! | Not a directory | 3 | | |
//! | Denied | 4 | | |
//! | The system's limit on watches | 5 | | |
//! | Shut down | 6 | | |
//! | Failed | 7 | | |
//! | Changes | 8 | the count, then for each change its path's length in bytes and its kinds' bits (created 1, written 2, renamed 4, removed 8, missed 16) | the paths, end to end |
//!
//! A refusal carries its detail, naming the path. A path is its bytes as
//! the platform gave them, which on Linux need not be UTF-8: the Lean side
//! decides what such a path is.
//!
//! # The C functions
//!
//! | Function | Does |
//! |---|---|
//! | [`editor_ffi_watches_start`] | Starts a watch. False, starting nothing, for words that spell no start, an id in use, or when the system refuses the start its thread |
//! | [`editor_ffi_watches_next`] | Asks for a watch's next delivery, under a wait id of its own. False for a watch that is not live, one with a read pending, or a wait id in use |
//! | [`editor_ffi_watches_take`] | Fills a [`RawWatchReply`] and returns true, or returns false when nothing is kept for the wait |
//! | [`editor_ffi_watches_flush`] | Asks for an id to be completed once every start asked before it has returned from the port; keeps no reply. False for an id in use |
//! | [`editor_ffi_watches_cancel`] | Cancels a watch, dropping its registration once no other watch shares it, or a wait |
//! | [`editor_ffi_watches_pending`] | Watches starting or live, and waits not answered or not taken. A readout for tests |
//! | [`editor_ffi_watches_shutdown`] | Ends every watch; a later start is refused as shut down |

use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt as _;
use std::path::PathBuf;
use std::sync::LazyLock;

use editor_watch::service::{Coalescing, Service, Target, WatchReply};
use editor_watch::{Depth, RefusalKind};
use editor_watch_notify::NotifyWatch;

use crate::events;
use crate::text;
use crate::timers::Monotonic;
use crate::words::{self, Reader, Writer};

/// The id of the watch service as an event's source: a completion of a
/// start or a read comes from the library source with this id.
pub const SERVICE: u64 = 4;

impl editor_watch::clock::Clock for Monotonic {
    fn now_ms(&self) -> u64 {
        crate::timers::Clock::now_ms(self)
    }
}

/// The process's watch service, over the machine's watch and the job
/// clock. It is made on its first use, by a start or by shutdown.
#[expect(
    clippy::disallowed_methods,
    reason = "the process's watch service is over the real watch; this static is the one place in the crate's sources that makes the adapter"
)]
static WATCHES: LazyLock<Service<NotifyWatch, Monotonic>> = LazyLock::new(|| {
    Service::new(NotifyWatch::system(), Monotonic::new(), |id| {
        events::complete(SERVICE, id);
    })
});

/// The target and the coalescing that `words` and `path` spell, in the
/// layout the module docs give. `None` when they spell none.
pub fn start_of(words: &[u8], path: &[u8]) -> Option<(Target, Coalescing)> {
    let path = PathBuf::from(std::str::from_utf8(path).ok()?);
    let mut reader = Reader::new(words)?;
    let target = reader.word()?;
    let window_ms = reader.word()?;
    let bound = usize::try_from(reader.word()?).ok()?;
    reader.finish()?;
    let target = match target {
        0 => Target::File(path),
        1 => Target::Directory(path, Depth::Entries),
        2 => Target::Directory(path, Depth::Tree),
        _ => return None,
    };
    Some((target, Coalescing { window_ms, bound }))
}

/// A reply, laid out as it crosses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Encoded {
    /// The status.
    pub status: u64,
    /// The words.
    pub words: Vec<u64>,
    /// The detail: empty but for a refusal.
    pub detail: String,
    /// The paths of the changes, end to end.
    pub paths: Vec<u8>,
}

/// The status of a refusal of `kind`.
///
/// The match on `editor-watch`'s [`RefusalKind`] is exhaustive on purpose:
/// every refusal must cross as a status of its own, so a new kind must be
/// given one here.
const fn refusal_status(kind: RefusalKind) -> u64 {
    match kind {
        RefusalKind::NotAbsolute => 1,
        RefusalKind::NotFound => 2,
        RefusalKind::NotADirectory => 3,
        RefusalKind::Denied => 4,
        RefusalKind::Limit => 5,
        RefusalKind::ShutDown => 6,
        RefusalKind::Failed => 7,
    }
}

/// `reply` laid out as it crosses.
pub fn encoded(reply: WatchReply) -> Encoded {
    match reply {
        WatchReply::Started => Encoded {
            status: 0,
            words: Vec::new(),
            detail: String::new(),
            paths: Vec::new(),
        },
        WatchReply::Refused(refusal) => Encoded {
            status: refusal_status(refusal.kind),
            words: Vec::new(),
            detail: refusal.detail,
            paths: Vec::new(),
        },
        WatchReply::Changes(changes) => {
            let mut words = Vec::with_capacity(1 + 2 * changes.len());
            words.push(words::word(changes.len()));
            let mut paths = Vec::new();
            for change in changes {
                let bytes = OsStr::as_bytes(change.path.as_os_str());
                words.push(words::word(bytes.len()));
                words.push(u64::from(change.kinds.bits()));
                paths.extend_from_slice(bytes);
            }
            Encoded {
                status: 8,
                words,
                detail: String::new(),
                paths,
            }
        }
    }
}

/// A reply as it crosses the boundary: one record, filled in one call. The
/// module docs have the table of statuses and words.
#[repr(C)]
pub struct RawWatchReply {
    /// What the reply is.
    pub status: u64,
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
    /// The paths, end to end: a buffer of `paths_len` bytes, owned by the
    /// caller until it is handed back the same way.
    pub paths: *mut u8,
    /// The length of `paths` in bytes.
    pub paths_len: usize,
}

impl RawWatchReply {
    /// The record that lends what `encoded` holds.
    fn lending(encoded: Encoded) -> Self {
        let mut writer = Writer::with_capacity(encoded.words.len());
        for word in encoded.words {
            writer.word(word);
        }
        let (words, words_len) = words::lend(writer.finish());
        let (detail, detail_len) = text::lend(encoded.detail);
        let (paths, paths_len) = words::lend(encoded.paths);
        Self {
            status: encoded.status,
            words,
            words_len,
            detail,
            detail_len,
            paths,
            paths_len,
        }
    }
}

/// Asks the process's watch service to start the watch that the
/// `words_len` bytes at `words` and the `path_len` bytes at `path` spell
/// ([`start_of`]), named `id`, and returns whether it was accepted. It
/// returns at once; its reply, started (status 0) or a refusal, is taken
/// with [`editor_ffi_watches_take`] once `id` is completed. After shutdown
/// a start is accepted, refused as shut down (status 6) and completed at
/// once.
///
/// Returns false, starting nothing, if the words spell no start, if `id`
/// is in use, or if the operating system refused the start its thread.
///
/// # Safety
///
/// `words` points to `words_len` readable bytes and `path` to `path_len`,
/// both unchanged for the call (no bytes at all may be lent with any
/// pointer).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_watches_start(
    id: u64,
    words: *const u8,
    words_len: usize,
    path: *const u8,
    path_len: usize,
) -> bool {
    // SAFETY: the caller guarantees each pointer and its length.
    let (words, path) = unsafe {
        (
            words::borrow(words, words_len),
            words::borrow(path, path_len),
        )
    };
    let Some((target, coalescing)) = start_of(words, path) else {
        return false;
    };
    WATCHES.start(id, target, coalescing)
}

/// Asks for the next delivery of the watch `watch`, under the wait id
/// `wait`, and returns whether it was accepted. The wait is completed once,
/// when a delivery can be taken with [`editor_ffi_watches_take`]: what is
/// taken is every change noticed up to the take.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_watches_next(watch: u64, wait: u64) -> bool {
    WATCHES.next(watch, wait)
}

/// Hands over the reply of the wait `wait`, once: fills `out` and returns
/// true, or returns false, with `out` untouched, when the service keeps
/// nothing for `wait` (it is pending, it was cancelled, it was taken
/// already, or it was another service's id).
///
/// # Safety
///
/// `out` points to a writable [`RawWatchReply`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_watches_take(wait: u64, out: *mut RawWatchReply) -> bool {
    let Some(reply) = WATCHES.take(wait) else {
        return false;
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(RawWatchReply::lending(encoded(reply))) };
    true
}

/// Cancels the watch or the wait `id`, and returns whether there was
/// anything to cancel. Cancelling a watch drops its pending read and its
/// reply not taken, none of them completed, and its registration once no
/// other watch shares it; cancelling a wait drops that wait alone. It is
/// safe for an id that is unknown. A completion already on the queue is
/// still delivered, and the caller ignores it.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_watches_cancel(id: u64) -> bool {
    WATCHES.cancel(id)
}

/// Asks the process's watch service for the wait `id` to be completed once
/// every start asked before this call has returned from the port
/// ([`Service::flush`]), and returns whether it was accepted. It returns at
/// once and never blocks. Its completion is queued from [`SERVICE`] behind
/// those of the starts it waited for, and it keeps no reply. A pending read
/// is not waited for.
///
/// Returns false, starting nothing, if `id` is in use.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_watches_flush(id: u64) -> bool {
    WATCHES.flush(id)
}

/// How many watches are starting or live, and how many waits have not been
/// answered or not taken, a start's among them: all together. A readout
/// for tests, which use it to see that a job's watch did not outlive it.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_watches_pending() -> u64 {
    words::word(WATCHES.pending())
}

/// Ends every watch, dropping every registration once each start in
/// flight has returned; a start asked for later is accepted, refused as
/// shut down (status 6) and completed at once. The editor calls it before
/// it quits; it is safe to call again.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_watches_shutdown() {
    WATCHES.shutdown();
}

#[cfg(test)]
mod tests {
    use editor_wait::HangGuard;
    use std::path::{Path, PathBuf};
    use std::sync::mpsc;
    use std::time::Duration;

    use editor_watch::batch::{Change, Kinds};
    use editor_watch::clock::ManualClock;
    use editor_watch::fake::FakeWatch;
    use editor_watch::service::{Coalescing, Service, Target, WatchReply};
    use editor_watch::{Depth, Kind, Refusal, RefusalKind};

    use super::{Encoded, encoded, start_of};
    use crate::timers::Monotonic;
    use crate::words::tests::buffer;

    /// hang guard: the next completion of the service; only a hang reaches the bound, and the test then fails as a hang.
    const DEADLINE: HangGuard =
        HangGuard::on("the next completion of the service", Duration::from_secs(5));

    fn kinds(of: &[Kind]) -> Kinds {
        of.iter()
            .fold(Kinds::default(), |set, &kind| set.with(kind))
    }

    #[test]
    fn a_start_crosses_as_its_target_window_and_bound_then_the_paths_bytes() {
        let file = start_of(&buffer(&[0, 300, 64]), "/w/é".as_bytes());
        let entries = start_of(&buffer(&[1, 0, 1]), b"/w");
        let tree = start_of(&buffer(&[2, 50, 7]), b"/w");

        let coalescing = |window_ms, bound| Coalescing { window_ms, bound };
        assert_eq!(
            file,
            Some((Target::File(PathBuf::from("/w/é")), coalescing(300, 64)))
        );
        assert_eq!(
            entries,
            Some((
                Target::Directory(PathBuf::from("/w"), Depth::Entries),
                coalescing(0, 1)
            ))
        );
        assert_eq!(
            tree,
            Some((
                Target::Directory(PathBuf::from("/w"), Depth::Tree),
                coalescing(50, 7)
            ))
        );
    }

    #[test]
    fn words_that_spell_no_start_are_refused() {
        assert_eq!(start_of(&buffer(&[3, 0, 1]), b"/w"), None, "no such target");
        assert_eq!(start_of(&buffer(&[0, 0]), b"/w"), None, "too few words");
        assert_eq!(
            start_of(&buffer(&[0, 0, 1, 9]), b"/w"),
            None,
            "too many words"
        );
        assert_eq!(start_of(&[0; 23], b"/w"), None, "not whole words");
        assert_eq!(start_of(&buffer(&[0, 0, 1]), b"/w\xff"), None, "not UTF-8");
    }

    #[test]
    fn a_reply_crosses_as_a_status_words_a_detail_and_the_paths_end_to_end() {
        assert_eq!(
            encoded(WatchReply::Started),
            Encoded {
                status: 0,
                words: Vec::new(),
                detail: String::new(),
                paths: Vec::new(),
            }
        );
        let changes = WatchReply::Changes(vec![
            Change {
                path: PathBuf::from("/w/a"),
                kinds: kinds(&[Kind::Created, Kind::Written]),
            },
            Change {
                path: PathBuf::from("/w/bé"),
                kinds: kinds(&[Kind::Missed]),
            },
        ]);
        assert_eq!(
            encoded(changes),
            Encoded {
                status: 8,
                words: vec![2, 4, 3, 6, 16],
                detail: String::new(),
                paths: "/w/a/w/bé".as_bytes().to_vec(),
            }
        );
    }

    #[test]
    fn each_refusal_crosses_as_its_status_with_its_detail() {
        let statuses: Vec<(u64, String)> = [
            RefusalKind::NotAbsolute,
            RefusalKind::NotFound,
            RefusalKind::NotADirectory,
            RefusalKind::Denied,
            RefusalKind::Limit,
            RefusalKind::ShutDown,
            RefusalKind::Failed,
        ]
        .into_iter()
        .map(|kind| {
            let reply = encoded(WatchReply::Refused(Refusal::new(kind, "why")));
            (reply.status, reply.detail)
        })
        .collect();

        assert_eq!(
            statuses,
            (1..=7)
                .map(|status| (status, "why".to_owned()))
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn a_start_read_from_words_runs_on_the_service_and_its_delivery_crosses() {
        let fake = FakeWatch::new();
        let ground = fake.ground();
        ground.make_dir(Path::new("/w"));
        let (sender, completed) = mpsc::channel();
        let sender = std::sync::Mutex::new(sender);
        let service = Service::new(fake, ManualClock::new(), move |id| {
            sender
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .send(id)
                .ok();
        });
        let (target, coalescing) = start_of(&buffer(&[0, 0, 8]), b"/w/f").expect("a start");

        assert!(service.start(1, target, coalescing));
        assert_eq!(editor_wait::recv(&completed, DEADLINE), Ok(1));
        assert_eq!(
            service.take(1).map(encoded).map(|reply| reply.status),
            Some(0)
        );
        assert!(service.next(1, 2));
        ground.write(Path::new("/w/f"), b"x");
        assert_eq!(editor_wait::recv(&completed, DEADLINE), Ok(2));

        assert_eq!(
            service.take(2).map(encoded),
            Some(Encoded {
                status: 8,
                words: vec![1, 4, 3],
                detail: String::new(),
                paths: b"/w/f".to_vec(),
            })
        );
    }

    #[test]
    fn the_job_clock_is_the_watch_services_clock_and_never_goes_back() {
        let clock = Monotonic::new();

        let first = editor_watch::clock::Clock::now_ms(&clock);
        let second = editor_watch::clock::Clock::now_ms(&clock);

        assert!(second >= first);
        assert_eq!(first, 0, "it begins when it is first read");
    }
}
