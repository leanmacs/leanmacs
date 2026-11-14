//! A key's names: winit's logical and physical keys as the port's, whose
//! named keys and physical keys are W3C UI Events names.
//!
//! winit's `NamedKey` and `KeyCode` follow the W3C UI Events `key` and
//! `code` tables, and say so, so a variant's own name is the W3C name: it is
//! taken through `Debug`. Both enums grow, and a key winit adds is named
//! here the day the pin moves, with nothing to list. The other way, a table
//! written out, would be some five hundred rows of two enums, and every key
//! winit adds would be unidentified until someone listed it.
//!
//! winit documents where its names are not the specification's, and those
//! are the whole of what is decided here:
//!
//! | winit | The port |
//! |---|---|
//! | `NamedKey::Super` | The named key `Meta` |
//! | `NamedKey::Space` | The character `" "`: the specification identifies the key by what it types |
//! | `KeyCode::SuperLeft`, `KeyCode::SuperRight` | The codes `MetaLeft`, `MetaRight` |
//!
//! A key winit could not identify is unidentified here, whatever native
//! number came with it: the port has no place for one.

use editor_platform::{LogicalKey, PhysicalKey};
use winit::keyboard::{Key, KeyCode, NamedKey, PhysicalKey as Physical};

/// What the keyboard layout makes of a key, as the port says it.
pub(crate) fn logical(key: &Key) -> LogicalKey {
    match key {
        Key::Character(characters) => LogicalKey::Character(characters.to_string()),
        Key::Named(NamedKey::Space) => LogicalKey::Character(" ".into()),
        Key::Named(NamedKey::Super) => LogicalKey::Named("Meta".into()),
        Key::Named(named) => LogicalKey::Named(format!("{named:?}")),
        Key::Dead(character) => LogicalKey::Dead(*character),
        _ => LogicalKey::Unidentified,
    }
}

/// Where a key is on the keyboard, as the port says it.
pub(crate) fn physical(key: Physical) -> PhysicalKey {
    match key {
        Physical::Code(KeyCode::SuperLeft) => PhysicalKey::Code("MetaLeft".into()),
        Physical::Code(KeyCode::SuperRight) => PhysicalKey::Code("MetaRight".into()),
        Physical::Code(code) => PhysicalKey::Code(format!("{code:?}")),
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
        assert_eq!(logical(&Key::Named(NamedKey::Super)), named("Meta"));
        assert_eq!(
            logical(&Key::Named(NamedKey::Space)),
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
            physical(Physical::Code(KeyCode::SuperLeft)),
            code("MetaLeft")
        );
        assert_eq!(
            physical(Physical::Code(KeyCode::SuperRight)),
            code("MetaRight")
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
