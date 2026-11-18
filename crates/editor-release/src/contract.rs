//! The contract of the [`Process`] port: what the core assumes of every
//! process adapter, as a check that runs one.
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

use crate::ports::{Invocation, Process, RunError, text};

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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake::RecordingProcess;

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
