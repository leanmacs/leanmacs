//! `launch-probe`: the helper of the launcher's tests, never shipped.
//!
//! - **As an editor** (any command line but `--contract …`), it is what the
//!   launcher starts in `tests/fallback.rs` and `tests/identity.rs`. It
//!   prints `probe pid <pid>`, an `argument <arg>` line for each argument
//!   (escaped as the hand-over record's values are), `CFProcessPath <value>`
//!   or `CFProcessPath unset`, and the main bundle's line
//!   (`editor_launch_std::identity::line`), then removes the record named
//!   by `--handed-over <record>`, as an editor does at the hand-shake.
//! - **As the contract's helper** (`--contract …`), it does what
//!   `editor_launch::contract`'s module docs say, through the real
//!   adapters.
//! - **As the variable contract's helper** (`--contract-var`), it runs
//!   `editor_launch::contract::check_var` on `StdPlatform` in the
//!   environment it was started with, and prints the name of each
//!   property that fails, one per line.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use editor_launch::contract::{REPORTED, Report, check_var, refused, report};
use editor_launch::handover::escape;
use editor_launch::launch::CF_PROCESS_PATH;
use editor_launch::ports::{Exec, Files, Invocation};
use editor_launch_std::{StdExec, StdFiles, StdPlatform, identity};

fn strings(args: &[OsString]) -> Vec<String> {
    args.iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect()
}

#[expect(
    clippy::disallowed_methods,
    reason = "the tests' probe reports this real process's own pid and environment, which is what the contract checks"
)]
fn probe(args: &[OsString]) -> ExitCode {
    println!("probe pid {}", std::process::id());
    for a in strings(args) {
        println!("argument {}", escape(&a));
    }
    match std::env::var_os(CF_PROCESS_PATH) {
        Some(v) => println!("{CF_PROCESS_PATH} {}", v.to_string_lossy()),
        None => println!("{CF_PROCESS_PATH} unset"),
    }
    println!("{}", identity::line(identity::main_bundle().as_ref()));
    if let Some(i) = args.iter().position(|a| a == "--handed-over")
        && let Some(record) = args.get(i + 1)
        && let Err(e) = StdFiles.remove(Path::new(record))
    {
        eprintln!(
            "launch-probe: could not remove {}: {e}",
            record.to_string_lossy()
        );
        return ExitCode::from(1);
    }
    ExitCode::SUCCESS
}

#[expect(
    clippy::disallowed_methods,
    reason = "the tests' probe reports this real process's own pid and environment, which is what the contract checks"
)]
fn this_report(args: &[OsString]) -> Report {
    Report {
        pid: std::process::id(),
        ppid: std::os::unix::process::parent_id(),
        arguments: strings(args),
        environment: REPORTED
            .iter()
            .map(|name| {
                (
                    (*name).to_owned(),
                    std::env::var_os(name).map(|v| v.to_string_lossy().into_owned()),
                )
            })
            .collect(),
        refused: None,
    }
}

fn contract(args: &[OsString]) -> ExitCode {
    let mut report_path: Option<PathBuf> = None;
    let mut sleep_ms = 0u64;
    let mut exec: Option<Invocation> = None;
    let mut set = Vec::new();
    let mut unset = Vec::new();
    let mut rest = args.iter();
    while let Some(word) = rest.next() {
        match word.to_str() {
            Some("--report") => {
                if let Some(path) = rest.next() {
                    report_path = Some(PathBuf::from(path));
                }
            }
            Some("--sleep") => {
                sleep_ms = rest
                    .next()
                    .and_then(|v| v.to_str())
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0);
            }
            Some("--set") => {
                if let Some((name, value)) = rest
                    .next()
                    .and_then(|v| v.to_str())
                    .and_then(|v| v.split_once('='))
                {
                    set.push((OsString::from(name), OsString::from(value)));
                }
            }
            Some("--unset") => unset.extend(rest.next().cloned()),
            Some("--exec") => {
                if let Some(program) = rest.next() {
                    exec = Some(Invocation::new(program).args(rest.by_ref().cloned()));
                }
            }
            _ => {}
        }
    }
    let Some(report_path) = report_path else {
        eprintln!("launch-probe: --contract needs --report <file>");
        return ExitCode::from(2);
    };
    let mut files = StdFiles;
    let mut ours = this_report(args);
    if files
        .write_atomic(&report_path, report(&ours).as_bytes())
        .is_err()
    {
        return ExitCode::from(1);
    }
    if let Some(mut invocation) = exec {
        invocation.set = set;
        invocation.unset = unset;
        let refusal = StdExec.exec(&invocation);
        ours.refused = Some(refused(&refusal));
        let mut name = report_path.file_name().unwrap_or_default().to_owned();
        name.push(".refused");
        if files
            .write_atomic(&report_path.with_file_name(name), report(&ours).as_bytes())
            .is_err()
        {
            return ExitCode::from(1);
        }
    }
    // real time under test: `--sleep`, the child's lifetime, which the
    // contract starts on purpose and ends by kill or exit.
    #[expect(
        clippy::disallowed_methods,
        reason = "real time under test: the probe's `--sleep`, the child's lifetime, which the launcher's contract starts on purpose and ends by kill or exit"
    )]
    std::thread::sleep(std::time::Duration::from_millis(sleep_ms));
    ExitCode::SUCCESS
}

/// The variable property on this process's own environment: prints the
/// name of each property that fails, one per line.
fn contract_var() -> ExitCode {
    let platform = match StdPlatform::new() {
        Ok(platform) => platform,
        Err(e) => {
            eprintln!("launch-probe: cannot tell where this probe is: {e}");
            return ExitCode::from(1);
        }
    };
    for failed in check_var(&platform) {
        println!("{failed}");
    }
    ExitCode::SUCCESS
}

#[expect(
    clippy::disallowed_methods,
    reason = "the probe binary's entry reads its own command line"
)]
fn main() -> ExitCode {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    match args.first().and_then(|a| a.to_str()) {
        Some("--contract") => contract(&args),
        Some("--contract-var") => contract_var(),
        _ => probe(&args),
    }
}
