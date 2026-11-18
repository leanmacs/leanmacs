import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Compile.Contribution
import Editor.Config.Owner
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.Display
import Editor.Display.Model
import Editor.DisplayRules
import Editor.Event
import Editor.Ex
import Editor.Ex.Line
import Editor.Files
import Editor.FrameCommands
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.InputScheme.Vim
import Editor.InputScheme.Vim.Default
import Editor.Invocation
import Editor.Job
import Editor.Keymap
import Editor.Language
import Editor.Layout
import Editor.Loop
import Editor.Loop.Driver
import Editor.Menu
import Editor.Menu.Compiled
import Editor.Mode
import Editor.ModeLine
import Editor.Process.Environment
import Editor.Program
import Editor.Role
import Editor.Scene
import Editor.State
import Editor.TabBar
import Editor.Text
import Editor.Text.Model
import Editor.Workspace
import ModelTest.Check
import ModelTest.Support.Driver
import ModelTest.Support.Evil
import ModelTest.Support.Frame
import ModelTest.Support.Keys
import ModelTest.Support.Loop
import ModelTest.Support.Models

/-!
# Model tests: `Editor/Menu.lean`

The model tests of `Editor/Menu.lean`: `menuChecks`. The root module `ModelTest`
runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The menu bar the frame driver over `registry` publishes once the window
has said its size; `none` without one. -/
def menuShown (registry : Config.Registry) : Option Menu := do
  let driver ← frameDriver registry
  let scene ← (fedTo driver [resizedTo false]).1.model.display.scenes.back?
  scene.menu

/-- The key equivalent of `character` with `modifiers` held, the system key
alone unless told. -/
def equivalent (character : Char) (modifiers : Modifiers := { superKey := true }) :
    Option KeyEquivalent :=
  some { character, modifiers }

/-- The Vim scheme of the menu's run-table checks: the default states, with
normal state's run table holding `t-enter`, run as `visual-line` entering
that state, and `t-fail`, run as itself entering it too. -/
def menuRunScheme : InputScheme :=
  let enter (name : String) : Vim.Edit := .run { name, enters := some "visual-line" } none none
  Vim.scheme
    (Vim.Default.states.register
      { Vim.Default.states.initial with
        runs := [("t-enter", enter "visual-line"), ("t-fail", enter "t-fail")] })

/-- A driver of the menu's run-table checks over the text and cursor
`fixture` says, with evil's commands and `t-fail`, which gives up. -/
def menuRunDriver (fixture : String) : Option (Loop.Driver menuRunScheme) :=
  let (contents, head) := barred fixture
  let fail : Dispatched := fun _ => giveUp "failed"
  let keys : Loop.Keys menuRunScheme :=
    { command? := (evilHanded (commands := [("t-fail", fail)])).command? }
  (Loop.Driver.over keys (fun _ => none) (evilState contents head) editorModel).toOption

/-- The selection of view 0 of `driver`, as the text model has it. -/
def menuRunSelection (driver : Loop.Driver menuRunScheme) : Option Selection := do
  let target ← driver.loop.state.target? ⟨0⟩
  (target.selection.runModel driver.model.texts).1.toOption

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

/-- The registry of nothing but the binding of `text` to `open-file`. -/
def openBoundTo (text : String) : Config.Registry :=
  ({} : Config.Registry).replaceBindings .compiled #[.ofKeys (keys text) "open-file"]

/-- The checks of the menu bar (`Editor/Menu.lean`, `Editor/Menu/Compiled.lean`):
a command item chosen runs its command as an invocation, and the key
equivalents the published menu shows are the chords the registry binds. -/
def menuChecks : List Check :=
  [{  name :=
        "a menu's undo undoes as u does: after x over abc, both leave abc and the same selection"
      run :=
        pure <|
          match evilDriver "|abc" with
          | none => false
          | some driver =>
            let cut := evilFed driver "x"
            let byKey := evilFed cut "u"
            let byMenu := (cut.feed { event := .menu "undo", stamp := 0 }).1
            evilShown cut != evilShown byKey && evilShown byMenu == evilShown byKey &&
              (evilShown byKey).replace "|" "" == "abc" &&
              evilSelection byMenu == evilSelection byKey },
    { name :=
        "a menu item naming a command the view's state's run table has an entry for runs that entry, with the report of the state it enters: t-enter in normal state leaves the view in visual-line, its selection of the line shape, at rest; one that gives up leaves the scheme at rest in normal state"
      run :=
        pure <|
          match menuRunDriver "a|b\ncd" with
          | none => false
          | some driver =>
            let initial := menuRunScheme.report menuRunScheme.init ⟨0⟩
            let entered := (driver.feed { event := .menu "t-enter", stamp := 0 }).1
            let failed := (driver.feed { event := .menu "t-fail", stamp := 0 }).1
            let report := menuRunScheme.report entered.loop.input ⟨0⟩
            report.shape == .line && report.selecting &&
              menuRunScheme.report entered.loop.atRest ⟨0⟩ == report &&
              (menuRunSelection entered).map (·.shape) == some .line &&
              entered.loop.state.echo.isEmpty &&
              failed.loop.state.echo == "t-fail: failed" &&
              menuRunScheme.report failed.loop.input ⟨0⟩ == initial &&
              menuRunScheme.report failed.loop.atRest ⟨0⟩ == initial &&
              menuRunSelection failed == menuRunSelection driver },
    { name := "a menu's minimise-window asks the frame to minimise"
      run := pure (framed frameDriver [.menu "minimise-window"] == some (#[.minimise], false)) },
    { name :=
        "a menu runs config's command of its name in place of the compiled one, and a command only config registers"
      run :=
        let replaced :=
          frameRegistry (commands :=
            #[{ name := "minimise-window", action := .plain (Display.askFrame .enterFullscreen) }])
        let greeting :=
          frameRegistry (commands :=
            #[{ name := "greet", action := .plain (Display.askFrame .leaveFullscreen) }])
        pure
          (framed (frameDriver replaced) [.menu "minimise-window"] ==
              some (#[.enterFullscreen], false) &&
            framed (frameDriver greeting) [.menu "greet"] == some (#[.leaveFullscreen], false)) },
    { name :=
        "a menu naming no command says no such command as an invocation does, and asks the frame nothing"
      run :=
        pure <|
          match frameDriver with
          | none => false
          | some driver =>
            let fed := (fedTo driver [.menu "nope"]).1
            fed.loop.state.echo == "nope: no such command" && fed.model.display.asked.isEmpty },
    { name :=
        "a menu, a file to open and the system's quit publish with the padding and the mode line the step's keys carry: views padded 8 across and 8 down, the echo 8, and the status lines the handed segments', whether the command runs to its end or is refused"
      run :=
        let ran : Call → EditorM (Option Config.Write) := fun _ => pure none
        let refused : Call → EditorM (Option Config.Write) := fun _ => throw .badRange
        let handed : Loop.Keys TestScheme.scheme :=
          { padding := 8
            modeLine := { left := #[ModeLine.position], right := #[ModeLine.buffer] }
            command? := fun
              | "noop" => some ran
              | "balk" => some refused
              | name => if name == Files.openName || name == Ex.quitName then some ran else none }
        let status : Array StatusField :=
          #[{ text := "All", face := ModeLine.secondaryFace, padding := 4 },
            { text := "scratch", face := ModeLine.bufferFace, side := .right, padding := 4 }]
        let publishedBy (event : Event) : Bool :=
          match dispatched handed [event] with
          | some (_, #[scene], _) =>
            scene.views.map (·.padding) == #[{ across := 8, down := 8 }] &&
              scene.echoPadding == 8 &&
              scene.views.map (·.status) == #[status]
          | _ => false
        pure
          ([Event.menu "noop", .menu "balk", .openFiles ["a"], .quitRequested].all publishedBy) },
    { name :=
        "on the compiled registry the published menu is the standard one with the chords bound to its commands: s-o, s-s, s-z, s-Z, s-x, s-c, s-v, s-a, s-m and C-s-f, and the system items' own"
      run :=
        pure
          (menuShown frameRegistry == some (Menu.standard.withKeys compiledEquivalents) &&
            ["open-file", "save-buffer", "undo", "redo", "clipboard-cut", "clipboard-copy",
                  "clipboard-paste", "select-all", "minimise-window", "toggle-fullscreen",
                  "nope"].all
              fun name => frameRegistry.keyEquivalent? name == compiledEquivalents name) },
    { name :=
        "the published default menu's Edit menu is Undo, Redo, a separator, Cut, Copy, Paste, a separator and Select All, with the key equivalents s-z, s-Z (s-S-z), s-x, s-c, s-v and s-a"
      run :=
        let edit : Option Submenu :=
          (menuShown frameRegistry).bind fun menu => menu.menus.find? (·.title == "Edit")
        pure
          (edit.map (·.items) ==
            some
              #[.item "Undo" (equivalent 'z') (.command "undo"),
                .item "Redo" (equivalent 'Z') (.command "redo"), .separator,
                .item "Cut" (equivalent 'x') (.command "clipboard-cut"),
                .item "Copy" (equivalent 'c') (.command "clipboard-copy"),
                .item "Paste" (equivalent 'v') (.command "clipboard-paste"), .separator,
                .item "Select All" (equivalent 'a') (.command "select-all")]) },
    { name := "after config binds toggle-fullscreen to M-s-f, Enter Full Screen shows M-s-f"
      run :=
        let rebound := frameRegistry #[.ofKeys (keys "M-s-f") FrameCommands.toggleFullscreenName]
        let shown := equivalent 'f' { alt := true, superKey := true }
        pure
          (rebound.keyEquivalent? "toggle-fullscreen" == shown &&
            ((menuShown rebound).bind (keyShown · "toggle-fullscreen")) == some shown) },
    { name :=
        "an item whose command has no single chord with the system key shows none: s-o rebound by config to another command, only C-x C-f, only C-o"
      run :=
        let taken := frameRegistry #[.ofKeys (keys "s-o") "save-buffer"]
        let registries := [taken, openBoundTo "C-x C-f", openBoundTo "C-o"]
        pure <|
          registries.all fun registry =>
            registry.keyEquivalent? "open-file" == none &&
              ((menuShown registry).bind (keyShown · "open-file")) == some none },
    { name :=
        "a chord a system item shows is no command item's, as AppKit runs the system item: config's s-q, s-h or M-s-h alone to save-buffer shows none on Save, and beside the compiled s-s Save shows s-s"
      run :=
        let bound := fun text =>
          ({} : Config.Registry).replaceBindings .config #[.ofKeys (keys text) Files.saveName]
        let beside := frameRegistry #[.ofKeys (keys "s-q") Files.saveName]
        pure
          (["s-q", "s-h", "M-s-h"].all
              (fun text =>
                ((menuShown (bound text)).bind (keyShown · Files.saveName)) == some none) &&
            ((menuShown beside).bind (keyShown · Files.saveName)) == some (equivalent 's') &&
            (menuShown beside).map (·.systemKeys) == some Menu.standard.systemKeys) }]

end ModelTest
