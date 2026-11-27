//! The safe Rust crate a package's library is written against: the package
//! runtime the core hands the library at its init, wrapped in safe types
//! that mirror `editor-service`'s, the init and the function table declared
//! with one macro ([`package!`]), all of the `unsafe` over the runtime, and
//! the runtime's fake, which runs on the test's thread
//! (docs/design/packages.md, "The package crate wrapper, as built"). It is
//! to the runtime what `emacs-module-rs` is to Emacs's `emacs_env`.
//!
//! # How a package depends on it
//!
//! A crate of this repository by path. A third party's crate by a git
//! source, pinned by revision, which Cargo finds by name in the repository:
//!
//! ```toml
//! editor-package = { git = "https://github.com/leanmacs/leanmacs", rev = "<sha>" }
//! ```
//!
//! It is not published to crates.io (`publish = false`, and its
//! `Cargo.toml` says why); a dependent fetches the whole repository.
//!
//! # The boundary
//!
//! It depends on the runtime's C definitions, re-exported as [`raw`], and
//! the typed time bounds, re-exported as [`wait`], and on nothing else: no
//! other crate of the editor's, no third-party crate. Neither has a
//! static, so a library built on this crate carries no copy of the core's
//! state, and a package's crate names neither. `deny.toml` refuses this
//! crate an edge to `editor-service` or `editor-package-library`, a
//! dev-dependency included; so the runtime's own contract runs on this
//! crate's fake from the test-only crate `editor-package-check`.
//!
//! # A package, declared
//!
//! A package writes its state, its init (`fn(Runtime) -> S`) and a
//! `#[repr(C)]` struct of its table's functions, each an `extern "C" fn`
//! over this crate's FFI-safe types ([`buffer`]), declared with
//! [`functions!`], whose body sees what the caller lends borrowed for the
//! call alone, with no `unsafe` of its own; [`package!`] declares the
//! package and exports its init, `editor_package_init`:
//!
//! ```
//! # #![deny(unsafe_code)]
//! use editor_package::buffer::{Bytes, Lent, Out};
//! use editor_package::{Package, Runtime, Service, functions, package};
//!
//! /// The library's state, made once by its init.
//! pub struct Loaded {
//!     service: Service,
//! }
//!
//! impl Loaded {
//!     /// The init: registers the package's service through the runtime.
//!     pub fn new(runtime: Runtime) -> Self {
//!         Self { service: runtime.register("echo") }
//!     }
//! }
//!
//! /// A reply as it crosses: `{ { uint8_t *bytes; size_t len; } text; }`.
//! #[repr(C)]
//! pub struct Reply {
//!     pub text: Lent,
//! }
//!
//! /// The table's functions, behind the size the wrapper puts first.
//! #[repr(C)]
//! pub struct Functions {
//!     pub start: extern "C" fn(id: u64, text: Bytes<'_>) -> bool,
//!     pub take: extern "C" fn(id: u64, out: Out<'_, Reply>) -> bool,
//!     pub free: extern "C" fn(text: Lent),
//! }
//!
//! functions! {
//!     /// `text` is the `&[u8]` the caller lent, for the call alone.
//!     extern "C" fn start(id: u64, text: Bytes<'_>) -> bool {
//!         !text.is_empty()
//!             && PACKAGE.state().is_some_and(|loaded| loaded.service.complete(id))
//!     }
//!
//!     /// `out` is a `Place`, written once.
//!     extern "C" fn take(_id: u64, out: Out<'_, Reply>) -> bool {
//!         out.put(Reply { text: Lent::of(b"echoed".to_vec()) });
//!         true
//!     }
//! }
//!
//! package! {
//!     /// The library.
//!     pub static PACKAGE: Package<Loaded, Functions> = Package::new(
//!         Loaded::new,
//!         Functions { start, take, free: editor_package::buffer::free },
//!     );
//! }
//!
//! // Its test, on the fake runtime, with no `unsafe`.
//! let fake = editor_package::fake::FakeRuntime::new().leak();
//! let (status, _table) = fake.init(editor_package_init);
//! assert_eq!(status, editor_package::raw::INIT_LOADED);
//! assert!((PACKAGE.table().functions().start)(7, Bytes::of(b"hi")));
//! assert_eq!(fake.next_completion(), Some((1024, 7)));
//! ```
//!
//! # The modules
//!
//! - [`package`](mod@package): [`Package`], [`Table`] and the macro [`package!`]; the
//!   init's refusal of a runtime smaller than [`REQUIRED`].
//! - [`runtime`]: [`Runtime`], the runtime a package's init is handed.
//! - [`service`]: [`Service`], and the port a service reports through
//!   ([`Completer`]), with its fake ([`RecordingCompleter`]) and contract
//!   ([`completer_contract`]).
//! - [`stream`]: a child taken over ([`stream::Child`], over the
//!   [`stream::ChildStreams`] port), its scripted fake ([`stream::fake`])
//!   and the port's own contract ([`stream::contract`]).
//! - [`frame`]: the frames a pull delivers, plain data.
//! - [`wire`]: how a pull crosses the runtime.
//! - [`buffer`]: what crosses a package's table and the runtime: [`Bytes`],
//!   [`Lent`], [`Out`], [`CoreBuffer`]; and the macro [`functions!`], which
//!   declares a table's functions and hands each body what it was lent
//!   borrowed for the call alone ([`buffer::Param`], [`buffer::Place`]).
//! - [`fake`]: [`fake::FakeRuntime`], the runtime's fake.
//!
//! The names, variants and fields of [`frame`], [`stream`] and [`service`]
//! are `editor-service`'s, so a crate's logic written over one ports to the
//! other by its imports. `editor-service`'s `Worker` and its count wait
//! (`RecordingCompleter::wait_for`) are not mirrored.
//!
//! [`Bytes`]: buffer::Bytes
//! [`Lent`]: buffer::Lent
//! [`Out`]: buffer::Out
//! [`CoreBuffer`]: buffer::CoreBuffer
//!
//! # Where the `unsafe` is
//!
//! The crate denies `unsafe_code` everywhere but its marked sites, each with
//! its reason:
//!
//! - [`runtime`]: `Runtime::from_raw`, which takes the runtime the core
//!   hands an init once its size is checked; the one `Calls` impl through
//!   which every member of a runtime is read, alone through its own place,
//!   and called; and `Calls`' `Send` and `Sync`, since it holds the runtime
//!   as a pointer, never a reference to the whole of a `PackageRuntime`
//!   that an older core's runtime may end before.
//! - [`buffer`]: [`Param::enter`](buffer::Param::enter), declared and
//!   implemented, which reads a [`Bytes`] and enters an [`Out`] for the
//!   call; [`Place::put`](buffer::Place::put); a [`Lent`]'s parts, its
//!   drop, its `Send` and `Sync`; and
//!   [`CoreBuffer::as_bytes`](buffer::CoreBuffer::as_bytes). And
//!   [`functions!`]' expansion, which enters each parameter, which rustc's
//!   `unsafe_code` lint does not reach in a package's crate.
//! - [`stream`]: [`stream::Child`]'s `Send` and `Sync`.
//! - [`package`](mod@package): [`Package::export`] and the macro's expansion, which
//!   rustc's `unsafe_code` lint does not reach in a package's crate.
//! - [`fake`]: its C members, its ledger's free and its
//!   [`init`](fake::FakeRuntime::init).
//!
//! # Where an addition goes
//!
//! | Addition | Where | Pinned by |
//! |---|---|---|
//! | A new runtime member (a trailing member of `editor-package-runtime`, with phase 2's steps there and in `editor-package-library`) | A method on the type it concerns ([`Runtime`], [`Service`], [`stream::Child`]), which asks `runtime_has!` for the member and only then reads it through `Calls`' `member!` (alone through its own place, never through a reference to the whole runtime, which on an older core ends before the new member) and calls it, and answers its absent outcome on an older runtime; the same member in [`fake::FakeRuntime`]; its words in [`wire`] if it carries any | The method's unit test over [`fake::FakeRuntime`], and over [`fake::FakeRuntime::sized`] ending before it (the absent outcome); `runtime`'s test over a runtime of exactly [`REQUIRED`] bytes (`a_runtime_that_ends_at_buffer_free_is_called_through_every_member_and_no_further`), which the method joins; the fake's run of the runtime's contract, which gains the member's property (`editor-package-check/tests/contract.rs`) |
//! | A new wrapper type for what crosses a package's table | [`buffer`], with its C shape in its docs, and its [`buffer::Param`] impl, which hands a declared function's body what it lends borrowed for the call alone, never a safe reader of its own | Its unit tests; `tests/functions.rs`, a function declared with [`functions!`] that takes it; and, when it crosses the runtime, `editor-package-check/tests/load.rs` over the real runtime |
//! | A new type mirrored from `editor-service` | The module of the same name ([`frame`], [`stream`], [`service`]), the same name, variants and fields | Its unit tests here; `editor-package-check`'s conversion, which matches every variant |
//! | Another way a child ends, or frames | A variant of [`stream::Ended`] or [`frame::Frames`], its words in [`wire::encode`] and [`wire::decode`] (both match every variant) | [`wire`]'s round trip, which lists every variant; `editor-package-check/tests/wire.rs`, both directions with the core |
//! | A rule of the init or the table | [`package`](mod@package) ([`Package::export`], [`Package::load`], [`Table`]) | [`package`](mod@package)'s unit tests and `tests/declare.rs` |
//! | A rule every stream source keeps (the scripted fake and the runtime's [`stream::Child`] alike) | A property of [`stream::contract::check`], a [`stream::contract::Scenario`] for its child, and each ground's mapping of it ([`stream::fake::ScriptedSource`]'s, and `editor-package-check`'s over `editor-service`'s `FakeSource`) | The contract on [`stream::fake::ScriptedSource`] (`the_scripted_source_keeps_the_stream_contract`), on [`Runtime`] over [`fake::FakeRuntime`] (`a_runtime_over_the_fake_keeps_the_stream_contract`), and on [`Runtime`] over the real `RUNTIME` (`editor-package-check/tests/load.rs`); and that it bites: a flaw of the scripted source that breaks the rule (its crate-private `Flaws`), and a test in [`stream::contract`]'s own that the contract reports exactly that property |
//! | Another way for a test to script the fake | A method of [`fake::FakeRuntime`] or [`stream::fake`] | The fake's unit tests, and the stream contract on [`stream::fake::ScriptedSource`] when the method changes what a child delivers |

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

/// The runtime's C definitions (`editor-package-runtime`): the struct, its
/// handle and records, the tags, the init's type and `runtime_has!`, for
/// the macro's paths and a package's tests.
pub use editor_package_runtime as raw;
/// The typed time bounds (`editor-wait`), so that a package's crate bounds
/// its tests' waits with a [`wait::HangGuard`] while depending on this crate
/// alone, as `editor_service::wait` does for an archive-linked one.
pub use editor_wait as wait;
