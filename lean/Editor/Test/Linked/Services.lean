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
of a feature that runs processes compares before and after.

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
  process service, its watch service, its diff service and its matcher. -/
  jobs : Job.Services
  /-- The completion pump, when these services started it (`Services.start`);
  none over a table another's pump runs over (`Services.over`). -/
  pump : Option (Task (Except IO.Error Unit))

/-- The real services over `completions`, a table of waits whose pump is
already running or is started by the caller: the library's timer service,
its file service over a table of snapshots of its own, its process service,
its watch service, its diff service and its matcher. It starts no pump. -/
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
killed and reaped, every watch is ended, and the queues are quit, for good
and process-wide. The caller exits explicitly afterwards. A test whose
process held a host ends with it, so that a child a failed check left is
not left behind. -/
def shutdown : IO Unit := do
  Ffi.processesShutdown
  Ffi.watchesShutdown
  Ffi.quit

/-- How many children the library's process service has started and not yet
reaped. A check reads it before it starts a child and requires it again
afterwards. -/
def pendingChildren : IO UInt64 :=
  Ffi.processesPending

end Editor.Test.Linked
