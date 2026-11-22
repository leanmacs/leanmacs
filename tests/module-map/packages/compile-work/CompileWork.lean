import Editor.Api

/-!
A package of the fixture for the module map check's reading of the sources
(tools/module-map-check.sh, with --points). It holds the one registration
of the job that lists the commands, whose work is a reader of both of the
compile mode's points, and nothing else that reads them (the package
compile-hook says why).
-/

namespace CompileWork

def setup : SetupM Unit := do
  workJob Compile.listJob Compile.listWork (restarted := true)

end CompileWork
