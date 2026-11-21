import Editor.Job.Runner

/-!
# The contract of the services' flush

What every port of the job runner's services does with a flush
(`Timers.flush`, `Files.flush`, `Processes.flush`, `FileWatches.flush`,
`Diffs.flush`, `Editor/Job/Runner.lean`), as a list of properties of its own:
a flush is not a job request, so it is not in the job port's contract
(`Editor/Job/Contract.lean`). Each property runs on a `FlushRig`, which says
how to flush one port and, where the port can hold work, how to start work
the service cannot finish until the rig lets it go. The same list runs two
ways:

- against the fakes (`Editor/Job/Fake.lean`), by `model-test`
  (`ModelTest.flushContractChecks`): the files and the diffs held by the fake
  file service's held completions, the processes by the fake process
  service's, and the clock, the watches and the searches idle;
- against the real ports over the Rust library (`Editor/Job/Real.lean`), by
  `contract-test` (`ContractTest.flushContractChecks`): the files held by the
  file service's in-process hold, the processes by a child only a cancel
  ends, and the clock, the watches, the diffs and the searches idle. A
  search held in its walk is the grep service's own unit tests' (`editor-grep`,
  `a_flush_is_completed_only_once_a_cancelled_searchs_thread_has_returned`).

**A deadline here is a hang guard, never a result**: a flush is awaited with
`Job.awaitWithin`, and one that has not ended within `patience` is reported
as a hang. That a flush has *not* ended while its work is held is read once,
with `IO.hasFinished`, while the rig holds that work: nothing the flush
waits for can end then, so a flush that ends at its call, or ahead of the
work, is seen every time.

This module imports only the runner's ports. The list is plain data, so it
is a constant: nothing in it calls a service when the module is initialised.
-/

namespace Editor.FlushContract

open Editor.Job

/-- hang guard: the flush's end, which must come once the work before it has
ended; only a hang reaches the bound, and the property then fails as a
hang. How long a property waits for it, in milliseconds. -/
def patience : Nat :=
  10000

/-- One port's flush, as the contract runs it. -/
structure FlushRig where
  /-- Which port, as a failure names it. -/
  name : String
  /-- Flushes the port: the task that ends with the flush's wait. -/
  flush : BaseIO (Task Completion)
  /-- Starts work the service cannot finish until the rig lets it go, and
  gives back how to let it go and whether that work has ended; none for a
  port the rig cannot hold. -/
  held : Option (IO (IO Unit × IO Bool)) := none
  /-- hang guard: the flush's end; only a hang reaches it, and the property
  then fails as a hang. `patience`, but for a check that a flush that never
  ends is reported as a hang, which runs it out on purpose. -/
  patience : Nat := patience

/-- One property of a flush: whether it holds on a rig, or why not, thrown. -/
structure Property where
  /-- What must hold, as a sentence. -/
  name : String
  /-- Observes it on a rig. -/
  holds : FlushRig → IO Bool

/-- What a flush came to within `waited` milliseconds, said for a failure. -/
def said (waited : Nat) : Option Completion → String
  | some .completed => "completed"
  | some .cancelled => "cancelled"
  | none => s!"a hang: it had not ended within {waited} ms"

/-- An idle service's flush is completed. -/
def idle : Property where
  name := "a flush of an idle service is completed"
  holds rig := do
    let ended ← awaitWithin rig.patience (← rig.flush)
    unless ended == some .completed do
      throw <| IO.userError s!"the flush came to {said rig.patience ended}"
    return true

/-- With work the service cannot finish held, a flush has not ended; once the
work is let go, the flush is completed, and the work has ended by then. A
rig that cannot hold work keeps it trivially. -/
def heldBehind : Property where
  name :=
    "a flush asked behind held work has not ended while it is held, and is completed once it is let go, the work ended by then"
  holds rig := do
    let some held := rig.held | return true
    let (release, ended) ← held
    let flushed ← rig.flush
    let early ← IO.hasFinished flushed
    release
    let outcome ← awaitWithin rig.patience flushed
    let workEnded ← ended
    unless !early && outcome == some .completed && workEnded do
      throw <|
          IO.userError
            s!"the flush had {if early then "ended" else "not ended"} while the work was held, then came to {said rig.patience outcome}, and the work had {if workEnded then "ended" else "not ended"}"
    return true

/-- Every property, in the order they run. -/
def properties : List Property :=
  [idle, heldBehind]

/-- Runs every property on each of `rigs`, and returns the failures, each
named `<rig>: <property>`, with what it saw. -/
def failures (rigs : List FlushRig) : IO (List String) := do
  let mut failed := []
  for rig in rigs do
    for property in properties do
      let name := s!"{rig.name}: {property.name}"
      try
        unless ← property.holds rig do
          failed := failed ++ [name]
      catch error =>
        failed := failed ++ [s!"{name} ({error})"]
  return failed

end Editor.FlushContract
