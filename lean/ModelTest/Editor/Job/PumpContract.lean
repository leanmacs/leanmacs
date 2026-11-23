import Editor.Job.Fake
import Editor.Job.Pump
import Editor.Job.PumpContract
import Editor.Job.Runner
import ModelTest.Check

/-!
# Model tests: `Editor/Job/PumpContract.lean`

The contract of the completion pump run over the fake pump (`FakePump`):
`pumpContractChecks`, one check per property, each over a table and a pump
of its own, `pumpFrom` run over the fake's source on the check's thread.
Beside them, what only the fake shows: nothing is finished before a step,
every completion is finished on the stepping thread, here the check's own,
and the pump is quiescent once stepped to its end. The root module
`ModelTest` runs them.
-/

namespace ModelTest

open Editor
open Editor.Job

/-- A rig over a fake pump of its own, over a table of its own, and the
pump. -/
def pumpFakeRig : BaseIO (PumpContract.PumpRig × FakePump) := do
  let completions ← Completions.new
  let pump ← FakePump.new completions
  let rig : PumpContract.PumpRig :=
    { name := "the fake pump", completions, hand := fun id => pump.hand id
      run := do
        pump.close
        pumpFrom pump.source completions }
  return (rig, pump)

/-- The contract of the completion pump over the fake pump, and the fake's
own promises. -/
def pumpContractChecks : List Check :=
  (PumpContract.properties.map fun property =>
      { name := s!"the fake pump keeps the pump's contract: {property.name}"
        run := do
          let (rig, pump) ← pumpFakeRig
          return (← property.holds rig) && (← pump.quiescent) }) ++
    [{  name :=
          "the fake pump finishes nothing before it is stepped, and a step finishes the oldest completion due, on the stepping thread: here the check's own"
        run := do
          let (rig, pump) ← pumpFakeRig
          let thread ← IO.getTID
          let (first, firstWait) ← rig.completions.register
          let (second, secondWait) ← rig.completions.register
          pump.hand first
          pump.hand second
          let before := (← IO.hasFinished firstWait.result?, ← IO.hasFinished secondWait.result?)
          discard <| pump.step
          let between := (← IO.hasFinished firstWait.result?, ← IO.hasFinished secondWait.result?)
          pump.stepAll
          let after ← IO.hasFinished secondWait.result?
          let threads ← pump.finishedThreads
          unless before == (false, false) && between == (true, false) && after &&
                threads == #[thread, thread] && (← pump.quiescent) do
            throw <|
                IO.userError
                  s!"before a step the waits had ended {before}, after one {between}, after all {after}; finished on {threads}, the check's thread {thread}"
          return true },
      { name :=
          "the fake pump resolves an arrival once that many completions are handed, at once when they already are, and is quiescent once stepped to its end"
        run := do
          let (rig, pump) ← pumpFakeRig
          let (id, _) ← rig.completions.register
          let one ← pump.arrivedAt 1
          let early ← IO.hasFinished one.result?
          pump.hand id
          let late ← IO.hasFinished one.result?
          let already ← IO.hasFinished (← pump.arrivedAt 1).result?
          let busy := !(← pump.quiescent)
          pump.stepAll
          return !early && late && already && busy && (← pump.quiescent) }]

end ModelTest
