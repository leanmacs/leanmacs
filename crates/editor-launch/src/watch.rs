//! The watcher: the process that outlives an editor the launcher started
//! from a hand-over, and starts the fallback when that editor ends before
//! it has restored the session.
//!
//! The launcher spawns it detached ([`crate::ports::Spawn`]) just before
//! each exec, as `leanmacs --watch <pid> --candidate <exe> --handover
//! <record> --patience <ms>`. It waits for one of three things:
//!
//! - **the record removed**: the new run has restored the session and
//!   written its own index (the hand-shake), or ended cleanly; it exits 0;
//! - **the process ended with the record still there**: whatever its
//!   status, it marks the candidate `failed` in the record and execs
//!   `leanmacs --handover <record>` in its own process, which starts the
//!   next candidate;
//! - **its patience over**: it kills the process (`SIGKILL`), waits for its
//!   end, and does the same.

use std::path::{Path, PathBuf};

use crate::handover;
use crate::ports::{Invocation, Outcome, Pid, Refusal, Waited, World};

/// How long each wait on the process lasts before the record is looked at
/// again.
pub const POLL_MS: u64 = 50;

/// How long the watcher waits for a killed process to end.
pub const KILL_WAIT_MS: u64 = 5_000;

/// What one watcher watches.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Watch {
    /// The process the candidate was exec'd into.
    pub pid: Pid,
    /// The executable it was exec'd into.
    pub candidate: PathBuf,
    /// The hand-over record.
    pub record: PathBuf,
    /// How long it may take to restore the session.
    pub patience_ms: u64,
}

/// Watches until the record goes, the process ends or the patience is over.
pub fn watch(w: &Watch, world: &mut World<'_>) -> Outcome {
    let start = world.clock.now_ms();
    loop {
        if !world.files.exists(&w.record) {
            return Outcome::Exit(0);
        }
        match world.pids.wait_exit(w.pid, POLL_MS) {
            Waited::Exited => {
                if !world.files.exists(&w.record) {
                    return Outcome::Exit(0);
                }
                return fall_back(w, "ended before it restored the session", world);
            }
            Waited::Running => {
                if world.clock.now_ms().saturating_sub(start) >= w.patience_ms {
                    if !world.files.exists(&w.record) {
                        return Outcome::Exit(0);
                    }
                    world.pids.kill(w.pid);
                    world.pids.wait_exit(w.pid, KILL_WAIT_MS);
                    let why = format!(
                        "did not restore the session within {} s, so it was killed",
                        w.patience_ms / 1000
                    );
                    return fall_back(w, &why, world);
                }
            }
        }
    }
}

fn fall_back(w: &Watch, why: &str, world: &mut World<'_>) -> Outcome {
    let record: &Path = &w.record;
    let decoded = world
        .files
        .read(record)
        .map_err(|e| e.to_string())
        .and_then(|bytes| handover::decode(&bytes).map_err(|e| e.to_string()));
    let mut handover = match decoded {
        Ok(handover) => handover,
        Err(reason) => {
            world.platform.say(&format!(
                "leanmacs: {} {why}, and the hand-over {} cannot be read ({reason}); the next start restores the session",
                w.candidate.display(),
                record.display()
            ));
            return Outcome::Exit(1);
        }
    };
    handover.mark_failed(&w.candidate);
    if let Err(reason) = world
        .files
        .write_atomic(record, handover::encode(&handover).as_bytes())
    {
        world.platform.say(&format!(
            "leanmacs: could not mark {} failed in {}: {reason}",
            w.candidate.display(),
            record.display()
        ));
        return Outcome::Exit(1);
    }
    let next = handover.next().map_or_else(
        || "none is left".to_owned(),
        |c| format!("starting {}", c.display()),
    );
    world.platform.say(&format!(
        "leanmacs: {} {why}; {next}",
        w.candidate.display()
    ));
    let own = world.platform.own_path();
    let launcher = Invocation::new(&own).arg("--handover").arg(record);
    match world.exec.exec(&launcher) {
        Refusal::Faked => Outcome::Execed,
        refusal => {
            world.platform.say(&format!(
                "leanmacs: could not start the launcher {}: {refusal}; the next start restores the session",
                own.display()
            ));
            Outcome::Exit(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake::FakeWorld;
    use crate::handover::Handover;
    use crate::ports::{Clock, Files};

    const LAUNCHER: &str = "/A.app/Contents/MacOS/leanmacs";
    const RECORD: &str = "/s/session/handover";

    fn watched(patience_ms: u64) -> (FakeWorld, Watch) {
        let mut fake = FakeWorld::new(LAUNCHER, true);
        let handover = Handover {
            session: "/s/session/session-2.json".into(),
            shipped: "/A.app/Contents/MacOS/editor".into(),
            candidates: vec!["/new/editor".into(), "/A.app/Contents/MacOS/editor".into()],
            arguments: Vec::new(),
            failed: Vec::new(),
        };
        fake.files = fake.files.clone().with(RECORD, handover::encode(&handover));
        let w = Watch {
            pid: Pid(42),
            candidate: "/new/editor".into(),
            record: RECORD.into(),
            patience_ms,
        };
        (fake, w)
    }

    #[test]
    fn the_record_removed_ends_the_watch_with_0() {
        let (mut fake, w) = watched(60_000);
        fake.files.remove_at(700, RECORD);
        assert_eq!(watch(&w, &mut fake.world()), Outcome::Exit(0));
        assert!(fake.clock.now_ms() >= 700 && fake.clock.now_ms() < 800);
        assert!(fake.exec.execs.is_empty());
        assert!(fake.pids.kills.is_empty());
    }

    #[test]
    fn the_process_ending_with_the_record_there_marks_it_failed_and_execs_the_launcher() {
        let (mut fake, w) = watched(60_000);
        fake.pids = fake.pids.clone().ending(Pid(42), 300);
        assert_eq!(watch(&w, &mut fake.world()), Outcome::Execed);
        let record = handover::decode(&fake.files.read(Path::new(RECORD)).unwrap()).unwrap();
        assert_eq!(record.failed, [PathBuf::from("/new/editor")]);
        let exec = &fake.exec.execs[0];
        assert_eq!(exec.program, PathBuf::from(LAUNCHER));
        assert_eq!(exec.args, ["--handover", RECORD]);
        assert_eq!(
            fake.platform.said,
            [
                "leanmacs: /new/editor ended before it restored the session; starting /A.app/Contents/MacOS/editor"
            ]
        );
    }

    #[test]
    fn the_process_ending_after_the_record_went_is_no_failure() {
        let (mut fake, w) = watched(60_000);
        fake.pids = fake.pids.clone().ending(Pid(42), 300);
        fake.files.remove_at(200, RECORD);
        assert_eq!(watch(&w, &mut fake.world()), Outcome::Exit(0));
        assert!(fake.exec.execs.is_empty());
    }

    #[test]
    fn with_its_patience_over_it_kills_the_process_then_falls_back() {
        let (mut fake, w) = watched(1_000);
        assert_eq!(watch(&w, &mut fake.world()), Outcome::Execed);
        assert_eq!(fake.pids.kills, [Pid(42)]);
        assert!(fake.clock.now_ms() >= 1_000);
        assert!(
            fake.platform.said[0]
                .contains("did not restore the session within 1 s, so it was killed")
        );
        let record = handover::decode(&fake.files.read(Path::new(RECORD)).unwrap()).unwrap();
        assert_eq!(record.failed, [PathBuf::from("/new/editor")]);
    }

    #[test]
    fn a_record_it_cannot_read_at_the_end_is_said_and_exits_1() {
        let (mut fake, w) = watched(60_000);
        fake.pids = fake.pids.clone().ending(Pid(42), 10);
        fake.files = fake.files.clone().with(RECORD, "garbage");
        assert_eq!(watch(&w, &mut fake.world()), Outcome::Exit(1));
        assert!(fake.exec.execs.is_empty());
    }
}
