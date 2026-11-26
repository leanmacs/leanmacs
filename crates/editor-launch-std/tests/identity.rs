//! CoreFoundation's main bundle in a process the launcher started, on
//! macOS: the launcher's `CFProcessPath` makes the app the main bundle of
//! an editor exec'd from inside the bundle and from outside it, in the same
//! process (`docs/design/lean-runtime.md`, "The app's identity across an
//! exec"). The bundle is a fake one in a temporary directory, with
//! `launch-probe` as its editor.

#![cfg(target_os = "macos")]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use editor_launch::handover::{Handover, encode};

const IDENTIFIER: &str = "org.leanmacs.launch-test";

struct Fixture {
    _dir: tempfile::TempDir,
    root: PathBuf,
    bundle: PathBuf,
}

impl Fixture {
    #[expect(
        clippy::disallowed_methods,
        reason = "runs the real launcher from outside a bundle, with the bundle and its records in a temporary directory the test owns"
    )]
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        // The temporary directory is under a symbolic link (/var), and
        // CoreFoundation answers the resolved path.
        let root = fs::canonicalize(dir.path()).unwrap();
        let bundle = root.join("Fake.app");
        let macos = bundle.join("Contents/MacOS");
        fs::create_dir_all(&macos).unwrap();
        fs::write(
            bundle.join("Contents/Info.plist"),
            format!(
                r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>{IDENTIFIER}</string>
  <key>CFBundleExecutable</key><string>leanmacs</string>
  <key>CFBundleName</key><string>Fake</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
"#
            ),
        )
        .unwrap();
        fs::copy(env!("CARGO_BIN_EXE_leanmacs"), macos.join("leanmacs")).unwrap();
        fs::copy(env!("CARGO_BIN_EXE_launch-probe"), macos.join("editor")).unwrap();
        fs::create_dir(root.join("elsewhere")).unwrap();
        fs::copy(
            env!("CARGO_BIN_EXE_launch-probe"),
            root.join("elsewhere/editor"),
        )
        .unwrap();
        Self {
            _dir: dir,
            root,
            bundle,
        }
    }

    fn launcher(&self) -> PathBuf {
        self.bundle.join("Contents/MacOS/leanmacs")
    }
}

/// Runs `program` and answers its standard output, with its pid.
#[expect(
    clippy::disallowed_methods,
    reason = "runs the real launcher from outside a bundle, with the bundle and its records in a temporary directory the test owns"
)]
fn run(program: &Path, args: &[&Path]) -> (String, u32) {
    let child = Command::new(program)
        .args(args)
        .env_remove("CFProcessPath")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let pid = child.id();
    let output = child.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    (String::from_utf8_lossy(&output.stdout).into_owned(), pid)
}

fn bundle_line(out: &str) -> &str {
    out.lines().find(|l| l.starts_with("bundle ")).unwrap()
}

#[test]
fn a_cold_start_from_the_bundles_launcher_runs_the_bundles_editor_as_the_app() {
    let fixture = Fixture::new();
    let (out, _) = run(&fixture.launcher(), &[]);
    assert_eq!(
        bundle_line(&out),
        format!(
            "bundle {} identifier {IDENTIFIER}",
            fixture.bundle.display()
        )
    );
    assert!(out.contains(&format!("CFProcessPath {}", fixture.launcher().display())));
}

#[test]
#[expect(
    clippy::disallowed_methods,
    reason = "runs the real launcher from outside a bundle, with the bundle and its records in a temporary directory the test owns"
)]
fn an_editor_outside_the_bundle_handed_over_to_is_the_app_in_the_launchers_process() {
    let fixture = Fixture::new();
    let elsewhere = fixture.root.join("elsewhere/editor");
    let record = fixture.root.join("handover");
    let handover = Handover {
        session: Some(fixture.root.join("session-1.json")),
        shipped: fixture.bundle.join("Contents/MacOS/editor"),
        candidates: vec![elsewhere.clone()],
        arguments: Vec::new(),
        failed: Vec::new(),
    };
    fs::write(&record, encode(&handover)).unwrap();
    let (out, launcher_pid) = run(&fixture.launcher(), &[Path::new("--handover"), &record]);
    assert_eq!(
        bundle_line(&out),
        format!(
            "bundle {} identifier {IDENTIFIER}",
            fixture.bundle.display()
        )
    );
    assert_eq!(
        out.lines().next(),
        Some(format!("probe pid {launcher_pid}").as_str())
    );
    assert!(!record.exists());

    let (direct, _) = run(&elsewhere, &[]);
    assert_ne!(
        bundle_line(&direct),
        format!(
            "bundle {} identifier {IDENTIFIER}",
            fixture.bundle.display()
        )
    );
    assert!(
        bundle_line(&direct).ends_with(" identifier none"),
        "{direct}"
    );
}

#[test]
fn an_explicit_default_outside_the_bundle_is_the_app_too() {
    let fixture = Fixture::new();
    let elsewhere = fixture.root.join("elsewhere/editor");
    let (out, _) = run(
        &fixture.launcher(),
        &[
            Path::new("--default"),
            &elsewhere,
            Path::new("--"),
            Path::new("--probe"),
        ],
    );
    assert_eq!(
        bundle_line(&out),
        format!(
            "bundle {} identifier {IDENTIFIER}",
            fixture.bundle.display()
        )
    );
    assert!(out.contains(&format!("argument {}", elsewhere.display())));
}
