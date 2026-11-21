//! The main-thread functions, called the way the Lean executable calls them:
//! from a process whose real main thread is handed to the service.
//!
//! This test has no harness (`harness = false` in `Cargo.toml`), because
//! libtest runs every test on a thread it spawns, and these checks need the
//! process's own main thread. `main` below is on it.

use std::process::exit;
use std::thread;
use std::time::Duration;

use editor_ffi::main_thread::{
    editor_ffi_is_main_thread, editor_ffi_main_thread_open, editor_ffi_main_thread_probe,
    editor_ffi_main_thread_serve,
};

/// hang guard: every probe answered and `main` returning, which ends the
/// process before the watchdog wakes; only a hang reaches the bound, and the test then fails as a hang. It is how long the whole test
/// may take: the service loop never returns, so a probe that is never
/// answered would otherwise hang `cargo test`.
const LIMIT: Duration = Duration::from_secs(30);

fn main() {
    thread::spawn(|| {
        thread::sleep(LIMIT);
        eprintln!("main_thread: no result after {LIMIT:?}");
        exit(2);
    });

    assert!(
        editor_ffi_is_main_thread(),
        "`main` runs on the process's main thread"
    );
    assert!(
        !spawned(editor_ffi_is_main_thread),
        "a spawned thread is not the main thread"
    );
    assert!(
        !spawned(editor_ffi_main_thread_probe),
        "before the service opens, a probe is answered on the thread that asks"
    );

    // The order the C entry point uses: open, start the other thread, serve.
    editor_ffi_main_thread_open();
    thread::spawn(|| {
        let on_main_thread = editor_ffi_main_thread_probe();
        if on_main_thread {
            println!("main_thread: ok");
            exit(0);
        }
        eprintln!("main_thread: the probe was not answered on the main thread");
        exit(1);
    });
    editor_ffi_main_thread_serve();
}

/// What `question` answers on a freshly spawned thread.
fn spawned(question: extern "C" fn() -> bool) -> bool {
    thread::spawn(move || question()).join().unwrap()
}
