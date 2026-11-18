import ContractTest.Check
import ContractTest.Support.Displays
import Editor.Clipboard
import Editor.Command
import Editor.Command.Real
import Editor.Display.Recorder
import Editor.Ffi.Snapshot
import Editor.Fuzzy
import Editor.Program
import Editor.SyntaxTree
import Editor.Text
import Editor.Text.Real
import Editor.Watch

/-!
# Contract tests: `Editor/Fuzzy/Real.lean`

The tests of `Editor/Fuzzy/Real.lean`: `fuzzyChecks`, what only the real fuzzy
binding shows. The root module `ContractTest` runs them; its module doc says
what each shows.
-/

namespace ContractTest

open Editor

/-- Where a command's fuzzy requests go when it is run against the
library: to the real binding, with nothing handed in. The case is the one
the contract fixes whatever the library's scores: of `wq`, `edit` and `w`
the pattern `w` matches the first and the third, and the third is the
pattern. -/
def fuzzyChecks : List Check :=
  [{  name :=
        "a command run against the library that asks for a fuzzy ranking is answered by the library's matcher: the candidate that is the pattern first, then the other that matches"
      run := do
        let table ← Snapshots.new
        let command : EditorM (Array Nat) := Fuzzy.rank "w" #["wq", "edit", "w"]
        let (result, _) ← command.runReal (.over table) (← recorderOf table).handle
        return match result with
          | .ok ranked => ranked == #[2, 0]
          | .error _ => false }]

end ContractTest
