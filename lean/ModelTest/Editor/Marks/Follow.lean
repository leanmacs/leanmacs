import Editor.Api
import Editor.Command.Dispatch
import Editor.Marks.Follow
import Editor.Test.Models
import ModelTest.Check
import ModelTest.Support.Evil

/-!
# Model tests: `Editor/Marks/Follow.lean`

The model tests of `Editor/Marks/Follow.lean`: `markFollowChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

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

/-- `followedState` with its buffer an excerpt buffer, its mark's line read
by a first `followMarks` as for any buffer: whether its mark is still set
once row 1 is deleted whole and the marks are followed again. -/
def followedExcerptDelete : Option Bool :=
  onTextModel do
    let (state, _) ← followedState
    let state : EditorState :=
      { state with
        buffers :=
          state.buffers.modify 0
            (·.map fun (buffer : Buffer) => { buffer with excerpts := some {} }) }
    (⟨0⟩ : TextId).delete 3 6
    let (state, _) ← state.followMarks
    return (state.localMark? ⟨0⟩ 'a').isSome

/-- A buffer named `name` over a new text holding `ab`, `cd` and `ef`, its
mark `a` at the start of row 1. -/
def markedBuffer (name : String) : TextM Buffer := do
  let text ← createText "ab\ncd\nef"
  let history ← UndoTree.over text
  let marker ← text.mark (.anchor { offset := 3, bias := .after })
  return { name, text, history, marks := #[('a', marker)] }

/-- `followedState` with two more buffers, each marked as `markedBuffer`
makes it, their lines read by a first `followMarks`, then the text of the
second, buffer 1, released, so that it refuses; then row 1 of the first and
the third deleted whole and the marks followed again: whether that follow
handed a refusal back, whether buffer 1 is as it was before it, and whether
the mark of buffer 0 and of buffer 2 is still set. -/
def followedRefusing : Option (Bool × Bool × Bool × Bool) :=
  onTextModel do
    let (state, _) ← followedState
    let state : EditorState :=
      { state with
        buffers :=
          (state.buffers.push (some (← markedBuffer "refusing"))).push
            (some (← markedBuffer "other")) }
    let (state, _) ← state.followMarks
    let some refusing := state.buffer? ⟨1⟩ | return (false, false, true, true)
    let some other := state.buffer? ⟨2⟩ | return (false, false, true, true)
    refusing.text.release
    (⟨0⟩ : TextId).delete 3 6
    other.text.delete 3 6
    let (followed, refusal) ← state.followMarks
    return (refusal.isSome, followed.buffer? ⟨1⟩ == some refusing,
        (followed.localMark? ⟨0⟩ 'a').isSome, (followed.localMark? ⟨2⟩ 'a').isSome)

/-- How `BufferId.followMarks` of buffer 0 ended, run dispatched on the
editor's models from `followedState`, its buffer an excerpt buffer when
`excerpt`, and then row 1 of its text deleted whole, or the text released
when `refuse`, so that it refuses: `refused` or `finished`, whether the
mark is still set, and whether the buffer is as it was before the run. -/
def apiFollowed (excerpt refuse : Bool) : Option (String × Bool × Bool) :=
  let program : EditorM (Guarded Unit × EditorState × Option Buffer) := do
    let (state, _) ← followedState
    let state : EditorState :=
      { state with
        buffers :=
          state.buffers.modify 0
            (·.map fun (buffer : Buffer) =>
              { buffer with excerpts := if excerpt then some {} else none }) }
    if refuse then
      (⟨0⟩ : TextId).release
    else
      (⟨0⟩ : TextId).delete 3 6
    let (ended, left) ← (BufferId.followMarks ⟨0⟩).dispatched {} state
    return (ended, left, state.buffer? ⟨0⟩)
  match (program.runModel editorModel).1 with
  | .ok (ended, state, before) =>
    let ended :=
      match ended with
      | .finished _ => "finished"
      | .refused _ => "refused"
      | _ => "other"
    some (ended, (state.localMark? ⟨0⟩ 'a').isSome, state.buffer? ⟨0⟩ == before)
  | .error _ => none

/-- What `driver` of a text whose one buffer is an excerpt buffer leaves
after the keys `before`, which set the mark `a`, then `after`: whether `a`
was set by `before`, and whether it is still set after `after`. -/
def excerptMarkAfter (fixture before after : String) : Option (Bool × Bool) := do
  let start : TextM EditorState := do
    let (contents, head) := barred fixture
    let state ← evilState contents head
    return { state with
        buffers :=
          state.buffers.modify 0
            (·.map fun (buffer : Buffer) => { buffer with excerpts := some {} }) }
  let driver ← (Loop.Driver.over evilHanded (fun _ => none) start editorModel).toOption
  let marked := evilFed driver before
  let left := evilFed marked after
  return ((marked.loop.state.localMark? ⟨0⟩ 'a').isSome,
      (left.loop.state.localMark? ⟨0⟩ 'a').isSome)

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
            releasedAfter "ab\nc|d\nef" "m a" "x u" == some (true, false, true) },
    { name :=
        "the marks of an excerpt buffer are not followed: its mark whose line an edit removed stays set"
      run := return followedExcerptDelete == some true },
    { name :=
        "a buffer whose text refuses is left as it was while the other buffers' marks are followed, before and after it, and the refusal is handed back"
      run := return followedRefusing == some (true, true, false, false) },
    { name :=
        "BufferId.followMarks erases a mark whose line an edit removed, leaves an excerpt buffer's marks alone, and is refused by a text that refuses, leaving its buffer as it was"
      run :=
        return apiFollowed false false == some ("finished", false, false) &&
            apiFollowed true false == some ("finished", true, true) &&
            apiFollowed false true == some ("refused", true, true) },
    { name :=
        "through the loop, m a in a window on an excerpt buffer sets the mark, and a charwise delete across its line, which erases a file buffer's, keeps it"
      run := return excerptMarkAfter "|ab\ncd\nef" "j m a" "k v j j d" == some (true, true) }]

end ModelTest
