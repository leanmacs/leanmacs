//! The launcher and its watcher on real processes: a hand-over whose first
//! candidate ends before it restores the session falls back to the next,
//! which is `launch-probe` and takes the session (it removes the record, as
//! an editor does at the hand-shake).
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
        session: dir.join("session-1.json"),
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
            path(&handover.session),
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
        session: dir.join("session-1.json"),
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
