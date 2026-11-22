import Editor.Command.Model
import Editor.Display
import Editor.Display.Model
import Editor.Event
import Editor.InputScheme
import Editor.Loop
import Editor.Loop.Driver
import Editor.Program
import Editor.Scene
import Editor.Scroll
import Editor.State
import Editor.Test.Editing
import Editor.Text
import Editor.Text.Model

/-!
# The test kit: Views

Views as the loop publishes them, and the rows the display model answers
for them: texts of numbered and of wrapping lines, the display model over a
text and its rows (`allRows`, `rowsFrom`, `rowAt`), the scroll margin as a
property of those rows (`marginHolds`), states of one window in a frame a
few rows tall (`viewState`, `frameAround`), a resize fed to a driver
(`viewResized`), and what the last scene a driver published shows of a
view, asked of the driver's models (`ViewSeen`, `seenIn`, `viewSeen`,
`viewPlaced`): where its scroll anchor is, the rows the display model
answers from it, and the row it answers for the cursor. The drivers are of
any scheme, so the loop's own checks of a view that follows its cursor read
it under the test scheme, and a scheme's package's checks of its scroll
commands under that scheme. It holds no checks of its own.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import"). The core's own model tests are written on it.
-/

namespace Editor.Test

open Editor

/-- A display model whose cells are one pixel each way, holding `texts` as
the snapshots 0, 1, 2 and so on, with nothing published. -/
def displayOver (texts : List String) (cells : Display.Cells := { advance := 1, lineHeight := 1 }) :
    DisplayModel :=
  { cells, texts := (texts.toArray.mapIdx fun index text => (⟨index⟩, text)) }

/-- Lines of 6, 2, 10 and 3 characters. Four characters wide, the first takes
two rows and the third three: rows 0 to 6 start at 0, 4, 7, 10, 14, 18 and
21. -/
def wrapping : String :=
  "abcdef\nab\nabcdefghij\nxyz"

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

/-- `count` lines of two digits each, `00`, `01` and so on, joined by line
feeds, and then `ending`. -/
def numbered (count : Nat) (ending : String := "") : String :=
  "\n".intercalate ((List.range count).map fun line => s!"{line / 10}{line % 10}") ++ ending

/-- The frame whose one window's text area is `area`, in `cells`: two rows
of a cell taller, for the window's status row and the frame's bottom row,
which the display model answers a cell tall each. So "a view of six rows"
of a check is a view whose rows are asked with six rows' height. -/
def frameAround (area : Size) (cells : Display.Cells) : Size :=
  ⟨area.width, area.height + 2 * cells.lineHeight⟩

/-- A state of the view checks: `barState` over `contents` with the cursor
at `head`, of the shape `shape`, in a frame of `size`, with the scroll
margin `margin`. The one window has the frame above its bottom row, and its
scroll anchor is at the text's start. -/
def viewState (contents : String) (size : Size) (margin : Nat := 0) (head : Nat := 0)
    (shape : Shape := .exclusive) : TextM EditorState := do
  let state ← barState contents head shape
  return { (state.setScrollMargin margin) with frame := { state.frame with size } }

/-- `driver` fed a resize of the frame to `size`. -/
def viewResized {scheme : InputScheme} (driver : Loop.Driver scheme) (size : Size) :
    Loop.Driver scheme :=
  let frame := frameAround size driver.model.display.cells
  (driver.feed
      { event := .resize { width := frame.width, height := frame.height, scale := 1.0 }
        stamp := 0 }).1

/-- Whether asking the text model of `driver` for the snapshot `id` is
refused with `noSuchSnapshot`: it was released. -/
def releasedSnapshot {scheme : InputScheme} (driver : Loop.Driver scheme) (id : SnapshotId) :
    Bool :=
  match ((id.lineCount : TextM Nat).runModel driver.model.texts).1 with
  | .error .noSuchSnapshot => true
  | _ => false

/-- What a scene shows of one view, as the view checks read it: where its
markers are, and what the display model answers for it. -/
structure ViewSeen where
  /-- The marker the scene names as the view's scroll anchor. -/
  scroll : MarkerId
  /-- Where that anchor is. -/
  anchor : Nat
  /-- The view's selection. -/
  selection : Selection
  /-- The head of its primary range: the cursor. -/
  head : Nat
  /-- The rows the display model answers for the scene's view, from its
  anchor. -/
  shown : Array Display.Row
  /-- The cursor's row: the first row the display model answers for the
  scene's view from the cursor; none in a view that shows no row. -/
  row : Option Display.Row
  deriving DecidableEq, Repr

/-- Where the cursor's row is among the rows the view shows, if it is one
of them. -/
def ViewSeen.index (seen : ViewSeen) : Option Nat :=
  seen.row.bind fun row => seen.shown.findIdx? (· == row)

/-- What the last scene `model`'s display recorded shows of the view `view`
(`ViewSeen`), asked of `model`: its markers of the text model, and the rows
of the display model for the scene's snapshot and rectangle. `none` when no
scene has the view, or a marker of it refuses. -/
def seenIn (model : EditorModel) (view : ViewId := ⟨0⟩) : Option ViewSeen := do
  let scene ← model.display.scenes.back?
  let shown ← scene.views.find? (·.id == view)
  let #[marker] := shown.selections | none
  let program : EditorM ViewSeen := do
    let .anchor anchor ← shown.scroll.text.marker shown.scroll | throw .noSuchMarker
    let .selection selection ← marker.text.marker marker | throw .noSuchMarker
    let some range := selection.ranges[selection.primary]? | throw .badSelection
    -- A window's view, asked with its height less its status row, which
    -- is the display model's cell.
    let area := Scroll.Area.ofRect shown.snapshot shown.rect model.display.cells.heights.status
    return {
        scroll := shown.scroll, anchor := anchor.offset, selection, head := range.head
        shown := ← area.rows anchor.offset, row := (← area.rows range.head)[0]? }
  (program.runModel model).1.toOption

/-- What the last scene of `driver` shows of the view `view` (`seenIn`). -/
def viewSeen {scheme : InputScheme} (driver : Loop.Driver scheme) (view : ViewId := ⟨0⟩) :
    Option ViewSeen :=
  seenIn driver.model view

/-- `driver` after the command called `name` has run as an invocation no key
yielded, with no arguments. -/
def viewRan {scheme : InputScheme} (driver : Loop.Driver scheme) (name : String) :
    Loop.Driver scheme :=
  (driver.stepped (driver.loop.invoke driver.handed { command := name })).1

/-- Where a view is in its text, by the rows `rows` of the text as the
display model answers them: the index of the first row the view shows, and
of the cursor's row. -/
def ViewSeen.place (seen : ViewSeen) (rows : Array Display.Row) : Option (Nat × Nat) := do
  let top ← rows.findIdx? (some · == seen.shown[0]?)
  let cursor ← rows.findIdx? (some · == seen.row)
  return (top, cursor)

/-- Where view 0 of `driver` is in its text once the keys `typed` are
pressed (`ViewSeen.place`). -/
def viewPlaced {scheme : InputScheme} (driver : Loop.Driver scheme) (typed : String)
    (rows : Array Display.Row) : Option (Nat × Nat) :=
  (viewSeen (keysFed driver typed)).bind (·.place rows)

/-- The key string that names `key` `count` times. -/
def keyTimes (key : String) (count : Nat) : String :=
  " ".intercalate (List.replicate count key)

end Editor.Test
