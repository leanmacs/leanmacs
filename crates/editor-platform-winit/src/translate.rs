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
//!
//! # What winit says once
//!
//! winit says which modifiers are held when they change, and the port wants
//! them on every key. [`Seen`] remembers what winit last said and gives it
//! to what comes after.
//!
//! **Modifiers are those winit last reported**, and are not put right. On
//! X11 a modifier's own press arrives before the change that names it, so
//! the press of Control does not carry `control`, and its release still
//! does. No command binds a bare modifier, and the order on macOS has not
//! been seen.

use editor_platform::{Composition, Input, Key, Modifiers, Pointer, PointerAction};
use winit::event::{ElementState, Ime, WindowEvent};
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

/// What winit has said of the window so far that the port wants on what
/// comes after: winit says a thing once, when it changes, and the port
/// carries it on every input.
#[derive(Debug, Default)]
pub(crate) struct Seen {
    /// The modifiers held, as winit last reported them.
    modifiers: Modifiers,
}

impl Seen {
    /// The key event winit reports with these parts, as the port's input.
    pub(crate) fn key(&self, parts: &KeyParts<'_>) -> Input {
        let pressed = parts.state == ElementState::Pressed;
        Input::Key(Key {
            pressed,
            repeat: parts.repeat,
            logical: names::logical(parts.logical),
            physical: names::physical(parts.physical),
            modifiers: self.modifiers,
            text: text(pressed, parts.text),
        })
    }

    /// Takes in `event`, and gives what the port reports for it, if it
    /// reports anything. A key event goes through [`Seen::key`].
    pub(crate) fn window_event(&mut self, event: &WindowEvent) -> Option<Input> {
        match event {
            WindowEvent::ModifiersChanged(modifiers) => {
                let state = modifiers.state();
                self.modifiers = Modifiers {
                    shift: state.shift_key(),
                    control: state.control_key(),
                    alt: state.alt_key(),
                    super_key: state.super_key(),
                };
                None
            }
            WindowEvent::Focused(gained) => Some(Input::Focus(*gained)),
            WindowEvent::Ime(step) => Some(Input::Composition(match step {
                Ime::Enabled => Composition::Enabled,
                Ime::Preedit(text, _) => Composition::Preedit(text.clone()),
                Ime::Commit(text) => Composition::Commit(text.clone()),
                Ime::Disabled => Composition::Disabled,
            })),
            WindowEvent::MouseInput {
                state: ElementState::Pressed,
                ..
            } => Some(Input::Pointer(Pointer {
                action: PointerAction::Press,
                x: 0.0,
                y: 0.0,
                button: None,
                modifiers: Modifiers::default(),
            })),
            WindowEvent::CloseRequested => Some(Input::CloseRequested),
            _ => None,
        }
    }
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
    use super::{KeyParts, Seen};
    use editor_platform::{Composition, Input, Key, LogicalKey, Modifiers, PhysicalKey};
    use editor_platform::{Pointer, PointerAction};
    use winit::dpi::PhysicalSize;
    use winit::event::{DeviceId, ElementState, Ime, MouseButton, WindowEvent};
    use winit::keyboard::{
        Key as WinitKey, KeyCode, ModifiersState, NamedKey, NativeKeyCode, PhysicalKey as Physical,
    };

    /// The logical key for the character `text`.
    fn character(text: &str) -> WinitKey {
        WinitKey::Character(text.into())
    }

    /// What the port reports for a key with these parts in a window that
    /// has said nothing else.
    fn key(parts: &KeyParts<'_>) -> Input {
        Seen::default().key(parts)
    }

    /// What the port reports for `event` in a window that has said nothing
    /// else.
    fn translate(event: &WindowEvent) -> Option<Input> {
        Seen::default().window_event(event)
    }

    /// winit's word that the modifiers held are now `state`.
    fn modifiers_changed(state: ModifiersState) -> WindowEvent {
        WindowEvent::ModifiersChanged(state.into())
    }

    /// The port's modifiers with these held.
    fn held(shift: bool, control: bool, alt: bool, super_key: bool) -> Modifiers {
        Modifiers {
            shift,
            control,
            alt,
            super_key,
        }
    }

    #[test]
    fn a_key_carries_the_modifiers_winit_last_reported() {
        let mut seen = Seen::default();
        let logical = character("A");
        let parts = press(&logical, KeyCode::KeyA, Some("A"));
        let pressed = |modifiers| {
            Input::Key(Key {
                pressed: true,
                logical: LogicalKey::Character("A".into()),
                physical: code("KeyA"),
                modifiers,
                text: "A".into(),
                ..Key::unidentified()
            })
        };
        // Before winit has said anything, none is held.
        assert_eq!(seen.key(&parts), pressed(Modifiers::default()));

        // The change is nothing the port reports by itself.
        let both = ModifiersState::SHIFT | ModifiersState::CONTROL;
        assert_eq!(seen.window_event(&modifiers_changed(both)), None);
        assert_eq!(seen.key(&parts), pressed(held(true, true, false, false)));
        // And every key after it, until winit says otherwise.
        assert_eq!(seen.key(&parts), pressed(held(true, true, false, false)));

        // One released, then the other.
        seen.window_event(&modifiers_changed(ModifiersState::CONTROL));
        assert_eq!(seen.key(&parts), pressed(held(false, true, false, false)));
        seen.window_event(&modifiers_changed(ModifiersState::empty()));
        assert_eq!(seen.key(&parts), pressed(Modifiers::default()));
    }

    #[test]
    fn each_modifier_winit_names_is_the_ports_own() {
        for (state, modifiers) in [
            (ModifiersState::SHIFT, held(true, false, false, false)),
            (ModifiersState::CONTROL, held(false, true, false, false)),
            (ModifiersState::ALT, held(false, false, true, false)),
            (ModifiersState::SUPER, held(false, false, false, true)),
            (ModifiersState::all(), held(true, true, true, true)),
        ] {
            let mut seen = Seen::default();
            seen.window_event(&modifiers_changed(state));
            let logical = WinitKey::Named(NamedKey::ArrowLeft);
            assert_eq!(
                seen.key(&press(&logical, KeyCode::ArrowLeft, None)),
                Input::Key(Key {
                    pressed: true,
                    logical: named("ArrowLeft"),
                    physical: code("ArrowLeft"),
                    modifiers,
                    ..Key::unidentified()
                }),
                "{state:?}"
            );
        }
    }

    #[test]
    fn each_step_of_a_composition_is_reported() {
        let step = |ime| translate(&WindowEvent::Ime(ime));

        assert_eq!(
            step(Ime::Enabled),
            Some(Input::Composition(Composition::Enabled))
        );
        assert_eq!(
            step(Ime::Preedit("´".into(), Some((0, 2)))),
            Some(Input::Composition(Composition::Preedit("´".into())))
        );
        assert_eq!(
            step(Ime::Preedit(String::new(), None)),
            Some(Input::Composition(Composition::Preedit(String::new())))
        );
        assert_eq!(
            step(Ime::Commit("é".into())),
            Some(Input::Composition(Composition::Commit("é".into())))
        );
        assert_eq!(
            step(Ime::Disabled),
            Some(Input::Composition(Composition::Disabled))
        );
    }

    #[test]
    fn focus_gained_and_lost_are_reported() {
        assert_eq!(
            translate(&WindowEvent::Focused(true)),
            Some(Input::Focus(true))
        );
        assert_eq!(
            translate(&WindowEvent::Focused(false)),
            Some(Input::Focus(false))
        );
    }

    #[test]
    fn a_pressed_pointer_button_is_reported_as_a_press_at_the_origin_with_no_button_and_its_release_is_not()
     {
        let button = |state| WindowEvent::MouseInput {
            device_id: DeviceId::dummy(),
            state,
            button: MouseButton::Left,
        };

        assert_eq!(
            translate(&button(ElementState::Pressed)),
            Some(Input::Pointer(Pointer {
                action: PointerAction::Press,
                x: 0.0,
                y: 0.0,
                button: None,
                modifiers: Modifiers::default(),
            }))
        );
        assert_eq!(translate(&button(ElementState::Released)), None);
    }

    #[test]
    fn a_request_to_close_is_reported() {
        assert_eq!(
            translate(&WindowEvent::CloseRequested),
            Some(Input::CloseRequested)
        );
    }

    #[test]
    fn an_event_the_port_has_no_input_for_is_not_reported() {
        assert_eq!(
            translate(&WindowEvent::Resized(PhysicalSize::new(800, 600))),
            None
        );
        assert_eq!(translate(&WindowEvent::Destroyed), None);
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
    fn a_key_press_is_a_key_with_its_logical_key_physical_key_and_modifiers() {
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
        // With shift held the layout makes `A` of the same key, and the
        // modifier is carried beside it.
        let mut shifted = Seen::default();
        shifted.window_event(&modifiers_changed(ModifiersState::SHIFT));
        assert_eq!(
            shifted.key(&press(&character("A"), KeyCode::KeyA, Some("A"))),
            Input::Key(Key {
                pressed: true,
                repeat: false,
                logical: LogicalKey::Character("A".into()),
                physical: code("KeyA"),
                modifiers: held(true, false, false, false),
                text: "A".into(),
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
