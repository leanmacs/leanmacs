import Editor.Compile
import Editor.Config.Registry

/-!
# The compile mode's commands, its job and its mode, as compiled code registers them

What a host is handed so that `compile` runs (`Editor/Compile.lean`). A host
registers them for the owner `compiled` when its loop starts, before any
config (`Editor/Config/Registry.lean`, "Compiled commands"), beside the ex
line's (`Editor/Ex/Compiled.lean`), which binds the ex names `compile` and
`kill-compilation` to them.

- **`Compile.commands`**: `compile`, which starts a run in the focused
  buffer's scope (`Compile.compileCommand`); `kill-compilation`, which kills
  the scope's run in flight (`Compile.killCommand`); and
  `compilation-output`, which no key runs: the run job posts its output to
  it (`Compile.outputCommand`).
- **`Compile.jobs`**: `compile-run`, which runs the child, posts its output
  as it comes and finishes with how it ended (`Compile.runWork`). A host
  that is not handed it runs no compile, and says so when one is asked for.
- **`Compile.modes`**: `compilation`, the compilation buffer's major mode
  (`Compile.mode`).

This module is apart from `Editor/Compile.lean` because it names the
registry, which is the config session's.

Pinned by `ModelTest.compileChecks`, on the models.
-/

namespace Editor.Compile

/-- The compile mode's commands, as a host registers them for the owner
`compiled`. -/
def commands : Array Config.Registration :=
  #[{ name := compileName, action := .call compileCommand },
    { name := killName, action := .call killCommand },
    { name := outputName, action := .call outputCommand }]

/-- The compile mode's job, as a host registers it for the owner
`compiled`. -/
def jobs : Array Config.JobRegistration :=
  #[{ name := runJob, work := runWork }]

/-- The compile mode's modes, as a host registers them for the owner
`compiled`. -/
def modes : Array Mode :=
  #[mode]

end Editor.Compile
