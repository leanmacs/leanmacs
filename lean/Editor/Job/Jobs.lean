import Editor.Job.Runner
import Editor.Job.Table

/-!
# The jobs a runtime is running

The shell over the job table (`Editor/Job/Table.lean`) and the runner
(`Editor/Job/Runner.lean`): what the editor thread calls to start a job, to
take the result of one that has ended, and to remove an owner. The headless
host calls these (`Editor/Headless.lean`): the command loop holds no job
table, and hands the jobs its commands ask for back to its host to start
(`Editor/Loop.lean`, "Jobs from commands").

A `Jobs` is a value the editor thread holds. Every operation here runs on
that thread, so there is no race to close: a job is in the table from the
moment it is started until its result is taken or its owner is removed.

- **`start`** spawns the job and adds it to the table, with its owner. The
  runtime hands in what the runner is to do when the job has ended, given
  the job's id: post a wake-up to the editor queue.
- **`finish`** takes the result of a job that has ended. It finds nothing
  for an id that is not in the table, and leaves a job that is still running
  where it is.
- **`removeOwner`** takes an owner's jobs out of the table and cancels each
  one. A job of that owner that ends afterwards, or had already ended and
  was waiting for the editor thread, has no entry, so `finish` finds nothing
  and no handler runs for it.
- **`cancelAll`** cancels every job, for a runtime that is ending.
- **What a job holds is released.** A job that finished holds what its
  loads made until its command has run (`Editor/Job/Runner.lean`, "What a
  job holds"): whoever takes its result with `finish` runs the command and
  then calls `Handle.settle`. `removeOwner` and `cancelAll` settle each job
  themselves, since the command of a job they remove never runs.
-/

namespace Editor.Job

/-- The jobs a runtime is running. -/
structure Jobs where
  /-- What the jobs' waits are made of. -/
  services : Services
  /-- The jobs, with their owners. -/
  table : Table Handle := {}

namespace Jobs

/-- How many jobs are in the table: started, and neither taken nor removed. -/
def running (jobs : Jobs) : Nat :=
  jobs.table.entries.size

/-- Starts `work` for `owner`, under `name`: its id, and the jobs with it.
`finished` is what the runner calls, with that id, once the job has ended. -/
def start (jobs : Jobs) (owner : Config.Owner) (name : String) (work : Work)
    (finished : Nat → BaseIO Unit) : BaseIO (Nat × Jobs) := do
  let handle ← spawn jobs.services work (finished jobs.table.next)
  let (id, table) := jobs.table.add owner name handle
  return (id, { jobs with table })

/-- Takes the job `id`, which has ended: its entry and how it ended, and the
jobs without it. `none`, with nothing changed, if `id` is not in the table
or the job is still running. It never blocks. -/
def finish (jobs : Jobs) (id : Nat) :
    BaseIO (Option (Entry Handle × Outcome (EditorM Unit)) × Jobs) := do
  let (entry?, table) := jobs.table.take id
  let some entry := entry? | return (none, jobs)
  let some outcome ← entry.handle.outcome? | return (none, jobs)
  return (some (entry, outcome), { jobs with table })

/-- Removes `owner`: takes its jobs out of the table, cancels each one and
releases what it holds. Returns those jobs, oldest first, and the jobs
without them. -/
def removeOwner (jobs : Jobs) (owner : Config.Owner) : BaseIO (Array (Entry Handle) × Jobs) := do
  let (removed, table) := jobs.table.removeOwner owner
  for entry in removed do
    entry.handle.cancel
    -- A job that had finished holds what its loads made for a command that
    -- will now never run. One that is still running settles itself when it
    -- ends cancelled, and this finds nothing of it to release.
    entry.handle.settle
  return (removed, { jobs with table })

/-- Cancels the job `id`: takes it out of the table, cancels it and releases
what it holds, as `removeOwner` does for each of an owner's jobs. A job that
had finished and was waiting for the editor thread has no entry after this,
so `finish` finds nothing and its command never runs. Nothing for an id
that is not in the table. -/
def cancel (jobs : Jobs) (id : Nat) : BaseIO Jobs := do
  let (entry?, table) := jobs.table.take id
  if let some entry := entry? then
    entry.handle.cancel
    entry.handle.settle
  return { jobs with table }

/-- Cancels every job in the table and releases what each holds: for a
runtime that is ending, which will deal with no more results. -/
def cancelAll (jobs : Jobs) : BaseIO Unit := do
  for entry in jobs.table.entries do
    entry.handle.cancel
    entry.handle.settle

end Jobs

end Editor.Job
