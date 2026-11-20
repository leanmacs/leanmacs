import Editor.Package
import Editor.Shell

/-!
# The `shell` package: the shell's commands and its job

What a host registers so that `:!` runs (`Editor/Shell.lean`): the package
`shell` (`Shell.package`, `Editor/Package.lean`). A host registers it for
the owner `shell` when its loop starts, before any config
(`Editor/Config/Packages.lean`), beside the `ex` package
(`Editor/Ex/Compiled.lean`), whose commands hand a `:!` line to
`shell-command`.

- **The commands**: `shell-command`, which starts a run
  (`Shell.command`); `shell-filter`, which starts a filter's
  (`Shell.filterCommand`); and `keyboard-quit`, which cancels the run in
  flight in the focused buffer's scope (`Shell.interruptCommand`).
- **The job**: `shell-run`, which runs the child and finishes with what
  came of it (`Shell.runWork`). A host that is not handed it runs no `:!`,
  and says so when one is asked for. It is reported: one running when the
  process ends is said stopped by the next start's restore.
- **Kept across a restart**: the history (`shell-history`), whole. Not the
  output buffers (`shell-output`), which hold buffer numbers, nor the run
  in flight (`shell-running`), which the report says stopped.

This module is apart from `Editor/Shell.lean` because it is what a host is
handed, not what config calls.

Pinned by `ModelTest.shellChecks`, on the models.
-/

namespace Editor.Shell

/-- The package `shell`: the shell's commands and the job that runs `:!`. -/
def package : Package :=
  { name := "shell"
    setup := do
      commandWith commandName command
      commandWith filterName filterCommand
      commandWith interruptName interruptCommand
      workJob runJob runWork (reported := true)
      historyStore.keptAcrossRestart }

end Editor.Shell
