import Editor.Extension
import ModelTest.Check
import ProjectApi
import ProjectApiTest.Contract
import ProjectApiTest.Fake

/-!
# Model tests: `ProjectApi.lean`

`projectApiChecks`: the interface library `project-api`'s names, its fake
held to its contract, and the contract biting on implementations that
leave something out or whose reach hands nothing on. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of `project-api`'s contract that do not hold over `package`. -/
def projectFailing (package : Package) : List String :=
  ((ProjectApiTest.contractChecks package).filter (!·.2)).map (·.1)

/-- A package of the workspace's name that registers the interface's names
and job and a `Workspaces` value whose reach and work hand nothing on. -/
def silentWorkspaces : Package :=
  { name := ProjectApi.implementationName
    setup := do
      for name in ProjectApi.names do
        command name (pure ())
      for job in ProjectApi.jobs do
        workJob job fun _ _ => pure (pure ())
      Extension.add
          ({  name := ProjectApi.implementationName, reach := fun _ _ _ _ _ => pure ()
              work := fun _ _ _ => pure (pure ()) } : ProjectApi.Workspaces) }

/-- The checks of `project-api` (`ProjectApi.lean`). -/
def projectApiChecks : List Check :=
  [{  name :=
        "the names project-api declares: find-file-in-workspace and find-file-in-project, and the job compile-list, the core's"
      run :=
        pure
          (ProjectApi.names == #["find-file-in-workspace", "find-file-in-project"] &&
            ProjectApi.jobs == #[Compile.listJob] &&
            ProjectApi.implementationName == "workspace") },
    { name := "the fake keeps the contract: every check of it holds"
      run := pure (projectFailing ProjectApiTest.fake).isEmpty },
    { name :=
        "a package that registers every name but find-file-in-project fails the contract on that name's check alone"
      run :=
        pure <|
          let lacking : Package :=
            { name := ProjectApi.implementationName
              setup := do
                command ProjectApi.findFileInWorkspaceName (pure ())
                for job in ProjectApi.jobs do
                  workJob job fun _ _ => pure (pure ())
                Extension.add (ProjectApiTest.workspacesOver ProjectApiTest.fakeFound) }
          match projectFailing lacking with
          | [sentence] => (sentence.splitOn s!"`{ProjectApi.findFileInProjectName}`").length > 1
          | _ => false },
    { name :=
        "an implementation whose reach hands the continuation nothing fails the contract: both reach checks are false, and those of what it registers hold"
      run := pure ((projectFailing silentWorkspaces).length == 2) },
    { name :=
        "with no Workspaces value a job over the point fails naming the continuation's job, and the latest value of the name is the one read"
      run :=
        pure <|
          let failed :=
            match
              ((ProjectApi.workOver #[] ProjectApiTest.probeContinuation [] ()).runModel {}).1 with
            | .failed said => some said
            | _ => none
          let other :=
            { ProjectApiTest.workspacesOver ProjectApiTest.fakeFound with name := "other" }
          failed == some "probe-find: no workspace implementation" &&
            (ProjectApi.workspacesIn #[other]).isNone &&
            (ProjectApi.workspacesIn
                #[ProjectApiTest.workspacesOver ProjectApiTest.fakeFound, other]).isSome }]

end ModelTest
