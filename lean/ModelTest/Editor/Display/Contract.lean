import Editor.Display
import Editor.Display.Contract
import Editor.Display.Model
import Editor.Text
import ModelTest.Support.Display

/-!
# Model tests: `Editor/Display/Contract.lean`

The model tests of `Editor/Display/Contract.lean`: `displayCells`,
`runOnDisplayModel` and `displayFailures`. The root module `ModelTest` runs
them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The cell sizes the display interface's contract is run at against the
model: one pixel each way, and 8 by 16. -/
def displayCells : List Display.Cells :=
  [{ advance := 1, lineHeight := 1 }, { advance := 8, lineHeight := 16 }]

/-- Runs a property of the display interface's contract against a display
model in `cells` that holds the property's texts, as the snapshots 0, 1, 2
and so on. -/
def runOnDisplayModel (cells : Display.Cells) (property : DisplayContract.Property) :
    IO (Except DisplayError Bool) :=
  let model := displayOver property.texts.toList cells
  pure ((property.holds (model.texts.map (·.1))).runModel model).1

/-- The names of the display interface's contract properties that do not
hold of the display model, at each of `displayCells`. -/
def displayFailures : IO (List String) := do
  let failed ←
    displayCells.flatMapM fun cells => do
        let failed ←
          DisplayContract.failures (runOnDisplayModel cells) (DisplayContract.properties cells)
        return failed.map
            (s!"the display model in cells of {cells.advance} by {cells.lineHeight}: {·}")
  return failed

end ModelTest
