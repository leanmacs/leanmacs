import Editor.Fuzzy.Model
import Editor.Test.Models

/-!
# Model tests: `Editor/Fuzzy/Contract.lean`

The model tests of `Editor/Fuzzy/Contract.lean`: `fuzzyFailures`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The names of the fuzzy matching interface's contract properties that do
not hold of the fuzzy model. -/
def fuzzyFailures : IO (List String) := do
  let failed ← fuzzyBroken FuzzyModel.handle
  return failed.map (s!"the fuzzy model: {·}")

end ModelTest
