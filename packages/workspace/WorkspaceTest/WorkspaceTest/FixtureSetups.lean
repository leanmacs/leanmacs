import Editor.Job.Model
import Editor.Test.Fixture.Setup
import Editor.Test.Jobs
import Workspace.FindFile
import Workspace.Lister
import WorkspaceTest.Check
import WorkspaceTest.FixtureSetups

/-!
# Model tests: `WorkspaceTest/FixtureSetups.lean`

The model tests of the workspace package's fixture setups:
`fixtureSetupChecks`. The test driver's root, `WorkspaceTest/Model.lean`,
runs them; its module doc says what each shows.
-/

namespace WorkspaceTest

open Editor
open Editor.Test
open Editor.Test.Fixture

/-- The checks of the workspace package's fixture setups, each pure. -/
def fixtureSetupChecks : List Check :=
  [{  name :=
        "the default config's fixture runs the shipped config/default in an empty working directory, where the finder's default source with no workspace finds nothing: its fallback lister and its filter are answered as in an empty directory"
      run := do
        let setup := Setup.of "tests/headless/default-config/script" FixtureSetups.setups
        let lister := Workspace.Lister.fallback
        let (outcome, _) :=
          modelled
            (Workspace.FindFile.found (Workspace.FindFile.filtering lister setup.workingDirectory)
              lister "")
            { processes := setup.processes }
        let foundNothing :=
          match outcome with
          | .finished (.ok records) => records.isEmpty
          | _ => false
        saw (setup.config == some "config/default" && setup.workingEntries.isEmpty && foundNothing)
            s!"config={setup.config} entries={setup.workingEntries} outcome={repr outcome}" }]

end WorkspaceTest
