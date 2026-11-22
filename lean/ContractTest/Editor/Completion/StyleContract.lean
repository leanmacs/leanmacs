import Editor.Completion.Style
import Editor.Completion.StyleContract
import Editor.Fuzzy
import Editor.Fuzzy.Real
import Editor.Program

/-!
# Contract tests: `Editor/Completion/StyleContract.lean`

The tests of `Editor/Completion/StyleContract.lean`: `styleFailures`, the
completion styles' contract over the library's matcher. The root module
`ContractTest` runs them; its module doc says what each shows.
-/

namespace ContractTest

open Editor

/-- The names of the completion styles' contract properties that do not hold
of the core's own style (`Completion.Style.unregistered`) over the real
fuzzy binding: the contract check of the style interface's real
implementation, beside `model-test`'s on the fuzzy model. -/
def styleFailures : IO (List String) := do
  let failed ←
    Completion.StyleContract.failures (Program.runM (port := fuzzyPort) Fuzzy.real)
        Completion.Style.unregistered
  return failed.map (s!"the core's own style over the real fuzzy binding: {·}")

end ContractTest
