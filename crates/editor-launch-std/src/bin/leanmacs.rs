//! `leanmacs`: the app's launcher, the bundle's `CFBundleExecutable`. It
//! wires the real adapters into `editor_launch::launch::run`, which starts
//! an editor by exec, or into the watcher (`--watch`). Its command line is
//! in `editor_launch::launch`'s docs; `--detach` is the intermediate of a
//! detached start (`editor_launch_std::detach`), which only the launcher
//! itself runs.

use std::ffi::OsString;
use std::process::ExitCode;

use editor_launch::launch;
use editor_launch::ports::{Outcome, World};
use editor_launch_std::{StdClock, StdExec, StdFiles, StdPids, StdPlatform, StdSpawn, detach};

fn main() -> ExitCode {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    if args.first().is_some_and(|a| a == "--detach") {
        return detach(&args[1..]);
    }
    let mut platform = match StdPlatform::new() {
        Ok(platform) => platform,
        Err(e) => {
            eprintln!("leanmacs: cannot tell where this launcher is: {e}");
            return ExitCode::from(1);
        }
    };
    let mut spawn = StdSpawn {
        via: editor_launch::ports::Platform::own_path(&platform),
    };
    let mut world = World {
        files: &mut StdFiles,
        clock: &mut StdClock::default(),
        pids: &mut StdPids,
        spawn: &mut spawn,
        exec: &mut StdExec,
        platform: &mut platform,
    };
    match launch::run(&args, &mut world) {
        Outcome::Exit(status) => ExitCode::from(status),
        // The real exec never answers `Faked`.
        Outcome::Execed => ExitCode::from(1),
    }
}
