//! A key's names: winit's logical and physical keys as the port's, whose
//! named keys and physical keys are W3C UI Events names.
//!
//! winit's `NamedKey` and `KeyCode` are the crate keyboard-types' `NamedKey`
//! and `Code`, which are the W3C UI Events `key` and `code` tables, and
//! whose `Display` is a variant's W3C name. A name is taken through it.
//! Both enums grow, and a key they add is named here the day the pin moves,
//! with nothing to list. The other way, a table written out, would be some
//! five hundred rows of two enums, and every key they add would be
//! unidentified until someone listed it.
//!
//! winit gives the system key as `Meta`, its codes as `MetaLeft` and
//! `MetaRight`, and Space as the character `" "` it types, as the
//! specification does, so no name is put right here. What is decided here:
//!
//! - **A key winit could not identify is unidentified**, whatever native
//!   number came with it: the port has no place for one.
//! - **keyboard-types' own `Unidentified`**, a variant of each enum, is the
//!   port's unidentified key too, and not a key named `Unidentified`.

use editor_platform::{LogicalKey, PhysicalKey};
use winit::keyboard::{Key, KeyCode, NamedKey, PhysicalKey as Physical};

/// What the keyboard layout makes of a key, as the port says it.
pub(crate) fn logical(key: &Key) -> LogicalKey {
    match key {
        Key::Character(characters) => LogicalKey::Character(characters.to_string()),
        Key::Named(NamedKey::Unidentified) => LogicalKey::Unidentified,
        Key::Named(named) => LogicalKey::Named(named.to_string()),
        Key::Dead(character) => LogicalKey::Dead(*character),
        _ => LogicalKey::Unidentified,
    }
}

/// Where a key is on the keyboard, as the port says it.
pub(crate) fn physical(key: Physical) -> PhysicalKey {
    match key {
        Physical::Code(KeyCode::Unidentified) => PhysicalKey::Unidentified,
        Physical::Code(code) => PhysicalKey::Code(code.to_string()),
        _ => PhysicalKey::Unidentified,
    }
}

#[cfg(test)]
mod tests {
    use super::{logical, physical};
    use editor_platform::{LogicalKey, PhysicalKey};
    use winit::keyboard::{
        Key, KeyCode, NamedKey, NativeKey, NativeKeyCode, PhysicalKey as Physical,
    };

    /// The port's named key `name`.
    fn named(name: &str) -> LogicalKey {
        LogicalKey::Named(name.into())
    }

    /// The port's physical key with the code `name`.
    fn code(name: &str) -> PhysicalKey {
        PhysicalKey::Code(name.into())
    }

    #[test]
    fn a_named_key_is_its_w3c_key_value() {
        for (key, name) in [
            (NamedKey::Escape, "Escape"),
            (NamedKey::ArrowLeft, "ArrowLeft"),
            (NamedKey::Enter, "Enter"),
            (NamedKey::F5, "F5"),
            (NamedKey::Shift, "Shift"),
            (NamedKey::PageDown, "PageDown"),
            (NamedKey::AltGraph, "AltGraph"),
        ] {
            assert_eq!(logical(&Key::Named(key)), named(name));
        }
    }

    #[test]
    fn the_system_key_is_named_meta_and_space_is_the_character_it_types() {
        assert_eq!(logical(&Key::Named(NamedKey::Meta)), named("Meta"));
        // winit gives Space as the character it types.
        assert_eq!(
            logical(&Key::Character(" ".into())),
            LogicalKey::Character(" ".into())
        );
    }

    #[test]
    fn a_character_key_is_its_characters_and_a_dead_key_its_character() {
        assert_eq!(
            logical(&Key::Character("a".into())),
            LogicalKey::Character("a".into())
        );
        assert_eq!(
            logical(&Key::Character("é".into())),
            LogicalKey::Character("é".into())
        );
        assert_eq!(logical(&Key::Dead(Some('´'))), LogicalKey::Dead(Some('´')));
        assert_eq!(logical(&Key::Dead(None)), LogicalKey::Dead(None));
    }

    #[test]
    fn a_physical_key_is_its_w3c_code() {
        for (key, name) in [
            (KeyCode::KeyA, "KeyA"),
            (KeyCode::Digit1, "Digit1"),
            (KeyCode::Escape, "Escape"),
            (KeyCode::ArrowLeft, "ArrowLeft"),
            (KeyCode::F5, "F5"),
            (KeyCode::ShiftLeft, "ShiftLeft"),
            (KeyCode::NumpadEnter, "NumpadEnter"),
        ] {
            assert_eq!(physical(Physical::Code(key)), code(name));
        }
    }

    #[test]
    fn the_system_keys_codes_are_meta_left_and_meta_right() {
        assert_eq!(
            physical(Physical::Code(KeyCode::MetaLeft)),
            code("MetaLeft")
        );
        assert_eq!(
            physical(Physical::Code(KeyCode::MetaRight)),
            code("MetaRight")
        );
    }

    #[test]
    fn keyboard_types_own_unidentified_is_unidentified() {
        assert_eq!(
            logical(&Key::Named(NamedKey::Unidentified)),
            LogicalKey::Unidentified
        );
        assert_eq!(
            physical(Physical::Code(KeyCode::Unidentified)),
            PhysicalKey::Unidentified
        );
    }

    #[test]
    fn a_key_winit_could_not_identify_is_unidentified() {
        assert_eq!(
            logical(&Key::Unidentified(NativeKey::Unidentified)),
            LogicalKey::Unidentified
        );
        assert_eq!(
            logical(&Key::Unidentified(NativeKey::Xkb(0x1008_ff02))),
            LogicalKey::Unidentified
        );
        assert_eq!(
            physical(Physical::Unidentified(NativeKeyCode::Unidentified)),
            PhysicalKey::Unidentified
        );
        assert_eq!(
            physical(Physical::Unidentified(NativeKeyCode::Xkb(240))),
            PhysicalKey::Unidentified
        );
    }
}
