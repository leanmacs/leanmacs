import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Config.Owner
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.Display
import Editor.Display.Model
import Editor.DisplayRules
import Editor.Event
import Editor.Ex.Line
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Keymap
import Editor.Language
import Editor.Layout
import Editor.Loop
import Editor.Loop.Driver
import Editor.Menu
import Editor.Mode
import Editor.ModeLine
import Editor.Process.Environment
import Editor.Program
import Editor.Quit
import Editor.Scene
import Editor.State
import Editor.TabBar
import Editor.Test.Driver
import Editor.Test.Editing
import Editor.Test.Frame
import Editor.Test.Hosted
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Text
import Editor.Workspace
import FilesApi
import ModelTest.Check
import ModelTest.Support.Switching

/-!
# Model tests: `Editor/Menu.lean`

The model tests of `Editor/Menu.lean`, the core's menu mechanism:
`menuChecks`, on a menu and a registry written here. The menu that ships
is the `menu` package's, checked there (`MenuTest.standardMenuChecks`,
`packages/menu/`). The root module `ModelTest` runs them; its module
doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

namespace MenuTest

/-- The chord of `character` with `modifiers` held, the system key alone
unless told. -/
def equivalent (character : Char) (modifiers : Modifiers := { superKey := true }) :
    Option KeyEquivalent :=
  some { character, modifiers }

/-- A menu bar written for the checks, with no item of the menu that
ships: an application menu whose system items show `s-h`, `M-s-h` and
`s-q`, as AppKit's own do, and a menu of three command items, `test-open`,
`test-save` and `test-zoom`. -/
def sample : Menu :=
  {
    menus :=
      #[{ title := "App", role := some .app
          items :=
            #[.item "Hide" (equivalent 'h') (.system .hide),
              .item "Hide Others" (equivalent 'h' { alt := true, superKey := true })
                (.system .hideOthers),
              .item "Quit" (equivalent 'q') (.system .quit)] },
        { title := "Test"
          items :=
            #[.item "Open" none (.command "test-open"), .item "Save" none (.command "test-save"),
              .item "Zoom" none (.command "test-zoom")] }] }

/-- The registry of the checks: the command `test-minimise`, which asks the
frame to minimise, and the bindings `s-o` to `test-open`, `s-s` to
`test-save` and `C-s-f` to `test-zoom`, registered for the owner
`compiled`, an owner that is not config, as a host registers a package's,
and `config` as config's bindings and `commands` as config's commands. -/
def sampleRegistry (config : Array Config.KeyBinding := #[])
    (commands : Array Config.Registration := #[]) : Config.Registry :=
  (((({} : Config.Registry).replace .compiled
                #[{ name := "test-minimise",
                    action := .plain (Display.askFrame .minimise) }]).replaceBindings
            .compiled
            #[.ofKeys (keys "s-o") "test-open", .ofKeys (keys "s-s") "test-save",
              .ofKeys (keys "C-s-f") "test-zoom"]).replaceBindings
        .config config).replace
    .config commands

/-- A driver of the checks (the kit's `frameDriverOver`) over `registry`,
`sampleRegistry` unless told, and the menu `sample`. -/
def sampleDriver (registry : Config.Registry := sampleRegistry) : Option TestDriver :=
  frameDriverOver registry (some sample)

/-- The menu bar the driver over `registry` publishes once the window has
said its size; `none` without one. -/
def menuShown (registry : Config.Registry) : Option Menu := do
  let driver ← sampleDriver registry
  let scene ← (fedTo driver [resizedTo false]).1.model.display.scenes.back?
  scene.menu

/-- The key equivalent `menu`'s item that runs `command` shows; `none` when
no item runs it. -/
def keyShown (menu : Menu) (command : String) : Option (Option KeyEquivalent) :=
  menu.menus.findSome? fun submenu =>
    submenu.items.findSome? fun
      | .item _ key (.command name) => if name == command then some key else none
      | _ => none

/-- The registry of nothing but the binding of `text` to `test-open`. -/
def openBoundTo (text : String) : Config.Registry :=
  ({} : Config.Registry).replaceBindings .compiled #[.ofKeys (keys text) "test-open"]

end MenuTest

open MenuTest in
/-- The checks of the menu bar (`Editor/Menu.lean`): a command item chosen
runs its command as an invocation, and the key equivalents the published
menu shows are the chords the registry binds, on a menu and a registry
written here (`MenuTest.sample`, `MenuTest.sampleRegistry`), so they name
nothing of the menu that ships or of the frame commands. The menu that
ships is the `menu` package's (`MenuTest.standardMenuChecks`,
`packages/menu/`). -/
def menuChecks : List Check :=
  [{  name :=
        "a menu's Undo runs the command registered as undo, as a key of that command does: after a delete over abc, both leave abc and the same selection"
      run :=
        pure <|
          -- A stand-in for a scheme package's `undo`, under the name the
          -- Edit menu's item runs: the kit's undo.
          let undo := (editingDispatched.find? (·.1 == "edit-undo")).map (·.2)
          match
            undo.bind fun undo =>
              editingDriver "|abc" [("C-u", invoke "undo")] [("undo", undo)] with
          | none => false
          | some driver =>
            let cut := keysFed driver "<Delete>"
            let byKey := keysFed cut "C-u"
            let byMenu := (cut.feed { event := .menu "undo", stamp := 0 }).1
            shownOf cut != shownOf byKey && shownOf byMenu == shownOf byKey &&
              (shownOf byKey).replace "|" "" == "abc" &&
              selectionOf byMenu == selectionOf byKey },
    { name :=
        "a menu item naming a command its scheme makes something of runs with the report of the state the scheme hands back: under a scheme whose report the command mark switches, the item leaves the view with that report, at rest; one whose command gives up leaves the scheme at rest as it was"
      run :=
        pure <|
          let over (commands : List (String × Dispatched)) : Option (Loop.Driver switching) :=
            (Loop.Driver.over (switchingKeys [] commands) (fun _ => none) (barState "ab\ncd" 1)
                editorModel).toOption
          match over [], over [("mark", fun _ => giveUp "failed")] with
          | some driver, some failing =>
            let initial := switching.report switching.init ⟨0⟩
            let entered := (driver.feed { event := .menu "mark", stamp := 0 }).1
            let failed := (failing.feed { event := .menu "mark", stamp := 0 }).1
            let report := switching.report entered.loop.input ⟨0⟩
            report == markedReport && report != initial &&
              switching.report entered.loop.atRest ⟨0⟩ == report &&
              entered.loop.state.echo.isEmpty &&
              failed.loop.state.echo == "mark: failed" &&
              switching.report failed.loop.input ⟨0⟩ == initial &&
              switching.report failed.loop.atRest ⟨0⟩ == initial &&
              selectionOf failed == selectionOf failing
          | _, _ => false },
    { name :=
        "a menu's item runs the command it names: chosen, the item that names a command that asks the frame to minimise asks it to"
      run := pure (framed sampleDriver [.menu "test-minimise"] == some (#[.minimise], false)) },
    { name :=
        "a menu runs config's command of its name in place of the compiled one, and a command only config registers"
      run :=
        let replaced :=
          sampleRegistry (commands :=
            #[{ name := "test-minimise", action := .plain (Display.askFrame .enterFullscreen) }])
        let greeting :=
          sampleRegistry (commands :=
            #[{ name := "greet", action := .plain (Display.askFrame .leaveFullscreen) }])
        pure
          (framed (sampleDriver replaced) [.menu "test-minimise"] ==
              some (#[.enterFullscreen], false) &&
            framed (sampleDriver greeting) [.menu "greet"] == some (#[.leaveFullscreen], false)) },
    { name :=
        "a menu naming no command says no such command as an invocation does, and asks the frame nothing"
      run :=
        pure <|
          match sampleDriver with
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
              | name =>
                if name == FilesApi.openFileName || name == Quit.name then some ran else none }
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
        "on the checks' registry the published menu is the one handed with the chords bound to its commands, s-o, s-s and C-s-f, and the system items' own; after config binds an item's command to M-s-f, the item shows M-s-f"
      run :=
        let compiled : String → Option KeyEquivalent
          | "test-open" => equivalent 'o'
          | "test-save" => equivalent 's'
          | "test-zoom" => equivalent 'f' { control := true, superKey := true }
          | _ => none
        let rebound := sampleRegistry #[.ofKeys (keys "M-s-f") "test-zoom"]
        let shown := equivalent 'f' { alt := true, superKey := true }
        pure
          (menuShown sampleRegistry == some (sample.withKeys compiled) &&
            ["test-open", "test-save", "test-zoom", "nope"].all
              (fun name => sampleRegistry.keyEquivalent? name == compiled name) &&
            rebound.keyEquivalent? "test-zoom" == shown &&
            ((menuShown rebound).bind (keyShown · "test-zoom")) == some shown) },
    { name :=
        "an item whose command has no single chord with the system key shows none: s-o rebound by config to another command, only C-x C-f, only C-o"
      run :=
        let taken := sampleRegistry #[.ofKeys (keys "s-o") "test-save"]
        let registries := [taken, openBoundTo "C-x C-f", openBoundTo "C-o"]
        pure <|
          registries.all fun registry =>
            registry.keyEquivalent? "test-open" == none &&
              ((menuShown registry).bind (keyShown · "test-open")) == some none },
    { name :=
        "a chord a system item shows is no command item's, as AppKit runs the system item: config's s-q, s-h or M-s-h alone to the save item's command shows none on it, and beside the compiled s-s the item shows s-s"
      run :=
        let bound := fun text =>
          ({} : Config.Registry).replaceBindings .config #[.ofKeys (keys text) "test-save"]
        let beside := sampleRegistry #[.ofKeys (keys "s-q") "test-save"]
        pure
          (["s-q", "s-h", "M-s-h"].all
              (fun text => ((menuShown (bound text)).bind (keyShown · "test-save")) == some none) &&
            ((menuShown beside).bind (keyShown · "test-save")) == some (equivalent 's') &&
            (menuShown beside).map (·.systemKeys) == some sample.systemKeys) }]

end ModelTest
