//! The ports' fakes, published for this crate's tests and for any crate
//! that drives the core: files that are a map ([`FakeFiles`]), a clock
//! that moves only when waited on ([`FakeClock`]), processes that end on a
//! script ([`FakePids`]), starts and execs that are recorded
//! ([`FakeSpawn`], [`FakeExec`]) and a platform that keeps what it was told
//! to say ([`FakePlatform`]). [`FakeWorld`] holds one of each.
//!
//! The clock's time is shared: [`FakePids`] and [`FakeFiles`] made from a
//! clock read and move the same time, so a wait on a process that ends at
//! 300 ms leaves the clock at 300 ms, and a file scripted to go at 200 ms is
//! gone once the clock has passed it.

use std::cell::Cell;
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::rc::Rc;

use crate::ports::{
    Clock, Exec, FileError, Files, Invocation, Pid, Pids, Platform, Refusal, Spawn, Waited, World,
};

/// A clock that moves only by [`Clock::sleep_ms`] and by waits on
/// [`FakePids`]; clones share one time.
#[derive(Debug, Clone, Default)]
pub struct FakeClock(Rc<Cell<u64>>);

impl FakeClock {
    /// A clock at 0.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Moves the time to `ms`, if that is later.
    pub fn advance_to(&self, ms: u64) {
        if ms > self.0.get() {
            self.0.set(ms);
        }
    }
}

impl Clock for FakeClock {
    fn now_ms(&self) -> u64 {
        self.0.get()
    }

    fn sleep_ms(&mut self, ms: u64) {
        self.0.set(self.0.get() + ms);
    }
}

/// Files that are a map of paths to bytes, read at the shared clock's
/// time: a removal scripted with [`FakeFiles::remove_at`] has happened once
/// the clock has reached it.
#[derive(Debug, Clone, Default)]
pub struct FakeFiles {
    /// Every file and its bytes.
    pub files: BTreeMap<PathBuf, Vec<u8>>,
    clock: FakeClock,
    removals: Vec<(u64, PathBuf)>,
}

impl FakeFiles {
    /// No files, on `clock`'s time.
    #[must_use]
    pub fn new(clock: &FakeClock) -> Self {
        Self {
            clock: clock.clone(),
            ..Self::default()
        }
    }

    /// These files with `path` holding `bytes`.
    #[must_use]
    pub fn with(mut self, path: impl Into<PathBuf>, bytes: impl Into<Vec<u8>>) -> Self {
        self.files.insert(path.into(), bytes.into());
        self
    }

    /// Scripts `path` to be removed, as by another process, at `ms`.
    pub fn remove_at(&mut self, ms: u64, path: impl Into<PathBuf>) {
        self.removals.push((ms, path.into()));
    }

    /// The file's bytes as text, if it is there.
    #[must_use]
    pub fn text(&self, path: &Path) -> Option<String> {
        self.read(path)
            .ok()
            .map(|b| String::from_utf8_lossy(&b).into_owned())
    }

    fn removed(&self, path: &Path) -> bool {
        let now = self.clock.now_ms();
        self.removals.iter().any(|(at, p)| *at <= now && p == path)
    }
}

impl Files for FakeFiles {
    fn read(&self, path: &Path) -> Result<Vec<u8>, FileError> {
        if self.removed(path) {
            return Err(FileError::NotFound);
        }
        self.files.get(path).cloned().ok_or(FileError::NotFound)
    }

    fn write_atomic(&mut self, path: &Path, bytes: &[u8]) -> Result<(), FileError> {
        self.removals.retain(|(_, p)| p != path);
        self.files.insert(path.to_owned(), bytes.to_vec());
        Ok(())
    }

    fn rename(&mut self, from: &Path, to: &Path) -> Result<(), FileError> {
        let bytes = self.read(from)?;
        self.files.remove(from);
        self.files.insert(to.to_owned(), bytes);
        Ok(())
    }

    fn remove(&mut self, path: &Path) -> Result<(), FileError> {
        self.files.remove(path);
        Ok(())
    }

    fn exists(&self, path: &Path) -> bool {
        !self.removed(path) && self.files.contains_key(path)
    }
}

/// Processes that end at a scripted time on the shared clock. A pid with
/// no time scripted runs for ever, until it is killed.
#[derive(Debug, Clone)]
pub struct FakePids {
    /// This process's id.
    pub own: Pid,
    /// When each process ends.
    pub ends: HashMap<Pid, u64>,
    /// Every kill asked for, in order.
    pub kills: Vec<Pid>,
    clock: FakeClock,
}

impl FakePids {
    /// This process is `own`, on `clock`'s time, and no process ends.
    #[must_use]
    pub fn new(clock: &FakeClock, own: Pid) -> Self {
        Self {
            own,
            ends: HashMap::new(),
            kills: Vec::new(),
            clock: clock.clone(),
        }
    }

    /// Scripts `pid` to end at `ms`.
    #[must_use]
    pub fn ending(mut self, pid: Pid, ms: u64) -> Self {
        self.ends.insert(pid, ms);
        self
    }
}

impl Pids for FakePids {
    fn own(&self) -> Pid {
        self.own
    }

    fn wait_exit(&mut self, pid: Pid, timeout_ms: u64) -> Waited {
        let now = self.clock.now_ms();
        match self.ends.get(&pid) {
            Some(&end) if end <= now + timeout_ms => {
                self.clock.advance_to(end);
                Waited::Exited
            }
            _ => {
                self.clock.advance_to(now + timeout_ms);
                Waited::Running
            }
        }
    }

    fn kill(&mut self, pid: Pid) {
        self.kills.push(pid);
        let now = self.clock.now_ms();
        let end = self.ends.entry(pid).or_insert(now);
        *end = (*end).min(now);
    }
}

/// Detached starts, recorded; each is given the next pid from 1000.
#[derive(Debug, Clone, Default)]
pub struct FakeSpawn {
    /// Every invocation started, in order.
    pub spawned: Vec<Invocation>,
    /// Refuses every start with this reason, when set.
    pub refuse: Option<String>,
}

impl Spawn for FakeSpawn {
    fn spawn_detached(&mut self, invocation: &Invocation) -> Result<Pid, String> {
        if let Some(reason) = &self.refuse {
            return Err(reason.clone());
        }
        self.spawned.push(invocation.clone());
        Ok(Pid(1000
            + u32::try_from(self.spawned.len())
                .unwrap_or(u32::MAX - 1000)))
    }
}

/// Execs, recorded. A program in [`FakeExec::refusals`] is refused with
/// its refusal and the core carries on; any other answers
/// [`Refusal::Faked`], after which the core stops as if replaced.
#[derive(Debug, Clone, Default)]
pub struct FakeExec {
    /// Every invocation exec'd, in order, refused ones among them.
    pub execs: Vec<Invocation>,
    /// The programs the exec refuses, and how.
    pub refusals: HashMap<PathBuf, Refusal>,
}

impl FakeExec {
    /// These execs refusing `program` with `refusal`.
    #[must_use]
    pub fn refusing(mut self, program: impl Into<PathBuf>, refusal: Refusal) -> Self {
        self.refusals.insert(program.into(), refusal);
        self
    }
}

impl Exec for FakeExec {
    fn exec(&mut self, invocation: &Invocation) -> Refusal {
        self.execs.push(invocation.clone());
        self.refusals
            .get(&invocation.program)
            .cloned()
            .unwrap_or(Refusal::Faked)
    }
}

/// The launcher's facts, as given, and every line it said.
#[derive(Debug, Clone, Default)]
pub struct FakePlatform {
    /// Its own path.
    pub own_path: PathBuf,
    /// Whether it is macOS.
    pub macos: bool,
    /// Every line said, in order.
    pub said: Vec<String>,
}

impl Platform for FakePlatform {
    fn own_path(&self) -> PathBuf {
        self.own_path.clone()
    }

    fn is_macos(&self) -> bool {
        self.macos
    }

    fn say(&mut self, line: &str) {
        self.said.push(line.to_owned());
    }
}

/// One of each fake, on one clock.
#[derive(Debug, Clone)]
pub struct FakeWorld {
    /// The files.
    pub files: FakeFiles,
    /// The clock.
    pub clock: FakeClock,
    /// The processes; this one is pid 100.
    pub pids: FakePids,
    /// The detached starts.
    pub spawn: FakeSpawn,
    /// The execs.
    pub exec: FakeExec,
    /// The platform.
    pub platform: FakePlatform,
}

impl FakeWorld {
    /// A launcher at `own_path`, on macOS or not, with no file, as pid
    /// 100 at time 0.
    #[must_use]
    pub fn new(own_path: impl Into<PathBuf>, macos: bool) -> Self {
        let clock = FakeClock::new();
        Self {
            files: FakeFiles::new(&clock),
            pids: FakePids::new(&clock, Pid(100)),
            clock,
            spawn: FakeSpawn::default(),
            exec: FakeExec::default(),
            platform: FakePlatform {
                own_path: own_path.into(),
                macos,
                said: Vec::new(),
            },
        }
    }

    /// The ports, lent for a call.
    pub fn world(&mut self) -> World<'_> {
        World {
            files: &mut self.files,
            clock: &mut self.clock,
            pids: &mut self.pids,
            spawn: &mut self.spawn,
            exec: &mut self.exec,
            platform: &mut self.platform,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_clock_moves_only_when_waited_on_and_clones_share_it() {
        let mut clock = FakeClock::new();
        let other = clock.clone();
        clock.sleep_ms(30);
        assert_eq!(other.now_ms(), 30);
        other.advance_to(10);
        assert_eq!(clock.now_ms(), 30);
    }

    #[test]
    fn a_process_ends_at_its_time_and_a_wait_moves_the_clock() {
        let clock = FakeClock::new();
        let mut pids = FakePids::new(&clock, Pid(1)).ending(Pid(5), 300);
        assert_eq!(pids.wait_exit(Pid(5), 100), Waited::Running);
        assert_eq!(clock.now_ms(), 100);
        assert_eq!(pids.wait_exit(Pid(5), 1000), Waited::Exited);
        assert_eq!(clock.now_ms(), 300);
        assert_eq!(pids.wait_exit(Pid(6), 50), Waited::Running);
        pids.kill(Pid(6));
        assert_eq!(pids.wait_exit(Pid(6), 0), Waited::Exited);
        assert_eq!(pids.kills, [Pid(6)]);
    }

    #[test]
    fn files_are_a_map_and_a_scripted_removal_happens_at_its_time() {
        let mut clock = FakeClock::new();
        let mut files = FakeFiles::new(&clock).with("/a", "x");
        files.remove_at(200, "/a");
        assert!(files.exists(Path::new("/a")));
        clock.sleep_ms(200);
        assert!(!files.exists(Path::new("/a")));
        assert_eq!(files.read(Path::new("/a")), Err(FileError::NotFound));
        files.write_atomic(Path::new("/a"), b"y").unwrap();
        assert_eq!(files.text(Path::new("/a")).as_deref(), Some("y"));
        files.rename(Path::new("/a"), Path::new("/b")).unwrap();
        assert!(!files.exists(Path::new("/a")));
        assert_eq!(
            files.rename(Path::new("/a"), Path::new("/c")),
            Err(FileError::NotFound)
        );
        files.remove(Path::new("/b")).unwrap();
        files.remove(Path::new("/b")).unwrap();
        assert!(files.files.is_empty());
    }

    #[test]
    fn execs_and_spawns_are_recorded_and_a_refused_program_answers_its_refusal() {
        let mut exec = FakeExec::default().refusing("/bad", Refusal::NotFound("gone".into()));
        assert_eq!(
            exec.exec(&Invocation::new("/bad")),
            Refusal::NotFound("gone".into())
        );
        assert_eq!(exec.exec(&Invocation::new("/good")), Refusal::Faked);
        assert_eq!(exec.execs.len(), 2);
        let mut spawn = FakeSpawn::default();
        assert_eq!(spawn.spawn_detached(&Invocation::new("/w")), Ok(Pid(1001)));
        assert_eq!(spawn.spawn_detached(&Invocation::new("/w")), Ok(Pid(1002)));
        spawn.refuse = Some("no".into());
        assert_eq!(
            spawn.spawn_detached(&Invocation::new("/w")),
            Err("no".into())
        );
        assert_eq!(spawn.spawned.len(), 2);
    }
}
