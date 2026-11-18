import ContractTest.Support.Displays
import Editor.Api.Cases
import Editor.Clipboard
import Editor.Command
import Editor.Command.Real
import Editor.Display.Recorder
import Editor.Ffi.Document
import Editor.Ffi.Snapshot
import Editor.SyntaxTree
import Editor.Text
import Editor.Text.Real
import Editor.Watch

/-!
# Contract tests: `Editor/Api/Cases.lean`

The tests of `Editor/Api/Cases.lean`: `apiFailures`, the cases of the editor API
against the real text binding. The root module `ContractTest` runs them; its
module doc says what each shows.
-/

namespace ContractTest

open Editor

/-- What must hold of the library's objects once the cases of the editor API
have run. -/
def apiLeakName : String :=
  "the cases of the editor API leave nothing behind: each table is dropped with its case, and the library holds the documents and the snapshots it held before"

/-- The names of the cases of the editor API (`Editor/Api/Cases.lean`) that
do not hold of the real text binding, each played from a table with no
texts, with a recorder over that table as the display and nothing watched.
`apiLeakName` is among them if the library's counts are not then what they
were. -/
def apiFailures : IO (List String) := do
  let before := (← Ffi.Document.live, ← Ffi.Snapshot.live)
  let failed ←
    ApiCases.failures
        (fun play => do
          let table ← Snapshots.new
          return (← play.runReal (.over table) (← recorderOf table).handle).1)
        ApiCases.cases
  let after := (← Ffi.Document.live, ← Ffi.Snapshot.live)
  return failed.map (s!"the real text binding: {·}") ++
      if after == before then []
      else
        [s!"{apiLeakName} ({before.1} documents and {before.2} snapshots before, {after.1} and {after.2} after)"]

end ContractTest
