import Editor.Command
import Editor.Config.Owner
import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.Fuzzy
import Editor.Invocation
import Editor.Job
import Editor.Job.Fake
import Editor.Job.Model
import Editor.Job.Runner
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.Text
import Editor.Text.Model
import ModelTest.Support.Models

/-!
# Model tests: support: Jobs

Jobs run on the job model and on the runner over its fakes (`Rig`): the fakes'
roots, how long a check waits, a job's outcome as a check compares it, and a
table of published snapshots.
Shared by several test modules under `ModelTest/Editor/`; it holds no checks of
its own.
-/

namespace ModelTest

open Editor

/-- How `job` ends when it runs against the job port's model from `model`, and
what the model's clock then reads. The clock is how a check sees which waits
a job made: only a wait moves it. -/
def modelled {α : Type} (job : JobM α) (model : JobModel := {}) : Job.Outcome α × Nat :=
  let (outcome, after) := job.runModel model
  (outcome, after.now)

/-- Five sleeps of 10 ms, each inside a handler that catches every error: a
job that would swallow a cancellation, were one ever delivered as an error. -/
def stubborn : JobM Unit := do
  for _ in [0:5] do
    try
      sleep 10
    catch _ =>
      pure ()

/-- How long a check waits, in milliseconds, for something that should happen
at once. Only broken code takes this long, and the check then fails instead
of hanging. -/
def patience : Nat :=
  5000

/-- Polls `condition` until it holds; `false` if it still does not after
`patience` milliseconds. The bound is only how long a check takes to fail:
what a check waits for is something it controls. -/
def eventually (condition : IO Bool) : IO Bool := do
  let deadline := (← IO.monoMsNow) + patience
  repeat
    if ← condition then
      return true
    if (← IO.monoMsNow) >= deadline then
      break
    IO.sleep 1
  return false

/-- A table of waits and a fake clock over it: what a check of the job runner
works with. Each check has its own, so no check moves another's clock. -/
structure Rig where
  /-- The fake clock. -/
  clock : Job.FakeClock
  /-- The table of waits and the clock, as the runner is given them. -/
  services : Job.Services

/-- A rig whose clock reads 0 and has no waits. -/
def Rig.new : BaseIO Rig := do
  let completions ← Job.Completions.new
  let clock ← Job.FakeClock.new completions
  return { clock, services := { completions, timers := clock.timers } }

/-- A table of published snapshots, each slot a text or `none` for one
released, as the files' model holds them (`FileModel.snapshots`). -/
def snapshotModelTable (table : Array (Option String)) : Array (Option TextContent) :=
  table.map (·.map fun contents => { contents })

/-- A job's outcome as a check compares it: the command it finished with is
replaced by the texts that command leaves, since commands cannot be compared. -/
def texts : Job.Outcome (EditorM Unit) → Job.Outcome (Array String)
  | .finished command => .finished (textsOf command)
  | .failed message => .failed message
  | .cancelled => .cancelled

/-- `job` as it is spawned by a check: it finishes with a command that makes
one text, the job's value as a string. -/
def reporting {α : Type} [ToString α] (job : Unit → JobM α) : Work :=
  Work.of job fun value => makes (toString value)

/-- A job a check spawned. -/
structure Spawned where
  /-- The job. -/
  handle : Job.Handle
  /-- How many times the runner has called the job's `finished`. -/
  finishes : IO.Ref Nat

namespace Spawned

/-- How the job ended, as a check compares it; `none` while it runs. -/
def outcome (spawned : Spawned) : BaseIO (Option (Job.Outcome (Array String))) :=
  return (← spawned.handle.outcome?).map texts

/-- Whether the job ended as `expected`, and the runner then said so once.
Waits for both, with a bound. -/
def endedAs (spawned : Spawned) (expected : Job.Outcome (Array String)) : IO Bool := do
  let ended ← eventually spawned.handle.ended
  -- The runner says a job has ended after it has left the outcome.
  let said ← eventually (return (← spawned.finishes.get) == 1)
  return ended && said && (← spawned.outcome) == some expected

end Spawned

/-- Spawns `work` on `rig`, counting the calls of its `finished`. -/
def Rig.spawn (rig : Rig) (work : Work) : BaseIO Spawned := do
  let finishes ← IO.mkRef 0
  return { handle := ← Job.spawn rig.services work (finishes.modify (· + 1)), finishes }

/-- Runs `job` on the runner over a fake clock of its own, and returns how it
ended. The driver stands in for time: while a wait is waiting it advances the
clock to the earliest deadline. A job that does not end in time has failed. -/
def runOnFake (job : JobM Bool) (rig? : Option Rig := none) : IO (Job.Outcome Bool) := do
  let rig ←
    match rig? with
    | some rig =>
      pure rig
    | none =>
      Rig.new
  let spawned ← rig.spawn (reporting fun _ => job)
  let ended ←
    eventually do
        if ← spawned.handle.ended then
          return true
        if let some deadline← rig.clock.nextDeadline then
          rig.clock.advance (deadline - (← rig.clock.now))
        return false
  unless ended do
    spawned.handle.cancel
    return .failed "the job did not end"
  match ← spawned.outcome with
  | some (.finished texts) =>
    return .finished (texts == #["true"])
  | some (.failed message) =>
    return .failed message
  | _ =>
    return .cancelled

/-- The made-up directory the files of a file property are in, for the model
and for the fake of the file service: an absolute path that is never opened. -/
def fileRoot : System.FilePath :=
  "/files"

/-- The model of the files a file property or a case starts with: the
directory `fileRoot`, and in it `files`, each a name and its bytes, and the
directories `directories`, each a name. -/
def fileModelOf (files : Array (String × ByteArray)) (directories : Array String := #[]) :
    FileModel :=
  files.foldl (fun model (name, bytes) => model.withFile (fileRoot / name) bytes)
    (directories.foldl (fun model (name : String) => model.withDirectory (fileRoot / name))
      (({} : FileModel).withDirectory fileRoot))

/-- The files of `model`, as a file property names them: one in `fileRoot`
by its name, and one outside `fileRoot` by its whole path, so that a file
written where none should be is seen; and each directory directly in
`fileRoot` by its name, with no bytes, as `ContractTest.filesOf` names one.
A file in a directory of `fileRoot`'s is left out, as `ContractTest.filesOf`
reads no directory's own entries. -/
def filesIn (model : FileModel) : Array (String × ByteArray) :=
  let named (path : System.FilePath) : String :=
    if path.parent == some fileRoot then path.fileName.getD path.toString else path.toString
  let deeper (path : System.FilePath) : Bool :=
    path.parent != some fileRoot && path.toString.startsWith (fileRoot.toString ++ "/")
  (model.directories.filter (·.parent == some fileRoot)).map (fun path => (named path, .empty)) ++
    (model.files.filter (!deeper ·.path)).map fun file => (named file.path, file.bytes)

/-- A rig whose services have a fake file service over `model`, and that
service. -/
def Rig.withFiles (model : FileModel) : BaseIO (Rig × Job.FakeFiles) := do
  let rig ← Rig.new
  let files ← Job.FakeFiles.new rig.services.completions model
  return ({ rig with
        services :=
          { rig.services with
            files := files.files, diffs := files.diffs, greps := files.greps } },
      files)

/-- The made-up directory the commands of a process property run in, for the
model and for the fake of the process service: an absolute path that is
never opened. -/
def processRoot : System.FilePath :=
  "/processes"

/-- A rig whose services have a fake process service over `model`, and that
service. -/
def Rig.withProcesses (model : ProcessModel) : BaseIO (Rig × Job.FakeProcesses) := do
  let rig ← Rig.new
  let processes ← Job.FakeProcesses.new rig.services.completions model
  return ({ rig with services := { rig.services with processes := processes.processes } },
      processes)

/-- The made-up directory the watch checks and the watch properties watch,
for the model and the fake: an absolute path that is never opened. -/
def watchRoot : System.FilePath :=
  "/watched"

/-- A rig whose services have a fake watch service over `watches` and a fake
process service over `processes`, whose runs touch the watches with what
their commands change; and the two services. -/
def Rig.withWatches (processes : ProcessModel) (watches : FileWatchModel) :
    BaseIO (Rig × Job.FakeProcesses × Job.FakeFileWatches) := do
  let rig ← Rig.new
  let fileWatches ← Job.FakeFileWatches.new rig.services.completions watches
  let fakeProcesses ← Job.FakeProcesses.new rig.services.completions processes fileWatches.ran
  return ({ rig with
        services :=
          { rig.services with
            processes := fakeProcesses.processes, fileWatches := fileWatches.fileWatches } },
      fakeProcesses, fileWatches)

/-- How many different thread ids `threads` holds. -/
def distinct (threads : Array UInt64) : Nat :=
  (threads.foldl (fun seen thread => if seen.contains thread then seen else seen.push thread)
      #[]).size

/-- How long a warming waits, in milliseconds, for a task to start before it
takes the pool to be full. A task starts on a free thread in microseconds. -/
def warmPatience : Nat :=
  200

/-- An owner of jobs. -/
def anna : Config.Owner :=
  { name := "anna" }

/-- Another owner of jobs. -/
def ben : Config.Owner :=
  { name := "ben" }

/-- No window, and room for every check's paths. -/
def atOnce : FileWatch.Coalescing :=
  { window := 0, bound := 100 }

end ModelTest
