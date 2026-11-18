import Editor.Completion.StyleContract
import Editor.Completion.Styles
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
of the fuzzy style or of the path style over the real fuzzy binding: the
contract check of the style interface's real implementation, beside
`model-test`'s on the fuzzy model. -/
def styleFailures : IO (List String) := do
  let failed ←
    Completion.StyleContract.failures (Program.runM (port := fuzzyPort) Fuzzy.real)
        Completion.Styles.fuzzy
  let pathFailed ←
    Completion.StyleContract.failures (Program.runM (port := fuzzyPort) Fuzzy.real)
        Completion.Styles.path
  return failed.map (s!"the fuzzy style over the real fuzzy binding: {·}") ++
      pathFailed.map (s!"the path style over the real fuzzy binding: {·}")

end ContractTest
