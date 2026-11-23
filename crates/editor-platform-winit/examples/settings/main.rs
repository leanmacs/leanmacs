//! The window's settings read back from AppKit (`mise run window-layer`,
//! its first half; macOS only).
//!
//! It runs [`WinitPlatform`] with the default options (the themed title
//! bar). Once the window has opened it asks for the paper `#2e3440` as its
//! background (`Request::Background`) and the dark appearance, waits until
//! the window's loop has carried both requests out on the main thread
//! (`probe::await_requests_handled`, never a poll), then reads the window
//! on the main thread (the module `appkit`), prints every reading, holds it
//! to what was asked (the module `reading`, whose tests run in the gate)
//! and closes the window. Nothing is drawn and no frame is waited for, so
//! a window the locked screen occludes is read all the same.
//!
//! Its exit status: 0 when nothing missed, 1 when something did, and 2
//! when it is not on macOS or no window could be opened.

#[cfg_attr(
    all(not(target_os = "macos"), not(test)),
    expect(dead_code, reason = "macOS only; its tests run everywhere")
)]
mod reading;

#[cfg(target_os = "macos")]
mod appkit;

use std::process::ExitCode;

#[cfg(target_os = "macos")]
fn main() -> ExitCode {
    macos::run()
}

#[cfg(not(target_os = "macos"))]
fn main() -> ExitCode {
    println!("settings: macOS only");
    ExitCode::from(2)
}

/// The run on macOS: the window, the scenario beside it, and the verdict.
#[cfg(target_os = "macos")]
mod macos {
    use std::process::ExitCode;
    use std::ptr::NonNull;
    use std::sync::Arc;
    use std::sync::mpsc::{self, Receiver};
    use std::thread;
    use std::time::Duration;

    use editor_wait::{self as wait, HangGuard};

    use editor_platform::{
        Appearance, Canvas, Input, NativeWindow, Platform, Request, Rgb, WindowOptions,
    };
    use editor_platform_winit::{WinitPlatform, probe};

    use crate::appkit;
    use crate::reading::{self, Reading};

    /// The paper asked for.
    const PAPER: Rgb = Rgb {
        red: 0x2e,
        green: 0x34,
        blue: 0x40,
    };

    /// hang guard: the window's opening and its saying its view; only a
    /// hang reaches the bound, and the example then says no window opened.
    const OPEN: HangGuard = HangGuard::on(
        "the window's opening and its saying its view",
        Duration::from_secs(20),
    );

    /// hang guard: the loop carrying the two requests out on the main
    /// thread; only a hang reaches the bound, and the example then says so
    /// and reads the window as it is.
    const SHOW: HangGuard = HangGuard::on(
        "the loop carrying the two requests out",
        Duration::from_secs(3),
    );

    /// `main` runs on the process's main thread, and the platform is run
    /// from `main`.
    fn on_main_thread() -> bool {
        true
    }

    /// The platform: one in a process, as winit allows.
    static PLATFORM: WinitPlatform = WinitPlatform::new(on_main_thread);

    /// The window's reading on the main thread, through the address of
    /// winit's view.
    fn read(view: usize) -> Option<Reading> {
        dispatch2::run_on_main(move |_| appkit::read(NonNull::new(view as *mut _)?))
    }

    /// Waits for the window to open and say its view, reads it as it
    /// opened (the control), asks it for the paper and the dark
    /// appearance, waits until the window's loop has carried both requests
    /// out on the main thread (`probe::await_requests_handled`, notified
    /// as the loop counts them, never a poll) and reads it once, on the
    /// main thread, after them: the control, and the reading; `None` when
    /// it did not open.
    #[expect(
        clippy::disallowed_methods,
        reason = "the adapter's settings check reads the window back once the loop has carried the requests out, on the adapter's readout `probe::await_requests_handled`"
    )]
    fn scenario(views: &Receiver<usize>, opened: &Receiver<()>) -> Option<(Reading, Reading)> {
        let view = wait::recv(views, OPEN).ok()?;
        wait::recv(opened, OPEN).ok()?;
        let before = read(view)?;
        PLATFORM.request(Request::Background(PAPER));
        PLATFORM.request(Request::Appearance(Appearance::Dark));
        if !probe::await_requests_handled(&PLATFORM, SHOW) {
            println!("settings: {SHOW}");
        }
        let reading = read(view)?;
        Some((before, reading))
    }

    /// Runs the window and the scenario, and gives the verdict.
    pub fn run() -> ExitCode {
        let (view_sent, views) = mpsc::channel();
        let (opened_sent, opened) = mpsc::channel();
        let drawer = Arc::new(move |canvas: Canvas| {
            if let Canvas::Opened {
                window: Some(NativeWindow::AppKit { view }),
                ..
            } = canvas
            {
                let _ = view_sent.send(view.as_ptr() as usize);
            }
        });
        let report = Arc::new(move |input: Input| {
            if matches!(input, Input::Opened { .. }) {
                let _ = opened_sent.send(());
            }
        });
        let scenario = thread::spawn(move || {
            let reading = scenario(&views, &opened);
            PLATFORM.close();
            reading
        });
        if let Err(cannot) = PLATFORM.run(WindowOptions::default(), report, drawer) {
            println!("settings: no window could be opened: {cannot:?}");
            return ExitCode::from(2);
        }
        let Ok(Some((before, reading))) = scenario.join() else {
            println!("settings: the window did not open and say its view within {OPEN:?}");
            return ExitCode::from(2);
        };
        // The control: the window as it opened, asked nothing, must miss
        // the paper, or the reading cannot see the background.
        for line in reading::lines(&before) {
            println!("settings: as it opened (the control): {line}");
        }
        let sees = reading::misses(&before, PAPER)
            .iter()
            .any(|miss| matches!(miss, reading::Miss::Background { .. }));
        if sees {
            println!("settings: the control misses the paper, as it must");
        } else {
            println!("settings: WITHIN: the reading cannot see the background");
        }
        for line in reading::lines(&reading) {
            println!("settings: {line}");
        }
        let missed = reading::misses(&reading, PAPER);
        for miss in &missed {
            println!("settings: MISS: {miss}");
        }
        if missed.is_empty() && sees {
            println!(
                "settings: the window shows the paper asked, the dark appearance, is opaque, and no layer of ours has a border"
            );
            ExitCode::SUCCESS
        } else {
            ExitCode::FAILURE
        }
    }
}
