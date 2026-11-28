import Editor.Markdown.Cases
import Editor.SyntaxTree
import Editor.SyntaxTree.Model
import ModelTest.Check
import ModelTest.Support.Markdown

/-!
# Model tests: `Editor/Markdown/Cases.lean`

The model tests of `Editor/Markdown/Cases.lean`: `markdownCaseChecks`. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Markdown

/-- The checks of the Markdown fixtures (`Editor/Markdown/Cases.lean`): each
layers file decodes, encoding and decoding round-trip, and the syntax tree
model with the canned answers answers each fixture its layers. -/
def markdownCaseChecks : List Check :=
  let model : SyntaxTreeModel := { once := Support.Markdown.canned }
  Support.Markdown.files.toList.map fun (fixture, layersFile) =>
    { name :=
        s!"tests/markdown/{fixture.name}.layers.json decodes to layers that encode and decode to themselves, and the model with the canned answers answers its text those layers"
      run :=
        pure <|
          match Cases.decode layersFile with
          | .error _ => false
          | .ok layers =>
            !layers.isEmpty && (Cases.decode (Cases.encode layers)).toOption == some layers &&
              (SyntaxTreeM.runModel (Cases.holds fixture) model).1 matches .ok true }

end ModelTest
