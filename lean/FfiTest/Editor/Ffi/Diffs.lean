import Editor.Ffi.Diffs
import Editor.Ffi.Events
import FfiTest.Check
import FfiTest.Support.Files
import FfiTest.Support.Queues

/-!
# FFI tests: `Editor/Ffi/Diffs.lean`

The tests of `Editor/Ffi/Diffs.lean`: `diffChecks`. The root module `FfiTest`
runs them, and each list's own doc says what it checks.
-/

namespace FfiTest

/-- The id of the diff service as an event's source (`SERVICE` in
`crates/editor-ffi/src/diffs.rs`). -/
def diffService : UInt64 :=
  5

/-- Whether the next completion is the diff service's for `id`. -/
def diffCompleted (id : UInt64) : IO Bool := do
  let some event ← pull .completion | return false
  return event.source == { kind := .library, id := diffService } && event.kind == .completion &&
      event.code == id

/-- The checks of the diff service's bindings: a flush. -/
def diffChecks (_ : Unit) : List Check :=
  [{  name := "a diff flush asked behind a diff is completed after it, and keeps no script"
      run :=
        inOwnDirectory fun directory => do
          let file := directory / "a.txt"
          IO.FS.writeFile file "a\nb\n"
          let some (.loaded snapshot _ _ _) ← loadResult 1330 file 1000 | return false
          let started ← Editor.Ffi.diffsStart 1331 snapshot snapshot 100
          let flushing ← Editor.Ffi.diffsFlush 1332
          let first ← diffCompleted 1331
          let second ← diffCompleted 1332
          let script ← Editor.Ffi.diffsTake 1331
          let kept ← Editor.Ffi.diffsTake 1332
          return started && flushing && first && second && script.isSome && kept.isNone &&
              (← Editor.Ffi.diffsPending) == 0 }]

end FfiTest
