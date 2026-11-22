import Editor.Api

/-!
An implementation package of the fixture for the module map check's reading
of the sources (tools/module-map-check.sh, with --points). It holds one
line for each way the reader counts a registration, one for each of the
four operations over a point it counts as a read, and one for each text it
skips. A call of a reader that an interface declares is a read too: each of
those eleven is in a package beside this one, the seven over one point in
the package readers and the four over both of the compile mode's points in
a package each, since a read counted here twice would hide one of its two
rules. Prose that names a read in backticks, as
`Extension.values Skipped.Prose`, is not counted.
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

def run : EditorM Unit := do
  -- The four operations that read a point.
  let files ← Extension.values FilesApi.Files
  let main ← Extension.named ProjectApi.Workspaces "main"
  let chosen ← Extension.configValues Sample.Choice
  let work ← Extension.workJob Sample.Work

end Sample
