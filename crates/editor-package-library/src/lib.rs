//! A package's native library, loaded at run time (docs/design/packages.md,
//! "A library loaded when the editor runs, as built"): the package runtime
//! the core hands the library at its init, the port that opens a library,
//! the load and its refusals, and the port's fake and contract.
//!
//! A package that ships native code ships it as a dynamic library of its
//! own with a C interface, in the shape of Emacs's dynamic modules. Its C
//! glue, linked into the editor, asks the core to load the library
//! (`editor-ffi`'s `editor_ffi_package_load`, the one site that wires the
//! real adapter); the core opens it, finds its init, calls it with the
//! process's runtime ([`runtime::RUNTIME`]) and hands the glue the table the
//! init wrote, through which the glue forwards each `@[extern]` call. The
//! library reaches the core only through the runtime, so it carries no copy
//! of `editor-service`'s process-wide statics: its completions land on the
//! queue the editor reads, and its child is the core's process service's.
//!
//! - [`runtime`]: the runtime's C struct, its one instance and the core's
//!   implementation of each member over `editor-service`, with who owns
//!   what and how a pull crosses.
//! - [`library`]: the port, [`library::Libraries`] and
//!   [`library::Library`], in the core's terms.
//! - [`load`]: the decision, [`load::load`], and its refusals in order
//!   ([`load::LoadRefusal`]).
//! - [`fake`]: the port's published fake, [`fake::FakeLibraries`].
//! - [`contract`]: what every adapter of the port keeps,
//!   [`contract::check`], held by the fake here and by the real adapter
//!   (`editor-package-library-libloading`) on real files.
//!
//! The crate denies `unsafe` everywhere but its marked sites: the runtime's
//! C members, which read and write what a library hands them; the call of a
//! library's init; and a table's `Send` and `Sync`.
//!
//! # Where an addition goes
//!
//! | Addition | Where | Pinned by |
//! |---|---|---|
//! | A capability of the runtime | A member appended to [`runtime::PackageRuntime`], a thin C forwarder over a safe function of [`runtime`] that takes its collaborator | That function's unit test on `editor-service`'s fakes; `tests/runtime.rs` where it reaches a process-wide queue |
//! | Another way a load is refused | A variant of [`load::LoadRefusal`], with the next tag, asked in [`load::load`]'s order | A test of [`load`] on the fake |
//! | A rule every adapter of the port keeps | A property of [`contract::check`] | The contract's tests, on the fake and on a fake canned to break it; the adapter's `tests/contract.rs` on real files |
//! | Another way a taken-over child ends, or frames | Its words in [`runtime::encode`], which matches every variant | [`runtime`]'s encoding tests |

#![deny(unsafe_code)]

pub mod contract;
pub mod fake;
pub mod library;
pub mod load;
pub mod runtime;
