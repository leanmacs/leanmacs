import Editor.Command
import Editor.Command.Model
import Editor.Display
import Editor.Invocation
import Editor.Job
import Editor.Job.Runner
import Editor.Program
import Editor.Text
import Editor.Text.Model

/-!
# The linked test kit: Jobs

Jobs on the real runner: how long a check waits (`patience`, `eventually`), a
job's outcome as a check compares it (`texts`), a job that reports its value,
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

/-- How long a check waits, in milliseconds, for something that should happen
at once. Only broken code takes this long, and the check then fails instead
of hanging. -/
def patience : Nat :=
  5000

/-- Polls `condition` until it holds; `false` if it still does not after
`patience` milliseconds. -/
def eventually (condition : IO Bool) : IO Bool := do
  let deadline := (← IO.monoMsNow) + patience
  repeat
    if ← condition then
      return true
    if (← IO.monoMsNow) >= deadline then
      break
    IO.sleep 1
  return false

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

/-- Whether the job behind `handle` ended as `expected`, within the bound. -/
def endedAs (handle : Job.Handle) (expected : Job.Outcome (Array String)) : IO Bool := do
  let ended ← eventually handle.ended
  return ended && (← handle.outcome?).map texts == some expected

/-- Runs `job` on the runner over the library's services, and returns how it
ended. A job that does not end in time has failed, and is cancelled. A job
that ended is settled, as whoever takes a finished job's result settles it,
so what its loads made is released. -/
def runOnTimers (services : Job.Services) (job : JobM Bool) : IO (Job.Outcome Bool) := do
  let handle ← Job.spawn services (reporting fun _ => job) (pure ())
  unless ← eventually handle.ended do
    handle.cancel
    return .failed "the job did not end"
  handle.settle
  match (← handle.outcome?).map texts with
  | some (.finished texts) =>
    return .finished (texts == #["true"])
  | some (.failed message) =>
    return .failed message
  | _ =>
    return .cancelled

end Editor.Test.Linked
