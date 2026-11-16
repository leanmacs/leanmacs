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
//! counts a handle live. [`display`] is a handle over a `Mutex` because its
//! layout is a cache its queries fill: the layout of `editor-layout` over
//! that crate's fake shaper, asked about a snapshot handle.
//! Tests: `a_counter_is_live_from_new_until_free` and
//! `a_document_is_edited_and_read_through_c_and_is_live_from_new_until_free`
//! in `tests/c_api.rs`;
//! `a_snapshot_is_taken_and_read_through_c_and_is_live_from_the_call_that_made_it_until_its_free`
//! in `tests/snapshot.rs`, an integration test of its own because it makes
//! documents and `tests/c_api.rs` counts its process's;
//! `a_document_made_from_a_snapshot_through_c_is_a_live_document_of_its_own`
//! in `tests/document_from_snapshot.rs`, its own for the same reason;
//! `a_display_is_live_from_new_until_free_and_answers_the_queries_as_layout_does`
//! in `tests/display.rs`, its own because it counts its process's displays;
//! the
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
//! | Enum | A `u8` tag, converted with a checked function that refuses a tag it does not know ([`events::QueueId::from_tag`], [`snapshot::ColumnUnit::from_tag`], [`motion::motion_of`]) | A `u64` tag in the result record ([`events::EventKind::tag`]) |
//! | Small structure | Its fields, as scalar arguments | One `#[repr(C)]` record filled through an out-pointer in a single call ([`events::RawEvent`]) |
//! | Option | A presence flag and a value | The function returns whether there is a value and fills the record only if so |
//! | Byte range | Two scalars | A record of two `u64`: a start and an end, half-open, in bytes ([`text::ByteRange`]) |
//! | List | *Words*: a buffer of 64-bit numbers, eight bytes each, least significant first, as a pointer and a byte length borrowed for the call. A checked reader takes it apart and refuses a length that is not whole words, a count that runs past the buffer and words left over (the private module `words`) | Words in an owned buffer, pointer and length, in the result record ([`log::RawWords`]); the glue copies it and hands it back with one call to [`text::editor_ffi_text_free`], which frees any buffer the library lent |
//! | List of handles | A C array of handle pointers and its count, borrowed for the call, which the glue builds from a Lean `Array` of handles; words name a handle by its index in it ([`display::editor_ffi_display_publish`]) | None yet |
//! | List of strings | Words, the count and then the byte length of each string, and one string of all of them end to end, both borrowed for the call. Lengths that do not add up to the string, and one that ends inside a character, are refused with the words that cannot be read ([`fuzzy::editor_ffi_fuzzy_rank`]) | None yet |
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
//! in [`snapshot::RawPoint`], and an option of a number; an enum with
//! values in, as the tag of a motion and the two numbers the motions by
//! rows take ([`motion::motion_of`],
//! [`snapshot::editor_ffi_snapshot_motion`]); and an option of a string
//! out, from [`snapshot::editor_ffi_snapshot_row`] and
//! [`snapshot::editor_ffi_snapshot_slice`]). Offsets into a
//! text cross as `usize`, and rows and columns as `u64`; a row or a column
//! no `usize` holds is refused, never cut down, but for the count and the
//! column of a motion by rows, which stops where the text does and so
//! reads one as the largest. A document's transactions
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
//! reason is a status, as a number ([`marker::MarkStatus`]). A
//! published scene is the example of a list of handles: words, one string
//! of every text it holds, and the snapshot handles its views show, which
//! the words name by index ([`display::editor_ffi_display_publish`], laid
//! out in [`display::WireScene`]); it comes back as the same words and
//! string ([`display::editor_ffi_display_scene`]). The definitions of the
//! faces the scene names are in the same words and the same string, after
//! the views, behind a presence: absent is "as last published", so a
//! scene and its faces cross in one call and a publish costs the faces
//! only when they changed. A document's
//! kept inverses are the example of scalars in and words out with an
//! option inside them: a run of revisions and an origin in, as three
//! numbers, and the revision the inverse produced with the selection it
//! hands back, if there is one, out
//! ([`inverse::editor_ffi_document_apply_inverse`], with its refusals in
//! [`inverse::InverseStatus`]); and a run in and a refusal as a `bool`
//! ([`inverse::editor_ffi_document_drop_inverses`]). Fuzzy ranking is the
//! example of a list of strings, and of a call that keeps nothing: a
//! pattern and candidates in, and the indices of the candidates the
//! pattern matches out, best first, as words
//! ([`fuzzy::editor_ffi_fuzzy_rank`], with its one refusal in
//! [`fuzzy::FuzzyStatus`]). In words, a
//! length or an offset the other side cannot hold is sent as the largest it
//! can, which no text accepts, so it too is refused and never cut down.
//! Tests: the unit tests in `text.rs`, `document.rs`, `snapshot.rs`,
//! `motion.rs`, `words.rs`, `transaction.rs`, `log.rs`, `marker.rs`,
//! `inverse.rs` and `fuzzy.rs`, and, for a scene's words, in
//! `display/wire.rs`;
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
//! `tests/snapshot.rs` is one; for a list of strings,
//! `candidates_are_ranked_through_c_as_the_ranking_rule_ranks_them`,
//! `no_candidates_are_ranked_as_none` and
//! `candidates_that_cannot_be_read_are_refused_with_no_words` in
//! `tests/fuzzy.rs`; for a list of handles,
//! `a_scene_published_through_c_is_laid_out_as_layout_lays_it_out`,
//! `words_that_spell_no_scene_are_refused_and_the_last_frame_is_kept`,
//! `a_display_nothing_was_published_to_has_no_scene` and, for the faces,
//! `faces_published_through_c_reach_layout_and_absent_faces_keep_the_last`,
//! `words_that_spell_no_face_are_refused_and_the_last_frame_and_faces_are_kept`
//! and `a_scene_published_with_faces_comes_back_with_them` in
//! `tests/display.rs`;
//! the `find` and event checks of `ffi-test`
//! (`dataChecks`), its document checks (`documentChecks`), its snapshot
//! checks (`snapshotChecks`), its transaction checks (`transactionChecks`),
//! its marker checks (`markerChecks`), its inverse checks
//! (`inverseChecks`) and, for a list of handles, its scene checks
//! (`sceneChecks`).
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
//! timer ([`timers`]) and a load or a save of a file ([`files`]) today, a
//! process later. A job that waits must not hold a thread, so a request to
//! a service is never a blocking call. Every service follows these rules:
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
//! Second example: the file service. Its port is `editor-text`'s
//! [`editor_text::fs::Fs`], with [`editor_text::fs::FakeFs`] published for
//! tests and the real adapter in a crate of its own (`editor-fs-std`),
//! which only the process's instance names; which request is worked when
//! is the pure [`files::Requests`]; what a load and a save do is
//! [`editor_text::file`]'s. A request has a result as well as a
//! completion, which the caller takes by the request's id once the
//! completion has arrived ([`files::editor_ffi_files_take`]): a record of a
//! status, a snapshot handle, words and a detail string. Its other C
//! functions are [`files::editor_ffi_files_load`],
//! [`files::editor_ffi_files_save`], [`files::editor_ffi_files_cancel`]
//! and, as a readout for tests, [`files::editor_ffi_files_pending`].
//!
//! Tests: the unit tests of `files.rs`, on the fake file system (the
//! requests alone; the service loop, where the fake holds the service's
//! thread inside a call so a test sees what is done meanwhile, and a marker
//! request shows what was not completed). They assert the service's rules
//! only: where a check needs what a load or a save answers, it asks
//! [`editor_text::file`] the same thing on a second fake and compares.
//! `files_are_loaded_and_saved_through_c_and_completed_on_the_completion_queue`
//! in `tests/files.rs` is the wiring test: the C functions, the process's
//! service, the logic and the real adapter, in a temporary directory it
//! owns, asserting bytes in and bytes out. The crate's `clippy.toml`
//! refuses a real file, and the adapter's constructor, everywhere in the
//! crate but the process's instance and that test. On the Lean side: the
//! file checks of `ffi-test` (`fileChecks`), which pin that the requests,
//! their arguments and every kind of result cross.
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
//!   the window port's options, and the present mode and frame latency a
//!   run asks for as a tag and a number, each 0 for none. How the run went
//!   comes back as a status and, but for a window that ran and was drawn
//!   in, a reason in a record ([`window::RawRefusal`]): a failure to open,
//!   or why nothing drew in a window that ran ([`window::WINDOW_UNDRAWN`]).
//! - **What Lean publishes is drawn in the window** by a render session
//!   over the process's presenter: a display bound to it
//!   ([`display::editor_ffi_display_present`]) is drawn there. A renderer
//!   that cannot be made, or a render thread that panics, leaves the window
//!   running with nothing drawing in it, and the run says why once the
//!   window has closed ([`window::Ran`]).
//! - **What the window reports is events** on the editor queue, from the
//!   window source, of the kinds from
//!   [`events::EventKind::WindowOpened`] on.
//! - **A window's event carries a stamp**: the reading of the process's
//!   input clock when the window reported it. Lean reads the same clock
//!   with [`window::editor_ffi_input_clock_now`].
//! - **Lean closes the window.** A window that is asked to close reports it
//!   and stays open until [`window::editor_ffi_window_close`] is called,
//!   which any thread may do.
//! - **Lean asks things of the window** with
//!   [`window::editor_ffi_window_request`]: enter or leave fullscreen, or
//!   minimise, by tag. It never blocks, and it goes through the window's
//!   own loop, not the main-thread service, which still answers nothing
//!   else while the window runs. Whether the window is in fullscreen comes
//!   back on every resize, as bit 0 of its code.
//! - **The window's title is the scene's.** A display bound to the
//!   presenter hands it the title of each scene it publishes, and the
//!   presenter sends it to the open window when it changes
//!   ([`render`], "What reaches the window: the title").
//! - **The platform is named by a tag** ([`window::PlatformId`]), checked
//!   like a queue's. The two scripted platforms, the one that reports a
//!   sample and the one that cannot open a window, are reachable for the
//!   Lean test executable, as the scripted event source is.
//!
//! Tests: the unit tests of `window.rs` (the event each input becomes, the
//! stamps, the options, a platform that cannot open, the request tags), on
//! the port's fake
//! with a clock and a queue of their own; the request's test in
//! `main_thread.rs`;
//! `the_process_wide_window_reports_on_the_editor_queue_until_it_is_closed`
//! in `tests/window.rs`, an integration test of its own because the queue
//! is process-wide and `tests/c_api.rs` quits it.
//!
//! ## The interrupt flag
//!
//! A flag the library raises as the interrupt key arrives, before the key
//! is queued, so that Lean can ask between the steps of a command whether
//! the user wants it stopped. [`interrupt`] has the detail. Its rules:
//!
//! - **The primitive is here; the policy is Lean's.** The library counts
//!   the presses of the interrupt key that have arrived, and marks each of
//!   their events ([`window::KEY_INTERRUPT`]). Which key that is, when the
//!   flag is asked and when it is lowered are Lean's.
//! - **The key goes in as words**
//!   ([`interrupt::editor_ffi_interrupt_key_set`]): a logical key, the
//!   modifiers and a mask of the modifiers to compare, so Lean's rule for
//!   which keys are the same stays in Lean.
//! - **The flag is raised on the arrival path** ([`window::arrive`]), the
//!   one path a window's input takes onto the editor queue, reported or
//!   posted.
//! - **The flag is a count, and Lean lowers it**
//!   ([`interrupt::editor_ffi_interrupt_lower`]), once for each marked event
//!   it takes off the queue. Pulling an event lowers nothing.
//!
//! Tests: the unit tests of `interrupt.rs`, and those of `window.rs` for the
//! arrival path, each on a flag and a queue of their own;
//! `the_interrupt_key_raises_the_flag_as_it_arrives_and_lean_lowers_it` in
//! `tests/interrupt.rs`, an integration test of its own because the flag
//! and the queue are process-wide. On the Lean side: `interruptChecks` of
//! `ffi-test`.
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

pub mod clipboard;
pub mod counter;
pub mod display;
pub mod document;
pub mod events;
pub mod files;
pub mod fuzzy;
pub mod interrupt;
pub mod inverse;
pub mod log;
pub mod main_thread;
pub mod marker;
pub mod motion;
pub mod render;
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
