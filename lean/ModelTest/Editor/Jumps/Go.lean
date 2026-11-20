import ModelTest.Check
import ModelTest.Support.Jumps

/-!
# Model tests: `Editor/Jumps/Go.lean`

The model tests of `Editor/Jumps/Go.lean`: `jumpGoChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The checks of moving through a window's jump list to a place in another
buffer or in a closed file, and of going to a place as a jump, on the
loop's driver over the editor's models and the file model
(`jumpDriver`). -/
def jumpGoChecks : List Check :=
  [{  name := "a move onto an entry of another open buffer shows that buffer, at the entry"
      run :=
        return (jumpedFrom "C-j 3 C-j n C-j o").map (fun driver => (jumpsOf driver, cursorOf driver)) ==
            some (some (["0@3:0", "1@0:0"], 0), some "0@3:0") &&
          (jumpedFrom "C-j 3 C-j n C-j o C-j i").map (cursorOf ·) == some (some "1@0:0") },
    { name :=
        "a move onto a closed buffer's entry moves the index at once and visits its file, and once the load is delivered the cursor is at the entry's row and column, held again"
      run :=
        let before := jumpDriver.map fun driver =>
          (fedTo (jumped driver "C-j n C-j 2 C-j w C-j r C-j k") (presses "C-j o")).1
        return before.map (fun driver => ((jumpsOf driver).map (·.2), cursorOf driver)) ==
              some (some 1, some "0@0:0") &&
            (jumpedFrom "C-j n C-j 2 C-j w C-j r C-j k C-j o").map
                (fun driver => (jumpsOf driver, cursorOf driver)) ==
              some (some (["0@0:0", "2@2:2", "0@0:0"], 1), some "2@2:2") },
    { name :=
        "C-o onto a closed file's entry records nothing when the load lands: the list holds the step's own record alone, the index stays on the entry, and the next C-o lands on the entry before"
      run :=
        let keys := "C-j 1 C-j r C-j 2 C-j n C-j 3 C-j r C-j s C-j K"
        return (jumpedFrom keys).map jumpsOf ==
              some (some (["0@1:0", "0@2:0", s!"{jumpsPath}@3:0"], 3)) &&
            (jumpedFrom (keys ++ " C-j o")).map (fun driver => (jumpsOf driver, cursorOf driver)) ==
              some (some (["0@1:0", "0@2:0", "2@3:0", "0@0:0"], 2), some "2@3:0") &&
            (jumpedFrom (keys ++ " C-j o C-j o")).map
                (fun driver => (jumpsOf driver, cursorOf driver)) ==
              some (some (["0@1:0", "0@2:0", "2@3:0", "0@0:0"], 1), some "0@2:0") },
    { name :=
        "going to a closed file's place as a jump records exactly one entry, where the cursor was, and none when the load lands"
      run :=
        return (jumpedFrom "C-j 5 C-j t").map (fun driver => (jumpsOf driver, cursorOf driver)) ==
            some (some (["0@5:0"], 1), some "1@1:0") }]

end ModelTest
