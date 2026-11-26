//! `stage-bundle`: lays a directory out as the app bundle will be
//! (`editor_release::bundle`, whose module docs say what each form copies
//! where and what is refused).
//!
//! ```text
//! stage-bundle [--launcher <file>] <bundle dir> <executable> <sysroot> <shipped list>
//! stage-bundle (--roots <root>,... | --closure <file>) [--launcher <file>] \
//!   <bundle dir> <executable> <sysroot> <package olean dirs> <kind>...
//! ```
//!
//! Every path is made absolute against the working directory. On macOS the
//! shipped form writes the link stubs too, running `lipo`, `otool`, `nm`
//! and `vtool`. A refusal is one line on standard error, `stage-bundle: …`,
//! and exit status 1; a command line it does not take is the usage, exit
//! status 2.

use std::ffi::OsString;
use std::process::ExitCode;

use editor_release::bundle::{self, Command, Host, USAGE};
use editor_release_std::{StdFiles, StdProcess};

fn main() -> ExitCode {
    #[expect(
        clippy::disallowed_methods,
        reason = "the binary's entry reads its own command line"
    )]
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    let Ok(command) = Command::parse(&args) else {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    };
    let command = match command.resolved(|path| {
        std::path::absolute(path)
            .map_err(|e| format!("cannot make {} absolute: {e}", path.display()))
    }) {
        Ok(command) => command,
        Err(message) => {
            eprintln!("stage-bundle: {message}");
            return ExitCode::FAILURE;
        }
    };
    let host = if cfg!(target_os = "macos") {
        Host::Macos
    } else {
        Host::Other
    };
    match bundle::stage(&command, host, &mut StdFiles, &mut StdProcess) {
        Ok(()) => ExitCode::SUCCESS,
        Err(refusal) => {
            eprintln!("stage-bundle: {refusal}");
            ExitCode::FAILURE
        }
    }
}
