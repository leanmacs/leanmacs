import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Config.Owner
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.DisplayRules
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Keymap
import Editor.Layout
import Editor.Loop
import Editor.Menu
import Editor.Mode
import Editor.ModeLine
import Editor.Process.Environment
import Editor.Program
import Editor.ProjectMode
import Editor.Role
import Editor.Scene
import Editor.State
import Editor.State.Request
import Editor.TabBar
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Test.Modes
import Editor.Test.States
import Editor.Text
import Editor.Workspace

/-!
# Model tests: support: Modes

Mode fixtures: registries of modes and their keys, and a buffer entering a mode.
Shared by several test modules under `ModelTest/Editor/`; it holds no checks of
its own.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- A mode called `name` that fills each of `roles` with a command named
after the mode and the role, and derives from `parent`, if given. -/
def filling (name : String) (roles : List Role) (parent : Option String := none) : Mode :=
  { name, parent, roles := roles.map fun role => (role, s!"{name}-{role.name}") }

/-- `twoBuffers` with the major mode `major` set on buffer 0 and the minor
modes `minors` added to it, in order. -/
def withModes (major : String) (minors : List String) : TextM EditorState := do
  let state := (← twoBuffers).setMajorMode ⟨0⟩ major |>.2
  return minors.foldl (fun state minor => (state.addMinorMode ⟨0⟩ minor).2) state

/-- The registry of the mode registry checks: a global binding of the keys
of `quit` and of `next-item`, two minor modes and a major mode that fill
roles over one another, and a derived mode whose parent derives from a
root. -/
def modeRegistry : Config.Registry :=
  (({} : Config.Registry).replaceBindings .compiled
        #[.ofKeys (roleKeys Role.quit) "global-quit",
          .ofKeys (roleKeys Role.nextItem) "global-next"]).replaceModes
    .compiled
    #[filling "m1" [Role.nextItem, Role.previousItem], filling "m2" [Role.nextItem],
      filling "major" [Role.nextItem, Role.previousItem, Role.activate],
      filling "root" [Role.toggle, Role.mark],
      filling "base" [Role.refresh, Role.mark] (some "root"),
      filling "child" [Role.mark] (some "base")]

/-- A mode called `name` whose on-enter action makes a text naming the mode
and the view it was given, and which derives from `parent`, if given. -/
def entering (name : String) (parent : Option String := none) : Mode :=
  { name, parent, onEnter := fun view => makes s!"{name} in {view.index}" }

/-- The registry of the on-enter checks: `listing` and `other`, and `child`,
which derives from `base`, which derives from `root`. -/
def enterRegistry : Config.Registry :=
  ({} : Config.Registry).replaceModes .compiled
    #[entering "listing", entering "other", entering "root", entering "base" (some "root"),
      entering "child" (some "base")]

/-- The command `enter-buffer` of the on-enter checks: it asks for the mode
named by its second argument to be the major mode of the buffer its first
argument numbers, by the request (`BufferId.setMajorMode`), and says a
refusal in the echo area. -/
def enterBuffer : Dispatched := fun call => do
  let [.nat buffer, .str name] := call.arguments | throw .badPosition
  if let .error refusal← (⟨buffer⟩ : BufferId).setMajorMode name then
    EditorState.ask (.message (modeRefusalText refusal))
  return none

/-- What a step of the on-enter checks is handed: the commands `enter`,
`enter-fail` and `enter-buffer`, and what `registry` says of its modes. -/
def enterKeys (registry : Config.Registry) : Loop.Keys TestScheme.scheme :=
  { command? := fun name =>
      ([("enter", enter), ("enter-fail", enter true), ("enter-buffer", enterBuffer)].find?
            (·.1 == name)).map
        (·.2)
    registered := registry.registered }

/-- The indents source of the model's test mode: an object and an array
indent what they hold, and their closing brackets lead out. -/
def jsonIndents : String :=
  "(object) @indent.begin\n(array) @indent.begin\n\"}\" @indent.branch\n\"]\" @indent.branch"

end ModelTest
