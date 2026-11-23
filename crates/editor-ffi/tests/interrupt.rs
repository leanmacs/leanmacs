//! The C functions over the process's interrupt flag, called the way the C
//! glue calls them, with the keys posted through the window input and
//! pulled from the process's editor queue.
//!
//! This is an integration test of its own, not part of `tests/window.rs` or
//! `tests/c_api.rs`, because the flag, the interrupt key and the editor
//! queue are process-wide. It is one test function, so nothing else in this
//! process posts a key or touches the flag.

use std::mem::MaybeUninit;
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use editor_wait::HangGuard;

use editor_ffi::events::{EventKind, QueueId, RawEvent, editor_ffi_events_next};
use editor_ffi::interrupt::{
    editor_ffi_interrupt_key_clear, editor_ffi_interrupt_key_set, editor_ffi_interrupt_lower,
    editor_ffi_interrupt_raised,
};
use editor_ffi::text::editor_ffi_text_free;
use editor_ffi::window::{
    self, KEY_INTERRUPT, KEY_PRESSED, MODIFIER_ALT, MODIFIER_CONTROL, MODIFIER_SHIFT,
    MODIFIER_SUPER, editor_ffi_window_post_input,
};
use editor_platform::{Input, Key, LogicalKey, Modifiers};

/// hang guard: the next event on the editor queue; only a hang reaches the bound, and the test then fails as a hang. Each
/// wait on it is for something that should happen at once.
const DEADLINE: HangGuard =
    HangGuard::on("the next event on the editor queue", Duration::from_secs(5));

/// The bytes of `words`, as they cross.
fn buffer(words: &[u64]) -> Vec<u8> {
    words.iter().flat_map(|word| word.to_le_bytes()).collect()
}

/// Tells the library its interrupt key through the C function, as the glue
/// does, and returns whether the words read.
fn set_key(words: &[u64]) -> bool {
    let bytes = buffer(words);
    // SAFETY: the pointer and length are those of `bytes`, alive for the
    // call.
    unsafe { editor_ffi_interrupt_key_set(bytes.as_ptr(), bytes.len()) }
}

/// A key event of the character `text` with `modifiers` held, pressed or
/// released.
fn key(text: &str, modifiers: Modifiers, pressed: bool) -> Input {
    Input::Key(Key {
        pressed,
        logical: LogicalKey::Character(text.into()),
        modifiers,
        ..Key::unidentified()
    })
}

/// The modifiers with control held, and shift too when `shift`.
fn control(shift: bool) -> Modifiers {
    Modifiers {
        shift,
        control: true,
        ..Modifiers::default()
    }
}

/// Posts `input` to the editor queue through the C function, as the glue
/// does, with `code` in place of the code of its event when one is given.
/// Returns whether it was queued.
fn post(input: Input, code: Option<u64>) -> bool {
    let event = window::event(input, 0);
    let words = buffer(&event.words);
    // SAFETY: the pointers and lengths are those of the event's text and of
    // `words`, alive for the call.
    unsafe {
        editor_ffi_window_post_input(
            EventKind::Key.tag() as u8,
            code.unwrap_or(event.code),
            event.text.as_ptr(),
            event.text.len(),
            words.as_ptr(),
            words.len(),
        )
    }
}

/// The code of the next event of the editor queue, bounded by the deadline:
/// the pull runs on a detached thread, so one that never returns fails the
/// test instead of hanging it.
fn next_code() -> u64 {
    let (done, result) = mpsc::channel();
    thread::spawn(move || {
        let mut raw = MaybeUninit::<RawEvent>::uninit();
        // SAFETY: `raw` is writable for one record.
        assert!(unsafe { editor_ffi_events_next(QueueId::Editor.tag(), raw.as_mut_ptr()) });
        // SAFETY: the call returned true, so it filled the record.
        let raw = unsafe { raw.assume_init() };
        // SAFETY: each buffer came from the library in this record, and is
        // handed back once.
        unsafe {
            editor_ffi_text_free(raw.text, raw.text_len);
            editor_ffi_text_free(raw.words, raw.words_len);
        }
        let _ = done.send(raw.code);
    });
    editor_wait::recv(&result, DEADLINE)
        .unwrap_or_else(|_| panic!("no event reached the editor queue: {DEADLINE}"))
}

/// The whole life of the process's interrupt flag, in order.
#[test]
fn the_interrupt_key_raises_the_flag_as_it_arrives_and_lean_lowers_it() {
    // `C-g`, as Lean tells it: the character `g` with control held, every
    // modifier compared but shift.
    let control_g = [1, 1, u64::from('g'), MODIFIER_CONTROL];
    let but_shift = MODIFIER_CONTROL | MODIFIER_ALT | MODIFIER_SUPER;
    let every = but_shift | MODIFIER_SHIFT;

    // With no interrupt key, the key raises nothing and arrives unmarked.
    assert!(!editor_ffi_interrupt_raised());
    assert!(post(key("g", control(false), true), None));
    assert!(!editor_ffi_interrupt_raised());
    assert_eq!(next_code(), KEY_PRESSED);

    // Words that do not read set no key: one word short, and a modifier
    // the mask does not name.
    assert!(!set_key(&control_g));
    assert!(!set_key(&[
        1,
        1,
        u64::from('g'),
        MODIFIER_CONTROL,
        MODIFIER_ALT
    ]));
    assert!(post(key("g", control(false), true), None));
    assert!(!editor_ffi_interrupt_raised());
    assert_eq!(next_code(), KEY_PRESSED);

    // Once the key is told, a press of it raises the flag as it arrives,
    // before anything pulls it, and its event carries the mark.
    let mut words = control_g.to_vec();
    words.push(but_shift);
    assert!(set_key(&words));
    assert!(
        !editor_ffi_interrupt_raised(),
        "telling the key raises nothing"
    );
    assert!(post(key("g", control(false), true), None));
    assert!(editor_ffi_interrupt_raised());
    assert_eq!(next_code(), KEY_PRESSED | KEY_INTERRUPT);
    assert!(
        editor_ffi_interrupt_raised(),
        "pulling the event does not lower the flag"
    );
    editor_ffi_interrupt_lower();
    assert!(!editor_ffi_interrupt_raised());

    // Shift is outside the mask, so the key with shift held is the key. A
    // release, another character and the key without control are not.
    assert!(post(key("g", control(true), true), None));
    assert!(editor_ffi_interrupt_raised());
    assert_eq!(next_code(), KEY_PRESSED | KEY_INTERRUPT);
    editor_ffi_interrupt_lower();
    for (input, code) in [
        (key("g", control(false), false), 0),
        (key("G", control(false), true), KEY_PRESSED),
        (key("g", Modifiers::default(), true), KEY_PRESSED),
    ] {
        assert!(post(input, None));
        assert!(!editor_ffi_interrupt_raised());
        assert_eq!(next_code(), code);
    }

    // With shift in the mask, the key with shift held is another key.
    let mut shifted = control_g.to_vec();
    shifted.push(every);
    assert!(set_key(&shifted));
    assert!(post(key("g", control(true), true), None));
    assert!(!editor_ffi_interrupt_raised());
    assert_eq!(next_code(), KEY_PRESSED);
    assert!(set_key(&words));

    // Two presses need two lowers, and a lower with none counted is
    // nothing: the next press still raises the flag.
    assert!(post(key("g", control(false), true), None));
    assert!(post(key("g", control(false), true), None));
    editor_ffi_interrupt_lower();
    assert!(editor_ffi_interrupt_raised(), "one press is still queued");
    editor_ffi_interrupt_lower();
    assert!(!editor_ffi_interrupt_raised());
    editor_ffi_interrupt_lower();
    assert_eq!(next_code(), KEY_PRESSED | KEY_INTERRUPT);
    assert_eq!(next_code(), KEY_PRESSED | KEY_INTERRUPT);
    assert!(post(key("g", control(false), true), None));
    assert!(editor_ffi_interrupt_raised());
    assert_eq!(next_code(), KEY_PRESSED | KEY_INTERRUPT);

    // The mark cannot be posted: a code that carries it is refused, and
    // raises nothing more.
    editor_ffi_interrupt_lower();
    assert!(!post(
        key("x", Modifiers::default(), true),
        Some(KEY_PRESSED | KEY_INTERRUPT)
    ));
    assert!(!editor_ffi_interrupt_raised());

    // Clearing the key leaves the count as it is, and nothing raises the
    // flag from then on.
    assert!(post(key("g", control(false), true), None));
    editor_ffi_interrupt_key_clear();
    assert!(editor_ffi_interrupt_raised());
    assert_eq!(next_code(), KEY_PRESSED | KEY_INTERRUPT);
    editor_ffi_interrupt_lower();
    assert!(post(key("g", control(false), true), None));
    assert!(!editor_ffi_interrupt_raised());
    assert_eq!(next_code(), KEY_PRESSED);
}
