import Editor.Clipboard
import Editor.FrameCommands
import Editor.Menu
import Editor.Package
import FilesApi

/-!
# The `menu` package: the menu bar that ships

The menu bar a host publishes (`Editor/Menu.lean`) and the key bindings of
its editor items: the package `menu` (`Menu.package`,
`Editor/Package.lean`), whose `setup` binds the keys and defines the menus
of `Menu.standard`, one at a time (`defineMenu`). A host registers it for
the owner `menu` when its loop starts, before any config
(`Editor/Config/Packages.lean`), and a host that is not handed it publishes
no menu bar:

- **`Menu.standard`**: the application's menu (About, Services, Hide, Hide
  Others, Show All, Quit, with the system's own key equivalents `s-h`,
  `M-s-h` and `s-q`), File (Open…, Save), Edit (Undo, Redo, a separator,
  Cut, Copy, Paste, a separator, Select All: the clipboard items name the
  core's names, `Clipboard.cutName`, `copyName`, `pasteName` and
  `selectAllName` (`Editor/Clipboard.lean`, "The Edit menu's names"), under
  which the input scheme's package registers its commands, as evil does
  in `packages/evil/Evil/Clipboard.lean`; Undo and Redo name evil's `undo` and
  `redo` as text) and Window (Minimise, Enter Full Screen). Its command items carry no key: a host
  fills them from the registry as it is at each step
  (`Config.Registry.menuBar?`), so a menu item and its key run the same
  command, and config's rebinding moves the shortcut. Config replaces one
  of these menus by defining a menu of its title, and adds one by defining
  a new title (`Editor/Config/Registry.lean`, "Menus").
- **The bindings** (`bindKeys`): `s-o` runs `open-file`, `s-s` `save-buffer`, `s-z`
  `undo`, `s-Z` (shift is in the character, as a chord says it) `redo`,
  `s-x` `clipboard-cut`, `s-c` `clipboard-copy`, `s-v` `clipboard-paste`
  and `s-a` `select-all`. They come after the `frame-commands` package's
  (`Editor/FrameCommands/Compiled.lean`), whose `C-s-f` and `s-m` are the
  Window menu's.

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
`EvilTest.clipboardCommandChecks`.
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

/-- The menu bar that ships, before its command items' keys are filled from
the registry (`Config.Registry.menuBar?`): the menus the `menu` package
defines, in order. -/
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
            #[.item "Open…" none (.command FilesApi.openFileName),
              .item "Save" none (.command FilesApi.saveName)] },
        -- Undo and Redo are names of evil's commands
        -- (`packages/evil/Evil/Compiled.lean`); the clipboard items' are the core's
        -- (`Editor/Clipboard.lean`).
        { title := "Edit"
          items :=
            #[.item "Undo" none (.command "undo"), .item "Redo" none (.command "redo"), .separator,
              .item "Cut" none (.command Clipboard.cutName),
              .item "Copy" none (.command Clipboard.copyName),
              .item "Paste" none (.command Clipboard.pasteName), .separator,
              .item "Select All" none (.command Clipboard.selectAllName)] },
        { title := "Window", role := some .window
          items :=
            #[.item "Minimise" none (.command FrameCommands.minimiseName),
              .item "Enter Full Screen" none (.command FrameCommands.toggleFullscreenName)] }] }

/-- The chord of the character `text` with the system key held. -/
private def chord (text : String) : Key :=
  Key.chord { logical := .character text, modifiers := { superKey := true } }

/-- The package `menu`: the key bindings of the menu's File and Edit items,
then the menus of `standard`, in order. The clipboard commands' names
are the core's (`Editor/Clipboard.lean`, "The Edit menu's names"). -/
def package : Package :=
  { name := "menu"
    setup := do
      bindKeys [chord "o"] FilesApi.openFileName
      bindKeys [chord "s"] FilesApi.saveName
      bindKeys [chord "z"] "undo"
      bindKeys [chord "Z"] "redo"
      bindKeys [chord "x"] Clipboard.cutName
      bindKeys [chord "c"] Clipboard.copyName
      bindKeys [chord "v"] Clipboard.pasteName
      bindKeys [chord "a"] Clipboard.selectAllName
      for menu in standard.menus do
        defineMenu menu }

end Menu

end Editor
