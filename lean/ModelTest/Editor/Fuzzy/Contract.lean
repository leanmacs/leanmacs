import Editor.Fuzzy.Model
import ModelTest.Support.Models

/-!
# Model tests: `Editor/Fuzzy/Contract.lean`

The model tests of `Editor/Fuzzy/Contract.lean`: `fuzzyFailures`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The names of the fuzzy matching interface's contract properties that do
not hold of the fuzzy model. -/
def fuzzyFailures : IO (List String) := do
  let failed ← fuzzyBroken FuzzyModel.handle
  return failed.map (s!"the fuzzy model: {·}")

end ModelTest
