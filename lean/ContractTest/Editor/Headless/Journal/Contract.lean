import ContractTest.Check
import ContractTest.Support.FileHold
import Editor.Ffi.Document
import Editor.Ffi.Snapshot
import Editor.Headless.Journal.Contract
import Editor.Headless.Journal.Real
import Editor.Job.Runner
import Editor.Test.Linked.Services
import Editor.Text.Real

/-!
# Contract tests: `Editor/Headless/Journal/Contract.lean`

The contract of the session journal's port run over the real journal
(`Journal.real`, `Editor/Headless/Journal/Real.lean`) on the library's file
service: `journalContractChecks`, one check per property, each in a
temporary directory of its own, removed once the service has been flushed
(`Linked.withFiles`). The rig holds the service's worker with its
in-process hold (`FileHold`), publishes a save's text through a table of
real snapshots of its own, and steps nothing: the service works by itself,
and every property waits on the journal's own drain, a flush of the
service. The root module `ContractTest` runs them over the services it
starts.
-/

namespace ContractTest

open Editor
open Editor.Headless

/-- The rig of the real journal over the file service among `services`,
writing in `directory`, publishing through `published`. -/
def journalRealRig (services : Job.Services) (published : Snapshots) (directory : System.FilePath) :
    JournalContract.JournalRig where
  name := "the journal over the library's file service"
  journal := Journal.real published.reader services
  directory
  read path := do
    if ← path.pathExists then
      return some (← IO.FS.readBinFile path)
    else
      return none
  put path bytes := IO.FS.writeBinFile path bytes
  snapshotOf text := do
    published.add (← (← Ffi.Document.new text).snapshot)
  step := pure ()
  held := do
    let hold ← FileHold.hold services.completions
    return hold.release

/-- The contract of the journal's port over the real journal on the file
service among `services` (`Editor/Headless/Journal/Contract.lean`). -/
def journalContractChecks (services : Job.Services) : List Check :=
  JournalContract.properties.map fun property =>
    { name := s!"the journal over the library's file service keeps the journal's contract: {property.name}"
      run :=
        -- Nothing handed to the service may outlive the directory.
        Editor.Test.Linked.withFiles services fun directory => do
          property.holds (journalRealRig services (← Snapshots.new) directory) }

end ContractTest
