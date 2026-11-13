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
//! # What a window reports
//!
//! A key with its identity: its logical key ([`LogicalKey`], what the layout
//! makes of it), its physical key ([`PhysicalKey`], where it is) and the
//! [`Modifiers`] held, with the text it produced beside them. Named keys and
//! physical keys are W3C UI Events names, as strings, so a new one needs no
//! number on either side of the Lean boundary. A pointer ([`Pointer`]) with
//! its action, position, button and modifiers; a resize ([`Resize`]) with
//! the size and the scale factor; the focus; an input method's composition;
//! that the window opened; and a request to close.
//!
//! The command loop fixed this shape (its phase 1), so that it and the
//! display pipeline build on one. The winit adapter maps only a dead key and
//! a bare pointer press so far; producing the rest from winit is the display
//! pipeline's (its phase 5).
//!
//! # Where an addition goes
//!
//! The port grows by data, not by methods. Each addition crosses to Lean as
//! a row of the table in `editor-ffi`'s `window.rs` and a case in Lean's
//! `Editor/Event/Queue.lean`; `Editor/Event.lean` says which roadmap owns
//! each side.
//!
//! | Addition | Where | Pinned by |
//! |---|---|---|
//! | Something more a window reports | A variant of [`Input`] (as [`Input::Pointer`] and [`Input::Resized`] were), or a field of one | The fake's tests in [`scripted`], and the adapter's translation tests |
//! | A new key attribute | A field of [`Key`] or of [`Modifiers`] | The same |
//! | A new named key or physical key | Nothing here: the adapter produces its W3C name in [`LogicalKey::Named`] or [`PhysicalKey::Code`] | The adapter's translation tests |
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
///
/// It is `PartialEq` and not `Eq`: a pointer's position and a resize's
/// scale are floating point.
#[derive(Debug, Clone, PartialEq)]
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
    /// The pointer did something in the window: a button went down or up,
    /// it moved with a button held, or a wheel turned.
    Pointer(Pointer),
    /// The window's drawable area changed size, or its scale factor did.
    Resized(Resize),
    /// The user asked for the window to be closed. The window stays open
    /// until [`Platform::close`] is called.
    CloseRequested,
}

/// A key event: which key, what happened to it, the modifiers held, and the
/// text it produced.
///
/// The key's identity ([`logical`](Self::logical),
/// [`physical`](Self::physical)) and the text it produced are separate: a
/// key may have an identity and produce no text (`Escape`), or produce text
/// an input method chose.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Key {
    /// Whether the key went down; `false` when it came up.
    pub pressed: bool,
    /// Whether this is a press the platform repeated because the key is held.
    pub repeat: bool,
    /// What the keyboard layout makes of the key.
    pub logical: LogicalKey,
    /// Where the key is on the keyboard, whatever the layout.
    pub physical: PhysicalKey,
    /// The modifiers held when the key went down or came up.
    pub modifiers: Modifiers,
    /// The text the key produced; empty when it produced none.
    pub text: String,
}

impl Key {
    /// A release of a key the platform could not identify, with no modifier
    /// held and no text: the base to build a key from with `..`.
    pub const fn unidentified() -> Self {
        Self {
            pressed: false,
            repeat: false,
            logical: LogicalKey::Unidentified,
            physical: PhysicalKey::Unidentified,
            modifiers: Modifiers {
                shift: false,
                control: false,
                alt: false,
                super_key: false,
            },
            text: String::new(),
        }
    }
}

/// What the keyboard layout makes of a key.
///
/// Named keys are W3C UI Events `key` values, as strings (`Escape`,
/// `ArrowLeft`, `Enter`), so a new one needs no new number on either side of
/// the Lean boundary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LogicalKey {
    /// A key that produces a character: the characters the layout gives it,
    /// usually one.
    Character(String),
    /// A key with a name and no character: its W3C UI Events `key` value.
    Named(String),
    /// A dead key: one that produces nothing by itself and changes the key
    /// after it. The character it would add, when the platform says.
    Dead(Option<char>),
    /// The platform could not say.
    Unidentified,
}

/// Where a key is on the keyboard, whatever the layout.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PhysicalKey {
    /// The key's W3C UI Events `code` value (`KeyA`, `Digit1`, `Escape`).
    Code(String),
    /// The platform could not say.
    Unidentified,
}

/// The modifier keys held.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Modifiers {
    /// Shift.
    pub shift: bool,
    /// Control.
    pub control: bool,
    /// Alt, which macOS calls Option.
    pub alt: bool,
    /// The system key: Command on macOS, the Windows key elsewhere.
    pub super_key: bool,
}

/// What the pointer did, where, with which button, and the modifiers held.
///
/// The position is in the window's physical pixels, from its top left.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Pointer {
    /// What happened.
    pub action: PointerAction,
    /// How far from the left of the window, in physical pixels.
    pub x: f64,
    /// How far from the top of the window, in physical pixels.
    pub y: f64,
    /// The button that went down or up, or that is held while dragging;
    /// `None` when there is none, as for a wheel.
    pub button: Option<Button>,
    /// The modifiers held.
    pub modifiers: Modifiers,
}

/// What a pointer did.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PointerAction {
    /// A button went down.
    Press,
    /// The pointer moved with a button held.
    Drag,
    /// A button came up.
    Release,
    /// A wheel turned, or a trackpad scrolled, by this much.
    Wheel(WheelDelta),
}

/// How far a wheel turned.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum WheelDelta {
    /// In lines and columns, as a mouse wheel's notches count.
    Lines {
        /// Columns.
        x: f64,
        /// Lines.
        y: f64,
    },
    /// In physical pixels, as a trackpad scrolls.
    Pixels {
        /// Pixels across.
        x: f64,
        /// Pixels down.
        y: f64,
    },
}

/// A pointer button.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Button {
    /// The main button: usually the left.
    Primary,
    /// The context button: usually the right.
    Secondary,
    /// The middle button, often the wheel.
    Middle,
    /// The back button.
    Back,
    /// The forward button.
    Forward,
    /// Another button, by the platform's number for it.
    Other(u16),
}

/// The window's new size and scale factor.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Resize {
    /// The drawable width, in physical pixels.
    pub width: u64,
    /// The drawable height, in physical pixels.
    pub height: u64,
    /// How many physical pixels a logical pixel is.
    pub scale: f64,
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
