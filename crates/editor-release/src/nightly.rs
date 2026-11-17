//! The rolling nightly release: the GitHub prerelease tagged [`TAG`],
//! which holds the newest `main` build's `.dmg` under a fixed name
//! ([`FIXED`]), the same image under its build ID's name
//! ([`dmg::file_name`]), its checksum ([`SHA256`]) and a description of
//! the build ([`BUILD_JSON`]).
//!
//! Everything here is pure or runs through the [`Process`] and [`Env`]
//! ports. `leanmacs-release nightly` and `publish` call it; CI's
//! `release / publish` job runs those two (`.github/workflows/release.yml`).
//!
//! - [`target`] and [`publish_gate`]: the server and repository the release
//!   lives in, from `GITHUB_SERVER_URL` and `GITHUB_REPOSITORY`. [`target`]
//!   falls back to [`DEFAULT_SERVER`] and [`DEFAULT_REPO`] so the owner can
//!   prepare a nightly locally; [`publish_gate`] requires both, and a push
//!   to `refs/heads/main`.
//! - [`read_stamp`] and [`check_stamp`]: the app's stamp, read from the
//!   mounted image's `Info.plist`, which must be the build ID and commit
//!   this build is published under, and the build the image's file name
//!   names. The image is always detached again.
//! - [`prepare`]: the stamp check, the image's SHA-256, the two copies, and
//!   the texts of [`BUILD_JSON`], [`SHA256`] and [`NOTES`] for the adapter
//!   to write. It holds no token and talks to no server.
//! - [`read_build`]: the [`Build`] the prepared directory describes, read
//!   back from its texts and the image's size, refusing any mismatch.
//! - [`publish`]: the ordered `gh` calls that publish a prepared
//!   directory, stopping at the first that fails, with [`prune`] deciding
//!   which old build-ID copies to delete last.

use std::error::Error;
use std::ffi::OsString;
use std::fmt;
use std::path::{Path, PathBuf};

use crate::build_id::BuildId;
use crate::commit::Commit;
use crate::dmg;
use crate::ports::{Env, Invocation, Process, RunError, text};

/// The image's fixed name, the permanent download link's.
pub const FIXED: &str = "Leanmacs.dmg";
/// The image's checksum, in the form `shasum -a 256 -c` reads.
pub const SHA256: &str = "Leanmacs.dmg.sha256";
/// The build's description, which the download page reads.
pub const BUILD_JSON: &str = "build.json";
/// The release's body, written beside the assets and never uploaded.
pub const NOTES: &str = "notes.md";
/// The release's tag.
pub const TAG: &str = "nightly";
/// The release's title.
pub const TITLE: &str = "Leanmacs nightly";
/// How many build-ID copies of the image the release keeps, the newest by
/// build ID.
pub const KEEP: usize = 10;
/// The server when `GITHUB_SERVER_URL` is unset.
pub const DEFAULT_SERVER: &str = "https://github.com";
/// The repository when `GITHUB_REPOSITORY` is unset.
pub const DEFAULT_REPO: &str = "leanmacs/leanmacs";

/// The variable naming the server, as Actions sets it.
pub const SERVER_VAR: &str = "GITHUB_SERVER_URL";
/// The variable naming the repository, `owner/name`, as Actions sets it.
pub const REPO_VAR: &str = "GITHUB_REPOSITORY";
/// The variable naming the event that started the run.
pub const EVENT_VAR: &str = "GITHUB_EVENT_NAME";
/// The variable naming the ref the run is for.
pub const REF_VAR: &str = "GITHUB_REF";
/// The one ref a nightly is published from.
pub const MAIN_REF: &str = "refs/heads/main";

/// A SHA-256 digest: always 64 lowercase hex digits.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Sha256(String);

impl Sha256 {
    /// Reads a digest: exactly 64 lowercase hex digits.
    ///
    /// # Errors
    ///
    /// The text, for anything else.
    pub fn parse(text: &str) -> Result<Self, String> {
        let hex = |b: u8| b.is_ascii_digit() || (b'a'..=b'f').contains(&b);
        if text.len() == 64 && text.bytes().all(hex) {
            Ok(Self(text.to_owned()))
        } else {
            Err(text.to_owned())
        }
    }

    /// The 64 digits.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for Sha256 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// `shasum` printing the SHA-256 of the file at `path`.
#[must_use]
pub fn shasum(path: &Path) -> Invocation {
    Invocation::new("shasum")
        .args(["-a", "256"])
        .arg(path)
        .captured()
}

/// The digest `shasum -a 256 <file>` printed: its first field.
///
/// # Errors
///
/// The output, trimmed, when its first field is not a digest.
pub fn parse_shasum(output: &str) -> Result<Sha256, String> {
    let field = output.split_whitespace().next().unwrap_or("");
    Sha256::parse(field).map_err(|_| output.trim().to_owned())
}

/// A GitHub server's address: `https://` and a host, with no path and no
/// trailing slash.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Server(String);

impl Server {
    /// Reads a server's address.
    ///
    /// # Errors
    ///
    /// The text, when it is not `https://` and a host of letters, digits,
    /// `.`, `-` and `:`.
    pub fn parse(text: &str) -> Result<Self, String> {
        let host = text.strip_prefix("https://").unwrap_or("");
        let ok = |b: u8| b.is_ascii_alphanumeric() || b"-.:".contains(&b);
        if !host.is_empty() && host.bytes().all(ok) {
            Ok(Self(text.to_owned()))
        } else {
            Err(text.to_owned())
        }
    }

    /// The address.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for Server {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// A repository: `owner/name`, each of letters, digits, `.`, `_` and `-`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Repo(String);

impl Repo {
    /// Reads a repository.
    ///
    /// # Errors
    ///
    /// The text, for anything but `owner/name` as above, with neither part
    /// empty nor made of dots alone.
    pub fn parse(text: &str) -> Result<Self, String> {
        let part = |p: &str| {
            !p.is_empty()
                && !p.bytes().all(|b| b == b'.')
                && p.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        };
        match text.split_once('/') {
            Some((owner, name)) if part(owner) && part(name) => Ok(Self(text.to_owned())),
            _ => Err(text.to_owned()),
        }
    }

    /// `owner/name`.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for Repo {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// Where the release lives: the server and the repository.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    /// The server, whose pages the release notes link to.
    pub server: Server,
    /// The repository the release is in.
    pub repo: Repo,
}

impl Target {
    /// The page of `commit` on this server.
    #[must_use]
    pub fn commit_url(&self, commit: &Commit) -> String {
        format!("{}/{}/commit/{commit}", self.server, self.repo)
    }

    /// The permanent link to the nightly's asset `name`.
    #[must_use]
    pub fn download_url(&self, name: &str) -> String {
        format!(
            "{}/{}/releases/download/{TAG}/{name}",
            self.server, self.repo
        )
    }
}

/// Why the release's server or repository could not be had.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TargetError {
    /// A variable that must be set is not.
    Unset(&'static str),
    /// `GITHUB_SERVER_URL` is not a server's address.
    Server(String),
    /// `GITHUB_REPOSITORY` is not `owner/name`.
    Repo(String),
}

impl fmt::Display for TargetError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unset(name) => write!(f, "{name} is not set"),
            Self::Server(value) => {
                write!(f, "{SERVER_VAR} is `{value}`, not https:// and a host")
            }
            Self::Repo(value) => write!(f, "{REPO_VAR} is `{value}`, not owner/name"),
        }
    }
}

impl Error for TargetError {}

/// The target from the environment: each variable when it is set, and
/// checked; when `strict`, an unset one is an error, else its default.
fn resolve_target(env: &impl Env, strict: bool) -> Result<Target, TargetError> {
    let read = |name: &'static str, default: &str| match env.var(name) {
        Some(value) => Ok(value.to_string_lossy().into_owned()),
        None if strict => Err(TargetError::Unset(name)),
        None => Ok(default.to_owned()),
    };
    let server = Server::parse(&read(SERVER_VAR, DEFAULT_SERVER)?).map_err(TargetError::Server)?;
    let repo = Repo::parse(&read(REPO_VAR, DEFAULT_REPO)?).map_err(TargetError::Repo)?;
    Ok(Target { server, repo })
}

/// The release's server and repository: `GITHUB_SERVER_URL` and
/// `GITHUB_REPOSITORY` when set, else [`DEFAULT_SERVER`] and
/// [`DEFAULT_REPO`], so a nightly can be prepared outside Actions. A set
/// variable must be well formed; an empty one is not.
///
/// # Errors
///
/// A malformed variable.
pub fn target(env: &impl Env) -> Result<Target, TargetError> {
    resolve_target(env, false)
}

/// Why [`publish_gate`] refuses to publish.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GateError {
    /// The run was not started by a push: the event it was, or unset.
    Event(Option<String>),
    /// The run is not for `refs/heads/main`: the ref it is, or unset.
    Ref(Option<String>),
    /// The server or repository is unset or malformed.
    Target(TargetError),
}

impl fmt::Display for GateError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let shown = |v: &Option<String>| v.clone().unwrap_or_else(|| "unset".to_owned());
        match self {
            Self::Event(event) => write!(
                f,
                "the nightly is published from a push only; {EVENT_VAR} is {}",
                shown(event)
            ),
            Self::Ref(reference) => write!(
                f,
                "the nightly is published from {MAIN_REF} only; {REF_VAR} is {}",
                shown(reference)
            ),
            Self::Target(error) => error.fmt(f),
        }
    }
}

impl Error for GateError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Target(error) => Some(error),
            Self::Event(_) | Self::Ref(_) => None,
        }
    }
}

/// The release's target, when this run may publish: it was started by a
/// push (`GITHUB_EVENT_NAME` is `push`) to `refs/heads/main`
/// (`GITHUB_REF`), and `GITHUB_SERVER_URL` and `GITHUB_REPOSITORY` are both
/// set and well formed, as [`target`] reads them but with no default. This
/// is defence in depth: the workflow's job runs on a main push alone.
///
/// # Errors
///
/// As [`GateError`] says.
pub fn publish_gate(env: &impl Env) -> Result<Target, GateError> {
    let var = |name| env.var(name).map(|v| v.to_string_lossy().into_owned());
    let event = var(EVENT_VAR);
    if event.as_deref() != Some("push") {
        return Err(GateError::Event(event));
    }
    let reference = var(REF_VAR);
    if reference.as_deref() != Some(MAIN_REF) {
        return Err(GateError::Ref(reference));
    }
    resolve_target(env, true).map_err(GateError::Target)
}

/// One build, as the release describes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Build {
    /// Its build ID.
    pub id: BuildId,
    /// The commit it was built from.
    pub commit: Commit,
    /// The image's size, in bytes.
    pub size: u64,
    /// The image's SHA-256.
    pub sha256: Sha256,
}

impl Build {
    /// The image's build-ID name, `Leanmacs-<id>.dmg`.
    #[must_use]
    pub fn copy_name(&self) -> String {
        dmg::file_name(&self.id)
    }
}

/// [`BUILD_JSON`]'s text: the build ID, the commit, the build's time in
/// UTC (the commit's, from the ID), the image's size and SHA-256, and its
/// two names, in that order, with a two-space indent and a final newline.
/// Every value is checked text (digits or hex) or a fixed name, so none
/// needs escaping.
#[must_use]
pub fn build_json(build: &Build) -> String {
    format!(
        "{{\n  \"build_id\": \"{}\",\n  \"commit\": \"{}\",\n  \"date\": \"{}\",\n  \"size\": {},\n  \"sha256\": \"{}\",\n  \"file\": \"{FIXED}\",\n  \"build_file\": \"{}\"\n}}\n",
        build.id,
        build.commit,
        build.id.timestamp(),
        build.size,
        build.sha256,
        build.copy_name()
    )
}

/// [`SHA256`]'s text: `<hex>  Leanmacs.dmg` and a newline, which
/// `shasum -a 256 -c` checks against the image beside it.
#[must_use]
pub fn sha256_line(build: &Build) -> String {
    format!("{}  {FIXED}\n", build.sha256)
}

/// The release's body, in Markdown: the build, where it runs, how to get
/// past Gatekeeper on first launch (as `packaging/macos/README.txt` says),
/// and how to see which build is installed.
#[must_use]
pub fn notes(build: &Build, target: &Target) -> String {
    let (id, commit) = (&build.id, &build.commit);
    format!(
        "The newest build of `main`: unreleased, made on every push that passes CI.

- Build ID: `{id}` (the commit's time, UTC)
- Commit: [`{commit}`]({url})
- Date: {date}
- Size: {size} bytes
- SHA-256: `{sha256}`

Requires macOS 26.0 or later, on Apple silicon.

## Install

Download [`{FIXED}`]({download}), open it, and drag Leanmacs.app onto Applications. `{copy}` is the same image under this build's name. To check the download, put `{SHA256}` beside it and run `shasum -a 256 -c {SHA256}`.

## First launch

The app is ad-hoc signed and not notarized (Developer ID signing is not done yet), so macOS blocks it the first time:

1. Open Leanmacs once. macOS says it cannot check it; click **Done**.
2. Open **System Settings > Privacy & Security**, scroll down, and click **Open Anyway** beside the message about Leanmacs.
3. Open Leanmacs again and confirm.

If that does not work, remove the quarantine flag in Terminal:

    xattr -dr com.apple.quarantine /Applications/Leanmacs.app

## Which build is installed

    /Applications/Leanmacs.app/Contents/MacOS/editor --version

prints the version, the build ID and the commit.
",
        url = target.commit_url(commit),
        download = target.download_url(FIXED),
        date = id.timestamp(),
        size = build.size,
        sha256 = build.sha256,
        copy = build.copy_name(),
    )
}

/// The app's stamp, as its `Info.plist` holds it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Stamp {
    /// `CFBundleVersion`, trimmed: the build ID it was built as.
    pub build_id: String,
    /// `LeanmacsCommit`, trimmed: the commit it was built from.
    pub commit: String,
}

/// `hdiutil` mounting `image` read-only at `mount_point`, with no Finder
/// window.
#[must_use]
pub fn attach(image: &Path, mount_point: &Path) -> Invocation {
    Invocation::new("hdiutil")
        .args([
            "attach",
            "-nobrowse",
            "-readonly",
            "-noautoopen",
            "-mountpoint",
        ])
        .arg(mount_point)
        .arg(image)
        .captured()
}

/// `hdiutil` detaching the image at `mount_point`, by force when `force`.
#[must_use]
pub fn detach(mount_point: &Path, force: bool) -> Invocation {
    let invocation = Invocation::new("hdiutil").arg("detach");
    let invocation = if force {
        invocation.arg("-force")
    } else {
        invocation
    };
    invocation.arg(mount_point).captured()
}

/// `plutil` printing `key` of the app's `Info.plist` in the volume at
/// `mount_point`.
#[must_use]
pub fn plist_key(mount_point: &Path, key: &str) -> Invocation {
    Invocation::new("plutil")
        .args(["-extract", key, "raw", "-o", "-"])
        .arg(
            mount_point
                .join(dmg::APP)
                .join("Contents")
                .join("Info.plist"),
        )
        .captured()
}

/// Why the stamp could not be read, or is not this build's.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StampError {
    /// A program failed: mounting, reading a key, or detaching even by
    /// force.
    Run {
        /// Its command line.
        command: String,
        /// How it failed.
        source: RunError,
    },
    /// The image's file name names another build, or none.
    FileName {
        /// The file name.
        name: String,
        /// This build.
        expected: BuildId,
    },
    /// The app's `CFBundleVersion` is not this build's ID.
    BuildId {
        /// What the app holds.
        plist: String,
        /// This build.
        expected: BuildId,
    },
    /// The app's `LeanmacsCommit` is not this build's commit.
    Commit {
        /// What the app holds.
        plist: String,
        /// This build's commit.
        expected: Commit,
    },
}

impl fmt::Display for StampError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Run { command, source } => write!(f, "`{command}` failed: {source}"),
            Self::FileName { name, expected } => write!(
                f,
                "the image is named {name}, not {}: it is not build {expected}",
                dmg::file_name(expected)
            ),
            Self::BuildId { plist, expected } => write!(
                f,
                "the app's CFBundleVersion is `{plist}`, but this build is {expected}"
            ),
            Self::Commit { plist, expected } => write!(
                f,
                "the app's LeanmacsCommit is `{plist}`, but this build's commit is {expected}"
            ),
        }
    }
}

impl Error for StampError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Run { source, .. } => Some(source),
            Self::FileName { .. } | Self::BuildId { .. } | Self::Commit { .. } => None,
        }
    }
}

fn run_error(invocation: &Invocation) -> impl FnOnce(RunError) -> StampError {
    let command = invocation.to_string();
    move |source| StampError::Run { command, source }
}

/// Mounts `image` at `mount_point`, reads the app's `CFBundleVersion` and
/// `LeanmacsCommit`, and detaches it, by force if a plain detach fails.
/// Once mounted, the image is always detached, even when a read failed.
///
/// # Errors
///
/// The first program that failed; a failed read is reported over a failed
/// detach.
pub fn read_stamp(
    process: &mut impl Process,
    image: &Path,
    mount_point: &Path,
) -> Result<Stamp, StampError> {
    let mount = attach(image, mount_point);
    process.run(&mount).map_err(run_error(&mount))?;
    let mut read = |key: &str| {
        let invocation = plist_key(mount_point, key);
        text(process, &invocation)
            .map(|value| value.trim().to_owned())
            .map_err(run_error(&invocation))
    };
    let stamp = read("CFBundleVersion")
        .and_then(|build_id| read("LeanmacsCommit").map(|commit| Stamp { build_id, commit }));
    let plain = detach(mount_point, false);
    let detached = process.run(&plain).or_else(|_| {
        let forced = detach(mount_point, true);
        process.run(&forced).map_err(run_error(&forced))
    });
    let stamp = stamp?;
    detached?;
    Ok(stamp)
}

/// Checks that the image is this build's: its file name names `id`, and the
/// app's `CFBundleVersion` is `id` and its `LeanmacsCommit` is `commit`.
/// Each error names both values.
///
/// # Errors
///
/// The first of those that does not hold, in that order.
pub fn check_stamp(
    stamp: &Stamp,
    id: &BuildId,
    commit: &Commit,
    file_name: &str,
) -> Result<(), StampError> {
    if dmg::build_of(file_name).as_ref() != Some(id) {
        return Err(StampError::FileName {
            name: file_name.to_owned(),
            expected: id.clone(),
        });
    }
    if stamp.build_id != id.as_str() {
        return Err(StampError::BuildId {
            plist: stamp.build_id.clone(),
            expected: id.clone(),
        });
    }
    if stamp.commit != commit.as_str() {
        return Err(StampError::Commit {
            plist: stamp.commit.clone(),
            expected: commit.clone(),
        });
    }
    Ok(())
}

/// A prepared nightly: the build, and the texts the adapter writes beside
/// the two images.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Prepared {
    /// The build.
    pub build: Build,
    /// [`BUILD_JSON`]'s text.
    pub build_json: String,
    /// [`SHA256`]'s text.
    pub sha256: String,
    /// [`NOTES`]'s text.
    pub notes: String,
}

impl Prepared {
    /// Each text with the file name it is written to, in the output
    /// directory.
    #[must_use]
    pub fn texts(&self) -> [(&'static str, &str); 3] {
        [
            (BUILD_JSON, &self.build_json),
            (SHA256, &self.sha256),
            (NOTES, &self.notes),
        ]
    }
}

/// Why [`prepare`] did not prepare the nightly.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PrepareError {
    /// The image's file name or the app's stamp is not this build's, or
    /// could not be read.
    Stamp(StampError),
    /// A program failed: `shasum` or a copy.
    Run {
        /// Its command line.
        command: String,
        /// How it failed.
        source: RunError,
    },
    /// `shasum` printed no digest.
    Shasum(String),
    /// The image's path has no file name.
    NoFileName(PathBuf),
}

impl fmt::Display for PrepareError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Stamp(error) => error.fmt(f),
            Self::Run { command, source } => write!(f, "`{command}` failed: {source}"),
            Self::Shasum(output) => write!(f, "shasum printed `{output}`, not a SHA-256"),
            Self::NoFileName(path) => write!(f, "{} names no file", path.display()),
        }
    }
}

impl Error for PrepareError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Stamp(error) => Some(error),
            Self::Run { source, .. } => Some(source),
            Self::Shasum(_) | Self::NoFileName(_) => None,
        }
    }
}

/// What [`prepare`] works on.
#[derive(Debug, Clone, Copy)]
pub struct Inputs<'a> {
    /// The packed image, `Leanmacs-<id>.dmg`.
    pub image: &'a Path,
    /// Its size, in bytes.
    pub size: u64,
    /// Where to mount it, an empty directory or none.
    pub mount_point: &'a Path,
    /// Where the two copies go; the adapter has made it and writes the
    /// texts there.
    pub out: &'a Path,
}

/// Prepares the nightly of build `id` from `commit`, published to
/// `target`: checks the image's file name and the app's stamp
/// ([`read_stamp`], [`check_stamp`]), reads the image's SHA-256, copies it
/// to `<out>/Leanmacs-<id>.dmg` and `<out>/Leanmacs.dmg`, and returns the
/// texts of [`BUILD_JSON`], [`SHA256`] and [`NOTES`], made from the same
/// `id` and `commit` the stamp was checked against. Nothing is copied
/// unless the stamp is this build's.
///
/// # Errors
///
/// As [`PrepareError`] says.
pub fn prepare(
    process: &mut impl Process,
    inputs: &Inputs<'_>,
    id: &BuildId,
    commit: &Commit,
    target: &Target,
) -> Result<Prepared, PrepareError> {
    let name = inputs
        .image
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .ok_or_else(|| PrepareError::NoFileName(inputs.image.to_owned()))?;
    let stamp =
        read_stamp(process, inputs.image, inputs.mount_point).map_err(PrepareError::Stamp)?;
    check_stamp(&stamp, id, commit, &name).map_err(PrepareError::Stamp)?;
    let run = |invocation: &Invocation| {
        let command = invocation.to_string();
        move |source| PrepareError::Run { command, source }
    };
    let sum = shasum(inputs.image);
    let output = text(process, &sum).map_err(run(&sum))?;
    let sha256 = parse_shasum(&output).map_err(PrepareError::Shasum)?;
    let build = Build {
        id: id.clone(),
        commit: commit.clone(),
        size: inputs.size,
        sha256,
    };
    for name in [build.copy_name(), FIXED.to_owned()] {
        let copy = Invocation::new("cp")
            .arg(inputs.image)
            .arg(inputs.out.join(name));
        process.run(&copy).map_err(run(&copy))?;
    }
    Ok(Prepared {
        build_json: build_json(&build),
        sha256: sha256_line(&build),
        notes: notes(&build, target),
        build,
    })
}

/// Why a prepared directory does not describe this build.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReadError {
    /// [`SHA256`]'s text is not a line [`sha256_line`] writes.
    Sha256File(String),
    /// [`BUILD_JSON`]'s text is not what [`build_json`] writes for this
    /// build, the image's size and the checksum file's digest.
    BuildJson {
        /// What it should be.
        expected: String,
        /// What it is.
        found: String,
    },
}

impl fmt::Display for ReadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Sha256File(found) => write!(
                f,
                "{SHA256} is `{}`, not `<sha-256>  {FIXED}`",
                found.trim_end()
            ),
            Self::BuildJson { expected, found } => write!(
                f,
                "{BUILD_JSON} does not describe this build, its image's size and its checksum: it is\n{found}it should be\n{expected}"
            ),
        }
    }
}

impl Error for ReadError {}

/// The build a prepared directory describes: its [`SHA256`] text's digest,
/// with `size` (the size of its [`FIXED`]), `id` and `commit`, which its
/// [`BUILD_JSON`] text must describe exactly.
///
/// # Errors
///
/// A checksum file [`sha256_line`] did not write, or a `build.json` that
/// is not this build's.
pub fn read_build(
    build_json_text: &str,
    sha256_text: &str,
    size: u64,
    id: &BuildId,
    commit: &Commit,
) -> Result<Build, ReadError> {
    let bad = || ReadError::Sha256File(sha256_text.to_owned());
    let hex = sha256_text
        .strip_suffix(&format!("  {FIXED}\n"))
        .ok_or_else(bad)?;
    let sha256 = Sha256::parse(hex).map_err(|_| bad())?;
    let build = Build {
        id: id.clone(),
        commit: commit.clone(),
        size,
        sha256,
    };
    let expected = build_json(&build);
    if expected != build_json_text {
        return Err(ReadError::BuildJson {
            expected,
            found: build_json_text.to_owned(),
        });
    }
    Ok(build)
}

/// The build-ID copies among `existing` (the release's asset names) to
/// delete once build `current`'s copy is up: all but the newest `keep` by
/// build ID, `current` counted among them. `current`'s own copy, the fixed
/// names and any name that is not a build-ID copy are never deleted. Oldest
/// first.
#[must_use]
pub fn prune(existing: &[String], current: &BuildId, keep: usize) -> Vec<String> {
    let mut ids: Vec<BuildId> = existing.iter().filter_map(|n| dmg::build_of(n)).collect();
    ids.push(current.clone());
    ids.sort();
    ids.dedup();
    let kept: Vec<BuildId> = ids.iter().rev().take(keep).cloned().collect();
    let mut doomed: Vec<(BuildId, String)> = existing
        .iter()
        .filter_map(|n| dmg::build_of(n).map(|id| (id, n.clone())))
        .filter(|(id, _)| id != current && !kept.contains(id))
        .collect();
    doomed.sort();
    doomed.into_iter().map(|(_, name)| name).collect()
}

/// Why [`publish`] stopped.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PublishError {
    /// A program failed.
    Run {
        /// Its command line.
        command: String,
        /// How it failed.
        source: RunError,
    },
    /// `shasum` printed no digest.
    Shasum(String),
    /// An image in the directory is not the one its checksum names.
    Hash {
        /// The image.
        file: PathBuf,
        /// The build's digest.
        expected: Sha256,
        /// The image's.
        found: Sha256,
    },
}

impl fmt::Display for PublishError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Run { command, source } => write!(f, "`{command}` failed: {source}"),
            Self::Shasum(output) => write!(f, "shasum printed `{output}`, not a SHA-256"),
            Self::Hash {
                file,
                expected,
                found,
            } => write!(
                f,
                "{}'s SHA-256 is {found}, but {SHA256} says {expected}",
                file.display()
            ),
        }
    }
}

impl Error for PublishError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Run { source, .. } => Some(source),
            Self::Shasum(_) | Self::Hash { .. } => None,
        }
    }
}

/// `gh` with `args`, then `--repo <repo>`.
fn gh<I, A>(repo: &Repo, args: I) -> Invocation
where
    I: IntoIterator<Item = A>,
    A: AsRef<std::ffi::OsStr>,
{
    Invocation::new("gh")
        .args(args)
        .args(["--repo", repo.as_str()])
}

/// Publishes the nightly prepared in `dir` as `build` to `repo`, in this
/// order, stopping at the first step that fails:
///
/// 1. list the releases' tags, to learn whether [`TAG`] exists, and if it
///    does, list its assets, the input to [`prune`];
/// 2. check both images' SHA-256 against the build's, so nothing goes up
///    that is not what was checked;
/// 3. if the release does not exist, create it as a prerelease, which
///    creates the tag at the build's commit;
/// 4. upload the build-ID copy (a new name, so the old nightly is
///    untouched), then [`FIXED`], [`SHA256`] and [`BUILD_JSON`] last, so
///    the page never names a build whose image is not up yet, each
///    replacing an asset of the same name;
/// 5. move the tag to the build's commit through the API (no git
///    credentials);
/// 6. set the release's title and body ([`NOTES`]), as a prerelease;
/// 7. delete the old build-ID copies [`prune`] names, keeping [`KEEP`].
///
/// # Errors
///
/// As [`PublishError`] says.
pub fn publish(
    process: &mut impl Process,
    repo: &Repo,
    dir: &Path,
    build: &Build,
) -> Result<(), PublishError> {
    let mut run = |invocation: Invocation| {
        text(process, &invocation).map_err(|source| PublishError::Run {
            command: invocation.to_string(),
            source,
        })
    };
    let tags = run(gh(
        repo,
        [
            "release",
            "list",
            "--limit",
            "1000",
            "--json",
            "tagName",
            "--jq",
            ".[].tagName",
        ],
    )
    .captured())?;
    let exists = tags.lines().any(|t| t.trim() == TAG);
    let assets: Vec<String> = if exists {
        run(gh(
            repo,
            [
                "release",
                "view",
                TAG,
                "--json",
                "assets",
                "--jq",
                ".assets[].name",
            ],
        )
        .captured())?
        .lines()
        .map(str::trim)
        .filter(|n| !n.is_empty())
        .map(str::to_owned)
        .collect()
    } else {
        Vec::new()
    };
    let copy = dir.join(build.copy_name());
    let fixed = dir.join(FIXED);
    for image in [&copy, &fixed] {
        let found = parse_shasum(&run(shasum(image))?).map_err(PublishError::Shasum)?;
        if found != build.sha256 {
            return Err(PublishError::Hash {
                file: image.clone(),
                expected: build.sha256.clone(),
                found,
            });
        }
    }
    let notes: OsString = dir.join(NOTES).into();
    let title_and_notes = || -> [OsString; 4] {
        [
            "--title".into(),
            TITLE.into(),
            "--notes-file".into(),
            notes.clone(),
        ]
    };
    if !exists {
        let head: [OsString; 5] = [
            "release".into(),
            "create".into(),
            TAG.into(),
            "--prerelease".into(),
            "--target".into(),
        ];
        let args = head
            .into_iter()
            .chain([build.commit.as_str().into()])
            .chain(title_and_notes());
        run(gh(repo, args))?;
    }
    for file in [copy, fixed, dir.join(SHA256), dir.join(BUILD_JSON)] {
        let args: [OsString; 5] = [
            "release".into(),
            "upload".into(),
            TAG.into(),
            file.into(),
            "--clobber".into(),
        ];
        run(gh(repo, args))?;
    }
    run(Invocation::new("gh")
        .args(["api", "--method", "PATCH"])
        .arg(format!("repos/{repo}/git/refs/tags/{TAG}"))
        .args(["-f", &format!("sha={}", build.commit), "-F", "force=true"])
        .captured())?;
    let head: [OsString; 4] = [
        "release".into(),
        "edit".into(),
        TAG.into(),
        "--prerelease".into(),
    ];
    run(gh(repo, head.into_iter().chain(title_and_notes())))?;
    for name in prune(&assets, &build.id, KEEP) {
        run(gh(repo, ["release", "delete-asset", TAG, &name, "--yes"]))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake::{FakeEnv, RecordingProcess};

    const ID: &str = "20010203040506";
    const SHA: &str = "0123456789abcdef0123456789abcdef01234567";
    const HEX: &str = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90";

    fn id() -> BuildId {
        BuildId::parse(ID).expect("an ID")
    }

    fn commit() -> Commit {
        Commit::parse(SHA).expect("a commit")
    }

    fn build() -> Build {
        Build {
            id: id(),
            commit: commit(),
            size: 123_456,
            sha256: Sha256::parse(HEX).expect("a digest"),
        }
    }

    fn leanmacs() -> Target {
        Target {
            server: Server::parse("https://github.com").expect("a server"),
            repo: Repo::parse("leanmacs/leanmacs").expect("a repo"),
        }
    }

    fn lines(runs: &[Invocation]) -> Vec<String> {
        runs.iter().map(ToString::to_string).collect()
    }

    #[test]
    fn a_digest_is_64_lowercase_hex_digits() {
        assert!(Sha256::parse(HEX).is_ok());
        for bad in [
            "",
            "abc",
            &HEX.to_uppercase(),
            &format!("{HEX}0"),
            &HEX.replace('a', "g"),
        ] {
            assert_eq!(Sha256::parse(bad), Err(bad.to_owned()), "{bad}");
        }
    }

    #[test]
    fn shasum_asks_for_sha_256_and_its_first_field_is_the_digest() {
        assert_eq!(
            shasum(Path::new("/w/Leanmacs.dmg")).to_string(),
            "shasum -a 256 /w/Leanmacs.dmg"
        );
        assert!(shasum(Path::new("/w/x")).captured);
        assert_eq!(
            parse_shasum(&format!("{HEX}  /w/Leanmacs.dmg\n")).map(|s| s.to_string()),
            Ok(HEX.to_owned())
        );
        assert_eq!(parse_shasum("nope  x\n"), Err("nope  x".to_owned()));
        assert_eq!(parse_shasum(""), Err(String::new()));
    }

    #[test]
    fn a_server_is_https_and_a_host() {
        for good in ["https://github.com", "https://ghe.example.com:8443"] {
            assert!(Server::parse(good).is_ok(), "{good}");
        }
        for bad in [
            "",
            "https://",
            "http://github.com",
            "https://github.com/",
            "https://github.com/x",
            "https://git hub.com",
        ] {
            assert_eq!(Server::parse(bad), Err(bad.to_owned()), "{bad}");
        }
    }

    #[test]
    fn a_repo_is_owner_slash_name() {
        for good in ["leanmacs/leanmacs", "a-b/c.d_e", "A1/b2"] {
            assert!(Repo::parse(good).is_ok(), "{good}");
        }
        for bad in [
            "",
            "leanmacs",
            "/leanmacs",
            "leanmacs/",
            "a/b/c",
            "a/b c",
            "a/..",
            "../b",
            "a/b;rm",
        ] {
            assert_eq!(Repo::parse(bad), Err(bad.to_owned()), "{bad}");
        }
    }

    #[test]
    fn the_target_defaults_outside_actions_and_reads_the_variables_inside() {
        assert_eq!(
            target(&FakeEnv::default()),
            Ok(target_of("https://github.com", DEFAULT_REPO))
        );
        let env = FakeEnv::default()
            .with(SERVER_VAR, "https://ghe.example.com")
            .with(REPO_VAR, "ada/fork");
        assert_eq!(
            target(&env),
            Ok(target_of("https://ghe.example.com", "ada/fork"))
        );
        assert_eq!(
            target(&FakeEnv::default().with(REPO_VAR, "")),
            Err(TargetError::Repo(String::new()))
        );
        assert_eq!(
            target(&FakeEnv::default().with(SERVER_VAR, "http://x")),
            Err(TargetError::Server("http://x".into()))
        );
        assert_eq!(
            TargetError::Repo("x".into()).to_string(),
            "GITHUB_REPOSITORY is `x`, not owner/name"
        );
    }

    fn target_of(server: &str, repo: &str) -> Target {
        Target {
            server: Server::parse(server).expect("a server"),
            repo: Repo::parse(repo).expect("a repo"),
        }
    }

    #[test]
    fn the_target_links_the_commit_and_the_permanent_download() {
        assert_eq!(
            leanmacs().commit_url(&commit()),
            format!("https://github.com/leanmacs/leanmacs/commit/{SHA}")
        );
        assert_eq!(
            leanmacs().download_url(FIXED),
            "https://github.com/leanmacs/leanmacs/releases/download/nightly/Leanmacs.dmg"
        );
    }

    fn main_push() -> FakeEnv {
        FakeEnv::default()
            .with(EVENT_VAR, "push")
            .with(REF_VAR, "refs/heads/main")
            .with(SERVER_VAR, "https://github.com")
            .with(REPO_VAR, "leanmacs/leanmacs")
    }

    #[test]
    fn the_gate_lets_a_main_push_publish() {
        assert_eq!(publish_gate(&main_push()), Ok(leanmacs()));
    }

    #[test]
    fn the_gate_refuses_a_pull_request_a_branch_or_an_unset_event() {
        assert_eq!(
            publish_gate(&main_push().with(EVENT_VAR, "pull_request")),
            Err(GateError::Event(Some("pull_request".into())))
        );
        assert_eq!(
            publish_gate(&main_push().with(REF_VAR, "refs/heads/topic")),
            Err(GateError::Ref(Some("refs/heads/topic".into())))
        );
        assert_eq!(
            publish_gate(&main_push().with(REF_VAR, "refs/pull/1/merge")),
            Err(GateError::Ref(Some("refs/pull/1/merge".into())))
        );
        assert_eq!(
            publish_gate(&FakeEnv::default()),
            Err(GateError::Event(None))
        );
        assert_eq!(
            GateError::Event(Some("pull_request".into())).to_string(),
            "the nightly is published from a push only; GITHUB_EVENT_NAME is pull_request"
        );
        assert_eq!(
            GateError::Ref(None).to_string(),
            "the nightly is published from refs/heads/main only; GITHUB_REF is unset"
        );
    }

    #[test]
    fn the_gate_has_no_default_leanmacs() {
        let mut env = main_push();
        env.0.remove(REPO_VAR);
        assert_eq!(
            publish_gate(&env),
            Err(GateError::Target(TargetError::Unset(REPO_VAR)))
        );
        let mut env = main_push();
        env.0.remove(SERVER_VAR);
        assert_eq!(
            publish_gate(&env),
            Err(GateError::Target(TargetError::Unset(SERVER_VAR)))
        );
        assert_eq!(
            publish_gate(&main_push().with(REPO_VAR, "nope")),
            Err(GateError::Target(TargetError::Repo("nope".into())))
        );
    }

    #[test]
    fn build_json_is_the_documented_schema() {
        assert_eq!(
            build_json(&build()),
            format!(
                "{{\n  \"build_id\": \"20010203040506\",\n  \"commit\": \"{SHA}\",\n  \"date\": \"2001-02-03T04:05:06Z\",\n  \"size\": 123456,\n  \"sha256\": \"{HEX}\",\n  \"file\": \"Leanmacs.dmg\",\n  \"build_file\": \"Leanmacs-20010203040506.dmg\"\n}}\n"
            )
        );
    }

    #[test]
    fn the_sha256_line_is_what_shasum_c_reads() {
        assert_eq!(sha256_line(&build()), format!("{HEX}  Leanmacs.dmg\n"));
    }

    #[test]
    fn the_notes_give_the_build_and_the_first_launch_steps() {
        let notes = notes(&build(), &leanmacs());
        for part in [
            "Build ID: `20010203040506`",
            &format!("[`{SHA}`](https://github.com/leanmacs/leanmacs/commit/{SHA})"),
            "Date: 2001-02-03T04:05:06Z",
            "Size: 123456 bytes",
            &format!("SHA-256: `{HEX}`"),
            "macOS 26.0 or later, on Apple silicon",
            "https://github.com/leanmacs/leanmacs/releases/download/nightly/Leanmacs.dmg",
            "`Leanmacs-20010203040506.dmg`",
            "shasum -a 256 -c Leanmacs.dmg.sha256",
            "click **Done**",
            "**System Settings > Privacy & Security**",
            "**Open Anyway**",
            "xattr -dr com.apple.quarantine /Applications/Leanmacs.app",
            "/Applications/Leanmacs.app/Contents/MacOS/editor --version",
            "Developer ID signing is not done yet",
        ] {
            assert!(notes.contains(part), "the notes lack {part}:\n{notes}");
        }
    }

    /// A process for the stamp: `plutil` answers from `version` and
    /// `commit`, a program in `failing` fails, and anything else succeeds
    /// with no output.
    fn mounted(
        version: &'static str,
        commit: &'static str,
        failing: &'static [&'static str],
    ) -> RecordingProcess<impl FnMut(&Invocation) -> Result<Vec<u8>, RunError>> {
        RecordingProcess::new(move |i: &Invocation| {
            let line = i.to_string();
            if failing.iter().any(|f| line.starts_with(f)) {
                return Err(RunError::Failed(Some(1)));
            }
            Ok(if line.contains("CFBundleVersion") {
                version.into()
            } else if line.contains("LeanmacsCommit") {
                commit.into()
            } else if i.program == "shasum" {
                format!("{HEX}  {}\n", i.args[2].to_string_lossy()).into_bytes()
            } else {
                Vec::new()
            })
        })
    }

    const IMAGE: &str = "/w/dist/Leanmacs-20010203040506.dmg";
    const MOUNT: &str = "/w/target/nightly-mount";

    fn stamp_runs() -> Vec<String> {
        vec![
            format!("hdiutil attach -nobrowse -readonly -noautoopen -mountpoint {MOUNT} {IMAGE}"),
            format!(
                "plutil -extract CFBundleVersion raw -o - {MOUNT}/Leanmacs.app/Contents/Info.plist"
            ),
            format!(
                "plutil -extract LeanmacsCommit raw -o - {MOUNT}/Leanmacs.app/Contents/Info.plist"
            ),
            format!("hdiutil detach {MOUNT}"),
        ]
    }

    #[test]
    fn read_stamp_mounts_reads_both_keys_and_detaches() {
        let mut process = mounted(
            "20010203040506\n",
            "0123456789abcdef0123456789abcdef01234567\n",
            &[],
        );
        let stamp = read_stamp(&mut process, Path::new(IMAGE), Path::new(MOUNT)).expect("a stamp");
        assert_eq!(
            stamp,
            Stamp {
                build_id: ID.into(),
                commit: SHA.into()
            }
        );
        assert_eq!(lines(&process.runs), stamp_runs());
        assert!(process.runs.iter().all(|i| i.captured));
    }

    #[test]
    fn read_stamp_detaches_even_when_a_read_fails() {
        let mut process = mounted(ID, SHA, &["plutil -extract LeanmacsCommit"]);
        let error =
            read_stamp(&mut process, Path::new(IMAGE), Path::new(MOUNT)).expect_err("fails");
        assert!(
            matches!(&error, StampError::Run { command, .. } if command.contains("LeanmacsCommit")),
            "{error:?}"
        );
        assert_eq!(lines(&process.runs), stamp_runs());
    }

    #[test]
    fn read_stamp_forces_the_detach_when_a_plain_one_fails() {
        let mut process = mounted(ID, SHA, &["hdiutil detach /"]);
        let stamp = read_stamp(&mut process, Path::new(IMAGE), Path::new(MOUNT));
        assert!(stamp.is_ok(), "{stamp:?}");
        let mut expected = stamp_runs();
        expected.push(format!("hdiutil detach -force {MOUNT}"));
        assert_eq!(lines(&process.runs), expected);
    }

    #[test]
    fn read_stamp_fails_when_even_the_forced_detach_fails() {
        let mut process = mounted(ID, SHA, &["hdiutil detach"]);
        let error =
            read_stamp(&mut process, Path::new(IMAGE), Path::new(MOUNT)).expect_err("fails");
        assert_eq!(
            error.to_string(),
            format!("`hdiutil detach -force {MOUNT}` failed: it exited with code 1")
        );
    }

    #[test]
    fn read_stamp_does_not_detach_what_it_never_mounted() {
        let mut process = mounted(ID, SHA, &["hdiutil attach"]);
        assert!(read_stamp(&mut process, Path::new(IMAGE), Path::new(MOUNT)).is_err());
        assert_eq!(process.runs.len(), 1);
    }

    fn stamp(build_id: &str, commit: &str) -> Stamp {
        Stamp {
            build_id: build_id.into(),
            commit: commit.into(),
        }
    }

    #[test]
    fn check_stamp_accepts_this_build() {
        assert_eq!(
            check_stamp(
                &stamp(ID, SHA),
                &id(),
                &commit(),
                "Leanmacs-20010203040506.dmg"
            ),
            Ok(())
        );
    }

    #[test]
    fn check_stamp_refuses_another_build_id_and_names_both() {
        let error = check_stamp(
            &stamp("20010203040507", SHA),
            &id(),
            &commit(),
            "Leanmacs-20010203040506.dmg",
        )
        .expect_err("another build");
        assert_eq!(
            error.to_string(),
            "the app's CFBundleVersion is `20010203040507`, but this build is 20010203040506"
        );
    }

    #[test]
    fn check_stamp_refuses_another_commit_and_names_both() {
        let other = "fedcba9876543210fedcba9876543210fedcba98";
        let error = check_stamp(
            &stamp(ID, other),
            &id(),
            &commit(),
            "Leanmacs-20010203040506.dmg",
        )
        .expect_err("another commit");
        assert_eq!(
            error.to_string(),
            format!("the app's LeanmacsCommit is `{other}`, but this build's commit is {SHA}")
        );
    }

    #[test]
    fn check_stamp_refuses_an_image_named_for_another_build() {
        for name in ["Leanmacs-20010203040507.dmg", "Leanmacs.dmg", "other.dmg"] {
            let error = check_stamp(&stamp(ID, SHA), &id(), &commit(), name).expect_err(name);
            assert_eq!(
                error,
                StampError::FileName {
                    name: name.into(),
                    expected: id()
                }
            );
        }
        assert_eq!(
            check_stamp(&stamp(ID, SHA), &id(), &commit(), "Leanmacs.dmg")
                .expect_err("fixed name")
                .to_string(),
            "the image is named Leanmacs.dmg, not Leanmacs-20010203040506.dmg: it is not build 20010203040506"
        );
    }

    fn inputs() -> Inputs<'static> {
        Inputs {
            image: Path::new(IMAGE),
            size: 123_456,
            mount_point: Path::new(MOUNT),
            out: Path::new("/w/target/nightly"),
        }
    }

    #[test]
    fn prepare_checks_the_stamp_then_sums_and_copies_the_image() {
        let mut process = mounted(ID, SHA, &[]);
        let prepared =
            prepare(&mut process, &inputs(), &id(), &commit(), &leanmacs()).expect("prepared");
        let mut expected = stamp_runs();
        expected.extend([
            format!("shasum -a 256 {IMAGE}"),
            format!("cp {IMAGE} /w/target/nightly/Leanmacs-20010203040506.dmg"),
            format!("cp {IMAGE} /w/target/nightly/Leanmacs.dmg"),
        ]);
        assert_eq!(lines(&process.runs), expected);
        assert_eq!(prepared.build, build());
        assert_eq!(prepared.build_json, build_json(&build()));
        assert_eq!(prepared.sha256, sha256_line(&build()));
        assert_eq!(prepared.notes, notes(&build(), &leanmacs()));
        let names: Vec<&str> = prepared.texts().iter().map(|(n, _)| *n).collect();
        assert_eq!(names, ["build.json", "Leanmacs.dmg.sha256", "notes.md"]);
    }

    #[test]
    fn prepare_copies_nothing_when_the_stamp_is_another_commit() {
        let mut process = mounted(ID, "fedcba9876543210fedcba9876543210fedcba98", &[]);
        let error =
            prepare(&mut process, &inputs(), &id(), &commit(), &leanmacs()).expect_err("refused");
        assert!(
            matches!(error, PrepareError::Stamp(StampError::Commit { .. })),
            "{error:?}"
        );
        assert_eq!(lines(&process.runs), stamp_runs());
    }

    #[test]
    fn prepare_refuses_an_image_named_for_another_build_after_detaching() {
        let mut process = mounted(ID, SHA, &[]);
        let image = Path::new("/w/dist/Leanmacs-20010203040507.dmg");
        let error = prepare(
            &mut process,
            &Inputs { image, ..inputs() },
            &id(),
            &commit(),
            &leanmacs(),
        )
        .expect_err("refused");
        assert!(
            matches!(error, PrepareError::Stamp(StampError::FileName { .. })),
            "{error:?}"
        );
        assert_eq!(
            process.runs.last().map(ToString::to_string),
            Some(format!("hdiutil detach {MOUNT}"))
        );
    }

    #[test]
    fn prepare_stops_when_a_copy_fails() {
        let mut process = mounted(ID, SHA, &["cp "]);
        let error =
            prepare(&mut process, &inputs(), &id(), &commit(), &leanmacs()).expect_err("cp fails");
        assert!(
            matches!(&error, PrepareError::Run { command, .. } if command.starts_with("cp ")),
            "{error:?}"
        );
        assert_eq!(
            process.runs.last().map(|i| i.program.clone()),
            Some("cp".into())
        );
        assert_eq!(process.runs.iter().filter(|i| i.program == "cp").count(), 1);
    }

    #[test]
    fn read_build_reads_back_what_prepare_wrote() {
        let b = build();
        assert_eq!(
            read_build(&build_json(&b), &sha256_line(&b), b.size, &id(), &commit()),
            Ok(b)
        );
    }

    #[test]
    fn read_build_refuses_a_mismatched_size_id_commit_or_checksum() {
        let b = build();
        let (json, line) = (build_json(&b), sha256_line(&b));
        let other_id = BuildId::parse("20010203040507").expect("an ID");
        let other_commit =
            Commit::parse("fedcba9876543210fedcba9876543210fedcba98").expect("a commit");
        let other_line = format!("{}  Leanmacs.dmg\n", "f".repeat(64));
        for (json_text, sha_text, size, id, commit) in [
            (&json, &line, b.size + 1, id(), commit()),
            (&json, &line, b.size, other_id, commit()),
            (&json, &line, b.size, id(), other_commit),
            (&json, &other_line, b.size, id(), commit()),
        ] {
            assert!(
                matches!(
                    read_build(json_text, sha_text, size, &id, &commit),
                    Err(ReadError::BuildJson { .. })
                ),
                "{size} {id} {commit} {sha_text}"
            );
        }
    }

    #[test]
    fn read_build_refuses_a_checksum_file_it_did_not_write() {
        let json = build_json(&build());
        for bad in [
            String::new(),
            format!("{HEX}  Leanmacs.dmg"),
            format!("{HEX} Leanmacs.dmg\n"),
            format!("{HEX}  other.dmg\n"),
            "nothex  Leanmacs.dmg\n".to_owned(),
        ] {
            assert_eq!(
                read_build(&json, &bad, 123_456, &id(), &commit()),
                Err(ReadError::Sha256File(bad.clone())),
                "{bad:?}"
            );
        }
    }

    fn copies(ids: &[&str]) -> Vec<String> {
        ids.iter().map(|i| format!("Leanmacs-{i}.dmg")).collect()
    }

    #[test]
    fn prune_keeps_the_newest_copies_counting_the_current_one() {
        let ids: Vec<String> = (10..22).map(|d| format!("200101{d}000000")).collect();
        let ids: Vec<&str> = ids.iter().map(String::as_str).collect();
        // Twelve old copies, oldest first, and the current build newer
        // than all: keep the current one and the newest nine.
        let mut existing = copies(&ids);
        existing.extend([
            FIXED.into(),
            SHA256.into(),
            BUILD_JSON.into(),
            "other.zip".into(),
        ]);
        existing.reverse();
        let current = BuildId::parse("20010301000000").expect("an ID");
        assert_eq!(prune(&existing, &current, 10), copies(&ids[..3]));
    }

    #[test]
    fn prune_never_deletes_the_current_copy_or_the_fixed_names() {
        let existing = copies(&["20010101000000", "20010102000000", "20010103000000"]);
        let current = BuildId::parse("20010101000000").expect("an ID");
        assert_eq!(prune(&existing, &current, 1), copies(&["20010102000000"]));
        assert_eq!(prune(&existing, &current, 10), Vec::<String>::new());
        assert_eq!(
            prune(&[FIXED.into(), SHA256.into(), BUILD_JSON.into()], &id(), 0),
            Vec::<String>::new()
        );
    }

    const DIR: &str = "/w/target/nightly";

    /// A process for `publish`: `gh release list` prints `tags`, `gh
    /// release view` prints `assets`, `shasum` prints `digest`, and the
    /// first invocation whose line starts with `failing` fails.
    fn github(
        tags: &'static str,
        assets: &'static str,
        digest: &'static str,
        failing: Option<&'static str>,
    ) -> RecordingProcess<impl FnMut(&Invocation) -> Result<Vec<u8>, RunError>> {
        RecordingProcess::new(move |i: &Invocation| {
            let line = i.to_string();
            if failing.is_some_and(|f| line.starts_with(f)) {
                return Err(RunError::Failed(Some(1)));
            }
            Ok(if line.starts_with("gh release list") {
                tags.into()
            } else if line.starts_with("gh release view") {
                assets.into()
            } else if i.program == "shasum" {
                format!("{digest}  x\n").into_bytes()
            } else {
                Vec::new()
            })
        })
    }

    const LIST: &str =
        "gh release list --limit 1000 --json tagName --jq .[].tagName --repo leanmacs/leanmacs";
    const VIEW: &str =
        "gh release view nightly --json assets --jq .assets[].name --repo leanmacs/leanmacs";

    fn sums() -> Vec<String> {
        vec![
            format!("shasum -a 256 {DIR}/Leanmacs-20010203040506.dmg"),
            format!("shasum -a 256 {DIR}/Leanmacs.dmg"),
        ]
    }

    fn uploads_to_prune() -> Vec<String> {
        let upload = |f: &str| {
            format!("gh release upload nightly {DIR}/{f} --clobber --repo leanmacs/leanmacs")
        };
        vec![
            upload("Leanmacs-20010203040506.dmg"),
            upload("Leanmacs.dmg"),
            upload("Leanmacs.dmg.sha256"),
            upload("build.json"),
            format!(
                "gh api --method PATCH repos/leanmacs/leanmacs/git/refs/tags/nightly -f sha={SHA} -F force=true"
            ),
            format!(
                "gh release edit nightly --prerelease --title Leanmacs nightly --notes-file {DIR}/notes.md --repo leanmacs/leanmacs"
            ),
        ]
    }

    fn repo() -> Repo {
        leanmacs().repo
    }

    #[test]
    fn publish_updates_an_existing_nightly_in_order_and_prunes_last() {
        let assets = "Leanmacs.dmg\nLeanmacs.dmg.sha256\nbuild.json\nLeanmacs-20000101000000.dmg\nLeanmacs-20000102000000.dmg\n";
        let mut process = github("v0.1\nnightly\n", assets, HEX, None);
        // With two old copies, under KEEP, nothing is pruned; the next
        // test has more.
        publish(&mut process, &repo(), Path::new(DIR), &build()).expect("published");
        let mut expected = vec![LIST.to_owned(), VIEW.to_owned()];
        expected.extend(sums());
        expected.extend(uploads_to_prune());
        assert_eq!(lines(&process.runs), expected);
        assert!(process.runs[0].captured && process.runs[1].captured);
    }

    #[test]
    fn publish_deletes_what_prune_names_after_everything_else() {
        let assets: String = (1..=12)
            .map(|d| format!("Leanmacs-200001{d:02}000000.dmg\n"))
            .collect();
        let assets: &'static str = Box::leak(assets.into_boxed_str());
        let mut process = github("nightly\n", assets, HEX, None);
        publish(&mut process, &repo(), Path::new(DIR), &build()).expect("published");
        let tail: Vec<String> = lines(&process.runs)[2 + 2 + 6..].to_vec();
        assert_eq!(
            tail,
            ["01", "02", "03"]
                .map(|d| format!("gh release delete-asset nightly Leanmacs-200001{d}000000.dmg --yes --repo leanmacs/leanmacs"))
        );
    }

    #[test]
    fn publish_creates_the_nightly_at_the_commit_on_the_first_run() {
        let mut process = github("v0.1\nnightly-old\n", "", HEX, None);
        publish(&mut process, &repo(), Path::new(DIR), &build()).expect("published");
        let mut expected = vec![LIST.to_owned()];
        expected.extend(sums());
        expected.push(format!(
            "gh release create nightly --prerelease --target {SHA} --title Leanmacs nightly --notes-file {DIR}/notes.md --repo leanmacs/leanmacs"
        ));
        expected.extend(uploads_to_prune());
        assert_eq!(lines(&process.runs), expected);
    }

    #[test]
    fn publish_uploads_nothing_when_an_image_is_not_the_checked_one() {
        let other: &'static str = Box::leak("f".repeat(64).into_boxed_str());
        let mut process = github("nightly\n", "", other, None);
        let error = publish(&mut process, &repo(), Path::new(DIR), &build()).expect_err("refused");
        assert!(matches!(error, PublishError::Hash { .. }), "{error:?}");
        assert!(
            process
                .runs
                .iter()
                .all(|i| !i.to_string().contains("upload"))
        );
        assert!(
            process
                .runs
                .iter()
                .all(|i| !i.to_string().contains("create"))
        );
    }

    #[test]
    fn publish_stops_at_each_step_that_fails() {
        let mut all = vec![LIST.to_owned(), VIEW.to_owned()];
        all.extend(sums());
        all.extend(uploads_to_prune());
        for (at, line) in all.iter().enumerate() {
            let failing: &'static str = Box::leak(line.clone().into_boxed_str());
            let mut process = github("nightly\n", "", HEX, Some(failing));
            let error = publish(&mut process, &repo(), Path::new(DIR), &build()).expect_err(line);
            assert!(
                matches!(&error, PublishError::Run { command, .. } if command == line),
                "{error:?}"
            );
            assert_eq!(
                lines(&process.runs),
                all[..=at].to_vec(),
                "failing at {line}"
            );
        }
    }

    #[test]
    fn a_failed_upload_moves_no_tag() {
        let mut process = github(
            "nightly\n",
            "",
            HEX,
            Some("gh release upload nightly /w/target/nightly/Leanmacs.dmg "),
        );
        assert!(publish(&mut process, &repo(), Path::new(DIR), &build()).is_err());
        assert!(
            process
                .runs
                .iter()
                .all(|i| !i.to_string().starts_with("gh api"))
        );
    }
}
