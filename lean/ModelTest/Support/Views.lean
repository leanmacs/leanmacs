import Editor.Command.Model
import Editor.Display
import Editor.Display.Model
import Editor.Event
import Editor.InputScheme.Vim.Default
import Editor.Loop
import Editor.Loop.Driver
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Text
import Editor.Text.Model
import ModelTest.Support.Evil

/-!
# Model tests: support: Views

Views as the loop publishes them: states with numbered texts, frames and
released snapshots. Shared by several test modules under `ModelTest/Editor/`; it
holds no checks of its own.
-/

namespace ModelTest

open Editor

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

/-- A state of the view checks: `evilState` over `contents` with the cursor
at `head`, in a frame of `size`, with the scroll margin `margin`. The one
window has the frame above its bottom row, and its scroll anchor is at the
text's start. -/
def viewState (contents : String) (size : Size) (margin : Nat := 0) (head : Nat := 0) :
    TextM EditorState := do
  let state ← evilState contents head
  return { (state.setScrollMargin margin) with frame := { state.frame with size } }

/-- `driver` fed a resize of the frame to `size`. -/
def viewResized (driver : EvilDriver) (size : Size) : EvilDriver :=
  let frame := frameAround size driver.model.display.cells
  (driver.feed
      { event := .resize { width := frame.width, height := frame.height, scale := 1.0 }
        stamp := 0 }).1

/-- Whether asking the text model of `driver` for the snapshot `id` is
refused with `noSuchSnapshot`: it was released. -/
def releasedSnapshot (driver : EvilDriver) (id : SnapshotId) : Bool :=
  match ((id.lineCount : TextM Nat).runModel driver.model.texts).1 with
  | .error .noSuchSnapshot => true
  | _ => false

end ModelTest
