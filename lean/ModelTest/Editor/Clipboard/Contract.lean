import Editor.Clipboard.Contract
import Editor.Clipboard.Model
import Editor.Test.Models

/-!
# Model tests: `Editor/Clipboard/Contract.lean`

The model tests of `Editor/Clipboard/Contract.lean`: `clipboardFailures`. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The names of the clipboard interface's contract properties that do not
hold of the clipboard model, each run from a model that is available and
holds nothing. -/
def clipboardFailures : IO (List String) := do
  let failed ←
    ClipboardContract.failures (fun property => pure (clipped property.holds).1)
        ClipboardContract.properties
  return failed.map (s!"the clipboard model: {·}")

end ModelTest
