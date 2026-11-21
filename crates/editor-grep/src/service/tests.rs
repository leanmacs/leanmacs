//! The service's rules, on the fake behind a gate the test holds: no
//! sleeps, and every wait bounded.

use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use editor_search::Literal;

use super::{Delivery, Reply, Service};
use crate::fake::FakeFiles;
use crate::{
    Files, Flow, Found, Limits, Match, Read, Refusal, RefusalKind, Request, Row, Source, Summary,
};

/// hang guard: a read entering the gate, or a completion; only a hang
/// reaches the bound, and the test then fails as a hang. How long a test
/// waits for what should happen at once.
const DEADLINE: Duration = Duration::from_secs(10);

/// What a gate holds: permits to read a file, and the reads entered.
#[derive(Debug, Default)]
struct Permits {
    /// Reads that may go on.
    permits: usize,
    /// Reads asked for, let through or not.
    entered: usize,
    /// Whether every read goes on.
    open: bool,
}

/// A gate a test holds in front of every read of a file.
#[derive(Debug, Clone, Default)]
struct Gate(Arc<(Mutex<Permits>, Condvar)>);

impl Gate {
    fn lock(&self) -> MutexGuard<'_, Permits> {
        self.0.0.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Lets `count` more reads go on.
    fn release(&self, count: usize) {
        self.lock().permits += count;
        self.0.1.notify_all();
    }

    /// Lets every read go on.
    fn open(&self) {
        self.lock().open = true;
        self.0.1.notify_all();
    }

    /// Waits until `count` reads were asked for.
    fn until_entered(&self, count: usize) -> bool {
        let (permits, _) = self
            .0
            .1
            .wait_timeout_while(self.lock(), DEADLINE, |permits| permits.entered < count)
            .unwrap_or_else(PoisonError::into_inner);
        permits.entered >= count
    }

    /// How many reads were asked for.
    fn entered(&self) -> usize {
        self.lock().entered
    }

    /// A read: counted, then held until a permit lets it go on.
    fn pass(&self) {
        let mut permits = self.lock();
        permits.entered += 1;
        self.0.1.notify_all();
        let mut permits = self
            .0
            .1
            .wait_while(permits, |permits| permits.permits == 0 && !permits.open)
            .unwrap_or_else(PoisonError::into_inner);
        if !permits.open {
            permits.permits -= 1;
        }
    }
}

/// The fake, each read behind the gate.
struct Gated {
    /// The tree.
    files: FakeFiles,
    /// The gate.
    gate: Gate,
}

impl Files for Gated {
    fn walk(&self, root: &Path, visit: &mut dyn FnMut(&Path) -> Flow) -> Result<(), Refusal> {
        self.files.walk(root, visit)
    }

    fn rows(
        &self,
        path: &Path,
        holds: &mut dyn FnMut(&str) -> bool,
        visit: &mut dyn FnMut(Row<'_>) -> Flow,
    ) -> Result<Read, Refusal> {
        self.gate.pass();
        self.files.rows(path, holds, visit)
    }
}

/// A service over `files` behind `gate`, and the completions it queues.
struct Rig {
    service: Service<Gated, Literal>,
    completed: Receiver<u64>,
    gate: Gate,
}

impl Rig {
    fn over(files: FakeFiles) -> Self {
        let gate = Gate::default();
        let (sender, completed) = mpsc::channel();
        let sender = Mutex::new(sender);
        let made = gate.clone();
        let service = Service::new(
            move || {
                (
                    Gated {
                        files: files.clone(),
                        gate: made.clone(),
                    },
                    Literal,
                )
            },
            |c: char| c.is_ascii_alphanumeric() || c == '_',
            move |id| {
                sender
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .send(id)
                    .ok();
            },
        );
        Self {
            service,
            completed,
            gate,
        }
    }

    /// Waits for the next completion.
    fn completion(&self) -> Option<u64> {
        self.completed.recv_timeout(DEADLINE).ok()
    }

    /// Starts the search `id` of `pattern` under `/w`, with `bound`, and
    /// takes its start's reply.
    fn started(&self, id: u64, pattern: &str, bound: usize) -> Option<Reply> {
        assert!(self.service.start(id, request("/w", pattern), bound));
        assert_eq!(self.completion(), Some(id));
        self.service.take(id)
    }

    /// Reads the search `id` from the wait `wait` on until its end, and
    /// gives every delivery.
    fn read_to_end(&self, id: u64, wait: u64) -> Vec<Delivery> {
        let mut deliveries = Vec::new();
        for wait in wait.. {
            let delivery = self.read(id, wait);
            let ended = delivery.end.is_some();
            deliveries.push(delivery);
            if ended {
                break;
            }
        }
        deliveries
    }

    /// Reads the search `id` under the wait `wait` and takes the delivery.
    fn read(&self, id: u64, wait: u64) -> Delivery {
        assert!(self.service.next(id, wait), "next {id} {wait}");
        assert_eq!(self.completion(), Some(wait));
        match self.service.take(wait) {
            Some(Reply::Delivery(delivery)) => delivery,
            other => panic!("not a delivery: {other:?}"),
        }
    }
}

impl Drop for Rig {
    /// Opens the gate, so the service's shutdown, as its last handle is
    /// dropped, finds no search held at a read.
    fn drop(&mut self) {
        self.gate.open();
    }
}

fn request(root: &str, pattern: &str) -> Request {
    Request {
        root: PathBuf::from(root),
        pattern: pattern.to_owned(),
        overlays: Vec::new(),
        limits: Limits {
            files: 100,
            matches: 1_000,
        },
    }
}

/// The paths of what a delivery found.
fn paths(delivery: &Delivery) -> Vec<&str> {
    delivery
        .found
        .iter()
        .map(|found| found.path.to_str().unwrap_or(""))
        .collect()
}

/// Five files under `/w`, each with one `x`.
fn five() -> FakeFiles {
    ["a", "b", "c", "d", "e"]
        .into_iter()
        .fold(FakeFiles::new(), |files, name| {
            files.file(format!("/w/{name}"), "x\n")
        })
}

#[test]
fn a_start_is_answered_started_and_a_read_delivers_what_was_found_then_the_end() {
    let rig = Rig::over(FakeFiles::new().file("/w/a", "x\nyx\n").file("/w/b", "x"));
    rig.gate.open();

    assert_eq!(rig.started(1, "x", 10), Some(Reply::Started));
    let deliveries = rig.read_to_end(1, 10);
    let end = deliveries.last().and_then(|delivery| delivery.end.clone());
    let found: Vec<Found> = deliveries
        .into_iter()
        .flat_map(|delivery| delivery.found)
        .collect();

    assert_eq!(
        found,
        [
            Found {
                path: PathBuf::from("/w/a"),
                source: Source::Disk,
                matches: vec![
                    Match {
                        row: 0,
                        start: 0,
                        stop: 1
                    },
                    Match {
                        row: 1,
                        start: 3,
                        stop: 4
                    }
                ],
            },
            Found {
                path: PathBuf::from("/w/b"),
                source: Source::Disk,
                matches: vec![Match {
                    row: 0,
                    start: 0,
                    stop: 1
                }],
            },
        ]
    );
    assert_eq!(
        end,
        Some(Ok(Summary {
            files: 2,
            matches: 3,
            truncated: false
        }))
    );
    // Once the end is taken the search is gone, and its id is free.
    assert_eq!(rig.service.pending(), 0);
    assert!(!rig.service.next(1, 99));
}

#[test]
fn a_read_is_completed_when_the_next_file_is_found_and_drained_when_taken() {
    let rig = Rig::over(five());
    assert_eq!(rig.started(1, "x", 10), Some(Reply::Started));

    assert!(rig.service.next(1, 2));
    rig.gate.release(1);
    assert_eq!(rig.completion(), Some(2));
    // Two more files are found between the completion and the take.
    rig.gate.release(2);
    assert!(rig.gate.until_entered(4));

    let Some(Reply::Delivery(delivery)) = rig.service.take(2) else {
        panic!("a delivery");
    };
    assert_eq!(paths(&delivery), ["/w/a", "/w/b", "/w/c"]);
    assert_eq!(delivery.end, None);
    assert_eq!(rig.service.take(2), None, "taken once");
}

#[test]
fn a_delivery_holds_at_most_bound_matches_and_a_larger_file_is_cut() {
    let rig = Rig::over(
        FakeFiles::new()
            .file("/w/a", "x\n")
            .file("/w/b", "x\n")
            .file("/w/c", "x x x x x\n"),
    );
    rig.gate.open();
    assert_eq!(rig.started(1, "x", 2), Some(Reply::Started));
    assert!(rig.service.until_held_back(1, DEADLINE));

    let deliveries = rig.read_to_end(1, 2);

    let found: Vec<(Vec<&str>, Vec<usize>)> = deliveries
        .iter()
        .filter(|delivery| !delivery.found.is_empty())
        .map(|delivery| {
            let starts = delivery
                .found
                .iter()
                .flat_map(|found| found.matches.iter().map(|m| m.start))
                .collect();
            (paths(delivery), starts)
        })
        .collect();
    assert_eq!(
        found,
        [
            (vec!["/w/a", "/w/b"], vec![0, 0]),
            (vec!["/w/c"], vec![0, 2]),
            (vec!["/w/c"], vec![4, 6]),
            (vec!["/w/c"], vec![8]),
        ]
    );
    let end = deliveries.last().and_then(|delivery| delivery.end.clone());
    assert_eq!(end.map(|end| end.map(|s| s.matches)), Some(Ok(7)));
}

#[test]
fn a_search_is_held_back_while_bound_matches_are_not_taken() {
    let rig = Rig::over(five());
    rig.gate.open();
    assert_eq!(rig.started(1, "x", 2), Some(Reply::Started));

    // `a` and `b` are kept; `c` is read and waits for room.
    assert!(rig.service.until_held_back(1, DEADLINE));
    assert_eq!(rig.gate.entered(), 3);

    assert_eq!(paths(&rig.read(1, 2)), ["/w/a", "/w/b"]);
    // `c` and `d` are kept; `e` waits.
    assert!(rig.gate.until_entered(5));
    assert!(rig.service.until_held_back(1, DEADLINE));
    assert_eq!(paths(&rig.read(1, 3)), ["/w/c", "/w/d"]);
    let rest = rig.read_to_end(1, 4);
    let rest: Vec<&str> = rest.iter().flat_map(paths).collect();
    assert_eq!(rest, ["/w/e"]);
}

#[test]
fn a_refusal_before_the_walk_is_the_starts_reply_and_one_of_the_walk_is_the_end() {
    let rig = Rig::over(FakeFiles::new().file("/w/f", "x"));
    rig.gate.open();

    assert!(rig.service.start(1, request("w", "x"), 4));
    assert_eq!(rig.completion(), Some(1));
    let Some(Reply::Refused(refusal)) = rig.service.take(1) else {
        panic!("refused");
    };
    assert_eq!(refusal.kind, RefusalKind::NotAbsolute);

    assert!(rig.service.start(2, request("/w", r"\("), 4));
    assert_eq!(rig.completion(), Some(2));
    assert_eq!(
        rig.service.take(2),
        Some(Reply::Refused(Refusal::new(
            RefusalKind::Invalid,
            r"E54: Unmatched \("
        )))
    );

    assert!(rig.service.start(3, request("/v", "x"), 4));
    assert_eq!(rig.completion(), Some(3));
    assert_eq!(rig.service.take(3), Some(Reply::Started));
    let delivery = rig.read(3, 4);
    assert!(delivery.found.is_empty());
    assert_eq!(
        delivery.end.map(|end| end.map_err(|refusal| refusal.kind)),
        Some(Err(RefusalKind::NotFound))
    );

    assert!(rig.service.start(5, request("/w", "x"), 0));
    assert_eq!(rig.completion(), Some(5));
    assert!(matches!(
        rig.service.take(5),
        Some(Reply::Refused(Refusal {
            kind: RefusalKind::Failed,
            ..
        }))
    ));
    assert_eq!(rig.service.pending(), 0);
}

#[test]
fn cancelling_mid_file_stops_the_search_and_completes_nothing_more() {
    let rig = Rig::over(five());
    assert_eq!(rig.started(1, "x", 10), Some(Reply::Started));
    assert!(rig.service.next(1, 2));
    assert!(rig.gate.until_entered(1));

    assert!(rig.service.cancel(1));
    rig.gate.open();
    rig.service.shutdown();

    assert_eq!(rig.completed.try_recv().ok(), None, "nothing completed");
    assert_eq!(rig.gate.entered(), 1, "nothing more read");
    assert_eq!(rig.service.pending(), 0);
    assert_eq!(rig.service.take(2), None);
    assert!(!rig.service.cancel(1), "safe for an id it no longer knows");
}

#[test]
fn cancelling_a_search_held_back_ends_it() {
    let rig = Rig::over(five());
    rig.gate.open();
    assert_eq!(rig.started(1, "x", 1), Some(Reply::Started));
    assert!(rig.service.until_held_back(1, DEADLINE));

    assert!(rig.service.cancel(1));

    assert!(rig.service.until_held_back(0, DEADLINE));
    rig.service.shutdown();
    assert_eq!(rig.gate.entered(), 2);
}

#[test]
fn cancelling_before_the_start_is_answered_answers_nothing() {
    let latch = Gate::default();
    let (sender, completed) = mpsc::channel();
    let sender = Mutex::new(sender);
    let held = latch.clone();
    let files = five();
    let service = Service::new(
        move || {
            // The factory waits for the test: the start is in flight.
            held.pass();
            (files.clone(), Literal)
        },
        |c: char| c.is_alphanumeric(),
        move |id| {
            sender
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .send(id)
                .ok();
        },
    );
    assert!(service.start(1, request("/w", "x"), 10));
    assert!(latch.until_entered(1));

    assert!(service.cancel(1));
    latch.open();
    service.shutdown();

    assert_eq!(completed.try_recv().ok(), None);
    assert_eq!(service.pending(), 0);
}

#[test]
fn an_id_in_use_is_refused_and_a_wait_is_cancelled_alone() {
    let rig = Rig::over(five());
    assert!(rig.service.start(1, request("/w", "x"), 10));
    assert!(!rig.service.start(1, request("/w", "x"), 10), "search held");
    assert_eq!(rig.completion(), Some(1));
    assert!(!rig.service.start(1, request("/w", "x"), 10), "reply kept");
    assert_eq!(rig.service.take(1), Some(Reply::Started));

    assert!(rig.service.next(1, 2));
    assert!(!rig.service.next(1, 3), "a read pending");
    assert!(!rig.service.start(2, request("/w", "x"), 10), "a wait");
    assert!(!rig.service.next(7, 3), "no such search");

    assert!(rig.service.cancel(2));
    assert!(rig.service.next(1, 3), "the search lives on");
    rig.gate.open();
    assert_eq!(rig.completion(), Some(3));
    assert_eq!(rig.service.take(2), None);
    assert!(matches!(rig.service.take(3), Some(Reply::Delivery(_))));
}

#[test]
fn shutdown_ends_every_search_and_refuses_later_starts() {
    let rig = Rig::over(five());
    assert_eq!(rig.started(1, "x", 10), Some(Reply::Started));
    assert_eq!(rig.started(2, "x", 10), Some(Reply::Started));
    assert!(rig.service.next(1, 3));

    rig.gate.open();
    rig.service.shutdown();
    rig.service.shutdown();
    assert_eq!(rig.service.pending(), 0);
    // A completion queued before the shutdown may be on the channel.
    while rig.completed.try_recv().is_ok() {}

    assert!(rig.service.start(4, request("/w", "x"), 10));
    assert_eq!(rig.completion(), Some(4));
    assert!(matches!(
        rig.service.take(4),
        Some(Reply::Refused(Refusal {
            kind: RefusalKind::ShutDown,
            ..
        }))
    ));
}

#[test]
fn an_overlay_is_delivered_with_its_source() {
    let rig = Rig::over(FakeFiles::new().file("/w/a", "nothing"));
    rig.gate.open();
    let mut asked = request("/w", "x");
    asked.overlays = vec![crate::Overlay::new("/w/a", String::from("y\nx"))];

    assert!(rig.service.start(1, asked, 10));
    assert_eq!(rig.completion(), Some(1));
    assert_eq!(rig.service.take(1), Some(Reply::Started));
    let delivery = rig.read(1, 2);

    assert_eq!(delivery.found[0].source, Source::Buffer);
    assert_eq!(delivery.found[0].matches[0].row, 1);
}

#[test]
fn a_flush_is_completed_only_once_a_cancelled_searchs_thread_has_returned() {
    let rig = Rig::over(five());
    assert_eq!(rig.started(1, "x", 10), Some(Reply::Started));
    assert!(rig.service.next(1, 2));
    // The search's thread is held in its first read.
    assert!(rig.gate.until_entered(1));
    assert!(rig.service.cancel(1));
    assert_eq!(rig.service.pending(), 0, "its bookkeeping is gone");

    assert!(rig.service.flush(9));
    // Read while the thread is held, checked once it is let go.
    let early = rig.completed.try_recv().ok();
    rig.gate.open();
    let flushed = rig.completion();

    assert_eq!(
        early, None,
        "the flush was completed while the cancelled search's thread was still in its read"
    );
    assert_eq!(flushed, Some(9));
    assert_eq!(rig.completed.try_recv().ok(), None, "nothing more");
    assert_eq!(rig.service.take(9), None, "a flush keeps no reply");
    assert_eq!(rig.service.pending(), 0);
}

#[test]
fn a_flush_with_no_search_running_is_completed_at_once_and_an_id_in_use_is_refused() {
    let rig = Rig::over(five());
    rig.gate.open();
    assert!(rig.service.flush(9));
    assert_eq!(
        rig.completed.try_recv().ok(),
        Some(9),
        "on the caller's thread"
    );

    assert_eq!(rig.started(1, "x", 10), Some(Reply::Started));
    assert!(!rig.service.flush(1), "a search's id");
    let deliveries = rig.read_to_end(1, 2);
    assert!(
        deliveries
            .last()
            .is_some_and(|delivery| delivery.end.is_some())
    );
}

#[test]
fn a_flush_waits_for_a_live_search_and_a_cancel_withdraws_it() {
    let rig = Rig::over(five());
    assert_eq!(rig.started(1, "x", 10), Some(Reply::Started));
    // The live search's thread is held in its first read.
    assert!(rig.gate.until_entered(1));
    assert!(rig.service.flush(8));
    assert!(rig.service.flush(9));
    assert!(
        !rig.service.flush(9),
        "a flush's id is in use while it waits"
    );
    assert_eq!(rig.service.pending(), 3, "the search and its two flushes");
    assert!(rig.service.cancel(8));
    let early = rig.completed.try_recv().ok();

    // Ended by its cancel, the search's thread returns once let go.
    assert!(rig.service.cancel(1));
    rig.gate.open();

    assert_eq!(early, None, "the flush waits for the live search");
    assert_eq!(rig.completion(), Some(9));
    assert_eq!(
        rig.completed.try_recv().ok(),
        None,
        "the withdrawn flush is never completed"
    );
    assert_eq!(rig.service.pending(), 0);
}

#[test]
fn shutdown_completes_a_flush_once_and_only_after_the_search_thread_it_waited_for_has_returned() {
    let gate = Gate::default();
    let completions = Arc::new(Mutex::new(Vec::new()));
    let made = gate.clone();
    let files = five();
    let service = Service::new(
        move || {
            (
                Gated {
                    files: files.clone(),
                    gate: made.clone(),
                },
                Literal,
            )
        },
        |c: char| c.is_ascii_alphanumeric() || c == '_',
        {
            let completions = Arc::clone(&completions);
            move |id| {
                completions
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .push(id);
            }
        },
    );
    assert!(service.start(1, request("/w", "x"), 10));
    // The search's thread is held in its first read.
    assert!(gate.until_entered(1));
    assert!(service.flush(9));
    // What was completed when shutdown first waited for the thread, then
    // the thread let go: the hook is the shutdown's own wait.
    let at_wait = Arc::new(std::sync::OnceLock::new());
    {
        let at_wait = Arc::clone(&at_wait);
        let completions = Arc::clone(&completions);
        let opener = gate.clone();
        service.when_shutdown_waits(move || {
            let _ = at_wait.set(
                completions
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clone(),
            );
            opener.open();
        });
    }

    service.shutdown();

    let at_wait = at_wait.get().cloned();
    let completed = completions
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone();
    assert!(
        at_wait.as_ref().is_some_and(|early| !early.contains(&9)),
        "the flush was completed before the search's thread returned: {at_wait:?}"
    );
    assert_eq!(
        completed.iter().filter(|&&id| id == 9).count(),
        1,
        "the flush is completed exactly once: {completed:?}"
    );
    assert_eq!(service.pending(), 0);
}
