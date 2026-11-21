import Editor.Ffi.Files
import Editor.Job.Runner

/-!
# Contract tests: support: FileHold

The library's file service with its worker held, in process: `FileHold.hold`
asks the service for a hold (`Ffi.filesHold`) under a wait of the table, and
returns once the worker has reached it, so nothing handed to the service
afterwards is worked until `FileHold.release` lets the worker go
(`Ffi.filesCancel`). It needs no file, no named pipe and no other process.
Its users are `ContractTest/Editor/Restore/Run.lean`,
`ContractTest/Editor/Job/FlushContract.lean`,
`ContractTest/Editor/Job/HandleContract.lean` and
`ContractTest/Editor/Test/Linked/Services.lean`; it holds no checks of its
own.
-/

namespace ContractTest

open Editor

/-- hang guard: the worker's arrival at the hold, behind the requests handed
to it before; only a hang reaches the bound, and the check then fails as a
hang. How long a hold waits for it, in milliseconds. -/
def holdPatience : Nat :=
  10000

/-- The file service's worker, held. -/
structure FileHold where
  /-- The hold's id: the wait it was completed under. -/
  id : UInt64
  /-- Whether it has been let go. -/
  released : IO.Ref Bool

/-- Holds the file service's worker through the table `completions`, whose
pump runs: returns once the worker has reached the hold, behind every request
handed to the service before. Throws when the service refuses the hold, or
reports a hang when the worker has not reached it within `holdPatience`. -/
def FileHold.hold (completions : Job.Completions) : IO FileHold := do
  let (id, wait) ← completions.register
  unless ← Ffi.filesHold id do
    completions.finish id .cancelled
    throw <| IO.userError "the file service did not take the hold"
  let hold := { id, released := ← IO.mkRef false : FileHold }
  let reached ← Job.awaitWithin holdPatience (wait.resultD .cancelled)
  unless reached == some .completed do
    discard <| Ffi.filesCancel id
    throw <|
        IO.userError
          s!"a hang: the file service's worker had not reached the hold within {holdPatience} ms"
  return hold

/-- Lets the worker go. Idempotent: only the first call cancels the hold. -/
def FileHold.release (hold : FileHold) : IO Unit := do
  unless ← hold.released.swap true do
    discard <| Ffi.filesCancel hold.id

end ContractTest
