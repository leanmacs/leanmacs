//! The safe Rust crate a package's library is written against.

#![deny(unsafe_code)]

pub mod buffer;
pub mod fake;
pub mod frame;
pub mod package;
pub mod runtime;
pub mod service;
pub mod stream;
pub mod wire;

pub use package::{Package, Table};
pub use runtime::{REQUIRED, Runtime};
pub use service::{Completer, RecordingCompleter, Service, completer_contract};

pub use editor_package_runtime as raw;
pub use editor_wait as wait;
