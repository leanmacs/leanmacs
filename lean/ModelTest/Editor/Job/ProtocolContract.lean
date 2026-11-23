import Editor.Job.ProtocolContract
import ModelTest.Check

/-!
# Model tests: `Editor/Job/ProtocolContract.lean`

The runner's protocol contract run on the fakes: `protocolContractChecks`,
each recorded run (`ProtocolContract.recordedRuns`) on a rig of its own over
the fake clock and the fake files (`ProtocolRig.fakes`). The root module
`ModelTest` runs them, after the checks that count pool threads: a hold
occupies a pool thread.
-/

namespace ModelTest

open Editor
open Editor.ProtocolContract

/-- A check of a recorded run on a fresh rig over the fakes. -/
def recordedCheck (property : RecordedProperty) : Check :=
  { name := s!"the fakes: {property.name}"
    run := do
      property.holds (← ProtocolRig.fakes) }

/-- The checks of the runner's protocol contract on the fakes. -/
def protocolContractChecks : List Check :=
  recordedRuns.map recordedCheck

end ModelTest
