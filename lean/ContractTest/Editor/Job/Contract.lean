import ContractTest.Support.Files
import ContractTest.Support.Jobs
import Editor.Command
import Editor.Ffi.Diffs
import Editor.Ffi.Document
import Editor.Ffi.Files
import Editor.Ffi.Grep
import Editor.Ffi.Processes
import Editor.Ffi.Snapshot
import Editor.Ffi.Watches
import Editor.Invocation
import Editor.Job
import Editor.Job.Contract
import Editor.Job.Real
import Editor.Job.Runner
import Editor.Program
import Editor.Text
import Editor.Text.Real

/-!
# Contract tests: `Editor/Job/Contract.lean`

The tests of `Editor/Job/Contract.lean`: `jobFailures`, `postFailures`,
`snapshotJobFailures`, `fuzzyJobFailures`, `fileFailures`, `processFailures` and
`fileWatchFailures`, the job port's contract against the runner over the
library's services. The root module `ContractTest` runs them; its module doc
says what each shows.
-/

namespace ContractTest

open Editor

/-- The names of the job port's contract properties that do not hold of the
runner over the library's timer service. -/
def jobFailures (services : Job.Services) : IO (List String) := do
  let failed ← JobContract.failures (runOnTimers services) JobContract.properties
  return failed.map (s!"the job runner over the timer service: {·}")

/-- Runs `job` on the runner over the library's services, spawned with a host
that records each post it is handed, and answers the posts once the job has
ended. A job that does not end in time is cancelled, and a job that ended is
settled. -/
def postedOnTimers (services : Job.Services) (job : JobM Unit) : IO (Array Invocation) := do
  let posts ← IO.mkRef #[]
  let handle ←
    Job.spawn services (Work.of (fun _ => job) fun _ => pure ()) (pure ()) fun invocation =>
        posts.modify (·.push invocation)
  unless ← eventually handle.ended do
    handle.cancel
  handle.settle
  posts.get

/-- The names of the job port's post properties that do not hold of the
runner over the library's timer service. -/
def postFailures (services : Job.Services) : IO (List String) := do
  let failed ← JobContract.postFailures (postedOnTimers services) JobContract.postProperties
  return failed.map (s!"the job runner over the timer service: {·}")

/-- The names of the job port's snapshot properties that do not hold of the
runner over the library's services, its snapshot reads answered from a real
table of snapshots (`Job.realSnapshots`): each property's table published as
documents' snapshots, a `none` slot's added and then released. -/
def snapshotJobFailures (services : Job.Services) : IO (List String) := do
  let failed ←
    JobContract.snapshotFailures
        (fun published job => do
          let table ← Snapshots.new
          for slot in published do
            let id ← table.add (← (← Ffi.Document.new (slot.getD "")).snapshot)
            if slot.isNone then
              discard <| table.release id
          runOnTimers { services with snapshots := Job.realSnapshots table.reader } job)
        JobContract.snapshotProperties
  return failed.map (s!"the job runner over the published table: {·}")

/-- The names of the job port's fuzzy properties that do not hold of the
runner given the library's matcher (`Fuzzy.real`). -/
def fuzzyJobFailures (services : Job.Services) : IO (List String) := do
  let failed ← JobContract.failures (runOnTimers services) JobContract.fuzzyProperties
  return failed.map (s!"the job runner over the library's matcher: {·}")

/-- Runs a file property's job on the runner over the library's file
service, on real files: how the job ended, and the files afterwards.

The files are in a temporary directory made here for this one property,
whose path the job is handed; nothing else is written anywhere. The
property's files are written into it, the job runs, every file then in it is
read back, and it is removed, whatever happened. -/
def runFilesOnService (services : Job.Services) (property : JobContract.FileProperty) :
    IO (Job.Outcome Bool × Array (String × ByteArray)) := do
  let directory ← IO.FS.createTempDir
  try
    for (name, bytes) in property.files do
      IO.FS.writeBinFile (directory / name) bytes
    for name in property.directories do
      IO.FS.createDirAll (directory / name)
    let outcome ← runOnTimers services (property.holds directory)
    return (outcome, ← filesOf directory)
  finally
    IO.FS.removeDirAll directory

/-- What must hold of the library's objects once the file properties have
run: it is about the library's counts, so the port cannot say it. -/
def fileLeakName : String :=
  "what the jobs of the file properties loaded is released when each job is settled, and no request is left in the file service"

/-- The names of the job port's file and diff properties that do not hold of
the runner over the library's file and diff services, on real files.
`fileLeakName` is among them if the library then holds a snapshot more than
before, `held` still holds one, or the file service or the diff service has a
request or a result left. -/
def fileFailures (services : Job.Services) (held : Job.HeldSnapshots) : IO (List String) := do
  let pending : IO UInt64 :=
    return (← Ffi.filesPending) + (← Ffi.diffsPending) + (← Ffi.grepPending)
  let before := (← Ffi.Snapshot.live, ← pending)
  let failed ←
    JobContract.fileFailures (runFilesOnService services)
        (JobContract.fileProperties ++ JobContract.diffProperties ++ JobContract.grepProperties)
  let freed ←
    eventually do
        return (← Ffi.Snapshot.live, ← pending) == before && (← held.size) == 0
  let after := (← Ffi.Snapshot.live, ← pending, ← held.size)
  return failed.map (s!"the job runner over the file service: {·}") ++
      if freed then []
      else
        [s!"{fileLeakName} ({before.1} snapshots and {before.2} requests before, {after.1} and {after.2.1} after, {after.2.2} held)"]

/-- Runs a process property's job on the runner over the library's process
service, on real processes: how the job ended.

Its commands run in a temporary directory made here for this one property,
whose path the job is handed; the property's files are written into it, and
it is removed, whatever happened. -/
def runProcessesOnService (services : Job.Services) (property : JobContract.ProcessProperty) :
    IO (Job.Outcome Bool) := do
  let directory ← IO.FS.createTempDir
  try
    for (name, bytes) in property.files do
      IO.FS.writeBinFile (directory / name) bytes
    runOnTimers services (property.holds directory)
  finally
    IO.FS.removeDirAll directory

/-- What must hold of the library's process service once the process
properties have run: it is about the library's count, so the port cannot say
it. -/
def processLeakName : String :=
  "every child the process properties ran is reaped, and the process service keeps no result"

/-- The names of the job port's process properties that do not hold of the
runner over the library's process service, on real processes.
`processLeakName` is among them if the service then has a run or a result
more than before. -/
def processFailures (services : Job.Services) : IO (List String) := do
  let before ← Ffi.processesPending
  let failed ←
    JobContract.processFailures (runProcessesOnService services) JobContract.processProperties
  let reaped ← eventually (return (← Ffi.processesPending) == before)
  let after ← Ffi.processesPending
  return failed.map (s!"the job runner over the process service: {·}") ++
      if reaped then [] else [s!"{processLeakName} ({before} before, {after} after)"]

/-- Runs a watch property's job on the runner over the library's watch and
process services, on real files: how the job ended.

Its directories and files are made in a temporary directory made here for
this one property, whose path the job is handed, and it is removed, whatever
happened. -/
def runWatchesOnService (services : Job.Services) (property : JobContract.FileWatchProperty) :
    IO (Job.Outcome Bool) := do
  let directory ← IO.FS.createTempDir
  try
    for name in property.directories do
      IO.FS.createDir (directory / name)
    for (name, bytes) in property.files do
      IO.FS.writeBinFile (directory / name) bytes
    runOnTimers services (property.holds directory)
  finally
    IO.FS.removeDirAll directory

/-- What must hold of the library's watch service once the watch properties
have run: it is about the library's count, so the port cannot say it. -/
def watchLeakName : String :=
  "every watch the watch properties started is ended with its job, and the watch service keeps no reply"

/-- The names of the job port's watch properties that do not hold of the
runner over the library's watch service, on real files. `watchLeakName` is
among them if the service then has a watch or a wait more than before. -/
def fileWatchFailures (services : Job.Services) : IO (List String) := do
  let before ← Ffi.watchesPending
  let failed ←
    JobContract.fileWatchFailures (runWatchesOnService services) JobContract.fileWatchProperties
  let ended ← eventually (return (← Ffi.watchesPending) == before)
  let after ← Ffi.watchesPending
  return failed.map (s!"the job runner over the watch service: {·}") ++
      if ended then [] else [s!"{watchLeakName} ({before} before, {after} after)"]

end ContractTest
