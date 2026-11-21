import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.Job
import Editor.Job.Fake
import Editor.Job.Runner
import Editor.Program
import Editor.Test.Jobs
import ModelTest.Check

/-!
# Model tests: `Editor/Test/Jobs.lean`

The model tests of the test kit's jobs (`Editor/Test/Jobs.lean`):
`rigChecks`, what the kit's waits promise. The root module `ModelTest` runs
them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The checks of the kit's waits: a rig's idle, the start gate and the
stepped driver, each forced into the order it must not get wrong. -/
def rigChecks : List Check :=
  [{  name :=
        "a rig is idle only once every job spawned on it is parked or has ended: its idle has not returned while a job is held in its leading work, and returns once the job is in its sleep on the fake clock"
      run := do
        let rig ← Rig.new
        let gate : IO.Promise Unit ← IO.Promise.new
        let job ←
          rig.spawn fun _ =>
              if gate.result?.get.isSome then do
                sleep 10
                return makes "slept"
              else pure (makes "dropped")
        try
          let idling ← IO.asTask (prio := .dedicated) rig.idle
          -- The job holds its unit while the gate is shut, so an idle that
          -- returned now would have returned too early.
          let early ← IO.hasFinished idling
          gate.resolve ()
          let some (.ok seen) ← Job.awaitWithin patience idling | return false
          let waiting ← rig.clock.waiting
          rig.clock.advance 10
          return !early && seen.running == 0 && waiting == 1 &&
              (← job.endedAs (.finished #["slept"]))
        finally
          gate.resolve ()
          job.handle.cancel },
    { name :=
        "the start gate resolves its promise at the given count of starts, after the start it decorates has returned, and resolves a count of 0 at once"
      run := do
        let log ← IO.mkRef (#[] : Array (UInt64 × Nat × Bool))
        let arrivedRef ← IO.mkRef (none : Option (IO.Promise Unit))
        let inner (id : UInt64) (request : Nat) : BaseIO Unit := do
          let resolved ←
            match ← arrivedRef.get with
            | some arrived =>
              arrived.isResolved
            | none =>
              pure false
          log.modify (·.push (id, request, resolved))
        let (start, arrived) ← startGate inner 2
        arrivedRef.set (some arrived)
        start 1 10
        let afterOne ← arrived.isResolved
        start 2 20
        let afterTwo ← arrived.isResolved
        start 3 30
        let (_, noStarts) ← startGate inner 0
        return !afterOne && afterTwo && (← noStarts.isResolved) &&
            (← log.get) == #[(1, 10, false), (2, 20, false), (3, 30, true)] },
    { name :=
        "the stepped driver fails a job stuck at idle in a wait nothing ends, at once and as stuck, and cancels it"
      run := do
        let (rig, _, _) ← Rig.withWatches {} { directories := #[watchRoot] }
        let outcome ←
          runOnFake
              (do
                let .ok watch ← FileWatch.start (.file (watchRoot / "f")) atOnce | return false
                discard <| FileWatch.next watch
                return true)
              (some rig)
        let stuck :=
          match outcome with
          | .failed message => (message.splitOn "stuck").length > 1
          | _ => false
        discard <| rig.idle
        return stuck && (← rig.services.completions.waiting) == 0 }]

end ModelTest
