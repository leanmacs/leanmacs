import ContractTest.Support.Displays
import Editor.Display
import Editor.Display.Contract
import Editor.Display.Real
import Editor.Display.Recorder
import Editor.Face
import Editor.Ffi.Display
import Editor.Ffi.Document
import Editor.Ffi.Snapshot
import Editor.Ffi.Window
import Editor.Text
import Editor.Text.Real

/-!
# Contract tests: `Editor/Display/Contract.lean`

The tests of `Editor/Display/Contract.lean`: `displayFailures` and
`recorderFailures`, the display interface's contract against the recorder, at
the cell sizes `displayCells`. The root module `ContractTest` runs them; its
module doc says what each shows.
-/

namespace ContractTest

open Editor

/-- The cell sizes the display contract is run at, against the real binding
and against the recorder: one pixel by one, and eight by sixteen, as
`model-test` runs it against the model. -/
def displayCells : List Display.Cells :=
  [{ advance := 1, lineHeight := 1 }, { advance := 8, lineHeight := 16 }]

/-- Runs `property` against the real display binding over a display of
`cells`: each of its texts is a document and a snapshot of the library,
entered in a new table of snapshots, which the display reads. The binding
has a theme of no definition to send, so every face is layout's base and a
cell is the size the contract was given. -/
def runOnRealDisplay (cells : Display.Cells) (property : DisplayContract.Property) :
    IO (Except DisplayError Bool) := do
  let table ← Snapshots.new
  let ids ←
    property.texts.mapM fun text => do
        let document ← Ffi.Document.new text
        table.add (← document.snapshot)
  let display ← Ffi.Display.newCells cells.advance.toUInt64 cells.lineHeight.toUInt64
  (property.holds ids).runReal (← RealDisplay.over display table.reader #[])

/-- The names of the display contract's properties that do not hold of the
real binding, at each of `displayCells`. -/
def displayFailures : IO (List String) :=
  displayCells.flatMapM fun cells => do
    let failed ←
      DisplayContract.failures (runOnRealDisplay cells) (DisplayContract.properties cells)
    return failed.map
        (s!"the real display binding in cells of {cells.advance} by {cells.lineHeight}: {·}")

/-- Runs a property of the display interface's contract against a recorder
in `cells` over real snapshots of the property's texts. -/
def runOnRecorder (cells : Display.Cells) (property : DisplayContract.Property) :
    IO (Except DisplayError Bool) := do
  let (recorder, _, snapshots) ← recorderOver cells property.texts
  (property.holds snapshots).runWith recorder.handle

/-- The names of the display interface's contract properties that do not
hold of the recorder over real snapshots, at each of `displayCells`. -/
def recorderFailures : IO (List String) :=
  displayCells.flatMapM fun cells => do
    let failed ← DisplayContract.failures (runOnRecorder cells) (DisplayContract.properties cells)
    return failed.map
        (s!"the display recorder in cells of {cells.advance} by {cells.lineHeight}: {·}")

end ContractTest
