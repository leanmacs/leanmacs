import Editor.Test.Models
import Editor.Watch.Contract
import Editor.Watch.Model

/-!
# Model tests: `Editor/Watch/Contract.lean`

The model tests of `Editor/Watch/Contract.lean`: `watchFailures`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The names of the watch port's contract properties that do not hold of
the watch model, each run from a model in which the property's interrupt
keys have arrived. -/
def watchFailures : IO (List String) := do
  let failed ←
    WatchContract.failures
        (fun property => pure (watched property.holds { arrived := property.arrived }).1)
        WatchContract.properties
  return failed.map (s!"the watch model: {·}")

end ModelTest
