//! The grep service: project searches, each on a thread of its own, their
//! matches delivered a read at a time through the completion queue.
//!
//! This is the seventh service behind the completion queue, in the watch
//! service's shape (the crate docs, "Services and completions"). A job in
//! Lean starts a search with an id ([`editor_ffi_grep_start`]); it returns
//! at once, and once the search has its pattern compiled, or is refused,
//! the service queues an
//! [`EventKind::Completion`](crate::events::EventKind::Completion) whose code
//! is the id, and the job takes the reply once ([`editor_ffi_grep_take`]).
//! The id names the search from then on: each [`editor_ffi_grep_next`] is a
//! wait with an id of its own, completed once, when a delivery can be taken.
//! Rust never calls Lean.
//!
//! Every rule of the service (what a delivery holds, back-pressure, the end
//! delivered last, what cancelling means) is `editor-grep`'s
//! ([`editor_grep::service::Service`]), and the rule of a search is
//! [`editor_grep::search`]'s, pinned there on the port's fake and, by the
//! contract and the ignore tests, on real files. This module only reads a
//! start, forwards, and lays a reply out.
//!
//! The process has one service, over the machine's files
//! (`editor_grep_ripgrep::RipgrepFiles`), the real engine
//! ([`RegexEngine`]) and the text's word class
//! ([`editor_text::is_word_character`]), in a static made on its first use.
//! That static is the one place in this crate's sources that makes the
//! adapter: the crate's `clippy.toml` refuses its constructor everywhere
//! else, so the unit tests below run on the fake and read no file.
//!
//! An open buffer's text is handed in as a snapshot handle, which the start
//! clones ([`Snapshot`]'s text; no text is copied), searched in place of its
//! file. Lean resolves each overlay to a handle before it starts, so a
//! snapshot it no longer holds is refused there, and never crosses.
//!
//! # How a start crosses
//!
//! Words, then the strings end to end, UTF-8, then the overlays' snapshot
//! handles, one for each overlay, in order:
//!
//! | Word | Is |
//! |---|---|
//! | the files limit | how many files with a match it answers |
//! | the matches limit | how many matches it answers |
//! | the bound | how many matches a delivery holds |
//! | the root's length | in bytes |
//! | the pattern's length | in bytes |
//! | the overlay count | |
//! | each overlay's path length | in bytes |
//!
//! The strings are the root, the pattern and each overlay's path. Words that
//! do not spell this, lengths that do not add up to the strings, strings
//! that are not UTF-8 and a count of handles that is not the overlay count
//! are refused: the search is not started and the call returns false.
//!
//! # How a reply crosses
//!
//! [`editor_ffi_grep_take`] fills a [`RawGrepReply`]: a status, words, a
//! detail and one buffer of paths, each a buffer the caller hands back with
//! [`editor_ffi_text_free`](crate::text::editor_ffi_text_free).
//!
//! | Reply | Status | Words | Paths |
//! |---|---|---|---|
//! | Started | 0 | | |
//! | Not absolute | 1 | | |
//! | Not found | 2 | | |
//! | Not a directory | 3 | | |
//! | Denied | 4 | | |
//! | Invalid pattern | 5 | | |
//! | Shut down | 6 | | |
//! | Failed | 7 | | |
//! | Found | 8 | the count of files, then for each its path's length, its source (0 disk, 1 buffer) and its match count, then each match's row, start and stop; then the end: 0 more to come, 1 complete or 2 truncated each followed by the files and the matches answered, or 3 refused followed by the refusal's status | the paths, end to end |
//!
//! A refusal carries its detail: for an invalid pattern the sentence the
//! echo area says (`E54: Unmatched \(`), otherwise words naming the root. A
//! found reply whose end is a refusal (the walk refused the root) carries
//! the refusal's detail too.
//!
//! # The C functions
//!
//! | Function | Does |
//! |---|---|
//! | [`editor_ffi_grep_start`] | Starts a search. False, starting nothing, for words that spell no start, an id in use, or when the system refuses the search its thread |
//! | [`editor_ffi_grep_next`] | Asks for a search's next delivery, under a wait id of its own. False for a search that is not held, one with a read pending, or a wait id in use |
//! | [`editor_ffi_grep_take`] | Fills a [`RawGrepReply`] and returns true, or returns false when nothing is kept for the wait |
//! | [`editor_ffi_grep_cancel`] | Cancels a search, which reads nothing more, or a wait |
//! | [`editor_ffi_grep_flush`] | Asks for a wait completed once the thread of every search started before has returned, a cancelled search's among them. False for an id in use |
//! | [`editor_ffi_grep_pending`] | Searches held, and waits not answered or not taken. A readout for tests |
//! | [`editor_ffi_grep_shutdown`] | Ends every search; a later start is refused as shut down |

use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt as _;
use std::path::PathBuf;
use std::sync::LazyLock;

use editor_grep::service::{Reply, Service};
use editor_grep::{Limits, Overlay, Refusal, RefusalKind, Request, Source, Summary, Text};
use editor_grep_ripgrep::RipgrepFiles;
use editor_search_regex::RegexEngine;

use crate::events;
use crate::snapshot::Snapshot;
use crate::text;
use crate::words::{self, Reader, Writer};

/// The id of the grep service as an event's source: a completion of a
/// start or a read comes from the library source with this id.
pub const SERVICE: u64 = 7;

/// The process's grep service, over the machine's files, the real engine
/// and the text's word class. It is made on its first use, by a start or
/// by shutdown.
#[expect(
    clippy::disallowed_methods,
    reason = "the process's grep service is over the real files; this static is the one place in the crate's sources that makes the adapter"
)]
static GREP: LazyLock<Service<RipgrepFiles, RegexEngine>> = LazyLock::new(|| {
    Service::new(
        || (RipgrepFiles::new(), RegexEngine::new()),
        editor_text::is_word_character,
        |id| {
            events::complete(SERVICE, id);
        },
    )
});

/// An open buffer's text, as a snapshot: searched as its chunks, where they
/// lie.
struct Held(editor_text::Snapshot);

impl Text for Held {
    fn pieces(&self) -> Vec<&str> {
        self.0.chunks().collect()
    }
}

/// What a start's words and strings spell, before its overlays' texts are
/// joined to it: the request with no overlays, the overlays' paths, and the
/// bound.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Start {
    /// The root.
    pub root: PathBuf,
    /// The pattern.
    pub pattern: String,
    /// The limits.
    pub limits: Limits,
    /// How many matches a delivery holds.
    pub bound: usize,
    /// Each overlay's path, in order.
    pub overlays: Vec<PathBuf>,
}

/// The start that `words` and `strings` spell, in the layout the module
/// docs give. `None` when they spell none.
pub fn start_of(words: &[u8], strings: &[u8]) -> Option<Start> {
    let mut reader = Reader::new(words)?;
    let files = reader.size()?;
    let matches = reader.size()?;
    let bound = reader.size()?;
    let root_len = reader.size()?;
    let pattern_len = reader.size()?;
    let count = reader.count(1)?;
    let lengths = (0..count)
        .map(|_| reader.size())
        .collect::<Option<Vec<usize>>>()?;
    reader.finish()?;
    let mut rest = strings;
    let mut cut = |len: usize| -> Option<&str> {
        let (head, tail) = rest.split_at_checked(len)?;
        rest = tail;
        std::str::from_utf8(head).ok()
    };
    let root = PathBuf::from(cut(root_len)?);
    let pattern = cut(pattern_len)?.to_owned();
    let overlays = lengths
        .into_iter()
        .map(|len| cut(len).map(PathBuf::from))
        .collect::<Option<Vec<_>>>()?;
    if !rest.is_empty() {
        return None;
    }
    Some(Start {
        root,
        pattern,
        limits: Limits { files, matches },
        bound,
        overlays,
    })
}

impl Start {
    /// The request, each overlay's path joined to the text of the snapshot
    /// in the same place. `None` when the counts differ.
    pub fn request(self, texts: Vec<editor_text::Snapshot>) -> Option<(Request, usize)> {
        if texts.len() != self.overlays.len() {
            return None;
        }
        let overlays = self
            .overlays
            .into_iter()
            .zip(texts)
            .map(|(path, text)| Overlay::new(path, Held(text)))
            .collect();
        Some((
            Request {
                root: self.root,
                pattern: self.pattern,
                overlays,
                limits: self.limits,
            },
            self.bound,
        ))
    }
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
    /// The paths of the files found, end to end.
    pub paths: Vec<u8>,
}

/// The status of a refusal of `kind`.
///
/// The match on `editor-grep`'s [`RefusalKind`] is exhaustive on purpose:
/// every refusal must cross as a status of its own, so a new kind must be
/// given one here.
const fn refusal_status(kind: RefusalKind) -> u64 {
    match kind {
        RefusalKind::NotAbsolute => 1,
        RefusalKind::NotFound => 2,
        RefusalKind::NotADirectory => 3,
        RefusalKind::Denied => 4,
        RefusalKind::Invalid => 5,
        RefusalKind::ShutDown => 6,
        RefusalKind::Failed => 7,
    }
}

/// The words of a summary's end: its word, then its counts.
fn summary_words(end: u64, summary: Summary) -> [u64; 3] {
    [
        end,
        words::word(summary.files),
        words::word(summary.matches),
    ]
}

/// `reply` laid out as it crosses.
pub fn encoded(reply: Reply) -> Encoded {
    match reply {
        Reply::Started => Encoded {
            status: 0,
            words: Vec::new(),
            detail: String::new(),
            paths: Vec::new(),
        },
        Reply::Refused(refusal) => Encoded {
            status: refusal_status(refusal.kind),
            words: Vec::new(),
            detail: refusal.detail,
            paths: Vec::new(),
        },
        Reply::Delivery(delivery) => {
            let mut out = vec![words::word(delivery.found.len())];
            let mut paths = Vec::new();
            for found in &delivery.found {
                let bytes = OsStr::as_bytes(found.path.as_os_str());
                out.push(words::word(bytes.len()));
                out.push(match found.source {
                    Source::Disk => 0,
                    Source::Buffer => 1,
                });
                out.push(words::word(found.matches.len()));
                for each in &found.matches {
                    out.extend([each.row, each.start, each.stop].map(words::word));
                }
                paths.extend_from_slice(bytes);
            }
            let mut detail = String::new();
            match delivery.end {
                None => out.push(0),
                Some(Ok(summary)) if !summary.truncated => {
                    out.extend(summary_words(1, summary));
                }
                Some(Ok(summary)) => out.extend(summary_words(2, summary)),
                Some(Err(Refusal { kind, detail: why })) => {
                    out.extend([3, refusal_status(kind)]);
                    detail = why;
                }
            }
            Encoded {
                status: 8,
                words: out,
                detail,
                paths,
            }
        }
    }
}

/// A reply as it crosses the boundary: one record, filled in one call. The
/// module docs have the table of statuses and words.
#[repr(C)]
pub struct RawGrepReply {
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

impl RawGrepReply {
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

/// Asks the process's grep service to start the search that the
/// `words_len` bytes at `words`, the `strings_len` bytes at `strings` and
/// the `snapshots_len` handles at `snapshots` spell ([`start_of`]), named
/// `id`, and returns whether it was accepted. It returns at once; its
/// reply, started (status 0) or a refusal, is taken with
/// [`editor_ffi_grep_take`] once `id` is completed. Each handle's text is
/// cloned, copying none of it; the handles stay the caller's.
///
/// Returns false, starting nothing, if they spell no start, if `id` is in
/// use, or if the operating system refused the search its thread.
///
/// # Safety
///
/// `words` points to `words_len` readable bytes, `strings` to
/// `strings_len`, and `snapshots` to `snapshots_len` pointers each to a
/// live [`Snapshot`], all unchanged for the call (nothing at all may be lent
/// with any pointer).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_grep_start(
    id: u64,
    words: *const u8,
    words_len: usize,
    strings: *const u8,
    strings_len: usize,
    snapshots: *const *const Snapshot,
    snapshots_len: usize,
) -> bool {
    // SAFETY: the caller guarantees each pointer and its length.
    let (words, strings) = unsafe {
        (
            words::borrow(words, words_len),
            words::borrow(strings, strings_len),
        )
    };
    let handles: &[*const Snapshot] = if snapshots_len == 0 {
        &[]
    } else {
        // SAFETY: the caller guarantees `snapshots_len` pointers.
        unsafe { std::slice::from_raw_parts(snapshots, snapshots_len) }
    };
    // SAFETY: the caller guarantees each handle is live.
    let texts = handles
        .iter()
        .map(|&handle| unsafe { (*handle).text().clone() })
        .collect();
    let Some((request, bound)) = start_of(words, strings).and_then(|start| start.request(texts))
    else {
        return false;
    };
    GREP.start(id, request, bound)
}

/// Asks for the next delivery of the search `id`, under the wait id
/// `wait`, and returns whether it was accepted. The wait is completed once,
/// when a delivery can be taken with [`editor_ffi_grep_take`].
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_grep_next(id: u64, wait: u64) -> bool {
    GREP.next(id, wait)
}

/// Hands over the reply of the wait `wait`, once: fills `out` and returns
/// true, or returns false, with `out` untouched, when the service keeps
/// nothing for `wait` (it is pending, it was cancelled, it was taken
/// already, or it was another service's id).
///
/// # Safety
///
/// `out` points to a writable [`RawGrepReply`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_grep_take(wait: u64, out: *mut RawGrepReply) -> bool {
    let Some(reply) = GREP.take(wait) else {
        return false;
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(RawGrepReply::lending(encoded(reply))) };
    true
}

/// Cancels the search or the wait `id`, and returns whether there was
/// anything to cancel. A cancelled search reads nothing more and completes
/// nothing more. It is safe for an id that is unknown. A completion already
/// on the queue is still delivered, and the caller ignores it.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_grep_cancel(id: u64) -> bool {
    GREP.cancel(id)
}

/// Asks for the request `id` to be completed once the thread of every
/// search started before this call has returned, a cancelled search's
/// among them, and returns whether it was accepted: refused for an id in
/// use. It returns at once and keeps no result; with no search's thread
/// running it is completed at once. `editor_ffi_grep_cancel` withdraws it.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_grep_flush(id: u64) -> bool {
    GREP.flush(id)
}

/// How many searches are held, and how many waits have not been answered
/// or not taken, a start's among them: all together. A readout for tests,
/// which use it to see that a job's search did not outlive it.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_grep_pending() -> u64 {
    words::word(GREP.pending())
}

/// Ends every search, once each search's thread has returned; a start asked
/// for later is accepted, refused as shut down (status 6) and completed at
/// once. The editor calls it before it quits; it is safe to call again.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_grep_shutdown() {
    GREP.shutdown();
}

#[cfg(test)]
mod tests {
    use editor_wait::HangGuard;
    use std::path::PathBuf;
    use std::sync::mpsc;
    use std::time::Duration;

    use editor_grep::fake::FakeFiles;
    use editor_grep::service::{Delivery, Reply, Service};
    use editor_grep::{Found, Limits, Match, Refusal, RefusalKind, Source, Summary};
    use editor_search::Literal;
    use editor_text::Text;

    use super::{Encoded, Start, encoded, start_of};
    use crate::words::tests::buffer;

    /// hang guard: the next completion of the service; only a hang reaches the bound, and the test then fails as a hang.
    const DEADLINE: HangGuard = HangGuard::on(
        "the next completion of the service",
        Duration::from_secs(10),
    );

    /// The words and strings of a start.
    fn spelled(overlays: &[&str]) -> (Vec<u8>, Vec<u8>) {
        let mut words = vec![200, 2000, 64, 2, 3, overlays.len() as u64];
        words.extend(overlays.iter().map(|path| path.len() as u64));
        let mut strings = b"/wpat".to_vec();
        for path in overlays {
            strings.extend_from_slice(path.as_bytes());
        }
        (buffer(&words), strings)
    }

    #[test]
    fn a_start_crosses_as_its_limits_bound_and_lengths_then_its_strings() {
        let (words, strings) = spelled(&["/w/a", "/w/é"]);

        assert_eq!(
            start_of(&words, &strings),
            Some(Start {
                root: PathBuf::from("/w"),
                pattern: "pat".to_owned(),
                limits: Limits {
                    files: 200,
                    matches: 2000
                },
                bound: 64,
                overlays: vec![PathBuf::from("/w/a"), PathBuf::from("/w/é")],
            })
        );
    }

    #[test]
    fn words_that_spell_no_start_are_refused() {
        let (words, strings) = spelled(&["/w/a"]);
        assert_eq!(start_of(&words[..40], &strings), None, "too few words");
        let mut more = words.clone();
        more.extend_from_slice(&buffer(&[1]));
        assert_eq!(start_of(&more, &strings), None, "too many words");
        assert_eq!(start_of(&words[..41], &strings), None, "not whole words");
        assert_eq!(
            start_of(&words, &strings[..strings.len() - 1]),
            None,
            "strings too short"
        );
        let mut longer = strings.clone();
        longer.push(b'x');
        assert_eq!(start_of(&words, &longer), None, "strings too long");
        let (words, _) = spelled(&[]);
        assert_eq!(start_of(&words, b"/w\xffat"), None, "not UTF-8");
    }

    #[test]
    fn a_start_with_a_handle_for_each_overlay_is_a_request_and_any_other_is_not() {
        let (words, strings) = spelled(&["/w/a"]);
        let start = start_of(&words, &strings).expect("a start");
        let text = Text::from("x\nfoo").snapshot();

        assert!(start.clone().request(Vec::new()).is_none());
        let (request, bound) = start.request(vec![text]).expect("a request");
        assert_eq!(bound, 64);
        assert_eq!(request.overlays.len(), 1);
        assert_eq!(request.overlays[0].text.pieces().concat(), "x\nfoo");
    }

    fn at(row: usize, start: usize, stop: usize) -> Match {
        Match { row, start, stop }
    }

    #[test]
    fn a_delivery_crosses_as_its_files_then_its_end() {
        let delivery = |end| {
            Reply::Delivery(Delivery {
                found: vec![
                    Found {
                        path: PathBuf::from("/w/a"),
                        source: Source::Disk,
                        matches: vec![at(0, 1, 2), at(3, 10, 12)],
                    },
                    Found {
                        path: PathBuf::from("/w/bé"),
                        source: Source::Buffer,
                        matches: vec![at(1, 4, 5)],
                    },
                ],
                end,
            })
        };
        let files = vec![2, 4, 0, 2, 0, 1, 2, 3, 10, 12, 6, 1, 1, 1, 4, 5];
        let with = |end: &[u64]| {
            let mut words = files.clone();
            words.extend_from_slice(end);
            words
        };
        let summary = |truncated| Summary {
            files: 2,
            matches: 3,
            truncated,
        };

        assert_eq!(
            encoded(delivery(None)),
            Encoded {
                status: 8,
                words: with(&[0]),
                detail: String::new(),
                paths: "/w/a/w/bé".as_bytes().to_vec(),
            }
        );
        assert_eq!(
            encoded(delivery(Some(Ok(summary(false))))).words,
            with(&[1, 2, 3])
        );
        assert_eq!(
            encoded(delivery(Some(Ok(summary(true))))).words,
            with(&[2, 2, 3])
        );
        let refused = encoded(Reply::Delivery(Delivery {
            found: Vec::new(),
            end: Some(Err(Refusal::new(RefusalKind::NotFound, "no /w"))),
        }));
        assert_eq!(
            (refused.words, refused.detail),
            (vec![0, 3, 2], "no /w".to_owned())
        );
    }

    #[test]
    fn each_refusal_crosses_as_its_status_with_its_detail() {
        let statuses: Vec<(u64, String)> = [
            RefusalKind::NotAbsolute,
            RefusalKind::NotFound,
            RefusalKind::NotADirectory,
            RefusalKind::Denied,
            RefusalKind::Invalid,
            RefusalKind::ShutDown,
            RefusalKind::Failed,
        ]
        .into_iter()
        .map(|kind| {
            let reply = encoded(Reply::Refused(Refusal::new(kind, "why")));
            (reply.status, reply.detail)
        })
        .collect();

        assert_eq!(
            statuses,
            (1..=7)
                .map(|status| (status, "why".to_owned()))
                .collect::<Vec<_>>()
        );
        assert_eq!(encoded(Reply::Started).status, 0);
    }

    #[test]
    fn a_start_read_from_words_runs_on_the_service_and_its_delivery_crosses() {
        let files = FakeFiles::new().file("/w/a", "foo\n").file("/w/b", "x foo");
        let (sender, completed) = mpsc::channel();
        let sender = std::sync::Mutex::new(sender);
        let service = Service::new(
            move || (files.clone(), Literal),
            editor_text::is_word_character,
            move |id| {
                sender
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .send(id)
                    .ok();
            },
        );
        let words = [200, 2000, 64, 2, 3, 1, 4];
        let strings = b"/wfoo/w/a".to_vec();
        let start = start_of(&buffer(&words), &strings).expect("a start");
        let text = Text::from("y\nfoo foo").snapshot();
        let (request, bound) = start.request(vec![text]).expect("a request");

        assert!(service.start(1, request, bound));
        assert_eq!(editor_wait::recv(&completed, DEADLINE), Ok(1));
        assert_eq!(
            service.take(1).map(encoded).map(|reply| reply.status),
            Some(0)
        );
        let mut all = Vec::new();
        for wait in 2.. {
            assert!(service.next(1, wait));
            assert_eq!(editor_wait::recv(&completed, DEADLINE), Ok(wait));
            let reply = service.take(wait).map(encoded).expect("a delivery");
            let ended = reply.words.last() != Some(&0);
            all.push(reply);
            if ended {
                break;
            }
        }
        let paths: Vec<u8> = all.iter().flat_map(|reply| reply.paths.clone()).collect();
        assert_eq!(paths, b"/w/a/w/b");
        let last = all.last().expect("a last delivery");
        assert_eq!(last.words[last.words.len() - 3..], [1, 2, 3]);
    }
}
