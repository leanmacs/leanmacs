import Editor.Test.Hosted
import FilesApi
import ModelTest.Check
import ModelTest.Support.JumpsGo

/-!
# Model tests: `Editor/Jumps/Go.lean`

The model tests of `Editor/Jumps/Go.lean`: `jumpGoChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The jump list of view 0 and where its cursor is, after the keys `keys`
of the jump checks of the files feature (`goJumpedFrom`). -/
def goJumpsAfter (keys : String) : Option ((List String × Nat) × String) := do
  let driver ← goJumpedFrom keys
  return (← jumpsOf driver, ← cursorOf driver)

/-- The checks of moving through a window's jump list to a place in another
buffer or in a closed file, and of going to a place as a jump, on the
loop's driver over the editor's models and the file model
(`goDriver`). -/
def jumpGoChecks : List Check :=
  [{  name :=
        "a move onto an entry of another open buffer shows that buffer, at the entry"
      run :=
        return (goJumpedFrom "C-j 3 C-j n C-j o").map (fun driver => (jumpsOf driver, cursorOf driver)) ==
            some (some (["0@3:0", "1@0:0"], 0), some "0@3:0") &&
          (goJumpedFrom "C-j 3 C-j n C-j o C-j i").map (cursorOf ·) == some (some "1@0:0") },
    { name :=
        "a move onto a closed buffer's entry moves the index at once and visits its file, and once the load is delivered the cursor is at the entry's row and column, held again"
      run :=
        let before := goDriver.map fun driver =>
          (fedTo (goJumped driver "C-j n C-j 2 C-j w C-j r C-j k") (presses "C-j o")).1
        return before.map (fun driver => ((jumpsOf driver).map (·.2), cursorOf driver)) ==
              some (some 1, some "0@0:0") &&
            (goJumpedFrom "C-j n C-j 2 C-j w C-j r C-j k C-j o").map
                (fun driver => (jumpsOf driver, cursorOf driver)) ==
              some (some (["0@0:0", "2@2:2", "0@0:0"], 1), some "2@2:2") },
    { name :=
        "C-o onto a closed file's entry records nothing when the load lands: the list holds the step's own record alone, the index stays on the entry, and the next C-o lands on the entry before"
      run :=
        let keys := "C-j 1 C-j r C-j 2 C-j n C-j 3 C-j r C-j s C-j K"
        return (goJumpedFrom keys).map jumpsOf ==
              some (some (["0@1:0", "0@2:0", s!"{jumpsPath}@3:0"], 3)) &&
            (goJumpedFrom (keys ++ " C-j o")).map (fun driver => (jumpsOf driver, cursorOf driver)) ==
              some (some (["0@1:0", "0@2:0", "2@3:0", "0@0:0"], 2), some "2@3:0") &&
            (goJumpedFrom (keys ++ " C-j o C-j o")).map
                (fun driver => (jumpsOf driver, cursorOf driver)) ==
              some (some (["0@1:0", "0@2:0", "2@3:0", "0@0:0"], 1), some "0@2:0") },
    { name :=
        "going to a closed file's place as a jump records exactly one entry, where the cursor was, and none when the load lands"
      run :=
        return (goJumpedFrom "C-j 5 C-j t").map (fun driver => (jumpsOf driver, cursorOf driver)) ==
            some (some (["0@5:0"], 1), some "1@1:0") },
    { name :=
        "entries that a deletion brought onto one line are one at the next move: the earlier is dropped, the cursor's place recorded, and the move lands on the later"
      run :=
        return goJumpsAfter "C-j 1 C-j r C-j 2 C-j r C-j 4 C-j r C-j 5 C-j x C-j o" ==
            some ((["0@1:0", "0@2:0", "0@3:0"], 1), "0@2:0") },
    { name :=
        "a move past either end changes nothing: the list, its index and the cursor stay"
      run :=
        return goJumpsAfter "C-j 2 C-j r C-j i" == some ((["0@2:0"], 1), "0@2:0") &&
            goJumpsAfter "C-j 2 C-j r C-j 5 C-j o C-j o" ==
              some ((["0@2:0", "0@5:0"], 0), "0@2:0") },
    { name :=
        "opening a file records a jump when the load is delivered and when a buffer holds the path already, and switching buffers records one"
      run :=
        return (goJumpsAfter "C-j 3 C-j n").map (·.1) == some (["0@3:0"], 1) &&
            (goJumpsAfter "C-j 3 C-j n C-j b").map (·.1) == some (["0@3:0", "1@0:0"], 2) &&
            (goJumpsAfter "C-j 3 C-j n C-j b C-j n").map (·.1) ==
              some (["0@3:0", "1@0:0", "0@0:0"], 3) },
    { name :=
        "a visit at a row's first non-blank puts the cursor there, when the load is delivered and when a buffer holds the path"
      run :=
        return (goJumpsAfter "C-j v").map (·.2) == some "1@1:2" &&
            (goJumpsAfter "C-j v C-j s C-j v").map (·.2) == some "1@1:2" },
    { name :=
        "a visit records one jump in each branch, and a visit that says not to records none in either"
      run :=
        return (goJumpsAfter "C-j 4 C-j v").map (·.1) == some (["0@4:0"], 1) &&
            (goJumpsAfter "C-j 4 C-j v C-j s C-j v").map (·.1) == some (["0@4:0", "0@0:0"], 2) &&
            goJumpsAfter "C-j 4 C-j V" == some (([], 0), "1@1:2") &&
            goJumpsAfter "C-j 4 C-j V C-j s C-j V" == some (([], 0), "1@1:2") },
    { name :=
        "with no files implementation, going to a closed file's place as a jump says so, records the jump, starts no load and leaves the view where it was"
      run :=
        let bare := goDriver.map fun driver =>
          { driver with keys := withoutExtension FilesApi.Files driver.keys }
        let gone := bare.map (goJumped · "C-j 5 C-j t")
        return gone.map (fun driver => (driver.loop.state.echo, driver.pending.size)) ==
              some (FilesApi.noImplementation "jump", 0) &&
            gone.map (fun driver => (jumpsOf driver, cursorOf driver)) ==
              some (some (["0@5:0"], 1), some "0@5:0") }]

end ModelTest
