//! `link-stubs`: writes the link stubs a relink of the editor needs where
//! there is no macOS SDK, from a linked executable's own import table
//! (`editor_release::stubs`, whose module docs say what each stub holds
//! and what is refused).
//!
//! ```text
//! link-stubs <linked executable> <out dir>
//! ```
//!
//! Both paths are made absolute against the working directory. It runs
//! `lipo`, `otool`, `nm` and `vtool`, the command line tools', so on macOS
//! only. A refusal is one line on standard error, `link-stubs: …`, and exit
//! status 1; a command line it does not take, or a host other than macOS,
//! exit status 2.

use std::ffi::OsString;
use std::path::PathBuf;
use std::process::ExitCode;

use editor_release::stubs::{self, Host, Refusal};
use editor_release_std::{StdFiles, StdProcess};

const USAGE: &str = "usage: link-stubs <linked executable> <out dir>";

/// `path` made absolute against the working directory.
fn absolute(path: &OsString) -> Result<PathBuf, String> {
    std::path::absolute(path)
        .map_err(|e| format!("cannot make {} absolute: {e}", path.to_string_lossy()))
}

fn main() -> ExitCode {
    #[expect(
        clippy::disallowed_methods,
        reason = "the binary's entry reads its own command line"
    )]
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    let [executable, out] = args.as_slice() else {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    };
    let host = if cfg!(target_os = "macos") {
        Host::Macos
    } else {
        Host::Other
    };
    let paths = absolute(executable).and_then(|e| Ok((e, absolute(out)?)));
    let (executable, out) = match paths {
        Ok(paths) => paths,
        Err(message) => {
            eprintln!("link-stubs: {message}");
            return ExitCode::FAILURE;
        }
    };
    match stubs::link_stubs(&mut StdProcess, &mut StdFiles, host, &executable, &out) {
        Ok(()) => ExitCode::SUCCESS,
        Err(refusal) => {
            eprintln!("link-stubs: {refusal}");
            if refusal == Refusal::NotMacos {
                ExitCode::from(2)
            } else {
                ExitCode::FAILURE
            }
        }
    }
}
