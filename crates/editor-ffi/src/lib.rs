//! The C functions the Lean editor binds to.
//!
//! Lean owns the process and is the editor; this crate is the one place in
//! the Rust library that knows so. It is built as a static library, which
//! Lake links into the Lean executables (`lean/lakefile.lean`). Every function
//! here is called by Lean, directly or through the C glue in
//! `lean/ffi/glue.c`. Nothing here calls Lean.
//!
//! The functions are plain C ABI over plain data. Where one needs a Lean
//! object built or taken apart (an `IO` result, a string), the glue does that
//! with `lean.h` and calls the function here with the plain values.
//!
//! # Conventions
//!
//! Every binding follows the rules below. Each rule that can have one has a
//! small real example in this crate, and each names the tests that pin it
//! or says that none does. This is Rust's side of each rule; Lean's side is
//! in the module docs of `lean/Editor/Ffi.lean`.
//!
//! `ffi-test` is the Lean test executable (`lean/FfiTest.lean`). It is
//! linked against this library like the editor, and `mise run ffi-test` runs
//! its checks and its scenarios, all but `overflow`, in the gate. The Rust
//! tests run under `mise run test`.
//!
//! ## Handles
//!
//! A Rust object crosses as an owned pointer from a `new` function. The glue
//! wraps it in a Lean external object, and that object's finaliser is the
//! only caller of the matching `free` function. No function takes or returns
//! an address as a number.
//!
//! Lean shares a value between threads and drops the last reference on
//! whichever thread holds it. A type behind a handle is therefore
//! `Send + Sync`, and its methods take `&self`.
//!
//! An object cannot be used after it is freed, because nothing can name it:
//! it is freed only when no reference to it is left.
//!
//! Examples: [`counter`]; [`document`], the text of the text-storage crate
//! (`editor-text`) behind a lock, which the editor's text interface is
//! bound to; and [`snapshot`], a document's text as it was at one moment,
//! made by a call on a document and not by a `new` function, which needs
//! no lock because it never changes and which outlives its document. A
//! handle may be handed out by more than one function: a document is made
//! from a string or from a snapshot
//! ([`document::editor_ffi_document_from_snapshot`]). The module that owns
//! the handle lists the functions that hand one out, and has one place that
//! counts a handle live.
//! Tests: `a_counter_is_live_from_new_until_free` and
//! `a_document_is_edited_and_read_through_c_and_is_live_from_new_until_free`
//! in `tests/c_api.rs`;
//! `a_snapshot_is_taken_and_read_through_c_and_is_live_from_the_call_that_made_it_until_its_free`
//! in `tests/snapshot.rs`, an integration test of its own because it makes
//! documents and `tests/c_api.rs` counts its process's;
//! `a_document_made_from_a_snapshot_through_c_is_a_live_document_of_its_own`
//! in `tests/document_from_snapshot.rs`, its own for the same reason; the
//! four counter
//! checks of `ffi-test` (`handleChecks`), its check that a document is
//! freed (`documentChecks`) and its checks that a snapshot is freed and
//! outlives its document (`snapshotChecks`).
//!
//! ## Plain data
//!
//! | Kind | Lean to Rust | Rust to Lean |
//! |---|---|---|
//! | String | A pointer and a byte length, borrowed for the call; what is kept is copied (`text::borrow`) | An owned buffer, pointer and length, in the result record; the glue copies it and hands it back with one call to [`text::editor_ffi_text_free`]. Embedded NUL bytes survive |
//! | Enum | A `u8` tag, converted with a checked function that refuses a tag it does not know ([`events::QueueId::from_tag`], [`snapshot::ColumnUnit::from_tag`]) | A `u64` tag in the result record ([`events::EventKind::tag`]) |
//! | Small structure | Its fields, as scalar arguments | One `#[repr(C)]` record filled through an out-pointer in a single call ([`events::RawEvent`]) |
//! | Option | A presence flag and a value | The function returns whether there is a value and fills the record only if so |
//! | Byte range | Two scalars | A record of two `u64`: a start and an end, half-open, in bytes ([`text::ByteRange`]) |
//! | List | *Words*: a buffer of 64-bit numbers, eight bytes each, least significant first, as a pointer and a byte length borrowed for the call. A checked reader takes it apart and refuses a length that is not whole words, a count that runs past the buffer and words left over (the private module `words`) | Words in an owned buffer, pointer and length, in the result record ([`log::RawWords`]); the glue copies it and hands it back with one call to [`text::editor_ffi_text_free`], which frees any buffer the library lent |
//!
//! Prefer a few scalar arguments or one record to many calls. No
//! `extern "C"` function panics: failure is a return value. A function that
//! dereferences a pointer is `unsafe` and says what it requires.
//!
//! Examples: [`text::editor_ffi_text_find`] (an option in, an option of a
//! byte range out), an event (a string, enums and a structure, in both
//! directions), a document (a string in, to `new` and `replace`; a string
//! out, in [`document::RawText`]; a refusal as a `bool`) and a snapshot (a
//! record of three numbers out, in [`snapshot::RawSnapshotInfo`]; an enum
//! in, as the tag of a [`snapshot::ColumnUnit`]; an option of a record out,
//! in [`snapshot::RawPoint`], and an option of a number). Offsets into a
//! text cross as `usize`, and rows and columns as `u64`; a row or a column
//! no `usize` holds is refused, never cut down. A document's transactions
//! and its edit log are the example of lists: a transaction in, as words
//! and one string of everything it inserts
//! ([`transaction::editor_ffi_document_apply`], with its result in
//! [`transaction::RawApplied`]); a patch and a trace out, as words
//! ([`log::editor_ffi_document_changes_since`],
//! [`log::editor_ffi_document_trace`]); and a refusal as a `bool`
//! ([`log::editor_ffi_document_forget`]). A document's markers are words in
//! both directions: a marker in, to
//! [`marker::editor_ffi_document_mark`], with its id in
//! [`marker::RawMarked`], and to [`marker::editor_ffi_document_place`]; a
//! marker out, from [`marker::editor_ffi_document_marker`]; and a selection
//! in and what it covers out, both as words, in
//! [`snapshot::editor_ffi_snapshot_extents`]. A refusal with more than one
//! reason is a status, as a number ([`marker::MarkStatus`]). A document's
//! kept inverses are the example of scalars in and words out with an
//! option inside them: a run of revisions and an origin in, as three
//! numbers, and the revision the inverse produced with the selection it
//! hands back, if there is one, out
//! ([`inverse::editor_ffi_document_apply_inverse`], with its refusals in
//! [`inverse::InverseStatus`]); and a run in and a refusal as a `bool`
//! ([`inverse::editor_ffi_document_drop_inverses`]). In words, a
//! length or an offset the other side cannot hold is sent as the largest it
//! can, which no text accepts, so it too is refused and never cut down.
//! Tests: the unit tests in `text.rs`, `document.rs`, `snapshot.rs`,
//! `words.rs`, `transaction.rs`, `log.rs`, `marker.rs` and `inverse.rs`;
//! the tag tests in `events.rs`;
//! `find_fills_the_range_it_found_and_reports_whether_it_found_one` and the
//! document test in `tests/c_api.rs`; the snapshot test in
//! `tests/snapshot.rs`;
//! `a_transaction_is_applied_and_the_log_is_read_through_c` in
//! `tests/log.rs`,
//! `a_document_is_marked_and_a_selections_extents_are_read_through_c` in
//! `tests/markers.rs` and
//! `the_inverse_of_a_run_is_applied_and_inverses_are_dropped_through_c` in
//! `tests/inverse.rs`, integration tests of their own for the reason
//! `tests/snapshot.rs` is one; the `find` and event checks of `ffi-test`
//! (`dataChecks`), its document checks (`documentChecks`), its snapshot
//! checks (`snapshotChecks`), its transaction checks (`transactionChecks`),
//! its marker checks (`markerChecks`) and its inverse checks
//! (`inverseChecks`).
//!
//! ## The event queues
//!
//! Rust threads push events and Lean pulls them with a blocking call. An
//! event is plain data tagged with its source. The process has two queues:
//! the editor queue, and the completion queue that a dedicated Lean task
//! pulls. A fake event source, [`events::ScriptedSource`], is published for
//! tests. The module docs of [`events`] have the detail.
//!
//! Tests: the unit tests in `events.rs` (ordering, the blocking pull, quit,
//! the scripted source), none of which needs Lean;
//! `the_process_wide_queues_carry_events_until_they_are_quit` in
//! `tests/c_api.rs`; the three queue checks of `ffi-test` (`queueChecks`).
//!
//! ## Services and completions
//!
//! A service is work the library does for a Lean job that takes time: a
//! timer today ([`timers`]), a process or a file later. A job that waits
//! must not hold a thread, so a request to a service is never a blocking
//! call. Every service follows these rules:
//!
//! - **The caller names the request.** `start` takes an id the caller
//!   chose. It returns at once and never blocks, and it returns false, having
//!   started nothing, if it could not start the request.
//! - **One completion for each request.** When the work is done the service
//!   queues one event of the kind [`events::EventKind::Completion`] on the
//!   completion queue, from the library source with the service's id, whose
//!   code is the request's id. A request that was cancelled first gets none.
//! - **`cancel` stops the work.** It takes the id, stops what the request
//!   started, and is safe for an id that is unknown or already done. A
//!   completion that was queued before the cancel still arrives after it,
//!   and the caller ignores a completion for an id it no longer waits for.
//! - **Plain data only, and no call into Lean.** A dedicated Lean task pulls
//!   the completion queue.
//! - **The logic is behind a port with a fake**, and is tested with no Lean.
//!
//! Example: the timer service. Its port is [`timers::Clock`], with
//! [`timers::FakeClock`] published for tests; which wait is due when is the
//! pure [`timers::Schedule`]; and its C functions are
//! [`timers::editor_ffi_timers_now`], [`timers::editor_ffi_timers_start`],
//! [`timers::editor_ffi_timers_cancel`] and, as a readout for tests,
//! [`timers::editor_ffi_timers_pending`].
//!
//! Tests: the unit tests of `timers.rs` (the schedule; the service loop on
//! the fake clock, where a marker wait shows what was not completed, and on
//! the real one); the completion tests of `events.rs`;
//! `the_process_wide_timers_complete_a_wait_on_the_completion_queue_unless_it_is_cancelled`
//! in `tests/timers.rs`, an integration test of its own because the service
//! and the queue are process-wide and `tests/c_api.rs` quits the queues. On
//! the Lean side: the timer checks of `ffi-test` (`timerChecks`), and
//! `contract-test`, which runs the job interface's contract over this
//! service through the job runner and its completion pump.
//!
//! ## The window
//!
//! A window is not a service behind the completion queue: it is run by the
//! main-thread service, and what it reports arrives on the editor queue.
//! [`window`] has the detail. Its rules:
//!
//! - **Running the window is one blocking call.**
//!   [`window::editor_ffi_window_run`] asks the main-thread service to run
//!   the window's loop ([`main_thread::Request::RunWindow`]) and returns
//!   when the window has closed. Call it from Lean's main thread or a
//!   dedicated task, never from the pool. While it runs, the main-thread
//!   service answers nothing else.
//! - **How the window is opened goes in as scalars**, one for each field of
//!   the window port's options. A failure to open comes back as a `bool` and
//!   a reason in a record ([`window::RawRefusal`]).
//! - **What the window reports is events** on the editor queue, from the
//!   window source, of the kinds from
//!   [`events::EventKind::WindowOpened`] on.
//! - **A window's event carries a stamp**: the reading of the process's
//!   input clock when the window reported it. Lean reads the same clock
//!   with [`window::editor_ffi_input_clock_now`].
//! - **Lean closes the window.** A window that is asked to close reports it
//!   and stays open until [`window::editor_ffi_window_close`] is called,
//!   which any thread may do.
//! - **The platform is named by a tag** ([`window::PlatformId`]), checked
//!   like a queue's. The two scripted platforms, the one that reports a
//!   sample and the one that cannot open a window, are reachable for the
//!   Lean test executable, as the scripted event source is.
//!
//! Tests: the unit tests of `window.rs` (the event each input becomes, the
//! stamps, the options, a platform that cannot open), on the port's fake
//! with a clock and a queue of their own; the request's test in
//! `main_thread.rs`;
//! `the_process_wide_window_reports_on_the_editor_queue_until_it_is_closed`
//! in `tests/window.rs`, an integration test of its own because the queue
//! is process-wide and `tests/c_api.rs` quits it.
//!
//! ## Calls go one way
//!
//! Lean calls this library. The library never calls a Lean function and
//! holds no Lean closure: it queues an event and Lean pulls it.
//!
//! No test pins this rule, and the build enforces only part of it; the rest
//! is kept by review.
//!
//! `mise run test` links this crate's tests with no Lean runtime. A test
//! that reaches a function which calls a Lean runtime function therefore
//! fails to link, with that function as an undefined symbol. Seen once by
//! hand, with a function that called `lean_io_mk_world` and a unit test
//! that called it.
//!
//! A function that no test reaches is not caught. The same experiment
//! without the test passed `mise run test`, `mise run lint` and the release
//! build of the archive: the linker drops the unreached function from the
//! test executables, and an archive is not linked at all. The Lean
//! executables were not built with it; they link the Lean runtime, which
//! defines that function.
//!
//! ## An exception from the interpreter ends the process
//!
//! Deep recursion or a missing native symbol in interpreted Lean code makes
//! Lean's interpreter throw a C++ exception, which Lean's own `try`/`catch`
//! does not see. Nothing catches it, here or in the glue, and the process
//! aborts. That is deliberate. The exception skips the compiled Lean frames
//! between the interpreter and whatever would catch it, and they release
//! nothing they hold: references leak, `finally` blocks do not run, locks
//! stay locked. State cannot be cleanly restored after that, so the editor
//! does not carry on. Do not add a guard, and do not add a C++ source to
//! hold one.
//!
//! Because calls go one way, no Rust frame is ever beneath Lean code, so the
//! exception never crosses this crate.
//!
//! Test: `mise run ffi-overflow`, which runs `ffi-test overflow` and
//! requires it to die of SIGABRT once it has entered the recursion. It is
//! run on demand, not by the gate: every abort makes macOS write a crash
//! report on the developer's machine.
//!
//! ## Shutdown
//!
//! [`events::editor_ffi_events_quit`] quits both queues, which makes every
//! pull, parked or later, return a quit event. Lean then exits the process
//! explicitly. Nothing in this crate joins a thread or waits at exit: a
//! service's thread runs until the process ends, and what it queues after
//! the quit is dropped.
//!
//! Tests: the quit tests in `events.rs`; `ffi-test shutdown` and
//! `ffi-test exit-while-blocked`.
//!
//! ## Nothing runs at initialisation
//!
//! A Lean module initialiser must not call this library: library objects are
//! created from Lean's `main` or later. The process-wide state here is
//! `const`-initialised statics, so the library needs no start-up call
//! either. A service's thread starts with the first request made of it.
//!
//! No test pins this rule, and the build enforces only part of it; the rest
//! is kept by review.
//!
//! A Lean `initialize` declaration that calls a binding fails
//! `mise run lean`. The `lean` compiler runs such a declaration when it
//! compiles a module that imports the one holding it, in a process where
//! this library's symbols do not exist, and reports "Could not find native
//! implementation of external declaration" for the importing module. Seen
//! once by hand, with an `initialize` in `lean/Editor/Ffi.lean` that called
//! `Counter.live`.
//!
//! A plain Lean constant whose value calls a binding is not caught. It
//! builds, and Lean evaluates it in the module's initialiser when the
//! executable starts, where the symbols exist. Seen once by hand, with a
//! constant defined as `add 2 3`.

pub mod counter;
pub mod document;
pub mod events;
pub mod inverse;
pub mod log;
pub mod main_thread;
pub mod marker;
pub mod snapshot;
pub mod text;
pub mod timers;
pub mod transaction;
pub mod window;
mod words;

/// The sum of `a` and `b`, wrapping on overflow.
///
/// This is the trivial function that shows a call crossing from Lean into
/// the Rust library. It wraps because a panic must not unwind into Lean.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_add(a: u32, b: u32) -> u32 {
    a.wrapping_add(b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_returns_the_sum() {
        assert_eq!(editor_ffi_add(2, 3), 5);
    }

    #[test]
    fn add_wraps_instead_of_overflowing() {
        assert_eq!(editor_ffi_add(u32::MAX, 2), 1);
    }
}
