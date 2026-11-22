import BuffersApi
import Editor.Api

/-!
An implementation package of the fixture for `tools/module-map-check.sh
--points`, with one line for each way the reader counts a registration or
a read, and one for each text it skips. Prose that names a read in
backticks, as `Extension.values Skipped.Prose`, is not counted.
-/

namespace Sample

/-- A declaration's first line is not counted: it is a definition, not a
call. -/
def runOpened (path : String) : EditorM Unit := FilesApi.runOpened path

def setup : SetupM Unit := do
  -- A registration whose type is on the line that adds it.
  Extension.add (opened : FilesApi.Opened)
  -- One whose type is on a later line, after a line that ends in a colon.
  Extension.add
    (backend :
      VcApi.Backend)
  -- The compile mode's two setup operations.
  compileContribution "sample" contribution
  projectCommands "sample" commands

def run (path : String) (buffer : Buffer) : EditorM Unit := do
  -- The four ways to read a point.
  let files ← Extension.values FilesApi.Files
  let main ← Extension.named ProjectApi.Workspaces "main"
  let chosen ← Extension.configValues Sample.Choice
  let work ← Extension.workJob Sample.Work
  -- Two readers that interfaces declare, and one over both of the compile
  -- mode's points.
  FilesApi.runSaved path
  BuffersApi.runClosing buffer
  let hook ← Compile.hook "sample"

end Sample
