import ContractTest.Check
import Editor.Ffi.Files
import Editor.Job.PumpContract
import Editor.Job.Real
import Editor.Job.Runner

/-!
# Contract tests: `Editor/Job/PumpContract.lean`

The contract of the completion pump run over the library's completion queue
(`Job.pump`, `pumpFrom` over `Job.librarySource`): `pumpContractChecks`, one
check per property, over the services the root starts, whose pump runs. A
completion is handed as a flush of the library's file service under the
wait's id (`Job.flushThrough`), which its one in-order worker completes in
the order handed. Each property waits on its own wait's task. The root
module `ContractTest` runs them.
-/

namespace ContractTest

open Editor
open Editor.Job

/-- The rig of the library's completion queue over `services`' table, whose
pump runs. -/
def pumpRealRig (services : Job.Services) : PumpContract.PumpRig where
  name := "the library's completion queue"
  completions := services.completions
  hand id := flushThrough services.completions Ffi.filesFlush id
  run := pure ()

/-- The contract of the completion pump over the library's completion
queue. -/
def pumpContractChecks (services : Job.Services) : List Check :=
  PumpContract.properties.map fun property =>
    { name := s!"the library's completion queue keeps the pump's contract: {property.name}"
      run := property.holds (pumpRealRig services) }

end ContractTest
