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

/-- Runs `body` on a new, empty directory this check owns, and removes the
directory afterwards, whatever `body` did. Every file a check touches is in
such a directory, and every path is passed explicitly. -/
def inOwnDirectory (body : System.FilePath → IO Bool) : IO Bool := do
  let directory ← IO.FS.createTempDir
  try
    body directory
  finally
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
