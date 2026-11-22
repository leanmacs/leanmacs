import Editor.Test.Driver
import Editor.Test.Editing
import FilesApi
import WorkingSet.Places
import WorkingSetTest.Check
import WorkingSetTest.Support.WorkingSet

/-!
# Model tests: `WorkingSet/Places.lean`

The model tests of `WorkingSet/Places.lean`: `workingSetPlaceChecks`, on the
loop's driver over the editor's models and the job model. The test driver's
root, `WorkingSetTest/Model.lean`, runs them; its module doc says what each
shows.
-/

namespace WorkingSetTest

open Editor
open Editor.Test
open WorkingSetTest.Support

/-- A driver of the checks with `a.txt` open and its third line, `charlie
three`, held in the set `demo`, the store read when `read`. -/
def heldDriver (read : Bool := true) : Option TestDriver :=
  (driverWith).map fun driver =>
    invoked (opened driver "a.txt") "ws-hold" [.str "demo", .nat 20, .nat 33, .bool read]

/-- `driver` once a line `new` is opened above the first, and `big ` typed
before the third word of the line that was the third. -/
def heldEdited (driver : TestDriver) : TestDriver :=
  keysFed driver
    s!"C-<Home> {typed "new"} RET {toLine 4} {" ".intercalate (List.replicate 8 "<ArrowRight>")} {typed "big "}"

/-- The checks of where a working set's ranges are held
(`WorkingSet/Places.lean`), on the loop's driver over the models. -/
def workingSetPlaceChecks : List Check :=
  [{  name :=
        "a held range follows a line inserted before it and text typed inside it, through its markers"
      run :=
        pure <|
          match heldDriver with
          | none => false
          | some driver =>
            let before := (rangesOf driver "demo")[0]?.bind (heldText driver)
            let after :=
              (rangesOf (heldEdited driver) "demo")[0]?.bind (heldText (heldEdited driver))
            before == some "charlie three" && after == some "charlie big three" },
    { name :=
        "closing the buffer detaches the range with its stored form as edited: its quote, its context and its points"
      run :=
        pure <|
          match heldDriver with
          | none => false
          | some driver =>
            let saved := drained (invoked (heldEdited driver) FilesApi.saveName)
            let gone := closed saved "a.txt"
            match (rangesOf gone "demo")[0]? with
            | some range =>
              range.hold == .detached && range.stored.quote == "charlie big three" &&
                range.stored.path == "a.txt" &&
                range.stored.start == ⟨4, 1⟩ &&
                range.stored.stop == ⟨4, 18⟩ &&
                range.stored.before == "new\nalpha one\nbravo two\n" &&
                (gone.loop.state.findFile "/r/a.txt").isNone
            | none => false },
    { name := "opening the file again holds the range again, at its text"
      run :=
        pure <|
          match heldDriver with
          | none => false
          | some driver =>
            let saved := drained (invoked (heldEdited driver) FilesApi.saveName)
            let again := opened (closed saved "a.txt") "a.txt"
            match (rangesOf again "demo")[0]? with
            | some range =>
              (match range.hold with
                | .held buffer _ _ changed =>
                  again.loop.state.findFile "/r/a.txt" == some buffer && !changed
                | _ => false) &&
                heldText again range == some "charlie big three"
            | none => false },
    { name :=
        "opening the file again after another program removed the range's text leaves the range drifted, its stored form as it was"
      run :=
        pure <|
          match heldDriver with
          | none => false
          | some driver =>
            let gone := closed driver "a.txt"
            let storedBefore := (rangesOf gone "demo")[0]?.map (·.stored)
            let changed :=
              onDisk gone "a.txt" "alpha one\nbravo two\ndelta four\necho five\nfoxtrot six\n"
            let again := opened changed "a.txt"
            match (rangesOf again "demo")[0]? with
            | some range => range.hold == .drifted && some range.stored == storedBefore
            | none => false },
    { name :=
        "with the workspace's sets not read, opening the file attaches nothing: a detached range stays detached"
      run :=
        pure <|
          match heldDriver (read := false) with
          | none => false
          | some driver =>
            let gone := closed driver "a.txt"
            let again := opened gone "a.txt"
            (kept again).disk == .notRead && (rangesOf again "demo").map (·.hold) == #[.detached] }]

end WorkingSetTest
