import Editor.Ffi
import Editor.Job.Runner

/-!
# The job runner's real services

The clock port (`Job.Timers`, `Editor/Job/Runner.lean`) answered by the Rust
library's timer service, and the completion pump. This is the only job module
that imports `Editor.Ffi`, so only an executable linked with the library
imports it: the editor, and `contract-test`, which runs the job port's
contract against it.

## The clock

`realTimers` is a thin adapter: each operation of the port is one call of a
binding. A wait goes to the library as its id and its deadline, and the
library queues a completion with that id when the deadline has come.

- **Deadlines are machine words there.** The port's deadlines are `Nat`. One
  that no 64-bit word holds is clamped to the largest, never wrapped:
  wrapped, `2 ^ 64 + 1` is 1, a deadline in the past, and the wait would
  complete at once.
- **A wait the service refuses ends as `cancelled`.** The service refuses
  an id that is already waiting, or when it cannot start its thread. The
  job cannot go on without its wait, and must not wait for ever.

## The pump

`pump` is the one place completions come back in: a loop that pulls the
completion queue and, for each completion, ends the wait whose id it
carries (`Completions.finish`). It blocks in the library, so it runs on a
dedicated task, never one of the pool's, and there is one for the process's
one table of waits. Quitting the queues ends it.

A completion for an id that is no longer waiting, because its job was
cancelled meanwhile, is dropped by the table.

## Tests

`contract-test` (`ContractTest.lean`), in the gate: the job port's contract
over these services, and what only the real service can show.
-/

namespace Editor.Job

/-- `deadline` as the library takes it: a 64-bit word, the largest there is
for a deadline no word holds. Converted without looking, such a deadline
would wrap round to an early one. -/
def word (deadline : Nat) : UInt64 :=
  (min deadline (UInt64.size - 1)).toUInt64

/-- The clock port answered by the library's timer service. `completions` is
the table its waits are registered in. -/
def realTimers (completions : Completions) : Timers :=
  { now := (return (← Ffi.timersNow).toNat : IO Nat).catchExceptions fun _ => pure 0
    start := fun id deadline => do
      let started ← (Ffi.timersStart id (word deadline)).catchExceptions fun _ => pure false
      -- Nothing will complete a wait the service did not take.
      unless started do
        completions.finish id .cancelled
    cancel := fun id =>
      (discard <| Ffi.timersCancel id : IO Unit).catchExceptions fun _ => pure () }

/-- The completion pump: pulls the completion queue and ends the wait each
completion names, until the queues are quit. It blocks in the library: run it
on a dedicated task. -/
def pump (completions : Completions) : IO Unit := do
  repeat
    let event ← Ffi.nextEvent .completion
    if event.kind == .quit then
      break
    if event.kind == .completion then
      completions.finish event.code .completed

end Editor.Job
