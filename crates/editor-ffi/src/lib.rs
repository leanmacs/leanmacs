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
//! Every binding follows the rules below. Each rule has one small real
//! example in this crate and names the tests that pin it. This is Rust's
//! side of each rule; Lean's side is in the module docs of
//! `lean/Editor/Ffi.lean`.
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
//! Example: [`counter`]. Tests: `a_counter_is_live_from_new_until_free` in
//! `tests/c_api.rs`; the four counter checks of `ffi-test` (`handleChecks`).
//!
//! ## Plain data
//!
//! | Kind | Lean to Rust | Rust to Lean |
//! |---|---|---|
//! | String | A pointer and a byte length, borrowed for the call; what is kept is copied (`text::borrow`) | An owned buffer, pointer and length, in the result record; the glue copies it and hands it back with one call to [`text::editor_ffi_text_free`]. Embedded NUL bytes survive |
//! | Enum | A `u8` tag, converted with a checked function that refuses a tag it does not know ([`events::QueueId::from_tag`]) | A `u64` tag in the result record ([`events::EventKind::tag`]) |
//! | Small structure | Its fields, as scalar arguments | One `#[repr(C)]` record filled through an out-pointer in a single call ([`events::RawEvent`]) |
//! | Option | A presence flag and a value | The function returns whether there is a value and fills the record only if so |
//! | Byte range | Two scalars | A record of two `u64`: a start and an end, half-open, in bytes ([`text::ByteRange`]) |
//!
//! Prefer a few scalar arguments or one record to many calls. No
//! `extern "C"` function panics: failure is a return value. A function that
//! dereferences a pointer is `unsafe` and says what it requires.
//!
//! Examples: [`text::editor_ffi_text_find`] (an option in, an option of a
//! byte range out) and an event (a string, enums and a structure, in both
//! directions). Tests: the unit tests in `text.rs`; the tag tests in
//! `events.rs`; `find_fills_the_range_it_found_and_reports_whether_it_found_one`
//! in `tests/c_api.rs`; the `find` and event checks of `ffi-test`
//! (`dataChecks`).
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
//! ## Calls go one way
//!
//! Lean calls this library. The library never calls a Lean function and
//! holds no Lean closure: it queues an event and Lean pulls it.
//!
//! Test: `mise run test` builds and runs this crate's tests with no Lean
//! runtime to link against, so a reference to a Lean function would fail
//! the link.
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
//! explicitly. Nothing in this crate joins a thread or waits at exit.
//!
//! Tests: the quit tests in `events.rs`; `ffi-test shutdown` and
//! `ffi-test exit-while-blocked`.
//!
//! ## Nothing runs at initialisation
//!
//! A Lean module initialiser must not call this library: library objects are
//! created from Lean's `main` or later. The process-wide state here is
//! `const`-initialised statics, so the library needs no start-up call
//! either.
//!
//! What holds Lean to this is the build. The `lean` compiler runs a module's
//! initialisers when it compiles a module that imports it, in a process
//! where this library's symbols do not exist, so `mise run lean` fails on an
//! initialiser that calls the library.

pub mod counter;
pub mod events;
pub mod main_thread;
pub mod text;

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
