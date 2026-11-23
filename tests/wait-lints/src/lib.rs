//! Every call the timed-wait bans refuse, once each: each path of the root
//! `clippy.toml`'s `wait-bans` block (`Cargo.toml` says how the gate runs
//! it). Clippy must refuse each line below under every config of the
//! workspace, and the gate reads the paths it must refuse from the block,
//! so a line that stops being refused is a ban that no longer bites, and a
//! path added to the block with no line here fails the gate too. It
//! type-checks and never runs.

#![allow(deprecated, reason = "the deprecated timed primitives are banned too")]

use std::process::Command;
use std::sync::mpsc;
use std::sync::{Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use editor_wait::HangGuard;

/// A guard for the readouts below, which never run.
const GUARD: HangGuard = HangGuard::on("nothing: this crate never runs", Duration::ZERO);

/// Each of std's timed primitives and polls, once.
pub fn primitives() {
    thread::sleep(Duration::ZERO);
    thread::sleep_ms(0);
    thread::park_timeout(Duration::ZERO);
    thread::park_timeout_ms(0);
    thread::yield_now();
    let (_sender, receiver) = mpsc::channel::<()>();
    let _ = receiver.recv_timeout(Duration::ZERO);
    let (lock, condvar) = (Mutex::new(()), Condvar::new());
    let _ = condvar.wait_timeout(lock.lock().unwrap(), Duration::ZERO);
    let _ = condvar.wait_timeout_ms(lock.lock().unwrap(), 0);
    let _ = condvar.wait_timeout_while(lock.lock().unwrap(), Duration::ZERO, |()| false);
    let _ = thread::spawn(|| {}).is_finished();
    let _ = Command::new("true")
        .spawn()
        .map(|mut child| child.try_wait());
    let _ = Instant::now();
}

/// Each public readout a test waits on, once.
#[expect(clippy::too_many_arguments, reason = "one of each readout's owners")]
pub fn readouts(
    queue: &editor_service::queue::Queue,
    completer: &editor_service::RecordingCompleter,
    scripted: &editor_platform::ScriptedPlatform,
    processes: &editor_process::service::Service<editor_process::fake::FakeProcesses>,
    winit: &editor_platform_winit::WinitPlatform,
    render: &editor_render::render_loop::RenderHandle,
    session: &editor_syntax::Session<editor_syntax::fake::Parens>,
    revision: editor_text::Revision,
    grep: &editor_grep::service::Service<editor_grep::fake::FakeFiles, editor_search::Literal>,
    syntaxes: &editor_ffi::syntax::Syntaxes,
    snapshot: &editor_ffi::snapshot::Snapshot,
) {
    let _ = queue.await_waiting(1, GUARD);
    let _ = completer.wait_for(1, GUARD);
    let _ = scripted.wait_parked(GUARD);
    let _ = processes.wait_held(1, GUARD);
    let _ = editor_platform_winit::probe::await_requests_handled(winit, GUARD);
    let _ = render.wait_resting(GUARD);
    let _ = session.wait_for(revision, GUARD);
    let _ = session.wait_exact(revision, GUARD);
    let _ = grep.until_held_back(1, GUARD);
    let _ = syntaxes.settle(snapshot, GUARD);
    let _ = syntaxes.settle_exact(snapshot, GUARD);
}

/// Each C function Lean calls to wait, once, its `bound_ms` made from the
/// guard as a Rust check makes it.
pub fn c_functions(snapshot: &editor_ffi::snapshot::Snapshot) {
    let bound_ms = GUARD.as_millis();
    let _ = editor_ffi::events::editor_ffi_events_await_waiting(0, 1, bound_ms);
    let _ = editor_ffi::events::editor_ffi_events_script_join(1, bound_ms);
    let _ = editor_ffi::live::editor_ffi_live_await(1, 0, bound_ms);
    let _ = editor_ffi::processes::editor_ffi_processes_await_held(1, bound_ms);
    let _ = editor_ffi::window::editor_ffi_window_await_parked(0, bound_ms);
    // SAFETY: never run; the snapshot is a live one, borrowed for the call.
    let _ = unsafe { editor_ffi::syntax::editor_ffi_syntax_settle(snapshot, bound_ms) };
    let _ = editor_ffi::render::editor_ffi_render_await_rest(bound_ms);
}
