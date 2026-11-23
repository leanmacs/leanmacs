import Editor.Command
import Editor.Command.Model
import Editor.Display
import Editor.InferredWait
import Editor.Invocation
import Editor.Job
import Editor.Job.Runner
import Editor.Program
import Editor.Text
import Editor.Text.Model

/-!
# The linked test kit: Jobs

Jobs on the real runner: what a check waits on (a task or promise,
`hangGuarded`; a start reaching the library, `startsArrive`; a rig's idle,
`untilIdle`) and the hang guard that bounds it (`patience`), a job's
outcome as a check compares it (`texts`), a job that reports its value,
whether a job ended as expected, and a run of jobs on the runner over the
library's timer service. Shared by several test modules; it holds no checks of
its own.

Published for a package's linked test: it is a module of the core's linked
test kit, in the namespace `Editor.Test.Linked`, which the root of a
package's linked test and the modules under it may import, and no other
module of a package may (`docs/design/packages.md`, "What a package may
import"). The core's own
checks against the real bindings (`contract-test`) are written on it.
-/

namespace Editor.Test.Linked

open Editor

/-- The guard of an event a check waits for that must come (a job's end, a
start reaching the library, a pump's end); only a hang reaches it, and the
check then fails as a hang. Ten times the slowest
such event seen under the stress load and more, as `Editor.Test.Linked.hangGuard` is
set, and the same 260 000. -/
def patience : HangGuard :=
  .on "the event the check waits for" 260000

/-- `task`'s value, waited for on the task itself, an event that must come:
`what` names it. The bound is `patience`, a hang guard: past it this throws
a hang, and the check fails as one. -/
def hangGuarded {α : Type} (what : String) (task : Task α) : IO α := do
  let some value ←
    Job.awaitWithin patience
        task | throw <| IO.userError s!"a hang: {what} had not come within {patience.ms} ms"
  return value

/-- `startsArrive` is an inferred wait (`Editor/InferredWait.lean`). -/
def startsArrive.inferredWait : InferredWait :=
  .firstAfter []

/-- `start`, a real port's start of a request, decorated to resolve the
promise it returns once its `count`-th call has returned: the `count`-th
request has been handed to the library, which counts it from then. What a
check waits on for a job that has reached its wait on a real service: the
job keeps its unit there, so no idle can say it is in. A `count` of 0 is
resolved at once. -/
def startsArrive {ρ : Type} (start : UInt64 → ρ → BaseIO Unit) (count : Nat) :
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

/-- `untilIdle` is an inferred wait (`Editor/InferredWait.lean`). -/
def untilIdle.inferredWait : InferredWait :=
  .idle [`Editor.Job.Runner, `Editor.Job.Activity]

/-- Waits until `activity`, a count of a rig's own (`Job.Activity.counting`),
reads 0: every job on it is parked in a wait only the check ends, or has
ended. Waited for on the count's own changes, never by time; the bound is a
hang guard. It is sound after a cancel too: a job parking gives back its
unit only once its wait is recorded as its own or withdrawn (`Job.drive`),
so a cancelled job holds a unit until it has ended. -/
def untilIdle (activity : Job.Activity) : IO Unit := do
  unless activity.tracked do
    throw <| IO.userError "this count is not kept: it is never idle"
  repeat
    let seen ← activity.seen
    if seen.running == 0 then
      return
    hangGuarded s!"a change of the count from {repr seen}" (← activity.changedSince seen.epoch)
  throw <| IO.userError "unreachable"

/-- A job's outcome as a check compares it: the command it finished with is
replaced by the texts that command leaves when it runs against the editor's
models, since commands cannot be compared. -/
def texts : Job.Outcome (EditorM Unit) → Job.Outcome (Array String)
  | .finished command =>
    .finished (command.runModel (.over { advance := 1, lineHeight := 1 })).2.texts.contents
  | .failed message => .failed message
  | .cancelled => .cancelled

/-- `job` as it is spawned by a check: it finishes with a command that makes
one text, the job's value as a string. -/
def reporting {α : Type} [ToString α] (job : Unit → JobM α) : Work :=
  Work.of job fun value => discard <| createText (toString value)

/-- Whether the job behind `handle` ended as `expected`: its end is waited for
on its outcome, an event, and a hang past `patience` is thrown. -/
def endedAs (handle : Job.Handle) (expected : Job.Outcome (Array String)) : IO Bool := do
  discard <| hangGuarded "the job's end" handle.outcome.result?
  return (← handle.outcome?).map texts == some expected

/-- Runs `job` on the runner over the library's services, and returns how it
ended. Its end is waited for on its outcome; a job that has not ended within
`patience`, a hang guard, has hung: it is cancelled, and has failed. A job
that ended is settled, as whoever takes a finished job's result settles it,
so what its loads made is released. -/
def runOnTimers (services : Job.Services) (job : JobM Bool) : IO (Job.Outcome Bool) := do
  let handle ← Job.spawn services (reporting fun _ => job) (pure ())
  if (← Job.awaitWithin patience handle.outcome.result?).isNone then
    handle.cancel
    return .failed s!"a hang: the job had not ended within {patience.ms} ms"
  handle.settle
  match (← handle.outcome?).map texts with
  | some (.finished texts) =>
    return .finished (texts == #["true"])
  | some (.failed message) =>
    return .failed message
  | _ =>
    return .cancelled

end Editor.Test.Linked
