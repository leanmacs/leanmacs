import Editor.Api
import Editor.Fold
import Editor.Folds
import Editor.InputScheme.Test
import Editor.Loop.Driver
import Editor.Package
import Editor.Test.Driver
import Editor.Test.Hosted
import Editor.Test.Models
import Editor.Test.Prompts
import FoldCommands.Compiled
import FoldCommandsTest.Check

/-!
# The tests of `FoldCommands.lean` and `FoldCommands/Compiled.lean`

The tests of the package that registers the fold commands:
`foldCommandsChecks`. The test driver `FoldCommandsTest/Model.lean` runs
them; its module doc says what each shows.
-/

namespace FoldCommandsTest

open Editor
open Editor.Test

/-- A package of the checks' own: `fill` makes a buffer of three rows whose
middle row is a folded range keyed `middle`, and shows it with the cursor
on that row. -/
def fillPackage : Package :=
  { name := "fold-commands-checks"
    setup := do
      commandWith "fill" fun call => do
          let .ok id ← createBuffer "sections" "a\nb\nc\n" | return
          discard <|
              id.setFolds
                #[{ start := 2, stop := 3, key := "middle", text := "[b]", folded := true }]
          discard <| call.target.window.id.show id
          if let .ok selection← call.target.window.id.selection then
            discard <|
                call.target.window.id.select
                  { selection with
                    ranges := #[⟨2, 2⟩], primary := 0 } }

/-- A driver over the packages `fold-commands` and `fillPackage`, installed
as a host installs them, with the registry's active keymaps; `none` if
making the state was refused. -/
def foldCommandsDriver : Option TestDriver :=
  let registry := hostedRegistry #[FoldCommands.package, fillPackage]
  let keys := hostedKeys registry
  (Loop.Driver.over { keys with maps := registry.activeMaps TestScheme.scheme } (fun _ => none)
      (EditorState.initial ⟨640, 480⟩) editorModel).toOption

/-- The checks of the package `fold-commands` (`FoldCommands.lean`,
`FoldCommands/Compiled.lean`). -/
def foldCommandsChecks : List Check :=
  [{  name :=
        "the package fold-commands registers fold-toggle and the mode folds, under the core's names, and nothing else"
      run :=
        let registered := FoldCommands.package.registered
        pure
          (FoldCommands.package.name == "fold-commands" &&
            registered.commands.map (·.name) == #[Folds.toggleName] &&
            registered.jobs.isEmpty &&
            registered.modes.map (·.name) == #[Folds.modeName] &&
            registered.modes.map (·.roles) == #[Folds.mode.roles] &&
            registered.bindings.isEmpty) },
    { name := "on a host with the package, toggle's key on a declared folded range unfolds it"
      run :=
        pure <|
          match foldCommandsDriver with
          | none => false
          | some driver =>
            let filled := hostedRan driver { command := "fill" }
            let pressed := (fedTo filled (rolePresses Role.toggle)).1
            let folded (driver : TestDriver) : Option Bool :=
              (driver.loop.state.target? ⟨0⟩).bind fun target =>
                target.buffer.folds[0]?.map (·.folded)
            folded filled == some true && folded pressed == some false }]

end FoldCommandsTest
