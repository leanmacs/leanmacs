//! The winit platform held to the window port's contract
//! (`editor_platform::contract`), on a real display.
//!
//! This opens a window, so it is an example and not a test: the gate builds
//! it and never runs it. Two opt-in tasks run it: `mise run linux-window`,
//! under Xvfb in a container, and `mise run window-contract`, on the desktop
//! it is started from. The window opens and closes again in about a second.
//!
//! It prints the verdict on one line, and then each resize the window
//! reported, in order, one line apiece: its size, scale, whether it was in
//! fullscreen, its corner clearance and its top inset (`window-contract:
//! resized 1600x1200 scale 2 fullscreen false corner 16 top 28`). That is
//! how what a real window says of its corners and its title bar is seen.
//! The window opens with the options' default, the themed title bar. Its
//! exit
//! status is the result: 0 when the platform keeps the contract, 1 when it
//! does not, which includes a window that could not be opened.

use std::process::exit;
use std::thread;
use std::time::Duration;

use editor_platform::WindowOptions;
use editor_platform::contract::Check;
use editor_platform_winit::WinitPlatform;

/// How long the platform has to open its window, and then to return once it
/// is asked to close.
const BOUND: Duration = Duration::from_secs(10);

/// How long the open window is left alone before it is asked to close. A
/// loop that an earlier close would end has turned many times by then.
const SETTLE: Duration = Duration::from_millis(500);

/// `main` runs on the process's main thread, and the platform is run from
/// `main`.
fn on_main_thread() -> bool {
    true
}

fn main() {
    let platform = WinitPlatform::new(on_main_thread);
    let check = Check::new(WindowOptions::default(), BOUND).settling_for(SETTLE);

    // The verdict is taken on a second thread, which ends the process with
    // it: a window that ignored the close would keep this thread for good.
    let judge = check.clone();
    thread::spawn(move || {
        let verdict = judge.verdict();
        match &verdict {
            Ok(()) => {
                println!("window-contract: the winit platform keeps the window port's contract");
            }
            Err(violation) => println!("window-contract: FAILED: {violation}"),
        }
        for size in judge.resizes() {
            println!(
                "window-contract: resized {}x{} scale {} fullscreen {} corner {} top {}",
                size.width,
                size.height,
                size.scale,
                size.fullscreen,
                size.corner_clearance,
                size.top_inset
            );
        }
        exit(i32::from(verdict.is_err()));
    });

    check.run(&platform);
    // The run is over and the verdict is on its way.
    loop {
        thread::park();
    }
}
