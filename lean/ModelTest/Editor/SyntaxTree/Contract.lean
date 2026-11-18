import Editor.SyntaxTree.Model
import ModelTest.Support.Models

/-!
# Model tests: `Editor/SyntaxTree/Contract.lean`

The model tests of `Editor/SyntaxTree/Contract.lean`: `syntaxTreeFailures`. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The names of the syntax tree interface's contract properties that do
not hold of its model. -/
def syntaxTreeFailures : IO (List String) := do
  let failed ← syntaxTreeBroken SyntaxTreeModel.handle
  return failed.map (s!"the syntax tree model: {·}")

end ModelTest
