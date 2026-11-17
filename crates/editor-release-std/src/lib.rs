//! Release tooling's real adapters: the environment over `std::env`
//! ([`StdEnv`]) and programs over `std::process` ([`StdProcess`]), and the
//! `leanmacs-release` binary (`src/bin/leanmacs-release.rs`) that wires them
//! to `editor-release`'s core.
//!
//! Both adapters are thin: every decision is the core's. `tests/contract.rs`
//! holds [`StdProcess`] to the process port's contract, the one the core's
//! fake passes, and `tests/resolve.rs` runs the core's resolvers through it
//! on a git repository it makes. Only release tooling depends on this
//! crate, and the editor never links it (`deny.toml`).

use std::ffi::OsString;
use std::process::{Command, Stdio};

use editor_release::ports::{Env, Invocation, Process, RunError};

/// The process's own environment.
#[derive(Debug, Clone, Copy, Default)]
pub struct StdEnv;

impl Env for StdEnv {
    fn var(&self, name: &str) -> Option<OsString> {
        std::env::var_os(name)
    }
}

/// Programs run with `std::process`, waited for to their end. Standard
/// input is closed and standard error is the tool's own; standard output is
/// captured when the invocation asks, and the tool's own otherwise.
#[derive(Debug, Clone, Copy, Default)]
pub struct StdProcess;

impl Process for StdProcess {
    fn run(&mut self, invocation: &Invocation) -> Result<Vec<u8>, RunError> {
        let mut command = Command::new(&invocation.program);
        command
            .args(&invocation.args)
            .stdin(Stdio::null())
            .stderr(Stdio::inherit());
        let (status, stdout) = if invocation.captured {
            let output = command
                .stdout(Stdio::piped())
                .output()
                .map_err(|e| RunError::Start(e.to_string()))?;
            (output.status, output.stdout)
        } else {
            let status = command
                .stdout(Stdio::inherit())
                .status()
                .map_err(|e| RunError::Start(e.to_string()))?;
            (status, Vec::new())
        };
        if status.success() {
            Ok(stdout)
        } else {
            Err(RunError::Failed(status.code()))
        }
    }
}
