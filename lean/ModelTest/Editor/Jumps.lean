import Editor.Test.Editing
import ModelTest.Check
import ModelTest.Support.Jumps

/-!
# Model tests: `Editor/Jumps.lean`

The model tests of `Editor/Jumps.lean`: `jumpChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The jump list of view 0 and where its cursor is, after the keys `keys`
of the jump checks (`jumpedFrom`). -/
def jumpsAfter (keys : String) : Option ((List String × Nat) × String) := do
  let driver ← jumpedFrom keys
  return (← jumpsOf driver, ← cursorOf driver)

/-- After `Jumps.deleteRows` over rows `first` through `last`, keeping the
first when `keepFirst`, of a buffer over `ab`, `cd` and `ef` whose marks
`a`, `b` and `c` are at the offsets 0, 3 and 7 and whose global mark `A` is
on row 1: the letters of buffer 0's lowercase marks, the offsets of the
markers its mark history says were decided, and whether `A` is still set. -/
def deletedRows (first last : Nat) (keepFirst : Bool := false) :
    Option (List Char × List Nat × Bool) :=
  let start : TextM EditorState := do
    let state ← barState "ab\ncd\nef" 0
    let text : TextId := ⟨0⟩
    let marks ←
      [('a', 0), ('b', 3), ('c', 7)].toArray.mapM fun (char, offset) => do
          return (char, ← text.mark (.anchor { offset, bias := .after }))
    let global ← text.mark (.anchor { offset := 4, bias := .after })
    return { state with
        buffers := state.buffers.modify 0 (·.map ({ · with marks }))
        remembered.globalMarks := #[('A', .held ⟨0⟩ global)] }
  let program : EditorM (List Char × List Nat × Bool) := do
    Jumps.deleteRows ⟨0⟩ first last keepFirst
    let state ← editorState
    let some buffer := state.buffer? ⟨0⟩ | return ([], [], false)
    let decided ← buffer.markHistory.decided.toList.mapM fun marker => Marks.offsetOf marker
    return (buffer.marks.toList.map (·.1), decided, (state.globalMark? 'A').isSome)
  (dispatchedFrom program start).map (·.1)

/-- The checks of recording, cleaning up, detaching and attaching the places
of a window's jump list, on the loop's driver over the editor's models and
the file model (`jumpDriver`). -/
def jumpChecks : List Check :=
  [{  name :=
        "a record keeps the cursor's place as the last entry, the index one past the end, and as the previous-context mark"
      run :=
        return (jumpedFrom "C-j 2 C-j r").map (fun driver => (jumpsOf driver, previousOf driver)) ==
            some (some (["0@2:0"], 1), some (some "0@2:0")) },
    { name :=
        "a recorded entry follows an insert of lines before it and a deletion before it, on the text model"
      run :=
        return (jumpsAfter "C-j 3 C-j r C-j l").map (·.1) == some (["0@4:0"], 1) &&
            (jumpsAfter "C-j 3 C-j r C-j l C-j l C-j d C-j d C-j d").map (·.1) ==
              some (["0@2:0"], 1) },
    { name :=
        "closing a buffer detaches its places into its file's path, row and column in characters, in the list and the previous-context mark"
      run :=
        return (jumpedFrom "C-j n C-j 2 C-j w C-j r C-j k").map
              (fun driver => (jumpsOf driver, previousOf driver, cursorOf driver)) ==
            some
              (some (["0@0:0", s!"{jumpsPath}@2:1"], 2), some (some s!"{jumpsPath}@2:1"),
                some "0@0:0") },
    { name := "closing a buffer with no file drops the places held in it"
      run :=
        return (jumpedFrom "C-j m C-j r C-j k").map (fun driver => (jumpsOf driver, previousOf driver)) ==
            some (some ([], 0), some none) },
    { name :=
        "loading a file again attaches its detached places to markers of the new buffer's text"
      run :=
        return (jumpsAfter "C-j n C-j 2 C-j w C-j r C-j k C-j n").map (·.1) ==
            some (["0@0:0", "2@2:2", "0@0:0"], 3) },
    { name :=
        "deleting rows erases the buffer's lowercase marks on them and keeps its others and the global marks, deciding none"
      run :=
        return deletedRows 1 2 == some (['a'], [], true) &&
            deletedRows 0 0 == some (['b', 'c'], [], true) },
    { name :=
        "deleting rows but the first keeps the first's lowercase marks and records them as decided, erasing the others'"
      run :=
        return deletedRows 1 2 true == some (['a', 'b'], [3], true) &&
            deletedRows 0 0 true == some (['a', 'b', 'c'], [0], true) }]

end ModelTest
