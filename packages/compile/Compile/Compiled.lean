import Compile
import Compile.Shipped
import Editor.Package

/-!
# The `compile` package: the compile mode's commands, its job, its mode, the contributions that ship and its ex names

What a host registers so that `compile` runs (`Compile.lean`): the
package `compile` (`Compile.package`, `Editor/Package.lean`). A host
registers it for the owner `compile` when its loop starts, before any
config (`Editor/Config/Packages.lean`).

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
- **The job**: `compile-run`, which runs the child, posts its output
  as it comes and finishes with how it ended (`Compile.runWork`). A host
  that is not handed it runs no compile, and says so when one is asked for.
  The job `compile-list`, which runs a contribution's listing, is the
  `workspace` package's (`Editor/Workspace/Compiled.lean`,
  `Editor/ProjectMode/Listing.lean`): a host handed this package and not
  that one offers a contribution's own commands and no listed ones.
- **The mode**: `compilation`, the compilation buffer's major mode
  (`Compile.mode`).
- **The contributions** that ship (`Compile.shipped`,
  `Compile/Shipped.lean`): `cargo-mode`, `lake-mode` and `mise-mode`,
  each registered with `compileContribution`.
- **The ex names** (`exCommand`), in this order, which the ex names'
  completion source keeps: `compile` runs `compile` and takes text: the
  rest of the line is the command line, run in the buffer's workspace; with
  none it asks for one. `compile-command` runs `compile-command` and takes
  text: the rest of the line chooses one of the buffer's on-modes' named
  commands, by its candidate or its bare name, and with none it asks for
  one. `recompile` runs `recompile` and takes nothing: it reruns the
  workspace's last line. `kill-compilation` runs `kill-compilation` and
  takes nothing. `next-error` and `previous-error` run the commands of
  those names and take nothing: they step through the locations of the
  focused buffer's workspace's compilation. No global key binds them. A
  host must be handed the `ex` package (`Editor/Ex/Compiled.lean`) for a
  line to run them; this package names it nowhere, and the `ex` package
  does not name this one.

This module is apart from `Compile.lean` because it is what a host is
handed, not what config calls.

Pinned by `CompileTest.compilePackageChecks`, which reads what the package
registers on its own, and `CompileTest.compileChecks`,
`CompileTest.compileLocationChecks` and `CompileTest.compileHookChecks`, on
the models; and, in an editor built from a set that holds it, by the
package's headless fixtures (`tests/headless/ex-names`, `config`).
-/

namespace Editor.Compile

/-- The package `compile`: the compile mode's commands, its job, its mode,
the contributions that ship (`shipped`) and its ex names. -/
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
      defineMode mode
      for contribution in shipped do
        compileContribution contribution
      exCommand "compile" compileName (takes := .text)
      exCommand "compile-command" commandName (takes := .text)
      exCommand "recompile" recompileName
      exCommand "kill-compilation" killName
      exCommand "next-error" nextName
      exCommand "previous-error" previousName }

end Editor.Compile
