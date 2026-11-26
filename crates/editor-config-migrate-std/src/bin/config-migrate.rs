//! `config-migrate`: converts a config directory from the old form, `.lean`
//! files in byte order with no header, to `init.lean` and
//! `Config/<Name>.lean` (`editor_config_migrate::migrate`, whose module
//! docs say what moves where and what is refused).
//!
//! ```text
//! config-migrate [<config dir>]
//! ```
//!
//! With no argument it converts `$XDG_CONFIG_HOME/leanmacs`, or
//! `$HOME/.config/leanmacs` (`editor_config_migrate::command`). The
//! directory is made absolute against the working directory, and named in
//! what it prints as the user gave it. It prints what it did, one
//! `config-migrate: …` line each, and exits 0, as it does when there is
//! nothing to convert; a refusal is `config-migrate: …` on standard error
//! and exit status 1, the directory left as it was; a command line it does
//! not take is the usage and exit status 2.

use std::ffi::OsString;
use std::process::ExitCode;

use editor_config_migrate::command::{self, CommandError, NO_HOME, USAGE};
use editor_config_migrate::migrate::{self, Refusal};
use editor_config_migrate_std::StdFiles;

fn main() -> ExitCode {
    #[expect(
        clippy::disallowed_methods,
        reason = "the binary's entry reads its own command line"
    )]
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    #[expect(
        clippy::disallowed_methods,
        reason = "the binary's entry reads the two variables the default config directory comes from, and hands them to the core as data"
    )]
    let (config_home, home) = (
        std::env::var_os("XDG_CONFIG_HOME"),
        std::env::var_os("HOME"),
    );
    let dir = match command::parse(&args, config_home, home) {
        Ok(dir) => dir,
        Err(CommandError::Usage) => {
            eprintln!("{USAGE}");
            return ExitCode::from(2);
        }
        Err(CommandError::NoHome) => {
            eprintln!("config-migrate: {NO_HOME}");
            return ExitCode::FAILURE;
        }
    };
    let shown = dir.display().to_string();
    let outcome = std::path::absolute(&dir)
        .map_err(|_| Refusal::NoDirectory)
        .and_then(|absolute| migrate::convert(&mut StdFiles, &absolute));
    match outcome {
        Ok(outcome) => {
            for line in outcome.lines(&shown) {
                println!("{line}");
            }
            ExitCode::SUCCESS
        }
        Err(refusal) => {
            eprintln!("config-migrate: {}", refusal.message(&shown));
            ExitCode::FAILURE
        }
    }
}
