import Editor.Completion.Filtering
import Editor.Process.Model
import Editor.Test.Fixture.Support
import Workspace.FindFile
import Workspace.Lister

/-!
# The workspace package's fixture support

What the workspace package brings to the stepped fixture harness of a set
that holds it (`Editor.Test.Fixture.Support`,
`lean/Editor/Test/Fixture/Support.lean`): the setups of the fixtures whose
runs reach its processes. The package-set build finds this module by its
name and only the fixture harness's root imports it, handing `support` to
the harness after the core's setups (`fixturesRootSource` in
`lean/lakefile.lean`; `docs/dev-practices/headless-mode.md`, "How the gate
runs a fixture").

`tests/headless/default-config` runs the shipped `config/default` in an
empty working directory, where the finder's default source, with no
workspace, runs the fallback lister and fzf as its filter. Their command
lines are built here from the package's own (`Lister.fallback`,
`FindFile.filtering`) and the core's (`Completion.Filtering.filterFor`),
so the lister stays defined in `Workspace/Lister.lean` alone.

Pinned by `WorkspaceTest.fixtureSupportChecks`
(`WorkspaceTest/WorkspaceTest/FixtureSupport.lean`).
-/

namespace WorkspaceTest.FixtureSupport

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

/-- The workspace package's fixture support: its setups. -/
def support : Support :=
  { name := "workspace", setups }

end WorkspaceTest.FixtureSupport
