//! The menu bar, asked of the running window on macOS and read back from
//! AppKit, and its items performed as a person's click performs them.
//!
//! The scenario runs on a thread of its own once the window has said it
//! opened and how large it is, before the module `terminate`'s. Each wait
//! is bounded, and a scenario that does not see what it should is a
//! failure, with the reason:
//!
//! 1. The window is asked for a sample menu ([`sample`]): an application
//!    menu with each system item, a File menu with command items (one with
//!    no key, one with every modifier) and a separator, and a windows menu.
//! 2. `NSApp.mainMenu` is read back through the crate's reading
//!    (`editor_platform_winit::probe`) until the items the adapter built
//!    spell exactly the sample. Then the application's `servicesMenu` and
//!    `windowsMenu` must be the submenus built for them, and no item may
//!    call `toggleFullScreen:` (`NSFullScreenMenuItemEverywhere`). The
//!    items AppKit added of its own are listed in a failure's reason; they
//!    are no failure by themselves.
//! 3. Each command item is performed (`performActionForItemAtIndex:`, found
//!    by its action and tag, since AppKit may add items before it), and
//!    each reports `Input::Menu` with its command's name, in order.
//! 4. The Quit item is performed from the run loop, not from a main-queue
//!    block, since its `terminate:` waits in a nested run loop until it is
//!    answered: exactly one `QuitRequested` is reported. Then keep running,
//!    and the perform returns. The module `terminate` asks again only after
//!    that, so this scenario leaves it one quit reported.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use editor_platform::menu::{Action, Item, KeyEquivalent, Role, Submenu, System};
use editor_platform::{Input, Menu, Modifiers, Platform, Request};
use editor_platform_winit::probe::{self, Reading};
use objc2::rc::Retained;
use objc2::runtime::{AnyObject, NSObject};
use objc2::{MainThreadOnly, define_class, msg_send, sel};
use objc2_app_kit::NSApplication;
use objc2_foundation::NSObjectNSThreadPerformAdditions;

use crate::Record;
use crate::terminate::{opened, reported};

/// How long each step waits for what it should see.
const STEP: Duration = Duration::from_secs(3);

/// How many performs of the Quit item have returned.
static QUIT_RETURNED: AtomicUsize = AtomicUsize::new(0);

define_class!(
    /// What performs the application menu's Quit item on the main thread,
    /// from the run loop, and counts each perform that returns.
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "EditorPlatformWinitContractMenuQuitter"]
    struct Quitter;

    impl Quitter {
        /// Performs the first menu's item whose action is `terminate:`.
        #[unsafe(method(quit:))]
        fn quit(&self, _: Option<&AnyObject>) {
            let app = NSApplication::sharedApplication(self.mtm());
            if let Some((menu, index)) = app.mainMenu().and_then(|main| {
                let first = main.itemAtIndex(0)?.submenu()?;
                let index = first
                    .itemArray()
                    .iter()
                    .position(|item| item.action() == Some(sel!(terminate:)))?;
                Some((first, index))
            }) {
                menu.performActionForItemAtIndex(index as isize);
            }
            QUIT_RETURNED.fetch_add(1, Ordering::SeqCst);
        }
    }
);

/// The modifiers with exactly these held.
fn held(shift: bool, control: bool, alt: bool, super_key: bool) -> Modifiers {
    Modifiers {
        shift,
        control,
        alt,
        super_key,
    }
}

/// An item that does `action`, titled `title`, chosen by `key`.
fn entry(title: &str, key: Option<(char, Modifiers)>, action: Action) -> Item {
    Item::Entry {
        title: title.into(),
        key: key.map(|(character, modifiers)| KeyEquivalent {
            character,
            modifiers,
        }),
        action,
    }
}

/// The menu the scenario asks for.
pub fn sample() -> Menu {
    let command = |name: &str| Action::Command(name.into());
    let system = Action::System;
    let super_key = held(false, false, false, true);
    Menu {
        menus: vec![
            Submenu {
                title: "Leanmacs".into(),
                role: Some(Role::App),
                items: vec![
                    entry("About Leanmacs", None, system(System::About)),
                    entry("Services", None, system(System::Services)),
                    Item::Separator,
                    entry(
                        "Hide Leanmacs",
                        Some(('h', super_key)),
                        system(System::Hide),
                    ),
                    entry(
                        "Hide Others",
                        Some(('h', held(false, false, true, true))),
                        system(System::HideOthers),
                    ),
                    entry("Show All", None, system(System::ShowAll)),
                    Item::Separator,
                    entry(
                        "Quit Leanmacs",
                        Some(('q', super_key)),
                        system(System::Quit),
                    ),
                ],
            },
            Submenu {
                title: "File".into(),
                role: None,
                items: vec![
                    entry("Open…", Some(('o', super_key)), command("open-file")),
                    entry("Save", None, command("save-buffer")),
                    Item::Separator,
                    entry(
                        "Every Modifier",
                        Some(('x', held(true, true, true, true))),
                        command("every-modifier"),
                    ),
                ],
            },
            Submenu {
                title: "Window".into(),
                role: Some(Role::Window),
                items: vec![
                    entry(
                        "Minimise",
                        Some(('m', super_key)),
                        command("minimise-window"),
                    ),
                    entry(
                        "Enter Full Screen",
                        Some(('f', held(false, true, false, true))),
                        command("toggle-fullscreen"),
                    ),
                ],
            },
        ],
    }
}

/// The command names of `menu`'s command items, in order: their tags.
fn commands(menu: &Menu) -> Vec<String> {
    menu.menus
        .iter()
        .flat_map(|submenu| &submenu.items)
        .filter_map(|item| match item {
            Item::Entry {
                action: Action::Command(name),
                ..
            } => Some(name.clone()),
            _ => None,
        })
        .collect()
}

/// Reads the menu bar on the main thread.
fn read() -> Option<Reading> {
    dispatch2::run_on_main(|_| probe::read_menu_bar())
}

/// Waits until the menu bar reads as `menu`, and gives the reading.
fn shown(menu: &Menu) -> Result<Reading, String> {
    let deadline = Instant::now() + STEP;
    loop {
        let reading = read();
        if let Some(reading) = &reading
            && reading.menu == *menu
        {
            return Ok(reading.clone());
        }
        if Instant::now() >= deadline {
            let (read, foreign) = reading
                .map(|reading| (Some(reading.menu), reading.foreign))
                .unwrap_or_default();
            return Err(format!(
                "the menu bar read back {read:?}, not the menu asked (AppKit's own items: {foreign:?})"
            ));
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Performs the command item tagged `tag` on the main thread; whether one
/// was found. It is found by its action and tag, not its place, since
/// AppKit adds items of its own.
fn perform(tag: usize) -> bool {
    dispatch2::run_on_main(|mtm| {
        let Some(main) = NSApplication::sharedApplication(mtm).mainMenu() else {
            return false;
        };
        for top in main.itemArray().iter() {
            let Some(submenu) = top.submenu() else {
                continue;
            };
            let found = submenu.itemArray().iter().position(|item| {
                item.action() == Some(sel!(choose:)) && usize::try_from(item.tag()) == Ok(tag)
            });
            if let Some(index) = found {
                submenu.performActionForItemAtIndex(index as isize);
                return true;
            }
        }
        false
    })
}

/// The `Input::Menu` names reported so far, in order.
fn chosen(inputs: &[Input]) -> Vec<String> {
    inputs
        .iter()
        .filter_map(|input| match input {
            Input::Menu(name) => Some(name.clone()),
            _ => None,
        })
        .collect()
}

/// Performs the Quit item from the run loop, and returns at once.
fn quit() {
    dispatch2::run_on_main(|mtm| {
        let this = Quitter::alloc(mtm).set_ivars(());
        // SAFETY: `init` is `NSObject`'s initialiser, called once on the
        // allocation.
        let quitter: Retained<Quitter> = unsafe { msg_send![super(this), init] };
        // SAFETY: `quit:` takes one object argument, which may be nil. The
        // target is retained until it is performed.
        unsafe {
            quitter.performSelectorOnMainThread_withObject_waitUntilDone(sel!(quit:), None, false)
        };
    });
}

/// Runs the scenario on `platform`, whose report is `record`.
pub fn scenario(platform: &impl Platform, record: &Record) -> Result<(), String> {
    opened(record)?;
    let menu = sample();
    platform.request(Request::Menu(menu.clone()));
    let reading = shown(&menu)?;
    if !reading.services_set {
        return Err("the Services item's submenu is not the application's `servicesMenu`".into());
    }
    if !reading.windows_set {
        return Err("the Window menu is not the application's `windowsMenu`".into());
    }
    if reading.full_screen_items != 0 {
        return Err(format!(
            "{} item(s) of AppKit's call `toggleFullScreen:` (AppKit's own items: {:?})",
            reading.full_screen_items, reading.foreign
        ));
    }

    let names = commands(&menu);
    for (tag, name) in names.iter().enumerate() {
        if !perform(tag) {
            return Err(format!("no command item is tagged {tag} ({name})"));
        }
        let seen = record.wait(STEP, |inputs| chosen(inputs).len() > tag);
        let seen = chosen(&seen);
        if seen.get(tag) != Some(name) {
            return Err(format!(
                "performing {name}'s item reported {seen:?}, not `Input::Menu({name:?})` last"
            ));
        }
    }
    if chosen(&record.inputs()) != names {
        return Err(format!(
            "the menu choices reported are {:?}, not {names:?}",
            chosen(&record.inputs())
        ));
    }

    quit();
    reported(record, 1, "after performing the Quit item")?;
    if QUIT_RETURNED.load(Ordering::SeqCst) != 0 {
        return Err("the Quit item's perform returned with no reply made".into());
    }
    platform.request(Request::KeepRunning);
    let deadline = Instant::now() + STEP;
    while QUIT_RETURNED.load(Ordering::SeqCst) < 1 {
        if Instant::now() >= deadline {
            return Err("after keeping running, the Quit item's perform did not return".into());
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    Ok(())
}
