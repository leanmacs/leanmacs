import Editor.Completion.Filtering
import Editor.Process.Model
import Editor.Test.Fixture.Setup
import Workspace.FindFile
import Workspace.Lister

/-!
# The workspace package's fixture setups

What the headless fixture harness gives the fixtures whose runs reach the
workspace package's processes (`Editor/Test/Fixture/Setup.lean`): the
package-set build hands `setups` to the harness of every set that holds
this Lake package, after the core's own (`fixturesRootSource` in
`lean/lakefile.lean`; `docs/dev-practices/headless-mode.md`, "How the gate
runs a fixture").

`tests/headless/default-config` runs the shipped `config/default` in an
empty working directory, where the finder's default source, with no
workspace, runs the fallback lister and fzf as its filter. Their command
lines are built here from the package's own (`Lister.fallback`,
`FindFile.filtering`) and the core's (`Completion.Filtering.filterFor`),
so the lister stays defined in `Workspace/Lister.lean` alone.

Pinned by `WorkspaceTest.fixtureSetupChecks`
(`WorkspaceTest/WorkspaceTest/FixtureSetups.lean`).
-/

namespace WorkspaceTest.FixtureSetups

open Editor
open Editor.Test.Fixture

/-- What the finder's default source runs in the empty directory
`directory` with no workspace, answered as the real programs answer there:
the fallback lister lists nothing, and the filter, given the empty query,
answers none, exiting 1, as fzf and its stand-in
(`tests/completion/filter`) do. -/
def emptyListing (directory : String) : ProcessModel :=
  let filtering := Workspace.FindFile.filtering Workspace.Lister.fallback directory
  let ended (status : Nat) : Except ProcessError Process.Ran :=
    .ok { exit := .code status, stdout := .empty, stderr := .empty }
  {
    scripts :=
      #[{ command := filtering.lister, reply := ended 0 },
        { command := filtering.filterFor "", reply := ended 1 }] }

/-- The setups of the fixtures whose runs reach the workspace package's
processes, keyed by their scripts' paths from the repository's root. -/
def setups : Array (String × Setup) :=
  #[("tests/headless/default-config/script",
      { config := some "config/default", directory := some "/d", workingDirectory := "/d/cwd"
        workingEntries := #[], processes := emptyListing "/d/cwd" })]

end WorkspaceTest.FixtureSetups
