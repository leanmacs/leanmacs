//! The contracts of the [`Process`] and [`Files`] ports: what the core
//! assumes of every adapter of each, as a check that runs one.
//!
//! [`check_process`] runs each property's invocation and returns the names
//! of those whose result is not the one the core assumes. Every program is
//! one every Unix has (`true`, `false`, `printf`) or an absolute path that
//! does not exist, and none writes a file.
//!
//! [`answers`] is what the system does with each of those invocations, so
//! the same check runs on a [`RecordingProcess`](crate::fake::RecordingProcess)
//! over it (this module's test) and on the real adapter
//! (`editor-release-std`'s `tests/contract.rs`): the fake's answers cannot
//! drift from the system's.
//!
//! [`check_files`] does the same for the files port, in a directory the
//! caller owns: on a [`FakeFiles`](crate::fake::FakeFiles) in this
//! module's test, and on the real adapter in a temporary directory
//! (`editor-release-std`'s `tests/contract.rs`).

use std::path::Path;

use crate::ports::{EntryKind, Files, Invocation, Kind, Process, RunError, text};

/// `true` runs, and its output, not captured, is nothing to the core.
pub const RUNS: &str = "a program that succeeds runs, and gives nothing back when not captured";
/// `false` is [`RunError::Failed`] with its status, 1.
pub const FAILS: &str = "a program that fails is Failed with its exit code";
/// Captured output comes back whole.
pub const CAPTURED: &str = "a captured program's standard output comes back whole";
/// Captured output that is not UTF-8 comes back as bytes, which
/// [`text`] refuses.
pub const NOT_UTF8: &str =
    "captured bytes that are not UTF-8 come back as they are, and text refuses them";
/// A program that does not exist is [`RunError::Start`].
pub const MISSING: &str = "a program that does not exist is a Start error";

/// The program of [`MISSING`]: an absolute path nothing is at.
pub const NO_SUCH_PROGRAM: &str = "/nonexistent/leanmacs-release-contract";

/// What [`CAPTURED`]'s program prints.
pub const PRINTED: &str = "leanmacs 1\nzwei\n";

fn printf(format: &str) -> Invocation {
    Invocation::new("printf").arg(format).captured()
}

/// What the system does with each of the check's invocations; for anything
/// else, a start error.
///
/// # Errors
///
/// As the system's.
pub fn answers(invocation: &Invocation) -> Result<Vec<u8>, RunError> {
    let program = invocation.program.to_string_lossy();
    let format = invocation.args.first().map(|a| a.to_string_lossy());
    match (program.as_ref(), format.as_deref()) {
        ("true", None) => Ok(Vec::new()),
        ("false", None) => Err(RunError::Failed(Some(1))),
        ("printf", Some(PRINTED)) if invocation.captured => Ok(PRINTED.as_bytes().to_vec()),
        ("printf", Some("\\377")) if invocation.captured => Ok(vec![0xff]),
        _ => Err(RunError::Start(format!("no such program: {program}"))),
    }
}

/// Runs every property against `process` and returns the names of those
/// that fail.
pub fn check_process(process: &mut impl Process) -> Vec<&'static str> {
    let mut failed = Vec::new();
    if process.run(&Invocation::new("true")) != Ok(Vec::new()) {
        failed.push(RUNS);
    }
    if process.run(&Invocation::new("false")) != Err(RunError::Failed(Some(1))) {
        failed.push(FAILS);
    }
    if text(process, &printf(PRINTED)).as_deref() != Ok(PRINTED) {
        failed.push(CAPTURED);
    }
    let raw = printf("\\377");
    if process.run(&raw) != Ok(vec![0xff]) || text(process, &raw) != Err(RunError::NotUtf8) {
        failed.push(NOT_UTF8);
    }
    if !matches!(
        process.run(&Invocation::new(NO_SUCH_PROGRAM)),
        Err(RunError::Start(_))
    ) {
        failed.push(MISSING);
    }
    failed
}

/// A written file reads back, with the executable bits it was written with.
pub const WRITTEN: &str = "a written file reads back, with its executable bit";
/// Nothing at a path is [`Kind::Nothing`].
pub const NOTHING: &str = "nothing at a path is reported as nothing";
/// Making a directory makes its parents, and making it again is fine.
pub const MAKE_DIR: &str = "making a directory makes its parents, and making it again is fine";
/// Entries come sorted by the bytes of their names, each with its kind,
/// and a link is not followed.
pub const ENTRIES: &str =
    "entries come sorted by bytes, with their kinds, and a link is not followed";
/// A copy keeps the bytes and the executable bit, and a copy of a link is
/// a regular file holding its target's bytes.
pub const COPY: &str =
    "a copy keeps bytes and the executable bit, and copying a link gives a regular file";
/// A made link reads back its target text, and following it reaches the
/// file.
pub const LINK: &str = "a made link reads back its target text, and following it reaches the file";
/// A copy onto a file that is there replaces it.
pub const REPLACE: &str = "a copy onto an existing file replaces it";

/// What [`WRITTEN`]'s file holds.
const WRITTEN_BYTES: &[u8] = b"leanmacs\n";

/// Runs every property against `files` in the directory `root`, which is
/// there and empty, and returns the names of those that fail.
pub fn check_files(files: &mut impl Files, root: &Path) -> Vec<&'static str> {
    let mut failed = Vec::new();
    let written = root.join("written");
    let tool = root.join("tool");
    let wrote = files.write(&written, WRITTEN_BYTES, false).is_ok()
        && files.write(&tool, b"#!/bin/sh\n", true).is_ok();
    if !wrote
        || files.read(&written).as_deref() != Ok(WRITTEN_BYTES)
        || files.kind(&written) != Ok(Kind::File { executable: false })
        || files.kind(&tool) != Ok(Kind::File { executable: true })
    {
        failed.push(WRITTEN);
    }
    if files.kind(&root.join("absent")) != Ok(Kind::Nothing) {
        failed.push(NOTHING);
    }
    let deep = root.join("a").join("b").join("c");
    if files.make_dir(&deep).is_err()
        || files.make_dir(&deep).is_err()
        || files.kind(&deep) != Ok(Kind::Directory)
        || files.kind(&root.join("a")) != Ok(Kind::Directory)
    {
        failed.push(MAKE_DIR);
    }
    if !entries_hold(files, root) {
        failed.push(ENTRIES);
    }
    if !copies_hold(files, root) {
        failed.push(COPY);
    }
    let made = root.join("made-link");
    if files.symlink(Path::new("written"), &made).is_err()
        || files.read_link(&made).as_deref() != Ok(Path::new("written"))
        || files.kind(&made) != Ok(Kind::File { executable: false })
        || files.read(&made).as_deref() != Ok(WRITTEN_BYTES)
    {
        failed.push(LINK);
    }
    let old = root.join("old");
    if files.write(&old, b"old\n", false).is_err()
        || files.copy(&written, &old).is_err()
        || files.read(&old).as_deref() != Ok(WRITTEN_BYTES)
    {
        failed.push(REPLACE);
    }
    failed
}

/// [`ENTRIES`] in `root/listed`: names whose byte order is not a locale's
/// (`B-upper` before `a-dir`), and a link listed as a link.
fn entries_hold(files: &mut impl Files, root: &Path) -> bool {
    let listed = root.join("listed");
    let made = files.make_dir(&listed.join("a-dir")).is_ok()
        && files.write(&listed.join("b-file"), b"b\n", false).is_ok()
        && files.write(&listed.join("B-upper"), b"B\n", true).is_ok()
        && files
            .symlink(Path::new("b-file"), &listed.join("c-link"))
            .is_ok();
    let Ok(entries) = files.entries(&listed) else {
        return false;
    };
    let seen: Vec<(String, EntryKind)> = entries
        .into_iter()
        .map(|e| (e.name.to_string_lossy().into_owned(), e.kind))
        .collect();
    made && seen
        == [
            ("B-upper".to_owned(), EntryKind::File { executable: true }),
            ("a-dir".to_owned(), EntryKind::Directory),
            ("b-file".to_owned(), EntryKind::File { executable: false }),
            ("c-link".to_owned(), EntryKind::Link),
        ]
}

/// [`COPY`]: the executable `root/tool` and the link `root/listed/c-link`
/// copied, once [`entries_hold`] has made it.
fn copies_hold(files: &mut impl Files, root: &Path) -> bool {
    let tool_copy = root.join("tool-copy");
    let link_copy = root.join("link-copy");
    files.copy(&root.join("tool"), &tool_copy).is_ok()
        && files.read(&tool_copy).as_deref() == Ok(b"#!/bin/sh\n".as_slice())
        && files.kind(&tool_copy) == Ok(Kind::File { executable: true })
        && files
            .copy(&root.join("listed").join("c-link"), &link_copy)
            .is_ok()
        && files.read(&link_copy).as_deref() == Ok(b"b\n".as_slice())
        && files.read_link(&link_copy).is_err()
        && files.kind(&link_copy) == Ok(Kind::File { executable: false })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake::{FakeFiles, RecordingProcess};

    #[test]
    fn the_fake_files_keep_the_contract() {
        let mut files = FakeFiles::new().with_dir("/contract");
        assert_eq!(
            check_files(&mut files, Path::new("/contract")),
            Vec::<&str>::new()
        );
    }

    #[test]
    fn the_fake_over_the_answers_keeps_the_contract() {
        let mut process = RecordingProcess::new(answers);
        assert_eq!(check_process(&mut process), Vec::<&str>::new());
    }

    #[test]
    fn a_process_that_answers_wrongly_fails_each_property() {
        let mut process = RecordingProcess::new(|_: &Invocation| Ok(b"x".to_vec()));
        assert_eq!(
            check_process(&mut process),
            vec![RUNS, FAILS, CAPTURED, NOT_UTF8, MISSING]
        );
    }
}
