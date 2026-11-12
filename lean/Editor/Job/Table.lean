import Editor.Config.Owner

/-!
# The job table

Which jobs are running, and for whom. The table is pure: an entry is a job's
id, its owner, its name and a handle of a type the runtime chooses, so the
model tests run it with strings for handles (`ModelTest.tableChecks`) and
the runtime with the runner's handles (`Editor/Job/Jobs.lean`).

- **Every job has an owner** (`Editor/Config/Owner.lean`): `add` takes one,
  and there is no other way in.
- **An id is a counter from 1** and is never used again in a table.
- **A job's result is taken with `take`**, which removes the entry and finds
  nothing for an id that is not there. So once an owner's jobs are removed
  with `removeOwner`, a job of that owner that ends later has no entry, and
  nothing can be done with its result.
-/

namespace Editor.Job

/-- A running job, as the table holds it. -/
structure Entry (η : Type) where
  /-- The job's id in its table. -/
  id : Nat
  /-- Who the job runs for. -/
  owner : Config.Owner
  /-- What the job is called, for whoever shows it. -/
  name : String
  /-- The job itself, as the runtime holds it. -/
  handle : η

/-- The jobs that are running, oldest first. -/
structure Table (η : Type) where
  /-- The id of the next job. -/
  next : Nat := 1
  /-- The jobs. -/
  entries : Array (Entry η) := #[]

namespace Table

variable {η : Type}

/-- Adds a job of `owner`: its id, and the table with it. -/
def add (table : Table η) (owner : Config.Owner) (name : String) (handle : η) : Nat × Table η :=
  (table.next,
    { next := table.next + 1,
      entries := table.entries.push { id := table.next, owner, name, handle } })

/-- Takes the job `id` out of the table: its entry, or `none` if it is not
there, and the table without it. -/
def take (table : Table η) (id : Nat) : Option (Entry η) × Table η :=
  (table.entries.find? (·.id == id), { table with entries := table.entries.filter (·.id != id) })

/-- Takes every job of `owner` out of the table: their entries, oldest first,
and the table without them. -/
def removeOwner (table : Table η) (owner : Config.Owner) : Array (Entry η) × Table η :=
  (table.entries.filter (·.owner == owner),
    { table with entries := table.entries.filter (·.owner != owner) })

end Table

end Editor.Job
