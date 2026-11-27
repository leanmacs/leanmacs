import Echo.Real
import EchoTest.Check
import Editor.RealHost
import Editor.Test.Linked.Jobs
import Editor.Test.Linked.Services

/-!
# Linked tests: a child taken over by echo's library

A streaming child opened through the linked test kit's real process service
(`services.jobs.processes`, the port a job's `Process.start` reaches) is
handed by its number to the binding `Echo.Real.attach`, and the package's
library, loaded when the program started, takes it over through the package
runtime alone (its `take_over`, over the stream source `editor-ffi` provided
when the core's library started). The library reads the child's lines
through the runtime, writes `pong` back when it reads `ping-me`, sees its
exit, and completes a request of its own service through the runtime, which
the kit's pump ends and Lean takes (`Echo.Real.attachTakeRaw`). So a
library that carries no copy of `editor-service`'s statics reaches the
core's one process service and completion queue.

The child's bound is the opener's choice, in megabytes, as an agent's would
be. Each wait is on the completion itself (`Job.awaitWithin`), the kit's
patience a hang guard.

What it covers is wiring alone. The orderings (a cancel or a shutdown while
the consumer is blocked in a pull, a child that exits before its hand-off,
the waiter's wake of a consumer waiting for the end) are forced and pinned
on the port's fake in `editor-process`'s `service/hand_off.rs`, and the
port's rules by its contract, on the fake and on real processes.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.EchoTest.Linked.Echo.Real.Attach : Editor.WiringSet :=
  .wiring "the library's process service, taken over by echo's library through the package runtime"
    "the subject is a child the real process port opened; no fake opens a child the crate can take"

namespace EchoTest.Linked

open Editor

/-- Whether `wait` ends as completed, waited for on the wait itself; the
kit's patience is a hang guard. -/
private def completes (wait : IO.Promise Job.Completion) : IO Bool := do
  return (← Job.awaitWithin Test.Linked.patience wait.result?) == some (some .completed)

/-- Opens `/bin/sh -c script` in `directory` as a streaming child through
`processes`, the real process port, with its input piped and a bound of four
mebibytes, and gives its number once it is open. -/
private def opened (processes : Job.Processes) (completions : Job.Completions)
    (directory : System.FilePath) (script : String) : IO (Option UInt64) := do
  let request :=
    ProcessRequest.start { program := "/bin/sh", arguments := #["-c", script], directory }
      { input := true, bound := 4 * 1024 * 1024 }
  let (child, wait) ← completions.register
  processes.start child request
  unless ← completes wait do
    return none
  match ← processes.take child request with
  | .ok _ =>
    return some child
  | .error _ =>
    return none

/-- Hands `child` to the crate as a request of its own, and gives what the
crate read once the request has completed: `none` if the take-over was
refused or the request did not complete. -/
private def attached (completions : Job.Completions) (child : UInt64) : IO (Option String) := do
  let (request, done) ← completions.register
  unless ← Echo.Real.attach request child do
    completions.finish request .completed
    return none
  unless ← completes done do
    return none
  return (← Echo.Real.attachTakeRaw request).map (·.1)

/-- The checks of a child taken over by the crate, over `services`, whose
pump is running. -/
def attachChecks (services : Editor.Test.Linked.Services) : List Check :=
  let processes := services.jobs.processes
  let completions := services.completions
  [{  name :=
        "the crate takes over a child the core's process service opened, reads its lines, writes to it and sees its exit"
      run :=
        Editor.Test.Linked.withFiles services.jobs (targets := [.processes]) fun directory => do
          let script := "echo one; echo ping-me; read x; echo \"got $x\"; echo three; exit 2"
          let some child ←
            opened processes completions directory script | saw false "the child was not opened"
          let read ← attached completions child
          let expected := "one\nping-me\ngot pong\nthree\n<exited 2>"
          saw (read == some expected) s!"{repr read}" },
    { name := "a cancel through the job port reaches the crate blocked in a pull"
      run :=
        Editor.Test.Linked.withFiles services.jobs (targets := [.processes]) fun directory => do
          let some child ←
            opened processes completions directory "read x" | saw false "the child was not opened"
          let (request, done) ← completions.register
          let taken ← Echo.Real.attach request child
          -- The crate's consumer pulls, and the child writes nothing: a
          -- pull blocks until the cancel, or answers it if it comes first.
          processes.cancel child
          let completed ←
            if taken then
              completes done
            else
              pure false
          let read := (← Echo.Real.attachTakeRaw request).map (·.1)
          saw (taken && completed && read == some "<cancelled>")
              s!"taken {taken}, completed {completed}, read {repr read}" },
    { name := "a child whose last delivery the crate pulled is forgotten, and not taken over again"
      run :=
        Editor.Test.Linked.withFiles services.jobs (targets := [.processes]) fun directory => do
          let some child ←
            opened processes completions directory
                "echo done" | saw false "the child was not opened"
          let first ← attached completions child
          let again ← attached completions child
          saw (first == some "done\n<exited 0>" && again.isNone)
              s!"first {repr first}, again {repr again}" }]

end EchoTest.Linked
