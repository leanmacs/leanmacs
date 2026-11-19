import Editor.SyntaxTree.Model
import Editor.Test.Models

/-!
# Model tests: `Editor/SyntaxTree/Contract.lean`

The model tests of `Editor/SyntaxTree/Contract.lean`: `syntaxTreeFailures`. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The names of the syntax tree interface's contract properties that do
not hold of its model. -/
def syntaxTreeFailures : IO (List String) := do
  let failed ← syntaxTreeBroken SyntaxTreeModel.handle
  return failed.map (s!"the syntax tree model: {·}")

end ModelTest
