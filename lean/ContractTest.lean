import Editor.Job.Contract
import Editor.Job.Pool
import Editor.Job.Real
import Editor.Text.Contract
import Editor.Text.Model
import Editor.Text.Real
import Editor.UndoTree.Cases

/-!
# The contract checks against the real bindings

The `contract-test` executable runs each port's contract against the port's
real binding, so against the Rust library: it is linked like `editor`, with
the glue object and the Rust archive. `model-test` runs the same lists
against the pure models. A property that holds of one and not of the other
fails one of the two, which is what keeps a model from drifting from the
library.

- The text port's contract (`Editor/Text/Contract.lean`) against its real
  binding (`Editor/Text/Real.lean`), and the properties of taking a job's
  snapshot into the store, each in a run handed snapshots the library made
  (`runHanded`). Beside them, what only the real binding can show, since it
  is about the library's objects and the binding's own table: that the
  binding's table is the only holder of its documents and of its snapshots,
  that releasing one frees it at once, and that the read half of its
  published table of snapshots finds what a command took and nothing a
  command released (`failures`, `releaseFrees`, `readerFinds`).
- The cases of the undo tree (`Editor/UndoTree/Cases.lean`), which is plain
  Lean over the text port, through the same binding and in the same run, so
  the count of live documents covers the texts they make. `model-test` runs
  them against the text model.
- The job port's contract (`Editor/Job/Contract.lean`) against the runner
  over the library's timer service, with the completion pump
  (`Editor/Job/Real.lean`). `model-test` runs it against the model and
  against the runner over the fake clock.

`jobChecks` then pins what only the real service can show: that a job in a
real wait holds no thread, that cancelling a job takes its timer out of the
library's schedule, that a deadline no machine word holds is not cut down,
and that the pump is not one of the pool's tasks.

`main` starts the pump once, on a dedicated task. When the checks are done
it quits the queues, requires the pump to have ended, and exits explicitly:
that is the shutdown sequence, and returning from `main` while a dedicated
task is blocked in the library would hang.

A check waits for what the library does with a bound, so a broken service
fails a check within seconds. Deadlines are an hour away where a wait must
not complete, and 0 to 3 ms where it must: no check sleeps to let something
happen.

No check knows how many threads Lean's pool has. That number is Lean's, and
`LEAN_NUM_THREADS` in the environment changes it, so `main` learns the
pool's threads by warming it before the pump starts, and the check of the
pump is stated relative to them.

`mise run ffi-test` runs it, in the gate. It names what did not hold and
exits non-zero if anything did not.
-/

namespace ContractTest

open Editor

/-- What must hold of the binding's tables once the contract has run. It is
not a property of the port, which has no way to say it: it is about the
library's objects, which only the real binding has. -/
def tableName : String :=
  "the real binding's table is the only holder of its documents and of its snapshots: they are all freed when it is dropped"

/-- What must hold of a release in the real binding. Like `tableName`, it is
about the library's objects, so the port cannot say it. -/
def releaseName : String :=
  "releasing a text or a snapshot frees the library's object at once, while the table is still held"

/-- Whether a release frees the library's object at once. A command makes two
texts and two snapshots and releases one of each; then, with the table it
left still held, the library must hold one document and one snapshot more
than before. -/
def releaseFrees : IO Bool := do
  let documents ← Ffi.Document.live
  let snapshots ← Ffi.Snapshot.live
  let command : EditorM Unit := do
    let kept ← createText "kept"
    let dropped ← createText "dropped"
    discard kept.snapshot
    let released ← kept.snapshot
    released.release
    dropped.release
  let (result, table) ← command.runReal (← RealTexts.new)
  let documentsHeld ← Ffi.Document.live
  let snapshotsHeld ← Ffi.Snapshot.live
  -- The table is read here, so it is alive until now. A released slot stays
  -- in it, empty.
  return result.isOk && documentsHeld == documents + 1 && snapshotsHeld == snapshots + 1 &&
      table.documents.size == 2 &&
      (← table.snapshots.size) == 2

/-- What must hold of the read half of the real binding's table of
snapshots, which is all a reader off the editor thread is given. It is about
the binding's own table, so the port cannot say it. -/
def readerName : String :=
  "a snapshot a command took is found through the read half of the binding's table by its id, and reads what the command read; one taken by a later command is found too; one a command released is not found, and neither is an id never given"

/-- Whether the read half of the table finds what the commands' own
questions read. One command takes two snapshots of a text with two- and
four-byte characters and an escape, at two revisions, and releases a third;
a second command, run on the table the first left, takes another. The reader
was made before either ran. -/
def readerFinds : IO Bool := do
  let snapshots ← Snapshots.new
  let reader := snapshots.reader
  let first : EditorM (TextId × SnapshotId × SnapshotId × SnapshotId × String) := do
    let text ← createText (TextContract.loaded)
    let early ← text.snapshot
    text.insert 0 "x"
    let released ← text.snapshot
    let late ← text.snapshot
    released.release
    return (text, early, late, released, ← late.read)
  let (.ok (text, early, late, released, read), table) ←
    first.runReal (.over snapshots) | return false
  let some foundEarly ← reader.find? early | return false
  let some foundLate ← reader.find? late | return false
  let gone ← reader.find? released
  let never ← reader.find? ⟨7⟩
  let (.ok later, _) ← text.snapshot.runReal table | return false
  let some foundLater ← reader.find? later | return false
  return (← foundEarly.read) == "héllo\r\n😀".push (Char.ofNat 0x10DCFF) &&
      (← foundLate.read) == read &&
      read == "xhéllo\r\n😀".push (Char.ofNat 0x10DCFF) &&
      (← foundLate.info).revision == 1 &&
      gone.isNone &&
      never.isNone &&
      (← foundLater.read) == read

/-- Runs `command` against the real binding, from a table with no texts, in
a run that is handed `arrived` as what a job held: for each, a snapshot the
library made of a document holding the string. The documents, the snapshots
and the table are dropped with the run. -/
def runHanded (arrived : Array (JobSnapshotId × String)) (command : EditorM Bool) :
    IO (Except TextError Bool) := do
  let handed ← arrived.mapM fun (id, text) => return (id, ← (← Ffi.Document.new text).snapshot)
  return (← command.runReal (← RealTexts.new) handed).1

/-- Runs `properties` against the real binding, each from a table with no
texts, and then `adoptProperties`, each in a run handed its snapshots
(`runHanded`), and returns the names of those that did not hold. Each table
is dropped with its run, and so is what a run was handed, so the counts of
live documents and of live snapshots must then be what they were before: if
either is not, `tableName` is among the names. `releaseName` is among them
if a release did not free its object at once. -/
def failures (properties : List TextContract.Property)
    (adoptProperties : List TextContract.AdoptProperty) : IO (List String) := do
  let before := (← Ffi.Document.live, ← Ffi.Snapshot.live)
  let held ←
    TextContract.failures (fun command => return (← command.runReal (← RealTexts.new)).1) properties
  let failed := held ++ (← TextContract.adoptFailures runHanded adoptProperties)
  let released ← releaseFrees
  let found ← readerFinds
  let after := (← Ffi.Document.live, ← Ffi.Snapshot.live)
  return failed ++ (if released then [] else [releaseName]) ++
      (if found then [] else [readerName]) ++
      if after == before then []
      else
        [s!"{tableName} ({before.1} documents and {before.2} snapshots before, {after.1} and {after.2} after)"]

/-- How long a check waits, in milliseconds, for something that should happen
at once. Only broken code takes this long, and the check then fails instead
of hanging. -/
def patience : Nat :=
  5000

/-- Polls `condition` until it holds; `false` if it still does not after
`patience` milliseconds. -/
def eventually (condition : IO Bool) : IO Bool := do
  let deadline := (← IO.monoMsNow) + patience
  repeat
    if ← condition then
      return true
    if (← IO.monoMsNow) >= deadline then
      break
    IO.sleep 1
  return false

/-- An hour, in milliseconds: how long a job sleeps when its wait must not
complete while a check runs. -/
def hour : Nat :=
  3600000

/-- A job's outcome as a check compares it: the command it finished with is
replaced by the texts that command leaves when it runs against the text
model, since commands cannot be compared. -/
def texts : Job.Outcome (EditorM Unit) → Job.Outcome (Array String)
  | .finished command => .finished (command.runModel {}).2.contents
  | .failed message => .failed message
  | .cancelled => .cancelled

/-- `job` as it is spawned by a check: it finishes with a command that makes
one text, the job's value as a string. -/
def reporting {α : Type} [ToString α] (job : Unit → JobM α) : Work :=
  Work.of job fun value => discard <| createText (toString value)

/-- Whether the job behind `handle` ended as `expected`, within the bound. -/
def endedAs (handle : Job.Handle) (expected : Job.Outcome (Array String)) : IO Bool := do
  let ended ← eventually handle.ended
  return ended && (← handle.outcome?).map texts == some expected

/-- Runs `job` on the runner over the library's timer service, and returns
how it ended. A job that does not end in time has failed, and is cancelled. -/
def runOnTimers (services : Job.Services) (job : JobM Bool) : IO (Job.Outcome Bool) := do
  let handle ← Job.spawn services (reporting fun _ => job) (pure ())
  unless ← eventually handle.ended do
    handle.cancel
    return .failed "the job did not end"
  match (← handle.outcome?).map texts with
  | some (.finished texts) =>
    return .finished (texts == #["true"])
  | some (.failed message) =>
    return .failed message
  | _ =>
    return .cancelled

/-- The names of the job port's contract properties that do not hold of the
runner over the library's timer service. -/
def jobFailures (services : Job.Services) : IO (List String) := do
  let failed ← JobContract.failures (runOnTimers services) JobContract.properties
  return failed.map (s!"the job runner over the timer service: {·}")

/-- One behaviour, and how to observe it. -/
structure Check where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Observes the behaviour; `true` when it holds. -/
  run : IO Bool

/-- `count` jobs that each sleep for an hour. -/
def sleepers (services : Job.Services) (count : Nat) : IO (Array Job.Handle) := do
  let mut jobs := #[]
  for _ in [0:count] do
    jobs :=
      jobs.push
        (←
          Job.spawn services
              (reporting fun _ => do
                sleep hour
                return true)
              (pure ()))
  return jobs

/-- How long a warming waits, in milliseconds, for a task to start before it
takes the pool to be full. A task starts on a free thread in microseconds. -/
def warmPatience : Nat :=
  200

/-- The checks of the runner over the library's timer service
(`Editor/Job/Real.lean`): what only the real service can show. It is a
function, not a constant, because it calls bindings.

`pool` is the threads the pool was seen to have before the pump was started
(`Pool.whole`). No check knows the pool's size otherwise: that number is
Lean's, and `LEAN_NUM_THREADS` changes it. -/
def jobChecks (services : Job.Services) (pool : Array UInt64) : List Check :=
  -- More jobs than the pool has threads, and at least 64.
  let many := max 64 (pool.size + 1)
  [{
      name :=
        "jobs in real waits do not delay a new pool task: more jobs than the pool has threads all have a timer in the library while a new pool task runs",
      run := do
        let before ← Ffi.timersPending
        let jobs ← sleepers services many
        try
          -- Each job's timer is in the library's schedule, so every job has
          -- reached its wait.
          unless ← eventually (return (← Ffi.timersPending) == before + many.toUInt64) do
            return false
          let ran ← IO.Promise.new
          discard <| BaseIO.asTask (ran.resolve ())
          let notDelayed ← eventually ran.isResolved
          let allWaiting := (← Ffi.timersPending) == before + many.toUInt64
          let noneEnded ← jobs.allM fun job => return !(← job.ended)
          return notDelayed && allWaiting && noneEnded
        finally
          for job in jobs do
            job.cancel },
    { name :=
        "cancelling a job withdraws its timer: each job ends cancelled, and the library's schedule is back to what it held"
      run := do
        let before ← Ffi.timersPending
        let jobs ← sleepers services many
        try
          unless ← eventually (return (← Ffi.timersPending) == before + many.toUInt64) do
            return false
          for job in jobs do
            job.cancel
          let allCancelled ← jobs.allM (endedAs · .cancelled)
          return allCancelled && (← Ffi.timersPending) == before &&
              (← services.completions.waiting) == 0
        finally
          for job in jobs do
            job.cancel },
    { name :=
        "a deadline no machine word holds is not cut down: a job that waits for it is still waiting when a job that sleeps for nothing has finished"
      run := do
        let before ← Ffi.timersPending
        -- Cut down to a 64-bit word, `2 ^ 64 + 1` is 1: a deadline in the
        -- past, which the service would complete at once.
        let far ←
          Job.spawn services
              (reporting fun _ => do
                waitUntil (2 ^ 64 + 1)
                return true)
              (pure ())
        try
          unless ← eventually (return (← Ffi.timersPending) == before + 1) do
            return false
          let short ←
            Job.spawn services
                (reporting fun _ => do
                  sleep 0
                  return true)
                (pure ())
          let shortFinished ← endedAs short (.finished #["true"])
          -- The timers complete in the order of their deadlines, so had the
          -- far one been due it would have left the schedule first.
          let stillWaiting := (← Ffi.timersPending) == before + 1 && !(← far.ended)
          far.cancel
          return shortFinished && stillWaiting && (← endedAs far .cancelled)
        finally
          far.cancel },
    { name :=
        "a wait the timer service refuses ends the job as cancelled: it does not wait for ever"
      run := do
        -- Ids are a counter, so the id the job's wait will get is known: a
        -- timer that already has it makes the service refuse the job's.
        let (reserved, _) ← services.completions.register
        let taken := reserved + 1
        try
          unless ← Ffi.timersStart taken ((← Ffi.timersNow) + hour.toUInt64) do
            return false
          let jobs ← sleepers services 1
          let ended ← jobs.allM (endedAs · .cancelled)
          return ended && (← services.completions.waiting) == 1
        finally
          discard <| Ffi.timersCancel taken
          services.completions.finish reserved .cancelled },
    { name :=
        "the pump is not one of the pool's tasks: with the pump parked in its pull, every thread the pool had before the pump was started is still free to be held, and no other"
      run := do
        unless ← eventually (return (← Ffi.waiting .completion) == 1) do
          return false
        -- A pump that was a pool task would be parked on one of these
        -- threads, and the warming would stop one short.
        let threads ← Job.Pool.warm (pool.size + 2) warmPatience
        return !pool.isEmpty && threads.size == pool.size && threads.all pool.contains }]

/-- Runs `checks` and returns the names of those that failed. A check that
throws has failed, and its error is reported with its name. -/
def checkFailures (checks : List Check) : IO (List String) :=
  checks.filterMapM fun check => do
    try
      return if ← check.run then none else some check.name
    catch error =>
      return some s!"{check.name} ({error})"

end ContractTest

/-- Runs the text port's contract against its real binding, then the job
port's contract and the job checks against the runner over the library's
timer service, then shuts down: exits 0 when everything holds, and 1 after
naming on stderr what does not.

The pool's threads are learnt first, by warming it, before anything else
runs: the check that the pump is not one of the pool's tasks compares
against them. Then the completion pump runs on a dedicated task for the rest
of the run. Shutdown is quit, which must end the pump, then an explicit
exit: a task that failed a check may still be blocked in the library. -/
def main : IO UInt32 := do
  let pool ← Editor.Job.Pool.whole ContractTest.warmPatience
  let completions ← Editor.Job.Completions.new
  let services : Editor.Job.Services := { completions, timers := Editor.Job.realTimers completions }
  let pump ← IO.asTask (prio := .dedicated) (Editor.Job.pump completions)
  let properties := Editor.TextContract.properties
  -- The undo tree's cases run through the same binding, so the count of
  -- live documents covers the texts they make too.
  let cases := Editor.UndoTreeCases.cases
  let adoptProperties := Editor.TextContract.adoptProperties
  let textFailed ← ContractTest.failures (properties ++ cases) adoptProperties
  let jobFailed ← ContractTest.jobFailures services
  let checks := ContractTest.jobChecks services pool
  let checkFailed ← ContractTest.checkFailures checks
  Editor.Ffi.quit
  let pumpEnded ← ContractTest.eventually (IO.hasFinished pump)
  let failed :=
    textFailed.map (s!"the real text binding: {·}") ++ jobFailed ++ checkFailed ++
      if pumpEnded then [] else ["quit ends the completion pump"]
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  unless failed.isEmpty do
    IO.Process.exit 1
  IO.println
      s!"contract-test: {properties.length + adoptProperties.length} properties hold of the real text binding, {cases.length} cases of the undo tree hold over it, and its documents and snapshots are freed when released and with its table; {Editor.JobContract.properties.length} properties hold of the job runner over the timer service, {checks.length} checks of it passed, and quit ended the pump"
  (← IO.getStdout).flush
  IO.Process.exit 0
