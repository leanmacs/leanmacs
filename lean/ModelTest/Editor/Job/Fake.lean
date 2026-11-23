import Editor.Bound
import Editor.Job.Fake
import Editor.Job.Runner
import ModelTest.Check

/-!
# Model tests: `Editor/Job/Fake.lean`

What the fakes of the job runner's services promise of themselves, beside
the contracts they keep (`ModelTest.fileFailures` and the other stepped
runs, `flushContractChecks`, `handleContractChecks`, `pumpContractChecks`):
`jobFakeChecks`. The root module `ModelTest` runs them; its module doc says
what each shows.
-/

namespace ModelTest

open Editor
open Editor.Job

/-- The guard of the stepped runner's end once a completion has been handed
to it between an empty step and its wait; only a hang reaches it. -/
def handedAfterEmptyStepGuard : HangGuard :=
  .on "the completion handed after an empty step, stepped, and its wait ended" 10000

/-- `FakePump.runToEnd` over a pump whose empty steps are held: a thread of
the check's own hands the completion its run waits for while the runner is
held just after a step that found nothing due, before it waits for the next
hand, so the hand lands in that window every time. The run must still step
it and end; a runner that reads the count of hands after its empty step
waits for a hand after this one, which never comes. -/
def handedAfterEmptyStepCheck : Check :=
  { name :=
      "the stepped runner steps a completion handed off its thread between a step that found nothing due and its wait for the next hand"
    run := do
      let completions ← Completions.new
      let pump ← FakePump.new completions
      let clock ← FakeClock.new completions
      let (id, wait) ← completions.register
      let hold ← pump.holdEmptySteps
      let arrived ← pump.emptyStepsArrivedAt 1
      let hander ←
        IO.asTask (prio := .dedicated) do
            try
              discard <| awaitOrHang handedAfterEmptyStepGuard arrived.result?
              pump.hand id
            finally
              hold.resolve ()
      try
        pump.runToEnd wait.result? handedAfterEmptyStepGuard (some clock)
      finally
        hold.resolve ()
        discard <| IO.wait hander
      return (← IO.hasFinished wait.result?) && (← pump.quiescent) }

/-- The checks of the job services' fakes' own promises. -/
def jobFakeChecks : List Check :=
  [handedAfterEmptyStepCheck]

end ModelTest
