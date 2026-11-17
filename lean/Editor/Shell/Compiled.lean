import Editor.Config.Registry
import Editor.Shell

/-!
# The shell's commands and its job, as compiled code registers them

What a host is handed so that `:!` runs (`Editor/Shell.lean`). A host
registers both for the owner `compiled` when its loop starts, before any
config (`Editor/Config/Registry.lean`, "Compiled commands"), beside the ex
line's commands (`Editor/Ex/Compiled.lean`), which hand a `:!` line to
`shell-command`.

- **`Shell.commands`**: `shell-command`, which starts a run
  (`Shell.command`); `shell-filter`, which starts a filter's
  (`Shell.filterCommand`); and `keyboard-quit`, which cancels the run in
  flight in the focused buffer's scope (`Shell.interruptCommand`).
- **`Shell.jobs`**: `shell-run`, which runs the child and finishes with what
  came of it (`Shell.runWork`). A host that is not handed it runs no `:!`,
  and says so when one is asked for.

This module is apart from `Editor/Shell.lean` because it names the registry,
which is the config session's.

Pinned by `ModelTest.shellChecks`, on the models.
-/

namespace Editor.Shell

/-- The shell's commands, as a host registers them for the owner
`compiled`. -/
def commands : Array Config.Registration :=
  #[{ name := commandName, action := .call command },
    { name := filterName, action := .call filterCommand },
    { name := interruptName, action := .call interruptCommand }]

/-- The shell's job, as a host registers it for the owner `compiled`. -/
def jobs : Array Config.JobRegistration :=
  #[{ name := runJob, work := runWork }]

end Editor.Shell
