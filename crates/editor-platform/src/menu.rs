//! The menu bar, as the editor asks for it: plain data that names no
//! windowing library.
//!
//! The editor asks a window for its menu bar with
//! [`Request::Menu`](crate::Request::Menu), and a platform reports a
//! command item chosen as [`Input::Menu`](crate::Input::Menu), with the
//! command's name. Every decision of which items there are, what each is
//! titled and which key each shows is the editor's: a platform builds what
//! it is given. A platform with no menu bar shows none, whatever it is
//! asked (`contract::requests`).
//!
//! A menu bar is a list of menus ([`Submenu`]), each with a title, a
//! [`Role`] that makes it one the system knows (the application's menu, the
//! windows menu) or none, and its items. An [`Item`] is a separator, or an
//! entry with a title, a key equivalent and an [`Action`]: an editor
//! command, by name, which the platform hands back when it is chosen, or a
//! thing the system does itself ([`System`]).

use crate::Modifiers;

/// The menu bar: its menus, in the order they are shown. The default has
/// none.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Menu {
    /// The menus, left to right.
    pub menus: Vec<Submenu>,
}

/// One menu of the menu bar.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Submenu {
    /// The menu's title in the bar. The application's menu is titled by
    /// the system on macOS, whatever this says.
    pub title: String,
    /// What the system makes of the menu; `None` for a plain one.
    pub role: Option<Role>,
    /// Its items, top to bottom.
    pub items: Vec<Item>,
}

/// A menu the system knows by its role.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// The application's menu, first in the bar: on macOS the one titled
    /// with the application's name.
    App,
    /// The windows menu, where the system lists the application's windows.
    Window,
}

/// One item of a menu.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Item {
    /// A line between items.
    Separator,
    /// An item that can be chosen.
    Entry {
        /// What the item says.
        title: String,
        /// The key that chooses it, shown beside it; `None` for none.
        key: Option<KeyEquivalent>,
        /// What choosing it does.
        action: Action,
    },
}

/// The key that chooses an item: one character and the modifiers held.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyEquivalent {
    /// The character, as the key types it: `Z` for shift and `z`.
    pub character: char,
    /// The modifiers held with it.
    pub modifiers: Modifiers,
}

/// What choosing an item does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    /// Runs the editor command of this name: the platform reports
    /// [`Input::Menu`](crate::Input::Menu) with it.
    Command(String),
    /// Something the system does itself, which the editor never hears of
    /// but as the system says (a quit is
    /// [`Input::QuitRequested`](crate::Input::QuitRequested)).
    System(System),
}

/// What the system does itself, from a menu item.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum System {
    /// Shows the application's About panel.
    About,
    /// The system's Services submenu.
    Services,
    /// Hides the application.
    Hide,
    /// Hides every other application.
    HideOthers,
    /// Shows every application again.
    ShowAll,
    /// Asks the application to quit, as the system does.
    Quit,
}

impl System {
    /// Every system action, each once, in the order they are declared: a
    /// crate that gives each its own word or selector checks the mapping
    /// over this, so a variant added here cannot cross as another.
    pub const ALL: [System; 6] = [
        System::About,
        System::Services,
        System::Hide,
        System::HideOthers,
        System::ShowAll,
        System::Quit,
    ];
}

#[cfg(test)]
mod tests {
    use super::System;

    #[test]
    fn every_system_action_is_listed_once() {
        // A new variant fails to compile here until it has an arm; give it
        // one, count it, and list it in `System::ALL`.
        let count = |system: System| match system {
            System::About
            | System::Services
            | System::Hide
            | System::HideOthers
            | System::ShowAll
            | System::Quit => 6,
        };
        for system in System::ALL {
            let listed = System::ALL.iter().filter(|&&each| each == system).count();
            assert_eq!(listed, 1, "{system:?}");
            assert_eq!(System::ALL.len(), count(system));
        }
    }
}
