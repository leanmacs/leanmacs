//! The launcher and its watcher on real processes: a hand-over whose first
//! candidate ends before it restores the session falls back to the next,
//! which is `launch-probe` and takes the session (it removes the record, as
//! an editor does at the hand-shake). And a cold start with per-user
//! editors in a data directory (`--data`) starts the newest, and falls back
//! to the previous, then to the shipped default, each a shell script that
//! takes the start by removing its `--handed-over` record or fails by
//! exiting 3.
//!
//! The launcher's standard output is a pipe the test reads to its end, and
//! every process the run starts holds it: the launcher, the candidates it
//! is exec'd into, and each watcher. So reading to the end shows that no
//! watcher is left running.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use editor_launch::handover::{Handover, encode};

fn script(path: &Path, body: &str) {
    fs::write(path, format!("#!/bin/sh\n{body}\n")).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

fn hand_over_with_a_bad_first(bad_body: &str) {
    let dir = tempfile::tempdir().unwrap();
    let dir = dir.path();
    let bad = dir.join("bad");
    script(&bad, bad_body);
    let probe = dir.join("probe");
    fs::copy(env!("CARGO_BIN_EXE_launch-probe"), &probe).unwrap();
    let record = dir.join("handover");
    let handover = Handover {
        session: Some(dir.join("session-1.json")),
        shipped: probe.clone(),
        candidates: vec![bad.clone(), probe.clone()],
        arguments: vec!["headless".into(), "two words".into()],
        failed: Vec::new(),
    };
    fs::write(&record, encode(&handover)).unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_leanmacs"))
        .arg("--handover")
        .arg(&record)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let path = |p: &PathBuf| p.to_string_lossy().into_owned();
    assert!(stdout.starts_with("probe pid "), "{stdout}\n{stderr}");
    let arguments: Vec<&str> = stdout
        .lines()
        .filter_map(|l| l.strip_prefix("argument "))
        .collect();
    assert_eq!(
        arguments[2..],
        [
            "--shipped".to_owned(),
            path(&probe),
            "--restore".to_owned(),
            path(handover.session.as_ref().unwrap()),
            "--handed-over".to_owned(),
            path(&record),
            "--failed".to_owned(),
            path(&bad),
            "headless".to_owned(),
            "two words".to_owned(),
        ]
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
    );
    assert!(
        stderr.contains(&format!(
            "leanmacs: {} ended before it restored the session; starting {}",
            bad.display(),
            probe.display()
        )),
        "{stderr}"
    );
    assert!(!record.exists(), "the record is gone at the hand-shake");
    assert!(!dir.join("handover.failed").exists());
}

#[test]
fn a_candidate_that_exits_before_the_hand_shake_falls_back_to_the_next() {
    hand_over_with_a_bad_first("exit 3");
}

#[test]
fn a_candidate_killed_before_the_hand_shake_falls_back_to_the_next() {
    hand_over_with_a_bad_first("kill -KILL $$");
}

#[test]
fn a_hand_over_with_no_candidate_left_keeps_the_record_as_failed_and_exits_1() {
    let dir = tempfile::tempdir().unwrap();
    let dir = dir.path();
    let bad = dir.join("bad");
    script(&bad, "exit 3");
    let record = dir.join("handover");
    let handover = Handover {
        session: Some(dir.join("session-1.json")),
        shipped: dir.join("missing"),
        candidates: vec![bad.clone(), dir.join("missing")],
        arguments: Vec::new(),
        failed: Vec::new(),
    };
    fs::write(&record, encode(&handover)).unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_leanmacs"))
        .arg("--handover")
        .arg(&record)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&output.stderr);
    // The launcher's own status is the bad candidate's: the watcher's
    // launcher, which found none left, is nobody's child.
    assert_eq!(output.status.code(), Some(3), "{stderr}");
    assert!(
        stderr.contains("no executable could restore the session"),
        "{stderr}"
    );
    assert!(!record.exists());
    let failed = fs::read_to_string(dir.join("handover.failed")).unwrap();
    assert!(
        failed.contains(&format!("failed {}", bad.display())),
        "{failed}"
    );
}

/// An editor script that finds `--handed-over <record>` among its
/// arguments, then runs `body`.
fn editor(path: &Path, body: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    script(
        path,
        &format!(
            "record=\nwhile [ $# -gt 0 ]; do\n  if [ \"$1\" = --handed-over ]; then record=$2; fi\n  shift\ndone\n{body}"
        ),
    );
}

/// The body of an editor that takes the start: it removes the record, as
/// an editor does at the hand-shake, and prints `name`.
fn takes(name: &str) -> String {
    format!("rm -f \"$record\"\necho {name}")
}

/// The body of an editor that ends before the hand-shake.
const FAILS: &str = "exit 3";

/// What a cold start's run left: its standard output, read to its end,
/// its standard error, and the records left in `<data>/launch`.
struct Cold {
    stdout: String,
    stderr: String,
    left: Vec<PathBuf>,
}

/// A cold start of `leanmacs --default <tmp>/shipped/editor --data
/// <tmp>/data headless` with a shipped default whose core is `c`, an
/// oldest version 1 that must never run, and the previous (2), newest
/// (10) and shipped editors running `previous`, `newest` and `shipped`.
fn cold_start(newest: &str, previous: &str, shipped: &str) -> Cold {
    let dir = tempfile::tempdir().unwrap();
    let dir = dir.path();
    let data = dir.join("data");
    let versions = data.join("editors").join("c");
    let default = dir.join("shipped").join("editor");
    editor(&default, shipped);
    fs::write(dir.join("shipped").join("editor.core"), "c\n").unwrap();
    editor(&versions.join("1").join("editor"), &takes("oldest"));
    editor(&versions.join("2").join("editor"), previous);
    editor(&versions.join("10").join("editor"), newest);
    fs::create_dir_all(data.join("editors").join("staging-1")).unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_leanmacs"))
        .arg("--default")
        .arg(&default)
        .arg("--data")
        .arg(&data)
        .arg("headless")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    let left = fs::read_dir(data.join("launch"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect();
    Cold {
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        left,
    }
}

#[test]
fn a_cold_start_runs_the_newest_per_user_editor_which_takes_the_record() {
    let cold = cold_start(&takes("newest"), &takes("previous"), &takes("shipped"));
    assert_eq!(cold.stdout, "newest\n", "{}", cold.stderr);
    assert_eq!(cold.left, Vec::<PathBuf>::new());
}

#[test]
fn a_newest_that_ends_before_the_hand_shake_falls_back_to_the_previous() {
    let cold = cold_start(FAILS, &takes("previous"), &takes("shipped"));
    assert_eq!(cold.stdout, "previous\n", "{}", cold.stderr);
    assert!(
        cold.stderr
            .contains("ended before it restored the session; starting"),
        "{}",
        cold.stderr
    );
    assert_eq!(cold.left, Vec::<PathBuf>::new());
}

#[test]
fn a_newest_and_previous_that_both_fail_fall_back_to_the_shipped_default() {
    let cold = cold_start(FAILS, FAILS, &takes("shipped"));
    assert_eq!(cold.stdout, "shipped\n", "{}", cold.stderr);
    assert_eq!(cold.left, Vec::<PathBuf>::new());
}
