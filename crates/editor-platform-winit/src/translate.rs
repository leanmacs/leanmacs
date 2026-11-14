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
//!
//! # The pointer
//!
//! winit says where the pointer is as it moves, and that a button went down
//! or came up with no position. So:
//!
//! - **A press and a release are where the pointer last was**, the origin
//!   before winit has said where that is.
//! - **A move with a button held is a drag**, carrying the button held
//!   longest. A move with none held is remembered and not reported: the
//!   port has no input for it.
//! - **A wheel carries winit's delta as it is**, in lines or in pixels, with
//!   no button. Positive is the content moving right and down.
//!
//! Touch is not mapped.
//!
//! # Size and scale
//!
//! winit says the window's size when it changes and its scale factor when
//! that does, each alone, and the port's resize carries both:
//!
//! - **A resize is the new size at the scale last known**, which is 1
//!   before winit has said.
//! - **A change of scale is a resize at the size last known and the new
//!   scale.** The size winit then gives the window arrives as a resize of
//!   its own. winit's event for it cannot be built outside winit either, so
//!   [`Seen::scale`] takes the scale alone, and the handler takes the event
//!   apart.
//! - **A window that opens says its size and scale** ([`Seen::opened`]),
//!   which the handler reports straight after `Opened`: nothing else in
//!   the port says how large a window is.

use editor_platform::{
    Button, Composition, Input, Key, Modifiers, Pointer, PointerAction, Resize, WheelDelta,
};
use winit::dpi::PhysicalSize;
use winit::event::{ElementState, Ime, MouseButton, MouseScrollDelta, WindowEvent};
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
#[derive(Debug)]
pub(crate) struct Seen {
    /// The modifiers held, as winit last reported them.
    modifiers: Modifiers,
    /// Where the pointer last was, in physical pixels from the window's top
    /// left; the origin until winit says.
    position: (f64, f64),
    /// The buttons held, in the order they went down.
    held: Vec<Button>,
    /// The window's drawable size, in physical pixels; none until winit
    /// says.
    size: PhysicalSize<u32>,
    /// The window's scale factor; 1 until winit says.
    scale: f64,
}

impl Default for Seen {
    /// What is known of a window winit has said nothing of.
    fn default() -> Self {
        Self {
            modifiers: Modifiers::default(),
            position: (0.0, 0.0),
            held: Vec::new(),
            size: PhysicalSize::new(0, 0),
            scale: 1.0,
        }
    }
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
            WindowEvent::CursorMoved { position, .. } => {
                self.position = (position.x, position.y);
                let dragged = self.held.first().copied()?;
                Some(self.pointer(PointerAction::Drag, Some(dragged)))
            }
            WindowEvent::MouseInput { state, button, .. } => {
                let button = button_of(*button);
                self.held.retain(|held| *held != button);
                let action = match state {
                    ElementState::Pressed => {
                        self.held.push(button);
                        PointerAction::Press
                    }
                    ElementState::Released => PointerAction::Release,
                };
                Some(self.pointer(action, Some(button)))
            }
            WindowEvent::MouseWheel { delta, .. } => {
                let delta = match delta {
                    MouseScrollDelta::LineDelta(x, y) => WheelDelta::Lines {
                        x: f64::from(*x),
                        y: f64::from(*y),
                    },
                    MouseScrollDelta::PixelDelta(by) => WheelDelta::Pixels { x: by.x, y: by.y },
                };
                Some(self.pointer(PointerAction::Wheel(delta), None))
            }
            WindowEvent::Resized(size) => {
                self.size = *size;
                Some(self.resized())
            }
            WindowEvent::CloseRequested => Some(Input::CloseRequested),
            _ => None,
        }
    }

    /// Takes in that the window has opened, `size` at `scale`, and gives
    /// what the port reports for it after [`Input::Opened`].
    pub(crate) fn opened(&mut self, size: PhysicalSize<u32>, scale: f64) -> Input {
        self.size = size;
        self.scale = scale;
        self.resized()
    }

    /// Takes in that the window's scale factor is now `scale`, and gives
    /// what the port reports for it. It takes the scale and not winit's
    /// whole event, which cannot be built outside winit.
    pub(crate) fn scale(&mut self, scale: f64) -> Option<Input> {
        self.scale = scale;
        Some(self.resized())
    }

    /// The window's size and scale as last known, as the port reports them.
    fn resized(&self) -> Input {
        Input::Resized(Resize {
            width: u64::from(self.size.width),
            height: u64::from(self.size.height),
            scale: self.scale,
        })
    }

    /// The pointer input of `action` with `button`, where the pointer last
    /// was and with the modifiers last reported.
    fn pointer(&self, action: PointerAction, button: Option<Button>) -> Input {
        Input::Pointer(Pointer {
            action,
            x: self.position.0,
            y: self.position.1,
            button,
            modifiers: self.modifiers,
        })
    }
}

/// winit's button as the port's.
///
/// The match is exhaustive on purpose: the adapter must give every button
/// winit names a [`Button`], so one winit adds has to be given its own here
/// before the crate builds.
fn button_of(button: MouseButton) -> Button {
    match button {
        MouseButton::Left => Button::Primary,
        MouseButton::Right => Button::Secondary,
        MouseButton::Middle => Button::Middle,
        MouseButton::Back => Button::Back,
        MouseButton::Forward => Button::Forward,
        MouseButton::Other(number) => Button::Other(number),
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
    use editor_platform::{Button, Composition, Input, Key, LogicalKey, Modifiers, PhysicalKey};
    use editor_platform::{Pointer, PointerAction, Resize, WheelDelta};
    use winit::dpi::{PhysicalPosition, PhysicalSize};
    use winit::event::{
        DeviceId, ElementState, Ime, MouseButton, MouseScrollDelta, TouchPhase, WindowEvent,
    };
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

    /// winit's word that `button` went down or came up.
    fn button(state: ElementState, button: MouseButton) -> WindowEvent {
        WindowEvent::MouseInput {
            device_id: DeviceId::dummy(),
            state,
            button,
        }
    }

    /// winit's word that the pointer is now at (`x`, `y`).
    fn moved(x: f64, y: f64) -> WindowEvent {
        WindowEvent::CursorMoved {
            device_id: DeviceId::dummy(),
            position: PhysicalPosition::new(x, y),
        }
    }

    /// The pointer input of `action` at `at` with `button`, with no
    /// modifier held, as the port reports it.
    fn pointer(action: PointerAction, at: (f64, f64), button: Option<Button>) -> Option<Input> {
        Some(Input::Pointer(Pointer {
            action,
            x: at.0,
            y: at.1,
            button,
            modifiers: Modifiers::default(),
        }))
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
    fn a_button_press_is_a_press_where_the_pointer_is_with_its_button_and_modifiers() {
        let mut seen = Seen::default();
        // A press before the pointer has been anywhere is at the origin.
        assert_eq!(
            seen.window_event(&button(ElementState::Pressed, MouseButton::Left)),
            pointer(PointerAction::Press, (0.0, 0.0), Some(Button::Primary))
        );
        seen.window_event(&button(ElementState::Released, MouseButton::Left));

        // The pointer moves, with no button held, and then a button goes
        // down with alt held: the press is where the pointer last was.
        assert_eq!(seen.window_event(&moved(12.5, 40.0)), None);
        seen.window_event(&modifiers_changed(ModifiersState::ALT));
        assert_eq!(
            seen.window_event(&button(ElementState::Pressed, MouseButton::Right)),
            Some(Input::Pointer(Pointer {
                action: PointerAction::Press,
                x: 12.5,
                y: 40.0,
                button: Some(Button::Secondary),
                modifiers: held(false, false, true, false),
            }))
        );
    }

    #[test]
    fn each_button_winit_names_is_the_ports_own() {
        for (given, button_of_the_port) in [
            (MouseButton::Left, Button::Primary),
            (MouseButton::Right, Button::Secondary),
            (MouseButton::Middle, Button::Middle),
            (MouseButton::Back, Button::Back),
            (MouseButton::Forward, Button::Forward),
            (MouseButton::Other(9), Button::Other(9)),
        ] {
            assert_eq!(
                translate(&button(ElementState::Pressed, given)),
                pointer(PointerAction::Press, (0.0, 0.0), Some(button_of_the_port)),
                "{given:?}"
            );
        }
    }

    #[test]
    fn a_move_with_a_button_held_is_a_drag_and_one_with_none_is_not_reported() {
        let mut seen = Seen::default();
        assert_eq!(seen.window_event(&moved(1.0, 2.0)), None);

        seen.window_event(&button(ElementState::Pressed, MouseButton::Left));
        assert_eq!(
            seen.window_event(&moved(30.0, 40.5)),
            pointer(PointerAction::Drag, (30.0, 40.5), Some(Button::Primary))
        );
        // A drag carries the modifiers held as it moves.
        seen.window_event(&modifiers_changed(ModifiersState::SHIFT));
        assert_eq!(
            seen.window_event(&moved(31.0, 41.0)),
            Some(Input::Pointer(Pointer {
                action: PointerAction::Drag,
                x: 31.0,
                y: 41.0,
                button: Some(Button::Primary),
                modifiers: held(true, false, false, false),
            }))
        );
        seen.window_event(&modifiers_changed(ModifiersState::empty()));

        // With the button up again a move is not reported, and is still
        // where the next press is.
        seen.window_event(&button(ElementState::Released, MouseButton::Left));
        assert_eq!(seen.window_event(&moved(50.0, 60.0)), None);
        assert_eq!(
            seen.window_event(&button(ElementState::Pressed, MouseButton::Middle)),
            pointer(PointerAction::Press, (50.0, 60.0), Some(Button::Middle))
        );
    }

    #[test]
    fn a_drag_carries_the_button_held_longest() {
        let mut seen = Seen::default();
        seen.window_event(&button(ElementState::Pressed, MouseButton::Right));
        seen.window_event(&button(ElementState::Pressed, MouseButton::Left));
        assert_eq!(
            seen.window_event(&moved(5.0, 5.0)),
            pointer(PointerAction::Drag, (5.0, 5.0), Some(Button::Secondary))
        );
        // The first comes up: the other is now the one held longest.
        seen.window_event(&button(ElementState::Released, MouseButton::Right));
        assert_eq!(
            seen.window_event(&moved(6.0, 6.0)),
            pointer(PointerAction::Drag, (6.0, 6.0), Some(Button::Primary))
        );
        seen.window_event(&button(ElementState::Released, MouseButton::Left));
        assert_eq!(seen.window_event(&moved(7.0, 7.0)), None);
    }

    #[test]
    fn a_button_release_is_a_release() {
        let mut seen = Seen::default();
        seen.window_event(&moved(10.0, 20.0));
        seen.window_event(&button(ElementState::Pressed, MouseButton::Left));
        seen.window_event(&moved(30.0, 40.0));
        assert_eq!(
            seen.window_event(&button(ElementState::Released, MouseButton::Left)),
            pointer(PointerAction::Release, (30.0, 40.0), Some(Button::Primary))
        );
        // A button that went down outside the window comes up in it: the
        // release is reported all the same.
        assert_eq!(
            seen.window_event(&button(ElementState::Released, MouseButton::Back)),
            pointer(PointerAction::Release, (30.0, 40.0), Some(Button::Back))
        );
    }

    #[test]
    fn a_wheel_turn_is_a_wheel_in_lines_or_in_pixels() {
        let mut seen = Seen::default();
        seen.window_event(&moved(10.0, 20.0));
        seen.window_event(&modifiers_changed(ModifiersState::CONTROL));
        let wheel = |delta| WindowEvent::MouseWheel {
            device_id: DeviceId::dummy(),
            delta,
            phase: TouchPhase::Moved,
        };
        let turned = |delta| {
            Some(Input::Pointer(Pointer {
                action: PointerAction::Wheel(delta),
                x: 10.0,
                y: 20.0,
                button: None,
                modifiers: held(false, true, false, false),
            }))
        };

        // winit's delta as it is, sign and all: a notch of a wheel, and a
        // trackpad's pixels.
        assert_eq!(
            seen.window_event(&wheel(MouseScrollDelta::LineDelta(0.0, -1.0))),
            turned(WheelDelta::Lines { x: 0.0, y: -1.0 })
        );
        assert_eq!(
            seen.window_event(&wheel(MouseScrollDelta::LineDelta(1.0, 0.0))),
            turned(WheelDelta::Lines { x: 1.0, y: 0.0 })
        );
        assert_eq!(
            seen.window_event(&wheel(MouseScrollDelta::PixelDelta(PhysicalPosition::new(
                -3.5, 12.25
            )))),
            turned(WheelDelta::Pixels { x: -3.5, y: 12.25 })
        );

        // A wheel turned with a button held has no button of its own.
        seen.window_event(&button(ElementState::Pressed, MouseButton::Left));
        assert_eq!(
            seen.window_event(&wheel(MouseScrollDelta::LineDelta(0.0, 2.0))),
            turned(WheelDelta::Lines { x: 0.0, y: 2.0 })
        );
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
        assert_eq!(translate(&WindowEvent::Destroyed), None);
        assert_eq!(
            translate(&WindowEvent::Moved(PhysicalPosition::new(10, 20))),
            None
        );
        assert_eq!(
            translate(&WindowEvent::CursorLeft {
                device_id: DeviceId::dummy()
            }),
            None
        );
    }

    /// The port's word that the window is `width` by `height` at `scale`.
    fn resized(width: u64, height: u64, scale: f64) -> Input {
        Input::Resized(Resize {
            width,
            height,
            scale,
        })
    }

    #[test]
    fn a_resize_is_the_new_size_at_the_scale_last_known() {
        let mut seen = Seen::default();
        // Before winit has said what the scale is, it is 1.
        assert_eq!(
            seen.window_event(&WindowEvent::Resized(PhysicalSize::new(800, 600))),
            Some(resized(800, 600, 1.0))
        );
        seen.scale(2.0);
        assert_eq!(
            seen.window_event(&WindowEvent::Resized(PhysicalSize::new(300, 120))),
            Some(resized(300, 120, 2.0))
        );
    }

    #[test]
    fn a_change_of_scale_is_a_resize_at_the_new_scale() {
        let mut seen = Seen::default();
        seen.window_event(&WindowEvent::Resized(PhysicalSize::new(800, 600)));
        // The size is the one last known. The size winit then gives the
        // window arrives as a resize of its own.
        assert_eq!(seen.scale(2.0), Some(resized(800, 600, 2.0)));
        assert_eq!(
            seen.window_event(&WindowEvent::Resized(PhysicalSize::new(1600, 1200))),
            Some(resized(1600, 1200, 2.0))
        );
        assert_eq!(seen.scale(1.25), Some(resized(1600, 1200, 1.25)));
    }

    #[test]
    fn a_window_that_opens_says_its_size_and_scale_which_are_then_the_ones_last_known() {
        let mut seen = Seen::default();
        assert_eq!(
            seen.opened(PhysicalSize::new(256, 96), 1.5),
            resized(256, 96, 1.5)
        );
        // A resize is at the scale the window opened at, and a change of
        // scale at the size it opened at.
        let mut resized_after = Seen::default();
        resized_after.opened(PhysicalSize::new(256, 96), 1.5);
        assert_eq!(
            resized_after.window_event(&WindowEvent::Resized(PhysicalSize::new(300, 120))),
            Some(resized(300, 120, 1.5))
        );
        assert_eq!(seen.scale(3.0), Some(resized(256, 96, 3.0)));
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
