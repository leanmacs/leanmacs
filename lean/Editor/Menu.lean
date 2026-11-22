import Editor.Event

/-!
# The menu bar

The application's menu bar, as the editor publishes it in the scene
(`Scene.menu`, `Editor/Scene.lean`): plain data, which names no windowing
library. The window builds it and reports a command item chosen as
`Event.menu`, with the command's name, which the loop runs as an
invocation no key yielded (`Editor/Loop.lean`). Every decision of which
items there are, what each is titled and which key each shows is the
editor's: the platform builds what it is given (`editor-platform`'s
`menu` module, `docs/design/rust-library.md`, "The menu bar").

A menu bar is a list of menus (`Submenu`), each with a title, a role that
makes it one the system knows (`MenuRole`: the application's menu, the
windows menu) or none, and its items. An item is a separator, or an item
with a title, a key equivalent and an action (`MenuAction`): an editor
command by name, or a thing the system does itself (`SystemAction`).

**A command item's key equivalent is the keymap's**: `Menu.withKeys` sets
each from a lookup of its command, which a host makes from the registry's
bindings (`Config.Registry.menuOf`; the menu that ships is the package
`menu`'s, `packages/menu/Menu/Compiled.lean`). A system
item's key is the menu's own, and `withKeys` leaves it; the lookup is told
the system items' keys (`Menu.systemKeys`), so no command item shows one.

## Where an addition goes

| Addition | Lean | Rust |
|---|---|---|
| A new item, menu or title of the default menu | `Menu.standard` (`packages/menu/Menu/Compiled.lean`) | Nothing |
| A new thing the system does from a menu | A constructor of `SystemAction`, its tag in `Display/Real.encode` and `Ffi.askedOf` | A variant of `editor_platform::menu::System`, its tag in `editor-ffi`'s `menu.rs` and its selector in `editor-platform-winit`'s `menu.rs` |
| A new attribute of an item | A field here, in the encoding and in the asked words | A field of `editor_platform::menu::Item`, and both crossings |

Pinned by `ModelTest.menuChecks`, `FfiTest`'s scene encoding check and
`ffi-test window-host`.
-/

namespace Editor

/-- A menu the system knows by its role. -/
inductive MenuRole where
  /-- The application's menu, first in the bar. -/
  | app
  /-- The windows menu, where the system lists the application's windows. -/
  | window
  deriving DecidableEq, Repr

/-- What the system does itself, from a menu item. -/
inductive SystemAction where
  /-- Shows the application's About panel. -/
  | about
  /-- The system's Services submenu. -/
  | services
  /-- Hides the application. -/
  | hide
  /-- Hides every other application. -/
  | hideOthers
  /-- Shows every application again. -/
  | showAll
  /-- Asks the application to quit, as the system does: it comes back as
  `Event.quitRequested`. -/
  | quit
  deriving DecidableEq, Repr

/-- What choosing an item does. -/
inductive MenuAction where
  /-- Runs the command of this name: the window reports `Event.menu` with
  it. -/
  | command (name : String)
  /-- Something the system does itself. -/
  | system (action : SystemAction)
  deriving DecidableEq, Repr

/-- The key that chooses an item: one character, and the modifiers held. -/
structure KeyEquivalent where
  /-- The character, as the key types it: `Z` for shift and `z`. -/
  character : Char
  /-- The modifiers held with it. -/
  modifiers : Modifiers := {}
  deriving DecidableEq, Repr

/-- One item of a menu. -/
inductive MenuItem where
  /-- A line between items. -/
  | separator
  /-- An item titled `title`, chosen by `key` when it has one, that does
  `action`. -/
  | item (title : String) (key : Option KeyEquivalent) (action : MenuAction)
  deriving DecidableEq, Repr

/-- One menu of the bar. -/
structure Submenu where
  /-- Its title in the bar. -/
  title : String
  /-- What the system makes of it; `none` for a plain menu. -/
  role : Option MenuRole := none
  /-- Its items, top to bottom. -/
  items : Array MenuItem := #[]
  deriving DecidableEq, Repr

/-- The menu bar: its menus, left to right. -/
structure Menu where
  /-- The menus. -/
  menus : Array Submenu := #[]
  deriving DecidableEq, Repr

/-- `item` with its key set from `keyOf` when it runs a command: the key
`keyOf` gives the command's name, or none. A separator and a system item
are left as they are. -/
def MenuItem.withKeys (keyOf : String → Option KeyEquivalent) : MenuItem → MenuItem
  | .item title _ (.command name) => .item title (keyOf name) (.command name)
  | other => other

/-- The key equivalents `menu`'s system items show, menu by menu, top to
bottom. -/
def Menu.systemKeys (menu : Menu) : List KeyEquivalent :=
  menu.menus.toList.flatMap fun submenu =>
    submenu.items.toList.filterMap fun
      | .item _ key (.system _) => key
      | _ => none

/-- `menu` with each command item's key set from `keyOf`
(`MenuItem.withKeys`). -/
def Menu.withKeys (menu : Menu) (keyOf : String → Option KeyEquivalent) : Menu :=
  {
    menus :=
      menu.menus.map fun submenu => { submenu with items := submenu.items.map (·.withKeys keyOf) } }

end Editor
