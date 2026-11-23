import Editor.Bound
import Editor.Job.Pump
import Editor.Job.Runner

/-!
# The contract of the completion pump

What the pump (`Editor/Job/Pump.lean`) keeps over whatever hands it its
completions, as a list of properties over a `PumpRig`: the rig gives the
table of waits, how to hand the completion of a wait, and how to run the
pump until what was handed is finished. The same list runs two ways:

- over the fake pump (`FakePump`, `Editor/Job/Fake.lean`), by `model-test`
  (`ModelTest.pumpContractChecks`): `hand` is the fake's, and `run` closes
  its source and runs `pumpFrom` over it on the check's thread;
- over the library's completion queue, by `contract-test`
  (`ContractTest.pumpContractChecks`): `hand` is a flush of the library's
  file service as the wait (`Job.flushThrough`), completed in queue order
  by its one in-order worker, and `run` does nothing, since the root's pump
  runs over the queue.

**A deadline here is a hang guard, never a result**: each property awaits
its own wait's task under `patience`, and one not ended within it is
reported as a hang.

This module imports the runner's table and the pump's port only: no `Ffi`.

## Where an addition goes

A new promise of the pump is a `Property` here, in `properties`; both
runners run it.
-/

namespace Editor.PumpContract

open Editor.Job

/-- The guard of a wait's end, which must come; only a hang reaches it. -/
def patience : HangGuard :=
  .on "the wait's end" 10000

/-- A pump as the contract runs it. -/
structure PumpRig where
  /-- Which pump, as a failure names it. -/
  name : String
  /-- The table the pump finishes its waits through. -/
  completions : Completions
  /-- Hands the completion of the wait `id` to the pump. -/
  hand : UInt64 → IO Unit
  /-- Runs the pump until what was handed is finished; nothing for a pump
  that runs by itself. -/
  run : IO Unit

/-- One property of the pump: whether it holds on a rig, or why not,
thrown. -/
structure Property where
  /-- What must hold, as a sentence. -/
  name : String
  /-- Observes it on a fresh rig. -/
  holds : PumpRig → IO Bool

/-- `task`'s value, or a hang thrown when it has not ended within
`patience`. -/
def awaited {α : Type} (what : String) (task : Task α) : IO α := do
  let some value ←
    awaitWithin patience
        task | throw <| IO.userError s!"a hang: {what} had not ended within {patience.ms} ms"
  return value

/-- A wait of `rig`'s table whose action appends its id and completion to
`log`, and the task of its end. -/
def logged (rig : PumpRig) (log : IO.Ref (Array (UInt64 × Completion))) :
    BaseIO (UInt64 × Task Completion) := do
  let ended ← IO.Promise.new
  let id ←
    rig.completions.registerWith fun id completion => do
        log.modify (·.push (id, completion))
        ended.resolve completion
  return (id, ended.result?.map (sync := true) (·.getD .cancelled))

/-- P1: a handed completion ends its wait as completed. -/
def endsItsWait : Property where
  name := "a completion handed to the pump ends its wait as completed"
  holds rig := do
    let log ← IO.mkRef #[]
    let (id, task) ← logged rig log
    rig.hand id
    rig.run
    let ended ← awaited "the wait" task
    unless ended == .completed && (← log.get) == #[(id, .completed)] do
      throw <|
          IO.userError
            s!"{rig.name}: the wait ended {repr ended}, its action ran {(← log.get).size} times"
    return true

/-- P2: two handed completions end their waits in the order handed. -/
def inOrder : Property where
  name := "two completions handed to the pump end their waits in the order handed"
  holds rig := do
    let log ← IO.mkRef #[]
    let (first, firstTask) ← logged rig log
    let (second, secondTask) ← logged rig log
    rig.hand first
    rig.hand second
    rig.run
    discard <| awaited "the first wait" firstTask
    discard <| awaited "the second wait" secondTask
    let order := (← log.get).map (·.1)
    unless order == #[first, second] do
      throw <|
          IO.userError
            s!"{rig.name}: handed {first} then {second}, the waits ended in the order {order}"
    return true

/-- P3: a completion for a wait no longer waiting changes nothing, and the
next is still finished. -/
def withdrawnIgnored : Property where
  name :=
    "a completion handed for a wait withdrawn before it changes nothing, and the completion handed after it still ends its wait"
  holds rig := do
    let log ← IO.mkRef #[]
    let (withdrawn, _) ← logged rig log
    rig.completions.finish withdrawn .cancelled
    rig.hand withdrawn
    let (next, nextTask) ← logged rig log
    rig.hand next
    rig.run
    let ended ← awaited "the wait after the withdrawn one" nextTask
    let seen ← log.get
    unless ended == .completed && seen == #[(withdrawn, .cancelled), (next, .completed)] do
      throw <|
          IO.userError s!"{rig.name}: the next wait ended {repr ended}; the actions ran {repr seen}"
    return true

/-- The properties, in the order they run. -/
def properties : List Property :=
  [endsItsWait, inOrder, withdrawnIgnored]

end Editor.PumpContract
