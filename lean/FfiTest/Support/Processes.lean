import Editor.Ffi.Events
import Editor.Ffi.Processes
import FfiTest.Support.Files
import FfiTest.Support.Queues

/-!
# FFI tests: support: Processes

The library's process service as the checks reach it through its raw
bindings: its id as the source of its completions (`processService`), its
flush as a directory's bracket asks for it (`processesFlushed`), and the
pull of a run's completion (`processCompleted`). Shared by the process
binding's checks (`FfiTest/Editor/Ffi/Processes.lean`) and the entry
point's (`FfiTest/Editor/Ffi/MainThread.lean`); it holds no checks of its
own.
-/

namespace FfiTest

/-- The id of the process service as the source of its completions. -/
def processService : UInt64 :=
  3

/-- The library's process service, as a directory's bracket flushes it: its
flush is completed once every run started before has ended and every child
cancelled before has been reaped. -/
def processesFlushed : Flushed :=
  { name := "process", flush := Editor.Ffi.processesFlush, service := processService }

/-- Whether the next completion on the queue is the process service's, for
the run `id`. -/
def processCompleted (id : UInt64) : IO Bool := do
  let some event ← pull .completion | return false
  return event.source == { kind := .library, id := processService } && event.kind == .completion &&
      event.code == id

end FfiTest
