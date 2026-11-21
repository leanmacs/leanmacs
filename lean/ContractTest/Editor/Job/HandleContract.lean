import ContractTest.Check
import ContractTest.Support.FileHold
import Editor.Ffi.Files
import Editor.Job.HandleContract
import Editor.Job.Runner
import Editor.Test.Linked.Services

/-!
# Contract tests: `Editor/Job/HandleContract.lean`

The contract of a file request's handle run against the real file port over
the Rust library (`realFiles`): `handleContractChecks`. The service is held
by its in-process hold (`FileHold`), what it keeps is its count of requests
waiting, being worked or holding a result not yet taken
(`Ffi.filesPending`, read once after a flush), and the properties write in a
temporary directory of the check's own, removed once the service has been
flushed (`Linked.withFiles`). The rig also reads the library's failures queue once
(`Ffi.filesFailure`, kept for the host's unobserved journal): a handle's
request must never say its outcome there. The root module `ContractTest`
runs them over the services it starts.
-/

namespace ContractTest

open Editor
open Editor.Job

/-- The rig of the real file port among `services`, writing in `directory`. -/
def handleRealRig (services : Job.Services) (directory : System.FilePath) : HandleContract.HandleRig
    where
  name := "the library's file service"
  services
  directory
  read path := do
    if ← path.pathExists then
      return some (← IO.FS.readBinFile path)
    else
      return none
  held := do
    let hold ← FileHold.hold services.completions
    return hold.release
  kept := return (← Ffi.filesPending).toNat
  leaked := return (← Ffi.filesFailure).isSome

/-- The contract of a file request's handle over the real file port among
`services` (`Editor/Job/HandleContract.lean`), in a temporary directory
removed once the service has been flushed. -/
def handleContractChecks (services : Job.Services) : List Check :=
  [{  name := "the contract of a file request's handle holds of the library's file service"
      run :=
        -- Nothing handed to the service may outlive the directory.
        Editor.Test.Linked.withFiles services fun directory => do
          let failed ← HandleContract.failures [handleRealRig services directory]
          unless failed.isEmpty do
            throw <| IO.userError s!"{failed}"
          return true }]

end ContractTest
