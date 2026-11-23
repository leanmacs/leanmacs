//! The conventions every service of the Rust library keeps, as a crate of
//! their own: what `editor-ffi`'s services and the crate of every package
//! that holds Rust share (docs/design/packages.md, "Rust in a package").
//!
//! - [`queue`]: the process's two event queues, the editor queue and the
//!   completion queue, with the events they carry and the fake source that
//!   feeds them a script.
//! - [`service`]: registering a service ([`Service`]), which gives it the
//!   id its completions carry, and the port a service reports through
//!   ([`Completer`]), with its published fake ([`RecordingCompleter`]) and
//!   contract ([`completer_contract`]).
//! - [`buffer`]: the plain-data buffers that cross the boundary, lent,
//!   borrowed and reclaimed.
//! - [`worker`]: a thread and the owner that ends it ([`Worker`]), whose
//!   drop asks the thread to stop and joins it on every path, so a thread a
//!   test starts never outlives the test.
//! - [`wait`]: the typed time bounds (`editor-wait`, re-exported), so that
//!   a package's crate bounds its tests' waits with a [`wait::HangGuard`]
//!   while depending on this crate alone.
//!
//! A package's crate depends on this crate and on nothing else of the
//! editor's. All of the editor is linked from one Rust archive, generated
//! from the package set, so the process holds one copy of this crate and
//! of everything process-wide in it: one editor queue, one completion
//! queue and one counter of service ids.
//!
//! # Where an addition goes
//!
//! | Addition | Where | Pinned by |
//! |---|---|---|
//! | A new thing to report, or a new origin | A variant of [`queue::EventKind`] or [`queue::SourceKind`] | The unit tests of [`queue`] |
//! | A rule of how a service is named or numbered | [`service`] | Its unit tests |
//! | A rule every completer keeps | A property of [`completer_contract`] | Its tests, on the fake and on completers written to break it, and `tests/queue.rs` on the real one |
//! | A thread a service starts and must end | [`worker::Worker`] | The unit tests of [`worker`] |

pub mod buffer;
pub mod queue;
pub mod service;
pub mod worker;

pub use service::{
    Completer, FIRST_PACKAGE_ID, RecordingCompleter, Service, completer_contract, registered,
};
pub use worker::Worker;

/// The typed time bounds: `editor-wait`, re-exported for the crates of
/// packages, which depend on this crate and on nothing else of the
/// editor's.
pub use editor_wait as wait;
