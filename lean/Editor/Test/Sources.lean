import Editor.Command
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Completion
import Editor.Completion.Contract
import Editor.Loop
import Editor.State
import Editor.Test.Keys
import Editor.Test.Models
import Editor.Test.States
import Editor.Text
import Editor.Text.Model

/-!
# The test kit: Sources

The runner the completion sources' contract is checked on
(`Completion.Contract.Runner`, `Editor/Completion/Contract.lean`), over the
editor's models: `sourceRunner`. The core's tests of the contract run it
over the sources the core ships (`ModelTest.sourceContractChecks`), and a
package's tests run it over the sources the package ships, under the same
sentences (`sourceContract`, `answersSomething`, `sourceHolds`).

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import").
-/

namespace Editor.Test

open Editor

/-- The contract's runner on the editor's models (`Completion.Contract.Runner`):
the source asked with `text` from the focused view of `twoBuffers`, dispatched
with a loop told two ex names, two themes, two commands and one key binding, so the shipped
sources that ask for them answer some. `some` with what it answered and whether the editor
state and the texts the store holds were left as they were; `none` when it
was refused, or the fixture could not be made. -/
def sourceRunner : Completion.Contract.Runner := fun text source =>
  let fixture : EditorM EditorState := do
    return ← twoBuffers
  match fixture.runModel editorModel with
  | (.error _, _) => none
  | (.ok start, model) =>
    match start.focusedTarget? with
    | none => none
    | some target =>
      let registered : Loop.Registered :=
        { exNames := #["w", "q"], themeNames := #["default", "second"]
          commandNames := #["load-theme", "quit"]
          keyBindings := fun _ =>
            #[{ keys := keys "C-c m", command := "load-theme", desc := some "Load" }] }
      let asking : EditorM (Guarded (Array Completion.Candidate) × EditorState) :=
        (source.candidates { text, view := target.window.id }).dispatched registered start
      match asking.runModel model with
      | (.ok (.finished answer, after), left) =>
        some (answer, after == start && left.texts.contents == model.texts.contents)
      | _ => none

/-- The contract's properties over `source` on `sourceRunner`, each with
what must hold as a sentence: `the source <name>: <property>`. -/
def sourceContract (source : Completion.Source) : List (String × Bool) :=
  Completion.Contract.properties.map fun property =>
    (s!"the source {source.name}: {property.name}", property.holds sourceRunner source)

/-- Whether `source` answers something on `sourceRunner`'s fixture, asked
with no text. -/
def answersSomething (source : Completion.Source) : Bool :=
  (sourceRunner "" source).any (!·.1.isEmpty)

/-- What a package's tests hold of a source it ships: the contract's
properties over it (`sourceContract`), then that it answers something on
the fixture (`answersSomething`), each with what must hold as a
sentence. -/
def sourceHolds (source : Completion.Source) : List (String × Bool) :=
  sourceContract source ++
    [(s!"the source {source.name} answers something on the fixture", answersSomething source)]

end Editor.Test
