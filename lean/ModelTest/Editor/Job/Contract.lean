import Editor.Command
import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.Fuzzy.Model
import Editor.Invocation
import Editor.Job
import Editor.Job.Contract
import Editor.Job.Fake
import Editor.Job.Model
import Editor.Job.Runner
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.Test.Jobs
import Editor.Text
import Editor.Text.Model
import ModelTest.Check

/-!
# Model tests: `Editor/Job/Contract.lean`

The model tests of `Editor/Job/Contract.lean`: `jobRunnerFailures`,
`postFailures`, `snapshotJobFailures`, `fuzzyJobFailures`, `fileFailures`,
`processFailures`, `fileWatchFailures`, `jobModelFailures` and
`snapshotReadChecks`. The job port's contract is run here against the job model
and against the runner over its fakes. The root module `ModelTest` runs them;
its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- A rig whose runner reads snapshots from `table`, each slot a text or
`none` for one released (`Job.Services.snapshots`). -/
def snapshotRig (table : Array (Option String)) : BaseIO Rig := do
  let rig ← Rig.new
  return { rig with
      services := { rig.services with snapshots := fun id => pure (table[id.index]?).join } }

-- inferred-waits W23: stays (the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle)
set_option linter.inferredWait false in
/-- The checks of the job port's snapshot read that need equality, against
the job model and the runner over the fake clock (`JobContract`, "Snapshots",
`Editor/Job/Contract.lean`). -/
def snapshotReadChecks : List Check :=
  [{  name :=
        "in the job model, a snapshot read leaves the clock where it was, and is answered from the published snapshots of the files' model; on the runner over the fake clock it registers no wait and starts none on the clock"
      run := do
        let published := snapshotModelTable JobContract.snapshotTable
        let job : JobM (Nat × Option String × Nat) := do
          let before ← now
          let read ← readSnapshot ⟨0⟩
          return (before, read, ← now)
        let onModel := modelled job { now := 7, files := { snapshots := published } }
        let rig ← snapshotRig JobContract.snapshotTable
        let outcome ←
          runOnFake
              (do
                return (← readSnapshot ⟨2⟩) == some "café\r\nau")
              (some rig)
        let state ← rig.clock.state.get
        return onModel == (.finished (7, some "alpha beta", 7), 7) && outcome == .finished true &&
            state.started.isEmpty &&
            (← rig.services.completions.waiting) == 0 }]

-- inferred-waits W24: stays (the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle)
set_option linter.inferredWait false in
/-- The names of the job port's contract properties that do not hold of the
runner over the fake clock. -/
def jobRunnerFailures : IO (List String) := do
  let failed ← JobContract.failures (runOnFake ·) JobContract.properties
  return failed.map (s!"the job runner over the fake clock: {·}")

-- inferred-waits W25: stays (the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle)
set_option linter.inferredWait false in
/-- Runs `job` on the runner over a fake clock of its own, spawned with a host
that records each post it is handed, and answers the posts once the job has
ended. The clock is advanced to each deadline at the rig's idle, as
`runOnFake` does (`Rig.stepToEnd`); a job stuck or hung there is cancelled,
and the posts it made are returned. -/
def postedOnFake (job : JobM Unit) : IO (Array Invocation) := do
  let rig ← Rig.new
  let posts ← IO.mkRef #[]
  let handle ←
    Job.spawn rig.services (Work.of (fun _ => job) fun _ => pure ()) (pure ()) fun invocation =>
        posts.modify (·.push invocation)
  discard <| rig.stepToEnd handle
  posts.get

/-- The names of the job port's post properties that do not hold of the job
model, and of those that do not hold of the runner over the fake clock. -/
def postFailures : IO (List String) := do
  let onModel ←
    JobContract.postFailures (fun job => pure (job.runModel {}).2.posted) JobContract.postProperties
  let onFake ← JobContract.postFailures postedOnFake JobContract.postProperties
  return onModel.map (s!"the job model: {·}") ++
      onFake.map (s!"the job runner over the fake clock: {·}")

-- inferred-waits W26: stays (the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle)
set_option linter.inferredWait false in
/-- The names of the job port's fuzzy properties that do not hold of the job
model, and of those that do not hold of the runner over the fake clock given
the fuzzy model as its fuzzy service (`FuzzyModel.handler`). -/
def fuzzyJobFailures : IO (List String) := do
  let onModel ←
    JobContract.failures (fun job => pure (job.runModel {}).1) JobContract.fuzzyProperties
  let onFake ←
    JobContract.failures
        (fun job => do
          let rig ← Rig.new
          runOnFake job
              (some { rig with services := { rig.services with fuzzy := FuzzyModel.handler } }))
        JobContract.fuzzyProperties
  return onModel.map (s!"the job model: {·}") ++
      onFake.map (s!"the job runner over the fake clock: {·}")

/-- Runs a file property's job against the job port's model, over the model
of its files: how the job ended, and the files afterwards. -/
def runFilesOnModel (property : JobContract.FileProperty) :
    IO (Job.Outcome Bool × Array (String × ByteArray)) :=
  let (outcome, model) :=
    (property.holds fileRoot).runModel { files := fileModelOf property.files property.directories }
  pure (outcome, filesIn model.files)

-- inferred-waits W27: stays (the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle)
set_option linter.inferredWait false in
/-- Runs a file property's job on the runner over a fake clock and the fake
of the file service, over the model of its files: how the job ended, and the
files afterwards. -/
def runFilesOnFake (property : JobContract.FileProperty) :
    IO (Job.Outcome Bool × Array (String × ByteArray)) := do
  let (rig, files) ← Rig.withFiles (fileModelOf property.files property.directories)
  let outcome ← runOnFake (property.holds fileRoot) (some rig)
  return (outcome, filesIn (← files.model))

/-- The names of the job port's file, diff and search properties that do not
hold of the job model, and of those that do not hold of the runner over the
fake of the file service, whose model answers a diff and a search. -/
def fileFailures : IO (List String) := do
  let properties :=
    JobContract.fileProperties ++ JobContract.diffProperties ++ JobContract.grepProperties
  let onModel ← JobContract.fileFailures runFilesOnModel properties
  let onFake ← JobContract.fileFailures runFilesOnFake properties
  return onModel.map (s!"the job model: {·}") ++
      onFake.map (s!"the job runner over the fake file service: {·}")

/-- The model of the processes a process property's commands are scripted
as. -/
def processModelOf (property : JobContract.ProcessProperty) : ProcessModel :=
  { scripts := property.scripts processRoot, streams := property.streams processRoot }

/-- Runs a process property's job against the job port's model, over the
model of its processes: how the job ended. -/
def runProcessesOnModel (property : JobContract.ProcessProperty) : IO (Job.Outcome Bool) :=
  pure ((property.holds processRoot).runModel { processes := processModelOf property }).1

-- inferred-waits W28: stays (the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle)
set_option linter.inferredWait false in
/-- Runs a process property's job on the runner over a fake clock and the
fake of the process service, over the model of its processes: how the job
ended. -/
def runProcessesOnFake (property : JobContract.ProcessProperty) : IO (Job.Outcome Bool) := do
  let (rig, _) ← Rig.withProcesses (processModelOf property)
  runOnFake (property.holds processRoot) (some rig)

/-- The names of the job port's process properties that do not hold of the
job model, and of those that do not hold of the runner over the fake of the
process service. -/
def processFailures : IO (List String) := do
  let onModel ← JobContract.processFailures runProcessesOnModel JobContract.processProperties
  let onFake ← JobContract.processFailures runProcessesOnFake JobContract.processProperties
  return onModel.map (s!"the job model: {·}") ++
      onFake.map (s!"the job runner over the fake process service: {·}")

/-- The models a watch property's directories, files and scripts are, for
the job model and the fake, in `watchRoot`: the directory and its
subdirectories, and each script as a run that ends with the status 0 and
changes what it touches. -/
def watchModelsOf (property : JobContract.FileWatchProperty) : ProcessModel × FileWatchModel :=
  let commandOf (script : JobContract.FileWatchScript) := JobContract.sh watchRoot script.script
  let processes : ProcessModel :=
    {
      scripts :=
        property.scripts.map fun script =>
          { command := commandOf script
            reply := .ok { exit := .code 0, stdout := .empty, stderr := .empty } } }
  let watches : FileWatchModel :=
    { directories :=
        #[watchRoot] ++ property.directories.map fun (name : String) => watchRoot / name
      effects :=
        property.scripts.map fun script =>
          (commandOf script, script.touches.map fun (name, kind) => (watchRoot / name, kind)) }
  (processes, watches)

/-- Runs a watch property's job against the job port's model: how the job
ended. -/
def runWatchesOnModel (property : JobContract.FileWatchProperty) : IO (Job.Outcome Bool) :=
  let (processes, fileWatches) := watchModelsOf property
  pure ((property.holds watchRoot).runModel { processes, fileWatches }).1

-- inferred-waits W29: stays (the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle)
set_option linter.inferredWait false in
/-- Runs a watch property's job on the runner over a fake clock, the fake of
the process service and the fake of the watch service: how the job ended. -/
def runWatchesOnFake (property : JobContract.FileWatchProperty) : IO (Job.Outcome Bool) := do
  let (processes, fileWatches) := watchModelsOf property
  let (rig, _, _) ← Rig.withWatches processes fileWatches
  runOnFake (property.holds watchRoot) (some rig)

/-- The names of the job port's watch properties that do not hold of the job
model, and of those that do not hold of the runner over the fakes. -/
def fileWatchFailures : IO (List String) := do
  let onModel ← JobContract.fileWatchFailures runWatchesOnModel JobContract.fileWatchProperties
  let onFake ← JobContract.fileWatchFailures runWatchesOnFake JobContract.fileWatchProperties
  return onModel.map (s!"the job model: {·}") ++
      onFake.map (s!"the job runner over the fake watch service: {·}")

-- inferred-waits W30: stays (the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle)
set_option linter.inferredWait false in
/-- The names of the snapshot properties of the job port that do not hold of
the job model, with the table published as its files' snapshots, and of
those that do not hold of the runner over the fake clock, with the table as
its snapshot service. -/
def snapshotJobFailures : IO (List String) := do
  let onModel ←
    JobContract.snapshotFailures
        (fun table job =>
          pure (job.runModel { files := { snapshots := snapshotModelTable table } }).1)
        JobContract.snapshotProperties
  let onFake ←
    JobContract.snapshotFailures
        (fun table job => do
          runOnFake job (some (← snapshotRig table)))
        JobContract.snapshotProperties
  return onModel.map (s!"the job model: {·}") ++
      onFake.map (s!"the job runner over the fake clock: {·}")

/-- The names of the job port's contract properties that do not hold of the
job model, each run from a clock at 0 that nothing cancels. -/
def jobModelFailures : IO (List String) := do
  let failed ← JobContract.failures (fun job => pure (job.runModel {}).1) JobContract.properties
  return failed.map (s!"the job model: {·}")

end ModelTest
