//! The menu bar in AppKit (macOS): builds the main menu from a plan of
//! `menu.rs`'s, holds the target its command items call, and reads the
//! main menu back for the contract example.
//!
//! Every decision is `menu.rs`'s. What is here is calls and readings with
//! none in them, which only a real application runs:
//!
//! - [`MenuBar::show`], which builds an `NSMenu` of each planned menu, item
//!   for item (title, action, target, tag, key equivalent and its mask, the
//!   mark, and the Services item's empty submenu), and makes them the
//!   application's main menu, `servicesMenu` and `windowsMenu`;
//! - the target's one method, `choose:`, which hands the name `menu::chosen`
//!   gives for the item's tag to `Handing::choose`;
//! - [`read_menu_bar`], which reads the main menu into `menu.rs`'s
//!   [`Held`] and reads it back with `menu::read`.
//!
//! An `NSMenuItem`'s target is a weak reference, so the [`MenuBar`] keeps
//! the target alive for the run, and clears the main menu when it is
//! dropped, before the target goes. A new menu replaces the target's names
//! under the same target.

use std::cell::RefCell;
use std::ffi::CString;

use objc2::rc::Retained;
use objc2::runtime::{AnyObject, Sel};
use objc2::{DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send};
use objc2_app_kit::{
    NSApplication, NSEventModifierFlags, NSMenu, NSMenuItem, NSUserInterfaceItemIdentification,
};
use objc2_foundation::{NSObject, NSString};

use crate::files::Handing;
use crate::menu::{self, CHOOSE, Held, HeldItem, Plan, PlannedItem, ROLE_WINDOW, SERVICES};

/// What the target holds: where it hands a choice, and the command names
/// of the menu shown, by tag. It is only touched on the main thread.
pub(crate) struct Choices {
    /// Where a choice goes.
    handing: Handing,
    /// The command names, by tag.
    commands: RefCell<Vec<String>>,
}

define_class!(
    /// The target of every command item: it hands the chosen item's
    /// command name on.
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "EditorPlatformWinitMenuTarget"]
    #[ivars = Choices]
    struct MenuTarget;

    impl MenuTarget {
        /// A command item was chosen: its tag names its command.
        #[unsafe(method(choose:))]
        fn choose(&self, item: Option<&NSMenuItem>) {
            let Some(item) = item else { return };
            let choices = self.ivars();
            let name = menu::chosen(&choices.commands.borrow(), item.tag());
            if let Some(name) = name {
                choices.handing.choose(name);
            }
        }
    }
);

/// The menu bar of the run: the target the command items call, kept alive.
pub(crate) struct MenuBar {
    /// The target, which the items hold weakly.
    target: Retained<MenuTarget>,
    /// The thread it was made on, the main one.
    mtm: MainThreadMarker,
}

impl Drop for MenuBar {
    fn drop(&mut self) {
        // The items hold their target weakly: they go before it does.
        let app = NSApplication::sharedApplication(self.mtm);
        app.setMainMenu(None);
        app.setServicesMenu(None);
        app.setWindowsMenu(None);
    }
}

/// The selector named `name`.
fn selector(name: &str) -> Option<Sel> {
    Some(Sel::register(&CString::new(name).ok()?))
}

/// Marks `item` with `mark`.
fn mark(item: &NSMenuItem, mark: &str) {
    item.setIdentifier(Some(&NSString::from_str(mark)));
}

impl MenuBar {
    /// The menu bar whose target hands choices to `handing`. `None` off the
    /// main thread, where AppKit cannot be asked.
    pub(crate) fn install(handing: Handing) -> Option<Self> {
        let mtm = MainThreadMarker::new()?;
        let this = MenuTarget::alloc(mtm).set_ivars(Choices {
            handing,
            commands: RefCell::new(Vec::new()),
        });
        // SAFETY: `init` is `NSObject`'s initialiser, called once on the
        // allocation, as `define_class!` asks.
        let target: Retained<MenuTarget> = unsafe { msg_send![super(this), init] };
        Some(Self { target, mtm })
    }

    /// Builds `plan` and makes it the application's main menu.
    pub(crate) fn show(&self, plan: &Plan) {
        let mtm = self.mtm;
        let app = NSApplication::sharedApplication(mtm);
        self.target.ivars().commands.replace(plan.commands.clone());
        let target: &AnyObject = &self.target;
        let main = NSMenu::new(mtm);
        let (mut services, mut windows) = (None, None);
        for planned in &plan.menus {
            let title = NSString::from_str(&planned.title);
            let submenu = NSMenu::initWithTitle(NSMenu::alloc(mtm), &title);
            for item in &planned.items {
                let built = match item {
                    PlannedItem::Separator => {
                        let separator = NSMenuItem::separatorItem(mtm);
                        mark(&separator, menu::ITEM);
                        separator
                    }
                    PlannedItem::Entry(entry) => {
                        // SAFETY: the selector is a registered one, and
                        // the strings are strings.
                        let built = unsafe {
                            NSMenuItem::initWithTitle_action_keyEquivalent(
                                NSMenuItem::alloc(mtm),
                                &NSString::from_str(&entry.title),
                                entry.action.and_then(selector),
                                &NSString::from_str(&entry.key),
                            )
                        };
                        built.setKeyEquivalentModifierMask(NSEventModifierFlags::from_bits_retain(
                            entry.mask,
                        ));
                        built.setTag(entry.tag);
                        if entry.targeted {
                            // SAFETY: the target answers the item's action,
                            // `choose:`, and outlives the item (`Drop`).
                            unsafe { built.setTarget(Some(target)) };
                        }
                        mark(&built, entry.mark);
                        if entry.mark == SERVICES {
                            let empty = NSMenu::initWithTitle(NSMenu::alloc(mtm), &title);
                            built.setSubmenu(Some(&empty));
                            if entry.services {
                                services = Some(empty);
                            }
                        }
                        built
                    }
                };
                submenu.addItem(&built);
            }
            let top = NSMenuItem::new(mtm);
            top.setTitle(&title);
            mark(&top, planned.mark);
            top.setSubmenu(Some(&submenu));
            main.addItem(&top);
            if planned.windows {
                windows = Some(submenu);
            }
        }
        app.setMainMenu(Some(&main));
        app.setServicesMenu(services.as_deref());
        app.setWindowsMenu(windows.as_deref());
    }
}

/// What the contract example reads of the menu bar: the menu the adapter's
/// items spell, and what else AppKit holds.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reading {
    /// The menu the items the adapter built spell.
    pub menu: editor_platform::Menu,
    /// Whether the application's `servicesMenu` is the submenu of the
    /// first Services item built.
    pub services_set: bool,
    /// Whether its `windowsMenu` is the submenu of the windows menu built.
    pub windows_set: bool,
    /// The titles of the items AppKit holds that the adapter did not build.
    pub foreign: Vec<String>,
    /// How many items, built or not, call `toggleFullScreen:`.
    pub full_screen_items: usize,
}

/// The string of an item's mark, if it has one.
fn mark_of(item: &NSMenuItem) -> Option<String> {
    item.identifier().map(|mark| mark.to_string())
}

/// Reads the application's main menu back into the port's terms, for
/// `examples/contract` alone. `None` off the main thread, or with no main
/// menu.
pub fn read_menu_bar() -> Option<Reading> {
    let mtm = MainThreadMarker::new()?;
    let app = NSApplication::sharedApplication(mtm);
    let main = app.mainMenu()?;
    let mut held = Vec::new();
    let mut commands = Vec::new();
    let mut services_set = false;
    let mut windows_set = false;
    let services_menu = app.servicesMenu();
    let windows_menu = app.windowsMenu();
    let same = |one: &Option<Retained<NSMenu>>, other: &NSMenu| {
        one.as_deref().is_some_and(|one| std::ptr::eq(one, other))
    };
    for top in main.itemArray().iter() {
        let submenu = top.submenu();
        let top_mark = mark_of(&top);
        if let Some(submenu) = &submenu
            && top_mark.as_deref() == Some(ROLE_WINDOW)
        {
            windows_set = same(&windows_menu, submenu);
        }
        let items = submenu
            .iter()
            .flat_map(|submenu| submenu.itemArray().iter().collect::<Vec<_>>())
            .map(|item| {
                let action = item
                    .action()
                    .map(|action| action.name().to_string_lossy().into_owned());
                let inner = item.submenu();
                if action.as_deref() == Some(CHOOSE)
                    && commands.is_empty()
                    && let Some(target) = item.target()
                    && let Some(target) = target.downcast_ref::<MenuTarget>()
                {
                    commands.clone_from(&target.ivars().commands.borrow());
                }
                let item_mark = mark_of(&item);
                if item_mark.as_deref() == Some(SERVICES)
                    && !services_set
                    && let Some(inner) = &inner
                {
                    services_set = same(&services_menu, inner);
                }
                HeldItem {
                    mark: item_mark,
                    separator: item.isSeparatorItem(),
                    title: item.title().to_string(),
                    action,
                    tag: item.tag(),
                    key: item.keyEquivalent().to_string(),
                    mask: item.keyEquivalentModifierMask().bits(),
                    submenu: inner.is_some(),
                }
            })
            .collect();
        held.push(Held {
            mark: top_mark,
            title: submenu.map_or_else(
                || top.title().to_string(),
                |submenu| submenu.title().to_string(),
            ),
            items,
        });
    }
    let read = menu::read(&held, &commands);
    Some(Reading {
        menu: read.menu,
        services_set,
        windows_set,
        foreign: read.foreign,
        full_screen_items: read.full_screen,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_plans_masks_are_appkits_modifier_flags() {
        assert_eq!(menu::SHIFT, NSEventModifierFlags::Shift.bits());
        assert_eq!(menu::CONTROL, NSEventModifierFlags::Control.bits());
        assert_eq!(menu::OPTION, NSEventModifierFlags::Option.bits());
        assert_eq!(menu::COMMAND, NSEventModifierFlags::Command.bits());
    }
}
