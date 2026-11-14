//! The translation: what winit reports about a window, as the port's
//! [`Input`].
//!
//! # A key
//!
//! winit's key event cannot be built outside winit (one of its fields is
//! private to it), so a key is translated from its parts, [`KeyParts`], each
//! a winit value a test builds. The one line that takes an event apart into
//! them is in the window's handler (`App::window_event` in `lib.rs`), which
//! only a real window runs.
//!
//! A key's names are the module [`names`]'s. Its text is what the port
//! documents, which is not always what winit gives:
//!
//! - **A release carries no text.** winit on X11 gives a release the text of
//!   its press.
//! - **A control character is not text.** winit on X11 gives Escape the
//!   text U+001B, and Enter, Tab and Backspace theirs. Such a key produced
//!   nothing to insert and is known by its name, so text that holds a
//!   control character is no text.

use editor_platform::{Input, Key};
use winit::event::ElementState;
use winit::keyboard;

use crate::names;

/// The parts of winit's key event that the port's key is made of.
#[derive(Debug, Clone, Copy)]
pub(crate) struct KeyParts<'a> {
    /// Whether the key went down or came up.
    pub state: ElementState,
    /// Whether winit repeated the press because the key is held.
    pub repeat: bool,
    /// What the layout makes of the key.
    pub logical: &'a keyboard::Key,
    /// Where the key is.
    pub physical: keyboard::PhysicalKey,
    /// The text winit says the key produced.
    pub text: Option<&'a str>,
}

/// The key event winit reports with these parts, as the port's input.
pub(crate) fn key(parts: &KeyParts<'_>) -> Input {
    let pressed = parts.state == ElementState::Pressed;
    Input::Key(Key {
        pressed,
        repeat: parts.repeat,
        logical: names::logical(parts.logical),
        physical: names::physical(parts.physical),
        text: text(pressed, parts.text),
        ..Key::unidentified()
    })
}

/// The text a key produced, as the port documents it, from what winit says
/// it produced: none for a release, and none where what winit gives holds a
/// control character.
fn text(pressed: bool, given: Option<&str>) -> String {
    given
        .filter(|text| pressed && !text.chars().any(char::is_control))
        .unwrap_or_default()
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::{KeyParts, key};
    use editor_platform::{Input, Key, LogicalKey, PhysicalKey};
    use winit::event::ElementState;
    use winit::keyboard::{
        Key as WinitKey, KeyCode, NamedKey, NativeKeyCode, PhysicalKey as Physical,
    };

    /// The logical key for the character `text`.
    fn character(text: &str) -> WinitKey {
        WinitKey::Character(text.into())
    }

    /// The parts of a press of the key `logical` at `code` that produced
    /// `text`, not repeated.
    fn press<'a>(logical: &'a WinitKey, code: KeyCode, text: Option<&'a str>) -> KeyParts<'a> {
        KeyParts {
            state: ElementState::Pressed,
            repeat: false,
            logical,
            physical: Physical::Code(code),
            text,
        }
    }

    /// The port's named key `name`.
    fn named(name: &str) -> LogicalKey {
        LogicalKey::Named(name.into())
    }

    /// The port's physical key with the code `name`.
    fn code(name: &str) -> PhysicalKey {
        PhysicalKey::Code(name.into())
    }

    #[test]
    fn a_key_press_is_a_key_with_its_logical_key_and_physical_key() {
        assert_eq!(
            key(&press(&character("a"), KeyCode::KeyA, Some("a"))),
            Input::Key(Key {
                pressed: true,
                logical: LogicalKey::Character("a".into()),
                physical: code("KeyA"),
                text: "a".into(),
                ..Key::unidentified()
            })
        );
        // The layout's character and the key's place are told apart: `é`
        // typed on the key that is `2` on a US keyboard.
        assert_eq!(
            key(&press(&character("é"), KeyCode::Digit2, Some("é"))),
            Input::Key(Key {
                pressed: true,
                logical: LogicalKey::Character("é".into()),
                physical: code("Digit2"),
                text: "é".into(),
                ..Key::unidentified()
            })
        );
    }

    #[test]
    fn a_named_key_is_its_w3c_key_value_and_code() {
        for (logical, physical, name) in [
            (NamedKey::Escape, KeyCode::Escape, "Escape"),
            (NamedKey::ArrowLeft, KeyCode::ArrowLeft, "ArrowLeft"),
            (NamedKey::F5, KeyCode::F5, "F5"),
        ] {
            assert_eq!(
                key(&press(&WinitKey::Named(logical), physical, None)),
                Input::Key(Key {
                    pressed: true,
                    logical: named(name),
                    physical: code(name),
                    ..Key::unidentified()
                })
            );
        }
        // A key's name and its place are two things: Shift is one name at
        // two places.
        assert_eq!(
            key(&press(
                &WinitKey::Named(NamedKey::Shift),
                KeyCode::ShiftRight,
                None
            )),
            Input::Key(Key {
                pressed: true,
                logical: named("Shift"),
                physical: code("ShiftRight"),
                ..Key::unidentified()
            })
        );
    }

    #[test]
    fn a_key_at_a_place_winit_cannot_name_has_no_physical_key() {
        let logical = character("a");
        let parts = KeyParts {
            physical: Physical::Unidentified(NativeKeyCode::Xkb(240)),
            ..press(&logical, KeyCode::KeyA, Some("a"))
        };
        assert_eq!(
            key(&parts),
            Input::Key(Key {
                pressed: true,
                logical: LogicalKey::Character("a".into()),
                physical: PhysicalKey::Unidentified,
                text: "a".into(),
                ..Key::unidentified()
            })
        );
    }

    #[test]
    fn a_repeated_press_is_marked_a_repeat() {
        let logical = character("a");
        let parts = KeyParts {
            repeat: true,
            ..press(&logical, KeyCode::KeyA, Some("a"))
        };
        assert_eq!(
            key(&parts),
            Input::Key(Key {
                pressed: true,
                repeat: true,
                logical: LogicalKey::Character("a".into()),
                physical: code("KeyA"),
                text: "a".into(),
                ..Key::unidentified()
            })
        );
    }

    #[test]
    fn a_dead_key_is_a_dead_logical_key_with_its_character_and_has_no_text() {
        assert_eq!(
            key(&press(&WinitKey::Dead(Some('´')), KeyCode::Quote, None)),
            Input::Key(Key {
                pressed: true,
                logical: LogicalKey::Dead(Some('´')),
                physical: code("Quote"),
                ..Key::unidentified()
            })
        );
        assert_eq!(
            key(&press(&WinitKey::Dead(None), KeyCode::Quote, None)),
            Input::Key(Key {
                pressed: true,
                logical: LogicalKey::Dead(None),
                physical: code("Quote"),
                ..Key::unidentified()
            })
        );
    }

    #[test]
    fn a_release_and_a_control_character_carry_no_text() {
        // A release, to which winit on X11 gives the text of its press.
        let logical = character("a");
        let release = KeyParts {
            state: ElementState::Released,
            ..press(&logical, KeyCode::KeyA, Some("a"))
        };
        assert_eq!(
            key(&release),
            Input::Key(Key {
                pressed: false,
                logical: LogicalKey::Character("a".into()),
                physical: code("KeyA"),
                ..Key::unidentified()
            })
        );
        // The keys winit on X11 gives a control character as text: each is
        // known by its name and produced nothing.
        for (logical, physical, name, text) in [
            (NamedKey::Escape, KeyCode::Escape, "Escape", "\u{1b}"),
            (NamedKey::Enter, KeyCode::Enter, "Enter", "\r"),
            (NamedKey::Tab, KeyCode::Tab, "Tab", "\t"),
            (
                NamedKey::Backspace,
                KeyCode::Backspace,
                "Backspace",
                "\u{8}",
            ),
            (NamedKey::Delete, KeyCode::Delete, "Delete", "\u{7f}"),
        ] {
            assert_eq!(
                key(&press(&WinitKey::Named(logical), physical, Some(text))),
                Input::Key(Key {
                    pressed: true,
                    logical: named(name),
                    physical: code(name),
                    ..Key::unidentified()
                }),
                "{name}"
            );
        }
        // A letter typed with control held, where the system gives the
        // control character it stands for.
        assert_eq!(
            key(&press(&character("a"), KeyCode::KeyA, Some("\u{1}"))),
            Input::Key(Key {
                pressed: true,
                logical: LogicalKey::Character("a".into()),
                physical: code("KeyA"),
                ..Key::unidentified()
            })
        );
        // Space is text: it is not a control character.
        assert_eq!(
            key(&press(
                &WinitKey::Named(NamedKey::Space),
                KeyCode::Space,
                Some(" ")
            )),
            Input::Key(Key {
                pressed: true,
                logical: LogicalKey::Character(" ".into()),
                physical: code("Space"),
                text: " ".into(),
                ..Key::unidentified()
            })
        );
    }
}
