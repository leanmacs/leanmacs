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

/-- Whether the text store of `driver`'s models still holds `marker`. -/
def markerHeld (driver : EvilDriver) (marker : MarkerId) : Bool :=
  ((marker.text.marker marker).runModel driver.model.texts).1.toOption.isSome

/-- From the fixture `fixture`, the keys `before`, which set the mark `a`,
then the keys `after`: whether the store held the marker of `a` after
`before`, whether it holds it after `after`, and whether `a` is still set,
by another marker. -/
def releasedAfter (fixture before after : String) : Option (Bool × Bool × Bool) := do
  let driver ← evilDriver fixture
  let marked := evilFed driver before
  let old ← marked.loop.state.localMark? ⟨0⟩ 'a'
  let left := evilFed marked after
  return (markerHeld marked old, markerHeld left old,
      (left.loop.state.localMark? ⟨0⟩ 'a').any (· != old))

/-- After the mark of `followedState` is followed through a node made by an
edit of part of its line and an undo of that node, run on the tree outside
the editor API so that the publish's `followMarks` puts the mark back:
whether the text store still holds the mark's first marker, and whether
the mark is set by another. -/
def followedUndo : Option (Bool × Bool) :=
  onTextModel do
    let (state, marker) ← followedState
    let text : TextId := ⟨0⟩
    let some buffer := state.buffer? ⟨0⟩ | return (true, false)
    text.delete 4 5
    let made := (buffer.history.record (← text.revision)).close
    let state : EditorState :=
      { state with
        buffers :=
          state.buffers.modify 0 (·.map fun (buffer : Buffer) => { buffer with history := made }) }
    let (state, _) ← state.followMarks
    let some moved ← made.undo | return (true, false)
    let state : EditorState :=
      { state with
        buffers :=
          state.buffers.modify 0
            (·.map fun (buffer : Buffer) => { buffer with history := moved.tree }) }
    let (state, _) ← state.followMarks
    let held := (← observing (text.marker marker)) matches .ok _
    return (held, (state.localMark? ⟨0⟩ 'a').any (· != marker))

/-- The checks of the marks of the editor state followed through an event. -/
def markFollowChecks : List Check :=
  [{  name :=
        "a lowercase mark whose line an edit removed is erased, and one a command decided about is not, and the decision is spent"
      run := return followedDelete false == some (false, #[]) && followedDelete true == some (true, #[]) },
    { name :=
        "followMarks gives up the marker a mark it put back replaced, when the tree moved by one edge outside the editor API"
      run := return followedUndo == some (false, true) },
    { name :=
        "through the loop, a mark's marker is given up once the mark is erased, by a charwise delete across its line or by dd, and once an undo puts the mark back by another"
      run :=
        return releasedAfter "|ab\ncd\nef" "j m a" "k v j j d" == some (true, false, false) &&
            releasedAfter "ab\nc|d\nef" "m a" "d d" == some (true, false, false) &&
            releasedAfter "ab\nc|d\nef" "m a" "x u" == some (true, false, true) }]

end ModelTest
