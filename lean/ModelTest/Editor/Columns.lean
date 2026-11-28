import Editor.Api
import Editor.Columns
import Editor.Command
import Editor.Command.Call
import Editor.Display
import Editor.Display.Model
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Loop
import Editor.Loop.Driver
import Editor.Scene
import Editor.State
import Editor.Test.Driver
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Models
import ModelTest.Check

/-!
# Model tests: `Editor/Columns.lean`

The model tests of `Editor/Columns.lean`: `columnsChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- A stop at `offset`, `x` points in. -/
def columnStop (offset x : Nat) : AlignStop :=
  { offset, x }

/-- A table of two rows of two cells, the first row's second cell in the
face `key`. -/
def columnTable : Array (Array (String × Option FaceName)) :=
  #[#[("ab", none), ("x", some ⟨"key"⟩)], #[("abcd", none), ("y", none)]]

/-- The bindings of the columns loop check: `C-c t` runs `table`, which
writes `columnTable`, measured in columns with a gap of 16, into a new
read-only buffer `table` with its spans and stops, and shows it in the
window. -/
def columnCommands : List (String × Dispatched) :=
  [("table", fun call => do
      let (text, stops, spans) ← Columns.measured columnTable 16
      let .ok table ← createBuffer "table" text | return none
      discard <| table.setSpans spans
      discard <| table.setStops stops
      discard <| table.setReadOnly true
      discard <| call.target.window.id.show table
      return none)]

/-- A driver whose window shows an empty buffer, with `columnCommands` on
`C-c t`; `none` if making the state was refused. -/
def columnDriver : Option TestDriver :=
  let keys := dispatchKeys [("C-c t", invoke "table")] columnCommands
  (Loop.Driver.over keys (fun _ => none) (EditorState.initial ⟨640, 480⟩) editorModel).toOption

/-- The checks of the column arithmetic (`Editor/Columns.lean`), pure and on
the display model, and of a generated buffer's stops reaching its view. -/
def columnsChecks : List Check :=
  let cells : Display.Cells := { advance := 8, lineHeight := 16 }
  [{  name :=
        "a column starts past the widest cell of every column before it and the gap, column 0 at 0, a ragged row's missing cells none wide"
      run := pure (Columns.starts #[#[3, 5], #[7], #[1, 2, 4]] 2 == #[0, 9, 16]) },
    { name :=
        "the cells are joined by the separator and the rows by line feeds, with a stop at the first byte of every cell after a row's first, at its column's x, cells of several bytes counted in bytes"
      run :=
        pure <|
          Columns.lay #[#["é", "x"], #["ab", "😀", "z"]] #[0, 10, 20] ==
            ("é x\nab 😀 z", #[columnStop 3 10, columnStop 8 10, columnStop 13 20]) },
    { name :=
        "stopsAt puts a stop at each row's later cells' offsets, at their columns' x, the first cell of a row none, and a column with no x none"
      run :=
        pure <|
          Columns.stopsAt #[#[0, 4, 9], #[12, 15]] #[0, 30] ==
            #[columnStop 4 30, columnStop 15 30] },
    { name := "a column `starts` has no x for gives its cells no stop"
      run := pure ((Columns.lay #[#["a", "b", "c"]] #[0, 10]).2 == #[columnStop 2 10]) },
    { name :=
        "measured on the display model in cells of 8, the second column is past the widest first cell and the gap, and a cell in a face is a decoration over it"
      run :=
        pure <|
          match (Columns.measured columnTable 16).runModel { cells } with
          | (.ok (text, stops, decorations), _) =>
            -- `abcd` is 32 wide: the second column is at 48.
            text == "ab x\nabcd y" && stops == #[columnStop 3 48, columnStop 10 48] &&
              decorations == #[{ start := 3, stop := 4, face := ⟨"key"⟩ }]
          | _ => false },
    { name := "the gap is at least the separator's measured width"
      run :=
        pure <|
          match (Columns.measured columnTable 0 (separator := "  ")).runModel { cells } with
          | (.ok (_, stops, _), _) => stops.map (·.x) == #[48, 48]
          | _ => false },
    { name :=
        "a command that writes a read-only buffer with a measured table's text, spans and stops shows a view whose stops and decorations are those"
      run :=
        pure <|
          match columnDriver with
          | none => false
          | some driver =>
            let ran := (fedTo driver (presses "C-c t")).1
            let view :=
              ran.model.display.scenes.back?.bind fun scene => scene.views.find? (·.id == ⟨0⟩)
            -- The editor model's display lays out in cells of 1: the
            -- widest first cell, `abcd`, is 4 wide, and the gap 16.
            view.map (·.stops) == some #[columnStop 3 20, columnStop 10 20] &&
              view.map (·.decorations) == some #[{ start := 3, stop := 4, face := ⟨"key"⟩ }] }]

end ModelTest
