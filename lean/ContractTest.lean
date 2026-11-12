import Editor.Job.Contract
import Editor.Job.Pool
import Editor.Job.Real
import Editor.Text.Contract
import Editor.Text.Model
import Editor.Text.Real

/-!
# The contract checks against the real bindings

The `contract-test` executable runs each port's contract against the port's
real binding, so against the Rust library: it is linked like `editor`, with
the glue object and the Rust archive. `model-test` runs the same lists
against the pure models. A property that holds of one and not of the other
fails one of the two, which is what keeps a model from drifting from the
library.

- The text port's contract (`Editor/Text/Contract.lean`) against its real
  binding (`Editor/Text/Real.lean`).
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

`mise run ffi-test` runs it, in the gate, with `LEAN_NUM_THREADS` removed
from its environment: one check measures the pool. It names what did not
hold and exits non-zero if anything did not.
-/

namespace ContractTest

open Editor

/-- What must hold of the binding's table of texts once the contract has run.
It is not a property of the port, which has no way to say it: it is about the
library's objects, which only the real binding has. -/
def tableName : String :=
  "the real binding's table is the only holder of its documents: they are all freed when it is dropped"

/-- Runs `properties` against the real binding, each from a table with no
texts, and returns the names of those that did not hold. Each table is dropped
with its run, so the count of live documents must then be what it was before:
if it is not, `tableName` is among the names. -/
def failures (properties : List TextContract.Property) : IO (List String) := do
  let before ← Ffi.Document.live
  let failed ← TextContract.failures (fun command => return (← command.runReal #[]).1) properties
  let after ← Ffi.Document.live
  return if after == before then failed
    else failed ++ [s!"{tableName} ({before} before, {after} after)"]

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
  | .finished command => .finished (command.runModel {}).2.texts
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

/-- More jobs than the pool has threads, and at least 64. -/
def many : Nat :=
  max 64 (Job.Pool.size + 1)

/-- The checks of the runner over the library's timer service
(`Editor/Job/Real.lean`): what only the real service can show. It is a
function, not a constant, because it calls bindings. -/
def jobChecks (services : Job.Services) : List Check :=
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
        "the pump is not one of the pool's tasks: with the pump parked in its pull, every thread of the pool is free to be held"
      run := do
        unless ← eventually (return (← Ffi.waiting .completion) == 1) do
          return false
        let threads ← Job.Pool.warm Job.Pool.size 2000
        return threads.size == Job.Pool.size }]

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

The completion pump runs on a dedicated task from the start. Shutdown is
quit, which must end the pump, then an explicit exit: a task that failed a
check may still be blocked in the library. -/
def main : IO UInt32 := do
  let completions ← Editor.Job.Completions.new
  let services : Editor.Job.Services := { completions, timers := Editor.Job.realTimers completions }
  let pump ← IO.asTask (prio := .dedicated) (Editor.Job.pump completions)
  let properties := Editor.TextContract.properties
  let textFailed ← ContractTest.failures properties
  let jobFailed ← ContractTest.jobFailures services
  let checks := ContractTest.jobChecks services
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
      s!"contract-test: {properties.length} properties hold of the real text binding, and its documents are freed with its table; {Editor.JobContract.properties.length} properties hold of the job runner over the timer service, {checks.length} checks of it passed, and quit ended the pump"
  (← IO.getStdout).flush
  IO.Process.exit 0
