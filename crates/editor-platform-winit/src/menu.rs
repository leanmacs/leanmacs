//! The menu bar the editor asks for: the pure plan of what to build in
//! AppKit from the port's [`Menu`], and the reading of what AppKit holds
//! back into the port's terms.
//!
//! The handler (`App::proxy_wake_up` in `lib.rs`) takes each
//! [`Request::Menu`](editor_platform::Request::Menu) and, on macOS, hands
//! [`plan`]'s plan to `menu_bar.rs`, which builds an `NSMenu` of it item
//! for item and makes it the main menu. A command item chosen calls the
//! one method of the crate's target object, which hands the name
//! [`chosen`] gives on. `menu_bar.rs` makes no decision; every one is
//! here:
//!
//! - **A system item's action is AppKit's standard selector**
//!   ([`selector`]): About `orderFrontStandardAboutPanel:`, Hide `hide:`,
//!   Hide Others `hideOtherApplications:`, Show All
//!   `unhideAllApplications:` and Quit `terminate:`, each sent to the
//!   first responder (no target), so the application answers it as it
//!   answers its own menu's. Services has no action of ours: it is an item
//!   with an empty submenu, which becomes the application's `servicesMenu`,
//!   and AppKit fills. AppKit gives an item with a submenu the action
//!   `submenuAction:` of its own (seen in the contract example), which the
//!   model of what it holds (`Plan::built`) says too.
//! - **A command item's action is the target's `choose:`, and its tag is
//!   its index among the plan's command items** ([`Plan::commands`]). The
//!   target turns the tag back into the name ([`chosen`]); a tag out of
//!   range names none. The tags are not the menus' positions, so a menu
//!   AppKit adds items to still chooses the right command.
//! - **A key equivalent is its character as a string and the mask of the
//!   modifiers held** ([`SHIFT`], [`CONTROL`], [`OPTION`], [`COMMAND`],
//!   which are `NSEventModifierFlags`' bits). An item with none has the
//!   empty string and no mask.
//! - **The application's menu is first.** AppKit takes the main menu's
//!   first item as the application menu, so the first menu with the
//!   [`Role::App`] role is put first and the others keep their order.
//!   Only the first menu with a role has it: a later one is plain. The
//!   first menu with [`Role::Window`] becomes the `windowsMenu`, and the
//!   first Services item the `servicesMenu`.
//! - **Every item built is marked**, with an identifier
//!   (`NSUserInterfaceItemIdentification`) that starts with [`MARK`]. A
//!   top-level item's mark says its menu's role ([`ROLE_APP`],
//!   [`ROLE_WINDOW`], [`ROLE_PLAIN`]), and the Services item's is
//!   [`SERVICES`]. AppKit adds items of its own (Emoji & Symbols,
//!   dictation and AutoFill to an Edit menu, the window list and tiling to
//!   a windows menu), and they carry no mark.
//! - **A reading keeps only the items marked** ([`read`]), and lists the
//!   titles of the others as foreign. A system item's action is read back
//!   from its selector, not from its mark, so a reading says what AppKit
//!   will do; a command item's from its tag. It counts the items, marked
//!   or not, whose action is `toggleFullScreen:`, the item AppKit adds to
//!   a windows menu unless told not to (`delegate::install`).
//!
//! `Plan::built` is the pure model of what AppKit holds once a plan is
//! built, marks and all, so reading it back is tested here: the plan and
//! the reading cannot drift. That AppKit holds what the model says is the
//! contract example's (`examples/contract/menu.rs`).

use editor_platform::Menu;
use editor_platform::Modifiers;
use editor_platform::menu::{Action, Item, KeyEquivalent, Role, Submenu, System};

/// What every identifier of an item the adapter built starts with.
pub(crate) const MARK: &str = "editor-platform-winit.menu";
/// The mark of the application menu's top-level item.
pub(crate) const ROLE_APP: &str = "editor-platform-winit.menu.app";
/// The mark of the windows menu's top-level item.
pub(crate) const ROLE_WINDOW: &str = "editor-platform-winit.menu.window";
/// The mark of a plain menu's top-level item.
pub(crate) const ROLE_PLAIN: &str = "editor-platform-winit.menu.plain";
/// The mark of the Services item.
pub(crate) const SERVICES: &str = "editor-platform-winit.menu.services";
/// The mark of any other item: a command, a system item or a separator.
pub(crate) const ITEM: &str = "editor-platform-winit.menu.item";

/// `NSEventModifierFlagShift`.
pub(crate) const SHIFT: usize = 1 << 17;
/// `NSEventModifierFlagControl`.
pub(crate) const CONTROL: usize = 1 << 18;
/// `NSEventModifierFlagOption`.
pub(crate) const OPTION: usize = 1 << 19;
/// `NSEventModifierFlagCommand`.
pub(crate) const COMMAND: usize = 1 << 20;

/// The selector of the target's one method, which a command item calls.
pub(crate) const CHOOSE: &str = "choose:";

/// The selector AppKit's fullscreen item calls.
const TOGGLE_FULL_SCREEN: &str = "toggleFullScreen:";

/// The action AppKit gives an item with a submenu.
const SUBMENU_ACTION: &str = "submenuAction:";

/// What to build: the menus in the order AppKit takes them, and the
/// command names by tag.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Plan {
    /// The menus, the application's first.
    pub(crate) menus: Vec<Planned>,
    /// The command items' command names, each at its item's tag.
    pub(crate) commands: Vec<String>,
}

/// One menu to build: its top-level item and its submenu.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Planned {
    /// The title, of the top-level item and of its submenu.
    pub(crate) title: String,
    /// The top-level item's mark, which says the role.
    pub(crate) mark: &'static str,
    /// Whether its submenu is the application's `windowsMenu`.
    pub(crate) windows: bool,
    /// The submenu's items.
    pub(crate) items: Vec<PlannedItem>,
}

/// One item to build.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum PlannedItem {
    /// A separator, marked [`ITEM`].
    Separator,
    /// An item that can be chosen.
    Entry(Entry),
}

/// An item that can be chosen, as AppKit takes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Entry {
    /// The title.
    pub(crate) title: String,
    /// The action's selector; `None` for Services, which has none.
    pub(crate) action: Option<&'static str>,
    /// Whether the target is the crate's: a command item's is, a system
    /// item's is the first responder.
    pub(crate) targeted: bool,
    /// The tag: a command item's index among the commands, else 0.
    pub(crate) tag: isize,
    /// The key equivalent's string; empty for none.
    pub(crate) key: String,
    /// The key equivalent's modifier mask; 0 for none.
    pub(crate) mask: usize,
    /// The mark: [`SERVICES`] or [`ITEM`].
    pub(crate) mark: &'static str,
    /// Whether it has an empty submenu, which is the application's
    /// `servicesMenu`.
    pub(crate) services: bool,
}

/// The standard selector of `system`; `None` for Services, which has none.
///
/// The match is exhaustive on purpose: the adapter must act on every
/// variant, since each is something AppKit does by its own selector, so a
/// variant added upstream fails to compile here until it has one.
pub(crate) fn selector(system: System) -> Option<&'static str> {
    match system {
        System::About => Some("orderFrontStandardAboutPanel:"),
        System::Services => None,
        System::Hide => Some("hide:"),
        System::HideOthers => Some("hideOtherApplications:"),
        System::ShowAll => Some("unhideAllApplications:"),
        System::Quit => Some("terminate:"),
    }
}

/// The system action whose standard selector is `action`, of every one
/// ([`System::ALL`]).
fn system_of(action: &str) -> Option<System> {
    System::ALL
        .into_iter()
        .find(|&system| selector(system) == Some(action))
}

/// The mask of the modifiers held.
pub(crate) fn mask(modifiers: Modifiers) -> usize {
    let bit = |held: bool, bit: usize| if held { bit } else { 0 };
    bit(modifiers.shift, SHIFT)
        | bit(modifiers.control, CONTROL)
        | bit(modifiers.alt, OPTION)
        | bit(modifiers.super_key, COMMAND)
}

/// The modifiers a mask holds.
fn modifiers(mask: usize) -> Modifiers {
    Modifiers {
        shift: mask & SHIFT != 0,
        control: mask & CONTROL != 0,
        alt: mask & OPTION != 0,
        super_key: mask & COMMAND != 0,
    }
}

/// The plan for `menu`: the module docs' decisions.
pub(crate) fn plan(menu: &Menu) -> Plan {
    let first_app = menu
        .menus
        .iter()
        .position(|submenu| submenu.role == Some(Role::App));
    let first_window = menu
        .menus
        .iter()
        .position(|submenu| submenu.role == Some(Role::Window));
    let order = first_app
        .into_iter()
        .chain((0..menu.menus.len()).filter(|&index| Some(index) != first_app));
    let mut commands = Vec::new();
    let mut services_given = false;
    let menus = order
        .map(|index| {
            let submenu = &menu.menus[index];
            let mark = if Some(index) == first_app {
                ROLE_APP
            } else if Some(index) == first_window {
                ROLE_WINDOW
            } else {
                ROLE_PLAIN
            };
            let items = submenu
                .items
                .iter()
                .map(|item| planned(item, &mut commands, &mut services_given))
                .collect();
            Planned {
                title: submenu.title.clone(),
                mark,
                windows: Some(index) == first_window,
                items,
            }
        })
        .collect();
    Plan { menus, commands }
}

/// The item to build for `item`, adding a command's name to `commands`
/// and noting the first Services item in `services_given`.
fn planned(item: &Item, commands: &mut Vec<String>, services_given: &mut bool) -> PlannedItem {
    let Item::Entry { title, key, action } = item else {
        return PlannedItem::Separator;
    };
    let (key, mask) = key.map_or((String::new(), 0), |key: KeyEquivalent| {
        (key.character.to_string(), self::mask(key.modifiers))
    });
    let entry = |action, targeted, tag, mark, services| {
        PlannedItem::Entry(Entry {
            title: title.clone(),
            action,
            targeted,
            tag,
            key: key.clone(),
            mask,
            mark,
            services,
        })
    };
    match action {
        Action::Command(name) => {
            let tag = isize::try_from(commands.len()).unwrap_or(isize::MAX);
            commands.push(name.clone());
            entry(Some(CHOOSE), true, tag, ITEM, false)
        }
        Action::System(System::Services) => {
            let first = !*services_given;
            *services_given = true;
            entry(None, false, 0, SERVICES, first)
        }
        Action::System(system) => entry(selector(*system), false, 0, ITEM, false),
    }
}

/// The name of the command the item tagged `tag` runs, among `commands`;
/// `None` for a tag out of range or negative.
pub(crate) fn chosen(commands: &[String], tag: isize) -> Option<String> {
    commands.get(usize::try_from(tag).ok()?).cloned()
}

/// A top-level item of the main menu as AppKit holds it, with its
/// submenu: what `menu_bar.rs` reads, and what `Plan::built` models.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Held {
    /// The item's identifier, if it has one.
    pub(crate) mark: Option<String>,
    /// Its submenu's title.
    pub(crate) title: String,
    /// Its submenu's items.
    pub(crate) items: Vec<HeldItem>,
}

/// An item of a submenu as AppKit holds it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct HeldItem {
    /// Its identifier, if it has one.
    pub(crate) mark: Option<String>,
    /// Whether it is a separator.
    pub(crate) separator: bool,
    /// Its title.
    pub(crate) title: String,
    /// Its action's selector's name, if it has one.
    pub(crate) action: Option<String>,
    /// Its tag.
    pub(crate) tag: isize,
    /// Its key equivalent.
    pub(crate) key: String,
    /// Its key equivalent's modifier mask.
    pub(crate) mask: usize,
    /// Whether it has a submenu.
    pub(crate) submenu: bool,
}

impl Plan {
    /// What AppKit holds once this plan is built: the model `menu_bar.rs`
    /// is held to by the contract example.
    #[cfg(test)]
    pub(crate) fn built(&self) -> Vec<Held> {
        self.menus
            .iter()
            .map(|planned| Held {
                mark: Some(planned.mark.to_owned()),
                title: planned.title.clone(),
                items: planned
                    .items
                    .iter()
                    .map(|item| match item {
                        PlannedItem::Separator => HeldItem {
                            mark: Some(ITEM.to_owned()),
                            separator: true,
                            title: String::new(),
                            action: None,
                            tag: 0,
                            key: String::new(),
                            mask: 0,
                            submenu: false,
                        },
                        PlannedItem::Entry(entry) => HeldItem {
                            mark: Some(entry.mark.to_owned()),
                            separator: false,
                            title: entry.title.clone(),
                            action: if entry.mark == SERVICES {
                                Some(SUBMENU_ACTION.to_owned())
                            } else {
                                entry.action.map(str::to_owned)
                            },
                            tag: entry.tag,
                            key: entry.key.clone(),
                            mask: entry.mask,
                            submenu: entry.mark == SERVICES,
                        },
                    })
                    .collect(),
            })
            .collect()
    }
}

/// What a reading of AppKit's main menu found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Read {
    /// The menu the marked items spell.
    pub(crate) menu: Menu,
    /// The titles of the items AppKit holds that the adapter did not
    /// build, or that spell nothing.
    pub(crate) foreign: Vec<String>,
    /// How many items, marked or not, call `toggleFullScreen:`.
    pub(crate) full_screen: usize,
}

/// Whether `mark` is one of the adapter's.
fn ours(mark: Option<&str>) -> bool {
    mark.is_some_and(|mark| mark.starts_with(MARK))
}

/// Reads `held` back into the port's terms, a command item's name found
/// among `commands` by its tag: the module docs' last decision.
pub(crate) fn read(held: &[Held], commands: &[String]) -> Read {
    let mut foreign = Vec::new();
    let mut full_screen = 0;
    let mut menus = Vec::new();
    for top in held {
        let full_screens = top
            .items
            .iter()
            .filter(|item| item.action.as_deref() == Some(TOGGLE_FULL_SCREEN))
            .count();
        full_screen += full_screens;
        let role = match top.mark.as_deref() {
            Some(ROLE_APP) => Some(Role::App),
            Some(ROLE_WINDOW) => Some(Role::Window),
            Some(ROLE_PLAIN) => None,
            _ => {
                foreign.push(top.title.clone());
                continue;
            }
        };
        let mut items = Vec::new();
        for item in &top.items {
            match read_item(item, commands) {
                Some(read) => items.push(read),
                None => foreign.push(item.title.clone()),
            }
        }
        menus.push(Submenu {
            title: top.title.clone(),
            role,
            items,
        });
    }
    Read {
        menu: Menu { menus },
        foreign,
        full_screen,
    }
}

/// The port's item `item` spells; `None` for one the adapter did not
/// build, or one that spells nothing.
fn read_item(item: &HeldItem, commands: &[String]) -> Option<Item> {
    if !ours(item.mark.as_deref()) {
        return None;
    }
    if item.separator {
        return Some(Item::Separator);
    }
    let services = item.mark.as_deref() == Some(SERVICES) && item.submenu;
    let action = match item.action.as_deref() {
        Some(CHOOSE) => Action::Command(chosen(commands, item.tag)?),
        Some(SUBMENU_ACTION) | None if services => Action::System(System::Services),
        Some(other) => Action::System(system_of(other)?),
        None => return None,
    };
    let mut characters = item.key.chars();
    let key = match (characters.next(), characters.next()) {
        (None, _) => None,
        (Some(character), None) => Some(KeyEquivalent {
            character,
            modifiers: modifiers(item.mask),
        }),
        (Some(_), Some(_)) => return None,
    };
    Some(Item::Entry {
        title: item.title.clone(),
        key,
        action,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn held(shift: bool, control: bool, alt: bool, super_key: bool) -> Modifiers {
        Modifiers {
            shift,
            control,
            alt,
            super_key,
        }
    }

    fn command(title: &str, name: &str, key: Option<KeyEquivalent>) -> Item {
        Item::Entry {
            title: title.into(),
            key,
            action: Action::Command(name.into()),
        }
    }

    fn system(title: &str, system: System, key: Option<KeyEquivalent>) -> Item {
        Item::Entry {
            title: title.into(),
            key,
            action: Action::System(system),
        }
    }

    fn key(character: char, modifiers: Modifiers) -> Option<KeyEquivalent> {
        Some(KeyEquivalent {
            character,
            modifiers,
        })
    }

    fn submenu(title: &str, role: Option<Role>, items: Vec<Item>) -> Submenu {
        Submenu {
            title: title.into(),
            role,
            items,
        }
    }

    /// The one entry a one-item menu plans.
    fn only_entry(item: Item) -> Entry {
        let plan = plan(&Menu {
            menus: vec![submenu("M", None, vec![item])],
        });
        match &plan.menus[0].items[..] {
            [PlannedItem::Entry(entry)] => entry.clone(),
            other => panic!("one entry, not {other:?}"),
        }
    }

    /// A menu with every kind of item, role, key and modifier, the
    /// application's menu first.
    fn every() -> Menu {
        Menu {
            menus: vec![
                submenu(
                    "Leanmacs",
                    Some(Role::App),
                    vec![
                        system("About", System::About, None),
                        system("Services", System::Services, None),
                        Item::Separator,
                        system(
                            "Hide",
                            System::Hide,
                            key('h', held(false, false, false, true)),
                        ),
                        system(
                            "Hide Others",
                            System::HideOthers,
                            key('h', held(false, false, true, true)),
                        ),
                        system("Show All", System::ShowAll, None),
                        system(
                            "Quit",
                            System::Quit,
                            key('q', held(false, false, false, true)),
                        ),
                    ],
                ),
                submenu(
                    "File",
                    None,
                    vec![
                        command(
                            "Open…",
                            "open-file",
                            key('o', held(false, false, false, true)),
                        ),
                        command("Every", "every", key('x', held(true, true, true, true))),
                        command("Ctrl", "ctrl", key('é', held(false, true, false, false))),
                    ],
                ),
                submenu(
                    "Window",
                    Some(Role::Window),
                    vec![
                        command("Minimise", "minimise-window", None),
                        command("Redo", "redo", key('Z', held(false, false, false, true))),
                    ],
                ),
                submenu("Empty", None, vec![]),
            ],
        }
    }

    #[test]
    fn every_system_action_with_a_selector_is_read_back_from_it() {
        let mut seen = Vec::new();
        for system in System::ALL {
            let Some(action) = selector(system) else {
                assert_eq!(system, System::Services, "only Services has no selector");
                continue;
            };
            assert_eq!(system_of(action), Some(system), "{system:?}");
            assert!(!seen.contains(&action), "{system:?} shares {action}");
            seen.push(action);
        }
        assert_eq!(system_of("toggleFullScreen:"), None);
    }

    #[test]
    fn each_system_action_is_its_standard_selector() {
        let selectors = [
            (System::About, "orderFrontStandardAboutPanel:"),
            (System::Hide, "hide:"),
            (System::HideOthers, "hideOtherApplications:"),
            (System::ShowAll, "unhideAllApplications:"),
            (System::Quit, "terminate:"),
        ];
        for (each, expected) in selectors {
            let entry = only_entry(system("S", each, None));
            assert_eq!(entry.action, Some(expected), "{each:?}");
            assert!(!entry.targeted, "{each:?} goes to the first responder");
            assert!(!entry.services);
            assert_eq!(entry.mark, ITEM);
        }
        let services = only_entry(system("Services", System::Services, None));
        assert_eq!(services.action, None, "Services has no selector");
        assert!(services.services, "it has the empty submenu");
        assert_eq!(services.mark, SERVICES);
    }

    #[test]
    fn a_command_item_is_the_targets_choose_with_its_index_among_the_commands_as_its_tag() {
        let plan = plan(&Menu {
            menus: vec![
                submenu(
                    "A",
                    None,
                    vec![
                        command("One", "one", None),
                        system("Quit", System::Quit, None),
                        Item::Separator,
                        command("Two", "two", None),
                    ],
                ),
                submenu("B", None, vec![command("Three", "three", None)]),
            ],
        });
        assert_eq!(plan.commands, ["one", "two", "three"]);
        let tags: Vec<(Option<&str>, bool, isize)> = plan
            .menus
            .iter()
            .flat_map(|menu| &menu.items)
            .filter_map(|item| match item {
                PlannedItem::Entry(entry) => Some((entry.action, entry.targeted, entry.tag)),
                PlannedItem::Separator => None,
            })
            .collect();
        assert_eq!(
            tags,
            [
                (Some(CHOOSE), true, 0),
                (Some("terminate:"), false, 0),
                (Some(CHOOSE), true, 1),
                (Some(CHOOSE), true, 2),
            ]
        );
    }

    #[test]
    fn a_key_equivalent_is_its_character_and_the_mask_of_each_modifier_held() {
        let cases = [
            (held(true, false, false, false), 1 << 17),
            (held(false, true, false, false), 1 << 18),
            (held(false, false, true, false), 1 << 19),
            (held(false, false, false, true), 1 << 20),
            (
                held(true, true, true, true),
                (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20),
            ),
        ];
        for (modifiers, expected) in cases {
            let entry = only_entry(command("C", "c", key('z', modifiers)));
            assert_eq!(entry.key, "z");
            assert_eq!(entry.mask, expected, "{modifiers:?}");
        }
        assert_eq!(
            (SHIFT, CONTROL, OPTION, COMMAND),
            (1 << 17, 1 << 18, 1 << 19, 1 << 20)
        );
        let upper = only_entry(command(
            "Redo",
            "redo",
            key('Z', held(false, false, false, true)),
        ));
        assert_eq!((upper.key.as_str(), upper.mask), ("Z", COMMAND));
    }

    #[test]
    fn an_item_with_no_key_equivalent_has_the_empty_string_and_no_mask() {
        let entry = only_entry(command("C", "c", None));
        assert_eq!((entry.key.as_str(), entry.mask), ("", 0));
        let entry = only_entry(system("Show All", System::ShowAll, None));
        assert_eq!((entry.key.as_str(), entry.mask), ("", 0));
    }

    #[test]
    fn a_separator_is_a_separator() {
        let plan = plan(&Menu {
            menus: vec![submenu("M", None, vec![Item::Separator])],
        });
        assert_eq!(plan.menus[0].items, [PlannedItem::Separator]);
        assert_eq!(plan.commands, Vec::<String>::new());
    }

    #[test]
    fn the_app_roles_menu_is_first_and_its_services_item_is_the_services_menu_and_the_window_roles_menu_is_the_windows_menu()
     {
        let plan = plan(&Menu {
            menus: vec![
                submenu("File", None, vec![]),
                submenu(
                    "App",
                    Some(Role::App),
                    vec![system("Services", System::Services, None)],
                ),
                submenu("Window", Some(Role::Window), vec![]),
            ],
        });
        let shape: Vec<(&str, &str, bool)> = plan
            .menus
            .iter()
            .map(|menu| (menu.title.as_str(), menu.mark, menu.windows))
            .collect();
        assert_eq!(
            shape,
            [
                ("App", ROLE_APP, false),
                ("File", ROLE_PLAIN, false),
                ("Window", ROLE_WINDOW, true),
            ]
        );
        assert!(matches!(
            &plan.menus[0].items[..],
            [PlannedItem::Entry(Entry { services: true, .. })]
        ));
    }

    #[test]
    fn only_the_first_menu_of_each_role_is_that_roles() {
        let plan = plan(&Menu {
            menus: vec![
                submenu("W1", Some(Role::Window), vec![]),
                submenu(
                    "A1",
                    Some(Role::App),
                    vec![
                        system("S1", System::Services, None),
                        system("S2", System::Services, None),
                    ],
                ),
                submenu("A2", Some(Role::App), vec![]),
                submenu("W2", Some(Role::Window), vec![]),
            ],
        });
        let shape: Vec<(&str, &str, bool)> = plan
            .menus
            .iter()
            .map(|menu| (menu.title.as_str(), menu.mark, menu.windows))
            .collect();
        assert_eq!(
            shape,
            [
                ("A1", ROLE_APP, false),
                ("W1", ROLE_WINDOW, true),
                ("A2", ROLE_PLAIN, false),
                ("W2", ROLE_PLAIN, false),
            ]
        );
        let services: Vec<bool> = plan.menus[0]
            .items
            .iter()
            .map(|item| matches!(item, PlannedItem::Entry(Entry { services: true, .. })))
            .collect();
        assert_eq!(
            services,
            [true, false],
            "only the first is the services menu"
        );
    }

    #[test]
    fn a_chosen_tag_names_its_command_and_a_tag_out_of_range_or_negative_names_none() {
        let commands = vec!["undo".to_owned(), "redo".to_owned()];
        assert_eq!(chosen(&commands, 0).as_deref(), Some("undo"));
        assert_eq!(chosen(&commands, 1).as_deref(), Some("redo"));
        assert_eq!(chosen(&commands, 2), None);
        assert_eq!(chosen(&commands, -1), None);
        assert_eq!(chosen(&[], 0), None);
    }

    #[test]
    fn reading_back_what_a_plan_builds_gives_the_menu_planned() {
        let plan = plan(&every());
        let read = read(&plan.built(), &plan.commands);
        assert_eq!(read.menu, every());
        assert_eq!(read.foreign, Vec::<String>::new());
        assert_eq!(read.full_screen, 0);
    }

    #[test]
    fn reading_leaves_out_items_the_adapter_did_not_build_and_lists_them() {
        let plan = plan(&every());
        let mut held = plan.built();
        let foreign_item = |title: &str, action: &str| HeldItem {
            mark: None,
            separator: false,
            title: title.into(),
            action: Some(action.into()),
            tag: 0,
            key: String::new(),
            mask: 0,
            submenu: false,
        };
        held[1].items.push(foreign_item(
            "Emoji & Symbols",
            "orderFrontCharacterPalette:",
        ));
        held[2]
            .items
            .push(foreign_item("Enter Full Screen", "toggleFullScreen:"));
        held[2].items.push(HeldItem {
            mark: Some("someone-else".into()),
            ..foreign_item("notes.txt", "makeKeyAndOrderFront:")
        });
        held.push(Held {
            mark: None,
            title: "Help".into(),
            items: vec![],
        });

        let read = read(&held, &plan.commands);

        assert_eq!(read.menu, every());
        assert_eq!(
            read.foreign,
            ["Emoji & Symbols", "Enter Full Screen", "notes.txt", "Help"]
        );
        assert_eq!(read.full_screen, 1, "AppKit's fullscreen item is counted");
    }

    #[test]
    fn a_marked_item_whose_action_or_tag_spells_nothing_is_foreign() {
        let plan = plan(&every());
        let mut held = plan.built();
        held[1].items[0].tag = 99;
        held[1].items[1].action = Some("cut:".into());
        let read = read(&held, &plan.commands);
        assert_eq!(read.foreign, ["Open…", "Every"]);
    }
}
