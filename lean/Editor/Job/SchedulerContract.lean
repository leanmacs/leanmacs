import Editor.Bound
import Editor.Job.Runner

/-!
# The contract of the scheduler

What a scheduler (`Scheduler`, `Editor/Job/Runner.lean`) keeps of a job's
code, as a list of properties over a `SchedulerRig`: the rig gives the
scheduler, how to run what it can run now, and how to run it until a task
has ended. The same list runs over both, by `model-test`
(`ModelTest.schedulerContractChecks`):

- over the fake (`FakeScheduler`, `Editor/Job/Fake.lean`): `runReady` and
  `settle` step it on the check's thread;
- over Lean's task pool (`Scheduler.pool`): `runReady` does nothing, and
  `settle` waits for the task under `patience`. The pool is Lean's runtime,
  so its run needs no library.

**A deadline here is a hang guard, never a result**: a property awaits its
own task under `patience`, and one not ended within it is reported as a
hang.

This module imports the runner alone: no `Ffi`.

## Where an addition goes

A new promise of the scheduler is a `Property` here, in `properties`; both
runs run it.
-/

namespace Editor.SchedulerContract

open Editor.Job

/-- The guard of a job's piece of code having run, which must come; only a
hang reaches it. -/
def patience : HangGuard :=
  .on "a scheduled piece of a job's code to have run" 10000

/-- A scheduler as the contract runs it. -/
structure SchedulerRig where
  /-- Which scheduler, as a failure names it. -/
  name : String
  /-- The scheduler. -/
  scheduler : Scheduler
  /-- Runs what the scheduler can run now; nothing for one that runs by
  itself. -/
  runReady : IO Unit
  /-- Runs what the scheduler holds until `task` has ended; throws a hang
  when it does not. -/
  settle : Task Unit → IO Unit

/-- One property of the scheduler: whether it holds on a rig, or why not,
thrown. -/
structure Property where
  /-- What must hold, as a sentence. -/
  name : String
  /-- Observes it on a fresh rig. -/
  holds : SchedulerRig → IO Bool

/-- A start's job runs once. -/
def startRunsOnce : Property where
  name := "a job handed to `start` runs, once"
  holds rig := do
    let runs ← IO.mkRef 0
    let ran ← IO.Promise.new
    rig.scheduler.start do
        runs.modify (· + 1)
        ran.resolve ()
    rig.settle (ran.result?.map (sync := true) fun _ => ())
    rig.runReady
    let count ← runs.get
    unless count == 1 do
      throw <| IO.userError s!"the job ran {count} times"
    return true

/-- A continuation runs only once its wait has ended, with what it ended
with, once. -/
def resumeAfterWait : Property where
  name :=
    "a continuation handed to `resume` does not run before its wait has ended, and then runs once, with what the wait ended with"
  holds rig := do
    let wait : IO.Promise Completion ← IO.Promise.new
    let runs ← IO.mkRef (#[] : Array (Option Completion))
    let ran ← IO.Promise.new
    rig.scheduler.resume wait.result? fun completion => do
        runs.modify (·.push completion)
        ran.resolve ()
    rig.runReady
    let early ← runs.get
    wait.resolve .cancelled
    rig.settle (ran.result?.map (sync := true) fun _ => ())
    rig.runReady
    let late ← runs.get
    unless early.isEmpty && late == #[some .cancelled] do
      throw <|
          IO.userError
            s!"before its wait ended the continuation had run {early.size} times; after, it had run with {repr late}"
    return true

/-- A continuation whose wait ended before it was handed runs too. -/
def resumeEndedWait : Property where
  name :=
    "a continuation handed to `resume` once its wait has ended runs, once, with what it ended with"
  holds rig := do
    let wait : IO.Promise Completion ← IO.Promise.new
    wait.resolve .completed
    let runs ← IO.mkRef (#[] : Array (Option Completion))
    let ran ← IO.Promise.new
    rig.scheduler.resume wait.result? fun completion => do
        runs.modify (·.push completion)
        ran.resolve ()
    rig.settle (ran.result?.map (sync := true) fun _ => ())
    rig.runReady
    let late ← runs.get
    unless late == #[some .completed] do
      throw <| IO.userError s!"the continuation ran with {repr late}"
    return true

/-- Every property, in the order they run. -/
def properties : List Property :=
  [startRunsOnce, resumeAfterWait, resumeEndedWait]

end Editor.SchedulerContract
