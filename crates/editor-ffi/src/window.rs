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
//! | `Key` | `Key` | Bit 0 pressed, bit 1 repeat, bit 2 a dead logical key | What the key produced, or empty | The logical key, the physical key, the modifiers |
//! | `Composition` | `Composition` | 0 enabled, 1 preedit, 2 commit, 3 disabled | The preedit or the committed text | None |
//! | `Pointer` | `Pointer` | 0 press, 1 drag, 2 release, 3 wheel | Empty | The position, the button, the modifiers, the wheel's delta |
//! | `Resized` | `Resize` | 0 | Empty | The width, the height, the scale |
//! | `CloseRequested` | `CloseRequested` | 0 | Empty | None |
//!
//! The words ([`crate::words`]) of each kind that has them:
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
//!
//! The modifiers are one word of bits: shift [`MODIFIER_SHIFT`], control
//! [`MODIFIER_CONTROL`], alt [`MODIFIER_ALT`] and the system key
//! [`MODIFIER_SUPER`]. A float (a position, a delta, a scale) crosses as its
//! IEEE 754 bits ([`f64::to_bits`]); Lean reads it back with `Float.ofBits`.
//!
//! A window is run by the main-thread service: "run the window" is a request
//! of it ([`crate::main_thread::Request::RunWindow`]), so the window's loop
//! is on the process's main thread and the caller is blocked until the
//! window has closed. Rust never closes a window by itself: a window that is
//! asked to close reports `CloseRequested` and stays open until Lean calls
//! [`editor_ffi_window_close`].
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
    Button, CannotOpen, Composition, Input, Key, LogicalKey, Modifiers, PhysicalKey, Platform,
    Pointer, PointerAction, Report, ScriptedPlatform, WheelDelta, WindowOptions,
};
use editor_platform_winit::WinitPlatform;

use crate::events::{Event, EventKind, Queue, QueueId, Source, SourceKind};
use crate::main_thread::{self, Reply, Request};
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

/// The bit of a modifier word that is set when shift is held.
pub const MODIFIER_SHIFT: u64 = 1;

/// The bit of a modifier word that is set when control is held.
pub const MODIFIER_CONTROL: u64 = 1 << 1;

/// The bit of a modifier word that is set when alt is held.
pub const MODIFIER_ALT: u64 = 1 << 2;

/// The bit of a modifier word that is set when the system key is held.
pub const MODIFIER_SUPER: u64 = 1 << 3;

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
            0,
            String::new(),
            vec![resize.width, resize.height, resize.scale.to_bits()],
        ),
        Input::CloseRequested => (EventKind::CloseRequested, 0, String::new(), Vec::new()),
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
fn modifier_bits(modifiers: Modifiers) -> u64 {
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

/// Runs `platform`'s window on the calling thread, opened as `options` say,
/// until the platform is asked to close, and pushes each thing the window
/// reports onto `queue`, stamped with `clock`'s reading when it was
/// reported.
///
/// Returns the platform's failure, having queued nothing, when no window
/// could be opened.
pub fn run<P, C, Q>(
    platform: &P,
    options: WindowOptions,
    clock: C,
    queue: Q,
) -> Result<(), CannotOpen>
where
    P: Platform + ?Sized,
    C: InputClock + 'static,
    Q: Deref<Target = Queue> + Send + Sync + 'static,
{
    let report: Report = Arc::new(move |input| {
        // The clock is read first: the stamp is when the window reported the
        // input, not when the event was built. A queue that has been quit
        // drops the event, and there is nobody to tell.
        let stamp = clock.now_ns();
        queue.push(event(input, stamp));
    });
    platform.run(options, report)
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
            _ => None,
        }
    }

    /// The process-wide platform this names.
    fn platform(self) -> &'static dyn Platform {
        match self {
            Self::Scripted => &*SCRIPTED,
            Self::Winit => &WINIT,
            Self::ScriptedFailing => &*SCRIPTED_FAILING,
        }
    }
}

/// Why [`PlatformId::ScriptedFailing`] cannot open a window. "é" is two
/// bytes, so a caller that took the reason's length in characters would get
/// it cut.
pub const SCRIPTED_FAILURE: &str = "the scripted platform opens no window: pas d'écran";

/// The process's input clock.
static CLOCK: Monotonic = Monotonic::new();

/// The process's scripted platform, made the first time it is asked for.
static SCRIPTED: LazyLock<ScriptedPlatform> = LazyLock::new(ScriptedPlatform::sample);

/// The process's scripted platform that cannot open a window, made the first
/// time it is asked for.
static SCRIPTED_FAILING: LazyLock<ScriptedPlatform> =
    LazyLock::new(|| ScriptedPlatform::failing(SCRIPTED_FAILURE));

/// The process's real platform. It opens nothing until it is run.
static WINIT: WinitPlatform = WinitPlatform::new(main_thread::is_main_thread);

/// Runs the process's window on the calling thread, on the platform
/// `platform`, onto the editor queue. This is what the main-thread service
/// does for [`Request::RunWindow`].
pub(crate) fn run_on_this_thread(
    platform: PlatformId,
    options: WindowOptions,
) -> Result<(), CannotOpen> {
    run(
        platform.platform(),
        options,
        &CLOCK,
        QueueId::Editor.queue(),
    )
}

/// Why a window did not run, as it crosses the boundary: one record, filled
/// in one call.
#[repr(C)]
pub struct RawRefusal {
    /// The reason: a buffer of `reason_len` bytes of UTF-8, owned by the
    /// caller until it is handed back with
    /// [`crate::text::editor_ffi_text_free`].
    pub reason: *mut u8,
    /// The length of `reason` in bytes.
    pub reason_len: usize,
}

/// Runs the process's window on the platform `platform`, with composition
/// allowed or not, and blocks the calling thread until the window has
/// closed: the main-thread service runs it. Returns whether it ran.
///
/// Returns false, and fills `out` with the reason, if `platform` names no
/// platform or the platform could not open a window. `out` is left alone
/// when the window ran.
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
    out: *mut RawRefusal,
) -> bool {
    let outcome = match PlatformId::from_tag(platform) {
        None => Err("the Rust library knows no such platform".to_owned()),
        Some(platform) => {
            let options = WindowOptions { composition };
            match main_thread::request(Request::RunWindow { platform, options }) {
                Reply::WindowClosed(Ok(())) => Ok(()),
                Reply::WindowClosed(Err(cannot_open)) => Err(cannot_open.reason),
                Reply::OnMainThread(_) => {
                    Err("the main-thread service answered another request".to_owned())
                }
            }
        }
    };
    match outcome {
        Ok(()) => true,
        Err(reason) => {
            let (reason, reason_len) = text::lend(reason);
            // SAFETY: the caller guarantees `out` is writable.
            unsafe { out.write(RawRefusal { reason, reason_len }) };
            false
        }
    }
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

/// The time on the process's input clock, in nanoseconds since the clock
/// began. It never goes back and is never 0.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_input_clock_now() -> u64 {
    CLOCK.now_ns()
}

#[cfg(test)]
mod tests {
    use super::*;
    use editor_platform::{
        Button, Key, LogicalKey, Modifiers, PhysicalKey, Pointer, PointerAction, Resize, WheelDelta,
    };
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
    /// stamped by a clock that counts its readings, and returns where its
    /// result arrives. The thread is detached, so a run that never returns
    /// cannot keep the test from ending.
    fn start(
        platform: &Arc<ScriptedPlatform>,
        options: WindowOptions,
        queue: &Arc<Queue>,
    ) -> Receiver<Result<(), CannotOpen>> {
        let (finished, done) = mpsc::channel();
        let platform = Arc::clone(platform);
        let queue = Arc::clone(queue);
        thread::spawn(move || {
            let _ = finished.send(run(&*platform, options, CountingClock::new(), queue));
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
    fn every_other_input_has_no_words() {
        for input in [
            Input::Opened {
                platform: "scripted".into(),
            },
            Input::Focus(true),
            Input::Composition(Composition::Preedit("´".into())),
            Input::CloseRequested,
        ] {
            assert_eq!(encoded(input).3, Vec::<u64>::new());
        }
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
        assert_eq!(PlatformId::Scripted.tag(), 0);
        assert_eq!(PlatformId::Winit.tag(), 1);
        assert_eq!(PlatformId::ScriptedFailing.tag(), 2);
        assert_eq!(PlatformId::from_tag(3), None);
        assert_eq!(PlatformId::from_tag(u8::MAX), None);
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
