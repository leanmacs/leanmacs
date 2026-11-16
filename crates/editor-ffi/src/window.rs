//! The window: a platform's window run onto an event queue.
//!
//! The window port is `editor-platform`'s: a [`Platform`] opens a window,
//! runs it on the calling thread and hands what it reports to its caller.
//! This module is the adapter from that port to the queue
//! ([`crate::events`], "a service crate defines its own port for reporting,
//! and `editor-ffi` adapts that port to a queue"). [`run`] runs a platform
//! and pushes each [`Input`] as the [`Event`] that [`event`] makes of it,
//! from the window source, stamped with the reading of an [`InputClock`]
//! when it was reported.
//!
//! | [`Input`] | [`EventKind`] | Code | Text | Words |
//! |---|---|---|---|---|
//! | `Opened` | `WindowOpened` | 0 | The platform's name | None |
//! | `Focus` | `WindowFocus` | 1 gained, 0 lost | Empty | None |
//! | `Key` | `Key` | Bit 0 pressed, bit 1 repeat, bit 2 a dead logical key, bit 3 the interrupt mark | What the key produced, or empty | The logical key, the physical key, the modifiers |
//! | `Composition` | `Composition` | 0 enabled, 1 preedit, 2 commit, 3 disabled | The preedit or the committed text | None |
//! | `Pointer` | `Pointer` | 0 press, 1 drag, 2 release, 3 wheel | Empty | The position, the button, the modifiers, the wheel's delta |
//! | `Resized` | `Resize` | Bit 0 in fullscreen ([`RESIZE_FULLSCREEN`]) | Empty | The width, the height, the scale |
//! | `CloseRequested` | `CloseRequested` | 0 | Empty | None |
//! | `OpenFiles` | `OpenFiles` | 0 | Empty | The paths |
//! | `QuitRequested` | `QuitRequested` | 0 | Empty | None |
//! | `Menu` | `Menu` | 0 | The chosen item's command name | None |
//!
//! The words (`words.rs`) of each kind that has them:
//!
//! - **Key**: `[logical tag, n, n scalars, physical tag, m, m scalars,
//!   modifiers]`. The logical tags are 0 unidentified (n is 0), 1 a
//!   character and 2 a named key (the n scalar values of its characters or
//!   of its W3C UI Events `key` name), and 3 a dead key (n is 1 with its
//!   character, or 0). The physical tags are 0 unidentified (m is 0) and 1 a
//!   W3C UI Events `code` (its m scalar values).
//! - **Pointer**: `[x, y, button tag, other, modifiers, delta tag, dx, dy]`.
//!   The button tags are 0 none, 1 primary, 2 secondary, 3 middle, 4 back,
//!   5 forward and 6 another, whose number is `other` (0 for the rest). The
//!   delta tags are 0 none (with `dx` and `dy` 0), 1 lines and 2 pixels, for
//!   a wheel.
//! - **Resize**: `[width, height, scale]`.
//! - **OpenFiles**: `[n, then for each of the n paths: m, m scalars]`, a
//!   path's characters laid out as a key's names are. An empty list is `[0]`;
//!   it is encoded and read back, though no platform reports one.
//!
//! Files to open come from the window source like every input, after
//! `Opened` (`editor-platform`'s crate docs, "Files to open come after
//! `Opened`").
//!
//! The modifiers are one word of bits: shift [`MODIFIER_SHIFT`], control
//! [`MODIFIER_CONTROL`], alt [`MODIFIER_ALT`] and the system key
//! [`MODIFIER_SUPER`]. A float (a position, a delta, a scale) crosses as its
//! IEEE 754 bits ([`f64::to_bits`]); Lean reads it back with `Float.ofBits`.
//!
//! Every input takes one path onto a queue, [`arrive`], whether a window
//! reported it or it was posted. That path is where the interrupt flag is
//! raised ([`crate::interrupt`]): the flag is told of the input before the
//! event is queued, and the event of a press it counted as the interrupt
//! key carries the interrupt mark, bit 3 of its code ([`KEY_INTERRUPT`]).
//! The mark is not part of the input: [`event`] never sets it and [`input`]
//! refuses it, so `input(event(i))` is still `i`, and nothing posted can
//! carry a mark the library did not set.
//!
//! A window is run by the main-thread service: "run the window" is a request
//! of it ([`crate::main_thread::Request::RunWindow`]), so the window's loop
//! is on the process's main thread and the caller is blocked until the
//! window has closed. Rust never closes a window by itself: a window that is
//! asked to close reports `CloseRequested` and stays open until Lean calls
//! [`editor_ffi_window_close`].
//!
//! **Lean asks things of the window** with [`editor_ffi_window_request`]:
//! a platform's tag and a request's, 0 enter fullscreen, 1 leave
//! fullscreen, 2 minimise and 4 keep running, the answer to a quit the
//! system asked when the editor does not quit ([`request_of`]). It never blocks, and it goes through
//! the window's own loop ([`Platform::request`]), not the main-thread
//! service, which still answers nothing else while the window runs. No tag
//! names a title: the title is a field of the scene Lean publishes, and
//! reaches the window from the presenter ([`crate::render`], "What reaches
//! the window: the title"). What a scripted window was asked is read back
//! for tests with [`editor_ffi_window_asked`] ([`asked_words`]).
//!
//! What draws in the process's window is a render session over the
//! process's presenter ([`run_on_this_thread`], [`crate::render`]): while
//! the window is open the session's loop is the presenter's target, so a
//! display Lean bound to it is drawn in the window, at the scale the window
//! last said. On the real platform the renderer is the wgpu renderer on
//! the window, presenting as the run asked ([`asked_presentation`]); on the
//! scripted platforms, which open nothing, it is the recording fake, but for
//! [`PlatformId::ScriptedUndrawn`], whose renderer cannot be made.
//! [`run_with`] is the same run with any session, for tests, which make
//! their own presenter. A window whose renderer could not be made, or whose
//! render thread did not end well, runs all the same, with nothing drawing
//! in it; once it has closed, the run says why ([`Ran::nothing_drew`], the
//! session's failure), and [`editor_ffi_window_run`] hands that reason to
//! Lean with its own status ([`WINDOW_UNDRAWN`]).
//!
//! The process has one window, number [`WINDOW`], whose events go to the
//! editor queue stamped from one process-wide clock, which Lean reads with
//! [`editor_ffi_input_clock_now`]: the time from an event's stamp to Lean
//! handling it is then a subtraction on one clock. Which platform runs it is
//! a [`PlatformId`]. The C functions at the bottom only forward.

use std::ops::Deref;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, OnceLock};
use std::time::Instant;

use editor_platform::{
    Button, CannotOpen, Composition, Drawer, Input, Key, LogicalKey, Modifiers, NativeWindow,
    PhysicalKey, Platform, Pointer, PointerAction, Report, Request as WindowRequest, Resize,
    ScriptedPlatform, WheelDelta, WindowOptions,
};
use editor_platform_winit::WinitPlatform;
use editor_render::fake::RecordingRenderer;
use editor_render::port::{DrawRequest, Drawn, Renderer};
use editor_render_wgpu::present::{Asked, Mode, Offered};
use editor_render_wgpu::{Settings, WgpuRenderer};

use crate::events::{Event, EventKind, Queue, QueueId, Source, SourceKind};
use crate::interrupt::{INTERRUPT, Interrupt};
use crate::main_thread::{self, Reply, Request};
use crate::render::{PRESENTER, Session};
use crate::words::Reader;
use crate::{text, words};

/// The number of the process's one window: the id of the window source its
/// events come from.
pub const WINDOW: u64 = 1;

/// The bit of a key event's code that is set for a press and clear for a
/// release.
pub const KEY_PRESSED: u64 = 1;

/// The bit of a key event's code that is set for a press the platform
/// repeated because the key is held.
pub const KEY_REPEAT: u64 = 1 << 1;

/// The bit of a key event's code that is set for a dead key.
pub const KEY_DEAD: u64 = 1 << 2;

/// The bit of a key event's code that is set when the key was counted as a
/// press of the interrupt key as it arrived ([`arrive`]). It is the
/// library's mark, set after the input is encoded: no input stands for an
/// event that carries it, so [`input`] refuses it and a poster cannot forge
/// it.
pub const KEY_INTERRUPT: u64 = 1 << 3;

/// The bit of a resize event's code that is set when the window is in the
/// system's fullscreen.
pub const RESIZE_FULLSCREEN: u64 = 1;

/// The tags of a request to the window, as `editor_ffi_window_request`
/// takes them and `editor_ffi_window_asked` writes them.
const REQUEST_ENTER_FULLSCREEN: u8 = 0;
const REQUEST_LEAVE_FULLSCREEN: u8 = 1;
const REQUEST_MINIMISE: u8 = 2;
/// The tag of a title in what a scripted window was asked. No request
/// from Lean has it: the title is a field of the scene.
const REQUEST_TITLE: u64 = 3;
/// The tag of keeping running: the editor's answer to a quit the system
/// asked, when it does not quit. It is 4 and not 3, which is the title's.
const REQUEST_KEEP_RUNNING: u8 = 4;
/// The tag of a menu bar in what a scripted window was asked. No request
/// from Lean has it: the menu is a field of the scene, as the title is.
const REQUEST_MENU: u64 = 5;

/// The bit of a modifier word that is set when shift is held.
pub const MODIFIER_SHIFT: u64 = 1;

/// The bit of a modifier word that is set when control is held.
pub const MODIFIER_CONTROL: u64 = 1 << 1;

/// The bit of a modifier word that is set when alt is held.
pub const MODIFIER_ALT: u64 = 1 << 2;

/// The bit of a modifier word that is set when the system key is held.
pub const MODIFIER_SUPER: u64 = 1 << 3;

/// Every bit a modifier word may have set.
pub(crate) const MODIFIERS: u64 = MODIFIER_SHIFT | MODIFIER_CONTROL | MODIFIER_ALT | MODIFIER_SUPER;

/// The tags of a key's logical key in its words.
const LOGICAL_UNIDENTIFIED: u64 = 0;
const LOGICAL_CHARACTER: u64 = 1;
const LOGICAL_NAMED: u64 = 2;
const LOGICAL_DEAD: u64 = 3;

/// The tags of a key's physical key in its words.
const PHYSICAL_UNIDENTIFIED: u64 = 0;
const PHYSICAL_CODE: u64 = 1;

/// The codes of a pointer event.
const POINTER_PRESS: u64 = 0;
const POINTER_DRAG: u64 = 1;
const POINTER_RELEASE: u64 = 2;
const POINTER_WHEEL: u64 = 3;

/// The tag of a button the platform numbers itself; the tags before it are
/// none (0) and the named buttons, primary (1) to forward (5).
const BUTTON_OTHER: u64 = 6;

/// The tags of a wheel's delta in a pointer event's words.
const WHEEL_NONE: u64 = 0;
const WHEEL_LINES: u64 = 1;
const WHEEL_PIXELS: u64 = 2;

/// The port a window's events are stamped through.
pub trait InputClock: Send + Sync {
    /// The time, in nanoseconds since the clock began. It never goes back,
    /// and it is never 0, which in an event's stamp means no stamp.
    fn now_ns(&self) -> u64;
}

impl<C: InputClock + ?Sized> InputClock for &C {
    fn now_ns(&self) -> u64 {
        (**self).now_ns()
    }
}

impl<C: InputClock + ?Sized> InputClock for Arc<C> {
    fn now_ns(&self) -> u64 {
        (**self).now_ns()
    }
}

/// The real input clock: monotonic, and beginning the first time it is read.
#[derive(Debug, Default)]
pub struct Monotonic {
    /// When the clock was first read.
    began: OnceLock<Instant>,
}

impl Monotonic {
    /// A clock that begins when it is first read.
    pub const fn new() -> Self {
        Self {
            began: OnceLock::new(),
        }
    }
}

impl InputClock for Monotonic {
    fn now_ns(&self) -> u64 {
        let elapsed = self.began.get_or_init(Instant::now).elapsed();
        // One more than the time since the clock began, so that the first
        // reading is not 0.
        u64::try_from(elapsed.as_nanos())
            .unwrap_or(u64::MAX)
            .saturating_add(1)
    }
}

/// A fake input clock: it reads 1, then 2, then 3, each reading one more
/// than the last, so a test sees which reading an event was stamped with.
/// It is public, not `cfg(test)`, like the timer service's fake clock.
#[derive(Debug, Default)]
pub struct CountingClock {
    /// How many times the clock has been read.
    readings: AtomicU64,
}

impl CountingClock {
    /// A clock whose first reading is 1.
    pub const fn new() -> Self {
        Self {
            readings: AtomicU64::new(0),
        }
    }
}

impl InputClock for CountingClock {
    fn now_ns(&self) -> u64 {
        self.readings.fetch_add(1, Ordering::SeqCst) + 1
    }
}

/// The event that stands for `input`, said to have happened at `stamp`: the
/// table in the module docs.
///
/// The match on the port's inputs is exhaustive on purpose. This crate must
/// act on every one of them: an input with no event would never reach Lean,
/// so a new variant has to be given its kind and its code here before the
/// crate builds.
pub fn event(input: Input, stamp: u64) -> Event {
    let (kind, code, text, words) = match input {
        Input::Opened { platform } => (EventKind::WindowOpened, 0, platform, Vec::new()),
        Input::Focus(gained) => (
            EventKind::WindowFocus,
            u64::from(gained),
            String::new(),
            Vec::new(),
        ),
        Input::Key(key) => {
            let bit = |set: bool, bit: u64| if set { bit } else { 0 };
            let dead = matches!(key.logical, LogicalKey::Dead(_));
            let code =
                bit(key.pressed, KEY_PRESSED) | bit(key.repeat, KEY_REPEAT) | bit(dead, KEY_DEAD);
            let words = key_words(&key);
            (EventKind::Key, code, key.text, words)
        }
        Input::Composition(step) => {
            let (code, text) = match step {
                Composition::Enabled => (0, String::new()),
                Composition::Preedit(text) => (1, text),
                Composition::Commit(text) => (2, text),
                Composition::Disabled => (3, String::new()),
            };
            (EventKind::Composition, code, text, Vec::new())
        }
        Input::Pointer(pointer) => {
            let (code, words) = pointer_words(&pointer);
            (EventKind::Pointer, code, String::new(), words)
        }
        Input::Resized(resize) => (
            EventKind::Resize,
            if resize.fullscreen {
                RESIZE_FULLSCREEN
            } else {
                0
            },
            String::new(),
            vec![resize.width, resize.height, resize.scale.to_bits()],
        ),
        Input::OpenFiles(paths) => {
            let mut words = vec![words::word(paths.len())];
            for path in &paths {
                push_scalars(&mut words, path);
            }
            (EventKind::OpenFiles, 0, String::new(), words)
        }
        Input::CloseRequested => (EventKind::CloseRequested, 0, String::new(), Vec::new()),
        Input::QuitRequested => (EventKind::QuitRequested, 0, String::new(), Vec::new()),
        Input::Menu(command) => (EventKind::Menu, 0, command, Vec::new()),
    };
    Event {
        source: Source {
            kind: SourceKind::Window,
            id: WINDOW,
        },
        kind,
        code,
        text,
        words,
        stamp,
    }
}

/// The bits of `modifiers`, as a word ([`MODIFIER_SHIFT`] and the rest).
pub(crate) fn modifier_bits(modifiers: Modifiers) -> u64 {
    let bit = |set: bool, bit: u64| if set { bit } else { 0 };
    bit(modifiers.shift, MODIFIER_SHIFT)
        | bit(modifiers.control, MODIFIER_CONTROL)
        | bit(modifiers.alt, MODIFIER_ALT)
        | bit(modifiers.super_key, MODIFIER_SUPER)
}

/// Adds the count of the scalar values of `text`, then each of them by its
/// number.
fn push_scalars(words: &mut Vec<u64>, text: &str) {
    words.push(words::word(text.chars().count()));
    words.extend(text.chars().map(u64::from));
}

/// The words of a key: its logical key, its physical key and its modifiers
/// (the table in the module docs).
fn key_words(key: &Key) -> Vec<u64> {
    let mut words = Vec::new();
    match &key.logical {
        LogicalKey::Unidentified => words.extend([LOGICAL_UNIDENTIFIED, 0]),
        LogicalKey::Character(text) => {
            words.push(LOGICAL_CHARACTER);
            push_scalars(&mut words, text);
        }
        LogicalKey::Named(name) => {
            words.push(LOGICAL_NAMED);
            push_scalars(&mut words, name);
        }
        LogicalKey::Dead(None) => words.extend([LOGICAL_DEAD, 0]),
        LogicalKey::Dead(Some(character)) => {
            words.extend([LOGICAL_DEAD, 1, u64::from(*character)]);
        }
    }
    match &key.physical {
        PhysicalKey::Unidentified => words.extend([PHYSICAL_UNIDENTIFIED, 0]),
        PhysicalKey::Code(code) => {
            words.push(PHYSICAL_CODE);
            push_scalars(&mut words, code);
        }
    }
    words.push(modifier_bits(key.modifiers));
    words
}

/// The code and the words of a pointer event (the table in the module
/// docs).
fn pointer_words(pointer: &Pointer) -> (u64, Vec<u64>) {
    let (code, delta) = match pointer.action {
        PointerAction::Press => (POINTER_PRESS, [WHEEL_NONE, 0, 0]),
        PointerAction::Drag => (POINTER_DRAG, [WHEEL_NONE, 0, 0]),
        PointerAction::Release => (POINTER_RELEASE, [WHEEL_NONE, 0, 0]),
        PointerAction::Wheel(WheelDelta::Lines { x, y }) => {
            (POINTER_WHEEL, [WHEEL_LINES, x.to_bits(), y.to_bits()])
        }
        PointerAction::Wheel(WheelDelta::Pixels { x, y }) => {
            (POINTER_WHEEL, [WHEEL_PIXELS, x.to_bits(), y.to_bits()])
        }
    };
    let (button, other) = match pointer.button {
        None => (0, 0),
        Some(Button::Primary) => (1, 0),
        Some(Button::Secondary) => (2, 0),
        Some(Button::Middle) => (3, 0),
        Some(Button::Back) => (4, 0),
        Some(Button::Forward) => (5, 0),
        Some(Button::Other(number)) => (BUTTON_OTHER, u64::from(number)),
    };
    let words = vec![
        pointer.x.to_bits(),
        pointer.y.to_bits(),
        button,
        other,
        modifier_bits(pointer.modifiers),
        delta[0],
        delta[1],
        delta[2],
    ];
    (code, words)
}

/// The input an event of `kind` with `code`, `text` and the words in
/// `words` stands for: the inverse of [`event`], so that
/// `input(event(i))` is `i` for every input `i`.
///
/// It trusts nothing it is given (`words.rs`): `None` for a kind no
/// window reports, a code out of range, words that are not whole words, too
/// few or left over, an unknown tag, a scalar that is not a `char`, a
/// modifier bit past the system key's, words that disagree with the code (a
/// dead bit without a dead key, a wheel without a delta), or text where the
/// table has none.
pub fn input(kind: EventKind, code: u64, text: &str, words: &[u8]) -> Option<Input> {
    let mut reader = Reader::new(words)?;
    let no_text = || text.is_empty().then_some(());
    let input = match kind {
        EventKind::Quit | EventKind::Message | EventKind::Completion => return None,
        EventKind::WindowOpened => {
            (code == 0).then_some(())?;
            Input::Opened {
                platform: text.to_owned(),
            }
        }
        EventKind::WindowFocus => {
            no_text()?;
            Input::Focus(match code {
                0 => false,
                1 => true,
                _ => return None,
            })
        }
        EventKind::Key => Input::Key(read_key(&mut reader, code, text)?),
        EventKind::Composition => Input::Composition(match code {
            0 => no_text().map(|()| Composition::Enabled)?,
            1 => Composition::Preedit(text.to_owned()),
            2 => Composition::Commit(text.to_owned()),
            3 => no_text().map(|()| Composition::Disabled)?,
            _ => return None,
        }),
        EventKind::Pointer => {
            no_text()?;
            Input::Pointer(read_pointer(&mut reader, code)?)
        }
        EventKind::Resize => {
            no_text()?;
            let fullscreen = match code {
                0 => false,
                RESIZE_FULLSCREEN => true,
                _ => return None,
            };
            Input::Resized(Resize {
                width: reader.word()?,
                height: reader.word()?,
                scale: f64::from_bits(reader.word()?),
                fullscreen,
            })
        }
        EventKind::CloseRequested => {
            no_text()?;
            (code == 0).then_some(())?;
            Input::CloseRequested
        }
        EventKind::QuitRequested => {
            no_text()?;
            (code == 0).then_some(())?;
            Input::QuitRequested
        }
        EventKind::Menu => {
            (code == 0).then_some(())?;
            Input::Menu(text.to_owned())
        }
        EventKind::OpenFiles => {
            no_text()?;
            (code == 0).then_some(())?;
            // Each path is at least its count of scalars, one word.
            let count = reader.count(1)?;
            Input::OpenFiles(
                (0..count)
                    .map(|_| read_scalars(&mut reader))
                    .collect::<Option<_>>()?,
            )
        }
    };
    reader.finish()?;
    Some(input)
}

/// The modifiers the word `bits` holds; `None` with a bit past the system
/// key's.
pub(crate) fn read_modifiers(bits: u64) -> Option<Modifiers> {
    (bits & !MODIFIERS == 0).then_some(Modifiers {
        shift: bits & MODIFIER_SHIFT != 0,
        control: bits & MODIFIER_CONTROL != 0,
        alt: bits & MODIFIER_ALT != 0,
        super_key: bits & MODIFIER_SUPER != 0,
    })
}

/// The character the word `word` numbers; `None` unless it is a Unicode
/// scalar value.
fn read_char(word: u64) -> Option<char> {
    char::from_u32(u32::try_from(word).ok()?)
}

/// A count of scalars and the scalars, as a string.
fn read_scalars(reader: &mut Reader<'_>) -> Option<String> {
    let count = reader.count(1)?;
    (0..count).map(|_| read_char(reader.word()?)).collect()
}

/// A logical key's words, `[logical tag, n, n scalars]`, as the logical
/// key: the first part of a key's words, and of the interrupt key's
/// ([`crate::interrupt`]).
pub(crate) fn read_logical(reader: &mut Reader<'_>) -> Option<LogicalKey> {
    Some(match reader.word()? {
        LOGICAL_UNIDENTIFIED => (reader.word()? == 0).then_some(LogicalKey::Unidentified)?,
        LOGICAL_CHARACTER => LogicalKey::Character(read_scalars(reader)?),
        LOGICAL_NAMED => LogicalKey::Named(read_scalars(reader)?),
        LOGICAL_DEAD => LogicalKey::Dead(match reader.word()? {
            0 => None,
            1 => Some(read_char(reader.word()?)?),
            _ => return None,
        }),
        _ => return None,
    })
}

/// A key's words and its code, as the key that produced `text`. A code
/// with the interrupt mark ([`KEY_INTERRUPT`]) is refused like any bit past
/// the dead bit: the mark is the library's to set.
fn read_key(reader: &mut Reader<'_>, code: u64, text: &str) -> Option<Key> {
    let all = KEY_PRESSED | KEY_REPEAT | KEY_DEAD;
    (code & !all == 0).then_some(())?;
    let logical = read_logical(reader)?;
    let physical = match reader.word()? {
        PHYSICAL_UNIDENTIFIED => (reader.word()? == 0).then_some(PhysicalKey::Unidentified)?,
        PHYSICAL_CODE => PhysicalKey::Code(read_scalars(reader)?),
        _ => return None,
    };
    let modifiers = read_modifiers(reader.word()?)?;
    let dead = matches!(logical, LogicalKey::Dead(_));
    (dead == (code & KEY_DEAD != 0)).then_some(())?;
    Some(Key {
        pressed: code & KEY_PRESSED != 0,
        repeat: code & KEY_REPEAT != 0,
        logical,
        physical,
        modifiers,
        text: text.to_owned(),
    })
}

/// A pointer's words and its code, as the pointer.
fn read_pointer(reader: &mut Reader<'_>, code: u64) -> Option<Pointer> {
    let x = f64::from_bits(reader.word()?);
    let y = f64::from_bits(reader.word()?);
    let tag = reader.word()?;
    let other = reader.word()?;
    let button = match tag {
        0 => None,
        1 => Some(Button::Primary),
        2 => Some(Button::Secondary),
        3 => Some(Button::Middle),
        4 => Some(Button::Back),
        5 => Some(Button::Forward),
        BUTTON_OTHER => Some(Button::Other(u16::try_from(other).ok()?)),
        _ => return None,
    };
    (tag == BUTTON_OTHER || other == 0).then_some(())?;
    let modifiers = read_modifiers(reader.word()?)?;
    let delta = [reader.word()?, reader.word()?, reader.word()?];
    let (dx, dy) = (f64::from_bits(delta[1]), f64::from_bits(delta[2]));
    let action = match (code, delta[0]) {
        (POINTER_PRESS | POINTER_DRAG | POINTER_RELEASE, WHEEL_NONE) => {
            (delta[1] == 0 && delta[2] == 0).then_some(())?;
            match code {
                POINTER_PRESS => PointerAction::Press,
                POINTER_DRAG => PointerAction::Drag,
                _ => PointerAction::Release,
            }
        }
        (POINTER_WHEEL, WHEEL_LINES) => PointerAction::Wheel(WheelDelta::Lines { x: dx, y: dy }),
        (POINTER_WHEEL, WHEEL_PIXELS) => PointerAction::Wheel(WheelDelta::Pixels { x: dx, y: dy }),
        _ => return None,
    };
    Some(Pointer {
        action,
        x,
        y,
        button,
        modifiers,
    })
}

/// The arrival of `input`, said to have happened at `stamp`, on `queue`:
/// the one path a window's input takes onto a queue, whether a window
/// reported it ([`run`]) or it was posted ([`post_input`]). Returns whether
/// the event was queued: false when the queue has been quit.
///
/// `interrupt` is told of the input first ([`Interrupt::arrived`]), so the
/// flag is up before the event can be pulled. When the input counted as a
/// press of the interrupt key, the event carries the mark
/// ([`KEY_INTERRUPT`]), so whoever pulls it lowers the flag for it. An
/// event the queue refuses will never be pulled, so the flag is lowered
/// for it here.
pub fn arrive(queue: &Queue, interrupt: &Interrupt, input: Input, stamp: u64) -> bool {
    let interrupts = interrupt.arrived(&input);
    let mut event = event(input, stamp);
    if interrupts {
        event.code |= KEY_INTERRUPT;
    }
    let queued = queue.push(event);
    if interrupts && !queued {
        interrupt.lower();
    }
    queued
}

/// Reads an input of `kind` with `code`, `text` and `words` ([`input`]) and
/// has it arrive on `queue` ([`arrive`]) from the window source, stamped
/// with `clock`'s reading: what a window does when it reports that input.
/// Returns whether the event was queued: false, queueing nothing, when the
/// words do not read as an input or the queue has been quit.
pub fn post_input(
    queue: &Queue,
    interrupt: &Interrupt,
    clock: &impl InputClock,
    kind: EventKind,
    code: u64,
    text: &str,
    words: &[u8],
) -> bool {
    input(kind, code, text, words)
        .is_some_and(|input| arrive(queue, interrupt, input, clock.now_ns()))
}

/// Runs `platform`'s window on the calling thread, opened as `options` say,
/// until the platform is asked to close, and has each thing the window
/// reports arrive on `queue` ([`arrive`]), stamped with `clock`'s reading
/// when it was reported, with `interrupt` told of it first. What the window
/// tells whatever draws in it goes to `drawer`, as it is told: nothing of
/// it is queued.
///
/// Returns the platform's failure, having queued nothing, when no window
/// could be opened.
pub fn run<P, C, Q, I>(
    platform: &P,
    options: WindowOptions,
    clock: C,
    queue: Q,
    interrupt: I,
    drawer: Drawer,
) -> Result<(), CannotOpen>
where
    P: Platform + ?Sized,
    C: InputClock + 'static,
    Q: Deref<Target = Queue> + Send + Sync + 'static,
    I: Deref<Target = Interrupt> + Send + Sync + 'static,
{
    let report: Report = Arc::new(move |input| {
        // The clock is read first: the stamp is when the window reported the
        // input, not when the event was built. A queue that has been quit
        // drops the event, and there is nobody to tell.
        let stamp = clock.now_ns();
        arrive(&queue, &interrupt, input, stamp);
    });
    platform.run(options, report, drawer)
}

/// Which platform runs the process's window.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlatformId {
    /// [`ScriptedPlatform::sample`], the fake: it opens nothing and needs no
    /// display. It is reachable from Lean for the Lean test executable, as
    /// the scripted event source is.
    Scripted = 0,
    /// The real window, over winit. It needs a display, and it refuses to
    /// run anywhere but on the process's main thread: reach it through the
    /// main-thread service of an executable that started at the entry point.
    /// Nothing the gate runs names it.
    Winit = 1,
    /// [`ScriptedPlatform::failing`], the fake that cannot open a window:
    /// every run fails at once with [`SCRIPTED_FAILURE`]. It is reachable
    /// from Lean so that the Lean test executable sees a refusal cross the
    /// boundary, which the real platform gives only on a machine with no
    /// display.
    ScriptedFailing = 2,
    /// [`ScriptedPlatform::sample`] again, run on its own, whose window
    /// nothing can draw in: its renderer cannot be made, for
    /// [`SCRIPTED_NO_RENDERER`]. It is reachable from Lean so that the Lean
    /// test executable sees a window that ran with nothing drawing in it
    /// ([`Ran::nothing_drew`]), which the real platform gives on a machine
    /// with no usable GPU.
    ScriptedUndrawn = 3,
}

impl PlatformId {
    /// The number that stands for this platform across the boundary.
    pub const fn tag(self) -> u8 {
        self as u8
    }

    /// The platform `tag` stands for, if it is one.
    pub const fn from_tag(tag: u8) -> Option<Self> {
        match tag {
            0 => Some(Self::Scripted),
            1 => Some(Self::Winit),
            2 => Some(Self::ScriptedFailing),
            3 => Some(Self::ScriptedUndrawn),
            _ => None,
        }
    }

    /// The process-wide platform this names.
    fn platform(self) -> &'static dyn Platform {
        match self {
            Self::Scripted => &*SCRIPTED,
            Self::Winit => &WINIT,
            Self::ScriptedFailing => &*SCRIPTED_FAILING,
            Self::ScriptedUndrawn => &*SCRIPTED_UNDRAWN,
        }
    }

    /// The scripted platform this names, when it names one.
    pub fn scripted(self) -> Option<&'static ScriptedPlatform> {
        match self {
            Self::Scripted => Some(&*SCRIPTED),
            Self::ScriptedFailing => Some(&*SCRIPTED_FAILING),
            Self::ScriptedUndrawn => Some(&*SCRIPTED_UNDRAWN),
            Self::Winit => None,
        }
    }
}

/// Why nothing can draw in the window of [`PlatformId::ScriptedUndrawn`].
pub const SCRIPTED_NO_RENDERER: &str = "the scripted platform's window has no renderer: pas de GPU";

/// Why [`PlatformId::ScriptedFailing`] cannot open a window. "é" is two
/// bytes, so a caller that took the reason's length in characters would get
/// it cut.
pub const SCRIPTED_FAILURE: &str = "the scripted platform opens no window: pas d'écran";

/// The process's input clock.
static CLOCK: Monotonic = Monotonic::new();

/// The process's input clock as a value: what the process's render loops
/// tell the time by, so that a journal entry's time from an input to its
/// frame is a subtraction on the clock that stamped the input.
#[derive(Debug, Clone, Copy, Default)]
pub struct ProcessClock;

impl InputClock for ProcessClock {
    fn now_ns(&self) -> u64 {
        CLOCK.now_ns()
    }
}

/// The process's scripted platform, made the first time it is asked for.
static SCRIPTED: LazyLock<ScriptedPlatform> = LazyLock::new(ScriptedPlatform::sample);

/// The process's scripted platform that cannot open a window, made the first
/// time it is asked for.
static SCRIPTED_FAILING: LazyLock<ScriptedPlatform> =
    LazyLock::new(|| ScriptedPlatform::failing(SCRIPTED_FAILURE));

/// The process's scripted platform whose window nothing can draw in, made
/// the first time it is asked for. It is a platform of its own, so that a
/// close of it is not a close of [`SCRIPTED`]'s window.
static SCRIPTED_UNDRAWN: LazyLock<ScriptedPlatform> = LazyLock::new(ScriptedPlatform::sample);

/// The process's real platform. It opens nothing until it is run.
static WINIT: WinitPlatform = WinitPlatform::new(main_thread::is_main_thread);

/// How a window that opened ran, once it has closed.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Ran {
    /// Why nothing drew in the window, when nothing did: the renderer could
    /// not be made, or the render thread could not be started or did not
    /// end well ([`Session::failure`]). The window ran all the same, and
    /// what it reported reached the queue.
    pub nothing_drew: Option<String>,
}

/// [`run`], with `session` drawing in the window: the session is told
/// everything the window tells whatever draws in it, so its loop is its
/// presenter's target while the window is open (`crate::render::Session`).
/// A window that ran says, once it has closed, why nothing drew in it when
/// nothing did ([`Ran`]).
pub fn run_with<P, C, Q, I, R>(
    platform: &P,
    options: WindowOptions,
    clock: C,
    queue: Q,
    interrupt: I,
    session: &Session<R>,
) -> Result<Ran, CannotOpen>
where
    P: Platform + ?Sized,
    C: InputClock + 'static,
    Q: Deref<Target = Queue> + Send + Sync + 'static,
    I: Deref<Target = Interrupt> + Send + Sync + 'static,
    R: Renderer + Send + 'static,
{
    run(platform, options, clock, queue, interrupt, session.drawer())?;
    Ok(Ran {
        nothing_drew: session.failure(),
    })
}

/// Where a window's renderer leaves what its surface offered, what the run
/// asked for and what the surface was configured with
/// ([`WgpuRenderer::presentation`]), after each draw: so that it can be
/// read once the window has closed and the renderer is gone. The
/// process's is [`PRESENTATION`]; a test makes its own.
#[derive(Debug, Default)]
pub(crate) struct PresentationSlot(std::sync::Mutex<Option<Offered>>);

impl PresentationSlot {
    /// Keeps `offered`, when there is one; a renderer that says nothing
    /// leaves what was kept.
    fn write(&self, offered: Option<Offered>) {
        if offered.is_some() {
            *self
                .0
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = offered;
        }
    }

    /// What was kept last, if a renderer has said anything.
    pub(crate) fn read(&self) -> Option<Offered> {
        self.0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }
}

/// What the process's window's renderer left of its surface's
/// presentation, which [`editor_ffi_window_presentation`] reads. Only
/// [`run_on_this_thread`] hands it to a renderer.
static PRESENTATION: LazyLock<PresentationSlot> = LazyLock::new(PresentationSlot::default);

/// The tag a present mode crosses the boundary as: the one a run asks for
/// it by ([`asked_presentation`]).
fn mode_tag(mode: Mode) -> u64 {
    match mode {
        Mode::Fifo => 1,
        Mode::FifoRelaxed => 2,
        Mode::Immediate => 3,
        Mode::Mailbox => 4,
    }
}

/// `offered` as words: how many modes the surface offered and each one's
/// tag ([`mode_tag`]), in its order; then the tag of the mode the run asked
/// for and the latency it asked for, each 0 when it asked for none; then
/// the mode's tag and the latency the surface was configured with.
fn offered_words(offered: &Offered) -> Vec<u64> {
    let mut words = vec![offered.modes.len() as u64];
    words.extend(offered.modes.iter().map(|mode| mode_tag(*mode)));
    words.extend([
        offered.asked.mode.map_or(0, mode_tag),
        offered.asked.frame_latency.map_or(0, u64::from),
    ]);
    words.extend([
        mode_tag(offered.configured.mode),
        u64::from(offered.configured.frame_latency),
    ]);
    words
}

/// What the process's window's surface offered, what its run asked for and
/// what it was configured with, as words ([`offered_words`]), from the
/// latest window that drew with the wgpu renderer, read after it has
/// closed too. The status is 1, with no words, when none has.
///
/// # Safety
///
/// `out` points to a writable [`RawWords`](crate::log::RawWords).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_window_presentation(out: *mut crate::log::RawWords) {
    let raw = match PRESENTATION.read() {
        None => crate::log::RawWords::with_status(1, Vec::new()),
        Some(offered) => {
            let offered = offered_words(&offered);
            let mut writer = words::Writer::with_capacity(offered.len());
            for word in offered {
                writer.word(word);
            }
            crate::log::RawWords::with_status(0, writer.finish())
        }
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
}

/// What draws in the process's window: the recording fake on the scripted
/// platforms, which open no window, and the wgpu renderer in a real one,
/// which leaves what its surface offered in a slot after each draw.
enum WindowRenderer<'a> {
    /// The fake.
    Recording(RecordingRenderer),
    /// The real renderer, on the window, and where it leaves what its
    /// surface offered.
    Wgpu(Box<WgpuRenderer>, &'a PresentationSlot),
}

impl Renderer for WindowRenderer<'_> {
    fn draw(&mut self, request: &DrawRequest<'_>) -> Drawn {
        match self {
            Self::Recording(renderer) => renderer.draw(request),
            Self::Wgpu(renderer, slot) => {
                let drawn = renderer.draw(request);
                slot.write(renderer.presentation());
                drawn
            }
        }
    }
}

/// The renderer for the process's window on `platform`, presenting as
/// `presentation` asks: the recording fake for a scripted platform, none
/// for the one whose window nothing can draw in, and the wgpu renderer on
/// the native window for the real one, in the platform's weight of text
/// (Core Text's on macOS).
fn window_renderer<'a>(
    platform: PlatformId,
    window: Option<&NativeWindow>,
    presentation: Asked,
    slot: &'a PresentationSlot,
) -> Result<WindowRenderer<'a>, String> {
    match platform {
        PlatformId::Scripted | PlatformId::ScriptedFailing => {
            Ok(WindowRenderer::Recording(RecordingRenderer::new()))
        }
        PlatformId::ScriptedUndrawn => Err(SCRIPTED_NO_RENDERER.to_owned()),
        PlatformId::Winit => {
            let window = window.ok_or("the platform named no native window to draw in")?;
            let base = if cfg!(target_os = "macos") {
                Settings::core_text()
            } else {
                Settings::default()
            };
            let settings = Settings {
                presentation,
                ..base
            };
            // SAFETY: the window port tells of `window` when it opens, on
            // this thread, and it stays live until the drawer returns from
            // being told the window is closing. The session drops this
            // renderer, on this thread, while it is being told so.
            #[expect(
                clippy::disallowed_methods,
                reason = "the process's window draws with the wgpu renderer; no test runs the winit platform"
            )]
            let made = unsafe { WgpuRenderer::on_window(window, settings) };
            made.map(|renderer| WindowRenderer::Wgpu(Box::new(renderer), slot))
                .map_err(|error| error.to_string())
        }
    }
}

/// Runs the process's window on the calling thread, on the platform
/// `platform`, onto the editor queue, with a session over the process's
/// presenter drawing in it what bound displays publish, and says once it
/// has closed why nothing drew in it, when nothing did ([`run_with`]). This
/// is what the main-thread service does for [`Request::RunWindow`].
pub(crate) fn run_on_this_thread(
    platform: PlatformId,
    options: WindowOptions,
    presentation: Asked,
) -> Result<Ran, CannotOpen> {
    let session = Session::new(
        Arc::new(ProcessClock),
        move |window, _| window_renderer(platform, window, presentation, &PRESENTATION),
        Arc::clone(&PRESENTER),
    )
    .asking(Arc::new(move |request| {
        platform.platform().request(request)
    }));
    run_with(
        platform.platform(),
        options,
        &CLOCK,
        QueueId::Editor.queue(),
        &INTERRUPT,
        &session,
    )
}

/// The presentation a run asks for, from its tags as they cross the
/// boundary: `mode` 0 for none, then `fifo`, `fifo-relaxed`, `immediate`
/// and `mailbox` from 1; and `frame_latency` 0 for none. Each half not
/// asked for is left to the renderer's decision
/// (`editor_render_wgpu::present::choose`), which this does not restate. A
/// mode tag that names no mode asks for nothing.
pub fn asked_presentation(mode: u8, frame_latency: u32) -> Asked {
    let mode = match mode {
        0 => None,
        1 => Some(Mode::Fifo),
        2 => Some(Mode::FifoRelaxed),
        3 => Some(Mode::Immediate),
        4 => Some(Mode::Mailbox),
        _ => return Asked::NOTHING,
    };
    Asked {
        mode,
        frame_latency: (frame_latency != 0).then_some(frame_latency),
    }
}

/// Why a window did not run, or why nothing drew in one that did, as it
/// crosses the boundary: one record, filled in one call.
#[repr(C)]
pub struct RawRefusal {
    /// The reason: a buffer of `reason_len` bytes of UTF-8, owned by the
    /// caller until it is handed back with
    /// [`crate::text::editor_ffi_text_free`].
    pub reason: *mut u8,
    /// The length of `reason` in bytes.
    pub reason_len: usize,
}

/// What [`editor_ffi_window_run`] returns when the window ran and something
/// drew in it.
pub const WINDOW_RAN: u8 = 0;

/// What [`editor_ffi_window_run`] returns when no window ran.
pub const WINDOW_REFUSED: u8 = 1;

/// What [`editor_ffi_window_run`] returns when the window ran but nothing
/// drew in it ([`Ran::nothing_drew`]).
pub const WINDOW_UNDRAWN: u8 = 2;

/// Runs the process's window on the platform `platform`, with composition
/// allowed or not, and blocks the calling thread until the window has
/// closed: the main-thread service runs it. Returns how it went:
///
/// - [`WINDOW_RAN`] when the window ran and something drew in it. `out` is
///   left alone.
/// - [`WINDOW_REFUSED`], with `out` filled with the reason, when `platform`
///   names no platform or the platform could not open a window.
/// - [`WINDOW_UNDRAWN`], with `out` filled with the reason, when the window
///   ran but nothing drew in it: its renderer could not be made, or the
///   render thread did not end well.
///
/// While the window runs the main-thread service answers nothing else.
///
/// # Safety
///
/// `out` points to a writable [`RawRefusal`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_window_run(
    platform: u8,
    composition: bool,
    present_mode: u8,
    frame_latency: u32,
    out: *mut RawRefusal,
) -> u8 {
    let (status, reason) = match PlatformId::from_tag(platform) {
        None => (
            WINDOW_REFUSED,
            "the Rust library knows no such platform".to_owned(),
        ),
        Some(platform) => {
            let options = WindowOptions { composition };
            let presentation = asked_presentation(present_mode, frame_latency);
            let request = Request::RunWindow {
                platform,
                options,
                presentation,
            };
            match main_thread::request(request) {
                Reply::WindowClosed(Ok(Ran { nothing_drew: None })) => return WINDOW_RAN,
                Reply::WindowClosed(Ok(Ran {
                    nothing_drew: Some(reason),
                })) => (WINDOW_UNDRAWN, reason),
                Reply::WindowClosed(Err(cannot_open)) => (WINDOW_REFUSED, cannot_open.reason),
                Reply::OnMainThread(_) => (
                    WINDOW_REFUSED,
                    "the main-thread service answered another request".to_owned(),
                ),
            }
        }
    };
    let (reason, reason_len) = text::lend(reason);
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(RawRefusal { reason, reason_len }) };
    status
}

/// Asks the window the platform `platform` is running to close, from any
/// thread, and returns whether `platform` names a platform. It does nothing
/// when that platform runs no window.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_window_close(platform: u8) -> bool {
    let Some(platform) = PlatformId::from_tag(platform) else {
        return false;
    };
    platform.platform().close();
    true
}

/// The request Lean's tag `tag` names: 0 enter fullscreen, 1 leave
/// fullscreen, 2 minimise, 4 keep running. No tag names a title, so 3
/// names nothing.
pub fn request_of(tag: u8) -> Option<WindowRequest> {
    match tag {
        REQUEST_ENTER_FULLSCREEN => Some(WindowRequest::EnterFullscreen),
        REQUEST_LEAVE_FULLSCREEN => Some(WindowRequest::LeaveFullscreen),
        REQUEST_MINIMISE => Some(WindowRequest::Minimise),
        REQUEST_KEEP_RUNNING => Some(WindowRequest::KeepRunning),
        _ => None,
    }
}

/// Asks the window the platform `platform` is running to do what the
/// request tagged `request` names ([`request_of`]), from any thread, and
/// returns whether both tags name something. It never blocks: the request
/// goes through the window's own loop, not the main-thread service. It
/// does nothing when that platform runs no window.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_window_request(platform: u8, request: u8) -> bool {
    let (Some(platform), Some(request)) = (PlatformId::from_tag(platform), request_of(request))
    else {
        return false;
    };
    platform.platform().request(request);
    true
}

/// The words of what a window was asked, oldest first: for each request its
/// tag, for a title the tag 3 followed by the count and the scalar values
/// of its characters, and for a menu bar the tag 5 followed by its layout
/// ([`crate::menu`]), each text in it written as a title's is.
///
/// The match on [`WindowRequest`] is exhaustive on purpose: this crate must
/// give every variant its words, since a request with none could not be
/// read back by Lean's tests, and a new one would cross unseen.
pub fn asked_words(asked: &[WindowRequest]) -> Vec<u64> {
    use crate::menu::Sink;
    /// The words, with each text as its count and its scalar values.
    struct Asked(Vec<u64>);
    impl Sink for Asked {
        fn word(&mut self, word: u64) {
            self.0.push(word);
        }
        fn text(&mut self, text: &str) {
            push_scalars(&mut self.0, text);
        }
    }
    let mut words = Asked(Vec::new());
    for request in asked {
        match request {
            WindowRequest::EnterFullscreen => words.word(u64::from(REQUEST_ENTER_FULLSCREEN)),
            WindowRequest::LeaveFullscreen => words.word(u64::from(REQUEST_LEAVE_FULLSCREEN)),
            WindowRequest::Minimise => words.word(u64::from(REQUEST_MINIMISE)),
            WindowRequest::KeepRunning => words.word(u64::from(REQUEST_KEEP_RUNNING)),
            WindowRequest::Title(title) => {
                words.word(REQUEST_TITLE);
                words.text(title);
            }
            WindowRequest::Menu(menu) => {
                words.word(REQUEST_MENU);
                crate::menu::write(&mut words, menu);
            }
        }
    }
    words.0
}

/// Writes to `out` what the scripted window of `platform` was asked in its
/// latest run ([`ScriptedPlatform::asked`]): status 0 and the words of
/// [`asked_words`]. For the real platform, which records nothing, and for
/// a tag that names no platform, status 1 and no words. For tests.
///
/// # Safety
///
/// `out` points to a writable [`RawWords`](crate::log::RawWords).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_window_asked(platform: u8, out: *mut crate::log::RawWords) {
    let scripted = PlatformId::from_tag(platform).and_then(PlatformId::scripted);
    let raw = match scripted {
        None => crate::log::RawWords::with_status(1, Vec::new()),
        Some(scripted) => {
            let asked = asked_words(&scripted.asked());
            let mut writer = words::Writer::with_capacity(asked.len());
            for word in asked {
                writer.word(word);
            }
            crate::log::RawWords::with_status(0, writer.finish())
        }
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
}

/// Posts to the editor queue the event the process's window would push if
/// it reported the input that an event of the kind tagged `kind`, with
/// `code`, `text` and `words`, stands for ([`input`]): from the window
/// source, stamped on the process's input clock. It takes the same encoding
/// path a real window does, for tests and for the headless driver.
///
/// Returns false, queueing nothing, if `kind` names no kind, if the words
/// do not read as an input of that kind, or if the queue has been quit.
/// `text` is read as an event's posted text is (U+FFFD for each invalid
/// sequence).
///
/// # Safety
///
/// `text` points to `text_len` readable bytes, and `words` to `words_len`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_window_post_input(
    kind: u8,
    code: u64,
    text: *const u8,
    text_len: usize,
    words: *const u8,
    words_len: usize,
) -> bool {
    let Some(kind) = EventKind::from_tag(u64::from(kind)) else {
        return false;
    };
    // SAFETY: the caller guarantees both pointers and their lengths.
    let (text, words) = unsafe {
        (
            text::borrow(text, text_len),
            words::borrow(words, words_len),
        )
    };
    post_input(
        QueueId::Editor.queue(),
        &INTERRUPT,
        &CLOCK,
        kind,
        code,
        &text,
        words,
    )
}

/// The time on the process's input clock, in nanoseconds since the clock
/// began. It never goes back and is never 0.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_input_clock_now() -> u64 {
    CLOCK.now_ns()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::display::Display;
    use crate::interrupt::InterruptKey;
    use crate::render::{Presenter, Session};
    use editor_platform::no_drawer;
    use editor_platform::{
        Button, Canvas, Key, LogicalKey, Modifiers, PhysicalKey, Pointer, PointerAction, Resize,
        WheelDelta,
    };
    use editor_render_wgpu::present::Presentation;
    use std::sync::mpsc::{self, Receiver};
    use std::thread;
    use std::time::Duration;

    /// How long a test waits for something that should happen at once. Only
    /// broken code takes this long, and the test then fails instead of
    /// hanging.
    const DEADLINE: Duration = Duration::from_secs(5);

    /// An event from the window, as it should arrive.
    fn from_window(kind: EventKind, code: u64, text: &str, stamp: u64) -> Event {
        Event {
            source: Source {
                kind: SourceKind::Window,
                id: WINDOW,
            },
            kind,
            code,
            text: text.into(),
            words: Vec::new(),
            stamp,
        }
    }

    /// A key event, of a dead key or of one the platform could not identify.
    fn key(pressed: bool, repeat: bool, dead: bool, text: &str) -> Input {
        Input::Key(Key {
            pressed,
            repeat,
            logical: if dead {
                LogicalKey::Dead(None)
            } else {
                LogicalKey::Unidentified
            },
            text: text.into(),
            ..Key::unidentified()
        })
    }

    /// A press of the primary button at the origin, with no modifier.
    fn pointer_press() -> Input {
        Input::Pointer(Pointer {
            action: PointerAction::Press,
            x: 0.0,
            y: 0.0,
            button: Some(Button::Primary),
            modifiers: Modifiers::default(),
        })
    }

    /// Starts [`run`] of `platform` on a thread of its own, onto `queue`,
    /// stamped by a clock that counts its readings, with an interrupt flag
    /// of its own that has no key, and returns where its result arrives.
    /// The thread is detached, so a run that never returns cannot keep the
    /// test from ending.
    fn start(
        platform: &Arc<ScriptedPlatform>,
        options: WindowOptions,
        queue: &Arc<Queue>,
    ) -> Receiver<Result<(), CannotOpen>> {
        start_watched(platform, options, queue, &Arc::new(Interrupt::new()))
    }

    /// [`start`], with `interrupt` as the flag the run tells of each input.
    fn start_watched(
        platform: &Arc<ScriptedPlatform>,
        options: WindowOptions,
        queue: &Arc<Queue>,
        interrupt: &Arc<Interrupt>,
    ) -> Receiver<Result<(), CannotOpen>> {
        let (finished, done) = mpsc::channel();
        let platform = Arc::clone(platform);
        let queue = Arc::clone(queue);
        let interrupt = Arc::clone(interrupt);
        thread::spawn(move || {
            let _ = finished.send(run(
                &*platform,
                options,
                CountingClock::new(),
                queue,
                interrupt,
                no_drawer(),
            ));
        });
        done
    }

    /// The next `count` events of `queue`; panics if they do not arrive by
    /// the deadline.
    fn pull(queue: &Arc<Queue>, count: usize) -> Vec<Event> {
        let (pulled, events) = mpsc::channel();
        let queue = Arc::clone(queue);
        thread::spawn(move || {
            for _ in 0..count {
                let _ = pulled.send(queue.next());
            }
        });
        (0..count)
            .map(|_| {
                events
                    .recv_timeout(DEADLINE)
                    .expect("the window's next event reaches the queue")
            })
            .collect()
    }

    #[test]
    fn each_input_becomes_its_event_in_order_stamped_with_the_clock_when_it_was_reported() {
        let script = vec![
            Input::Focus(true),
            Input::Focus(false),
            key(true, false, false, "a"),
            key(false, false, false, ""),
            key(true, true, false, "a"),
            key(true, false, true, ""),
            Input::Composition(Composition::Enabled),
            Input::Composition(Composition::Preedit("´".into())),
            Input::Composition(Composition::Commit("é".into())),
            Input::Composition(Composition::Disabled),
            pointer_press(),
            Input::Resized(Resize {
                width: 800,
                height: 600,
                scale: 2.0,
                fullscreen: false,
            }),
            Input::CloseRequested,
        ];
        let platform = Arc::new(ScriptedPlatform::new(script));
        let queue = Arc::new(Queue::new());

        let done = start(&platform, WindowOptions::default(), &queue);

        // The stamps are the clock's readings 1, 2, 3 and so on: one reading
        // for each input, taken as it was reported. The words of each event
        // are left out here: the tests of `event` pin them.
        let pulled: Vec<Event> = pull(&queue, 14)
            .into_iter()
            .map(|event| event.with_words(Vec::new()))
            .collect();
        assert_eq!(
            pulled,
            [
                from_window(EventKind::WindowOpened, 0, ScriptedPlatform::NAME, 1),
                from_window(EventKind::WindowFocus, 1, "", 2),
                from_window(EventKind::WindowFocus, 0, "", 3),
                from_window(EventKind::Key, KEY_PRESSED, "a", 4),
                from_window(EventKind::Key, 0, "", 5),
                from_window(EventKind::Key, KEY_PRESSED | KEY_REPEAT, "a", 6),
                from_window(EventKind::Key, KEY_PRESSED | KEY_DEAD, "", 7),
                from_window(EventKind::Composition, 0, "", 8),
                from_window(EventKind::Composition, 1, "´", 9),
                from_window(EventKind::Composition, 2, "é", 10),
                from_window(EventKind::Composition, 3, "", 11),
                from_window(EventKind::Pointer, 0, "", 12),
                from_window(EventKind::Resize, 0, "", 13),
                from_window(EventKind::CloseRequested, 0, "", 14),
            ]
        );
        platform.close();
        assert_eq!(done.recv_timeout(DEADLINE), Ok(Ok(())));
    }

    #[test]
    fn the_bits_of_a_key_events_code_are_one_two_and_four() {
        assert_eq!((KEY_PRESSED, KEY_REPEAT, KEY_DEAD), (1, 2, 4));
    }

    /// The kind, the code, the text and the words of the event `input` is.
    fn encoded(input: Input) -> (EventKind, u64, String, Vec<u64>) {
        let event = event(input, 0);
        (event.kind, event.code, event.text, event.words)
    }

    /// The modifiers with exactly these held.
    fn held(shift: bool, control: bool, alt: bool, super_key: bool) -> Modifiers {
        Modifiers {
            shift,
            control,
            alt,
            super_key,
        }
    }

    /// The bits of a float, as they cross.
    fn bits(value: f64) -> u64 {
        value.to_bits()
    }

    #[test]
    fn the_bits_of_the_modifiers_are_one_two_four_and_eight() {
        assert_eq!(
            (
                MODIFIER_SHIFT,
                MODIFIER_CONTROL,
                MODIFIER_ALT,
                MODIFIER_SUPER
            ),
            (1, 2, 4, 8)
        );
    }

    #[test]
    fn a_character_key_is_its_characters_its_code_and_its_modifiers() {
        let input = Input::Key(Key {
            pressed: true,
            repeat: false,
            logical: LogicalKey::Character("a".into()),
            physical: PhysicalKey::Code("KeyA".into()),
            modifiers: held(true, true, false, false),
            text: "a".into(),
        });

        assert_eq!(
            encoded(input),
            (
                EventKind::Key,
                KEY_PRESSED,
                "a".into(),
                vec![1, 1, 97, 1, 4, 75, 101, 121, 65, 3]
            )
        );
    }

    #[test]
    fn a_character_of_several_scalars_is_each_of_them_by_its_number() {
        let input = Input::Key(Key {
            pressed: true,
            logical: LogicalKey::Character("é😀".into()),
            ..Key::unidentified()
        });

        assert_eq!(encoded(input).3, vec![1, 2, 0xE9, 0x1F600, 0, 0, 0]);
    }

    #[test]
    fn a_named_key_is_its_name_and_a_repeat_with_every_modifier_sets_every_bit() {
        let input = Input::Key(Key {
            pressed: true,
            repeat: true,
            logical: LogicalKey::Named("Escape".into()),
            physical: PhysicalKey::Code("Escape".into()),
            modifiers: held(true, true, true, true),
            text: String::new(),
        });
        let escape: Vec<u64> = "Escape".chars().map(u64::from).collect();
        let mut words = vec![2, 6];
        words.extend(&escape);
        words.extend([1, 6]);
        words.extend(&escape);
        words.push(15);

        assert_eq!(
            encoded(input),
            (
                EventKind::Key,
                KEY_PRESSED | KEY_REPEAT,
                String::new(),
                words
            )
        );
    }

    #[test]
    fn a_dead_key_is_tag_three_with_its_character_or_none_and_sets_the_dead_bit() {
        let dead = |character| {
            Input::Key(Key {
                pressed: true,
                logical: LogicalKey::Dead(character),
                ..Key::unidentified()
            })
        };

        assert_eq!(
            encoded(dead(Some('´'))),
            (
                EventKind::Key,
                KEY_PRESSED | KEY_DEAD,
                String::new(),
                vec![3, 1, 0xB4, 0, 0, 0]
            )
        );
        assert_eq!(
            encoded(dead(None)),
            (
                EventKind::Key,
                KEY_PRESSED | KEY_DEAD,
                String::new(),
                vec![3, 0, 0, 0, 0]
            )
        );
    }

    #[test]
    fn an_unidentified_key_is_tag_zero_twice_and_no_modifier() {
        assert_eq!(
            encoded(Input::Key(Key::unidentified())),
            (EventKind::Key, 0, String::new(), vec![0, 0, 0, 0, 0])
        );
    }

    #[test]
    fn each_pointer_action_is_its_code_with_the_position_the_button_and_the_modifiers() {
        let pointer = |action, button| {
            Input::Pointer(Pointer {
                action,
                x: 12.5,
                y: -3.25,
                button,
                modifiers: held(false, false, true, false),
            })
        };
        let words = |button: u64, other: u64, delta: [u64; 3]| {
            vec![
                bits(12.5),
                bits(-3.25),
                button,
                other,
                4,
                delta[0],
                delta[1],
                delta[2],
            ]
        };

        assert_eq!(
            encoded(pointer(PointerAction::Press, Some(Button::Primary))),
            (EventKind::Pointer, 0, String::new(), words(1, 0, [0, 0, 0]))
        );
        assert_eq!(
            encoded(pointer(PointerAction::Drag, Some(Button::Secondary))),
            (EventKind::Pointer, 1, String::new(), words(2, 0, [0, 0, 0]))
        );
        assert_eq!(
            encoded(pointer(PointerAction::Release, Some(Button::Middle))),
            (EventKind::Pointer, 2, String::new(), words(3, 0, [0, 0, 0]))
        );
        assert_eq!(
            encoded(pointer(
                PointerAction::Wheel(WheelDelta::Lines { x: 0.0, y: -1.5 }),
                None
            )),
            (
                EventKind::Pointer,
                3,
                String::new(),
                words(0, 0, [1, bits(0.0), bits(-1.5)])
            )
        );
        assert_eq!(
            encoded(pointer(
                PointerAction::Wheel(WheelDelta::Pixels { x: 7.0, y: 0.5 }),
                None
            )),
            (
                EventKind::Pointer,
                3,
                String::new(),
                words(0, 0, [2, bits(7.0), bits(0.5)])
            )
        );
    }

    #[test]
    fn each_button_is_its_tag_and_another_button_carries_its_number() {
        let button = |button| {
            encoded(Input::Pointer(Pointer {
                action: PointerAction::Press,
                x: 0.0,
                y: 0.0,
                button: Some(button),
                modifiers: Modifiers::default(),
            }))
            .3[2..4]
                .to_vec()
        };

        assert_eq!(button(Button::Primary), [1, 0]);
        assert_eq!(button(Button::Secondary), [2, 0]);
        assert_eq!(button(Button::Middle), [3, 0]);
        assert_eq!(button(Button::Back), [4, 0]);
        assert_eq!(button(Button::Forward), [5, 0]);
        assert_eq!(button(Button::Other(9)), [6, 9]);
    }

    #[test]
    fn a_resize_is_its_width_its_height_and_the_bits_of_its_scale() {
        assert_eq!(
            encoded(Input::Resized(Resize {
                width: 800,
                height: 600,
                scale: 2.0,
                fullscreen: false,
            })),
            (
                EventKind::Resize,
                0,
                String::new(),
                vec![800, 600, bits(2.0)]
            )
        );
    }

    #[test]
    fn a_resize_in_fullscreen_sets_bit_zero_of_its_code() {
        assert_eq!(RESIZE_FULLSCREEN, 1);
        assert_eq!(
            encoded(Input::Resized(Resize {
                width: 1440,
                height: 900,
                scale: 2.0,
                fullscreen: true,
            })),
            (
                EventKind::Resize,
                RESIZE_FULLSCREEN,
                String::new(),
                vec![1440, 900, bits(2.0)]
            )
        );
    }

    #[test]
    fn files_to_open_cross_as_their_count_then_each_paths_scalars() {
        assert_eq!(
            encoded(Input::OpenFiles(vec!["a".into(), "bé".into()])),
            (
                EventKind::OpenFiles,
                0,
                String::new(),
                vec![2, 1, 97, 2, 98, 233]
            )
        );
        assert_eq!(EventKind::OpenFiles.tag(), 10);
    }

    #[test]
    fn files_to_open_with_text_a_code_too_few_or_left_over_words_or_a_scalar_that_is_no_char_are_refused()
     {
        let words = [2, 1, 97, 2, 98, 233];
        assert_eq!(
            read(EventKind::OpenFiles, 0, "", &words),
            Some(Input::OpenFiles(vec!["a".into(), "bé".into()]))
        );
        assert_eq!(read(EventKind::OpenFiles, 0, "x", &words), None);
        assert_eq!(read(EventKind::OpenFiles, 1, "", &words), None);
        // A count of paths past the words, and one of scalars past them.
        assert_eq!(read(EventKind::OpenFiles, 0, "", &[2, 1, 97]), None);
        assert_eq!(read(EventKind::OpenFiles, 0, "", &[u64::MAX]), None);
        assert_eq!(read(EventKind::OpenFiles, 0, "", &[1, 5, 97]), None);
        // A word left over, and a scalar that is no character.
        assert_eq!(read(EventKind::OpenFiles, 0, "", &[1, 1, 97, 5]), None);
        assert_eq!(read(EventKind::OpenFiles, 0, "", &[1, 1, 0xD800]), None);
    }

    #[test]
    fn each_request_is_its_tag_and_an_unknown_tag_is_refused() {
        assert_eq!(request_of(0), Some(WindowRequest::EnterFullscreen));
        assert_eq!(request_of(1), Some(WindowRequest::LeaveFullscreen));
        assert_eq!(request_of(2), Some(WindowRequest::Minimise));
        // No tag names a title: Lean never asks for one.
        assert_eq!(request_of(3), None);
        assert_eq!(request_of(4), Some(WindowRequest::KeepRunning));
        assert_eq!(request_of(5), None);
        assert_eq!(request_of(u8::MAX), None);
    }

    #[test]
    fn a_request_to_a_platform_tag_that_names_none_is_refused() {
        assert!(!editor_ffi_window_request(4, 0));
        assert!(!editor_ffi_window_request(u8::MAX, 0));
        // A platform that names one, with a request that names none.
        assert!(!editor_ffi_window_request(
            PlatformId::ScriptedFailing.tag(),
            3
        ));
        // Both name something: asked of a platform that runs no window, it
        // does nothing.
        assert!(editor_ffi_window_request(
            PlatformId::ScriptedFailing.tag(),
            0
        ));
    }

    /// What `editor_ffi_window_asked` writes for the platform tagged `tag`:
    /// its status and its words.
    fn asked_of(tag: u8) -> (u64, Vec<u64>) {
        let mut raw = std::mem::MaybeUninit::<crate::log::RawWords>::uninit();
        // SAFETY: `raw` is writable.
        unsafe { editor_ffi_window_asked(tag, raw.as_mut_ptr()) };
        // SAFETY: the library filled it.
        let raw = unsafe { raw.assume_init() };
        // SAFETY: the buffer is `len` bytes, owned here until handed back.
        let bytes = unsafe { std::slice::from_raw_parts(raw.words, raw.len) }.to_vec();
        // SAFETY: the buffer came from the library, and is handed back once.
        unsafe { crate::text::editor_ffi_text_free(raw.words, raw.len) };
        let (words, rest) = bytes.as_chunks::<8>();
        assert!(rest.is_empty(), "whole words");
        (
            raw.status,
            words.iter().copied().map(u64::from_le_bytes).collect(),
        )
    }

    #[test]
    fn what_a_scripted_window_was_asked_crosses_as_tags_and_a_titles_characters() {
        assert_eq!(
            asked_words(&[
                WindowRequest::EnterFullscreen,
                WindowRequest::Minimise,
                WindowRequest::Title("é😀".into()),
                WindowRequest::LeaveFullscreen,
                WindowRequest::Title(String::new()),
                WindowRequest::KeepRunning,
            ]),
            [0, 2, 3, 2, 0xe9, 0x1_f600, 1, 3, 0, 4]
        );
        // A scripted platform answers what its latest run was asked: this
        // one has never run.
        assert_eq!(asked_of(PlatformId::ScriptedFailing.tag()), (0, vec![]));
        // The real platform records nothing, and a tag that names none is
        // no platform.
        assert_eq!(asked_of(PlatformId::Winit.tag()), (1, vec![]));
        assert_eq!(asked_of(4), (1, vec![]));
    }

    #[test]
    fn every_other_input_has_no_words() {
        for input in [
            Input::Opened {
                platform: "scripted".into(),
            },
            Input::Focus(true),
            Input::Composition(Composition::Preedit("´".into())),
            Input::CloseRequested,
            Input::QuitRequested,
        ] {
            assert_eq!(encoded(input).3, Vec::<u64>::new());
        }
    }

    #[test]
    fn a_menu_choice_crosses_as_kind_12_code_0_with_its_name_as_the_text() {
        assert_eq!(
            encoded(Input::Menu("undo".into())),
            (EventKind::Menu, 0, "undo".to_owned(), vec![])
        );
        assert_eq!(EventKind::Menu.tag(), 12);
        assert_eq!(
            read(EventKind::Menu, 0, "undo", &[]),
            Some(Input::Menu("undo".into()))
        );
        assert_eq!(
            read(EventKind::Menu, 0, "", &[]),
            Some(Input::Menu(String::new())),
            "an empty name crosses as it is"
        );
        assert_eq!(read(EventKind::Menu, 1, "undo", &[]), None);
        assert_eq!(read(EventKind::Menu, 0, "undo", &[0]), None);
    }

    #[test]
    fn the_words_of_a_menu_asked_are_tag_5_and_its_structure() {
        use editor_platform::menu::{Action, Item, KeyEquivalent, Role, Submenu, System};
        let menu = editor_platform::Menu {
            menus: vec![
                Submenu {
                    title: "A".into(),
                    role: Some(Role::App),
                    items: vec![
                        Item::Entry {
                            title: "Q".into(),
                            key: Some(KeyEquivalent {
                                character: 'q',
                                modifiers: held(false, false, false, true),
                            }),
                            action: Action::System(System::Quit),
                        },
                        Item::Separator,
                    ],
                },
                Submenu {
                    title: "é".into(),
                    role: Some(Role::Window),
                    items: vec![Item::Entry {
                        title: String::new(),
                        key: None,
                        action: Action::Command("u".into()),
                    }],
                },
                Submenu {
                    title: String::new(),
                    role: None,
                    items: vec![],
                },
            ],
        };
        assert_eq!(
            asked_words(&[WindowRequest::Menu(menu), WindowRequest::Minimise]),
            [
                5, 3, // the tag, and three menus
                1, 0x41, 1, 2, // "A", the app's, two items
                2, 1, 0x51, 1, 0x71, 8, 5, // Quit, "Q", s-q
                0, // a separator
                1, 0xe9, 2, 1, // "é", the windows menu, one item
                1, 0, 0, 0, 0, 1, 0x75, // command "u", untitled, no key
                0, 0, 0, // untitled, plain, no items
                2, // then the minimise
            ]
        );
    }

    #[test]
    fn a_quit_asked_by_the_system_crosses_as_its_kind_with_no_code_text_or_words() {
        assert_eq!(
            encoded(Input::QuitRequested),
            (EventKind::QuitRequested, 0, String::new(), vec![])
        );
        assert_eq!(EventKind::QuitRequested.tag(), 11);
        assert_eq!(
            read(EventKind::QuitRequested, 0, "", &[]),
            Some(Input::QuitRequested)
        );
        assert_eq!(read(EventKind::QuitRequested, 1, "", &[]), None);
        assert_eq!(read(EventKind::QuitRequested, 0, "x", &[]), None);
        assert_eq!(read(EventKind::QuitRequested, 0, "", &[0]), None);
    }

    /// One of each row of the table in the module docs, and of each value
    /// in a row's words: every input `input` must read back from its event.
    fn every_kind_of_input() -> Vec<Input> {
        let pointer = |action, button| {
            Input::Pointer(Pointer {
                action,
                x: 12.5,
                y: -3.25,
                button,
                modifiers: held(false, true, false, true),
            })
        };
        vec![
            Input::Opened {
                platform: "scripted".into(),
            },
            Input::Focus(true),
            Input::Focus(false),
            Input::Key(Key {
                pressed: true,
                repeat: false,
                logical: LogicalKey::Character("é😀".into()),
                physical: PhysicalKey::Code("KeyA".into()),
                modifiers: held(true, true, false, false),
                text: "é😀".into(),
            }),
            Input::Key(Key {
                pressed: true,
                repeat: true,
                logical: LogicalKey::Named("Escape".into()),
                physical: PhysicalKey::Code("Escape".into()),
                modifiers: held(true, true, true, true),
                text: String::new(),
            }),
            Input::Key(Key {
                pressed: true,
                logical: LogicalKey::Dead(Some('´')),
                ..Key::unidentified()
            }),
            Input::Key(Key {
                logical: LogicalKey::Dead(None),
                ..Key::unidentified()
            }),
            Input::Key(Key::unidentified()),
            Input::Composition(Composition::Enabled),
            Input::Composition(Composition::Preedit("´".into())),
            Input::Composition(Composition::Commit("é".into())),
            Input::Composition(Composition::Disabled),
            pointer(PointerAction::Press, Some(Button::Primary)),
            pointer(PointerAction::Drag, Some(Button::Secondary)),
            pointer(PointerAction::Release, Some(Button::Middle)),
            pointer(PointerAction::Press, Some(Button::Back)),
            pointer(PointerAction::Press, Some(Button::Forward)),
            pointer(PointerAction::Press, Some(Button::Other(u16::MAX))),
            pointer(
                PointerAction::Wheel(WheelDelta::Lines { x: 0.0, y: -1.5 }),
                None,
            ),
            pointer(
                PointerAction::Wheel(WheelDelta::Pixels { x: 7.0, y: 0.5 }),
                None,
            ),
            Input::Resized(Resize {
                width: 800,
                height: 600,
                scale: 2.0,
                fullscreen: false,
            }),
            Input::Resized(Resize {
                width: 1440,
                height: 900,
                scale: 1.0,
                fullscreen: true,
            }),
            Input::OpenFiles(vec!["/Users/me/notes.txt".into(), "/tmp/é ü.lean".into()]),
            Input::OpenFiles(vec![]),
            Input::CloseRequested,
            Input::QuitRequested,
            Input::Menu("toggle-fullscreen".into()),
        ]
    }

    /// The input `kind`, `code`, `text` and `words` read back as.
    fn read(kind: EventKind, code: u64, text: &str, words: &[u64]) -> Option<Input> {
        input(kind, code, text, &crate::words::tests::buffer(words))
    }

    /// The input `event` reads back as.
    fn read_back(event: &Event) -> Option<Input> {
        read(event.kind, event.code, &event.text, &event.words)
    }

    #[test]
    fn every_input_reads_back_from_its_event() {
        for expected in every_kind_of_input() {
            let event = event(expected.clone(), 0);

            assert_eq!(read_back(&event), Some(expected));
        }
    }

    #[test]
    fn words_that_are_not_whole_words_are_refused() {
        let event = event(Input::Key(Key::unidentified()), 0);
        let mut bytes = crate::words::tests::buffer(&event.words);
        bytes.pop();

        assert_eq!(input(EventKind::Key, 0, "", &bytes), None);
    }

    #[test]
    fn too_few_words_and_words_left_over_are_refused() {
        for original in every_kind_of_input() {
            let event = event(original, 0);
            let mut longer = event.words.clone();
            longer.push(0);

            assert_eq!(
                read(event.kind, event.code, &event.text, &longer),
                None,
                "{event:?} with a word left over"
            );
            if let Some((_, shorter)) = event.words.split_last() {
                assert_eq!(
                    read(event.kind, event.code, &event.text, shorter),
                    None,
                    "{event:?} a word short"
                );
            }
        }
    }

    #[test]
    fn a_count_of_scalars_longer_than_the_words_is_refused() {
        assert_eq!(read(EventKind::Key, 1, "", &[1, u64::MAX, 97]), None);
    }

    #[test]
    fn an_unknown_tag_is_refused() {
        // A logical tag, a physical tag, a button tag and a delta tag past
        // the last.
        assert_eq!(read(EventKind::Key, 1, "", &[4, 0, 0, 0, 0]), None);
        assert_eq!(read(EventKind::Key, 1, "", &[0, 0, 2, 0, 0]), None);
        let pointer = |button: u64, delta: u64| {
            read(
                EventKind::Pointer,
                3,
                "",
                &[0, 0, button, 0, 0, delta, 0, 0],
            )
        };
        assert!(pointer(0, 1).is_some());
        assert_eq!(pointer(7, 1), None);
        assert_eq!(pointer(0, 3), None);
    }

    #[test]
    fn a_scalar_that_is_not_a_character_is_refused() {
        // A surrogate, a number past the last scalar value, and one no `u32`
        // holds.
        for scalar in [0xD800, 0x11_0000, u64::MAX] {
            assert_eq!(read(EventKind::Key, 1, "", &[1, 1, scalar, 0, 0, 0]), None);
            assert_eq!(read(EventKind::Key, 1, "", &[0, 0, 1, 1, scalar, 0]), None);
            assert_eq!(read(EventKind::Key, 5, "", &[3, 1, scalar, 0, 0, 0]), None);
        }
    }

    #[test]
    fn a_code_out_of_range_is_refused() {
        assert_eq!(read(EventKind::WindowFocus, 2, "", &[]), None);
        assert_eq!(read(EventKind::Composition, 4, "", &[]), None);
        assert_eq!(read(EventKind::Key, 8, "", &[0, 0, 0, 0, 0]), None);
        assert_eq!(
            read(EventKind::Pointer, 4, "", &[0, 0, 0, 0, 0, 0, 0, 0]),
            None
        );
        assert_eq!(read(EventKind::Resize, 2, "", &[1, 1, 0]), None);
    }

    #[test]
    fn words_that_disagree_with_the_code_are_refused() {
        // The dead bit without a dead key, and a dead key without the bit.
        assert_eq!(read(EventKind::Key, 5, "", &[0, 0, 0, 0, 0]), None);
        assert_eq!(read(EventKind::Key, 1, "", &[3, 0, 0, 0, 0]), None);
        // A wheel with no delta, and a press with one.
        assert_eq!(
            read(EventKind::Pointer, 3, "", &[0, 0, 0, 0, 0, 0, 0, 0]),
            None
        );
        assert_eq!(
            read(EventKind::Pointer, 0, "", &[0, 0, 0, 0, 0, 1, 0, 0]),
            None
        );
        // A press with no delta that still gives one.
        assert_eq!(
            read(EventKind::Pointer, 0, "", &[0, 0, 0, 0, 0, 0, 1, 0]),
            None
        );
        // A number for a named button, and a number no button holds.
        assert_eq!(
            read(EventKind::Pointer, 0, "", &[0, 0, 1, 5, 0, 0, 0, 0]),
            None
        );
        assert_eq!(
            read(EventKind::Pointer, 0, "", &[0, 0, 6, 1 << 16, 0, 0, 0, 0]),
            None
        );
        // Modifier bits past the system key's.
        assert_eq!(read(EventKind::Key, 1, "", &[0, 0, 0, 0, 16]), None);
    }

    #[test]
    fn a_kind_no_window_reports_is_refused() {
        for kind in [EventKind::Quit, EventKind::Message, EventKind::Completion] {
            assert_eq!(read(kind, 0, "", &[]), None);
        }
    }

    #[test]
    fn posting_an_input_queues_its_window_event_stamped_with_the_clock() {
        let queue = Queue::new();
        let clock = CountingClock::new();
        clock.now_ns();
        let input = Input::Resized(Resize {
            width: 1,
            height: 2,
            scale: 1.5,
            fullscreen: false,
        });
        let posted = event(input, 0);
        let bytes = crate::words::tests::buffer(&posted.words);

        assert!(post_input(
            &queue,
            &Interrupt::new(),
            &clock,
            posted.kind,
            posted.code,
            "",
            &bytes
        ));

        assert_eq!(queue.next(), posted.stamped(2));
    }

    #[test]
    fn posting_malformed_words_queues_nothing() {
        let queue = Queue::new();

        assert!(!post_input(
            &queue,
            &Interrupt::new(),
            &CountingClock::new(),
            EventKind::Resize,
            0,
            "",
            &crate::words::tests::buffer(&[1, 2])
        ));
        queue.quit();

        assert_eq!(queue.next(), Event::quit());
    }

    /// A press of the character `g` with control held, and the flag whose
    /// interrupt key it is: every modifier but shift is compared.
    fn interrupt_key() -> (Input, Arc<Interrupt>) {
        let interrupt = Interrupt::new();
        interrupt.set_key(Some(InterruptKey {
            logical: LogicalKey::Character("g".into()),
            modifiers: MODIFIER_CONTROL,
            mask: MODIFIER_CONTROL | MODIFIER_ALT | MODIFIER_SUPER,
        }));
        let key = Input::Key(Key {
            pressed: true,
            logical: LogicalKey::Character("g".into()),
            modifiers: held(false, true, false, false),
            ..Key::unidentified()
        });
        (key, Arc::new(interrupt))
    }

    #[test]
    fn a_press_of_the_interrupt_key_arrives_marked_and_the_flag_is_up_when_it_is_pulled() {
        let (key, interrupt) = interrupt_key();
        let queue = Arc::new(Queue::new());
        // The puller is parked before the key arrives, and reads the flag
        // the moment it has the event.
        let (pulled, events) = mpsc::channel();
        let puller = (Arc::clone(&queue), Arc::clone(&interrupt));
        thread::spawn(move || {
            let event = puller.0.next();
            let _ = pulled.send((event, puller.1.raised()));
        });

        assert!(arrive(&queue, &interrupt, key.clone(), 7));

        let (event, raised) = events
            .recv_timeout(DEADLINE)
            .expect("the key reaches the puller");
        let unmarked = super::event(key, 7);
        assert_eq!(event.code, unmarked.code | KEY_INTERRUPT);
        assert_eq!(event.code, KEY_PRESSED | KEY_INTERRUPT);
        assert_eq!(
            Event {
                code: unmarked.code,
                ..event
            },
            unmarked
        );
        assert!(raised, "the flag is up before the event can be pulled");
        assert!(interrupt.raised(), "pulling the event does not lower it");
    }

    #[test]
    fn an_input_that_is_not_the_interrupt_key_arrives_as_its_event_and_raises_nothing() {
        let (key, interrupt) = interrupt_key();
        let queue = Queue::new();
        let Input::Key(key) = key else {
            unreachable!("the interrupt key is a key")
        };
        let release = Input::Key(Key {
            pressed: false,
            ..key
        });

        for input in [release, Input::Focus(true), pointer_press()] {
            assert!(arrive(&queue, &interrupt, input.clone(), 3));

            assert_eq!(queue.next(), event(input, 3));
        }
        assert!(!interrupt.raised());
    }

    #[test]
    fn an_interrupt_key_a_quit_queue_refuses_leaves_the_flag_down() {
        let (key, interrupt) = interrupt_key();
        let queue = Queue::new();
        queue.quit();

        assert!(!arrive(&queue, &interrupt, key, 1));

        assert!(!interrupt.raised(), "nothing will pull the key");
    }

    #[test]
    fn a_posted_press_of_the_interrupt_key_takes_the_arrival_path() {
        let (key, interrupt) = interrupt_key();
        let queue = Queue::new();
        let posted = event(key, 0);
        let bytes = crate::words::tests::buffer(&posted.words);

        assert!(post_input(
            &queue,
            &interrupt,
            &CountingClock::new(),
            posted.kind,
            posted.code,
            "",
            &bytes
        ));

        assert_eq!(queue.next().code, posted.code | KEY_INTERRUPT);
        assert!(interrupt.raised());
    }

    #[test]
    fn a_window_that_reports_the_interrupt_key_raises_the_flag_and_marks_the_event() {
        let (key, interrupt) = interrupt_key();
        let platform = Arc::new(ScriptedPlatform::new(vec![key, Input::Focus(true)]));
        let queue = Arc::new(Queue::new());

        let done = start_watched(&platform, WindowOptions::default(), &queue, &interrupt);

        let codes: Vec<(EventKind, u64)> = pull(&queue, 3)
            .into_iter()
            .map(|event| (event.kind, event.code))
            .collect();
        assert_eq!(
            codes,
            [
                (EventKind::WindowOpened, 0),
                (EventKind::Key, KEY_PRESSED | KEY_INTERRUPT),
                (EventKind::WindowFocus, 1),
            ]
        );
        assert!(interrupt.raised());
        platform.close();
        assert_eq!(done.recv_timeout(DEADLINE), Ok(Ok(())));
    }

    #[test]
    fn a_key_code_with_the_interrupt_mark_reads_as_no_input() {
        assert_eq!(KEY_INTERRUPT, 8);
        let key = event(interrupt_key().0, 0);

        assert!(read(EventKind::Key, key.code, "", &key.words).is_some());
        assert_eq!(
            read(EventKind::Key, key.code | KEY_INTERRUPT, "", &key.words),
            None
        );
    }

    #[test]
    fn the_platform_is_run_with_the_options_it_was_given_and_a_close_ends_the_run() {
        let platform = Arc::new(ScriptedPlatform::new(Vec::new()));
        let queue = Arc::new(Queue::new());
        let options = WindowOptions { composition: false };

        let done = start(&platform, options, &queue);
        assert_eq!(pull(&queue, 1).len(), 1);
        assert!(
            done.recv_timeout(Duration::from_millis(20)).is_err(),
            "the run goes on until the platform is asked to close"
        );
        platform.close();

        assert_eq!(done.recv_timeout(DEADLINE), Ok(Ok(())));
        assert_eq!(platform.runs(), [options]);
    }

    #[test]
    fn what_the_window_tells_reaches_the_drawer_it_was_run_with_and_not_the_queue() {
        let platform = Arc::new(ScriptedPlatform::new(vec![Input::Resized(Resize {
            width: 300,
            height: 120,
            scale: 2.0,
            fullscreen: false,
        })]));
        let queue = Arc::new(Queue::new());
        // Which kind of thing the drawer was told, in order: the thing
        // itself is not another thread's to keep.
        let (tell, told) = mpsc::channel();
        let drawer: Drawer = Arc::new(move |canvas| {
            let _ = tell.send(match canvas {
                Canvas::Opened { .. } => "opened",
                Canvas::Resized(_) => "resized",
                Canvas::Closing => "closing",
                _ => "something else",
            });
        });

        let done = {
            let (finished, done) = mpsc::channel();
            let (platform, queue) = (Arc::clone(&platform), Arc::clone(&queue));
            thread::spawn(move || {
                let options = WindowOptions::default();
                let interrupt = Arc::new(Interrupt::new());
                let result = run(
                    &*platform,
                    options,
                    CountingClock::new(),
                    queue,
                    interrupt,
                    drawer,
                );
                let _ = finished.send(result);
            });
            done
        };
        // The window's two events are queued, and nothing for what the
        // drawer was told.
        let kinds: Vec<EventKind> = pull(&queue, 2).iter().map(|event| event.kind).collect();
        assert_eq!(kinds, [EventKind::WindowOpened, EventKind::Resize]);
        platform.close();
        assert_eq!(done.recv_timeout(DEADLINE), Ok(Ok(())));

        let told: Vec<&str> = told.try_iter().collect();
        assert_eq!(told, ["opened", "resized", "closing"]);
        queue.quit();
        assert_eq!(queue.next(), Event::quit());
    }

    #[test]
    fn a_platform_that_cannot_open_gives_its_reason_and_queues_nothing() {
        let platform = Arc::new(ScriptedPlatform::failing("no display"));
        let queue = Arc::new(Queue::new());

        let done = start(&platform, WindowOptions::default(), &queue);

        assert_eq!(
            done.recv_timeout(DEADLINE),
            Ok(Err(CannotOpen {
                reason: "no display".into()
            }))
        );
        // The marker is the first event of the queue: the run queued nothing.
        let marker = Event::message(
            Source {
                kind: SourceKind::Script,
                id: 0,
            },
            0,
            "marker",
        );
        queue.push(marker.clone());
        assert_eq!(pull(&queue, 1), [marker]);
    }

    #[test]
    fn the_counting_clock_reads_one_more_each_time() {
        let clock = CountingClock::new();

        assert_eq!([clock.now_ns(), clock.now_ns(), clock.now_ns()], [1, 2, 3]);
    }

    #[test]
    fn the_real_clock_is_never_zero_and_does_not_go_back() {
        let clock = Monotonic::new();

        let first = clock.now_ns();
        let second = clock.now_ns();

        assert!(first > 0, "0 would read as no stamp");
        assert!(first <= second);
    }

    #[test]
    fn every_platform_converts_from_its_tag_and_an_unknown_tag_is_refused() {
        assert_eq!(PlatformId::from_tag(0), Some(PlatformId::Scripted));
        assert_eq!(PlatformId::from_tag(1), Some(PlatformId::Winit));
        assert_eq!(PlatformId::from_tag(2), Some(PlatformId::ScriptedFailing));
        assert_eq!(PlatformId::from_tag(3), Some(PlatformId::ScriptedUndrawn));
        assert_eq!(PlatformId::Scripted.tag(), 0);
        assert_eq!(PlatformId::Winit.tag(), 1);
        assert_eq!(PlatformId::ScriptedFailing.tag(), 2);
        assert_eq!(PlatformId::ScriptedUndrawn.tag(), 3);
        assert_eq!(PlatformId::from_tag(4), None);
        assert_eq!(PlatformId::from_tag(u8::MAX), None);
    }

    /// The recording renderer, which also says on a channel the target of
    /// each draw.
    struct Watched {
        /// The fake.
        inner: editor_render::fake::RecordingRenderer,
        /// Where it says it drew.
        drew: mpsc::Sender<editor_render::port::Target>,
    }

    impl editor_render::port::Renderer for Watched {
        fn draw(
            &mut self,
            request: &editor_render::port::DrawRequest<'_>,
        ) -> editor_render::port::Drawn {
            let drawn = self.inner.draw(request);
            let _ = self.drew.send(request.target);
            drawn
        }
    }

    /// A session over `presenter` whose renderers are watched, on the fake
    /// clock, and where their draws are said.
    fn watched_session(
        presenter: &Arc<Presenter>,
    ) -> (Session<Watched>, Receiver<editor_render::port::Target>) {
        let (drew, draws) = mpsc::channel();
        let drew = std::sync::Mutex::new(drew);
        let session = Session::new(
            Arc::new(editor_render::clock::FakeClock::new()),
            move |_, _| {
                let drew = drew.lock().expect("nothing panics holding it").clone();
                Ok(Watched {
                    inner: editor_render::fake::RecordingRenderer::new(),
                    drew,
                })
            },
            Arc::clone(presenter),
        );
        (session, draws)
    }

    /// Runs `platform` onto `queue` with `session` drawing in its window,
    /// on a thread of its own: where the run's result arrives.
    fn start_drawn<R: editor_render::port::Renderer + Send + 'static>(
        platform: &Arc<ScriptedPlatform>,
        queue: &Arc<Queue>,
        session: &Session<R>,
    ) -> Receiver<Result<Ran, CannotOpen>> {
        let (finished, done) = mpsc::channel();
        let (platform, queue, session) = (Arc::clone(platform), Arc::clone(queue), session.clone());
        thread::spawn(move || {
            let interrupt = Arc::new(Interrupt::new());
            let _ = finished.send(run_with(
                &*platform,
                WindowOptions::default(),
                CountingClock::new(),
                queue,
                interrupt,
                &session,
            ));
        });
        done
    }

    /// Publishes to `display` a scene of one view of `snapshot`.
    fn publish_to(display: &Display, snapshot: &crate::snapshot::Snapshot) {
        let wire = crate::display::WireScene {
            size: [80, 32],
            views: vec![crate::display::WireView {
                id: 1,
                rect: [0, 0, 80, 32],
                snapshot: Some(0),
                ..crate::display::WireView::default()
            }],
            ..crate::display::WireScene::default()
        };
        let (words, strings) = wire.encode();
        assert!(display.publish(&words, &strings, &[snapshot]));
    }

    #[test]
    fn a_display_bound_to_the_windows_presenter_is_drawn_in_the_window_at_its_scale() {
        let presenter = Presenter::new();
        let (session, draws) = watched_session(&presenter);
        // Not the scripted window's scale, so that its being said shows.
        presenter.set_scale(3.0);
        let platform = Arc::new(ScriptedPlatform::new(Vec::new()));
        let queue = Arc::new(Queue::new());
        let done = start_drawn(&platform, &queue, &session);
        // The window has opened, and has told the drawer so first.
        assert_eq!(pull(&queue, 1)[0].kind, EventKind::WindowOpened);
        assert_eq!(presenter.scale(), ScriptedPlatform::SIZE.scale as f32);
        let handle = session.handle().expect("an open window has a loop");
        assert!(
            presenter
                .target()
                .is_some_and(|target| target.same(&handle))
        );
        // A display bound to the presenter is drawn in the window.
        let display = Display::cells(8, 16);
        display.present_to(Arc::clone(&presenter));
        let document = crate::document::Document::new("ab");
        let snapshot = crate::snapshot::Snapshot::of(&document);
        publish_to(&display, &snapshot);
        draws.recv_timeout(DEADLINE).expect("the frame is drawn");
        platform.close();
        // Something drew in the window, so the run has no reason to give.
        assert_eq!(
            done.recv_timeout(DEADLINE),
            Ok(Ok(Ran { nothing_drew: None }))
        );
        // Closed: nothing takes submits, and the run's handle is the last.
        assert!(presenter.target().is_none());
        let last = presenter.last().expect("the run's handle");
        assert!(last.same(&handle));
        let counters = last.counters();
        assert_eq!(counters.frames_submitted, 1);
        assert!(counters.draws >= 1);
        publish_to(&display, &snapshot);
        assert_eq!(last.counters().frames_submitted, 1);
    }

    #[test]
    fn a_presentation_asked_for_crosses_as_a_mode_tag_and_a_latency_each_0_for_none() {
        let asked = |mode, frame_latency| Asked {
            mode,
            frame_latency,
        };
        assert_eq!(asked_presentation(0, 0), Asked::NOTHING);
        assert_eq!(asked_presentation(1, 0), asked(Some(Mode::Fifo), None));
        assert_eq!(
            asked_presentation(2, 0),
            asked(Some(Mode::FifoRelaxed), None)
        );
        assert_eq!(
            asked_presentation(3, 2),
            asked(Some(Mode::Immediate), Some(2))
        );
        assert_eq!(asked_presentation(4, 0), asked(Some(Mode::Mailbox), None));
        // A latency alone is a latency alone: the mode is the renderer's
        // to decide.
        assert_eq!(asked_presentation(0, 3), asked(None, Some(3)));
        // A tag that names no mode asks for nothing.
        assert_eq!(asked_presentation(5, 2), Asked::NOTHING);
    }

    #[test]
    fn what_a_surface_offered_crosses_as_its_modes_then_what_was_asked_then_what_was_configured() {
        let configured = Presentation {
            mode: Mode::Immediate,
            frame_latency: 2,
        };
        let offered = Offered {
            modes: vec![Mode::Fifo, Mode::Immediate, Mode::Mailbox],
            asked: Asked {
                mode: Some(Mode::Immediate),
                frame_latency: Some(2),
            },
            configured,
        };
        assert_eq!(offered_words(&offered), vec![3, 1, 3, 4, 3, 2, 3, 2]);
        // Each half asked for alone, the other 0.
        let latency_only = Offered {
            asked: Asked {
                mode: None,
                frame_latency: Some(2),
            },
            ..offered.clone()
        };
        assert_eq!(offered_words(&latency_only), vec![3, 1, 3, 4, 0, 2, 3, 2]);
        let mode_only = Offered {
            asked: Asked {
                mode: Some(Mode::Mailbox),
                frame_latency: None,
            },
            ..offered
        };
        assert_eq!(offered_words(&mode_only), vec![3, 1, 3, 4, 4, 0, 3, 2]);
        let decided = Offered {
            modes: vec![Mode::FifoRelaxed],
            asked: Asked::NOTHING,
            configured: Presentation {
                mode: Mode::Fifo,
                frame_latency: 1,
            },
        };
        assert_eq!(offered_words(&decided), vec![1, 2, 0, 0, 1, 1]);
        // Each mode's tag is the one a run asks for it by.
        for mode in [
            Mode::Fifo,
            Mode::FifoRelaxed,
            Mode::Immediate,
            Mode::Mailbox,
        ] {
            let tag = u8::try_from(mode_tag(mode)).expect("a tag is small");
            assert_eq!(asked_presentation(tag, 1).mode, Some(mode));
        }
    }

    #[test]
    fn a_window_renderer_on_a_scripted_platform_leaves_no_presentation() {
        let slot = PresentationSlot::default();
        let mut renderer = window_renderer(PlatformId::Scripted, None, Asked::NOTHING, &slot)
            .unwrap_or_else(|reason| panic!("the recording renderer is made: {reason}"));
        let frame = Arc::new(editor_layout::frame::Frame::default());
        let request = DrawRequest {
            frame: &frame,
            target: editor_render::port::Target {
                width: 8,
                height: 8,
                scale: 1.0,
            },
        };
        let _ = renderer.draw(&request);
        assert_eq!(slot.read(), None);
    }

    #[test]
    fn the_scale_a_window_is_resized_to_is_its_presenters() {
        let presenter = Presenter::new();
        let (session, _draws) = watched_session(&presenter);
        let resized = Resize {
            width: 800,
            height: 600,
            scale: 2.0,
            fullscreen: false,
        };
        let platform = Arc::new(ScriptedPlatform::new(vec![Input::Resized(resized)]));
        let queue = Arc::new(Queue::new());
        let done = start_drawn(&platform, &queue, &session);
        let kinds: Vec<EventKind> = pull(&queue, 2).iter().map(|event| event.kind).collect();
        assert_eq!(kinds, [EventKind::WindowOpened, EventKind::Resize]);
        // The drawer is told before the queue, so the resize has been said.
        assert_eq!(presenter.scale(), 2.0);
        platform.close();
        assert!(done.recv_timeout(DEADLINE).is_ok_and(|ran| ran.is_ok()));
    }

    /// Why the renderer of [`a_window_whose_renderer_cannot_be_made_runs_and_its_run_says_why_nothing_drew`]
    /// cannot be made.
    const NO_ADAPTER: &str = "no adapter: the machine offers no GPU";

    #[test]
    fn a_window_whose_renderer_cannot_be_made_runs_and_its_run_says_why_nothing_drew() {
        let presenter = Presenter::new();
        let session: Session<editor_render::fake::RecordingRenderer> = Session::new(
            Arc::new(editor_render::clock::FakeClock::new()),
            |_, _| Err(NO_ADAPTER.to_owned()),
            Arc::clone(&presenter),
        );
        let platform = Arc::new(ScriptedPlatform::new(Vec::new()));
        let queue = Arc::new(Queue::new());
        let done = start_drawn(&platform, &queue, &session);
        // The window opens and reports all the same.
        assert_eq!(pull(&queue, 1)[0].kind, EventKind::WindowOpened);
        assert!(presenter.target().is_none());
        platform.close();
        assert_eq!(
            done.recv_timeout(DEADLINE),
            Ok(Ok(Ran {
                nothing_drew: Some(NO_ADAPTER.to_owned())
            }))
        );
    }

    #[test]
    fn a_window_that_cannot_open_gives_its_presenter_no_target() {
        let presenter = Presenter::new();
        let (session, _draws) = watched_session(&presenter);
        let result = run_with(
            PlatformId::ScriptedFailing.platform(),
            WindowOptions::default(),
            CountingClock::new(),
            Arc::new(Queue::new()),
            Arc::new(Interrupt::new()),
            &session,
        );
        assert!(result.is_err());
        assert!(presenter.target().is_none() && presenter.last().is_none());
    }

    #[test]
    fn the_scripted_platform_that_fails_cannot_open_and_gives_its_reason_on_every_run() {
        for _ in 0..2 {
            let queue = Arc::new(Queue::new());

            let result = run(
                PlatformId::ScriptedFailing.platform(),
                WindowOptions::default(),
                CountingClock::new(),
                queue,
                Arc::new(Interrupt::new()),
                no_drawer(),
            );

            assert_eq!(
                result,
                Err(CannotOpen {
                    reason: SCRIPTED_FAILURE.into()
                })
            );
        }
    }
}
