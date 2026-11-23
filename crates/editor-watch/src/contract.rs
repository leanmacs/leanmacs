//! The contract of the watch port: the rules every [`Watch`] keeps, as a
//! check that runs one.
//!
//! [`check`] runs every property in a fresh subdirectory of a directory its
//! caller owns, and returns the names of those that fail. Each changes only
//! what is inside its own subdirectory, through the [`Ground`] it is
//! given.
//!
//! The port's properties are [`LIVE_ON_RETURN`] to [`REFUSED`]. The
//! service's, [`FILE_WRITTEN`] to [`FLUSH`], run [`Service`] over the
//! watch the check is given, on the clock it is given, so a real adapter
//! shows them on real files. On a real file system they check that a kind
//! is *present* in a change, never that the set is exactly something, and
//! a property reads up to [`READS`] deliveries for each change it looks
//! for: a platform can carry an earlier change's flag, or split what one
//! step made across two deliveries. The exact sets are pinned on the fake,
//! in the service's unit tests. [`COALESCED`] is the exception: it fails if
//! the path written five times is in more than its first delivery.
//!
//! [`COALESCED`] needs the window to pass on the service's clock. The
//! check is given the clock, and [`Ground::let_pass`] moves it: the fake's
//! ground advances the [`ManualClock`](crate::clock::ManualClock) it is
//! on, and the property then wakes the service; a real ground does
//! nothing, and the property waits for the delivery up to its deadline,
//! while real time passes. So the property is deterministic on the fake.
//! On a real adapter it needs the platform's notices of the five writes to
//! reach the service before the first delivery is taken: a delivery holds
//! every change noticed up to its take ([`Service::take`]), so how fast
//! the writes were made does not matter, and a notice the platform tells
//! later than that does.
//!
//! Seen to bite once by hand, on 2026-11-15, on the fake
//! (`tests/contract.rs`): with the service's router keeping every entry of
//! a file watch's directory, [`FILE_IGNORES_SIBLINGS`] alone fails; with
//! its timer thread never completing a read, [`COALESCED`] alone fails.
//! Each port property bites on a fake written to break it, in
//! `tests/contract.rs`.
//!
//! # How a property waits
//!
//! A sink sends each notice to a channel, and the property waits on it for
//! a notice that matches, each wait up to [`Ground::deadline`]. Only an
//! implementation that breaks a rule takes that long. A negative claim
//! uses a sentinel: the property makes the change that must not be
//! noticed, then one that must, and when the sentinel's notice arrives it
//! looks at what came before it. That holds because one registration's
//! notices come in order, a rule of the port.
//!
//! [`TREE_NEW_SUBDIRECTORY`] writes its file again, a bounded number of
//! times, until it is noticed: a platform that watches a new subdirectory
//! when it hears of it (inotify, through `notify`) can miss what is made
//! there before it gets to it, and the rule the editor needs is that what
//! changes there is noticed once the subdirectory is watched.
//!
//! # The ground
//!
//! The port has no way to make a file or a directory. The check needs
//! them, so its caller supplies them as a [`Ground`]: for the fake, its
//! file system in memory ([`FakeWatch::ground`](crate::fake::FakeWatch::ground));
//! for a real adapter, `std::fs` in a temporary directory.
//!
//! # Where an addition goes
//!
//! A new rule is a named `pub const`, an entry of [`PROPERTIES`], a step of
//! [`check`], and in `tests/contract.rs` a fake written to break it.

use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex, PoisonError};

use editor_wait::HangGuard;

use crate::batch::Change;
use crate::clock::Clock;
use crate::service::{Coalescing, Service, Target, WatchReply};
use crate::{Depth, Kind, Notice, RefusalKind, Sink, Watch};

/// What [`check`] needs done that the port has no method for. It is the
/// truth the port's notices are compared with, so it must not be built on
/// the [`Watch`] being checked. Each method panics if it cannot do what it
/// is asked: the check's directory is its caller's own.
pub trait Ground {
    /// Writes `bytes` to the file at `path`, making it if it is not there.
    fn write(&self, path: &Path, bytes: &[u8]);

    /// Writes to the file at `path` `times` times, as fast as it can.
    fn write_times(&self, path: &Path, times: usize);

    /// Makes the directory `path`, whose parent is there.
    fn make_dir(&self, path: &Path);

    /// Renames `from` to `to` in one step, replacing what is at `to`.
    fn rename(&self, from: &Path, to: &Path);

    /// Removes the file at `path`.
    fn remove(&self, path: &Path);

    /// Makes `link` a symbolic link to the directory `to`.
    fn link(&self, link: &Path, to: &Path);

    /// Lets `ms` pass on the clock the check was given: a ground on a
    /// manual clock advances it; a real ground does nothing, real time
    /// passing by itself while the check waits.
    fn let_pass(&self, ms: u64);

    /// hang guard: the notice or completion each wait of the check ends
    /// on; only a hang reaches the bound, and the check then fails as a
    /// hang. How long the check waits for what should happen at once.
    fn deadline(&self) -> HangGuard;

    /// Holds every later call of the port's `watch` inside the port, until
    /// [`release_starts`](Self::release_starts), and says whether it can.
    /// The fake's ground can; a real ground cannot, and keeps this default,
    /// so [`FLUSH`] there checks the order without forcing it.
    fn hold_starts(&self) -> bool {
        false
    }

    /// Lets every call [`hold_starts`](Self::hold_starts) held go on, and
    /// holds none from now on.
    fn release_starts(&self) {}
}

/// An entry made right after `watch` returns is noticed, on each of 20
/// fresh registrations, so that a race shows up.
pub const LIVE_ON_RETURN: &str = "a registration is live when watch returns";
/// A file made in the directory is noticed as created, under its path.
pub const CREATED: &str = "an entry made is noticed as created";
/// A write to a file in the directory is noticed as written.
pub const WRITTEN: &str = "an entry written is noticed as written";
/// A file removed from the directory is noticed as removed.
pub const REMOVED: &str = "an entry removed is noticed as removed";
/// `a` renamed to `b` inside the directory is noticed as renamed under
/// both paths.
pub const RENAMED: &str = "an entry renamed is noticed as renamed under its old and its new path";
/// `c` renamed over an existing `b` is noticed as renamed under `b`.
pub const RENAMED_OVER: &str =
    "an entry renamed over another is noticed as renamed under the other";
/// A registration of the tree notices a write two levels down.
pub const TREE: &str = "a registration of the tree notices a write two levels down";
/// A registration of the tree notices a subdirectory made after `watch`
/// returned, and then a file written inside it.
pub const TREE_NEW_SUBDIRECTORY: &str =
    "a registration of the tree notices a new subdirectory and what is written in it";
/// A directory registered through a link is told under the link's
/// spelling.
pub const SPELLED_AS_GIVEN: &str = "a notice names its path as the directory was spelled";
/// Two registrations of one directory each notice a write, and after one
/// is dropped the other still notices.
pub const INDEPENDENT: &str = "registrations of one directory are independent";
/// Once a registration's drop has returned, its sink is never called: 200
/// writes right after the drop reach it not at all, which a sentinel on a
/// second registration shows.
pub const DROPPED_IS_SILENT: &str = "after its drop returns a registration's sink is never called";
/// A directory that is not there is [`RefusalKind::NotFound`], and a file
/// given as a directory [`RefusalKind::NotADirectory`].
pub const REFUSED: &str = "a directory not there, or a file, is refused as such";

/// A watch on a file is told when the file is written.
pub const FILE_WRITTEN: &str = "a file watch is told when the file is written";
/// A watch on a file is told when another file is renamed over it.
pub const FILE_RENAMED_OVER: &str = "a file watch is told when a file is renamed over it";
/// A watch on a file is told when the file is removed.
pub const FILE_REMOVED: &str = "a file watch is told when the file is removed";
/// A watch on a file that is not there yet is told of its creation.
pub const FILE_MADE: &str = "a file watch is told when the file is made";
/// A watch on a file is told of a write after a rename over the file, an
/// atomic save.
pub const FILE_SURVIVES_SAVE: &str = "a file watch is still told after an atomic save";
/// A watch on a file is told nothing of the files beside it.
pub const FILE_IGNORES_SIBLINGS: &str = "a file watch is told nothing of its siblings";
/// A watch on a directory's entries is told each entry created, written,
/// renamed and removed directly inside it, with its path, and nothing
/// deeper.
pub const DIRECTORY_ENTRIES: &str =
    "a directory watch is told each entry changed directly inside it, and nothing deeper";
/// A watch on a directory's tree is told of a change two levels down.
pub const DIRECTORY_TREE: &str = "a tree watch is told of a change in a subdirectory";
/// With a window of 300 ms and a read pending, five writes to one path
/// arrive as one delivery holding that path once; and after it, a write to
/// a sentinel gives a delivery that holds the sentinel and not the first
/// path.
pub const COALESCED: &str = "writes within the window arrive as one delivery";
/// Of two watches on one file, one cancelled: the other is told of a
/// write, and the cancelled one's pending read is never completed.
///
/// The file is first made after the cancel. An adapter may tell of a
/// change made just before a registration as soon as it is live, as
/// FSEvents does, and a write before the watches would then complete the
/// read before it was cancelled.
pub const CANCELLED_SILENT: &str = "a cancelled watch's pending read is never completed";
/// After shutdown a start is refused as shut down, and a pending read is
/// never completed. As in [`CANCELLED_SILENT`], the file is first made
/// after the shutdown, so no late notice completes the read before it.
pub const SHUTDOWN: &str = "after shutdown a start is refused and a pending read never completed";
/// A flush asked while a start is in the port is completed after the
/// start's own completion, and not before it. Where the ground can hold
/// starts ([`Ground::hold_starts`]), the start is held and nothing is
/// completed until it is let go, which forces the order; elsewhere the
/// same order is required.
pub const FLUSH: &str = "a flush is completed once every start asked before it has returned";

/// Every property, in the order [`check`] runs them.
pub const PROPERTIES: [&str; 24] = [
    LIVE_ON_RETURN,
    CREATED,
    WRITTEN,
    REMOVED,
    RENAMED,
    RENAMED_OVER,
    TREE,
    TREE_NEW_SUBDIRECTORY,
    SPELLED_AS_GIVEN,
    INDEPENDENT,
    DROPPED_IS_SILENT,
    REFUSED,
    FILE_WRITTEN,
    FILE_RENAMED_OVER,
    FILE_REMOVED,
    FILE_MADE,
    FILE_SURVIVES_SAVE,
    FILE_IGNORES_SIBLINGS,
    DIRECTORY_ENTRIES,
    DIRECTORY_TREE,
    COALESCED,
    CANCELLED_SILENT,
    SHUTDOWN,
    FLUSH,
];

/// How many deliveries a service property reads for each change it looks
/// for, at most. With no window, each delivery is taken as soon as it is
/// completed, so what one step made can come in several: inotify tells a
/// new file's creation, its write and the write's close one by one.
pub const READS: usize = 4;

/// The window of [`COALESCED`], in milliseconds.
const WINDOW: u64 = 300;

/// How many writes [`COALESCED`] makes to its one path.
const COALESCED_WRITES: usize = 5;

/// The coalescing of every service property but [`COALESCED`]: no window,
/// and room for every path a property changes.
const AT_ONCE: Coalescing = Coalescing {
    window_ms: 0,
    bound: 100,
};

/// How many fresh registrations [`LIVE_ON_RETURN`] makes.
const LIVE_TIMES: usize = 20;
/// How many writes [`DROPPED_IS_SILENT`] makes after the drop.
const AFTER_DROP: usize = 200;
/// How many times [`TREE_NEW_SUBDIRECTORY`] writes its file, at most.
const NEW_SUBDIRECTORY_TRIES: u32 = 20;

/// Holds `watch` to the port's rules, and a [`Service`] over it on `clock`
/// to the service's, in fresh subdirectories of `dir`, which the caller
/// owns and which is there, making every change through `ground`; and
/// returns the names of the properties that fail, in the order of
/// [`PROPERTIES`].
pub fn check<W: Watch + Clone, C: Clock + Clone>(
    watch: W,
    clock: C,
    ground: &impl Ground,
    dir: &Path,
) -> Vec<&'static str> {
    let check = Check {
        watch,
        clock,
        ground,
        dir,
    };
    let results = [
        (LIVE_ON_RETURN, check.live_on_return()),
        (CREATED, check.created()),
        (WRITTEN, check.written()),
        (REMOVED, check.removed()),
        (RENAMED, check.renamed()),
        (RENAMED_OVER, check.renamed_over()),
        (TREE, check.tree()),
        (TREE_NEW_SUBDIRECTORY, check.tree_new_subdirectory()),
        (SPELLED_AS_GIVEN, check.spelled_as_given()),
        (INDEPENDENT, check.independent()),
        (DROPPED_IS_SILENT, check.dropped_is_silent()),
        (REFUSED, check.refused()),
        (FILE_WRITTEN, check.file_written()),
        (FILE_RENAMED_OVER, check.file_renamed_over()),
        (FILE_REMOVED, check.file_removed()),
        (FILE_MADE, check.file_made()),
        (FILE_SURVIVES_SAVE, check.file_survives_save()),
        (FILE_IGNORES_SIBLINGS, check.file_ignores_siblings()),
        (DIRECTORY_ENTRIES, check.directory_entries()),
        (DIRECTORY_TREE, check.directory_tree()),
        (COALESCED, check.coalesced()),
        (CANCELLED_SILENT, check.cancelled_silent()),
        (SHUTDOWN, check.shutdown()),
        (FLUSH, check.flush()),
    ];
    results
        .into_iter()
        .filter(|(_, holds)| !holds)
        .map(|(name, _)| name)
        .collect()
}

/// A sink's notices, as a property reads them.
pub(crate) struct Listener {
    /// What the sink sent.
    notices: Receiver<Notice>,
}

/// A sink that sends each notice, and the listener that reads them.
pub(crate) fn listener() -> (Sink, Listener) {
    let (sender, notices) = mpsc::channel();
    let sender = Mutex::new(sender);
    let sink: Sink = Arc::new(move |notice| {
        sender
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .send(notice)
            .ok();
    });
    (sink, Listener { notices })
}

impl Listener {
    /// Reads notices until one for which `matches` holds, each read up to
    /// `deadline`, and says whether one came.
    pub(crate) fn until(
        &self,
        deadline: HangGuard,
        mut matches: impl FnMut(&Notice) -> bool,
    ) -> bool {
        loop {
            // hang guard: the next notice; only a hang reaches the bound,
            // and the check then fails as a hang.
            match editor_wait::recv(&self.notices, deadline) {
                Ok(notice) if matches(&notice) => return true,
                Ok(_) => {}
                Err(_) => return false,
            }
        }
    }

    /// Reads notices until one at `path` of `kind`.
    pub(crate) fn heard(&self, deadline: HangGuard, path: &Path, kind: Kind) -> bool {
        self.until(deadline, |notice| {
            notice.path == path && notice.kind == kind
        })
    }

    /// Reads notices until one at `path`, and gives every notice before it;
    /// `None` if none came.
    pub(crate) fn before(&self, deadline: HangGuard, path: &Path) -> Option<Vec<Notice>> {
        let mut before = Vec::new();
        self.until(deadline, |notice| {
            if notice.path == path {
                return true;
            }
            before.push(notice.clone());
            false
        })
        .then_some(before)
    }

    /// Every notice sent so far, without waiting.
    pub(crate) fn drain(&self) -> Vec<Notice> {
        self.notices.try_iter().collect()
    }
}

/// A service a property runs, and the ids it completes.
struct Served<W: Watch, C: Clock> {
    /// The service.
    service: Service<W, C>,
    /// The ids it completed, in order.
    completed: Receiver<u64>,
    /// Every id received from `completed` and not yet looked for.
    seen: Vec<u64>,
    /// The next wait id to use.
    next_wait: u64,
}

impl<W: Watch, C: Clock> Served<W, C> {
    /// Waits for the id `id` to be completed, up to `deadline`, keeping the
    /// others it receives on the way.
    fn completed(&mut self, id: u64, deadline: HangGuard) -> bool {
        if let Some(index) = self.seen.iter().position(|&seen| seen == id) {
            self.seen.remove(index);
            return true;
        }
        loop {
            // hang guard: the next completion; only a hang reaches the
            // bound, and the check then fails as a hang.
            match editor_wait::recv(&self.completed, deadline) {
                Ok(seen) if seen == id => return true,
                Ok(seen) => self.seen.push(seen),
                Err(_) => return false,
            }
        }
    }

    /// Whether `id` has been completed by now, without waiting.
    fn ever_completed(&mut self, id: u64) -> bool {
        self.seen.extend(self.completed.try_iter());
        self.seen.contains(&id)
    }

    /// Starts the watch `id` and waits for it to be live.
    fn started(
        &mut self,
        id: u64,
        target: Target,
        coalescing: Coalescing,
        deadline: HangGuard,
    ) -> bool {
        self.service.start(id, target, coalescing)
            && self.completed(id, deadline)
            && self.service.take(id) == Some(WatchReply::Started)
    }

    /// Asks for the next delivery of `watch` and gives its wait id.
    fn ask(&mut self, watch: u64) -> Option<u64> {
        let wait = self.next_wait;
        self.next_wait += 1;
        self.service.next(watch, wait).then_some(wait)
    }

    /// Waits for the delivery of `wait` and takes it.
    fn delivery(&mut self, wait: u64, deadline: HangGuard) -> Option<Vec<Change>> {
        if !self.completed(wait, deadline) {
            return None;
        }
        match self.service.take(wait) {
            Some(WatchReply::Changes(changes)) => Some(changes),
            _ => None,
        }
    }

    /// Reads deliveries of `watch`, up to [`READS`], until `done` holds of
    /// one, and says whether it did. `done` sees each delivery in turn.
    fn reads_until(
        &mut self,
        watch: u64,
        deadline: HangGuard,
        done: impl FnMut(&[Change]) -> bool,
    ) -> bool {
        self.reads_for(watch, deadline, 1, done)
    }

    /// Reads deliveries of `watch`, up to [`READS`] for each of `wanted`
    /// changes, until `done` holds of one, and says whether it did.
    fn reads_for(
        &mut self,
        watch: u64,
        deadline: HangGuard,
        wanted: usize,
        mut done: impl FnMut(&[Change]) -> bool,
    ) -> bool {
        for _ in 0..READS * wanted {
            let Some(wait) = self.ask(watch) else {
                return false;
            };
            let Some(changes) = self.delivery(wait, deadline) else {
                return false;
            };
            if done(&changes) {
                return true;
            }
        }
        false
    }
}

/// Whether `changes` hold a change at `path` with `kind` among its kinds.
fn has(changes: &[Change], path: &Path, kind: Kind) -> bool {
    changes
        .iter()
        .any(|change| change.path == path && change.kinds.contains(kind))
}

/// Whether `changes` hold a change at `path`, of any kind.
fn names(changes: &[Change], path: &Path) -> bool {
    changes.iter().any(|change| change.path == path)
}

/// One run of [`check`].
struct Check<'a, W, C, G> {
    /// What is checked.
    watch: W,
    /// The clock the service properties run on.
    clock: C,
    /// What makes the changes.
    ground: &'a G,
    /// The caller's directory.
    dir: &'a Path,
}

impl<W: Watch + Clone, C: Clock + Clone, G: Ground> Check<'_, W, C, G> {
    /// A fresh directory named `name` in the caller's.
    fn fresh(&self, name: &str) -> PathBuf {
        let dir = self.dir.join(name);
        self.ground.make_dir(&dir);
        dir
    }

    /// hang guard: the ground's [`Ground::deadline`], the deadline of each
    /// wait; only a hang reaches it, and the check then fails as a hang.
    fn deadline(&self) -> HangGuard {
        self.ground.deadline()
    }

    /// A registration of `dir` to `depth`, and its listener; `None` if it
    /// was refused.
    fn register(&self, dir: &Path, depth: Depth) -> Option<(W::Registration, Listener)> {
        let (sink, listener) = listener();
        let registration = self.watch.watch(dir, depth, sink).ok()?;
        Some((registration, listener))
    }

    fn live_on_return(&self) -> bool {
        (0..LIVE_TIMES).all(|time| {
            let dir = self.fresh(&format!("live-{time}"));
            let Some((_registration, listener)) = self.register(&dir, Depth::Entries) else {
                return false;
            };
            let file = dir.join("f");
            self.ground.write(&file, b"x");
            listener.until(self.deadline(), |notice| notice.path == file)
        })
    }

    fn created(&self) -> bool {
        let dir = self.fresh("created");
        let Some((_registration, listener)) = self.register(&dir, Depth::Entries) else {
            return false;
        };
        let file = dir.join("f");
        self.ground.write(&file, b"x");
        listener.heard(self.deadline(), &file, Kind::Created)
    }

    fn written(&self) -> bool {
        let dir = self.fresh("written");
        let file = dir.join("f");
        self.ground.write(&file, b"x");
        let Some((_registration, listener)) = self.register(&dir, Depth::Entries) else {
            return false;
        };
        self.ground.write(&file, b"y");
        listener.heard(self.deadline(), &file, Kind::Written)
    }

    fn removed(&self) -> bool {
        let dir = self.fresh("removed");
        let file = dir.join("f");
        self.ground.write(&file, b"x");
        let Some((_registration, listener)) = self.register(&dir, Depth::Entries) else {
            return false;
        };
        self.ground.remove(&file);
        listener.heard(self.deadline(), &file, Kind::Removed)
    }

    fn renamed(&self) -> bool {
        let dir = self.fresh("renamed");
        let (from, to) = (dir.join("a"), dir.join("b"));
        self.ground.write(&from, b"x");
        let Some((_registration, listener)) = self.register(&dir, Depth::Entries) else {
            return false;
        };
        self.ground.rename(&from, &to);
        let (mut old, mut new) = (false, false);
        listener.until(self.deadline(), |notice| {
            if notice.kind == Kind::Renamed {
                old |= notice.path == from;
                new |= notice.path == to;
            }
            old && new
        })
    }

    fn renamed_over(&self) -> bool {
        let dir = self.fresh("renamed-over");
        let (over, from) = (dir.join("b"), dir.join("c"));
        self.ground.write(&over, b"b");
        self.ground.write(&from, b"c");
        let Some((_registration, listener)) = self.register(&dir, Depth::Entries) else {
            return false;
        };
        self.ground.rename(&from, &over);
        listener.heard(self.deadline(), &over, Kind::Renamed)
    }

    fn tree(&self) -> bool {
        let dir = self.fresh("tree");
        let deep = dir.join("x").join("y");
        self.ground.make_dir(&dir.join("x"));
        self.ground.make_dir(&deep);
        let file = deep.join("f");
        self.ground.write(&file, b"x");
        let Some((_registration, listener)) = self.register(&dir, Depth::Tree) else {
            return false;
        };
        self.ground.write(&file, b"y");
        listener.heard(self.deadline(), &file, Kind::Written)
    }

    fn tree_new_subdirectory(&self) -> bool {
        let dir = self.fresh("tree-new");
        let Some((_registration, listener)) = self.register(&dir, Depth::Tree) else {
            return false;
        };
        let sub = dir.join("new");
        self.ground.make_dir(&sub);
        if !listener.until(self.deadline(), |notice| notice.path == sub) {
            return false;
        }
        let file = sub.join("f");
        // hang guard: the file's notice in the new subdirectory; each try's
        // share of the deadline only triggers a rewrite (inotify may watch
        // the subdirectory only after the first write), so only a hang
        // reaches the whole deadline, and the check then fails as a hang.
        let each = self
            .deadline()
            .with_bound(self.deadline().bound() / NEW_SUBDIRECTORY_TRIES);
        (0..NEW_SUBDIRECTORY_TRIES).any(|_| {
            self.ground.write(&file, b"x");
            listener.until(each, |notice| notice.path == file)
        })
    }

    fn spelled_as_given(&self) -> bool {
        let dir = self.fresh("spelled");
        let real = dir.join("real");
        let link = dir.join("link");
        self.ground.make_dir(&real);
        self.ground.link(&link, &real);
        let Some((_registration, listener)) = self.register(&link, Depth::Entries) else {
            return false;
        };
        self.ground.write(&real.join("f"), b"x");
        let told = link.join("f");
        listener.until(self.deadline(), |notice| notice.path == told)
    }

    fn independent(&self) -> bool {
        let dir = self.fresh("independent");
        let (Some((first, first_heard)), Some((_second, second_heard))) = (
            self.register(&dir, Depth::Entries),
            self.register(&dir, Depth::Entries),
        ) else {
            return false;
        };
        let file = dir.join("f");
        self.ground.write(&file, b"x");
        let both = first_heard.until(self.deadline(), |notice| notice.path == file)
            && second_heard.until(self.deadline(), |notice| notice.path == file);
        drop(first);
        let after = dir.join("g");
        self.ground.write(&after, b"x");
        both && second_heard.until(self.deadline(), |notice| notice.path == after)
    }

    fn dropped_is_silent(&self) -> bool {
        let dir = self.fresh("dropped");
        let (Some((dropped, dropped_heard)), Some((_kept, kept_heard))) = (
            self.register(&dir, Depth::Entries),
            self.register(&dir, Depth::Entries),
        ) else {
            return false;
        };
        drop(dropped);
        dropped_heard.drain();
        let file = dir.join("f");
        self.ground.write_times(&file, AFTER_DROP);
        let sentinel = dir.join("sentinel");
        self.ground.write(&sentinel, b"x");
        kept_heard.before(self.deadline(), &sentinel).is_some() && dropped_heard.drain().is_empty()
    }

    fn refused(&self) -> bool {
        let dir = self.fresh("refused");
        let file = dir.join("file");
        self.ground.write(&file, b"x");
        let kind = |path: &Path| {
            let (sink, _listener) = listener();
            self.watch
                .watch(path, Depth::Entries, sink)
                .err()
                .map(|refusal| refusal.kind)
        };
        kind(&dir.join("missing")) == Some(RefusalKind::NotFound)
            && kind(&file) == Some(RefusalKind::NotADirectory)
    }

    /// A service over the watch, on the clock.
    fn served(&self) -> Served<W, C> {
        let (sender, completed) = mpsc::channel();
        let sender = Mutex::new(sender);
        let service = Service::new(self.watch.clone(), self.clock.clone(), move |id| {
            sender
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .send(id)
                .ok();
        });
        Served {
            service,
            completed,
            seen: Vec::new(),
            next_wait: 100,
        }
    }

    /// A served watch, the watch `1`, on `target`; `None` if it was not
    /// started.
    fn watching(&self, target: Target, coalescing: Coalescing) -> Option<Served<W, C>> {
        let mut served = self.served();
        served
            .started(1, target, coalescing, self.deadline())
            .then_some(served)
    }

    /// A file watch on `file` with no window, read until a delivery holds
    /// `kind` at `file` once `change` has been made.
    fn file_told(&self, file: &Path, kind: Kind, change: impl FnOnce()) -> bool {
        let Some(mut served) = self.watching(Target::File(file.to_path_buf()), AT_ONCE) else {
            return false;
        };
        change();
        served.reads_until(1, self.deadline(), |changes| has(changes, file, kind))
    }

    fn file_written(&self) -> bool {
        let file = self.fresh("file-written").join("f");
        self.ground.write(&file, b"x");
        self.file_told(&file, Kind::Written, || self.ground.write(&file, b"y"))
    }

    fn file_renamed_over(&self) -> bool {
        let dir = self.fresh("file-renamed-over");
        let (file, other) = (dir.join("f"), dir.join("g"));
        self.ground.write(&file, b"f");
        self.ground.write(&other, b"g");
        self.file_told(&file, Kind::Renamed, || self.ground.rename(&other, &file))
    }

    fn file_removed(&self) -> bool {
        let file = self.fresh("file-removed").join("f");
        self.ground.write(&file, b"x");
        self.file_told(&file, Kind::Removed, || self.ground.remove(&file))
    }

    fn file_made(&self) -> bool {
        let file = self.fresh("file-made").join("f");
        self.file_told(&file, Kind::Created, || self.ground.write(&file, b"x"))
    }

    fn file_survives_save(&self) -> bool {
        let dir = self.fresh("file-save");
        let (file, saved) = (dir.join("f"), dir.join("f.tmp"));
        self.ground.write(&file, b"x");
        let Some(mut served) = self.watching(Target::File(file.clone()), AT_ONCE) else {
            return false;
        };
        self.ground.write(&saved, b"y");
        self.ground.rename(&saved, &file);
        if !served.reads_until(1, self.deadline(), |changes| {
            has(changes, &file, Kind::Renamed)
        }) {
            return false;
        }
        self.ground.write(&file, b"z");
        served.reads_until(1, self.deadline(), |changes| {
            has(changes, &file, Kind::Written)
        })
    }

    fn file_ignores_siblings(&self) -> bool {
        let dir = self.fresh("file-siblings");
        let (file, sibling) = (dir.join("f"), dir.join("s"));
        let Some(mut served) = self.watching(Target::File(file.clone()), AT_ONCE) else {
            return false;
        };
        self.ground.write(&sibling, b"x");
        self.ground.write(&file, b"x");
        let mut sibling_told = false;
        served.reads_until(1, self.deadline(), |changes| {
            sibling_told |= names(changes, &sibling);
            names(changes, &file)
        }) && !sibling_told
    }

    fn directory_entries(&self) -> bool {
        let dir = self.fresh("directory-entries");
        let sub = dir.join("sub");
        let (made, written, renamed, removed) =
            (dir.join("n"), dir.join("a"), dir.join("b"), dir.join("r"));
        let deeper = sub.join("x");
        self.ground.make_dir(&sub);
        self.ground.write(&deeper, b"x");
        self.ground.write(&written, b"a");
        self.ground.write(&removed, b"r");
        let Some(mut served) =
            self.watching(Target::Directory(dir.clone(), Depth::Entries), AT_ONCE)
        else {
            return false;
        };
        self.ground.write(&deeper, b"y");
        self.ground.write(&made, b"n");
        self.ground.write(&written, b"aa");
        self.ground.rename(&written, &renamed);
        self.ground.remove(&removed);
        let wanted = [
            (&made, Kind::Created),
            (&written, Kind::Written),
            (&written, Kind::Renamed),
            (&renamed, Kind::Renamed),
            (&removed, Kind::Removed),
        ];
        let mut seen = [false; 5];
        let mut deeper_told = false;
        served.reads_for(1, self.deadline(), wanted.len(), |changes| {
            deeper_told |= names(changes, &deeper);
            for (index, (path, kind)) in wanted.iter().enumerate() {
                seen[index] |= has(changes, path, *kind);
            }
            seen.iter().all(|&seen| seen)
        }) && !deeper_told
    }

    fn directory_tree(&self) -> bool {
        let dir = self.fresh("directory-tree");
        let deep = dir.join("x").join("y");
        self.ground.make_dir(&dir.join("x"));
        self.ground.make_dir(&deep);
        let file = deep.join("f");
        self.ground.write(&file, b"x");
        let Some(mut served) = self.watching(Target::Directory(dir, Depth::Tree), AT_ONCE) else {
            return false;
        };
        self.ground.write(&file, b"y");
        served.reads_until(1, self.deadline(), |changes| {
            has(changes, &file, Kind::Written)
        })
    }

    fn coalesced(&self) -> bool {
        let dir = self.fresh("coalesced");
        let (file, sentinel) = (dir.join("f"), dir.join("sentinel"));
        self.ground.write(&file, b"x");
        let window = Coalescing {
            window_ms: WINDOW,
            bound: 100,
        };
        let Some(mut served) = self.watching(Target::Directory(dir, Depth::Entries), window) else {
            return false;
        };
        let Some(first) = served.ask(1) else {
            return false;
        };
        self.ground.write_times(&file, COALESCED_WRITES);
        self.ground.let_pass(WINDOW);
        served.service.wake();
        let Some(changes) = served.delivery(first, self.deadline()) else {
            return false;
        };
        let once = changes.iter().filter(|change| change.path == file).count() == 1;
        let Some(second) = served.ask(1) else {
            return false;
        };
        self.ground.write(&sentinel, b"x");
        self.ground.let_pass(WINDOW);
        served.service.wake();
        let Some(after) = served.delivery(second, self.deadline()) else {
            return false;
        };
        once && names(&after, &sentinel) && !names(&after, &file)
    }

    fn cancelled_silent(&self) -> bool {
        let file = self.fresh("cancelled").join("f");
        let target = Target::File(file.clone());
        let mut served = self.served();
        if !(served.started(1, target.clone(), AT_ONCE, self.deadline())
            && served.started(2, target, AT_ONCE, self.deadline()))
        {
            return false;
        }
        let (Some(cancelled), Some(kept)) = (served.ask(1), served.ask(2)) else {
            return false;
        };
        served.service.cancel(1);
        self.ground.write(&file, b"y");
        let told = served
            .delivery(kept, self.deadline())
            .is_some_and(|changes| names(&changes, &file));
        told && !served.ever_completed(cancelled)
    }

    fn flush(&self) -> bool {
        let file = self.fresh("flush").join("f");
        let served = self.served();
        let held = self.ground.hold_starts();
        let asked = served.service.start(1, Target::File(file), AT_ONCE) && served.service.flush(2);
        // Held, the start cannot return from the port: nothing is done.
        let waited = !held || served.completed.try_recv().is_err();
        self.ground.release_starts();
        let deadline = self.deadline();
        // hang guard: the start's and the flush's completions; only a hang
        // reaches the bound, and the check then fails as a hang.
        let order = [
            editor_wait::recv(&served.completed, deadline).ok(),
            editor_wait::recv(&served.completed, deadline).ok(),
        ];
        asked && waited && order == [Some(1), Some(2)] && served.service.take(2).is_none()
    }

    fn shutdown(&self) -> bool {
        let dir = self.fresh("shutdown");
        let file = dir.join("f");
        let Some(mut ended) = self.watching(Target::File(file.clone()), AT_ONCE) else {
            return false;
        };
        let Some(pending) = ended.ask(1) else {
            return false;
        };
        ended.service.shutdown();
        let refused = ended.service.start(2, Target::File(file.clone()), AT_ONCE)
            && ended.completed(2, self.deadline())
            && matches!(
                ended.service.take(2),
                Some(WatchReply::Refused(refusal)) if refusal.kind == RefusalKind::ShutDown
            );
        let Some(mut sentinel) = self.watching(Target::File(file.clone()), AT_ONCE) else {
            return false;
        };
        self.ground.write(&file, b"y");
        let told = sentinel.reads_until(1, self.deadline(), |changes| names(changes, &file));
        refused && told && !ended.ever_completed(pending)
    }
}
