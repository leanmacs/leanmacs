//! The window port: what the editor needs of a platform's window, in its own
//! terms, with a fake and a contract.
//!
//! A [`Platform`] opens one window and runs it on the calling thread until
//! it is closed, handing each thing the window reports to its caller as an
//! [`Input`]: plain data that names no windowing library. The crate has no
//! dependencies and knows nothing about Lean. `editor-platform-winit` is the
//! real adapter; `editor-ffi` runs a platform and puts what it reports on the
//! editor's event queue.
//!
//! # This is a first cut
//!
//! The vocabulary is what the keyboard check needs to tell a key, a dead key
//! and a composition apart (`editor window-check`, `README.md`). An [`Input`]
//! carries no key identity: no physical or logical key and no modifiers. The
//! display pipeline defines those, and may replace [`Input`] when it does.
//!
//! # Where an addition goes
//!
//! The port grows by data, not by methods.
//!
//! | Addition | Where | Pinned by |
//! |---|---|---|
//! | Something more a window reports | A variant of [`Input`], or a field of one | The fake's tests in [`scripted`], and the adapter's translation tests |
//! | Another way to open the window | A field of [`WindowOptions`] | The fake's tests: it records the options it was run with |
//! | A rule every platform keeps | [`contract`] | Its own tests, on the fake and on platforms written to break it |
//!
//! # Where the real adapter is held to the contract
//!
//! [`ScriptedPlatform`] passes [`contract::check`] in this crate's tests, and
//! everything above the port is tested on it. The real adapter needs a
//! display to open a window, and the gate (`mise run ci`) opens no window and
//! needs neither a display nor Docker. So the adapter's run of the contract
//! is not in the gate. It is an example binary of `editor-platform-winit`,
//! run by two opt-in tasks:
//!
//! - `mise run linux-window` runs it in a container under Xvfb, a display
//!   that needs no person and puts no window on the developer's screen. This
//!   is the repeatable one: run it after a change to the adapter or to the
//!   contract.
//! - `mise run window-contract` runs the same example on the desktop it is
//!   started from.

pub mod contract;
pub mod scripted;

use std::error::Error;
use std::fmt;
use std::sync::Arc;

pub use scripted::ScriptedPlatform;

/// One thing a window reports.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Input {
    /// The window is open. This is the first thing a platform reports.
    Opened {
        /// The name the platform gives itself: `winit`, `scripted`.
        platform: String,
    },
    /// The window gained (`true`) or lost (`false`) the keyboard focus.
    Focus(bool),
    /// A key was pressed or released.
    Key(Key),
    /// A step of an input method's composition.
    Composition(Composition),
    /// A pointer button was pressed in the window.
    PointerPressed,
    /// The user asked for the window to be closed. The window stays open
    /// until [`Platform::close`] is called.
    CloseRequested,
}

/// A key event: what happened to a key, and the text it produced.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Key {
    /// Whether the key went down; `false` when it came up.
    pub pressed: bool,
    /// Whether this is a press the platform repeated because the key is held.
    pub repeat: bool,
    /// Whether the key is a dead key: one that produces nothing by itself
    /// and changes the key after it.
    pub dead: bool,
    /// The text the key produced; empty when it produced none.
    pub text: String,
}

/// A step of an input method's composition (IME).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Composition {
    /// The input method became available to the window.
    Enabled,
    /// The text being composed changed; it is not yet part of the input.
    Preedit(String),
    /// The composition ended with this text.
    Commit(String),
    /// The input method is no longer available to the window.
    Disabled,
}

/// How a window is to be opened.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WindowOptions {
    /// Whether an input method may compose text in the window. When it may
    /// not, the platform reports no [`Input::Composition`], and a dead key
    /// arrives as a key.
    pub composition: bool,
}

impl Default for WindowOptions {
    /// Composition is allowed.
    fn default() -> Self {
        Self { composition: true }
    }
}

/// Where a platform hands what its window reports.
///
/// It is owned, not borrowed for the run, so a platform may hand it to a
/// thread of its own. A platform reports nothing once its
/// [`run`](Platform::run) has returned; [`contract`] checks that.
pub type Report = Arc<dyn Fn(Input) + Send + Sync>;

/// Why a platform could not open a window.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CannotOpen {
    /// The reason, in the platform's words.
    pub reason: String,
}

impl fmt::Display for CannotOpen {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.reason)
    }
}

impl Error for CannotOpen {}

/// The port: a platform that can open a window.
///
/// The rules every implementation keeps are [`contract::check`].
pub trait Platform: Sync {
    /// Opens a window as `options` say and runs it on the calling thread
    /// until [`close`](Self::close) is called, handing each [`Input`] to
    /// `report` as it arrives, [`Input::Opened`] first.
    ///
    /// Returns a failure, having reported nothing, when no window can be
    /// opened.
    fn run(&self, options: WindowOptions, report: Report) -> Result<(), CannotOpen>;

    /// Asks the running window to close, so that [`run`](Self::run) returns.
    /// It may be called from any thread, and does nothing when no window is
    /// running.
    fn close(&self);
}
