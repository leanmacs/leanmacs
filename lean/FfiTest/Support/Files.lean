import Editor.Ffi.Events
import Editor.Ffi.Files
import FfiTest.Support.Queues

/-!
# FFI tests: support: Files

The library's file service: its source id, a test in a directory of its own, a
pulled completion and a load's result, and words as bytes. Shared by several
test modules; it holds no checks of its own.
-/

namespace FfiTest

/-- The id of the library's file service as an event's source (`SERVICE` in
`crates/editor-ffi/src/files.rs`). -/
def fileService : UInt64 :=
  2

/-- The id of the next flush a directory's bracket asks (`inOwnDirectory`):
far above every request id a check uses. -/
initialize directoryFlushes : IO.Ref UInt64 ←
  IO.mkRef ((1 : UInt64) <<< 62)

/-- Asks the library's file service for a flush under an id of its own and
waits for its completion, with no deadline: every file request handed to
the service before it has then been worked. The completion queue is pulled
through `pullTask`, so a pull a timed-out `pull` left parked is the one
waited on, and no stray pull takes the flush's completion. A wait not over
after `patience` polls is said on stderr as a hang, once, and still waited
for; a flush the service refuses, or a quit, is said too, since nothing more
will be worked. Other completions pulled meanwhile are a finished check's,
and are dropped. -/
def filesWorked : IO Unit := do
  let id ← directoryFlushes.modifyGet fun id => (id, id + 1)
  unless ← Editor.Ffi.filesFlush id do
    IO.eprintln
        "ffi-test: the file service refused a directory's flush: nothing more will be worked"
    return
  let mut said := false
  repeat
    let task ← pullTask .completion
    if !said && !(← eventually (IO.hasFinished task)) then
      IO.eprintln
          s!"ffi-test: a hang: the file service had not completed a directory's flush after {patience} polls; waiting for it"
      said := true
    let event ← IO.ofExcept (← IO.wait task)
    if event.kind == .quit then
      IO.eprintln "ffi-test: the queues were quit before a directory's flush was completed"
      return
    if
        event.source == { kind := .library, id := fileService } && event.kind == .completion &&
          event.code == id then
      return

/-- Runs `body` on a new, empty directory this check owns, and removes the
directory afterwards, whatever `body` did, once the library's file service
has worked every request handed to it before (`filesWorked`): nothing still
writes into the directory being removed. Every file a check touches is in
such a directory, and every path is passed explicitly. -/
def inOwnDirectory (body : System.FilePath → IO Bool) : IO Bool := do
  let directory ← IO.FS.createTempDir
  try
    body directory
  finally
    filesWorked
    IO.FS.removeDirAll directory

/-- Pulls one event from the completion queue; `true` when it is the
completion of the file request `id`, from the library's file service. -/
def fileCompleted (id : UInt64) : IO Bool := do
  let some event ← pull .completion | return false
  return event.source == { kind := .library, id := fileService } && event.kind == .completion &&
      event.code == id

/-- Starts a load of `path` as the request `id`, waits for its completion and
takes its result. `none` when the request was refused, was not completed in
time, or left no result. -/
def loadResult (id : UInt64) (path : System.FilePath) (limit : UInt64) :
    IO (Option Editor.Ffi.FileResult) := do
  unless ← Editor.Ffi.filesLoad id path.toString limit do
    return none
  unless ← fileCompleted id do
    return none
  Editor.Ffi.filesTake id

/-- `values` as words: eight bytes each, least significant first. -/
def wordBytes (values : List UInt64) : ByteArray :=
  values.foldl
    (fun bytes word =>
      (List.range 8).foldl (fun bytes byte => bytes.push (word >>> (8 * byte).toUInt64).toUInt8)
        bytes)
    ByteArray.empty

end FfiTest
