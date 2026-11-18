import Editor.Display
import Editor.Display.Recorder
import Editor.Ffi.Document
import Editor.Ffi.Snapshot
import Editor.Menu
import Editor.Scene
import Editor.Text
import Editor.Text.Real

/-!
# Contract tests: support: Displays

Display recorders over a table, and a scene with no views. Shared by several
test modules; it holds no checks of its own.
-/

namespace ContractTest

open Editor

/-- A display recorder that reads `table`: the display a command run over
that table is handed, as the headless host hands its loop one. -/
def recorderOf (table : Snapshots) : BaseIO DisplayRecorder :=
  DisplayRecorder.new { advance := 1, lineHeight := 1 } table.reader

/-- A recorder in `cells` over a table of its own, which holds a snapshot of
a document of each of `texts`: the recorder, the table, and the ids of the
snapshots, in the order of `texts`. -/
def recorderOver (cells : Display.Cells) (texts : Array String) :
    IO (DisplayRecorder × Snapshots × Array SnapshotId) := do
  let table ← Snapshots.new
  let snapshots ←
    texts.mapM fun text => do
        table.add (← (← Ffi.Document.new text).snapshot)
  return (← DisplayRecorder.new cells table.reader, table, snapshots)

/-- A scene with no views, for the recorder's checks. -/
def emptyScene : Scene :=
  { size := ⟨640, 480⟩, views := #[], focused := none, echo := "published", pending := ""
    preedit := some "ka" }

end ContractTest
