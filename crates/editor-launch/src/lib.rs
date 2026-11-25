//! The app launcher's core: what the bundle's `leanmacs` decides when it
//! starts an editor, and what its watcher decides when one fails
//! (`docs/design/lean-runtime.md`, "The app's identity across an exec").
//!
//! - [`handover`]: the hand-over record a restart writes and a cold start
//!   of a per-user editor writes, read and rewritten here, and its text
//!   format.
//! - [`launch`]: the launcher's command line and its whole decision: the
//!   default, a cold start, a hand-over's candidates and their order, the
//!   launch flags it gives an editor, `CFProcessPath` on macOS, and what
//!   happens when no candidate is left.
//! - [`editors`]: the per-user editors a cold start chooses among: the
//!   data directory, the default's core, its complete versions newest
//!   first, and the cold record's place.
//! - [`watch`]: the watcher the launcher spawns before each hand-over's
//!   exec, which starts the fallback when the editor ends before the
//!   hand-shake.
//!
//! The crate touches nothing itself. It reaches files, the time, other
//! processes, starts, execs and its environment through the ports in
//! [`ports`], and the root `clippy.toml` refuses the calls that would reach
//! them directly. Its tests run on the published fakes ([`fake`]);
//! [`contract`] holds the real adapters to what the fakes do. The adapters
//! and the `leanmacs` binary are `editor-launch-std`.

pub mod contract;
pub mod editors;
pub mod fake;
pub mod handover;
pub mod launch;
pub mod ports;
pub mod watch;
