import Editor.Api.Cases
import Editor.Command
import Editor.Command.Model
import Editor.Test.Models
import Editor.Text

/-!
# Model tests: `Editor/Api/Cases.lean`

The model tests of `Editor/Api/Cases.lean`: `apiCaseFailures`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The names of the cases of the editor API (`Editor/Api/Cases.lean`) that
do not hold of the editor's models, each played from models with no
text. -/
def apiCaseFailures : IO (List String) := do
  let failed ← ApiCases.failures (fun play => pure (play.runModel editorModel).1) ApiCases.cases
  return failed.map (s!"the editor's models: {·}")

end ModelTest
