//! Input, for a person: each input the window reports, in words, and the
//! input an event reads back as.

use editor_ffi::events::Event;
use editor_ffi::window;
use editor_platform::{
    Button, Composition, Input, Key, LogicalKey, Modifiers, PhysicalKey, Pointer, PointerAction,
    WheelDelta,
};

/// The modifiers held, for a person: `shift+control`, or `none`.
fn held(modifiers: Modifiers) -> String {
    let names: Vec<&str> = [
        (modifiers.shift, "shift"),
        (modifiers.control, "control"),
        (modifiers.alt, "alt"),
        (modifiers.super_key, "super"),
    ]
    .into_iter()
    .filter_map(|(held, name)| held.then_some(name))
    .collect();
    if names.is_empty() {
        "none".to_owned()
    } else {
        names.join("+")
    }
}

/// A key, for a person.
fn key(key: &Key) -> String {
    let what = match (key.pressed, key.repeat) {
        (true, false) => "press",
        (true, true) => "repeat",
        (false, _) => "release",
    };
    let logical = match &key.logical {
        LogicalKey::Character(characters) => format!("'{characters}'"),
        LogicalKey::Named(name) => name.clone(),
        LogicalKey::Dead(Some(character)) => format!("dead '{character}'"),
        LogicalKey::Dead(None) => "dead".to_owned(),
        LogicalKey::Unidentified => "unidentified".to_owned(),
    };
    let physical = match &key.physical {
        PhysicalKey::Code(code) => code.as_str(),
        PhysicalKey::Unidentified => "unidentified",
    };
    format!(
        "key {what} {logical} at {physical} with {}, text {:?}",
        held(key.modifiers),
        key.text
    )
}

/// What the pointer did, for a person.
fn pointer(pointer: &Pointer) -> String {
    let button = match pointer.button {
        Some(Button::Primary) => "primary".to_owned(),
        Some(Button::Secondary) => "secondary".to_owned(),
        Some(Button::Middle) => "middle".to_owned(),
        Some(Button::Back) => "back".to_owned(),
        Some(Button::Forward) => "forward".to_owned(),
        Some(Button::Other(number)) => format!("button {number}"),
        None => "no button".to_owned(),
    };
    let what = match pointer.action {
        PointerAction::Press => format!("press {button}"),
        PointerAction::Drag => format!("drag {button}"),
        PointerAction::Release => format!("release {button}"),
        PointerAction::Wheel(WheelDelta::Lines { x, y }) => {
            format!("wheel {x} across and {y} down in lines")
        }
        PointerAction::Wheel(WheelDelta::Pixels { x, y }) => {
            format!("wheel {x} across and {y} down in pixels")
        }
    };
    format!(
        "pointer {what} at ({}, {}) with {}",
        pointer.x,
        pointer.y,
        held(pointer.modifiers)
    )
}

/// One thing the window reported, for a person: one line.
pub fn described(input: &Input) -> String {
    match input {
        Input::Opened { platform } => format!("opened by {platform}"),
        Input::Focus(true) => "focus gained".to_owned(),
        Input::Focus(false) => "focus lost".to_owned(),
        Input::Key(pressed) => key(pressed),
        Input::Composition(Composition::Enabled) => "composition enabled".to_owned(),
        Input::Composition(Composition::Preedit(text)) => format!("composition preedit {text:?}"),
        Input::Composition(Composition::Commit(text)) => format!("composition commit {text:?}"),
        Input::Composition(Composition::Disabled) => "composition disabled".to_owned(),
        Input::Pointer(did) => pointer(did),
        Input::Resized(size) => format!(
            "resized {} by {} at scale {}",
            size.width, size.height, size.scale
        ),
        Input::OpenFiles(paths) => format!("open files: {}", paths.join(", ")),
        Input::CloseRequested => "close requested".to_owned(),
        Input::QuitRequested => "quit requested by the system".to_owned(),
        Input::Menu(name) => format!("menu item chosen: {name}"),
    }
}

/// The input `event` stands for, read back from the event as Lean reads
/// it: its kind, its code, its text and its words, each word as eight
/// bytes, least significant first.
pub fn read_back(event: &Event) -> Option<Input> {
    let words: Vec<u8> = event
        .words
        .iter()
        .flat_map(|word| word.to_le_bytes())
        .collect();
    window::input(event.kind, event.code, &event.text, &words)
}
