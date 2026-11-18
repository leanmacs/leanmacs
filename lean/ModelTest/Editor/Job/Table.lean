import Editor.Config.Owner
import Editor.Job.Table
import ModelTest.Check
import ModelTest.Support.Jobs

/-!
# Model tests: `Editor/Job/Table.lean`

The model tests of `Editor/Job/Table.lean`: `tableChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- An entry of a job table as a check compares it: its id, its owner's name,
its name and its handle. -/
def row (entry : Job.Entry String) : Nat × String × String × String :=
  (entry.id, entry.owner.name, entry.name, entry.handle)

/-- The checks of the job table (`Editor/Job/Table.lean`), which is pure:
here a job's handle is a string. -/
def tableChecks : List Check :=
  [{ name := "a job table gives each job an id of its own, and never uses an id again",
     run :=
       let (first, table) := ({} : Job.Table String).add anna "one" "h1"
       let (second, table) := table.add ben "two" "h2"
       let (_, table) := table.take second
       let (third, table) := table.add anna "three" "h3"
       pure
         ([first, second, third].eraseDups.length == 3 &&
           table.entries.map row ==
             #[(first, "anna", "one", "h1"), (third, "anna", "three", "h3")]) },
    { name := "take returns a job once, and nothing for an id that is not in the table"
      run :=
        let (id, table) := ({} : Job.Table String).add anna "one" "h1"
        let (kept, table) := table.add ben "two" "h2"
        let (taken, table) := table.take id
        let (again, table) := table.take id
        let (never, table) := table.take 99
        pure
          (taken.map row == some (id, "anna", "one", "h1") && again.isNone && never.isNone &&
            table.entries.map row == #[(kept, "ben", "two", "h2")]) },
    { name := "removeOwner returns exactly that owner's jobs and leaves the others"
      run :=
        let (first, table) := ({} : Job.Table String).add anna "one" "h1"
        let (second, table) := table.add ben "two" "h2"
        let (third, table) := table.add anna "three" "h3"
        let (removed, table) := table.removeOwner anna
        let (nothing, same) := table.removeOwner anna
        pure
          (removed.map row == #[(first, "anna", "one", "h1"), (third, "anna", "three", "h3")] &&
            table.entries.map row == #[(second, "ben", "two", "h2")] &&
            nothing.isEmpty &&
            same.entries.size == 1) },
    { name := "take after removeOwner finds nothing: a job whose owner is gone has no entry left"
      run :=
        let (id, table) := ({} : Job.Table String).add anna "one" "h1"
        let (_, table) := table.removeOwner anna
        pure (table.take id).1.isNone }]

end ModelTest
