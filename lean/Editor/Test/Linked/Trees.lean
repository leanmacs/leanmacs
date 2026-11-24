import Editor.File
import Editor.Test.Linked.Services

/-!
# The linked test kit: Trees

Temporary directories of a check's own, and files written into them; and a
temporary directory removed only once the services that worked under it
have worked what was handed to them (`withFlushedBase`). Shared by several
test modules; it holds no checks of its own.

Published for a package's linked test: it is a module of the core's linked
test kit, in the namespace `Editor.Test.Linked`, which the root of a
package's linked test and the modules under it may import, and no other
module of a package may (`docs/design/packages.md`, "What a package may
import"). The core's own
checks against the real bindings (`contract-test`) are written on it.
-/

namespace Editor.Test.Linked

open Editor

/-- A temporary directory of its own for `check`, with its real path, so that
what the git fixture prints names it as the finder does; removed
afterwards, whatever happened. -/
def withBase {α : Type} (check : System.FilePath → IO α) : IO α := do
  let directory ← IO.FS.createTempDir
  try
    check (← IO.FS.realPath directory)
  finally
    IO.FS.removeDirAll directory

/-- A temporary directory of its own for `check`, with its real path, as
`withBase` makes it, removed only once a flush of the process service and
then of the file service through `jobs` has completed (`withFiles`): a
barrier on every child and file request handed to them before, so nothing
`check` started still runs in it. -/
def withFlushedBase {α : Type} (jobs : Job.Services) (check : System.FilePath → IO α) : IO α :=
  withFiles jobs
    (fun directory => do
      check (← IO.FS.realPath directory))
    [.processes, .files]

/-- Writes `content` as the file `path`, with the directories on the way. -/
def writeMaking (path : System.FilePath) (content : String) : IO Unit := do
  if let some parent := path.parent then
    IO.FS.createDirAll parent
  IO.FS.writeBinFile path (File.encodeText content)

end Editor.Test.Linked
