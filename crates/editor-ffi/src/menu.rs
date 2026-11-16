//! The menu bar as it crosses: one layout of words and texts, written into
//! a scene ([`crate::display`]'s wire) and into what a scripted window was
//! asked ([`crate::window::asked_words`]), and read back from a scene.
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
//! A text is written as the [`Sink`] writes one: in a scene, its length in
//! bytes, with the text in the scene's string; in what a window was asked,
//! the count of its scalar values and each of them. Lean's
//! `Display/Real.encode` and `Ffi.askedOf` are the other side of each.
//!
//! Reading refuses a role, a kind or a system tag out of range, a key's
//! presence that is neither 0 nor 1, a character that is no `char`, and
//! modifier bits past the system key's.

use editor_platform::Menu;
use editor_platform::menu::{Action, Item, KeyEquivalent, Role, Submenu, System};

use crate::window::{modifier_bits, read_modifiers};

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

/// Where the layout is read from.
pub(crate) trait Source {
    /// The next word.
    fn word(&mut self) -> Option<u64>;
    /// The next text.
    fn text(&mut self) -> Option<String>;
    /// A count of things each at least `each` words long, bounded by the
    /// words left.
    fn count(&mut self, each: usize) -> Option<usize>;
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

/// Reads a menu in the layout of the module docs; `None` when the words
/// and texts spell none.
pub(crate) fn read(source: &mut impl Source) -> Option<Menu> {
    // A menu is at least its title, its role and its count of items.
    let count = source.count(3)?;
    let menus = (0..count).map(|_| submenu(source)).collect::<Option<_>>()?;
    Some(Menu { menus })
}

/// Reads one menu of the bar.
fn submenu(source: &mut impl Source) -> Option<Submenu> {
    let title = source.text()?;
    let role = match source.word()? {
        ROLE_NONE => None,
        ROLE_APP => Some(Role::App),
        ROLE_WINDOW => Some(Role::Window),
        _ => return None,
    };
    let count = source.count(1)?;
    let items = (0..count).map(|_| item(source)).collect::<Option<_>>()?;
    Some(Submenu { title, role, items })
}

/// Reads one item.
fn item(source: &mut impl Source) -> Option<Item> {
    let kind = source.word()?;
    if kind == ITEM_SEPARATOR {
        return Some(Item::Separator);
    }
    if kind != ITEM_COMMAND && kind != ITEM_SYSTEM {
        return None;
    }
    let title = source.text()?;
    let (present, character, bits) = (source.word()?, source.word()?, source.word()?);
    let key = match present {
        0 => None,
        1 => Some(KeyEquivalent {
            character: char::from_u32(u32::try_from(character).ok()?)?,
            modifiers: read_modifiers(bits)?,
        }),
        _ => return None,
    };
    let action = if kind == ITEM_COMMAND {
        Action::Command(source.text()?)
    } else {
        let tag = usize::try_from(source.word()?).ok()?;
        Action::System(*SYSTEMS.get(tag)?)
    };
    Some(Item::Entry { title, key, action })
}
