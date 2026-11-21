import Editor.Ffi.Events
import Editor.Ffi.Processes
import Editor.Ffi.Watches
import Editor.Fuzzy.Real
import Editor.Job.Real
import Editor.Job.Runner
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
services have worked what was handed to them under it.

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
the pump these services started has ended, within `patience`; `true` when
they started none. The caller exits explicitly afterwards: a task that
failed a check may still be blocked in the library. -/
def Services.stop (services : Services) : IO Bool := do
  Ffi.quit
  match services.pump with
  | some pump =>
    eventually (IO.hasFinished pump)
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

/-- How many children the library's process service has started and not yet
reaped. A check reads it before it starts a child and requires it again
afterwards. -/
def pendingChildren : IO UInt64 :=
  Ffi.processesPending

/-- How long `childrenReapedTo` waits for its flush: a guard against a hang,
never a result. -/
def reapPatience : Nat :=
  10000

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

/-- Waits for a flush of each of `targets` among `jobs`, asked in turn, with no
deadline: one not completed `guard` milliseconds after it was asked is said
through `hung` as a hang, once, and still waited for, and one the service
refuses is said through `hung` too, since nothing more will be worked. -/
private def workedBefore (jobs : Job.Services) (targets : List Job.Service) (guard : Nat)
    (hung : String → IO Unit) : IO Unit := do
  for target in targets do
    let flushed ← jobs.flushed target
    let completion ←
      match ← Job.awaitWithin guard flushed with
      | some completion =>
        pure completion
      | none =>
        hung
            s!"a hang: the {serviceName target} service had not completed a flush {guard} ms after it was asked; waiting for it"
        IO.wait flushed
    if completion == .cancelled then
      hung
          s!"the {serviceName target} service refused a flush: its queues are quit, and nothing more will be worked"

/-- Runs `body` in a fresh temporary directory and removes it only once the
library's services have worked what was handed to them before: whether `body`
returned or threw, a flush of each of `targets` through `jobs`
(`Job.Services.flushed`) is waited for, in turn, with no deadline. A flush not
completed `guard` milliseconds after it was asked is said through `hung` as a
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
    (targets : List Job.Service := [.files]) (guard : Nat := reapPatience)
    (hung : String → IO Unit := IO.eprintln) : IO α := do
  let directory ← IO.FS.createTempDir
  try
    body directory
  finally
    workedBefore jobs targets guard hung
    IO.FS.removeDirAll directory

end Editor.Test.Linked
