import Editor.Config.Packages
import Editor.Workspace.Compiled
import ModelTest.Check
import ProjectApiTest.Contract

/-!
# Model tests: `Editor/Workspace/Compiled.lean`

The model tests of `Editor/Workspace/Compiled.lean`:
`workspacePackageChecks`. The root module `ModelTest` runs them; its module
doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the `workspace` package (`Editor/Workspace/Compiled.lean`):
the contract of the interface library `project-api`
(`ProjectApiTest.contractChecks`), with a check that it bites, and which of
its jobs a restart leaves to it to start again. -/
def workspacePackageChecks : List Check :=
  -- The contract of `project-api`, which workspace implements, over its
  -- package, each of its sentences one check.
  ((ProjectApiTest.contractChecks Workspace.package).map fun (name, held) =>
      { name, run := pure held }) ++
    [{  name :=
          "the contract of project-api this list runs bites: over a package of the workspace package's name that registers nothing, every check of it fails"
        run :=
          let broken : Package := { name := Workspace.package.name, setup := pure () }
          pure ((ProjectApiTest.contractChecks broken).all (!·.2)) },
      { name :=
          "the package workspace registers find-workspace, find-mode-markers and compile-list as restarted by their owner, since a restore opens each file it puts back as an open does, and reports none: the finder's and the picker's jobs running at a restart are counted among the other jobs"
        run :=
          let jobs := Workspace.package.registered.jobs
          pure
            ((jobs.filter (·.restarted)).map (·.name) ==
                #[Workspace.findJob, Workspace.markerJob, Compile.listJob] &&
              (jobs.filter (·.reported)).isEmpty &&
              [Workspace.FindInProject.chooseJob, Workspace.FindInProject.findJob].all fun name =>
                jobs.any fun job => job.name == name && !job.restarted) }]

end ModelTest
