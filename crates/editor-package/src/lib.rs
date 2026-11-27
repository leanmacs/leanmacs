//! The safe Rust crate a package's library is written against.

#![deny(unsafe_code)]

pub mod frame;
pub mod stream;
pub mod wire;

pub use editor_package_runtime as raw;
pub use editor_wait as wait;
