//! Tests alone, which hold the package wrapper (`editor-package`) to the
//! core: it has no code of its own.
//!
//! The wrapper may depend on nothing of the core's, not even for its tests
//! (`deny.toml`), so what needs the core runs here, in a crate nothing
//! depends on:
//!
//! - `tests/contract.rs`: the runtime's contract
//!   (`editor_package_library::runtime::contract::check`), the one the
//!   core's model and its real `RUNTIME` keep, run on the wrapper's fake
//!   (`editor_package::fake::FakeRuntime`), as the current runtime and as a
//!   later one. The contract stays the core's: the crate that owns the
//!   runtime publishes it, and every implementation is held to it.
//! - `tests/wire.rs`: a pull the core encodes reads back through the
//!   wrapper's decoder, and one the wrapper encodes through the core's, for
//!   every way to frame and to end.
//! - `tests/load.rs`: a package declared with the wrapper's macro loads
//!   through the core's load (`editor_package_library::load::load`) on the
//!   process's real runtime, and its `Runtime` there keeps the completer
//!   contract and the wrapper's own stream contract.
//!
//! A change to the wrapper's fake that breaks the core's rules fails here,
//! not in the core's tests.
