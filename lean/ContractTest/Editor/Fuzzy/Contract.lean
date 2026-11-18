import Editor.Fuzzy
import Editor.Fuzzy.Contract
import Editor.Fuzzy.Real
import Editor.Program

/-!
# Contract tests: `Editor/Fuzzy/Contract.lean`

The tests of `Editor/Fuzzy/Contract.lean`: `fuzzyFailures`, the fuzzy matching
interface's contract over the library's matcher. The root module `ContractTest`
runs them; its module doc says what each shows.
-/

namespace ContractTest

open Editor

/-- The names of the fuzzy matching interface's contract properties that do
not hold of its real binding. The binding keeps nothing, so each property
is run against the same handler. -/
def fuzzyFailures : IO (List String) := do
  let failed ←
    FuzzyContract.failures
        (fun property => Program.runM (port := fuzzyPort) Fuzzy.real property.holds)
        FuzzyContract.properties
  return failed.map (s!"the real fuzzy binding: {·}")

end ContractTest
