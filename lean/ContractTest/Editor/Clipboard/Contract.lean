import Editor.Clipboard
import Editor.Clipboard.Contract
import Editor.Clipboard.InProcess
import Editor.Clipboard.Real
import Editor.Program

/-!
# Contract tests: `Editor/Clipboard/Contract.lean`

The tests of `Editor/Clipboard/Contract.lean`: `clipboardFailures` and
`realClipboardFailures`, the clipboard interface's contract. The root module
`ContractTest` runs them; its module doc says what each shows.
-/

namespace ContractTest

open Editor

/-- The names of the clipboard interface's contract properties that do not
hold of the clipboard a host with no window keeps: one clipboard for the
whole list, so each property finds what the one before it left. -/
def clipboardFailures : IO (List String) := do
  let clipboard ← Clipboard.InProcess.new
  let failed ←
    ClipboardContract.failures
        (fun property => Program.runM (port := clipboardPort) clipboard.handle property.holds)
        ClipboardContract.properties
  return failed.map (s!"the in-process clipboard: {·}")

/-- The names of the clipboard interface's contract properties that do not
hold of its real binding, over the library's memory clipboard: one
clipboard for the whole list. The desktop's clipboard is never reached. -/
def realClipboardFailures : IO (List String) := do
  let clipboard ← Clipboard.Real.memory
  let failed ←
    ClipboardContract.failures
        (fun property => Program.runM (port := clipboardPort) clipboard.handle property.holds)
        ClipboardContract.properties
  return failed.map (s!"the real clipboard binding over the library's memory clipboard: {·}")

end ContractTest
