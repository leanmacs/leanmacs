import Editor.Clipboard
import Editor.Clipboard.Contract
import Editor.Clipboard.Model
import Editor.Program
import Editor.Test.Models
import ModelTest.Check

/-!
# Model tests: `Editor/Clipboard/Model.lean`

The model tests of `Editor/Clipboard/Model.lean`: `clipboardChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- A clipboard written for the test that breaks the contract: it accepts
every write and keeps none, so a read answers what it held before. -/
def droppingWrites : (request : ClipboardRequest) → ClipboardModel → request.Reply × ClipboardModel
  | .read, model => (.ok model.held, model)
  | .write _, model => (.ok (), model)

/-- The checks of the clipboard interface's model
(`Editor/Clipboard/Model.lean`): what only the model shows, a clipboard
that is not available and one that holds nothing, and the contract
(`Editor/Clipboard/Contract.lean`) seen to report a clipboard that breaks
it. -/
def clipboardChecks : List Check :=
  [{  name :=
        "a clipboard model that is not available refuses a read and a write, each with unavailable, and holds what it held: the refused write replaces nothing, and once it is available again a read answers the text from before"
      run :=
        pure <|
          let away : ClipboardModel := { held := some "kept", available := false }
          let (read, afterRead) := clipped Clipboard.read away
          let (written, afterWrite) := clipped (Clipboard.write "lost") away
          let (back, _) := clipped Clipboard.read { afterWrite with available := true }
          replied read == .inl .unavailable && afterRead == away &&
            replied written == .inl .unavailable &&
            afterWrite == away &&
            replied back == .inr (some "kept") },
    { name :=
        "a clipboard model that holds nothing answers a read with no text, which is another answer than the empty text, and a read changes nothing"
      run :=
        pure <|
          let (read, after) := clipped Clipboard.read
          let (empty, _) :=
            clipped do
              discard <| Clipboard.write ""
              Clipboard.read
          replied read == .inr none && after == {} && replied empty == .inr (some "") &&
            replied read != replied empty },
    { name :=
        "the clipboard contract reports a clipboard that drops every write: its first property, that a text written is the text read, does not hold of it, and every property holds of the model"
      run := do
        let dropped ←
          ClipboardContract.failures
              (fun property =>
                pure (Program.run (port := clipboardPort) droppingWrites property.holds {}).1)
              ClipboardContract.properties
        let held ←
          ClipboardContract.failures (fun property => pure (clipped property.holds).1)
              ClipboardContract.properties
        return (ClipboardContract.properties.head?.map (·.name)).any dropped.contains &&
            held.isEmpty &&
            !ClipboardContract.properties.isEmpty }]

end ModelTest
