import ModelTest.Check
import ModelTest.Support.Evil
import ModelTest.Support.Jumps

/-!
# Model tests: `Editor/Jumps.lean`

The model tests of `Editor/Jumps.lean`: `jumpChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The jump list of view 0 and where its cursor is, after the keys `keys`
of the jump checks (`jumpedFrom`). -/
def jumpsAfter (keys : String) : Option ((List String × Nat) × String) := do
  let driver ← jumpedFrom keys
  return (← jumpsOf driver, ← cursorOf driver)

/-- The lowercase marks of buffer 0 and whether the global mark `A` is still
set, after `Jumps.eraseRows` over rows `first` through `last` of a buffer
over `ab`, `cd` and `ef` whose marks `a`, `b` and `c` are on rows 0, 1 and
2 and whose global mark `A` is on row 1. -/
def erasedRows (first last : Nat) : Option (List Char × Bool) :=
  let start : TextM EditorState := do
    let state ← evilState "ab\ncd\nef" 0
    let text : TextId := ⟨0⟩
    let marks ←
      [('a', 0), ('b', 3), ('c', 7)].toArray.mapM fun (char, offset) => do
          return (char, ← text.mark (.anchor { offset, bias := .after }))
    let global ← text.mark (.anchor { offset := 4, bias := .after })
    return { state with
        buffers := state.buffers.modify 0 (·.map ({ · with marks }))
        remembered.globalMarks := #[('A', .held ⟨0⟩ global)] }
  let program : EditorM (List Char × Bool) := do
    Jumps.eraseRows ⟨0⟩ first last
    let state ← editorState
    return (((state.buffer? ⟨0⟩).map (·.marks.toList.map (·.1))).getD [],
        (state.globalMark? 'A').isSome)
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
        "entries that a deletion brought onto one line are one at the next move: the earlier is dropped, the cursor's place recorded, and the move lands on the later"
      run :=
        return jumpsAfter "C-j 1 C-j r C-j 2 C-j r C-j 4 C-j r C-j 5 C-j x C-j o" ==
            some ((["0@1:0", "0@2:0", "0@3:0"], 1), "0@2:0") },
    { name :=
        "a move past either end changes nothing: the list, its index and the cursor stay"
      run :=
        return jumpsAfter "C-j 2 C-j r C-j i" == some ((["0@2:0"], 1), "0@2:0") &&
            jumpsAfter "C-j 2 C-j r C-j 5 C-j o C-j o" ==
              some ((["0@2:0", "0@5:0"], 0), "0@2:0") },
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
        "opening a file records a jump when the load is delivered and when a buffer holds the path already, and switching buffers records one"
      run :=
        return (jumpsAfter "C-j 3 C-j n").map (·.1) == some (["0@3:0"], 1) &&
            (jumpsAfter "C-j 3 C-j n C-j b").map (·.1) == some (["0@3:0", "1@0:0"], 2) &&
            (jumpsAfter "C-j 3 C-j n C-j b C-j n").map (·.1) ==
              some (["0@3:0", "1@0:0", "0@0:0"], 3) },
    { name :=
        "a visit at a row's first non-blank puts the cursor there, when the load is delivered and when a buffer holds the path"
      run :=
        return (jumpsAfter "C-j v").map (·.2) == some "1@1:2" &&
            (jumpsAfter "C-j v C-j s C-j v").map (·.2) == some "1@1:2" },
    { name :=
        "a visit records one jump in each branch, and a visit that says not to records none in either"
      run :=
        return (jumpsAfter "C-j 4 C-j v").map (·.1) == some (["0@4:0"], 1) &&
            (jumpsAfter "C-j 4 C-j v C-j s C-j v").map (·.1) == some (["0@4:0", "0@0:0"], 2) &&
            jumpsAfter "C-j 4 C-j V" == some (([], 0), "1@1:2") &&
            jumpsAfter "C-j 4 C-j V C-j s C-j V" == some (([], 0), "1@1:2") },
    { name :=
        "erasing rows erases the buffer's lowercase marks on them and keeps its others and the global marks"
      run :=
        return erasedRows 1 2 == some (['a'], true) && erasedRows 0 0 == some (['b', 'c'], true) }]

end ModelTest
