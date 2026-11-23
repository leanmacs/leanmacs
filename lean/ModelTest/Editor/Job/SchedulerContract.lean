import Editor.Job.Fake
import Editor.Job.Runner
import Editor.Job.SchedulerContract
import ModelTest.Check

/-!
# Model tests: `Editor/Job/SchedulerContract.lean`

The contract of the scheduler run over the fake (`FakeScheduler`), stepped
on the check's thread, and over Lean's task pool (`Scheduler.pool`), each
property on a rig of its own: `schedulerContractChecks`. Beside them, what
only the fake shows: it runs nothing until it is stepped, runs the oldest
piece that can run on the stepping thread, here the check's own, and is
quiescent once stepped to its end. The root module `ModelTest` runs them.
-/

namespace ModelTest

open Editor
open Editor.Job

/-- A rig over a fake scheduler of its own, stepped on the check's thread,
and the fake. -/
def schedulerFakeRig : BaseIO (SchedulerContract.SchedulerRig × FakeScheduler) := do
  let jobs ← FakeScheduler.new
  let rig : SchedulerContract.SchedulerRig :=
    { name := "the fake scheduler", scheduler := jobs.scheduler, runReady := jobs.stepAll
      settle := fun task => do
        jobs.stepAll
        unless ← IO.hasFinished task do
          throw <| IO.userError "the fake scheduler ran all it could, and the task had not ended" }
  return (rig, jobs)

/-- A rig over Lean's task pool. -/
def schedulerPoolRig : SchedulerContract.SchedulerRig :=
  { name := "the task pool", scheduler := Scheduler.pool, runReady := pure ()
    settle := fun task => awaitOrHang SchedulerContract.patience task }

/-- The contract of the scheduler over the fake and over the pool, and the
fake's own promises. -/
def schedulerContractChecks : List Check :=
  (SchedulerContract.properties.map fun property =>
      { name := s!"the fake scheduler keeps the scheduler's contract: {property.name}"
        run := do
          let (rig, jobs) ← schedulerFakeRig
          return (← property.holds rig) && (← jobs.quiescent) }) ++
    (SchedulerContract.properties.map fun property =>
      { name := s!"the task pool keeps the scheduler's contract: {property.name}"
        run := property.holds schedulerPoolRig }) ++
    [{  name :=
          "the fake scheduler runs nothing until it is stepped; a step runs the oldest piece that can run, on the stepping thread, here the check's own, and passes over a continuation whose wait has not ended"
        run := do
          let jobs ← FakeScheduler.new
          let thread ← IO.getTID
          let log ← IO.mkRef (#[] : Array String)
          let wait : IO.Promise Completion ← IO.Promise.new
          jobs.scheduler.resume wait.result? fun _ => log.modify (·.push "resumed")
          jobs.scheduler.start (log.modify (·.push "first"))
          jobs.scheduler.start (log.modify (·.push "second"))
          let before ← log.get
          let stepped ← jobs.step
          let afterOne ← log.get
          jobs.stepAll
          let held ← jobs.size
          let afterAll ← log.get
          wait.resolve .completed
          jobs.stepAll
          let afterWait ← log.get
          let ran ← jobs.ranThreads
          unless
            before.isEmpty && stepped && afterOne == #["first"] && held == 1 &&
              afterAll == #["first", "second"] &&
              afterWait == #["first", "second", "resumed"] &&
              ran == #[thread, thread, thread] &&
              (← jobs.quiescent) do
            throw <|
                IO.userError
                  s!"before a step {before}, after one {afterOne}, after all {afterAll} with {held} held, after the wait {afterWait}; ran on {ran}, the check's thread {thread}"
          return true }]

end ModelTest
