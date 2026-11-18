import Editor.Text
import Editor.Text.Contract
import Editor.Text.Model
import Editor.UndoTree.Cases
import ModelTest.Editor.Command.Append

/-!
# Model tests: `Editor/Text/Contract.lean`

The model tests of `Editor/Text/Contract.lean`: `textProperties`, `textFailures`
and `adoptFailures`. The root module `ModelTest` runs them; its module doc says
what each shows.
-/

namespace ModelTest

open Editor

/-- The properties run against the text model: the text port's contract,
those of the commands, and the cases of the undo tree, which is plain Lean
over the port. -/
def textProperties : List TextContract.Property :=
  TextContract.properties ++ commandProperties ++ UndoTreeCases.cases

/-- The names of the `textProperties` that do not hold of the text model, each
run from a model with no texts. -/
def textFailures : IO (List String) := do
  let failed ← TextContract.failures (fun command => pure (command.runModel {}).1) textProperties
  return failed.map (s!"the text model: {·}")

/-- The names of the properties of taking a job's snapshot into the store
that do not hold of the text model. Each is run from a model with no texts
that was handed, as what a job held, the strings the property names. -/
def adoptFailures : IO (List String) := do
  let failed ←
    TextContract.adoptFailures
        (fun arrived command =>
          pure
            (command.runModel
                { arrived := arrived.map fun (id, text) => (id, { contents := text }) }).1)
        TextContract.adoptProperties
  return failed.map (s!"the text model: {·}")

end ModelTest
