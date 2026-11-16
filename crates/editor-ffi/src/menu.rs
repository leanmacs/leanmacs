//! The menu bar as it crosses: one layout of words and texts, written into
//! what a scripted window was asked ([`crate::window::asked_words`]).
//!
//! The layout, after whatever says the menu is there:
//!
//! - the count of menus;
//! - for each menu: its title, its role's tag ([`ROLE_NONE`],
//!   [`ROLE_APP`], [`ROLE_WINDOW`]) and the count of its items;
//! - for each item: its kind ([`ITEM_SEPARATOR`], [`ITEM_COMMAND`],
//!   [`ITEM_SYSTEM`]). A command or a system item then has its title, the
//!   key equivalent's presence (0 or 1), its character's scalar value and
//!   its modifier bits (each 0 when absent; the bits are `window.rs`'s
//!   `MODIFIER_*`). A command item then has its command's name, and a
//!   system item its action's tag ([`system_tag`]).
//!
//! A text is written as the [`Sink`] writes one: in what a window was
//! asked, the count of its scalar values and each of them. Lean's
//! `Ffi.askedOf` is the other side.

use editor_platform::Menu;
use editor_platform::menu::{Action, Item, Role, System};

use crate::window::modifier_bits;

/// A plain menu's role tag.
pub const ROLE_NONE: u64 = 0;
/// The application menu's role tag.
pub const ROLE_APP: u64 = 1;
/// The windows menu's role tag.
pub const ROLE_WINDOW: u64 = 2;

/// A separator's kind.
pub const ITEM_SEPARATOR: u64 = 0;
/// A command item's kind.
pub const ITEM_COMMAND: u64 = 1;
/// A system item's kind.
pub const ITEM_SYSTEM: u64 = 2;

/// The system actions in the order of their tags: 0 about, 1 services,
/// 2 hide, 3 hide others, 4 show all, 5 quit.
const SYSTEMS: [System; 6] = [
    System::About,
    System::Services,
    System::Hide,
    System::HideOthers,
    System::ShowAll,
    System::Quit,
];

/// The tag of `system`.
pub fn system_tag(system: System) -> u64 {
    SYSTEMS
        .iter()
        .position(|&each| each == system)
        .map_or(0, |index| index as u64)
}

/// Where the layout is written: words, and texts as the place writes them.
pub(crate) trait Sink {
    /// Writes one word.
    fn word(&mut self, word: u64);
    /// Writes one text.
    fn text(&mut self, text: &str);
}

/// Writes `menu` in the layout of the module docs.
pub(crate) fn write(sink: &mut impl Sink, menu: &Menu) {
    sink.word(menu.menus.len() as u64);
    for submenu in &menu.menus {
        sink.text(&submenu.title);
        sink.word(match submenu.role {
            None => ROLE_NONE,
            Some(Role::App) => ROLE_APP,
            Some(Role::Window) => ROLE_WINDOW,
        });
        sink.word(submenu.items.len() as u64);
        for item in &submenu.items {
            let Item::Entry { title, key, action } = item else {
                sink.word(ITEM_SEPARATOR);
                continue;
            };
            sink.word(match action {
                Action::Command(_) => ITEM_COMMAND,
                Action::System(_) => ITEM_SYSTEM,
            });
            sink.text(title);
            sink.word(u64::from(key.is_some()));
            sink.word(key.map_or(0, |key| u64::from(key.character)));
            sink.word(key.map_or(0, |key| modifier_bits(key.modifiers)));
            match action {
                Action::Command(command) => sink.text(command),
                Action::System(system) => sink.word(system_tag(*system)),
            }
        }
    }
}
