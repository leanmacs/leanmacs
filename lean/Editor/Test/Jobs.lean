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
import Editor.Test.Models
import Editor.Text
import Editor.Text.Model

/-!
# The test kit: Jobs

Jobs run on the job model and on the runner over its fakes (`Rig`): the fakes'
roots, what a check waits on (the rig's idle, `Rig.idle`; a job's outcome; a
start reaching a service, `startGate`) and the hang guard that bounds it
(`patience`), a job's outcome as a check compares it, and a table of
published snapshots. A check never polls for a state with a deadline: it
waits for the event, or for idle and then reads once.
Shared by several test modules under `ModelTest/Editor/`; it holds no checks of
its own.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import"). The core's own model tests are written on it.
-/

namespace Editor.Test

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

/-- The guard of an event a check waits for that must come (a job's end, a
fake's arrival, the rig's idle, a start reaching a service); only a hang
reaches it, and the check then fails as a hang. Ten times the slowest such event seen under the stress load and more, as
`Editor.Test.Linked.hangGuard` is set. -/
def patience : HangGuard :=
  .on "the event the check waits for" 120000

/-- `task`'s value, waited for on the task itself, an event that must come:
`what` names it. The bound is `patience`, a hang guard: past it this throws
a hang, and the check fails as one. -/
def awaitEvent {α : Type} (what : String) (task : Task α) : IO α := do
  let some value ←
    Job.awaitWithin patience
        task | throw <| IO.userError s!"a hang: {what} had not come within {patience.ms} ms"
  return value

/-- `start`, a port's start of a request, decorated to resolve the promise it
returns once its `count`-th call has returned: the `count`-th request has
reached the service, and the service has recorded it. What a check waits on
for a request that keeps its job's unit, so that idle cannot say it is there
(a fake's held completions, a real service). A `count` of 0 is resolved at
once. -/
def startGate {ρ : Type} (start : UInt64 → ρ → BaseIO Unit) (count : Nat) :
    BaseIO ((UInt64 → ρ → BaseIO Unit) × IO.Promise Unit) := do
  let arrived ← IO.Promise.new
  let calls ← IO.mkRef 0
  if count == 0 then
    arrived.resolve ()
  let gated := fun id request => do
    start id request
    let made ← calls.modifyGet fun made => (made + 1, made + 1)
    if made == count then
      arrived.resolve ()
  return (gated, arrived)

/-- The count `activity` reads at its next change after `seen`, waited for on
the change itself (`changedSince`). The bound is `patience`, a hang guard:
past it this throws a hang. -/
def changedAfter (activity : Job.Activity) (seen : Job.Activity.Seen) : IO Job.Activity.Seen := do
  awaitEvent s!"a change of the count from {repr seen}" (← activity.changedSince seen.epoch)
  activity.seen

/-- Waits, on the count's own changes, until `activity`'s epoch has reached
`epoch`: the steps a check knows will come, counted from a fresh count, so
it never waits for a change that already happened. The bound is a hang
guard: past it this throws a hang. -/
def untilEpoch (activity : Job.Activity) (epoch : Nat) : IO Unit := do
  repeat
    let seen ← activity.seen
    if seen.epoch >= epoch then
      return
    discard <| changedAfter activity seen
  throw <| IO.userError "unreachable"

/-- A table of waits and a fake clock over it: what a check of the job runner
works with. Each check has its own, so no check moves another's clock.

Its services keep a count of their activity (`Job.Activity.counting`), so a
check waits for the rig to be idle (`Rig.idle`) rather than polling for a
state its jobs reach by themselves. -/
structure Rig where
  /-- The fake clock. -/
  clock : Job.FakeClock
  /-- The table of waits, the clock and the count, as the runner is given
  them. -/
  services : Job.Services

/-- A rig whose clock reads 0 and has no waits, with a fresh count of its
activity. -/
def Rig.new : BaseIO Rig := do
  let completions ← Job.Completions.new
  let clock ← Job.FakeClock.new completions
  let activity ← Job.Activity.counting
  return { clock, services := { completions, timers := clock.timers, activity } }

/-- Waits for the end of each job of `handles`, on its outcome, an event; the
bound is a hang guard (`awaitEvent`). What a check waits for after it has
cancelled jobs, before it waits for idle (`Rig.idle`). -/
def awaitEnded (handles : Array Job.Handle) : IO Unit := do
  for handle in handles do
    discard <| awaitEvent "a cancelled job's end" handle.outcome.result?

/-- Waits until nothing on `rig` can run by itself, and returns the count's
reading then: every job spawned on it is parked in a wait only the check
ends (the fake clock's sleep, a fake watch's next) or has ended, its
`finished` run, and no request is in flight on a service that ends it by
itself. It stays so until the check acts: moves the clock, changes a watch,
lets a fake go, spawns.

It is sound after a cancel too: a job parking gives back its unit only once
its wait is recorded as its own or withdrawn (`Job.drive`), so a cancelled
job holds a unit from the cancel, or from its own withdrawal, until its
`finished` has run, and idle after a cancel means the job has ended. The
checks that wait for a cancelled job's end first (`awaitEnded`) wait for
an event that idle now implies.

Waited for on the count's own changes, never by time; the bound is a hang
guard (`changedAfter`). A rig whose services keep no count is refused: it
is never idle. -/
def Rig.idle (rig : Rig) : IO Job.Activity.Seen := do
  let activity := rig.services.activity
  unless activity.tracked do
    throw <| IO.userError "this rig's services keep no count of their activity: it is never idle"
  repeat
    let seen ← activity.seen
    if seen.running == 0 then
      return seen
    discard <| changedAfter activity seen
  throw <| IO.userError "unreachable"

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
  /-- Waits for the rig the job was spawned on to be idle (`Rig.idle`). -/
  idle : IO Unit

namespace Spawned

/-- How the job ended, as a check compares it; `none` while it runs. -/
def outcome (spawned : Spawned) : BaseIO (Option (Job.Outcome (Array String))) :=
  return (← spawned.handle.outcome?).map texts

/-- Whether the job ended as `expected`, and the runner then said so once.
Waits for the job's end on its outcome, an event, and then for the rig's
idle: the runner calls `finished` after it has left the outcome and gives
the job's unit back after that, so at idle no further call can come and the
count read then is the whole of it. Each wait's bound is a hang guard:
past it this throws a hang. -/
def endedAs (spawned : Spawned) (expected : Job.Outcome (Array String)) : IO Bool := do
  discard <| awaitEvent "the job's end" spawned.handle.outcome.result?
  spawned.idle
  return (← spawned.finishes.get) == 1 && (← spawned.outcome) == some expected

end Spawned

/-- Spawns `work` on `rig`, counting the calls of its `finished`. -/
def Rig.spawn (rig : Rig) (work : Work) : BaseIO Spawned := do
  let finishes ← IO.mkRef 0
  return {
      handle := ← Job.spawn rig.services work (finishes.modify (· + 1)), finishes
      idle := discard rig.idle }

/-- Steps the job behind `handle` on `rig` to its end, standing in for time:
at each idle of the rig, if the job has ended it stops; else, if a wait is
due on the fake clock, it advances the clock to the earliest deadline and
waits for the next idle; else the job is stuck in a wait nothing here ends,
and it says so. `none` once the job has ended, else why it has not, the job
then cancelled. Only the idle's hang guard bounds it; a hang is said as
well. -/
def Rig.stepToEnd (rig : Rig) (handle : Job.Handle) : IO (Option String) := do
  try
    repeat
      discard <| rig.idle
      if ← handle.ended then
        return none
      let some deadline ← rig.clock.nextDeadline |
        handle.cancel
        -- Nothing it started outlives the driver.
        awaitEnded #[handle]
        return some "the job is stuck: at idle it had not ended, and no wait was due on the clock"
      rig.clock.advance (deadline - (← rig.clock.now))
    return some "unreachable"
  catch error =>
    handle.cancel
    return some (toString error)

/-- Runs `job` on the runner over a fake clock of its own, and returns how it
ended. The driver stands in for time, stepped on the rig's idle
(`Rig.stepToEnd`): at each idle it advances the clock to the earliest
deadline. A job stuck at idle, or one that hangs, has failed. -/
def runOnFake (job : JobM Bool) (rig? : Option Rig := none) : IO (Job.Outcome Bool) := do
  let rig ←
    match rig? with
    | some rig =>
      pure rig
    | none =>
      Rig.new
  let spawned ← rig.spawn (reporting fun _ => job)
  if let some why← rig.stepToEnd spawned.handle then
    return .failed s!"the job did not end: {why}"
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

/-- An owner of jobs. -/
def anna : Config.Owner :=
  { name := "anna" }

/-- Another owner of jobs. -/
def ben : Config.Owner :=
  { name := "ben" }

/-- No window, and room for every check's paths. -/
def atOnce : FileWatch.Coalescing :=
  { window := 0, bound := 100 }

end Editor.Test
