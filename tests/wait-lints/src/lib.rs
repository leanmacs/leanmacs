//! Every banned wait that a crate other than its owner can call, once each:
//! the wait bans of the root `clippy.toml` (`Cargo.toml` says how the gate
//! runs it). Each call is under an `#[expect(clippy::disallowed_methods)]`
//! of its own that names the one path it shows, so clippy passes over this
//! crate only while every one of them is refused: a ban that no longer
//! bites leaves its expectation unfulfilled, which `-D warnings` fails.
//! No expectation covers two banned calls, so none is fulfilled by a call
//! other than the one it names. A wait ban added to the root `clippy.toml`
//! gets its call here (.agents/rules/structure.md, "Clippy's bans"), and so
//! does an `allow-invalid` ban that no crate of the workspace calls at an
//! `#[expect]` of its own ([`unreached`]). It type-checks and never runs.

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
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `std::thread::sleep` bites"
    )]
    thread::sleep(Duration::ZERO);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `std::thread::sleep_ms` bites"
    )]
    thread::sleep_ms(0);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `std::thread::park_timeout` bites"
    )]
    thread::park_timeout(Duration::ZERO);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `std::thread::park_timeout_ms` bites"
    )]
    thread::park_timeout_ms(0);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `std::thread::yield_now` bites"
    )]
    thread::yield_now();
    let (_sender, receiver) = mpsc::channel::<()>();
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `std::sync::mpsc::Receiver::recv_timeout` bites"
    )]
    let _ = receiver.recv_timeout(Duration::ZERO);
    let (lock, condvar) = (Mutex::new(()), Condvar::new());
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `std::sync::Condvar::wait_timeout` bites"
    )]
    let _ = condvar.wait_timeout(lock.lock().unwrap(), Duration::ZERO);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `std::sync::Condvar::wait_timeout_ms` bites"
    )]
    let _ = condvar.wait_timeout_ms(lock.lock().unwrap(), 0);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `std::sync::Condvar::wait_timeout_while` bites"
    )]
    let _ = condvar.wait_timeout_while(lock.lock().unwrap(), Duration::ZERO, |()| false);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `std::thread::JoinHandle::is_finished` bites"
    )]
    let _ = thread::spawn(|| {}).is_finished();
    let mut child = command().spawn().unwrap();
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `std::process::Child::try_wait` bites"
    )]
    let _ = child.try_wait();
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `std::time::Instant::now` bites"
    )]
    let _ = Instant::now();
}

/// A command to start, for the poll on its child above. Starting one is
/// banned too (`std::process::Command::new`), so it is made here, apart,
/// where its own expectation cannot be fulfilled by the poll.
#[expect(
    clippy::disallowed_methods,
    reason = "a child for `Child::try_wait` to poll: starting one is banned too"
)]
fn command() -> Command {
    Command::new("true")
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
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `editor_service::queue::Queue::await_waiting` bites"
    )]
    let _ = queue.await_waiting(1, GUARD);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `editor_service::service::RecordingCompleter::wait_for` bites"
    )]
    let _ = completer.wait_for(1, GUARD);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `editor_platform::scripted::ScriptedPlatform::wait_parked` bites"
    )]
    let _ = scripted.wait_parked(GUARD);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `editor_process::service::Service::wait_held` bites"
    )]
    let _ = processes.wait_held(1, GUARD);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `editor_platform_winit::probe::await_requests_handled` bites"
    )]
    let _ = editor_platform_winit::probe::await_requests_handled(winit, GUARD);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `editor_render::render_loop::RenderHandle::wait_resting` bites"
    )]
    let _ = render.wait_resting(GUARD);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `editor_syntax::session::Session::wait_for` bites"
    )]
    let _ = session.wait_for(revision, GUARD);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `editor_syntax::session::Session::wait_exact` bites"
    )]
    let _ = session.wait_exact(revision, GUARD);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `editor_grep::service::Service::until_held_back` bites"
    )]
    let _ = grep.until_held_back(1, GUARD);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `editor_ffi::syntax::Syntaxes::settle` bites"
    )]
    let _ = syntaxes.settle(snapshot, GUARD);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `editor_ffi::syntax::Syntaxes::settle_exact` bites"
    )]
    let _ = syntaxes.settle_exact(snapshot, GUARD);
}

/// Each entry point of the outside world that the root `clippy.toml` bans
/// with `allow-invalid` and no crate of the workspace calls, once: with no
/// site under an `#[expect]` anywhere else, a path among them that stopped
/// resolving would ban nothing and fail nothing. Every other
/// `allow-invalid` path has such a site.
pub fn unreached(collection: &mut parley::fontique::Collection) {
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `parley::FontContext::new` bites"
    )]
    let _ = parley::FontContext::new();
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `fontique::Collection::load_system_fonts` bites"
    )]
    collection.load_system_fonts();
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `fontique::Collection::load_fonts_from_paths` bites"
    )]
    collection.load_fonts_from_paths(Vec::<std::path::PathBuf>::new());
}

/// Each C function Lean calls to wait, once, its `bound_ms` made from the
/// guard as a Rust check makes it.
pub fn c_functions(snapshot: &editor_ffi::snapshot::Snapshot) {
    let bound_ms = GUARD.as_millis();
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `editor_ffi::events::editor_ffi_events_await_waiting` bites"
    )]
    let _ = editor_ffi::events::editor_ffi_events_await_waiting(0, 1, bound_ms);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `editor_ffi::events::editor_ffi_events_script_join` bites"
    )]
    let _ = editor_ffi::events::editor_ffi_events_script_join(1, bound_ms);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `editor_ffi::live::editor_ffi_live_await` bites"
    )]
    let _ = editor_ffi::live::editor_ffi_live_await(1, 0, bound_ms);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `editor_ffi::processes::editor_ffi_processes_await_held` bites"
    )]
    let _ = editor_ffi::processes::editor_ffi_processes_await_held(1, bound_ms);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `editor_ffi::window::editor_ffi_window_await_parked` bites"
    )]
    let _ = editor_ffi::window::editor_ffi_window_await_parked(0, bound_ms);
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `editor_ffi::syntax::editor_ffi_syntax_settle` bites"
    )]
    // SAFETY: never run; the snapshot is a live one, borrowed for the call.
    let _ = unsafe { editor_ffi::syntax::editor_ffi_syntax_settle(snapshot, bound_ms) };
    #[expect(
        clippy::disallowed_methods,
        reason = "shows the ban on `editor_ffi::render::editor_ffi_render_await_rest` bites"
    )]
    let _ = editor_ffi::render::editor_ffi_render_await_rest(bound_ms);
}
