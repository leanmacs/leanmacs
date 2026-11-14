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
//! - [`schedule`]: when to draw, as a pure function of what is asked for
//!   and the time.
//! - [`port`]: the [`Renderer`](port::Renderer) port itself.
//! - [`rows`]: which rows of a frame a renderer builds and which it draws
//!   from what it kept.
//! - [`fake`]: the port's published fake, which records what it is asked
//!   to draw.
//! - [`contract`]: the rules the fake and every real adapter are held to.
//! - [`journal`]: the frame journal and the counters.

pub mod clock;
pub mod contract;
pub mod fake;
pub mod journal;
pub mod mailbox;
pub mod port;
pub mod rows;
pub mod schedule;
