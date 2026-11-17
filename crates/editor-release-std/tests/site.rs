//! `leanmacs-release site` run as the binary it is, on the fixtures in
//! `tests/site/`: the wiring from a `build.json` on disk and
//! `MACOSX_DEPLOYMENT_TARGET` to an `index.html` on disk. What the page
//! says is `editor_release::site`'s, pinned by its own tests; here the
//! written file must be byte-equal to each case's `index.html`.
//!
//! Each run is a child with its environment given explicitly: the case's
//! minimum in `MACOSX_DEPLOYMENT_TARGET`, and `GITHUB_SERVER_URL` and
//! `GITHUB_REPOSITORY` removed so the links are leanmacs/leanmacs's. The
//! page is written into a temporary directory the test owns; the test's
//! own environment, the working directory and the repository are not
//! touched.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use tempfile::TempDir;

/// `tests/site/` in the workspace this test was built in.
fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/site")
        .canonicalize()
        .expect("tests/site exists")
}

/// The binary run as `site <build_json> <out>`, with `minimum` as
/// `MACOSX_DEPLOYMENT_TARGET`, or with it unset when `None`.
fn site(build_json: &Path, out: &Path, minimum: Option<&str>) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_leanmacs-release"));
    command
        .arg("site")
        .arg(build_json)
        .arg(out)
        .env_remove("GITHUB_SERVER_URL")
        .env_remove("GITHUB_REPOSITORY")
        .env_remove("MACOSX_DEPLOYMENT_TARGET");
    if let Some(minimum) = minimum {
        command.env("MACOSX_DEPLOYMENT_TARGET", minimum);
    }
    command.output().expect("leanmacs-release runs")
}

#[test]
fn site_writes_each_fixture_s_golden_page() {
    for case in ["nightly-26.0", "nightly-27.1"] {
        let dir = fixtures().join(case);
        let minimum = std::fs::read_to_string(dir.join("minimum")).expect("minimum");
        let tmp = TempDir::new().expect("a temporary directory");
        let out = tmp.path().join("site");
        let run = site(&dir.join("build.json"), &out, Some(minimum.trim_end()));
        assert!(run.status.success(), "{case}: {run:?}");
        let index = out.join("index.html");
        assert_eq!(
            String::from_utf8(run.stdout).expect("UTF-8"),
            format!("{}\n", index.display()),
            "{case}"
        );
        assert_eq!(
            std::fs::read_to_string(&index).expect("index.html written"),
            std::fs::read_to_string(dir.join("index.html")).expect("the golden page"),
            "{case}"
        );
    }
}

#[test]
fn site_refuses_an_unset_minimum_and_writes_nothing() {
    let tmp = TempDir::new().expect("a temporary directory");
    let out = tmp.path().join("site");
    let run = site(&fixtures().join("nightly-26.0/build.json"), &out, None);
    assert_eq!(run.status.code(), Some(1), "{run:?}");
    let stderr = String::from_utf8(run.stderr).expect("UTF-8");
    assert!(
        stderr.contains("MACOSX_DEPLOYMENT_TARGET is not set: run it through mise run site"),
        "{stderr}"
    );
    assert!(!out.exists());
}

#[test]
fn site_refuses_a_malformed_build_json_naming_it_and_writes_nothing() {
    let tmp = TempDir::new().expect("a temporary directory");
    let json = tmp.path().join("build.json");
    std::fs::write(&json, "{}\n").expect("written");
    let out = tmp.path().join("site");
    let run = site(&json, &out, Some("26.0"));
    assert_eq!(run.status.code(), Some(1), "{run:?}");
    let stderr = String::from_utf8(run.stderr).expect("UTF-8");
    assert!(stderr.contains(&json.display().to_string()), "{stderr}");
    assert!(
        stderr.contains("build.json has no \"build_id\" line"),
        "{stderr}"
    );
    assert!(!out.exists());
}
