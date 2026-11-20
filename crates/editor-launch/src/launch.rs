//! The launcher's whole decision: which editor to start, with which
//! arguments, and what to do when it cannot be started.
//!
//! ```text
//! leanmacs [--default <exe>] [--data <dir>] [--handover <record>] [--] [<editor arguments>…]
//! leanmacs --watch <pid> --candidate <exe> --handover <record> --patience <ms>
//! ```
//!
//! A command line whose first word is none of these options is all the
//! editor's arguments, so Finder's launch and `leanmacs headless …` both
//! pass straight through. The options share no name with the editor's.
//!
//! - **The default** is the shipped editor: `--default` when given, else
//!   `<bundle>/Contents/MacOS/editor` when the launcher is at
//!   `<bundle>/Contents/MacOS/<name>`. An explicit `--default` wins over
//!   the layout, so a check can start an editor outside the bundle through
//!   the bundle's own launcher. Outside a bundle with no `--default`, a
//!   start that needs the default is refused with status 2.
//! - **A cold start** (no `--handover`) starts the newest per-user editor
//!   of the default's core ([`crate::editors`]), when there is one: the
//!   data directory is `--data` when given, else from `XDG_DATA_HOME` or
//!   `HOME`, and the core is the line of `<default>.core`. It writes a
//!   cold record at `<data>/launch/cold-<pid>`, in the hand-over record's
//!   format with no `session`, naming the newest version, the one before it
//!   when there is one, and the default as candidates, and the arguments;
//!   then it starts that record's first candidate as a hand-over does, so
//!   with its watcher, and with no `--restore`. With no data directory, no
//!   core record, or no complete version, or when an argument is not UTF-8
//!   (which the record cannot hold) or the record cannot be written (said
//!   on standard error), it execs the default with `--launched-by
//!   <launcher> --shipped <default>` and the arguments, as before there
//!   were per-user editors. `--data` is the launcher's alone; no editor is
//!   handed it.
//! - **A hand-over** reads the record ([`crate::handover`]) and tries each
//!   candidate not marked failed, in order. A missing one is marked failed
//!   and skipped. For the one it starts, it first spawns the watcher
//!   ([`crate::watch`]), detached, then execs the candidate with
//!   `--launched-by`, `--shipped`, `--restore <session>` when the record
//!   names a session, `--handed-over <record>`, a `--failed <exe>` for each
//!   failed one, and the record's arguments. An exec that is refused marks
//!   that candidate failed, kills its watcher, and the next is tried in
//!   this same process. With none left, the record is renamed
//!   `<record>.failed` and the launcher exits 1: a restart's index is left
//!   not ended, so the next start restores it.
//! - **A record it cannot read** (a later format, or not a record) is left
//!   as it is, and the launcher starts cold, with no hand-over: the
//!   session is then restored as after an unclean end.
//! - **On macOS** every exec of an editor sets `CFProcessPath` to the
//!   launcher's own path, so CoreFoundation's main bundle is the app
//!   wherever the executable lives (`docs/design/lean-runtime.md`, "The
//!   app's identity across an exec").

use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};

use crate::editors;
use crate::handover::{self, Handover};
use crate::ports::{Invocation, Outcome, Pid, Refusal, World};
use crate::watch::{self, Watch};

/// How long the watcher waits for a started editor to restore the session
/// before it kills it and falls back.
pub const PATIENCE_MS: u64 = 60_000;

/// The variable that points CoreFoundation's main bundle at the app.
pub const CF_PROCESS_PATH: &str = "CFProcessPath";

/// The usage, said on a command line the launcher does not take.
pub const USAGE: &str = "usage: leanmacs [--default <exe>] [--data <dir>] [--handover <record>] [--] [<editor arguments>...]\n       leanmacs --watch <pid> --candidate <exe> --handover <record> --patience <ms>";

/// The launch flags the launcher gives an editor, first on its command
/// line; the editor strips them (`Editor.Restart.Launch.strip`).
pub mod flags {
    /// The launcher that started the editor.
    pub const LAUNCHED_BY: &str = "--launched-by";
    /// The shipped default executable.
    pub const SHIPPED: &str = "--shipped";
    /// The index to restore; a cold start's editor has none.
    pub const RESTORE: &str = "--restore";
    /// The record to remove at the hand-shake, once the session is
    /// restored.
    pub const HANDED_OVER: &str = "--handed-over";
    /// An executable that failed before restoring the session (repeated).
    pub const FAILED: &str = "--failed";
}

/// What a command line asks.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Asked {
    Start {
        default: Option<PathBuf>,
        data: Option<PathBuf>,
        handover: Option<PathBuf>,
        editor: Vec<OsString>,
    },
    Watch(Watch),
}

fn parse(args: &[OsString]) -> Result<Asked, String> {
    if args.first().map(OsString::as_os_str) == Some(OsStr::new("--watch")) {
        return parse_watch(args).map(Asked::Watch);
    }
    let mut default = None;
    let mut data = None;
    let mut handover = None;
    let mut rest = args.iter();
    let mut editor = Vec::new();
    while let Some(word) = rest.next() {
        let value = |rest: &mut std::slice::Iter<'_, OsString>| {
            rest.next()
                .map(PathBuf::from)
                .ok_or_else(|| format!("{} needs a value", word.to_string_lossy()))
        };
        match word.to_str() {
            Some("--default") => default = Some(value(&mut rest)?),
            Some("--data") => data = Some(value(&mut rest)?),
            Some("--handover") => handover = Some(value(&mut rest)?),
            Some("--") => {
                editor.extend(rest.by_ref().cloned());
            }
            _ => {
                editor.push(word.clone());
                editor.extend(rest.by_ref().cloned());
            }
        }
    }
    Ok(Asked::Start {
        default,
        data,
        handover,
        editor,
    })
}

fn parse_watch(args: &[OsString]) -> Result<Watch, String> {
    let mut pid = None;
    let mut candidate = None;
    let mut record = None;
    let mut patience = None;
    let mut rest = args.iter();
    while let Some(word) = rest.next() {
        let value = rest
            .next()
            .ok_or_else(|| format!("{} needs a value", word.to_string_lossy()))?;
        let number = || {
            value
                .to_str()
                .and_then(|v| v.parse::<u64>().ok())
                .ok_or_else(|| format!("{} needs a number", word.to_string_lossy()))
        };
        match word.to_str() {
            Some("--watch") => {
                pid = Some(Pid(u32::try_from(number()?).map_err(|e| e.to_string())?))
            }
            Some("--candidate") => candidate = Some(PathBuf::from(value)),
            Some("--handover") => record = Some(PathBuf::from(value)),
            Some("--patience") => patience = Some(number()?),
            _ => return Err(format!("--watch does not take {}", word.to_string_lossy())),
        }
    }
    match (pid, candidate, record, patience) {
        (Some(pid), Some(candidate), Some(record), Some(patience_ms)) => Ok(Watch {
            pid,
            candidate,
            record,
            patience_ms,
        }),
        _ => Err("--watch needs --candidate, --handover and --patience".to_owned()),
    }
}

/// The shipped default: `explicit` when given, else the bundle's `editor`
/// when `own` is `<bundle>/Contents/MacOS/<name>`.
#[must_use]
pub fn default_editor(own: &Path, explicit: Option<&Path>) -> Option<PathBuf> {
    if let Some(explicit) = explicit {
        return Some(explicit.to_owned());
    }
    let macos = own.parent()?;
    let contents = macos.parent()?;
    (macos.file_name()? == "MacOS" && contents.file_name()? == "Contents")
        .then(|| macos.join("editor"))
}

/// The record's sibling an exhausted hand-over is renamed to.
#[must_use]
pub fn failed_record(record: &Path) -> PathBuf {
    let mut name = record.file_name().unwrap_or_default().to_owned();
    name.push(".failed");
    record.with_file_name(name)
}

/// Runs the launcher on its arguments (the program's name not among them).
/// It answers only when it did not exec, or when the fake exec stopped it.
pub fn run(args: &[OsString], world: &mut World<'_>) -> Outcome {
    match parse(args) {
        Err(why) => {
            world.platform.say(&format!("leanmacs: {why}"));
            world.platform.say(USAGE);
            Outcome::Exit(2)
        }
        Ok(Asked::Watch(w)) => watch::watch(&w, world),
        Ok(Asked::Start {
            default,
            data,
            handover: None,
            editor,
        }) => cold(default.as_deref(), data.as_deref(), &editor, world),
        Ok(Asked::Start {
            default,
            data,
            handover: Some(record),
            editor,
        }) => hand_over(&record, default.as_deref(), data.as_deref(), &editor, world),
    }
}

fn with_identity(invocation: Invocation, world: &World<'_>) -> Invocation {
    if world.platform.is_macos() {
        invocation.set(CF_PROCESS_PATH, world.platform.own_path())
    } else {
        invocation
    }
}

fn cold(
    explicit: Option<&Path>,
    data: Option<&Path>,
    editor: &[OsString],
    world: &mut World<'_>,
) -> Outcome {
    let own = world.platform.own_path();
    let Some(default) = default_editor(&own, explicit) else {
        world.platform.say(&format!(
            "leanmacs: no editor to start: {} is not in an app bundle's Contents/MacOS and no --default was given",
            own.display()
        ));
        world.platform.say(USAGE);
        return Outcome::Exit(2);
    };
    if let Some(outcome) = per_user(&default, data, editor, world) {
        return outcome;
    }
    let invocation = Invocation::new(&default)
        .arg(flags::LAUNCHED_BY)
        .arg(&own)
        .arg(flags::SHIPPED)
        .arg(&default)
        .args(editor.iter().cloned());
    let invocation = with_identity(invocation, world);
    match world.exec.exec(&invocation) {
        Refusal::Faked => Outcome::Execed,
        refusal => {
            world.platform.say(&format!(
                "leanmacs: could not start {}: {refusal}",
                default.display()
            ));
            Outcome::Exit(1)
        }
    }
}

/// The cold start of the newest per-user editor of `default`'s core, as
/// the module docs say; `None` when the default is to start as before.
fn per_user(
    default: &Path,
    data: Option<&Path>,
    editor: &[OsString],
    world: &mut World<'_>,
) -> Option<Outcome> {
    let data = editors::data_dir(data, |name| world.platform.var(name))?;
    let core = world
        .files
        .read(&editors::core_record(default))
        .ok()
        .and_then(|bytes| editors::core_identity(&bytes))?;
    let versions = editors::versions(&*world.files, &data, &core);
    if versions.is_empty() {
        return None;
    }
    let Some(arguments) = editor
        .iter()
        .map(|a| a.to_str().map(str::to_owned))
        .collect::<Option<Vec<String>>>()
    else {
        world.platform.say(
            "leanmacs: an argument is not UTF-8, which a launch record cannot hold, so the shipped default starts",
        );
        return None;
    };
    let record = editors::cold_record(&data, world.pids.own());
    let handover = Handover {
        session: None,
        shipped: default.to_owned(),
        candidates: editors::candidates(&versions, default),
        arguments,
        failed: Vec::new(),
    };
    let written = record
        .parent()
        .map_or(Ok(()), |dir| world.files.make_dir_all(dir))
        .and_then(|()| {
            world
                .files
                .write_atomic(&record, handover::encode(&handover).as_bytes())
        });
    if let Err(why) = written {
        world.platform.say(&format!(
            "leanmacs: could not write the launch record {}: {why}; starting the shipped default",
            record.display()
        ));
        return None;
    }
    Some(start(&record, handover, world))
}

fn persist(record: &Path, handover: &Handover, world: &mut World<'_>) {
    if let Err(why) = world
        .files
        .write_atomic(record, handover::encode(handover).as_bytes())
    {
        world.platform.say(&format!(
            "leanmacs: could not mark the failure in {}: {why}",
            record.display()
        ));
    }
}

/// The editor invocation that starts `candidate` for `handover`: with
/// `--restore <session>` when the record names one (a restart's), and with
/// none when it does not (a cold start's).
fn restoring(
    candidate: &Path,
    record: &Path,
    handover: &Handover,
    world: &World<'_>,
) -> Invocation {
    let mut invocation = Invocation::new(candidate)
        .arg(flags::LAUNCHED_BY)
        .arg(world.platform.own_path())
        .arg(flags::SHIPPED)
        .arg(&handover.shipped);
    if let Some(session) = &handover.session {
        invocation = invocation.arg(flags::RESTORE).arg(session);
    }
    let mut invocation = invocation.arg(flags::HANDED_OVER).arg(record);
    for failed in &handover.failed {
        invocation = invocation.arg(flags::FAILED).arg(failed);
    }
    let invocation = invocation.args(handover.arguments.iter().cloned());
    with_identity(invocation, world)
}

/// The watcher's invocation for `candidate`, run as this process.
#[must_use]
pub fn watcher(own: &Path, pid: Pid, candidate: &Path, record: &Path) -> Invocation {
    Invocation::new(own)
        .arg("--watch")
        .arg(pid.to_string())
        .arg("--candidate")
        .arg(candidate)
        .arg("--handover")
        .arg(record)
        .arg("--patience")
        .arg(PATIENCE_MS.to_string())
}

fn hand_over(
    record: &Path,
    explicit: Option<&Path>,
    data: Option<&Path>,
    editor: &[OsString],
    world: &mut World<'_>,
) -> Outcome {
    let decoded = world
        .files
        .read(record)
        .map_err(|why| format!("it cannot be read: {why}"))
        .and_then(|bytes| handover::decode(&bytes).map_err(|why| why.to_string()));
    match decoded {
        Ok(handover) => start(record, handover, world),
        Err(why) => {
            world.platform.say(&format!(
                "leanmacs: the hand-over {} is not taken: {why}; starting cold with no hand-over, so the session is restored as after an unclean end",
                record.display()
            ));
            cold(explicit, data, editor, world)
        }
    }
}

/// Starts the first of `handover`'s candidates that can be, as the module
/// docs say, with `record` the file it is kept in.
fn start(record: &Path, mut handover: Handover, world: &mut World<'_>) -> Outcome {
    let own = world.platform.own_path();
    let pid = world.pids.own();
    while let Some(candidate) = handover.next().cloned() {
        if !world.files.exists(&candidate) {
            world.platform.say(&format!(
                "leanmacs: {} is missing, so it is skipped",
                candidate.display()
            ));
            handover.mark_failed(&candidate);
            persist(record, &handover, world);
            continue;
        }
        let watching = world
            .spawn
            .spawn_detached(&watcher(&own, pid, &candidate, record));
        if let Err(why) = &watching {
            world.platform.say(&format!(
                "leanmacs: the watcher could not be started ({why}), so {} has no fallback",
                candidate.display()
            ));
        }
        let invocation = restoring(&candidate, record, &handover, world);
        match world.exec.exec(&invocation) {
            Refusal::Faked => return Outcome::Execed,
            refusal => {
                world.platform.say(&format!(
                    "leanmacs: could not start {}: {refusal}",
                    candidate.display()
                ));
                if let Ok(watcher) = watching {
                    world.pids.kill(watcher);
                }
                handover.mark_failed(&candidate);
                persist(record, &handover, world);
            }
        }
    }
    exhausted(record, &handover, world)
}

fn exhausted(record: &Path, handover: &Handover, world: &mut World<'_>) -> Outcome {
    let failed = failed_record(record);
    if let Err(why) = world.files.rename(record, &failed) {
        world.platform.say(&format!(
            "leanmacs: could not rename {} to {}: {why}",
            record.display(),
            failed.display()
        ));
    }
    let tried: Vec<String> = handover
        .candidates
        .iter()
        .map(|c| c.display().to_string())
        .collect();
    let tried = tried.join(", ");
    world.platform.say(&if handover.session.is_some() {
        format!(
            "leanmacs: no executable could restore the session (tried {tried}); it is kept, and the next start restores it"
        )
    } else {
        format!("leanmacs: no executable could start the editor (tried {tried})")
    });
    Outcome::Exit(1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake::{FakeWorld, Happened};
    use crate::ports::Files;

    const LAUNCHER: &str = "/Apps/Leanmacs.app/Contents/MacOS/leanmacs";
    const SHIPPED: &str = "/Apps/Leanmacs.app/Contents/MacOS/editor";
    const RECORD: &str = "/s/session/handover";

    fn args(words: &[&str]) -> Vec<OsString> {
        words.iter().map(OsString::from).collect()
    }

    fn strings(invocation: &Invocation) -> Vec<String> {
        invocation
            .args
            .iter()
            .map(|a| a.to_string_lossy().into_owned())
            .collect()
    }

    fn record(candidates: &[&str], failed: &[&str]) -> Handover {
        Handover {
            session: Some("/s/session/session-4.json".into()),
            shipped: SHIPPED.into(),
            candidates: candidates.iter().map(PathBuf::from).collect(),
            arguments: vec!["--state".into(), "/s".into()],
            failed: failed.iter().map(PathBuf::from).collect(),
        }
    }

    fn handing_over(candidates: &[&str], failed: &[&str], present: &[&str]) -> FakeWorld {
        let mut fake = FakeWorld::new(LAUNCHER, true);
        let encoded = handover::encode(&record(candidates, failed));
        fake.files = fake.files.clone().with(RECORD, encoded);
        for path in present {
            fake.files = fake.files.clone().with(*path, "exe");
        }
        fake
    }

    /// The data directory `HOME=/h` gives.
    const DATA: &str = "/h/.local/share/leanmacs";
    /// The cold record of the fake launcher, pid 100, in [`DATA`].
    const COLD: &str = "/h/.local/share/leanmacs/launch/cold-100";

    /// The editor of version `n` of the core `c` in `data`.
    fn version(data: &str, n: &str) -> String {
        format!("{data}/editors/c/{n}/editor")
    }

    /// A launcher in its bundle, on Linux, with `HOME=/h`, a shipped
    /// default whose core is `c`, and `paths` present.
    fn cold_world(paths: &[String]) -> FakeWorld {
        let mut fake = FakeWorld::new(LAUNCHER, false);
        fake.platform.set_var("HOME", "/h");
        fake.files = fake.files.clone().with(format!("{SHIPPED}.core"), "c\n");
        for path in paths {
            fake.files = fake.files.clone().with(path.as_str(), "exe");
        }
        fake
    }

    /// The cold start of today: the default, exec'd with no record and no
    /// watcher.
    fn assert_started_the_default_as_before(fake: &FakeWorld) {
        assert_eq!(fake.exec.execs.len(), 1);
        let exec = &fake.exec.execs[0];
        assert_eq!(exec.program, PathBuf::from(SHIPPED));
        assert_eq!(
            strings(exec),
            ["--launched-by", LAUNCHER, "--shipped", SHIPPED, "headless"]
        );
        assert!(fake.spawn.spawned.is_empty());
        assert!(
            !fake
                .journal
                .entries()
                .iter()
                .any(|h| matches!(h, Happened::Wrote(_) | Happened::MadeDir(_)))
        );
    }

    #[test]
    fn a_cold_start_writes_a_record_of_the_newest_the_previous_and_the_shipped_first() {
        let mut fake = cold_world(&[version(DATA, "1"), version(DATA, "2"), version(DATA, "10")]);
        let outcome = run(&args(&["headless", "two words"]), &mut fake.world());
        assert_eq!(outcome, Outcome::Execed);
        let written = handover::decode(&fake.files.read(Path::new(COLD)).unwrap()).unwrap();
        assert_eq!(
            written,
            Handover {
                session: None,
                shipped: SHIPPED.into(),
                candidates: vec![
                    version(DATA, "10").into(),
                    version(DATA, "2").into(),
                    SHIPPED.into()
                ],
                arguments: vec!["headless".into(), "two words".into()],
                failed: Vec::new(),
            }
        );
        assert_eq!(
            fake.journal.entries(),
            [
                Happened::MadeDir(format!("{DATA}/launch").into()),
                Happened::Wrote(COLD.into()),
                Happened::Spawned(LAUNCHER.into()),
                Happened::Execed(version(DATA, "10").into()),
            ]
        );
    }

    #[test]
    fn a_cold_start_execs_the_newest_handed_over_with_no_restore_and_watches_it() {
        let mut fake = cold_world(&[version(DATA, "1"), version(DATA, "10")]);
        run(&args(&["headless"]), &mut fake.world());
        let exec = &fake.exec.execs[0];
        assert_eq!(exec.program, PathBuf::from(version(DATA, "10")));
        assert_eq!(
            strings(exec),
            [
                "--launched-by",
                LAUNCHER,
                "--shipped",
                SHIPPED,
                "--handed-over",
                COLD,
                "headless"
            ]
        );
        assert_eq!(
            strings(&fake.spawn.spawned[0]),
            [
                "--watch",
                "100",
                "--candidate",
                &version(DATA, "10"),
                "--handover",
                COLD,
                "--patience",
                "60000"
            ]
        );
    }

    #[test]
    fn incomplete_staging_and_other_cores_editors_are_skipped() {
        let mut fake = cold_world(&[
            version(DATA, "3"),
            format!("{DATA}/editors/c/7/editor.build"),
            format!("{DATA}/editors/c/staging-9/editor"),
            format!("{DATA}/editors/staging-9/editor"),
            format!("{DATA}/editors/other/99/editor"),
        ]);
        run(&args(&["headless"]), &mut fake.world());
        let written = handover::decode(&fake.files.read(Path::new(COLD)).unwrap()).unwrap();
        assert_eq!(
            written.candidates,
            [PathBuf::from(version(DATA, "3")), PathBuf::from(SHIPPED)]
        );
        assert_eq!(
            fake.exec.execs[0].program,
            PathBuf::from(version(DATA, "3"))
        );
    }

    #[test]
    fn with_no_complete_version_the_shipped_default_starts_as_before() {
        let mut fake = cold_world(&[
            format!("{DATA}/editors/c/7/editor.build"),
            format!("{DATA}/editors/c/staging-9/editor"),
            format!("{DATA}/editors/other/99/editor"),
        ]);
        run(&args(&["headless"]), &mut fake.world());
        assert_started_the_default_as_before(&fake);
    }

    #[test]
    fn with_no_core_record_or_an_empty_one_the_shipped_default_starts_as_before() {
        let mut fake = cold_world(&[version(DATA, "1")]);
        fake.files
            .files
            .remove(Path::new(&format!("{SHIPPED}.core")));
        run(&args(&["headless"]), &mut fake.world());
        assert_started_the_default_as_before(&fake);
        let mut fake = cold_world(&[version(DATA, "1")]);
        fake.files = fake.files.clone().with(format!("{SHIPPED}.core"), "\n");
        run(&args(&["headless"]), &mut fake.world());
        assert_started_the_default_as_before(&fake);
    }

    #[test]
    fn data_beats_the_environment_and_is_not_handed_to_the_editor() {
        let mut fake = cold_world(&[version(DATA, "1"), version("/given", "5")]);
        fake.platform.set_var("XDG_DATA_HOME", "/x");
        run(&args(&["--data", "/given", "headless"]), &mut fake.world());
        let exec = &fake.exec.execs[0];
        assert_eq!(exec.program, PathBuf::from(version("/given", "5")));
        assert_eq!(
            strings(exec)[4..],
            ["--handed-over", "/given/launch/cold-100", "headless"]
        );
    }

    #[test]
    fn xdg_data_home_beats_home() {
        let mut fake = cold_world(&[version(DATA, "9"), version("/x/leanmacs", "1")]);
        fake.platform.set_var("XDG_DATA_HOME", "/x");
        run(&args(&["headless"]), &mut fake.world());
        assert_eq!(
            fake.exec.execs[0].program,
            PathBuf::from(version("/x/leanmacs", "1"))
        );
    }

    #[test]
    fn with_neither_data_nor_a_variable_there_is_no_per_user_choice() {
        let mut fake = cold_world(&[version(DATA, "1"), version("/leanmacs", "1")]);
        fake.platform.vars.clear();
        run(&args(&["headless"]), &mut fake.world());
        assert_started_the_default_as_before(&fake);
    }

    #[test]
    fn a_cold_record_that_cannot_be_written_is_said_and_the_default_starts() {
        let mut fake = cold_world(&[version(DATA, "1")]);
        fake.files = fake.files.clone().with(format!("{DATA}/launch"), "a file");
        let outcome = run(&args(&["headless"]), &mut fake.world());
        assert_eq!(outcome, Outcome::Execed);
        assert_eq!(fake.exec.execs.len(), 1);
        assert_eq!(fake.exec.execs[0].program, PathBuf::from(SHIPPED));
        assert_eq!(
            strings(&fake.exec.execs[0]),
            ["--launched-by", LAUNCHER, "--shipped", SHIPPED, "headless"]
        );
        assert!(fake.spawn.spawned.is_empty());
        assert!(fake.platform.said[0].starts_with(&format!(
            "leanmacs: could not write the launch record {COLD}: "
        )));
    }

    #[cfg(unix)]
    #[test]
    fn an_argument_that_is_not_utf8_starts_the_default_as_before() {
        use std::os::unix::ffi::OsStringExt;
        let mut fake = cold_world(&[version(DATA, "1")]);
        let odd = OsString::from_vec(vec![b'x', 0xff]);
        run(std::slice::from_ref(&odd), &mut fake.world());
        assert_eq!(fake.exec.execs[0].program, PathBuf::from(SHIPPED));
        assert_eq!(fake.exec.execs[0].args[4], odd);
        assert!(fake.spawn.spawned.is_empty());
        assert!(fake.platform.said[0].contains("not UTF-8"));
    }

    #[test]
    fn data_needs_a_value_and_the_watcher_does_not_take_it() {
        let mut fake = FakeWorld::new(LAUNCHER, false);
        assert_eq!(run(&args(&["--data"]), &mut fake.world()), Outcome::Exit(2));
        let mut fake = FakeWorld::new(LAUNCHER, false);
        let watching = args(&[
            "--watch",
            "1",
            "--candidate",
            "/e",
            "--handover",
            "/r",
            "--patience",
            "1",
            "--data",
            "/d",
        ]);
        assert_eq!(run(&watching, &mut fake.world()), Outcome::Exit(2));
        assert!(fake.platform.said[0].contains("--watch does not take --data"));
    }

    #[test]
    fn a_cold_record_with_no_candidate_left_is_kept_as_failed_and_says_none_could_start() {
        let mut fake = FakeWorld::new(LAUNCHER, false);
        let cold = Handover {
            session: None,
            arguments: Vec::new(),
            ..record(&[SHIPPED], &[SHIPPED])
        };
        fake.files = fake.files.clone().with(COLD, handover::encode(&cold));
        let outcome = run(&args(&["--handover", COLD]), &mut fake.world());
        assert_eq!(outcome, Outcome::Exit(1));
        assert!(fake.files.exists(Path::new(&format!("{COLD}.failed"))));
        let said = fake.platform.said.last().unwrap();
        assert!(
            said.contains("no executable could start the editor"),
            "{said}"
        );
        assert!(!said.contains("session"), "{said}");
    }

    #[test]
    fn a_cold_start_in_a_bundle_execs_the_bundles_editor_with_the_launch_flags() {
        let mut fake = FakeWorld::new(LAUNCHER, true);
        let outcome = run(&args(&["headless", "-x"]), &mut fake.world());
        assert_eq!(outcome, Outcome::Execed);
        let exec = &fake.exec.execs[0];
        assert_eq!(exec.program, PathBuf::from(SHIPPED));
        assert_eq!(
            strings(exec),
            [
                "--launched-by",
                LAUNCHER,
                "--shipped",
                SHIPPED,
                "headless",
                "-x"
            ]
        );
        assert!(fake.spawn.spawned.is_empty());
    }

    #[test]
    fn an_explicit_default_wins_over_the_bundle_layout() {
        let mut fake = FakeWorld::new(LAUNCHER, true);
        let outcome = run(
            &args(&["--default", "/elsewhere/editor", "--", "--probe"]),
            &mut fake.world(),
        );
        assert_eq!(outcome, Outcome::Execed);
        let exec = &fake.exec.execs[0];
        assert_eq!(exec.program, PathBuf::from("/elsewhere/editor"));
        assert_eq!(
            strings(exec),
            [
                "--launched-by",
                LAUNCHER,
                "--shipped",
                "/elsewhere/editor",
                "--probe"
            ]
        );
        assert_eq!(exec.set, [(CF_PROCESS_PATH.into(), LAUNCHER.into())]);
    }

    #[test]
    fn outside_a_bundle_a_cold_start_needs_a_default() {
        let mut fake = FakeWorld::new("/build/leanmacs", false);
        assert_eq!(
            run(&args(&["headless"]), &mut fake.world()),
            Outcome::Exit(2)
        );
        assert!(fake.exec.execs.is_empty());
        assert!(fake.platform.said[0].contains("no editor to start"));
        let mut fake = FakeWorld::new("/build/leanmacs", false);
        let outcome = run(
            &args(&["--default", "/build/editor", "headless"]),
            &mut fake.world(),
        );
        assert_eq!(outcome, Outcome::Execed);
        assert_eq!(fake.exec.execs[0].program, PathBuf::from("/build/editor"));
    }

    #[test]
    fn cf_process_path_is_set_on_macos_and_not_elsewhere() {
        let mut mac = FakeWorld::new(LAUNCHER, true);
        run(&[], &mut mac.world());
        assert_eq!(
            mac.exec.execs[0].set,
            [(CF_PROCESS_PATH.into(), LAUNCHER.into())]
        );
        let mut linux = FakeWorld::new(LAUNCHER, false);
        run(&[], &mut linux.world());
        assert!(linux.exec.execs[0].set.is_empty());
    }

    #[test]
    fn a_word_that_is_no_option_and_everything_after_it_are_the_editors() {
        let mut fake = FakeWorld::new(LAUNCHER, false);
        run(&args(&["--probe", "--default", "x"]), &mut fake.world());
        assert_eq!(
            strings(&fake.exec.execs[0])[4..],
            ["--probe", "--default", "x"]
        );
    }

    #[test]
    fn an_option_with_no_value_is_refused_with_the_usage() {
        let mut fake = FakeWorld::new(LAUNCHER, false);
        assert_eq!(
            run(&args(&["--handover"]), &mut fake.world()),
            Outcome::Exit(2)
        );
        assert!(fake.platform.said.iter().any(|l| l.starts_with("usage:")));
    }

    #[test]
    fn a_hand_over_spawns_the_watcher_then_execs_the_first_candidate() {
        let mut fake = handing_over(&["/new/editor", SHIPPED], &[], &["/new/editor", SHIPPED]);
        let outcome = run(&args(&["--handover", RECORD]), &mut fake.world());
        assert_eq!(outcome, Outcome::Execed);
        assert_eq!(fake.spawn.spawned.len(), 1);
        let watcher = &fake.spawn.spawned[0];
        assert_eq!(watcher.program, PathBuf::from(LAUNCHER));
        assert_eq!(
            strings(watcher),
            [
                "--watch",
                "100",
                "--candidate",
                "/new/editor",
                "--handover",
                RECORD,
                "--patience",
                "60000"
            ]
        );
        let exec = &fake.exec.execs[0];
        assert_eq!(exec.program, PathBuf::from("/new/editor"));
        assert_eq!(
            strings(exec),
            [
                "--launched-by",
                LAUNCHER,
                "--shipped",
                SHIPPED,
                "--restore",
                "/s/session/session-4.json",
                "--handed-over",
                RECORD,
                "--state",
                "/s"
            ]
        );
        assert_eq!(exec.set, [(CF_PROCESS_PATH.into(), LAUNCHER.into())]);
    }

    #[test]
    fn a_record_with_no_session_after_its_newest_failed_execs_the_previous_with_no_restore() {
        let mut fake = FakeWorld::new(LAUNCHER, false);
        let cold = Handover {
            session: None,
            failed: vec!["/d/editors/c/10/editor".into()],
            arguments: vec!["headless".into()],
            ..record(
                &["/d/editors/c/10/editor", "/d/editors/c/2/editor", SHIPPED],
                &[],
            )
        };
        fake.files = fake
            .files
            .clone()
            .with(RECORD, handover::encode(&cold))
            .with("/d/editors/c/10/editor", "exe")
            .with("/d/editors/c/2/editor", "exe");
        let outcome = run(&args(&["--handover", RECORD]), &mut fake.world());
        assert_eq!(outcome, Outcome::Execed);
        let exec = &fake.exec.execs[0];
        assert_eq!(exec.program, PathBuf::from("/d/editors/c/2/editor"));
        assert_eq!(
            strings(exec),
            [
                "--launched-by",
                LAUNCHER,
                "--shipped",
                SHIPPED,
                "--handed-over",
                RECORD,
                "--failed",
                "/d/editors/c/10/editor",
                "headless"
            ]
        );
        assert_eq!(strings(&fake.spawn.spawned[0])[3], "/d/editors/c/2/editor");
    }

    #[test]
    fn a_failed_candidate_is_skipped_and_named_with_failed() {
        let mut fake = handing_over(
            &["/new/editor", SHIPPED],
            &["/new/editor"],
            &["/new/editor", SHIPPED],
        );
        run(&args(&["--handover", RECORD]), &mut fake.world());
        let exec = &fake.exec.execs[0];
        assert_eq!(exec.program, PathBuf::from(SHIPPED));
        assert_eq!(
            strings(exec)[8..],
            ["--failed", "/new/editor", "--state", "/s"]
        );
        assert_eq!(strings(&fake.spawn.spawned[0])[3], SHIPPED);
    }

    #[test]
    fn a_missing_candidate_is_marked_failed_in_the_record_and_skipped() {
        let mut fake = handing_over(&["/gone/editor", SHIPPED], &[], &[SHIPPED]);
        run(&args(&["--handover", RECORD]), &mut fake.world());
        assert_eq!(fake.exec.execs.len(), 1);
        assert_eq!(fake.exec.execs[0].program, PathBuf::from(SHIPPED));
        let written = handover::decode(&fake.files.read(Path::new(RECORD)).unwrap()).unwrap();
        assert_eq!(written.failed, [PathBuf::from("/gone/editor")]);
        assert!(fake.platform.said[0].contains("/gone/editor is missing"));
        assert_eq!(fake.spawn.spawned.len(), 1);
    }

    #[test]
    fn a_refused_exec_kills_its_watcher_and_moves_to_the_next_in_this_process() {
        let mut fake = handing_over(&["/new/editor", SHIPPED], &[], &["/new/editor", SHIPPED]);
        fake.exec = fake
            .exec
            .clone()
            .refusing("/new/editor", Refusal::Refused("bad CPU type".into()));
        let outcome = run(&args(&["--handover", RECORD]), &mut fake.world());
        assert_eq!(outcome, Outcome::Execed);
        assert_eq!(fake.exec.execs.len(), 2);
        assert_eq!(fake.exec.execs[1].program, PathBuf::from(SHIPPED));
        assert_eq!(fake.pids.kills, [Pid(1001)]);
        assert_eq!(fake.spawn.spawned.len(), 2);
        assert!(strings(&fake.exec.execs[1]).contains(&"--failed".to_owned()));
        assert!(fake.platform.said[0].contains("could not start /new/editor: bad CPU type"));
    }

    #[test]
    fn with_no_candidate_left_the_record_is_renamed_and_the_launcher_exits_1() {
        let mut fake = handing_over(
            &["/new/editor", SHIPPED],
            &["/new/editor"],
            &["/new/editor"],
        );
        let outcome = run(&args(&["--handover", RECORD]), &mut fake.world());
        assert_eq!(outcome, Outcome::Exit(1));
        assert!(fake.exec.execs.is_empty());
        assert!(!fake.files.exists(Path::new(RECORD)));
        let failed = handover::decode(
            &fake
                .files
                .read(Path::new("/s/session/handover.failed"))
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            failed.failed,
            [PathBuf::from("/new/editor"), PathBuf::from(SHIPPED)]
        );
        assert!(
            fake.platform
                .said
                .last()
                .unwrap()
                .contains("next start restores it")
        );
    }

    #[test]
    fn a_newer_record_is_left_byte_for_byte_and_the_default_starts_with_no_hand_over() {
        let newer = b"leanmacs-handover 9\nsomething new\n".to_vec();
        let mut fake = FakeWorld::new(LAUNCHER, false);
        fake.files = fake.files.clone().with(RECORD, newer.clone());
        let outcome = run(&args(&["--handover", RECORD]), &mut fake.world());
        assert_eq!(outcome, Outcome::Execed);
        assert_eq!(fake.files.read(Path::new(RECORD)), Ok(newer));
        assert_eq!(
            strings(&fake.exec.execs[0]),
            ["--launched-by", LAUNCHER, "--shipped", SHIPPED]
        );
        assert!(fake.spawn.spawned.is_empty());
        assert!(fake.platform.said[0].contains("format 9"));
    }

    #[test]
    fn the_record_and_the_failed_sibling_and_the_layout_rule() {
        assert_eq!(
            failed_record(Path::new("/s/session/handover")),
            PathBuf::from("/s/session/handover.failed")
        );
        assert_eq!(
            default_editor(Path::new("/A.app/Contents/MacOS/x"), None),
            Some(PathBuf::from("/A.app/Contents/MacOS/editor"))
        );
        assert_eq!(default_editor(Path::new("/A.app/Contents/x"), None), None);
        assert_eq!(default_editor(Path::new("x"), None), None);
    }
}
