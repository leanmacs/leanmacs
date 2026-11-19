import Editor.Marks.Follow
import ModelTest.Check
import ModelTest.Support.Evil
import ModelTest.Support.Models

/-!
# Model tests: `Editor/Marks/Follow.lean`

The model tests of `Editor/Marks/Follow.lean`: `markFollowChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- A state over `ab`, `cd` and `ef` whose buffer's mark `a` is at the start
of row 1, its line read by a first `followMarks`, and the mark's marker. -/
def followedState : TextM (EditorState × MarkerId) := do
  let state ← evilState "ab\ncd\nef" 0
  let marker ← (⟨0⟩ : TextId).mark (.anchor { offset := 3, bias := .after })
  let state : EditorState :=
    { state with
      buffers :=
        state.buffers.modify 0
          (·.map fun (buffer : Buffer) => { buffer with marks := #[('a', marker)] }) }
  let (state, _) ← state.followMarks
  return (state, marker)

/-- After row 1 of `followedState` is deleted whole and the marks are
followed, with its mark's marker recorded as decided first when `decided`:
whether the mark is still set, and the markers left decided. -/
def followedDelete (decided : Bool) : Option (Bool × Array MarkerId) :=
  onTextModel do
    let (state, marker) ← followedState
    let state : EditorState :=
      if decided then
        { state with
          buffers :=
            state.buffers.modify 0
              (·.map fun (buffer : Buffer) => { buffer with markHistory.decided := #[marker] }) }
      else state
    (⟨0⟩ : TextId).delete 3 6
    let (state, _) ← state.followMarks
    let some buffer := state.buffer? ⟨0⟩ | return (false, #[])
    return ((buffer.marks.find? (·.1 == 'a')).isSome, buffer.markHistory.decided)

/-- The checks of the marks of the editor state followed through an event. -/
def markFollowChecks : List Check :=
  [{  name :=
        "a lowercase mark whose line an edit removed is erased, and one a command decided about is not, and the decision is spent"
      run := return followedDelete false == some (false, #[]) && followedDelete true == some (true, #[]) }]

end ModelTest
