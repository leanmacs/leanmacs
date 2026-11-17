//! The core's resolvers run through the real adapter on a real git
//! repository, so the build ID and the commit are checked against git
//! itself and not only against the fake's canned output.
//!
//! The repository is made in a temporary directory this test owns, with
//! one empty commit whose committer time is 2001-02-03 04:05:06 UTC, given
//! in another zone, and whose author time is another day: the build ID must
//! be the committer time in UTC. The environment is the empty fake, as
//! with `LEANMACS_BUILD_ID` and `LEANMACS_COMMIT` unset, so git is asked.
//! The commit is compared with `git rev-parse HEAD`, run here directly.
//! git's identity, dates and config for the setup are given to each child
//! alone; the test's own environment, the working directory and the
//! project's repository are not touched.

use std::path::Path;
use std::process::Command;

use editor_release::fake::FakeEnv;
use editor_release::{build_id, commit};
use editor_release_std::StdProcess;
use tempfile::TempDir;

/// Runs git in `repo` with a config and identity of the test's own, and
/// returns its standard output.
fn git(repo: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_AUTHOR_NAME", "Ada")
        .env("GIT_AUTHOR_EMAIL", "ada@example.invalid")
        .env("GIT_AUTHOR_DATE", "@1700000000 +0000")
        .env("GIT_COMMITTER_NAME", "Ada")
        .env("GIT_COMMITTER_EMAIL", "ada@example.invalid")
        // 2001-02-03 04:05:06 UTC, written in a zone two hours east.
        .env("GIT_COMMITTER_DATE", "2001-02-03T06:05:06+02:00")
        .output()
        .expect("git runs");
    assert!(output.status.success(), "git {args:?}: {output:?}");
    String::from_utf8(output.stdout).expect("UTF-8")
}

#[test]
fn resolve_reads_head_s_committer_time_in_utc_and_its_sha_from_git() {
    let dir = TempDir::new().expect("a temporary directory");
    let repo = dir.path();
    git(repo, &["init", "-q"]);
    git(
        repo,
        &[
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-q",
            "--allow-empty",
            "--no-verify",
            "-m",
            "one",
        ],
    );

    let id = build_id::resolve(&FakeEnv::default(), &mut StdProcess, repo).expect("a build ID");
    assert_eq!(id.as_str(), "20010203040506");

    let sha = commit::resolve(&FakeEnv::default(), &mut StdProcess, repo).expect("a commit");
    assert_eq!(sha.as_str(), git(repo, &["rev-parse", "HEAD"]).trim());
}

#[test]
fn resolve_outside_a_repository_says_to_set_the_variable() {
    let dir = TempDir::new().expect("a temporary directory");
    let missing = dir.path().join("not-a-repository");
    let error = build_id::resolve(&FakeEnv::default(), &mut StdProcess, &missing)
        .expect_err("no repository");
    assert!(
        error
            .to_string()
            .starts_with("set LEANMACS_BUILD_ID or run inside a git checkout"),
        "{error}"
    );
    let error =
        commit::resolve(&FakeEnv::default(), &mut StdProcess, &missing).expect_err("no repository");
    assert!(
        error
            .to_string()
            .starts_with("set LEANMACS_COMMIT or run inside a git checkout"),
        "{error}"
    );
}
