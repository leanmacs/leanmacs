import Editor.Api

/-!
An interface package of the fixture for `tools/module-map-check.sh
--points`. It declares the points `Buffers` and `Closing` and the readers
over them, so what reads them here is a reader's body and is not counted
in this package; a point of another namespace is counted here as anywhere.
-/

namespace BuffersApi

/-- The buffers a package supplies, if one does. -/
def buffers? : EditorM (Option Buffers) := do
  return (← Extension.values Buffers).back?

/-- Runs every hook registered for a buffer's closing, over the files a
package supplies. -/
def runClosing (buffer : Buffer) : EditorM Unit := do
  let files ← Extension.values FilesApi.Files
  for hook in ← Extension.values BuffersApi.Closing do
    hook.run files buffer

end BuffersApi
