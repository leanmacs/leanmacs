import ContractTest.Check
import ContractTest.Support.Displays
import Editor.Clipboard
import Editor.Clipboard.InProcess
import Editor.Clipboard.Real
import Editor.Command
import Editor.Command.Real
import Editor.Display
import Editor.Display.Recorder
import Editor.Ffi.Clipboard
import Editor.Ffi.Snapshot
import Editor.Program
import Editor.SyntaxTree
import Editor.Text
import Editor.Text.Real
import Editor.Watch

/-!
# Contract tests: `Editor/Clipboard/Real.lean`

The tests of `Editor/Clipboard/Real.lean`: `clipboardChecks`, what only the real
clipboard shows. The root module `ContractTest` runs them; its module doc says
what each shows.
-/

namespace ContractTest

open Editor

/-- A command that reads the clipboard, writes `text` to it and reads it
again: the three replies. -/
def clipboardRound (text : String) :
    EditorM
      (Except ClipboardError (Option String) ×
        Except ClipboardError Unit × Except ClipboardError (Option String)) :=
  do
  let before ← Clipboard.read
  let written ← Clipboard.write text
  return (before, written, ← Clipboard.read)

/-- The reason the library's failing clipboard is made with in
`clipboardChecks`: not ASCII, so a reason cut or mis-decoded at the glue
shows. -/
def failingReason : String :=
  "pas de presse-papiers: é"

/-- What the contract cannot show of the clipboard a host with no window
keeps, and where a command's clipboard requests go when it is run against
the library. -/
def clipboardChecks : List Check :=
  [{  name := "a new in-process clipboard holds no text, and holds what was written to it last"
      run := do
        let clipboard ← Clipboard.InProcess.new
        let before ← clipboard.held?
        let first ← clipboard.handle (.write "first")
        let second ← clipboard.handle (.write "second")
        return before.isNone && first matches .ok () && second matches .ok () &&
            (← clipboard.held?) == some "second" },
    { name :=
        "a command run against the library with no clipboard handed in is answered unavailable for a read and for a write"
      run := do
        let table ← Snapshots.new
        let (result, _) ← (clipboardRound "x").runReal (.over table) (← recorderOf table).handle
        return match result with
          | .ok (.error .unavailable, .error .unavailable, .error .unavailable) => true
          | _ => false },
    { name :=
        "a command run against the library with the in-process clipboard handed in reads what it wrote, and a later command reads it too"
      run := do
        let table ← Snapshots.new
        let display := (← recorderOf table).handle
        let clipboard ← Clipboard.InProcess.new
        let (first, texts) ←
          (clipboardRound "kept").runReal (.over table) display (clipboard := clipboard.handle)
        let (second, _) ←
          EditorM.runReal (Clipboard.lift Clipboard.read) texts display (clipboard :=
              clipboard.handle)
        return (match first with
            | .ok (.ok none, .ok (), .ok (some "kept")) => true
            | _ => false) &&
            match second with
            | .ok (.ok (some "kept")) => true
            | _ => false },
    { name :=
        "a read and a write of the library's failing clipboard each cross the glue as a failure with the library's reason whole"
      run := do
        let clipboard ← Ffi.Clipboard.failing failingReason
        let read ← clipboard.read
        let written ← clipboard.write "lost"
        return (match read with
            | .error reason => reason == failingReason
            | .ok _ => false) &&
            written == some failingReason },
    { name :=
        "the real clipboard binding over the library's failing clipboard answers a read and a write unavailable"
      run := do
        let real ← Clipboard.Real.failing failingReason
        let read ← real.handle .read
        let written ← real.handle (.write "lost")
        return read matches .error .unavailable && written matches .error .unavailable }]

end ContractTest
