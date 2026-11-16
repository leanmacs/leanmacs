//! The contract of the watch port: the rules every [`Watch`] keeps, as a
//! check that runs one.
//!
//! [`check`] runs every property in a fresh subdirectory of a directory its
//! caller owns, and returns the names of those that fail. Each changes only
//! what is inside its own subdirectory, through the [`Ground`] it is
//! given.
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
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

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

    /// How long the check waits for what should happen at once.
    fn deadline(&self) -> Duration;
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

/// Every property, in the order [`check`] runs them.
pub const PROPERTIES: [&str; 12] = [
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
];

/// How many fresh registrations [`LIVE_ON_RETURN`] makes.
const LIVE_TIMES: usize = 20;
/// How many writes [`DROPPED_IS_SILENT`] makes after the drop.
const AFTER_DROP: usize = 200;
/// How many times [`TREE_NEW_SUBDIRECTORY`] writes its file, at most.
const NEW_SUBDIRECTORY_TRIES: u32 = 20;

/// Holds `watch` to the port's rules in fresh subdirectories of `dir`,
/// which the caller owns and which is there, making every change through
/// `ground`; and returns the names of the properties that fail, in the
/// order of [`PROPERTIES`].
pub fn check<W: Watch + Clone>(watch: W, ground: &impl Ground, dir: &Path) -> Vec<&'static str> {
    let check = Check { watch, ground, dir };
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
        deadline: Duration,
        mut matches: impl FnMut(&Notice) -> bool,
    ) -> bool {
        loop {
            match self.notices.recv_timeout(deadline) {
                Ok(notice) if matches(&notice) => return true,
                Ok(_) => {}
                Err(RecvTimeoutError::Timeout | RecvTimeoutError::Disconnected) => return false,
            }
        }
    }

    /// Reads notices until one at `path` of `kind`.
    pub(crate) fn heard(&self, deadline: Duration, path: &Path, kind: Kind) -> bool {
        self.until(deadline, |notice| {
            notice.path == path && notice.kind == kind
        })
    }

    /// Reads notices until one at `path`, and gives every notice before it;
    /// `None` if none came.
    pub(crate) fn before(&self, deadline: Duration, path: &Path) -> Option<Vec<Notice>> {
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

/// One run of [`check`].
struct Check<'a, W, G> {
    /// What is checked.
    watch: W,
    /// What makes the changes.
    ground: &'a G,
    /// The caller's directory.
    dir: &'a Path,
}

impl<W: Watch + Clone, G: Ground> Check<'_, W, G> {
    /// A fresh directory named `name` in the caller's.
    fn fresh(&self, name: &str) -> PathBuf {
        let dir = self.dir.join(name);
        self.ground.make_dir(&dir);
        dir
    }

    /// The deadline of each wait.
    fn deadline(&self) -> Duration {
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
        let each = self.deadline() / NEW_SUBDIRECTORY_TRIES;
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
}
