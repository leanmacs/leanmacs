import Editor.Ffi.Document
import Editor.Ffi.Events
import Editor.Ffi.Processes
import Editor.Ffi.Snapshot
import Editor.Ffi.Watches
import Editor.Fuzzy.Real
import Editor.InferredWait
import Editor.Job.Fake
import Editor.Job.Real
import Editor.Job.Runner
import Editor.RealHost
import Editor.Test.Linked.Jobs

/-!
# The linked test kit: Services

The library's real job services, as a test linked with the Rust library
runs its checks over them: the timer, file, process, watch and diff
services and the matcher, over one table of waits (`Services.over`); that
table with the completion pump running over it (`Services.start`); the
shutdown that ends the pump (`Services.stop`), and the one a process that
held a host ends with (`shutdown`); and how many children the process
service has started and not yet reaped (`pendingChildren`), which a check
of a feature that runs processes compares before and after, once the
service has been flushed (`childrenReapedTo`); and the bracket a check's
temporary directory lives in (`withFiles`), which removes it only once the
services have worked what was handed to them under it. And the job
services of a stepped check (`SteppedServices`): the fake scheduler, the
fake completion pump, and the file, diff, grep and process fakes and the
package services' fakes answering through it, over one table of waits,
which the check steps on its own thread.

**One table and one pump a process.** The library has one completion queue,
and a pump ends the wait each completion names in the one table it is given
(`Job.pump`), so a second pump over another table would take the first
one's completions. A process that has a host already
(`Editor.Headless.shipped`, which makes a table and starts the pump) makes
its checks' services over the host's table (`Services.over`); one with no
host starts them (`Services.start`), as `contract-test` does.

Published for a package's linked test: it is a module of the core's linked
test kit, in the namespace `Editor.Test.Linked`, which the root of a
package's linked test and the modules under it may import, and no other
module of a package may (`docs/design/packages.md`, "What a package may
import"). It names the raw
bindings and the real job services so that a package's linked test need
not.
-/

namespace Editor.Test.Linked

open Editor

/-- The real job services of a test process, with what a check of them
reads beside them. -/
structure Services where
  /-- The table of waits the services share. -/
  completions : Job.Completions
  /-- The table of snapshots the file service and the diff service read. No
  text publishes to it unless a check hands it to one. -/
  published : Snapshots
  /-- What the jobs hold. -/
  held : Job.HeldSnapshots
  /-- The services: the library's timer service, its file service, its
  process service, its watch service, its diff service, its grep service and
  its matcher. -/
  jobs : Job.Services
  /-- The completion pump, when these services started it (`Services.start`);
  none over a table another's pump runs over (`Services.over`). -/
  pump : Option (Task (Except IO.Error Unit))

/-- The job services of a stepped check, every one a fake that the check
steps on its own thread (`step`): the fake scheduler (`Job.FakeScheduler`),
which runs a job's code only when stepped; the fake completion pump
(`Job.FakePump`); the file service's fake (`Job.FakeFiles`) as the files,
the diffs and the searches, and the process service's (`Job.FakeProcesses`),
both answering through the pump (`FakeAnswer.onStep`); the clock and the
watches handed in, whose waits end on the check's own `advance` and
`change`; the library's matcher (`Fuzzy.real`) and the snapshot reads
handed in. Nothing here starts a thread: so "nothing can run" is a
property of the check's own objects, read on its own thread, never of a
count another thread moves. -/
structure SteppedServices where
  /-- The fake scheduler the jobs' code runs on. -/
  scheduler : Job.FakeScheduler
  /-- The fake pump the file and process fakes answer through. -/
  pump : Job.FakePump
  /-- The files, the diffs and the searches. -/
  files : Job.FakeFiles
  /-- The processes. -/
  processes : Job.FakeProcesses
  /-- The package services' fakes (`Job.FakePackageService`), each over its
  spec, answering through the pump, their hand-offs taken from
  `processes`. -/
  packages : Array Job.FakePackageService := #[]
  /-- The services a runner is given, over the fakes. -/
  jobs : Job.Services

/-- The stepped services over `completions`, with the clock `clock`, the
watches `watches`, the files of `files` and the runs of `processes`: a
published snapshot is read through `snapshots`, by the job's snapshot
reads and by the file fake when it takes a save, a diff or a search that
names one (`Job.FakeFiles.learn`); a load the fake makes is held in `held`,
the host's table of what its jobs hold, as a library snapshot of its text
(`Job.FakeFiles.holding`); and a fake of each of `packages`, the services a
package brings, over the pump and the process fake. -/
def SteppedServices.new (completions : Job.Completions) (clock : Job.FakeClock)
    (watches : Job.FakeFileWatches) (snapshots : SnapshotId → BaseIO (Option String))
    (held : Job.HeldSnapshots) (files : FileModel := {}) (processes : ProcessModel := {})
    (packages : Array Job.FakePackageService.Spec := #[]) : IO SteppedServices := do
  let scheduler ← Job.FakeScheduler.new
  let pump ← Job.FakePump.new completions
  -- A load the fake made is held in the host's table as a library snapshot
  -- of its text, so a finished job's command adopts it as it would the
  -- library's own.
  let holding (id : JobSnapshotId) : Option String → BaseIO Unit
    | some text => do
      match
        ←
          (do
                (← Ffi.Document.new text).snapshot : IO Ffi.Snapshot).toBaseIO with
      | .ok snapshot =>
        held.put id snapshot
      | .error _ =>
        pure ()
    | none => held.release id
  let fakeFiles ← Job.FakeFiles.new completions files (.onStep pump) snapshots holding
  let fakeProcesses ← Job.FakeProcesses.new completions processes (answer := .onStep pump)
  let fakePackages ←
    packages.mapM fun spec =>
        Job.FakePackageService.new completions spec (some fakeProcesses) (.onStep pump)
  return {
      scheduler, pump, files := fakeFiles, processes := fakeProcesses, packages := fakePackages
      jobs :=
        { completions, timers := clock.timers, files := fakeFiles.files
          processes := fakeProcesses.processes, fileWatches := watches.fileWatches
          diffs := fakeFiles.diffs, greps := fakeFiles.greps, fuzzy := Fuzzy.real, snapshots
          scheduler := scheduler.scheduler
          packages := Job.PackageServices.of (fakePackages.map (·.service)) } }

/-- Runs one piece of work of the stepped services, on the caller's thread:
the oldest piece of a job's code that can run, else the oldest due
completion; `false` when neither can. -/
def SteppedServices.step (services : SteppedServices) : IO Bool := do
  if ← services.scheduler.step then
    return true
  services.pump.step

/-- Whether the stepped services hold nothing: no job's code is left to
run, no completion is due, and no package service's fake holds a request. -/
def SteppedServices.quiescent (services : SteppedServices) : IO Bool := do
  return (← services.scheduler.quiescent) && (← services.pump.quiescent) &&
      (← services.packages.allM (·.quiescent))

/-- The mark of `Services.over`: it runs a real background service (`Editor/RealHost.lean`). -/
def Services.over.realHost : RealHost :=
  .service

/-- The real services over `completions`, a table of waits whose pump is
already running or is started by the caller: the library's timer service,
its file service over a table of snapshots of its own, its process service,
its watch service, its diff service, its grep service over the same table
and its matcher. It starts no pump. -/
def Services.over (completions : Job.Completions) : IO Services := do
  let published ← Snapshots.new
  let held ← Job.HeldSnapshots.new
  let timers := Job.realTimers completions
  let jobs : Job.Services :=
    { completions, timers
      files := Job.realFiles completions published.reader held
      processes :=
        Job.realProcesses completions (← Job.RefusedRuns.new) timers (← Job.TimedRuns.new)
      fileWatches := Job.realFileWatches completions (← Job.RealWatches.new)
      diffs := Job.realDiffs completions published.reader held (← Job.RefusedDiffs.new)
      greps := Job.realGreps completions published.reader held (← Job.RealGreps.new)
      fuzzy := Fuzzy.real }
  return { completions, published, held, jobs, pump := none }

/-- The mark of `Services.start`: it runs a real background service (`Editor/RealHost.lean`). -/
def Services.start.realHost : RealHost :=
  .service

/-- The real services over a table of waits of their own (`Services.over`),
with the completion pump started over it on a dedicated task, for the rest
of the run. A process calls it once, and only when it has no host: see the
module docs. -/
def Services.start : IO Services := do
  let completions ← Job.Completions.new
  let services ← Services.over completions
  let pump ← IO.asTask (prio := .dedicated) (Job.pump completions)
  return { services with pump := some pump }

/-- Quits the library's queues, for good and process-wide, and says whether
the pump these services started has ended, waited for on the pump's task
with `patience`, a hang guard; `true` when they started none. The caller
exits explicitly afterwards: a task that failed a check may still be blocked
in the library. -/
def Services.stop (services : Services) : IO Bool := do
  Ffi.quit
  match services.pump with
  | some pump =>
    return (← Job.awaitWithin patience pump).isSome
  | none =>
    return true

/-- Ends the library's services as a host's `main` does once its script has
run (`Editor.Headless.main`): every child the process service started is
killed and reaped, every watch is ended, every search is ended, and the
queues are quit, for good
and process-wide. The caller exits explicitly afterwards. A test whose
process held a host ends with it, so that a child a failed check left is
not left behind. -/
def shutdown : IO Unit := do
  Ffi.processesShutdown
  Ffi.watchesShutdown
  Ffi.grepShutdown
  Ffi.quit

/-- `pendingChildren` is an inferred wait (`Editor/InferredWait.lean`). -/
def pendingChildren.inferredWait : InferredWait :=
  .count []

/-- How many children the library's process service has started and not yet
reaped. A check reads it before it starts a child and requires it again
afterwards. -/
def pendingChildren : IO UInt64 :=
  Ffi.processesPending

/-- The guard of a flush's end (`childrenReapedTo`, `flushedAll`,
`filesFlushed`, `withFiles`), which comes once the work before it has been
worked; only a hang reaches it, and the check then fails as a hang. -/
def reapPatience : HangGuard :=
  .on "the flush's end" 10000

/-- Whether a flush of each of `targets` among `jobs`, asked in turn, is
completed: each service has then finished the work handed to it before. -/
def flushedAll (jobs : Job.Services) (targets : List Job.Service) : IO Bool :=
  targets.allM fun target => do
    return (← Job.awaitWithin reapPatience (← jobs.flushed target)) == some .completed

/-- Whether a flush of the library's file service, through the table
`completions`, whose pump runs, is completed: every file request handed to
it before has been worked. For a check that has the table and no
`Job.Services`. -/
def filesFlushed (completions : Job.Completions) : IO Bool := do
  let (id, wait) ← completions.register
  Job.flushThrough completions Ffi.filesFlush id
  return (← Job.awaitWithin reapPatience (wait.resultD .cancelled)) == some .completed

/-- `childrenReapedTo` is an inferred wait (`Editor/InferredWait.lean`). -/
def childrenReapedTo.inferredWait : InferredWait :=
  .count []

/-- Whether the library's process service, flushed through `jobs`, is back to
`before` children: the flush (`Job.Services.flushed .processes`) is
completed once every run started before it has ended and every child
cancelled before it has been reaped, and `pendingChildren` is then read
once. It replaces a poll of the count: a check reads `pendingChildren`
before it starts a child and asks this afterwards. -/
def childrenReapedTo (jobs : Job.Services) (before : UInt64) : IO Bool := do
  let flushed ← Job.awaitWithin reapPatience (← jobs.flushed .processes)
  return flushed == some .completed && (← pendingChildren) == before

/-- The name of `service`, as a hang says it. -/
private def serviceName : Job.Service → String
  | .timers => "timer"
  | .files => "file"
  | .processes => "process"
  | .fileWatches => "watch"
  | .diffs => "diff"
  | .greps => "grep"
  | .package name => name

/-- Waits for a flush of each of `targets` among `jobs`, asked in turn, with no
deadline: one not completed within `guard` after it was asked is said
through `hung` as a hang, once, and still waited for, and one the service
refuses is said through `hung` too, since nothing more will be worked. -/
private def workedBefore (jobs : Job.Services) (targets : List Job.Service) (guard : HangGuard)
    (hung : String → IO Unit) : IO Unit := do
  for target in targets do
    let flushed ← jobs.flushed target
    let completion ←
      -- Past the guard the hang is said, and the flush still waited for.
      match ← Job.awaitWithin guard flushed with
      | some completion =>
        pure completion
      | none =>
        hung
            s!"a hang: the {serviceName target} service had not completed a flush {guard.ms} ms after it was asked; waiting for it"
        IO.wait flushed
    if completion == .cancelled then
      hung
          s!"the {serviceName target} service refused a flush: its queues are quit, and nothing more will be worked"

/-- Runs `body` in a fresh temporary directory and removes it only once the
library's services have worked what was handed to them before: whether `body`
returned or threw, a flush of each of `targets` through `jobs`
(`Job.Services.flushed`) is waited for, in turn, with no deadline. A flush not
completed within `guard` after it was asked is said through `hung` as a
hang, once, and still waited for. A flush the service refuses (the queues are
quit) is said through `hung` too, since nothing more will be worked.

A check whose requests under the directory go to the file service, the
default, writes `withFiles services fun directory => …`; one whose children
run there, or whose watches start there, names that service in `targets`.
A check that runs a host over the directory nests the host's bracket inside
(`withFiles … fun directory => Headless.withHost … fun host => …`): the
loop has ended, so it hands out nothing more, before the flushes are asked,
and each flush is behind every request the loop's jobs handed out,
cancelled ones included. -/
def withFiles {α : Type} (jobs : Job.Services) (body : System.FilePath → IO α)
    (targets : List Job.Service := [.files]) (guard : HangGuard := reapPatience)
    (hung : String → IO Unit := IO.eprintln) : IO α := do
  let directory ← IO.FS.createTempDir
  try
    body directory
  finally
    workedBefore jobs targets guard hung
    IO.FS.removeDirAll directory

end Editor.Test.Linked
