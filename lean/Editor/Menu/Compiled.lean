import Editor.Config.Registry
import Editor.Evil.Clipboard
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
  `M-s-h` and `s-q`), File (Open…, Save), Edit (Undo, Redo, a separator,
  Cut, Copy, Paste, a separator, Select All: the clipboard commands of
  `Editor/Evil/Clipboard.lean`) and Window (Minimise, Enter Full Screen). Its command items carry no key: a host
  fills them from the registry as it is at each step
  (`Config.Registry.menuOf`), so a menu item and its key run the same
  command, and config's rebinding moves the shortcut.
- **`Menu.bindings`**: `s-o` runs `open-file`, `s-s` `save-buffer`, `s-z`
  `undo`, `s-Z` (shift is in the character, as a chord says it) `redo`,
  `s-x` `clipboard-cut`, `s-c` `clipboard-copy`, `s-v` `clipboard-paste`
  and `s-a` `select-all`. A host registers them for the owner `compiled` beside
  `FrameCommands.bindings`, whose `C-s-f` and `s-m` are the Window menu's.

A chord the menu shows never reaches the window as a key on macOS: AppKit
runs the item first. Since the menu's keys are the keymap's, the two agree,
and the loop runs a menu item through the scheme as a key bound to the
command's name would run (`InputScheme.invoked`, `Editor/Loop.lean`), so
`s-c` chosen as an item is `"+y` in a visual state as the key is.
A config binding of a system item's chord (`s-h`, `M-s-h`, `s-q`) is
shadowed by the item, so `menuOf` shows it on no command item: the command
shows its next chord, or none.

Pinned by `ModelTest.menuChecks` and `ConfigTest.shippedChecks` (which runs
in the `config-test` executable, under `mise run ci`, not under `lake test`
alone), and what the clipboard items do by
`ModelTest.clipboardCommandChecks`.
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
          items :=
            #[.item "Undo" none (.command "undo"), .item "Redo" none (.command "redo"), .separator,
              .item "Cut" none (.command Evil.cutName), .item "Copy" none (.command Evil.copyName),
              .item "Paste" none (.command Evil.pasteName), .separator,
              .item "Select All" none (.command Evil.selectAllName)] },
        { title := "Window", role := some .window
          items :=
            #[.item "Minimise" none (.command FrameCommands.minimiseName),
              .item "Enter Full Screen" none (.command FrameCommands.toggleFullscreenName)] }] }

/-- The chord of the character `text` with the system key held. -/
private def chord (text : String) : Key :=
  Key.chord { logical := .character text, modifiers := { superKey := true } }

/-- The compiled key bindings of the menu's File and Edit items, as a host
registers them for the owner `compiled`. The clipboard commands' names are
`Editor/Evil/Clipboard.lean`'s. -/
def bindings : Array Config.KeyBinding :=
  #[.ofKeys [chord "o"] Files.openName, .ofKeys [chord "s"] Files.saveName,
    .ofKeys [chord "z"] "undo", .ofKeys [chord "Z"] "redo", .ofKeys [chord "x"] Evil.cutName,
    .ofKeys [chord "c"] Evil.copyName, .ofKeys [chord "v"] Evil.pasteName,
    .ofKeys [chord "a"] Evil.selectAllName]

end Menu

/-- `menu` with each command item's key equivalent the one `registry`'s
bindings give its command (`keyEquivalent?`), never a key one of `menu`'s
system items shows (`Menu.systemKeys`). -/
def Config.Registry.menuOf (registry : Config.Registry) (menu : Menu) : Menu :=
  menu.withKeys (registry.keyEquivalent? (taken := menu.systemKeys))

end Editor
