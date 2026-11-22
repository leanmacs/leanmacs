import Editor.Clipboard
import Editor.Config.Packages
import Editor.FrameCommands
import Editor.Menu
import Editor.Menu.Compiled
import Editor.Test.Config
import Editor.Test.Driver
import Editor.Test.Frame
import Editor.Test.Hosted
import Editor.Test.Keys
import ModelTest.Check

/-!
# Model tests: `Editor/Menu/Compiled.lean`

The model tests of the `menu` package (`Editor/Menu/Compiled.lean`):
`standardMenuChecks`: the standard menu, its items and the chords the
package binds to them, on the kit's frame driver (`Editor/Test/Frame.lean`)
over a registry of the package's bindings and the two chords the frame
commands' package binds to the Window menu's commands, written here. The
core's menu mechanism (a chosen item runs its command, the key equivalents
a registry gives a menu) is checked on a menu written in the test
(`menuChecks`, `ModelTest/Editor/Menu.lean`). The root module `ModelTest`
runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

namespace StandardMenuTest

/-- The chords the frame commands' package binds to the Window menu's
commands, written here as that package binds them, so the checks name no
module of it but the names: `C-s-f` to `toggle-fullscreen` and `s-m` to
`minimise-window`. That the package binds them is its own checks'
(`frameCommandChecks`). -/
def frameBindings : Array Config.KeyBinding :=
  #[.ofKeys (keys "C-s-f") FrameCommands.toggleFullscreenName,
    .ofKeys (keys "s-m") FrameCommands.minimiseName]

/-- The registry of the standard menu's checks: the `menu` package's
bindings and `frameBindings`, registered for the owner `compiled`, an owner
that is not config, as a host registers a package's. -/
def menuRegistry : Config.Registry :=
  ({} : Config.Registry).replaceBindings .compiled
    (frameBindings ++ Menu.package.registered.bindings)

/-- The menu bar the frame driver over `registry` and the standard menu
publishes once the window has said its size; `none` without one. -/
def menuShown (registry : Config.Registry) : Option Menu := do
  let driver ← frameDriverOver registry (some Menu.standard)
  let scene ← (fedTo driver [resizedTo false]).1.model.display.scenes.back?
  scene.menu

/-- The key equivalent of `character` with `modifiers` held, the system key
alone unless told. -/
def equivalent (character : Char) (modifiers : Modifiers := { superKey := true }) :
    Option KeyEquivalent :=
  some { character, modifiers }

/-- The key equivalents the compiled bindings give the menu's commands. -/
def compiledEquivalents : String → Option KeyEquivalent
  | "open-file" => equivalent 'o'
  | "save-buffer" => equivalent 's'
  | "undo" => equivalent 'z'
  | "redo" => equivalent 'Z'
  | "clipboard-cut" => equivalent 'x'
  | "clipboard-copy" => equivalent 'c'
  | "clipboard-paste" => equivalent 'v'
  | "select-all" => equivalent 'a'
  | "minimise-window" => equivalent 'm'
  | "toggle-fullscreen" => equivalent 'f' { control := true, superKey := true }
  | _ => none

/-- The key equivalent `menu`'s item that runs `command` shows; `none` when
no item runs it. -/
def keyShown (menu : Menu) (command : String) : Option (Option KeyEquivalent) :=
  menu.menus.findSome? fun submenu =>
    submenu.items.findSome? fun
      | .item _ key (.command name) => if name == command then some key else none
      | _ => none

end StandardMenuTest

open StandardMenuTest in
/-- The checks of the standard menu (`Editor/Menu/Compiled.lean`): its
items, the names they run and the chords the package binds to them. -/
def standardMenuChecks : List Check :=
  [{  name :=
        "the Edit menu's Cut, Copy, Paste and Select All, and s-x, s-c, s-v and s-a, name the core's clipboard names"
      run :=
        let named :=
          [("Cut", "s-x", Clipboard.cutName), ("Copy", "s-c", Clipboard.copyName),
            ("Paste", "s-v", Clipboard.pasteName), ("Select All", "s-a", Clipboard.selectAllName)]
        let edit := (Menu.standard.menus.find? (·.title == "Edit")).map (·.items)
        let registry := hostedRegistry #[Menu.package]
        pure
          (named.all fun (title, chord, name) =>
            (edit.getD #[]).any
                (fun
                  | .item shown _ (.command command) => shown == title && command == name
                  | _ => false) &&
              boundTo registry chord == some { command := name }) },
    { name :=
        "on the compiled registry the published menu is the standard one with the chords bound to its commands: s-o, s-s, s-z, s-Z, s-x, s-c, s-v, s-a, s-m and C-s-f, and the system items' own"
      run :=
        pure
          (menuShown menuRegistry == some (Menu.standard.withKeys compiledEquivalents) &&
            ["open-file", "save-buffer", "undo", "redo", "clipboard-cut", "clipboard-copy",
                  "clipboard-paste", "select-all", "minimise-window", "toggle-fullscreen",
                  "nope"].all
              fun name => menuRegistry.keyEquivalent? name == compiledEquivalents name) },
    { name :=
        "the published default menu's Edit menu is Undo, Redo, a separator, Cut, Copy, Paste, a separator and Select All, with the key equivalents s-z, s-Z (s-S-z), s-x, s-c, s-v and s-a"
      run :=
        let edit : Option Submenu :=
          (menuShown menuRegistry).bind fun menu => menu.menus.find? (·.title == "Edit")
        pure
          (edit.map (·.items) ==
            some
              #[.item "Undo" (equivalent 'z') (.command "undo"),
                .item "Redo" (equivalent 'Z') (.command "redo"), .separator,
                .item "Cut" (equivalent 'x') (.command "clipboard-cut"),
                .item "Copy" (equivalent 'c') (.command "clipboard-copy"),
                .item "Paste" (equivalent 'v') (.command "clipboard-paste"), .separator,
                .item "Select All" (equivalent 'a') (.command "select-all")]) },
    { name :=
        "the standard menu's Window menu is Minimise and Enter Full Screen, which run minimise-window and toggle-fullscreen, and its File menu Open… and Save, which run open-file and save-buffer"
      run :=
        let items (title : String) : Option (Array MenuItem) :=
          (Menu.standard.menus.find? (·.title == title)).map (·.items)
        pure
          (items "Window" ==
              some
                #[.item "Minimise" none (.command "minimise-window"),
                  .item "Enter Full Screen" none (.command "toggle-fullscreen")] &&
            items "File" ==
              some
                #[.item "Open…" none (.command "open-file"),
                  .item "Save" none (.command "save-buffer")]) }]

end ModelTest
