//! The conventions every service of the Rust library keeps, as a crate of
//! their own: what `editor-ffi`'s services and the crate of every package
//! that holds Rust share (docs/design/packages.md, "Rust in a package").
//!
//! - [`service`]: registering a service ([`Service`]), which gives it the
//!   id its completions carry, and the port a service reports through
//!   ([`Completer`]), with its published fake ([`RecordingCompleter`]) and
//!   contract ([`completer_contract`]).
//!
//! A package's crate depends on this crate and on nothing else of the
//! editor's. All of the editor is linked from one Rust archive, generated
//! from the package set, so the process holds one copy of this crate and
//! of everything process-wide in it.
//!
//! # Where an addition goes
//!
//! | Addition | Where | Pinned by |
//! |---|---|---|
//! | A rule of how a service is named or numbered | [`service`] | Its unit tests |
//! | A rule every completer keeps | A property of [`completer_contract`] | Its tests, on the fake and on completers written to break it, and `tests/queue.rs` on the real one |

pub mod service;

pub use service::{
    Completer, FIRST_PACKAGE_ID, RecordingCompleter, Service, completer_contract, registered,
};
