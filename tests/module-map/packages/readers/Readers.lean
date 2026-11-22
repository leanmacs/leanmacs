import BuffersApi
import Editor.Api

/-!
An implementation package of the fixture for the module map check's reading
of the sources (tools/module-map-check.sh, with --points). It holds one
call of each of the seven readers an interface declares over one point,
each on a line of its own and over a point nothing else in this package
reads, so the read is counted by that reader's rule alone: without the
rule, the map names a read the sources lack. None is on a declaration's
first line, which is skipped (the package sample holds that case).
-/

namespace Readers

def run (path : String) (buffer : Buffer) (backends : Array Backend) : EditorM Unit := do
  -- The two hooks of the files interface, and its implementation.
  FilesApi.runOpened path
  FilesApi.runSaved path
  let some files ← FilesApi.files? | return
  -- The hook of the buffers interface, and its implementation.
  BuffersApi.runClosing buffer
  let some buffers ← BuffersApi.buffers? | return
  -- The implementations of the project and version control interfaces.
  let some workspaces ← ProjectApi.workspaces? | return
  let some backend := VcApi.connect? backends | return

end Readers
