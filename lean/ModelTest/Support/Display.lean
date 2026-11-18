import Editor.Display
import Editor.Display.Model
import Editor.Menu
import Editor.Scene
import Editor.Scroll
import Editor.Text

/-!
# Model tests: support: Display

Programs over the display port on its model: the scenes and texts it holds, the
rows it answers, and the scroll margin as a property of those rows. Shared by
several test modules under `ModelTest/Editor/`; it holds no checks of its own.
-/

namespace ModelTest

open Editor

/-- A scene of two views, with every field of a scene and of a view set: the
first view focused, with two selections, a decoration and two status fields;
the second with none of those. Its content is named by handles only. -/
def twoViews : Scene where
  size := { width := 1600, height := 1200 }
  views :=
    #[{ id := ⟨0⟩, rect := { x := 0, y := 0, width := 800, height := 1160 }, snapshot := ⟨3⟩
        scroll := { text := ⟨1⟩, index := 0 }
        selections := #[{ text := ⟨1⟩, index := 1 }, { text := ⟨1⟩, index := 2 }]
        cursor := { shape := .block, face := ⟨"cursor.normal"⟩ }
        decorations := #[{ start := 4, stop := 9, face := ⟨"search.match"⟩ }]
        status :=
          #[{ text := "notes.txt", face := ⟨"mode-line.buffer"⟩, padding := 4 },
            { text := "1:1", face := ⟨"mode-line.secondary"⟩, side := .right, padding := 4 }] },
      { id := ⟨1⟩, rect := { x := 800, y := 0, width := 800, height := 1160 }, snapshot := ⟨4⟩
        scroll := { text := ⟨2⟩, index := 0 }, selections := #[]
        cursor := { shape := .bar, face := ⟨"cursor.insert"⟩ }, decorations := #[], status := #[] }]
  focused := some ⟨0⟩
  echo := "2 lines yanked"
  pending := "d2"
  preedit := some "´"

/-- A display model whose cells are one pixel each way, holding `texts` as
the snapshots 0, 1, 2 and so on, with nothing published. -/
def displayOver (texts : List String) (cells : Display.Cells := { advance := 1, lineHeight := 1 }) :
    DisplayModel :=
  { cells, texts := (texts.toArray.mapIdx fun index text => (⟨index⟩, text)) }

/-- A display program's answer, or the refusal it failed with on the left, as
a value with equality. -/
def answered {α : Type} : Except DisplayError α → DisplayError ⊕ α
  | .ok answer => .inr answer
  | .error refusal => .inl refusal

/-- Lines of 6, 2, 10 and 3 characters. Four characters wide, the first takes
two rows and the third three: rows 0 to 6 start at 0, 4, 7, 10, 14, 18 and
21. -/
def wrapping : String :=
  "abcdef\nab\nabcdefghij\nxyz"

/-- Where the display model over `texts` moves `position` of the first of
them, in a view `width` pixels wide, by `lines` rows aiming for `goal`. -/
def movedBy (texts : List String) (width position : Nat) (lines : Int) (goal : Option Nat)
    (cells : Display.Cells := { advance := 1, lineHeight := 1 }) : DisplayError ⊕ Display.Moved :=
  answered
    ((Display.linesFrom { snapshot := ⟨0⟩, width, position, lines, goal }).runModel
        (displayOver texts cells)).1

/-- A view of the first text of a display model, `width` pixels wide and
`height` tall. -/
def areaOf (width height : Nat) : Scroll.Area :=
  { snapshot := ⟨0⟩, width, height }

/-- What a display program answers on the display model over `text`, or none
where it was refused. -/
def onDisplay {α : Type} (text : String) (program : DisplayM α)
    (cells : Display.Cells := { advance := 1, lineHeight := 1 }) : Option α :=
  (program.runModel (displayOver [text] cells)).1.toOption

/-- The rows a view of `text`, `width` by `height` pixels, shows from
`anchor`, as the display model answers them; none where it refuses. -/
def rowsFrom (text : String) (width height anchor : Nat)
    (cells : Display.Cells := { advance := 1, lineHeight := 1 }) : Array Display.Row :=
  (onDisplay text ((areaOf width height).rows anchor) cells).getD #[]

/-- Every row of `text` in a view `width` pixels wide, as the display model
answers them: what a view taller than the text shows from its start. -/
def allRows (text : String) (width : Nat)
    (cells : Display.Cells := { advance := 1, lineHeight := 1 }) : Array Display.Row :=
  rowsFrom text width (cells.lineHeight * (text.utf8ByteSize + 1)) 0 cells

/-- The row that holds `position`, as the display model answers it. -/
def rowAt (text : String) (width position : Nat)
    (cells : Display.Cells := { advance := 1, lineHeight := 1 }) : Option Display.Row :=
  (rowsFrom text width cells.lineHeight position cells)[0]?

/-- Where row `index` of `rows` starts; past the last of them, an offset no
row starts at. -/
def startOf (rows : Array Display.Row) (index : Nat) : Nat :=
  (rows[index]?.map (·.start)).getD (rows.size + (rows.back?.map (·.stop)).getD 0 + 1)

/-- Whether `row` is among `shown` at least `margin` rows from the first and
from the last of them, except where the first is the first of `rows`, the
text's rows, or the last their last. -/
def marginHolds (rows shown : Array Display.Row) (row : Display.Row) (margin : Nat) : Bool :=
  match shown.findIdx? (· == row) with
  | none => false
  | some index =>
    (index ≥ margin || shown[0]? == rows[0]?) &&
      (shown.size - 1 - index ≥ margin || shown.back? == rows.back?)

/-- Lines of 10, 2, 0, 7, 1, 1, 1, 17 and 1 characters, and a line feed after
the last: four characters wide, the first, the fourth and the eighth wrap. -/
def ragged : String :=
  "abcdefghij\nab\n\nabcdefg\nx\ny\nz\nabcdefghijklmnopq\nq\n"

end ModelTest
