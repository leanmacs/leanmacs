import Editor.Job.ProtocolContract
import ModelTest.Check
import ModelTest.Support.Protocol

/-!
# Model tests: `Editor/Job/ProtocolContract.lean`

The runner's protocol contract run on the fakes: `protocolContractChecks`.
Each recorded run (`ProtocolContract.recordedRuns`) runs on a rig of its own
over the fake clock, the fake files and the fake processes
(`ProtocolRig.fakes`). The park
property (`parkHolds`) is required of the runner over that rig, held after
its unit's `done` with the cancel made on the check's thread, and of the
model, scripted to the same place; and it is required to fail on the
protocol before the runner-park fix (`PreFix`,
`ModelTest/Support/Protocol.lean`), scripted the same way. The root module
`ModelTest` runs them, after the checks that count pool threads: a hold
occupies a pool thread.
-/

namespace ModelTest

open Editor
open Editor.Job.Protocol
open Editor.ProtocolContract

/-- A check of a recorded run on a fresh rig over the fakes. -/
def recordedCheck (property : RecordedProperty) : Check :=
  { name := s!"the fakes: {property.name}"
    run := do
      property.holds (← ProtocolRig.fakes) }

/-- The park subject of a model of the protocol whose steps are `step`: it
takes `script` from the initial state, a job's start, its ask of a parking
wait and its next step, stops there, and cancels the job with `cancel`. The
wait the job asked, whether the count has given its unit back, and what the
cancel found recorded, which is what it withdraws. -/
def scriptedPark {τ : Type} (name : String) (step : State → τ → Option State) (script : List τ)
    (cancel : τ) : ParkSubject
    where
  name := name
  run := do
    let some held := script.foldlM step {}
      | throw (IO.userError s!"{name}: the model refuses the script")
    let job := held.job 0
    let asked :=
      match job.status with
      | .parked wait | .waiting wait => some wait
      | _ => none
    let some _ := step held cancel
      | throw (IO.userError s!"{name}: the model refuses the cancel")
    return { asked, unitBack := held.count == 0, withdrawn := job.recorded.toList.toArray }

/-- The model's park: start, ask a parking wait, park. -/
def modelPark : ParkSubject :=
  scriptedPark "the model" State.step [.start 0, .ask 0 0 .parks, .park 0] (.cancel 0)

/-- The pre-fix park: start, ask a parking wait, give the unit back, its wait
not yet recorded. -/
def preFixPark : ParkSubject :=
  scriptedPark "the pre-fix model" PreFix.step [.of (.start 0), .of (.ask 0 0 .parks), .giveBack 0]
    (.of (.cancel 0))

/-- A check that `subject` holds the park property, or with `holds` false,
that it breaks it. -/
def parkCheck (subject : ParkSubject) (holds : Bool := true) : Check :=
  { name :=
      if holds then
        s!"{subject.name}: a job whose unit has been given back for its sleep is in a wait the cancel made there withdraws"
      else
        s!"{subject.name}: a job whose unit has been given back for its sleep is in no wait the cancel made there withdraws"
    run := do
      let observed ← subject.run
      unless parkHolds observed == holds do
        throw (IO.userError s!"saw {repr observed}")
      return true }

/-- The checks of the runner's protocol contract on the fakes and the
models. -/
def protocolContractChecks : List Check :=
  recordedRuns.map recordedCheck ++
    [parkCheck (ParkSubject.ofRig "the fakes" ProtocolRig.fakes), parkCheck modelPark,
      parkCheck preFixPark (holds := false)]

end ModelTest
