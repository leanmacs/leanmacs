import Editor.Config.Registry
import Editor.Files
import Editor.FrameCommands
import Editor.Menu

/-!
# The menu bar, as compiled code ships it

The menu bar a host publishes (`Editor/Menu.lean`) and the compiled key
bindings of its editor items, as a host is handed them
(`Headless.shippedOver`):

- **`Menu.standard`**: the application's menu (About, Services, Hide, Hide
  Others, Show All, Quit, with the system's own key equivalents `s-h`,
  `M-s-h` and `s-q`), File (Open…, Save), Edit (Undo, Redo) and Window
  (Minimise, Enter Full Screen). Its command items carry no key: a host
  fills them from the registry as it is at each step
  (`Config.Registry.menuOf`), so a menu item and its key run the same
  command, and config's rebinding moves the shortcut.
- **`Menu.bindings`**: `s-o` runs `open-file`, `s-s` `save-buffer`, `s-z`
  `undo` and `s-Z` (shift is in the character, as a chord says it)
  `redo`. A host registers them for the owner `compiled` beside
  `FrameCommands.bindings`, whose `C-s-f` and `s-m` are the Window menu's.

A chord the menu shows never reaches the window as a key on macOS: AppKit
runs the item first. Since the menu's keys are the keymap's, the two agree.
A config binding of a system item's chord (`s-h`, `M-s-h`, `s-q`) is
shadowed by the item, so `menuOf` shows it on no command item: the command
shows its next chord, or none.

Pinned by `ModelTest.menuChecks` and `ConfigTest.shippedChecks`.
-/

namespace Editor

namespace Menu

/-- The application's name, as its menu says it. -/
def appName : String :=
  "Leanmacs"

/-- The chord of `character` with the system key held, and alt when
`alt`. -/
private def commandKey (character : Char) (alt : Bool := false) : KeyEquivalent :=
  { character, modifiers := { alt, superKey := true } }

/-- The menu bar a host publishes, before its command items' keys are
filled from the registry (`Config.Registry.menuOf`). -/
def standard : Menu :=
  {
    menus :=
      #[{ title := appName, role := some .app
          items :=
            #[.item s!"About {appName}" none (.system .about),
              .item "Services" none (.system .services), .separator,
              .item s!"Hide {appName}" (some (commandKey 'h')) (.system .hide),
              .item "Hide Others" (some (commandKey 'h' (alt := true))) (.system .hideOthers),
              .item "Show All" none (.system .showAll), .separator,
              .item s!"Quit {appName}" (some (commandKey 'q')) (.system .quit)] },
        { title := "File"
          items :=
            #[.item "Open…" none (.command Files.openName),
              .item "Save" none (.command Files.saveName)] },
        -- The names of evil's commands (`Editor/Evil/Compiled.lean`).
        { title := "Edit"
          items := #[.item "Undo" none (.command "undo"), .item "Redo" none (.command "redo")] },
        { title := "Window", role := some .window
          items :=
            #[.item "Minimise" none (.command FrameCommands.minimiseName),
              .item "Enter Full Screen" none (.command FrameCommands.toggleFullscreenName)] }] }

/-- The chord of the character `text` with the system key held. -/
private def chord (text : String) : Key :=
  Key.chord { logical := .character text, modifiers := { superKey := true } }

/-- The compiled key bindings of the menu's File and Edit items, as a host
registers them for the owner `compiled`. -/
def bindings : Array Config.KeyBinding :=
  #[{ keys := [chord "o"], command := Files.openName },
    { keys := [chord "s"], command := Files.saveName }, { keys := [chord "z"], command := "undo" },
    { keys := [chord "Z"], command := "redo" }]

end Menu

/-- `menu` with each command item's key equivalent the one `registry`'s
bindings give its command (`keyEquivalent?`), never a key one of `menu`'s
system items shows (`Menu.systemKeys`). -/
def Config.Registry.menuOf (registry : Config.Registry) (menu : Menu) : Menu :=
  menu.withKeys (registry.keyEquivalent? (taken := menu.systemKeys))

end Editor
