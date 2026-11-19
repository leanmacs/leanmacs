import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Config.Stores
import Editor.Event
import Editor.Gutter
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Loop
import Editor.Loop.Driver
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Test.Driver
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Text
import Editor.Text.Model
import ModelTest.Check

/-!
# Model tests: `Editor/Gutter.lean`

The model tests of `Editor/Gutter.lean`: `gutterCarryChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- An edit of a patch: the bytes `start` up to `stop` before replaced by
`count` bytes. The points are not looked at by the carry. -/
def gutterEdit (start stop count : Nat) (placed : Nat := start) : Edit :=
  { old := { start, stop, startPoint := ⟨0, 0⟩, stopPoint := ⟨0, 0⟩ }
    new := { start := placed, stop := placed + count, startPoint := ⟨0, 0⟩, stopPoint := ⟨0, 0⟩ } }

/-- A patch of the one edit `edit`, from revision 0 to 1. -/
def gutterPatch (edit : Edit) : Patch :=
  { since := 0, revision := 1, edits := #[edit] }

/-- A mark over `start` up to `stop`, in `diff.added`. -/
def addedMark (start stop : Nat) : GutterMark :=
  { start, stop, text := "+", face := ⟨"diff.added"⟩ }

/-- The bindings of the gutter carry checks: `C-g m`, which gives the window's
buffer a gutter of one mark over its first line at its text's revision, and
`C-g e`, which puts `z\n` at its start. -/
def gutterCarryCommands : List (String × Dispatched) :=
  [("mark-gutter", fun call => do
      let text := call.target.buffer.text
      let revision ← text.revision
      discard <| call.target.window.buffer.setGutter (some { revision, marks := #[addedMark 0 2] })
      return none),
    ("edit-top", fun call => do
      call.target.buffer.text.insert 0 "z\n"
      return none)]

/-- A driver whose view 0 shows `a\nb\n`, with `gutterCarryCommands` on
`C-g m` and `C-g e`; `none` if making the state was refused. -/
def gutterCarryDriver : Option TestDriver :=
  let keys :=
    dispatchKeys [("C-g m", invoke "mark-gutter"), ("C-g e", invoke "edit-top")] gutterCarryCommands
  (Loop.Driver.over keys (fun _ => none) (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver =>
    let typed := (fedTo driver [.preedit "", .commit "a\nb\n"]).1
    typed

/-- The checks of carrying a buffer's gutter marks through its edits
(`Editor/Gutter.lean`) and of the gutter column in a view's padding. -/
def gutterCarryChecks : List Check :=
  let carried (edit : Edit) (mark : GutterMark) := Gutter.carry (gutterPatch edit) mark
  [{  name := "an insert above a mark moves it down by what was inserted"
      run := pure (carried (gutterEdit 0 0 2) (addedMark 2 4) == some (addedMark 4 6)) },
    { name := "an insert inside a mark grows it, and one at its start moves its start past it"
      run :=
        pure <|
          carried (gutterEdit 3 3 1) (addedMark 2 4) == some (addedMark 2 5) &&
            carried (gutterEdit 2 2 2) (addedMark 2 4) == some (addedMark 4 6) },
    { name := "a deletion of all of a mark drops it, and of part of it shrinks it"
      run :=
        pure <|
          carried (gutterEdit 2 4 0) (addedMark 2 4) == none &&
            carried (gutterEdit 1 3 0) (addedMark 2 4) == some (addedMark 1 2) },
    { name :=
        "an empty mark stays at its line: moved by an insert above, and kept at the start of its line by one at its offset"
      run :=
        pure <|
          carried (gutterEdit 0 0 2) (addedMark 6 6) == some (addedMark 8 8) &&
            carried (gutterEdit 6 6 1) (addedMark 6 6) == some (addedMark 7 7) &&
            carried (gutterEdit 8 8 1) (addedMark 6 6) == some (addedMark 6 6) },
    { name := "a mark past every edit moves by all of them, and one before every edit stays"
      run :=
        pure <|
          Gutter.carry
                { since := 0, revision := 2, edits := #[gutterEdit 0 0 1, gutterEdit 4 6 0 5] }
                (addedMark 8 10) ==
              some (addedMark 7 9) &&
            carried (gutterEdit 9 9 3) (addedMark 2 4) == some (addedMark 2 4) },
    { name :=
        "the marks of a text whose log is forgotten past their revision draw none, and those at the snapshot's revision are kept as they are"
      run :=
        pure <|
          let program : TextM (Array GutterMark × Array GutterMark) := do
            let text ← createText "a\nb\n"
            let gutter : Buffer.Gutter := { revision := 0, marks := #[addedMark 0 2] }
            let at0 ← text.snapshot
            let kept ← Gutter.marksOf text (some gutter) at0 0 4
            text.insert 0 "z\n"
            text.insert 0 "y\n"
            text.forget 2
            let at2 ← text.snapshot
            let forgotten ← Gutter.marksOf text (some gutter) at2 0 8
            return (kept, forgotten)
          (program.runModel {}).1.toOption == some (#[addedMark 0 2], #[]) },
    { name := "a mark is carried to the revision a view shows, and clipped to the view's range"
      run :=
        pure <|
          let program : TextM (Array GutterMark) := do
            let text ← createText "a\nb\nc\n"
            let gutter : Buffer.Gutter :=
              { revision := 0, marks := #[addedMark 0 2, addedMark 2 6, addedMark 6 6] }
            text.insert 0 "z\n"
            let shown ← text.snapshot
            Gutter.marksOf text (some gutter) shown 2 6
          (program.runModel {}).1.toOption == some #[addedMark 2 4, addedMark 4 6] },
    { name :=
        "a buffer with a gutter has the gutter's column in its view's padding and its marks in the scene, carried through an edit; one with none has neither"
      run :=
        pure <|
          match gutterCarryDriver with
          | none => false
          | some driver =>
            let bare := gutterView driver
            let (marked, _) := fedTo driver (presses "C-g m")
            let (edited, _) := fedTo marked (presses "C-g e")
            (bare.map (·.padding.gutter)) == some 0 && (bare.map (·.marks)) == some #[] &&
              (gutterView marked).map (·.padding.gutter) == some Buffer.Gutter.width &&
              (gutterView marked).map (·.marks) == some #[addedMark 0 2] &&
              (gutterView edited).map (·.marks) == some #[addedMark 2 4] }]

end ModelTest
