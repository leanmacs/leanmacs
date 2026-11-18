//! The commit a build is made from: HEAD's full SHA.
//!
//! [`resolve`] takes it from [`VAR`] when that is set, as CI sets it from
//! `github.sha`, and otherwise asks `git` for HEAD ([`head`]), with the
//! same precedence and errors as the build ID ([`crate::build_id`]). A
//! build from a tree with uncommitted changes is still named by HEAD.

use std::error::Error;
use std::fmt;
use std::path::Path;

use crate::ports::{Env, Invocation, Process, RunError};

/// The variable that overrides the read of HEAD.
pub const VAR: &str = "LEANMACS_COMMIT";

/// A commit's full SHA-1: always exactly 40 lowercase hex digits.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Commit(String);

/// Why a value is not a commit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommitError {
    /// The text is not 40 lowercase hex digits.
    Malformed(String),
}

impl fmt::Display for CommitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Malformed(text) => {
                write!(f, "`{text}` is not a commit (40 lowercase hex digits)")
            }
        }
    }
}

impl Error for CommitError {}

impl Commit {
    /// Reads a commit: exactly 40 lowercase hex digits.
    ///
    /// # Errors
    ///
    /// [`CommitError::Malformed`] for anything else: a short or long SHA,
    /// an uppercase digit, the empty string.
    pub fn parse(text: &str) -> Result<Self, CommitError> {
        let hex = |b: u8| b.is_ascii_digit() || (b'a'..=b'f').contains(&b);
        if text.len() == 40 && text.bytes().all(hex) {
            Ok(Self(text.to_owned()))
        } else {
            Err(CommitError::Malformed(text.to_owned()))
        }
    }

    /// The 40 digits.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for Commit {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// `git rev-parse` printing HEAD's full SHA in the checkout at `repo`.
#[must_use]
pub fn head(repo: &Path) -> Invocation {
    Invocation::new("git")
        .arg("-C")
        .arg(repo)
        .args(["rev-parse", "--verify", "HEAD"])
        .captured()
}

/// Why the commit could not be had.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResolveError {
    /// [`VAR`] is set, but not to a commit.
    Env(CommitError),
    /// [`VAR`] is unset and `git` could not read HEAD.
    Git {
        /// The `git` command line.
        command: String,
        /// How it failed.
        source: RunError,
    },
    /// `git` printed something other than a full SHA.
    Output {
        /// The `git` command line.
        command: String,
        /// What it printed, trimmed.
        output: String,
    },
}

impl fmt::Display for ResolveError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Env(error) => write!(f, "{VAR}: {error}"),
            Self::Git { command, source } => {
                write!(
                    f,
                    "set {VAR} or run inside a git checkout: `{command}` failed: {source}"
                )
            }
            Self::Output { command, output } => {
                write!(f, "`{command}` printed `{output}`, not a full commit SHA")
            }
        }
    }
}

impl Error for ResolveError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Env(error) => Some(error),
            Self::Git { source, .. } => Some(source),
            Self::Output { .. } => None,
        }
    }
}

/// The commit: [`VAR`]'s when it is set, else HEAD in the checkout at
/// `repo`, read with [`head`]. A set but empty variable is an error, and a
/// set variable runs nothing.
///
/// # Errors
///
/// A malformed [`VAR`], a failing `git` or output that is not a full SHA.
pub fn resolve(
    env: &impl Env,
    process: &mut impl Process,
    repo: &Path,
) -> Result<Commit, ResolveError> {
    if let Some(value) = env.var(VAR) {
        return Commit::parse(&value.to_string_lossy()).map_err(ResolveError::Env);
    }
    let invocation = head(repo);
    let stdout = process
        .run(&invocation)
        .map_err(|source| ResolveError::Git {
            command: invocation.to_string(),
            source,
        })?;
    let output = String::from_utf8_lossy(&stdout).trim().to_owned();
    Commit::parse(&output).map_err(|_| ResolveError::Output {
        command: invocation.to_string(),
        output,
    })
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;
    use crate::fake::{FakeEnv, RecordingProcess};

    const SHA: &str = "3d9490ca5c5244a972da004c20f1cf2b72ce29d9";

    fn repo() -> PathBuf {
        Path::new("/work").join("leanmacs")
    }

    fn git_prints(
        output: &'static [u8],
    ) -> RecordingProcess<impl FnMut(&Invocation) -> Result<Vec<u8>, RunError>> {
        RecordingProcess::new(move |_: &Invocation| Ok(output.to_vec()))
    }

    #[test]
    fn parses_exactly_forty_lowercase_hex_digits() {
        assert_eq!(
            Commit::parse(SHA).map(|c| c.to_string()),
            Ok(SHA.to_owned())
        );
        assert_eq!(
            Commit::parse(&"a".repeat(40)).map(|c| c.as_str().len()),
            Ok(40)
        );
    }

    #[test]
    fn rejects_each_malformed_commit() {
        for bad in [
            String::new(),
            SHA[..39].to_owned(),
            format!("{SHA}0"),
            SHA.to_uppercase(),
            format!("{}G", &SHA[..39]),
            format!(" {}", &SHA[..39]),
            "3d9490c".to_owned(),
        ] {
            assert_eq!(
                Commit::parse(&bad),
                Err(CommitError::Malformed(bad.clone())),
                "{bad:?}"
            );
        }
    }

    #[test]
    fn the_variable_overrides_git_and_runs_nothing() {
        let mut process = git_prints(b"ignored\n");
        let env = FakeEnv::default().with(VAR, "a".repeat(40));
        let commit = resolve(&env, &mut process, &repo()).expect("a commit");
        assert_eq!(commit.as_str(), "a".repeat(40));
        assert!(process.runs.is_empty());
    }

    #[test]
    fn a_malformed_or_empty_variable_is_an_error_and_runs_nothing() {
        for bad in [String::new(), SHA[..39].to_owned(), SHA.to_uppercase()] {
            let mut process = git_prints(b"ignored\n");
            let env = FakeEnv::default().with(VAR, bad.clone());
            let error = resolve(&env, &mut process, &repo()).expect_err("malformed");
            assert_eq!(error, ResolveError::Env(CommitError::Malformed(bad)));
            assert!(
                error.to_string().starts_with("LEANMACS_COMMIT: "),
                "{error}"
            );
            assert!(process.runs.is_empty());
        }
    }

    #[test]
    fn without_the_variable_it_reads_head() {
        let repo = repo();
        let mut process = git_prints(b"3d9490ca5c5244a972da004c20f1cf2b72ce29d9\n");
        let commit = resolve(&FakeEnv::default(), &mut process, &repo).expect("a commit");
        assert_eq!(commit.as_str(), SHA);
        assert_eq!(process.runs, vec![head(&repo)]);
    }

    #[test]
    fn head_asks_git_to_verify_head() {
        assert_eq!(
            head(&repo()).to_string(),
            "git -C /work/leanmacs rev-parse --verify HEAD"
        );
        assert!(head(&repo()).captured);
    }

    #[test]
    fn a_failing_git_is_an_error_that_names_the_variable() {
        let mut process = RecordingProcess::new(|_: &Invocation| Err(RunError::Failed(Some(128))));
        let error = resolve(&FakeEnv::default(), &mut process, &repo()).expect_err("fails");
        assert!(
            matches!(
                error,
                ResolveError::Git {
                    source: RunError::Failed(Some(128)),
                    ..
                }
            ),
            "{error:?}"
        );
        assert!(error.to_string().contains("set LEANMACS_COMMIT"), "{error}");
    }

    #[test]
    fn output_that_is_not_a_full_sha_is_an_error() {
        for (output, shown) in [
            (&b"HEAD\n"[..], "HEAD"),
            (b"", ""),
            (b"3d9490c\n", "3d9490c"),
        ] {
            let mut process = RecordingProcess::new(move |_: &Invocation| Ok(output.to_vec()));
            let error = resolve(&FakeEnv::default(), &mut process, &repo()).expect_err("fails");
            assert!(
                matches!(&error, ResolveError::Output { output, .. } if output == shown),
                "{error:?}"
            );
        }
    }
}
