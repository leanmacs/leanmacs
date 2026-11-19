import Editor.File

/-!
# The linked test kit: Trees

Temporary directories of a check's own, and files written into them. Shared by
several test modules; it holds no checks of its own.

Published for a package's tests: it is a module of the core's linked test
kit, a test double in the namespace `Editor.Test.Linked`, which a package's
test modules may import and its library may not
(`docs/design/packages.md`, "What a package may import"). The core's own
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

/-- Writes `content` as the file `path`, with the directories on the way. -/
def writeMaking (path : System.FilePath) (content : String) : IO Unit := do
  if let some parent := path.parent then
    IO.FS.createDirAll parent
  IO.FS.writeBinFile path (File.encodeText content)

end Editor.Test.Linked
