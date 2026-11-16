//! The fake of the port: a file system in memory and the registrations on
//! it, published so that everything above the port is tested with no real
//! file and no real watch.
//!
//! [`FakeWatch`] keeps a set of directories and files, from `/` alone, and
//! a list of live registrations. [`FakeWatch::notice`] tells a notice, on
//! the calling thread, to the sink of every live registration that covers
//! its path by the port's rule: a registration of [`Depth::Entries`] covers
//! its directory and what is directly inside it, one of [`Depth::Tree`]
//! everything under it. Its ground ([`FakeWatch::ground`], a
//! [`FakeGround`]) changes the file system and tells the notices a real one
//! would: a write to a new file is [`Kind::Created`] then
//! [`Kind::Written`], a rename is [`Kind::Renamed`] under the old path then
//! under the new one, a rename over a file replaces it.
//!
//! It keeps the port's rules, which `tests/contract.rs` holds it to:
//!
//! - [`Watch::watch`] of a directory that is not there is
//!   [`RefusalKind::NotFound`], and of a file
//!   [`RefusalKind::NotADirectory`]; a refusal can be scripted for any
//!   directory ([`FakeWatch::refuse`]);
//! - a registration is live when `watch` returns;
//! - a directory reached through a link ([`FakeGround::link`]) is told
//!   under the spelling it was registered with;
//! - once a registration's drop has returned, its sink is never called
//!   again: each registration has a gate, which a notice holds open while
//!   it calls the sink and which the drop shuts, as the real adapter's
//!   does.
//!
//! It records every `watch` call, every refusal and every drop
//! ([`Record`]), and gives the registrations still up
//! ([`FakeWatch::live`]). A test can wait on the record with a deadline
//! ([`FakeWatch::until`]) instead of sleeping, latch every `watch` call
//! until it lets go ([`FakeWatch::hold_watches`]), so it can act while a
//! start is in flight, and have every drop call its sink once before it
//! returns ([`FakeWatch::call_sinks_on_drop`]), as a platform's drop that
//! joins a thread in the sink does, which is how a test sees that a
//! registration is never dropped under its user's lock.
//!
//! [`Flaws`] makes a fake that breaks a rule, for the contract's own tests:
//! that is how they show the contract bites.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError, RwLock};
use std::time::Duration;

use crate::contract::Ground;
use crate::{Depth, Kind, Notice, Refusal, RefusalKind, Sink, Watch};

/// The rules a flawed fake breaks, each a rule of the port.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "each flaw is one rule broken, set on its own"
)]
pub struct Flaws {
    /// Now and then a registration is not live when `watch` returns: the
    /// twentieth the fake makes misses every notice of the first path it
    /// is told of, until it is told of another.
    pub live_late: bool,
    /// A creation is not told.
    pub misses_creation: bool,
    /// A write is not told.
    pub misses_writes: bool,
    /// A removal is not told.
    pub misses_removal: bool,
    /// A rename is not told, under either path.
    pub drops_renames: bool,
    /// A rename over a path that is there is told under the old path only.
    pub misses_rename_over: bool,
    /// A registration of the tree covers only its directory's entries.
    pub no_tree: bool,
    /// A registration of the tree covers only the directories that were
    /// there when `watch` returned.
    pub no_new_subdirectories: bool,
    /// A directory reached through a link is told under its canonical
    /// spelling, not the one it was registered with.
    pub canonical_spelling: bool,
    /// Dropping a registration ends every registration of its directory.
    pub shared_drop: bool,
    /// A dropped registration's sink is still called.
    pub late_after_drop: bool,
    /// Every directory is watched, one that is not there and a file among
    /// them.
    pub accepts_anything: bool,
}

/// The serial of the registration that is not live when `watch` returns,
/// with [`Flaws::live_late`].
const LATE_SERIAL: u64 = 20;

/// How long the contract waits, on the fake, for what should happen at
/// once. The fake tells its notices before its ground returns, so only a
/// flawed fake, or a service that breaks a rule, takes this long.
const FAKE_DEADLINE: Duration = Duration::from_secs(2);

/// What the fake was asked.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Record {
    /// Every `watch` call, its directory as it was given and its depth, in
    /// order, a refused one among them.
    pub watched: Vec<(PathBuf, Depth)>,
    /// Every refusal, by directory and kind.
    pub refused: Vec<(PathBuf, RefusalKind)>,
    /// Every drop of a registration, by directory and depth.
    pub dropped: Vec<(PathBuf, Depth)>,
    /// How many `watch` calls are parked by [`FakeWatch::hold_watches`].
    pub parked: usize,
}

/// One registration's gate: open while its sink may be called. A notice
/// holds it for reading while it calls the sink; the drop shuts it,
/// holding it for writing, so once the drop returns no call is in flight.
type Gate = Arc<RwLock<bool>>;

/// A registration, as the fake keeps it.
struct Live {
    /// Its serial, which names it to its drop.
    serial: u64,
    /// Its directory, as it was given.
    given: PathBuf,
    /// Its directory, with every link resolved.
    canonical: PathBuf,
    /// What it covers.
    depth: Depth,
    /// Where its notices go.
    sink: Sink,
    /// Its gate.
    gate: Gate,
    /// Whether it is not yet live ([`Flaws::live_late`]), and the first
    /// path it was told of, whose notices it misses until another comes.
    late: Option<Option<PathBuf>>,
    /// The directories under it when it was made
    /// ([`Flaws::no_new_subdirectories`]).
    known: BTreeSet<PathBuf>,
    /// Whether it was dropped, and is kept only to break a rule
    /// ([`Flaws::late_after_drop`]).
    dropped: bool,
}

impl Live {
    /// Whether it covers `path`, a canonical path, with `flaws`.
    fn covers(&self, path: &Path, flaws: Flaws) -> bool {
        let entry = path == self.canonical || path.parent() == Some(&self.canonical);
        match self.depth {
            Depth::Entries => entry,
            Depth::Tree if flaws.no_tree => entry,
            Depth::Tree if flaws.no_new_subdirectories => {
                entry
                    || path
                        .parent()
                        .is_some_and(|parent| self.known.contains(parent))
            }
            Depth::Tree => path.starts_with(&self.canonical),
        }
    }
}

/// What the fake holds.
struct State {
    /// The rules it breaks.
    flaws: Flaws,
    /// The directories of its file system, canonical.
    dirs: BTreeSet<PathBuf>,
    /// The files of its file system, canonical.
    files: BTreeSet<PathBuf>,
    /// Each link and the directory it points to.
    links: Vec<(PathBuf, PathBuf)>,
    /// The registrations, in the order they were made.
    live: Vec<Live>,
    /// The next registration's serial.
    serial: u64,
    /// Each scripted refusal, by directory as it is given.
    refusals: Vec<(PathBuf, Refusal)>,
    /// Whether `watch` calls are latched.
    held: bool,
    /// Whether every drop calls its sink once.
    sinks_on_drop: bool,
    /// What it was asked.
    record: Record,
}

impl State {
    /// `path` with every link resolved.
    fn resolve(&self, path: &Path) -> PathBuf {
        for (link, target) in &self.links {
            if let Ok(rest) = path.strip_prefix(link) {
                return target.join(rest);
            }
        }
        path.to_path_buf()
    }
}

/// What a fake's clones share.
struct Shared {
    /// The state.
    state: Mutex<State>,
    /// Told whenever the state changes.
    changed: Condvar,
}

impl Shared {
    /// Locks the state. The lock is never held while a sink is called.
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// The port's fake. The module docs have its rules. A cheap handle: clones
/// share one fake.
#[derive(Clone)]
pub struct FakeWatch {
    /// What its clones share.
    shared: Arc<Shared>,
}

impl Default for FakeWatch {
    fn default() -> Self {
        Self::new()
    }
}

/// A registration of the fake's. Dropping it ends it.
pub struct FakeRegistration {
    /// The fake it is of.
    fake: FakeWatch,
    /// Its serial.
    serial: u64,
}

/// The fake's ground: changes to its file system, each told as the
/// notices a real one would make. It is the contract's ground for the
/// fake.
#[derive(Clone)]
pub struct FakeGround {
    /// The fake whose file system it changes.
    fake: FakeWatch,
}

impl FakeWatch {
    /// A fake whose file system is `/` alone, and that keeps every rule.
    pub fn new() -> Self {
        Self::flawed(Flaws::default())
    }

    /// A fake that breaks the rules `flaws` names.
    pub fn flawed(flaws: Flaws) -> Self {
        Self {
            shared: Arc::new(Shared {
                state: Mutex::new(State {
                    flaws,
                    dirs: BTreeSet::from([PathBuf::from("/")]),
                    files: BTreeSet::new(),
                    links: Vec::new(),
                    live: Vec::new(),
                    serial: 0,
                    refusals: Vec::new(),
                    held: false,
                    sinks_on_drop: false,
                    record: Record::default(),
                }),
                changed: Condvar::new(),
            }),
        }
    }

    /// Tells a notice of `kind` at `path` to the sink of every live
    /// registration that covers it, on this thread, before it returns. A
    /// path reached through a link is told under each registration's
    /// spelling.
    pub fn notice(&self, path: impl AsRef<Path>, kind: Kind) {
        let calls = {
            let mut state = self.shared.state();
            let path = state.resolve(path.as_ref());
            let flaws = state.flaws;
            let lost = match kind {
                Kind::Created => flaws.misses_creation,
                Kind::Written => flaws.misses_writes,
                Kind::Removed => flaws.misses_removal,
                Kind::Renamed => flaws.drops_renames,
                Kind::Missed => false,
            };
            let mut calls = Vec::new();
            for live in &mut state.live {
                if !live.covers(&path, flaws) {
                    continue;
                }
                if let Some(first) = &mut live.late {
                    let first = first.get_or_insert_with(|| path.clone());
                    if *first == path {
                        continue;
                    }
                    live.late = None;
                }
                if lost {
                    continue;
                }
                let told = if flaws.canonical_spelling {
                    path.clone()
                } else {
                    path.strip_prefix(&live.canonical)
                        .map_or_else(|_| path.clone(), |rest| join(&live.given, rest))
                };
                calls.push((
                    Arc::clone(&live.gate),
                    Arc::clone(&live.sink),
                    Notice::new(told, kind),
                ));
            }
            calls
        };
        for (gate, sink, notice) in calls {
            let open = gate.read().unwrap_or_else(PoisonError::into_inner);
            if *open {
                sink(notice);
            }
        }
    }

    /// What it was asked, so far.
    pub fn record(&self) -> Record {
        self.shared.state().record.clone()
    }

    /// The registrations still up, by directory as it was given and depth,
    /// in the order they were made.
    pub fn live(&self) -> Vec<(PathBuf, Depth)> {
        self.shared
            .state()
            .live
            .iter()
            .filter(|live| !live.dropped)
            .map(|live| (live.given.clone(), live.depth))
            .collect()
    }

    /// Makes every later `watch` of `directory`, as it is given, come to
    /// `refusal`.
    pub fn refuse(&self, directory: impl Into<PathBuf>, refusal: Refusal) {
        self.shared
            .state()
            .refusals
            .push((directory.into(), refusal));
    }

    /// Parks every later `watch` call, once it is recorded, until
    /// [`release_watches`](Self::release_watches).
    pub fn hold_watches(&self) {
        self.shared.state().held = true;
    }

    /// Lets every parked `watch` call go on, and holds none from now on.
    pub fn release_watches(&self) {
        self.shared.state().held = false;
        self.shared.changed.notify_all();
    }

    /// Makes every later drop of a registration call its sink once, with
    /// [`Kind::Missed`] on its directory, before it shuts its gate.
    pub fn call_sinks_on_drop(&self) {
        self.shared.state().sinks_on_drop = true;
    }

    /// Waits until `ready` holds of the record, up to `deadline`, and says
    /// whether it did.
    pub fn until(&self, deadline: Duration, ready: impl Fn(&Record) -> bool) -> bool {
        let (state, _) = self
            .shared
            .changed
            .wait_timeout_while(self.shared.state(), deadline, |state| !ready(&state.record))
            .unwrap_or_else(PoisonError::into_inner);
        ready(&state.record)
    }

    /// Its ground: changes to its file system, told as notices.
    pub fn ground(&self) -> FakeGround {
        FakeGround { fake: self.clone() }
    }

    /// Changes the state with `change`, and tells whoever waits on it.
    fn change<T>(&self, change: impl FnOnce(&mut State) -> T) -> T {
        let result = change(&mut self.shared.state());
        self.shared.changed.notify_all();
        result
    }

    /// Ends the registration `serial`.
    fn end(&self, serial: u64) {
        let (gates, call) = self.change(|state| {
            let flaws = state.flaws;
            let Some(index) = state.live.iter().position(|live| live.serial == serial) else {
                return (Vec::new(), None);
            };
            let live = &state.live[index];
            let entry = (live.given.clone(), live.depth);
            let canonical = live.canonical.clone();
            let call = state
                .sinks_on_drop
                .then(|| (Arc::clone(&live.sink), live.given.clone()));
            state.record.dropped.push(entry);
            if flaws.late_after_drop {
                state.live[index].dropped = true;
                return (Vec::new(), call);
            }
            let mut gates = Vec::new();
            state.live.retain(|live| {
                let ends =
                    live.serial == serial || (flaws.shared_drop && live.canonical == canonical);
                if ends {
                    gates.push(Arc::clone(&live.gate));
                }
                !ends
            });
            (gates, call)
        });
        if let Some((sink, directory)) = call {
            sink(Notice::new(directory, Kind::Missed));
        }
        for gate in gates {
            *gate.write().unwrap_or_else(PoisonError::into_inner) = false;
        }
    }
}

/// `base` joined with `rest`, which may be empty.
fn join(base: &Path, rest: &Path) -> PathBuf {
    if rest.as_os_str().is_empty() {
        base.to_path_buf()
    } else {
        base.join(rest)
    }
}

impl Watch for FakeWatch {
    type Registration = FakeRegistration;

    fn watch(
        &self,
        directory: &Path,
        depth: Depth,
        sink: Sink,
    ) -> Result<FakeRegistration, Refusal> {
        let parked = self.change(|state| {
            state.record.watched.push((directory.to_path_buf(), depth));
            if state.held {
                state.record.parked += 1;
            }
            state.held
        });
        let mut state = self
            .shared
            .changed
            .wait_while(self.shared.state(), |state| state.held)
            .unwrap_or_else(PoisonError::into_inner);
        if parked {
            state.record.parked -= 1;
        }
        let refusal = state
            .refusals
            .iter()
            .find(|(of, _)| of == directory)
            .map(|(_, refusal)| refusal.clone())
            .or_else(|| {
                let canonical = state.resolve(directory);
                if state.flaws.accepts_anything || state.dirs.contains(&canonical) {
                    None
                } else if state.files.contains(&canonical) {
                    Some(Refusal::new(
                        RefusalKind::NotADirectory,
                        format!(
                            "cannot watch {}: it is not a directory",
                            directory.display()
                        ),
                    ))
                } else {
                    Some(Refusal::new(
                        RefusalKind::NotFound,
                        format!("cannot watch {}: it is not there", directory.display()),
                    ))
                }
            });
        let result = if let Some(refusal) = refusal {
            state
                .record
                .refused
                .push((directory.to_path_buf(), refusal.kind));
            Err(refusal)
        } else {
            let canonical = state.resolve(directory);
            let known = state
                .dirs
                .iter()
                .filter(|dir| dir.starts_with(&canonical))
                .cloned()
                .collect();
            state.serial += 1;
            let serial = state.serial;
            let late = (state.flaws.live_late && serial == LATE_SERIAL).then_some(None);
            state.live.push(Live {
                serial,
                given: directory.to_path_buf(),
                canonical,
                depth,
                sink,
                gate: Arc::new(RwLock::new(true)),
                late,
                known,
                dropped: false,
            });
            Ok(FakeRegistration {
                fake: self.clone(),
                serial,
            })
        };
        drop(state);
        self.shared.changed.notify_all();
        result
    }
}

impl Drop for FakeRegistration {
    fn drop(&mut self) {
        self.fake.end(self.serial);
    }
}

impl FakeGround {
    /// Writes `bytes` to the file at `path`: [`Kind::Created`] first if it
    /// was not there, then [`Kind::Written`].
    pub fn write(&self, path: &Path, bytes: &[u8]) {
        let _ = bytes;
        let made = self.fake.change(|state| {
            let path = state.resolve(path);
            state.files.insert(path)
        });
        if made {
            self.fake.notice(path, Kind::Created);
        }
        self.fake.notice(path, Kind::Written);
    }

    /// Writes to the file at `path` `times` times, one byte each.
    pub fn write_times(&self, path: &Path, times: usize) {
        for _ in 0..times {
            self.write(path, b"x");
        }
    }

    /// Makes the directory `path`: [`Kind::Created`].
    pub fn make_dir(&self, path: &Path) {
        self.fake.change(|state| {
            let path = state.resolve(path);
            state.dirs.insert(path);
        });
        self.fake.notice(path, Kind::Created);
    }

    /// Renames `from` to `to`, replacing a file at `to`, and moving what is
    /// in a directory with it: [`Kind::Renamed`] under `from`, then under
    /// `to`.
    pub fn rename(&self, from: &Path, to: &Path) {
        let (over, misses_over) = self.fake.change(|state| {
            let (old, new) = (state.resolve(from), state.resolve(to));
            let over = state.files.contains(&new) || state.dirs.contains(&new);
            let moved = |set: &mut BTreeSet<PathBuf>| {
                let under: Vec<PathBuf> = set
                    .iter()
                    .filter(|p| p.starts_with(&old))
                    .cloned()
                    .collect();
                for path in under {
                    set.remove(&path);
                    let rest = path
                        .strip_prefix(&old)
                        .map(Path::to_path_buf)
                        .unwrap_or_default();
                    set.insert(join(&new, &rest));
                }
            };
            moved(&mut state.files);
            moved(&mut state.dirs);
            (over, state.flaws.misses_rename_over)
        });
        self.fake.notice(from, Kind::Renamed);
        if !(over && misses_over) {
            self.fake.notice(to, Kind::Renamed);
        }
    }

    /// Removes the file or the directory at `path`, and what is in it:
    /// [`Kind::Removed`].
    pub fn remove(&self, path: &Path) {
        self.fake.change(|state| {
            let path = state.resolve(path);
            state.files.retain(|file| !file.starts_with(&path));
            state.dirs.retain(|dir| !dir.starts_with(&path));
        });
        self.fake.notice(path, Kind::Removed);
    }

    /// Makes `link` a link to the directory `to`: [`Kind::Created`] under
    /// `link`.
    pub fn link(&self, link: &Path, to: &Path) {
        self.fake.change(|state| {
            let to = state.resolve(to);
            state.links.push((link.to_path_buf(), to));
        });
        self.fake.notice(link, Kind::Created);
    }
}

impl Ground for FakeGround {
    fn write(&self, path: &Path, bytes: &[u8]) {
        Self::write(self, path, bytes);
    }

    fn write_times(&self, path: &Path, times: usize) {
        Self::write_times(self, path, times);
    }

    fn make_dir(&self, path: &Path) {
        Self::make_dir(self, path);
    }

    fn rename(&self, from: &Path, to: &Path) {
        Self::rename(self, from, to);
    }

    fn remove(&self, path: &Path) {
        Self::remove(self, path);
    }

    fn link(&self, link: &Path, to: &Path) {
        Self::link(self, link, to);
    }

    fn deadline(&self) -> Duration {
        FAKE_DEADLINE
    }
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};
    use std::sync::mpsc::{self, Receiver};
    use std::sync::{Arc, Mutex, PoisonError};
    use std::thread;
    use std::time::Duration;

    use super::{FakeWatch, Flaws, Record};
    use crate::{Depth, Kind, Notice, Refusal, RefusalKind, Sink, Watch};

    /// How long a test waits for what should happen at once.
    const DEADLINE: Duration = Duration::from_secs(5);

    /// A sink that sends each notice, and what it sends.
    fn sink() -> (Sink, Receiver<Notice>) {
        let (sender, notices) = mpsc::channel();
        let sender = Mutex::new(sender);
        let sink: Sink = Arc::new(move |notice| {
            sender
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .send(notice)
                .ok();
        });
        (sink, notices)
    }

    fn told(notices: &Receiver<Notice>) -> Vec<Notice> {
        notices.try_iter().collect()
    }

    fn notice(path: &str, kind: Kind) -> Notice {
        Notice::new(path, kind)
    }

    /// A fake whose ground has `/w/sub/deeper`.
    fn fake() -> FakeWatch {
        let fake = FakeWatch::new();
        let ground = fake.ground();
        for dir in ["/w", "/w/sub", "/w/sub/deeper"] {
            ground.make_dir(Path::new(dir));
        }
        fake
    }

    #[test]
    fn an_entries_registration_is_told_of_its_directory_and_what_is_directly_inside_it() {
        let fake = fake();
        let (sink, notices) = sink();
        let _registration = fake
            .watch(Path::new("/w"), Depth::Entries, sink)
            .expect("watched");

        fake.notice("/w", Kind::Removed);
        fake.notice("/w/a", Kind::Written);
        fake.notice("/w/sub", Kind::Created);
        fake.notice("/w/sub/b", Kind::Written);
        fake.notice("/other/a", Kind::Written);
        fake.notice("/wx", Kind::Written);

        assert_eq!(
            told(&notices),
            [
                notice("/w", Kind::Removed),
                notice("/w/a", Kind::Written),
                notice("/w/sub", Kind::Created)
            ]
        );
    }

    #[test]
    fn a_tree_registration_is_told_of_everything_under_its_directory() {
        let fake = fake();
        let (sink, notices) = sink();
        let _registration = fake
            .watch(Path::new("/w"), Depth::Tree, sink)
            .expect("watched");

        fake.notice("/w/a", Kind::Written);
        fake.notice("/w/sub/deeper/c", Kind::Written);
        fake.notice("/wx/a", Kind::Written);

        assert_eq!(
            told(&notices),
            [
                notice("/w/a", Kind::Written),
                notice("/w/sub/deeper/c", Kind::Written)
            ]
        );
    }

    #[test]
    fn the_record_has_every_watch_refusal_and_drop_and_live_has_what_is_still_up() {
        let fake = fake();
        let (sink, _notices) = sink();

        let entries = fake
            .watch(Path::new("/w"), Depth::Entries, Arc::clone(&sink))
            .expect("watched");
        let tree = fake
            .watch(Path::new("/w/sub"), Depth::Tree, Arc::clone(&sink))
            .expect("watched");
        assert!(
            fake.watch(Path::new("/nowhere"), Depth::Tree, sink)
                .is_err()
        );
        drop(entries);

        assert_eq!(
            fake.record(),
            Record {
                watched: vec![
                    ("/w".into(), Depth::Entries),
                    ("/w/sub".into(), Depth::Tree),
                    ("/nowhere".into(), Depth::Tree)
                ],
                refused: vec![("/nowhere".into(), RefusalKind::NotFound)],
                dropped: vec![("/w".into(), Depth::Entries)],
                parked: 0,
            }
        );
        assert_eq!(fake.live(), [(PathBuf::from("/w/sub"), Depth::Tree)]);
        drop(tree);
        assert_eq!(fake.live(), []);
    }

    #[test]
    fn a_directory_that_is_not_there_or_is_a_file_is_refused_and_a_scripted_refusal_is_given() {
        let fake = fake();
        fake.ground().write(Path::new("/w/file"), b"x");
        fake.refuse("/w/sub", Refusal::new(RefusalKind::Limit, "too many"));
        let watch = |dir: &str| {
            let (sink, _notices) = sink();
            fake.watch(Path::new(dir), Depth::Entries, sink)
                .err()
                .map(|refusal| refusal.kind)
        };

        assert_eq!(watch("/nowhere"), Some(RefusalKind::NotFound));
        assert_eq!(watch("/w/file"), Some(RefusalKind::NotADirectory));
        assert_eq!(watch("/w/sub"), Some(RefusalKind::Limit));
        assert_eq!(watch("/w"), None);
    }

    #[test]
    fn a_held_watch_call_parks_until_it_is_released() {
        let fake = fake();
        fake.hold_watches();

        thread::scope(|scope| {
            let watching = scope.spawn(|| {
                let (sink, _notices) = sink();
                fake.watch(Path::new("/w"), Depth::Entries, sink)
            });
            assert!(fake.until(DEADLINE, |record| record.parked == 1));
            assert_eq!(fake.live(), []);
            fake.release_watches();
            let registration = watching.join().expect("the watch returns");
            assert!(registration.is_ok());
            assert_eq!(fake.live().len(), 1);
        });

        assert_eq!(fake.record().parked, 0);
    }

    #[test]
    fn after_a_drop_returns_its_sink_is_never_called_and_another_registration_is_whole() {
        let fake = fake();
        let (first, first_told) = sink();
        let (second, second_told) = sink();
        let one = fake
            .watch(Path::new("/w"), Depth::Entries, first)
            .expect("watched");
        let _two = fake
            .watch(Path::new("/w"), Depth::Entries, second)
            .expect("watched");

        drop(one);
        fake.notice("/w/a", Kind::Written);

        assert_eq!(told(&first_told), []);
        assert_eq!(told(&second_told), [notice("/w/a", Kind::Written)]);
    }

    #[test]
    fn a_fake_told_to_calls_each_sink_once_in_its_drop_with_missed_on_the_directory() {
        let fake = fake();
        fake.call_sinks_on_drop();
        let (sink, notices) = sink();
        let registration = fake
            .watch(Path::new("/w"), Depth::Entries, sink)
            .expect("watched");

        drop(registration);
        fake.notice("/w/a", Kind::Written);

        assert_eq!(told(&notices), [notice("/w", Kind::Missed)]);
    }

    #[test]
    fn the_ground_makes_the_notices_a_file_system_makes() {
        let fake = fake();
        let (sink, notices) = sink();
        let _registration = fake
            .watch(Path::new("/w"), Depth::Entries, sink)
            .expect("watched");
        let ground = fake.ground();

        ground.write(Path::new("/w/a"), b"1");
        ground.write(Path::new("/w/a"), b"2");
        ground.write_times(Path::new("/w/a"), 2);
        ground.make_dir(Path::new("/w/d"));
        ground.rename(Path::new("/w/a"), Path::new("/w/b"));
        ground.remove(Path::new("/w/b"));

        assert_eq!(
            told(&notices),
            [
                notice("/w/a", Kind::Created),
                notice("/w/a", Kind::Written),
                notice("/w/a", Kind::Written),
                notice("/w/a", Kind::Written),
                notice("/w/a", Kind::Written),
                notice("/w/d", Kind::Created),
                notice("/w/a", Kind::Renamed),
                notice("/w/b", Kind::Renamed),
                notice("/w/b", Kind::Removed)
            ]
        );
    }

    #[test]
    fn a_rename_over_a_file_replaces_it_and_a_rename_of_a_directory_moves_what_is_in_it() {
        let fake = fake();
        let ground = fake.ground();
        ground.write(Path::new("/w/a"), b"a");
        ground.write(Path::new("/w/b"), b"b");
        ground.write(Path::new("/w/sub/c"), b"c");

        ground.rename(Path::new("/w/a"), Path::new("/w/b"));
        ground.rename(Path::new("/w/sub"), Path::new("/w/moved"));

        let watch = |dir: &str| {
            let (sink, _notices) = sink();
            fake.watch(Path::new(dir), Depth::Entries, sink)
                .err()
                .map(|refusal| refusal.kind)
        };
        assert_eq!(watch("/w/b"), Some(RefusalKind::NotADirectory));
        assert_eq!(watch("/w/a"), Some(RefusalKind::NotFound));
        assert_eq!(watch("/w/sub/deeper"), Some(RefusalKind::NotFound));
        assert_eq!(watch("/w/moved/deeper"), None);
    }

    #[test]
    fn a_directory_registered_through_a_link_is_told_under_the_links_spelling() {
        let fake = fake();
        let ground = fake.ground();
        ground.link(Path::new("/l"), Path::new("/w"));
        let (sink, notices) = sink();
        let _registration = fake
            .watch(Path::new("/l"), Depth::Entries, sink)
            .expect("watched");

        ground.write(Path::new("/w/a"), b"x");
        fake.notice("/l/b", Kind::Removed);

        assert_eq!(
            told(&notices),
            [
                notice("/l/a", Kind::Created),
                notice("/l/a", Kind::Written),
                notice("/l/b", Kind::Removed)
            ]
        );
    }

    #[test]
    fn a_late_fake_s_twentieth_registration_misses_its_first_path_until_another_comes() {
        let fake = FakeWatch::flawed(Flaws {
            live_late: true,
            ..Flaws::default()
        });
        fake.ground().make_dir(Path::new("/w"));
        for _ in 1..20 {
            let (sink, notices) = sink();
            let registration = fake
                .watch(Path::new("/w"), Depth::Entries, sink)
                .expect("watched");
            fake.notice("/w/a", Kind::Written);
            drop(registration);
            assert_eq!(told(&notices), [notice("/w/a", Kind::Written)]);
        }
        let (sink, notices) = sink();
        let _twentieth = fake
            .watch(Path::new("/w"), Depth::Entries, sink)
            .expect("watched");

        fake.notice("/w/a", Kind::Written);
        fake.notice("/w/a", Kind::Created);
        fake.notice("/w/b", Kind::Written);
        fake.notice("/w/a", Kind::Written);

        assert_eq!(
            told(&notices),
            [notice("/w/b", Kind::Written), notice("/w/a", Kind::Written)]
        );
    }
}
