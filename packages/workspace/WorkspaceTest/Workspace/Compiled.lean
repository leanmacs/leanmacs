import Editor.Config.Packages
import Editor.InputScheme.Test
import Editor.Test.Keys
import ProjectApiTest.Contract
import Workspace.Compiled
import WorkspaceTest.Check

/-!
# Model tests: `Workspace/Compiled.lean`

The model tests of `Workspace/Compiled.lean`: `workspacePackageChecks`. The
test driver's root, `WorkspaceTest/Model.lean`, runs them; its module doc
says what each shows.
-/

namespace WorkspaceTest

open Editor

/-- The registry the `workspace` package makes registered alone, as a host
of a set that holds it registers it. -/
def workspaceRegistry : Config.Registry :=
  let (state, _) : Config.State Unit Unit × Array String :=
    Config.State.ofPackages #[Workspace.package]
  state.registry

/-- The checks of the `workspace` package (`Workspace/Compiled.lean`):
the contract of the interface library `project-api`
(`ProjectApiTest.contractChecks`), with a check that it bites, which of
its jobs a restart leaves to it to start again, and what it registers, in
the registry it makes alone (`workspaceRegistry`): its commands, sources,
jobs and binding, each for its owner. -/
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
                jobs.any fun job => job.name == name && !job.restarted) },
      { name :=
          "the workspace package registers find-file-in-workspace, the source workspace-files in the category workspace-file, which it alone is in, filtered and answered later by its job workspace-files, registered by it"
        run := do
          let registry := workspaceRegistry
          let owner := Workspace.package.owner
          return (registry.find? "find-file-in-workspace").any (·.owner == owner) &&
              registry.sources.any
                (fun entry =>
                  entry.source.name == "workspace-files" && entry.owner == owner &&
                    entry.source.filtered &&
                    entry.source.later.map (·.job) == some "workspace-files") &&
              registry.sourcesIn "workspace-file" == #["workspace-files"] &&
              registry.jobs.any
                (fun entry =>
                  entry.registration.name == "workspace-files" && entry.owner == owner) },
      { name :=
          "the workspace package registers find-file-in-project, the source project-workspaces in the category project-workspace, which it alone is in, answered later by its job project-workspaces, and that job, project-workspace-choose and project-workspace-find"
        run := do
          let registry := workspaceRegistry
          let owner := Workspace.package.owner
          let jobs := ["project-workspaces", "project-workspace-choose", "project-workspace-find"]
          return (registry.find? "find-file-in-project").any (·.owner == owner) &&
              registry.sources.any
                (fun entry =>
                  entry.source.name == "project-workspaces" && entry.owner == owner &&
                    entry.source.later.map (·.job) == some "project-workspaces") &&
              registry.sourcesIn "project-workspace" == #["project-workspaces"] &&
              jobs.all fun name =>
                registry.jobs.any
                  (fun entry => entry.registration.name == name && entry.owner == owner) },
      { name :=
          "the workspace package registers find-file-in-another-workspace and one binding of it, C-x C-d in the prompt category workspace-file, described Find in another workspace; the global keymap does not bind C-x"
        run := do
          let registry := workspaceRegistry
          let owner := Workspace.package.owner
          let escapes :=
            registry.bindings.filter (·.binding.command == "find-file-in-another-workspace")
          let global : Keymap Invocation := registry.keymap TestScheme.scheme
          return (registry.find? "find-file-in-another-workspace").any (·.owner == owner) &&
              escapes.map (fun entry => (entry.owner, entry.binding)) ==
                #[(owner,
                    { keys := (Test.keys "C-x C-d").map .key
                      command := "find-file-in-another-workspace"
                      category := some "workspace-file"
                      desc := some "Find in another workspace" })] &&
              global.find? (Test.keys "C-x") == none &&
              !global.continues (Test.keys "C-x") },
      { name :=
          "the workspace package registers the jobs find-mode-markers and compile-list, beside find-workspace, and compile-list once: the listing is the core's, whichever package gives the contributions it lists"
        run := do
          let registry := workspaceRegistry
          let owner := Workspace.package.owner
          return (registry.findJob? "find-mode-markers").any (·.owner == owner) &&
              (registry.findJob? "find-workspace").any (·.owner == owner) &&
              (registry.jobs.filter (·.registration.name == Compile.listJob)).map (·.owner) ==
                #[owner] }]

end WorkspaceTest
