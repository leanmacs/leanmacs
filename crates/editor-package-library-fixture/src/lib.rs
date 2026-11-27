//! A test fixture: six small package libraries written in C, each
//! exporting `editor_package_init` (docs/design/packages.md, "A library
//! loaded when the editor runs, as built", "The package runtime, as
//! built", and "A package's library, staged and loaded, as built"). Every
//! one but [`NO_DECLARATION`] exports a declaration
//! (`editor_package_declaration`) saying interface 1.
//!
//! Two refuse the runtime they are handed, the two refusals a load only
//! reaches by calling a real library's init (`editor_package_library::load`):
//! `editor-ffi`'s `tests/package_load.rs` loads each through the C function
//! a package's glue calls, so the init is handed the process's real
//! runtime, with no size of the runtime made smaller for a test.
//!
//! Two are refused by their declaration, before the init: one that
//! declares nothing, and one that declares a runtime one member longer than
//! today's. `tests/package_load.rs` loads both too.
//!
//! Two load and run on it: one built against its own copy of the runtime
//! as it ended at `complete`, smaller than today's, and one built against
//! the generated header (`crates/editor-package-runtime/include/`), which
//! is how the header is compiled by a C compiler and run against the Rust
//! runtime. `editor-ffi`'s `tests/package_runtime.rs` loads both, and the
//! library port's adapter reads the second's declaration in its contract
//! test (`editor-package-library-libloading`'s `tests/contract.rs`).
//!
//! `editor-ffi` and the adapter reach this crate by a dev-dependency, and
//! the editor never links it (`deny.toml`).
//!
//! **Why build-script products, not `cdylib`s.** Each library is compiled
//! and linked by `build.rs` into `OUT_DIR`, as the fixture grammar library
//! is (`editor-syntax-fixture-ini`, whose crate docs say why a Cargo
//! `cdylib` would not do).

/// A library whose init requires a larger runtime than any core's: it
/// answers 1, the runtime too small, with its table unwritten
/// (`fixture/runtime_too_small.c`). The built library's absolute path.
pub const RUNTIME_TOO_SMALL: &str = env!("EDITOR_PACKAGE_LIBRARY_FIXTURE_RUNTIME_TOO_SMALL");

/// A library whose init answers 7, a status no library answers, with its
/// table unwritten (`fixture/init_failed.c`). The built library's absolute
/// path.
pub const INIT_FAILED: &str = env!("EDITOR_PACKAGE_LIBRARY_FIXTURE_INIT_FAILED");

/// A library built when the runtime ended at `complete`, against its own
/// copy of that smaller struct: its init checks the runtime is at least
/// that large, registers the service `older` and answers 0 with a table
/// `{ size, service, fire }`, whose `fire(request)` completes through the
/// older view (`fixture/older_runtime.c`). The built library's absolute
/// path.
pub const OLDER_RUNTIME: &str = env!("EDITOR_PACKAGE_LIBRARY_FIXTURE_OLDER_RUNTIME");

/// A library built against the generated header, declared with
/// `EDITOR_PACKAGE_DECLARE(1, buffer_free)`: its init checks the
/// runtime has `buffer_free`, registers the service `current` and answers 0
/// with a table `{ size, service, fire, post, lend_twice }`, which complete,
/// post an event, and lend a buffer and hand it back twice, answering both
/// hand-backs (`fixture/current_runtime.c`). The built library's absolute
/// path.
pub const CURRENT_RUNTIME: &str = env!("EDITOR_PACKAGE_LIBRARY_FIXTURE_CURRENT_RUNTIME");

/// A library that exports an init and no declaration: refused before its
/// init, which would write a table and answer 0
/// (`fixture/no_declaration.c`). The built library's absolute path.
pub const NO_DECLARATION: &str = env!("EDITOR_PACKAGE_LIBRARY_FIXTURE_NO_DECLARATION");

/// A library whose declaration needs a runtime one function pointer longer
/// than today's: refused before its init, which would write a table and
/// answer 0 (`fixture/newer_runtime.c`). The built library's absolute
/// path.
pub const NEWER_RUNTIME: &str = env!("EDITOR_PACKAGE_LIBRARY_FIXTURE_NEWER_RUNTIME");
