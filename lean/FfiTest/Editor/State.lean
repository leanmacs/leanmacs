import Editor.Clipboard
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Real
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Config.Stores
import Editor.Display.Real
import Editor.DisplayRules
import Editor.Event
import Editor.Ex.Line
import Editor.Face
import Editor.Ffi.Display
import Editor.Ffi.Snapshot
import Editor.Ffi.Window
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Keymap
import Editor.Language
import Editor.Layout
import Editor.Loop
import Editor.Menu
import Editor.Mode
import Editor.ModeLine
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.SyntaxTree
import Editor.TabBar
import Editor.Text
import Editor.Text.Real
import Editor.UndoTree
import Editor.Watch
import Editor.Workspace
import FfiTest.Check

/-!
# FFI tests: `Editor/State.lean`

The tests of `Editor/State.lean`: `paddingChecks`, over the real display. The
root module `FfiTest` runs them, and each list's own doc says what it checks.
-/

namespace FfiTest

/-- The `status` line of the view `id` in `frame`, a frame as
`Display.frameText` writes it; `none` when the view has no status row. -/
def statusLineOf (frame : String) (id : Nat) : Option String := do
  let lines := frame.splitOn "\n"
  let start ← lines.findIdx? (·.startsWith s!"view {id} rect ")
  let inView := (lines.drop (start + 1)).takeWhile (·.startsWith "  ")
  inView.find? (·.startsWith "  status ")

/-- The x of the first glyph of the status row of the view `id` in `frame`:
the first `id@x` after ` glyphs` on its `status` line; `none` when the view
has no status row or its row no glyph. -/
def firstStatusGlyph (frame : String) (id : Nat) : Option Nat := do
  let status ← statusLineOf frame id
  let glyphs := (status.splitOn " glyphs ")[1]?.getD ""
  let first ← (glyphs.splitOn " ").head?
  let x := (first.splitOn "@")[1]?.getD ""
  -- A glyph in another font has `#font` after its x.
  ((x.splitOn "#").head?.getD "").toNat?

/-- The x of the first field's box of the status row of the view `id` in
`frame`: the `x` of the first `x+width:colour` after ` boxes`. -/
def firstStatusBox (frame : String) (id : Nat) : Option Nat := do
  let status ← statusLineOf frame id
  let boxes := (status.splitOn " boxes ")[1]?.getD ""
  let first ← (boxes.splitOn " ").head?
  ((first.splitOn "+").head?.getD "").toNat?

/-- The frame the real display, in cells 8 pixels across and 16 down at scale
1, lays out of the scene the loop publishes after a resize of a frame 640 by
480 to `corner` points of corner clearance and a top inset of `top`, in
fullscreen when `fullscreen`
says, each step handed a frame padding of 8: with a `:` prompt open over the
scratch window when `prompt` says, and otherwise with `echo` in the echo
area. And the id of the minibuffer's view, when a prompt is open. At scale 1
a point is a pixel, so the glyph positions are the scene's points. -/
def paddedFrame (corner : Nat) (fullscreen prompt : Bool) (echo : String := "") (top : Nat := 0) :
    IO (String × Option Nat) := do
  let table ← Editor.Snapshots.new
  let display ← Editor.Ffi.Display.newCells 8 16
  let real ← Editor.RealDisplay.over display table.reader #[]
  let program : Editor.EditorM (Option Nat) := do
    let state ← Editor.EditorState.initial ⟨640, 480⟩
    let state ←
      if prompt then
        do
          let made ← Editor.createText ""
          let scroll ← made.mark (.anchor { offset := 0, bias := .before })
          let selection ← made.mark (.selection { ranges := #[⟨0, 0⟩] })
          let history ← Editor.UndoTree.over made
          pure (state.openPrompt ":" { command := "ex" } made history scroll selection).2
      else
        pure { state with echo }
    let loop : Editor.Loop Editor.TestScheme.scheme := { state }
    let keys : Editor.Loop.Keys Editor.TestScheme.scheme := { padding := 8 }
    let resized ←
      loop.step keys
          (.resize { width := 640, height := 480, scale := 1.0, fullscreen, corner, top })
    return resized.loop.state.minibufferView?.map (·.index)
  let (result, _) ← program.runReal (Editor.RealTexts.over table) real.handle
  let .ok minibuffer := result | throw (IO.userError "the loop's program was refused")
  return (← display.frameText, minibuffer)

/-- The checks of criterion 3 over real layout (`ModelTest.paddingChecks`
pins the same numbers in the scene): the first glyph of the frame's bottom
row, the `:` prompt's label in the minibuffer's view's status row and an
echo in the echo's view, starts at or past the larger of the padding and the
corner clearance outside fullscreen, and at the padding alone in
fullscreen. -/
def paddingChecks (_ : Unit) : List Check :=
  [{  name :=
        "criterion 3, over real layout: with a prompt open, padding 8 and a corner clearance of 14, the prompt's first glyph is at 14 or past it, and the window's text and its mode line's first field are at 8; in fullscreen the prompt's first glyph is at 8, the padding alone"
      run := do
        let (windowed, some minibuffer) ← paddedFrame 14 false true | return false
        let (full, some fullMinibuffer) ← paddedFrame 14 true true | return false
        let prompt := firstStatusGlyph windowed minibuffer
        -- The window's mode line's first field starts at the padding; its
        -- glyphs are its own padding further in.
        let window := firstStatusBox windowed 0
        return prompt.any (· ≥ 14) && prompt == some 14 && window == some 8 &&
            firstStatusGlyph full fullMinibuffer == some 8 &&
            (windowed.splitOn "  row x 8 y 8 ").length > 1 },
    { name :=
        "criterion 3, over real layout: with no prompt open, padding 8 and a corner clearance of 14, an echo's first glyph is at 14 or past it; in fullscreen at 8, the padding alone"
      run := do
        let echoView := 18446744073709551615
        let (windowed, none) ← paddedFrame 14 false false "hello" | return false
        let (full, none) ← paddedFrame 14 true false "hello" | return false
        let echo := firstStatusGlyph windowed echoView
        return echo.any (· ≥ 14) && echo == some 14 && firstStatusGlyph full echoView == some 8 },
    { name :=
        "criterion 4, over real layout: with padding 8 and a top inset of 28, the window's first text row is at y 36, below the inset and the padding; after a fullscreen resize that says none, at 8"
      run := do
        let (covered, _) ← paddedFrame 0 false false "hello" 28
        let (full, _) ← paddedFrame 0 true false "hello" 0
        return (covered.splitOn "  row x 8 y 36 ").length > 1 &&
            (covered.splitOn "  row x 8 y 8 ").length == 1 &&
            (full.splitOn "  row x 8 y 8 ").length > 1 }]

end FfiTest
