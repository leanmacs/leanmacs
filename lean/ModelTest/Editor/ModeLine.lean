import Editor.ModeLine
import Editor.Scene
import Editor.State
import Editor.Text
import ModelTest.Check
import ModelTest.Support.Config

/-!
# Model tests: `Editor/ModeLine.lean`

The model tests of `Editor/ModeLine.lean`: `modeLineChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The texts of `fields`, each with its face's name. -/
def textsAndFaces (fields : Array StatusField) : Array (String × String) :=
  fields.map fun field => (field.text, field.face.name)

/-- The checks of the mode line (`Editor/ModeLine.lean`): the shipped
segments' fields, in the order a listing gives, for a selected and an
unselected window. -/
def modeLineChecks : List Check :=
  let secondary (text : String) : StatusField :=
    { text, face := ⟨"mode-line.secondary"⟩, side := .right, padding := 4 }
  let positionOf (row lines : Nat) : Array String :=
    let fields :=
      ModeLine.standard.fields
        { loopContext with
          cursor := some ⟨row, 0⟩, lines }
    (fields.filter (·.side == .right)).map (·.text) |>.toList.getLast?.toArray
  [{  name :=
        "the shipped mode line of a selected window on a modified file in normal state is the badge, the name, the mark and the directory on the left, and the mode, line:col and position on the right"
      run :=
        pure
          (ModeLine.standard.fields loopContext ==
            #[{ text := "NORMAL", face := ⟨"mode-line.state.normal"⟩, padding := 8 },
              { text := "Loop.lean", face := ⟨"mode-line.buffer"⟩, padding := 4 },
              { text := "●", face := ⟨"mode-line.modified"⟩, padding := 4 },
              { text := "lean/Editor", face := ⟨"mode-line.secondary"⟩, padding := 4 },
              secondary "lean", secondary "959:5", secondary "41%"]) },
    { name :=
        "an unselected window on the same buffer has no badge, and every field in mode-line.inactive with the same texts, sides and paddings"
      run :=
        let selected := ModeLine.standard.fields loopContext
        let unselected := ModeLine.standard.fields (loopContext (selected := false))
        pure
          (unselected == (selected.extract 1).map ({ · with face := ModeLine.inactiveFace }) &&
            ModeLine.inactiveFace == ⟨"mode-line.inactive"⟩ &&
            ModeLine.activeFace == ⟨"mode-line.active"⟩) },
    { name :=
        "a segment with nothing to say gives no field: no directory with no file or a bare name, no mode with none, no line:col or position with no cursor, no mark unmodified"
      run :=
        let texts (context : ModeLine.Context) := (ModeLine.standard.fields context).map (·.text)
        let bare := loopContext (loopLean (path := "Loop.lean"))
        let dotted := loopContext (loopLean (path := "./Loop.lean"))
        let noFile := loopContext { loopLean with file := none }
        let noMode := loopContext { loopLean with major := none }
        let noCursor := { loopContext with cursor := none }
        let unmodified := loopContext (loopLean (modified := false))
        pure
          (texts bare == #["NORMAL", "Loop.lean", "●", "lean", "959:5", "41%"] &&
            texts dotted == #["NORMAL", "Loop.lean", "●", "lean", "959:5", "41%"] &&
            texts noFile == #["NORMAL", "Loop.lean", "●", "lean", "959:5", "41%"] &&
            texts noMode == #["NORMAL", "Loop.lean", "●", "lean/Editor", "959:5", "41%"] &&
            texts noCursor == #["NORMAL", "Loop.lean", "●", "lean/Editor", "lean"] &&
            texts unmodified == #["NORMAL", "Loop.lean", "lean/Editor", "lean", "959:5", "41%"]) },
    { name :=
        "the position is All in a buffer of one row, Top on the first row, Bot on the last or past it, and otherwise the cursor's row as a whole percentage of the rows"
      run :=
        pure
          (positionOf 0 1 == #["All"] && positionOf 0 0 == #["All"] &&
            positionOf 0 10 == #["Top"] &&
            positionOf 9 10 == #["Bot"] &&
            positionOf 12 10 == #["Bot"] &&
            positionOf 4 10 == #["50%"] &&
            positionOf 1 3 == #["66%"]) },
    { name := "the line:col is the cursor's row and column counted from 1"
      run :=
        let fields :=
          ModeLine.standard.fields
            { loopContext with
              cursor := some ⟨0, 0⟩, lines := 1 }
        pure ((fields.map (·.text)).contains "1:1") },
    { name := "a listing's order and side win over the segment's own place"
      run :=
        let line :=
          ModeLine.resolve { left := #["position"], right := #["buffer"] } ModeLine.shipped?
        let fields := line.1.fields loopContext
        pure
          (line.2.isEmpty &&
            fields.map (fun field => (field.text, field.side)) ==
              #[("41%", .left), ("Loop.lean", .right)]) },
    { name :=
        "a listing that names a segment nobody registered keeps the rest, in order, and names the unknown ones once each, in order"
      run :=
        let (line, unknown) :=
          ModeLine.resolve { left := #["state", "nope", "buffer", "nope"], right := #["gone"] }
            ModeLine.shipped?
        pure
          (textsAndFaces (line.fields loopContext) ==
              #[("NORMAL", "mode-line.state.normal"), ("Loop.lean", "mode-line.buffer")] &&
            unknown == #["nope", "gone"] &&
            ModeLine.unknown "nope" == "no segment is registered as `nope`") },
    { name :=
        "the default order is the badge, buffer, modified mark, changed mark and directory on the left, and major mode, line:col and position on the right"
      run :=
        pure
          (ModeLine.Order.standard ==
              { left := #["state", "buffer", "modified", "changed", "directory"]
                right := #["major-mode", "line-column", "position"] } &&
            ModeLine.shipped.map (·.name) ==
              #["state", "buffer", "modified", "changed", "directory", "major-mode", "line-column",
                "position"] &&
            ModeLine.standard.left.map (·.name) == ModeLine.Order.standard.left &&
            ModeLine.standard.right.map (·.name) == ModeLine.Order.standard.right) }]

end ModelTest
