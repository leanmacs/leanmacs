//! The `Renderer` port, and the render loop every back end shares.
//!
//! A renderer draws a frame of `editor-layout` on a target and says what
//! that cost. This crate owns the port, and beside it the plain logic that
//! is the same whatever draws: the mailbox frames arrive through, the
//! scheduler, the frame journal and the counters, with time behind a port
//! of its own. It depends on `editor-layout` alone and names no drawing
//! library; `editor-render-wgpu` holds the real adapters.
//!
//! - [`clock`]: the [`Clock`](clock::Clock) port and its fake.
//! - [`mailbox`]: one slot in which a newer value replaces one not yet
//!   taken.

pub mod clock;
pub mod mailbox;
