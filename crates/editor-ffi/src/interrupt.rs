//! The interrupt flag: raised as the interrupt key arrives.
//!
//! A command that runs for long holds the editor thread, and the key that
//! asks it to stop is behind it on the editor queue. So the library looks
//! at each input as it arrives, before it is queued, and raises a flag for
//! a press of the interrupt key. Lean asks the flag between the steps of a
//! command.
//!
//! The primitive is here and the policy is Lean's
//! (`lean/Editor/Watch.lean`, `lean/Editor/Loop.lean`):
//!
//! - **Which key** is told by Lean ([`editor_ffi_interrupt_key_set`]): a
//!   logical key, the modifiers it is pressed with, and a mask of the
//!   modifiers to compare ([`InterruptKey`]). What "the same key" means is
//!   Lean's rule for a chord, which leaves shift out for a character and
//!   keeps it for a named key: the mask carries it. This module compares
//!   the words it was given and knows no such rule. With no key set,
//!   nothing raises the flag.
//! - **The flag is a count** ([`Interrupt`]): how many presses of the
//!   interrupt key have arrived and have not been taken off the queue. It
//!   is up while the count is not 0. With `A`, the key, `B`, the key
//!   queued, taking the first must not lower the flag for `B`, which is
//!   still ahead of an interrupt key.
//! - **Arriving raises it** ([`Interrupt::arrived`]), on the arrival path of
//!   the editor queue ([`crate::window::arrive`]), which also marks the
//!   event ([`crate::window::KEY_INTERRUPT`]). So the library decides once
//!   which event is an interrupt key, and the mark says which.
//! - **Lean lowers it** ([`editor_ffi_interrupt_lower`]), once for each
//!   marked event it takes off the queue, and asks it
//!   ([`editor_ffi_interrupt_raised`]) when it chooses. Nothing here lowers
//!   the flag when an event is pulled.
//! - **Setting or clearing the key does not touch the count**: the events
//!   already marked are still on the queue, and are still lowered for.
//!
//! The process has one flag, the private static `INTERRUPT`, which the
//! process's window and the C functions at the bottom share. The type is public and has no
//! process-wide state of its own, so a test makes its own.
//!
//! Tests: the unit tests here, on a flag of their own; the tests of
//! `window.rs` for the arrival path, on a flag and a queue of their own;
//! `the_interrupt_key_raises_the_flag_as_it_arrives_and_lean_lowers_it` in
//! `tests/interrupt.rs`, an integration test of its own because the flag
//! and the queue are process-wide. On the Lean side: `interruptChecks` of
//! `ffi-test`, and the watch port's contract in `contract-test`.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard, PoisonError};

use editor_platform::{Input, Key, LogicalKey};

use crate::window;
use crate::words::{self, Reader};

/// The interrupt key, as Lean told it: what a press must be to raise the
/// flag.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InterruptKey {
    /// The logical key.
    pub logical: LogicalKey,
    /// The modifiers held, of those `mask` names, as a word of bits
    /// ([`window::MODIFIER_SHIFT`] and the rest).
    pub modifiers: u64,
    /// The modifiers that are compared, as a word of the same bits. A
    /// modifier outside the mask may be held or not.
    pub mask: u64,
}

impl InterruptKey {
    /// Whether `key` is a press of this key: it went down, a repeat
    /// included, it is the same logical key, and of the modifiers the mask
    /// names exactly these are held.
    pub fn matches(&self, key: &Key) -> bool {
        key.pressed
            && key.logical == self.logical
            && window::modifier_bits(key.modifiers) & self.mask == self.modifiers
    }
}

/// The interrupt flag, and the key that raises it.
#[derive(Debug, Default)]
pub struct Interrupt {
    /// The interrupt key; `None` when Lean has told none.
    key: Mutex<Option<InterruptKey>>,
    /// How many presses of the interrupt key have arrived and have not been
    /// lowered for. The flag is up while this is not 0.
    pending: AtomicU64,
}

impl Interrupt {
    /// A flag that is down, with no interrupt key.
    pub const fn new() -> Self {
        Self {
            key: Mutex::new(None),
            pending: AtomicU64::new(0),
        }
    }

    /// Makes `key` the interrupt key, or no key at all. The count is left
    /// as it is.
    pub fn set_key(&self, key: Option<InterruptKey>) {
        *self.key() = key;
    }

    /// Tells the flag that `input` is arriving. When it is a press of the
    /// interrupt key, counts it, so the flag is up, and returns true: the
    /// caller marks the event it queues. Anything else changes nothing.
    pub fn arrived(&self, input: &Input) -> bool {
        let Input::Key(key) = input else {
            return false;
        };
        let interrupts = self.key().as_ref().is_some_and(|set| set.matches(key));
        if interrupts {
            self.pending.fetch_add(1, Ordering::SeqCst);
        }
        interrupts
    }

    /// Whether the flag is up: a press of the interrupt key has arrived and
    /// has not been lowered for.
    pub fn raised(&self) -> bool {
        self.pending.load(Ordering::SeqCst) > 0
    }

    /// One press of the interrupt key was taken off the queue: one fewer
    /// holds the flag up. With none counted, nothing.
    pub fn lower(&self) {
        // An update that is refused left the count at 0, which is the
        // answer wanted.
        let _ = self
            .pending
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |pending| {
                pending.checked_sub(1)
            });
    }

    /// Locks the key. The lock is never held while other code runs, so a
    /// poisoned lock still guards a consistent key.
    fn key(&self) -> MutexGuard<'_, Option<InterruptKey>> {
        self.key.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// The process's interrupt flag.
pub(crate) static INTERRUPT: Interrupt = Interrupt::new();

/// The interrupt key the words in `words` stand for: `[logical tag, n, n
/// scalars, modifiers, mask]`, the logical key as in a key event's words
/// (the table in `window.rs`). `None` for words that do not read
/// (`words.rs`): a length that is not whole words, too few words or words
/// left over, an unknown tag, a scalar that is not a `char`, a bit past
/// the system key's in the modifiers or in the mask, or a modifier the
/// mask does not name.
fn read(words: &[u8]) -> Option<InterruptKey> {
    let mut reader = Reader::new(words)?;
    let logical = window::read_logical(&mut reader)?;
    let modifiers = reader.word()?;
    let mask = reader.word()?;
    reader.finish()?;
    (mask & !window::MODIFIERS == 0 && modifiers & !mask == 0).then_some(InterruptKey {
        logical,
        modifiers,
        mask,
    })
}

/// Makes the key the words in `words` stand for the process's interrupt
/// key: `[logical tag, n, n scalars, modifiers, mask]`, the logical key as
/// in a key event's words, and the modifiers and the mask each a word of
/// modifier bits. From then on a press of that key, with exactly those of
/// the masked modifiers held, raises the flag as it arrives.
///
/// Returns false, changing nothing, for words that do not read. The count
/// is left as it is either way.
///
/// # Safety
///
/// `words` points to `words_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_interrupt_key_set(words: *const u8, words_len: usize) -> bool {
    // SAFETY: the caller guarantees the pointer and its length.
    let words = unsafe { words::borrow(words, words_len) };
    read(words).is_some_and(|key| {
        INTERRUPT.set_key(Some(key));
        true
    })
}

/// Leaves the process with no interrupt key: nothing raises the flag until
/// one is set again. The count is left as it is.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_interrupt_key_clear() {
    INTERRUPT.set_key(None);
}

/// Whether the process's interrupt flag is up.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_interrupt_raised() -> bool {
    INTERRUPT.raised()
}

/// Tells the process's interrupt flag that one press of the interrupt key
/// was taken off the queue. With none counted, nothing.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_interrupt_lower() {
    INTERRUPT.lower();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::window::{MODIFIER_ALT, MODIFIER_CONTROL, MODIFIER_SHIFT, MODIFIER_SUPER};
    use editor_platform::{Modifiers, Resize};

    /// The modifiers with exactly these held.
    fn held(shift: bool, control: bool, alt: bool, super_key: bool) -> Modifiers {
        Modifiers {
            shift,
            control,
            alt,
            super_key,
        }
    }

    /// A press of the character `text` with `modifiers` held.
    fn press(text: &str, modifiers: Modifiers) -> Key {
        Key {
            pressed: true,
            logical: LogicalKey::Character(text.into()),
            modifiers,
            ..Key::unidentified()
        }
    }

    /// The key `C-g` as Lean tells it: the character `g` with control held,
    /// and every modifier compared but shift.
    fn control_g() -> InterruptKey {
        InterruptKey {
            logical: LogicalKey::Character("g".into()),
            modifiers: MODIFIER_CONTROL,
            mask: MODIFIER_CONTROL | MODIFIER_ALT | MODIFIER_SUPER,
        }
    }

    /// A flag whose interrupt key is `C-g`.
    fn watching() -> Interrupt {
        let interrupt = Interrupt::new();
        interrupt.set_key(Some(control_g()));
        interrupt
    }

    #[test]
    fn a_press_of_the_interrupt_key_raises_the_flag_and_is_said_to() {
        let interrupt = watching();
        assert!(!interrupt.raised());

        let counted = interrupt.arrived(&Input::Key(press("g", held(false, true, false, false))));

        assert!(counted);
        assert!(interrupt.raised());
    }

    #[test]
    fn a_repeated_press_of_the_interrupt_key_raises_the_flag_too() {
        let interrupt = watching();
        let repeat = Key {
            repeat: true,
            ..press("g", held(false, true, false, false))
        };

        assert!(interrupt.arrived(&Input::Key(repeat)));
        assert!(interrupt.raised());
    }

    #[test]
    fn a_release_another_key_and_the_key_with_another_modifier_raise_nothing() {
        let interrupt = watching();
        let control = held(false, true, false, false);
        let release = Key {
            pressed: false,
            ..press("g", control)
        };
        let named = Key {
            logical: LogicalKey::Named("g".into()),
            ..press("g", control)
        };

        for key in [
            release,
            press("x", control),
            press("G", control),
            press("g", held(false, false, false, false)),
            press("g", held(false, true, true, false)),
            press("g", held(false, true, false, true)),
            named,
        ] {
            assert!(
                !interrupt.arrived(&Input::Key(key.clone())),
                "{key:?} is not the interrupt key"
            );
        }
        assert!(!interrupt.raised());
    }

    #[test]
    fn an_input_that_is_not_a_key_raises_nothing() {
        let interrupt = watching();

        for input in [
            Input::Focus(true),
            Input::Resized(Resize {
                width: 1,
                height: 1,
                scale: 1.0,
                fullscreen: false,
            }),
            Input::CloseRequested,
        ] {
            assert!(!interrupt.arrived(&input));
        }
        assert!(!interrupt.raised());
    }

    #[test]
    fn a_modifier_the_mask_leaves_out_is_not_compared_and_one_it_names_is() {
        // The mask of `C-g` leaves shift out: held or not, it is the key.
        let interrupt = watching();
        assert!(interrupt.arrived(&Input::Key(press("g", held(true, true, false, false)))));

        // A named key's mask names shift: the key with shift held is another.
        let tab = InterruptKey {
            logical: LogicalKey::Named("Tab".into()),
            modifiers: MODIFIER_CONTROL,
            mask: MODIFIER_SHIFT | MODIFIER_CONTROL | MODIFIER_ALT | MODIFIER_SUPER,
        };
        let named = |modifiers| Key {
            pressed: true,
            logical: LogicalKey::Named("Tab".into()),
            modifiers,
            ..Key::unidentified()
        };
        assert!(tab.matches(&named(held(false, true, false, false))));
        assert!(!tab.matches(&named(held(true, true, false, false))));
    }

    #[test]
    fn the_flag_stays_up_until_it_is_lowered_and_asking_does_not_lower_it() {
        let interrupt = watching();
        interrupt.arrived(&Input::Key(press("g", held(false, true, false, false))));

        assert!(interrupt.raised());
        assert!(interrupt.raised());
        interrupt.lower();

        assert!(!interrupt.raised());
    }

    #[test]
    fn two_arrivals_need_two_lowers() {
        let interrupt = watching();
        let key = Input::Key(press("g", held(false, true, false, false)));
        interrupt.arrived(&key);
        interrupt.arrived(&key);

        interrupt.lower();
        assert!(interrupt.raised(), "one press is still on the queue");
        interrupt.lower();

        assert!(!interrupt.raised());
    }

    #[test]
    fn a_lower_with_none_counted_is_nothing_and_the_next_arrival_still_raises() {
        let interrupt = watching();

        interrupt.lower();
        interrupt.lower();
        assert!(!interrupt.raised());
        interrupt.arrived(&Input::Key(press("g", held(false, true, false, false))));

        assert!(interrupt.raised());
    }

    #[test]
    fn with_no_interrupt_key_nothing_raises_the_flag() {
        let interrupt = Interrupt::new();
        let key = Input::Key(press("g", held(false, true, false, false)));

        assert!(!interrupt.arrived(&key));
        assert!(!interrupt.raised());

        interrupt.set_key(Some(control_g()));
        interrupt.set_key(None);
        assert!(!interrupt.arrived(&key));
        assert!(!interrupt.raised());
    }

    #[test]
    fn setting_and_clearing_the_key_leave_the_count_as_it_is() {
        let interrupt = watching();
        interrupt.arrived(&Input::Key(press("g", held(false, true, false, false))));

        interrupt.set_key(None);
        assert!(interrupt.raised());
        interrupt.set_key(Some(control_g()));
        assert!(interrupt.raised());
        interrupt.lower();

        assert!(!interrupt.raised());
    }

    /// The interrupt key the words `words` read as.
    fn read_words(words: &[u64]) -> Option<InterruptKey> {
        read(&crate::words::tests::buffer(words))
    }

    #[test]
    fn a_key_reads_from_its_logical_key_its_modifiers_and_its_mask() {
        assert_eq!(read_words(&[1, 1, 103, 2, 14]), Some(control_g()));
        let tab: Vec<u64> = "Tab".chars().map(u64::from).collect();
        let mut words = vec![2, 3];
        words.extend(&tab);
        words.extend([0, 15]);
        assert_eq!(
            read_words(&words),
            Some(InterruptKey {
                logical: LogicalKey::Named("Tab".into()),
                modifiers: 0,
                mask: 15,
            })
        );
    }

    #[test]
    fn words_that_do_not_read_are_no_key() {
        // Not whole words.
        let mut bytes = crate::words::tests::buffer(&[1, 1, 103, 2, 14]);
        bytes.pop();
        assert_eq!(read(&bytes), None);
        // Too few, and one left over.
        assert_eq!(read_words(&[1, 1, 103, 2]), None);
        assert_eq!(read_words(&[1, 1, 103, 2, 14, 0]), None);
        // An unknown tag, and a scalar that is not a character.
        assert_eq!(read_words(&[4, 0, 2, 14]), None);
        assert_eq!(read_words(&[1, 1, 0xD800, 2, 14]), None);
        // A bit past the system key's, in the modifiers and in the mask.
        assert_eq!(read_words(&[1, 1, 103, 16, 31]), None);
        assert_eq!(read_words(&[1, 1, 103, 2, 16 | 2]), None);
        // A modifier the mask does not name.
        assert_eq!(read_words(&[1, 1, 103, 3, 14]), None);
        assert_eq!(read_words(&[]), None);
    }
}
