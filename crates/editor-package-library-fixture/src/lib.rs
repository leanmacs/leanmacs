//! A test fixture: two small package libraries, each exporting
//! `editor_package_init` and refusing the runtime it is handed, the two
//! refusals a load only reaches by calling a real library's init
//! (`editor_package_library::load`; docs/design/packages.md, "A library
//! loaded when the editor runs, as built").
//!
//! `editor-ffi`'s `tests/package_load.rs` loads each through the C function
//! a package's glue calls, so the init is handed the process's real
//! runtime, with no size of the runtime made smaller for a test. It reaches
//! this crate by a dev-dependency, and the editor never links it
//! (`deny.toml`).
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
