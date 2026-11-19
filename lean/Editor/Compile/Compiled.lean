import Editor.Compile
import Editor.Compile.Shipped
import Editor.Package

/-!
# The `compile` package: the compile mode's commands, its jobs, its mode and the contributions that ship

What a host registers so that `compile` runs (`Editor/Compile.lean`): the
package `compile` (`Compile.package`, `Editor/Package.lean`). A host
registers it for the owner `compile` when its loop starts, before any
config (`Editor/Config/Packages.lean`), beside the `ex` package
(`Editor/Ex/Compiled.lean`), which binds the ex names `compile`,
`compile-command`, `recompile` and `kill-compilation` to its commands.

- **The commands**: `compile`, which starts a run in the focused
  buffer's scope (`Compile.compileCommand`); `compile-command`, which runs
  one of the on-modes' named commands (`Compile.commandCommand`), bound to
  no key; `recompile`, which reruns its
  last line (`Compile.recompileCommand`); `compile-confirm`, which no key
  runs: the prompt that asks before a restart answers it
  (`Compile.confirmCommand`); `kill-compilation`, which kills
  the scope's run in flight (`Compile.killCommand`); and
  `compilation-output`, which no key runs: the run job posts its output to
  it (`Compile.outputCommand`); `next-error` and `previous-error`, which
  step through the focused buffer's scope's locations
  (`Compile.stepCommand`); and `compile-goto-error`, which visits the
  location on the cursor's line of a compilation buffer, the mode's
  `activate` (`Compile.gotoCommand`).
- **The jobs**: `compile-run`, which runs the child, posts its output
  as it comes and finishes with how it ended (`Compile.runWork`); and
  `compile-list`, which runs a contribution's listing in its mode's root
  when its markers' stamps have changed (`Compile.listWork`,
  `Editor/Compile/Listing.lean`). A host
  that is not handed it runs no compile, and says so when one is asked for.
- **The mode**: `compilation`, the compilation buffer's major mode
  (`Compile.mode`).
- **The contributions** that ship (`Compile.shipped`,
  `Editor/Compile/Shipped.lean`): `cargo-mode`, `lake-mode` and `mise-mode`,
  each registered with `compileContribution`.

This module is apart from `Editor/Compile.lean` because it is what a host is
handed, not what config calls.

Pinned by `ModelTest.compileChecks`, `ModelTest.compileLocationChecks` and
`ModelTest.compileHookChecks`, on the models.
-/

namespace Editor.Compile

/-- The package `compile`: the compile mode's commands, its jobs, its mode
and the contributions that ship (`shipped`). -/
def package : Package :=
  { name := "compile"
    setup := do
      commandWith compileName compileCommand
      commandWith commandName commandCommand
      commandWith recompileName recompileCommand
      commandWith confirmName confirmCommand
      commandWith killName killCommand
      commandWith outputName outputCommand
      commandWith nextName (stepCommand nextName true)
      commandWith previousName (stepCommand previousName false)
      commandWith gotoName gotoCommand
      workJob runJob runWork
      workJob listJob listWork
      defineMode mode
      for contribution in shipped do
        compileContribution contribution }

end Editor.Compile
