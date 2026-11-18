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
import Editor.Ex.Compiled
import Editor.Ex.Line
import Editor.File
import Editor.FrameCommands.Compiled
import Editor.InputScheme.Test
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
import Editor.Scene
import Editor.State
import Editor.TabBar
import Editor.Text
import Editor.Value
import Editor.Workspace
import ModelTest.Support.Driver
import ModelTest.Support.Models

/-!
# Model tests: support: Frame

The frame commands' registry, keys and driver. Shared by several test modules
under `ModelTest/Editor/`; it holds no checks of its own.
-/

namespace ModelTest

open Editor

/-- The registry of the frame command checks: the frame's commands, and the
ex line's, whose `quit` the frame's `s-q` names, and the frame's bindings,
with the menu bar's bindings, registered for the owner `compiled`, as a
host registers them, and `config` as config's bindings and `commands` as
config's commands. -/
def frameRegistry (config : Array Config.KeyBinding := #[])
    (commands : Array Config.Registration := #[]) : Config.Registry :=
  (((({} : Config.Registry).replace .compiled
                (FrameCommands.commands ++ Ex.commands)).replaceBindings
            .compiled (FrameCommands.bindings ++ Menu.bindings)).replaceBindings
        .config config).replace
    .config commands

/-- What a step of the frame command checks is handed: the active keymaps
`registry` makes for the test scheme from the loop's state, its plain
commands and those given their call, and the menu bar that ships with its
key equivalents filled from `registry`, as a host's are. -/
def frameKeys (registry : Config.Registry) : Loop.Keys TestScheme.scheme :=
  { maps := registry.activeMaps TestScheme.scheme
    command? := fun name =>
      match registry.find? name with
      | some { registration := { action := .plain run, .. }, .. } =>
        some fun _ => do
          run
          return none
      | some { registration := { action := .call run, .. }, .. } =>
        some fun call => do
          run call
          return none
      | _ => none
    menu := some (registry.menuOf Menu.standard) }

/-- A driver of the frame command checks over the initial state, with the
keys of `registry`; `none` if making the state was refused. With `held`
the scratch buffer holds a file, made up and never loaded, so that an edit
of it is an unsaved change. -/
def frameDriver (registry : Config.Registry := frameRegistry) (held : Bool := false) :
    Option TestDriver :=
  let start : TextM EditorState := do
    let state ← EditorState.initial ⟨640, 480⟩
    if held then
      return (state.attachFile ⟨0⟩ "/files/note.txt" { seconds := 0, nanoseconds := 0, size := 0 }
            .lf).2
    return state
  (Loop.Driver.over (frameKeys registry) driverJobs start editorModel).toOption

/-- The window's word that it is 640 by 480 at scale 1, in fullscreen or not. -/
def resizedTo (fullscreen : Bool) : Event :=
  .resize { width := 640, height := 480, scale := 1.0, fullscreen }

/-- What `driver`'s display model was asked of the window, and whether the
frame last said it is in fullscreen, after `events`; `none` without a
driver. -/
def framed (driver : Option TestDriver) (events : List Event) :
    Option (Array Display.FrameRequest × Bool) :=
  driver.map fun driver =>
    let fed := (fedTo driver events).1
    (fed.model.display.asked, fed.loop.state.frame.fullscreen)

end ModelTest
