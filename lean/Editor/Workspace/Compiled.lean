import Editor.Extension
import Editor.Package
import Editor.ProjectMode.Listing
import Editor.Workspace.Attach
import Editor.Workspace.FindFile
import Editor.Workspace.FindInProject

/-!
# The `workspace` package: the workspace commands, jobs and sources

What a host registers, as the package `workspace` (`Workspace.package`,
`Editor/Package.lean`), so that a buffer's file finds its workspace, so
that `workspace-current` says it (`Editor/Workspace/Attach.lean`), so
that `find-file-in-workspace` lists the workspace's files
(`Editor/Workspace/FindFile.lean`), and so that `find-file-in-project`
picks a workspace of the project to find files in
(`Editor/Workspace/FindInProject.lean`). A host registers it for the owner
`workspace` when its loop starts, before any config
(`Editor/Config/Packages.lean`), beside the `files` package
(`Editor/Files/Compiled.lean`).

- **The commands**: `workspace-current`, which says the workspace
  of the buffer of the window it was called with in the echo area
  (`Workspace.currentCommand`); `find-file-in-workspace`, which opens
  a prompt over the files of that workspace (`FindFile.command`); and
  `find-file-in-project`, which opens a prompt over the project's
  workspaces and then `find-file-in-workspace` in the one chosen
  (`FindInProject.command`); and `find-file-in-another-workspace`, which
  closes the open workspace finder and opens that picker, carrying the
  text typed in the finder to the finder the choice opens
  (`FindInProject.escapeCommand`).
- **The binding**: `C-x C-d` runs `find-file-in-another-workspace`,
  in the prompt category `workspace-file` alone (`bindKeys`'s `category`), so
  it holds only while the workspace finder is open.
- **The jobs**: `find-workspace`, which a file's open starts for its
  directory when no answer is cached under the config generation
  (`Workspace.findWork`). A host that is not handed it finds no workspace,
  and says nothing about it. And `find-mode-markers`, which gives a buffer
  whose file opened the minor modes its markers turn on
  (`Workspace.markerWork`, `Editor/Workspace/Modes.lean`). And
  `compile-list`, which that job's command starts for each mode it turned
  on whose contribution computes its commands: it runs the contribution's
  listing in the mode's root when its markers' stamps have changed
  (`Compile.listWork`, `Editor/ProjectMode/Listing.lean`). It is registered
  here, not by the `compile` package, because the listing is the core's
  and the mode marker search is what starts it. And
  `workspace-files`, the job of the finder's source, which runs the
  workspace's lister and fzf (`FindFile.answer`). And the picker's three:
  `project-workspaces`, its source's job, which lists the repository's
  worktrees (`FindInProject.answer`); `project-workspace-choose`, which
  lists them again on accept and chooses (`FindInProject.chooseWork`);
  and `project-workspace-find`, which finds a worktree not yet found
  (`FindInProject.findWork`).
- **Which jobs a restart counts.** `find-workspace`, `find-mode-markers`
  and `compile-list` are registered restarted (`workJob …
  (restarted := true)`): a file's open starts them, and a restore opens
  every file buffer it puts back the same way (`Files.takeIn`), so it
  starts them again; one running at a restart is not counted as stopped
  by it. The finder's and the picker's jobs are counted.
- **The sources**: `workspace-files`, in the category
  `workspace-file`, and `project-workspaces`, in the category
  `project-workspace`, which the package gives no style or display of
  their own: config picks them as for any category.

This module is apart from `Editor/Workspace/Attach.lean` because it is what
a host is handed, not what config calls.

Pinned by `ModelTest.workspaceChecks`, `CompileTest.compileHookChecks` and
`ModelTest.findFileChecks` and `ModelTest.findInProjectChecks`, on the models, and by
`ConfigTest.shippedChecks` over the hosts' registry.
-/

namespace Editor.Workspace

/-- The package `workspace`: the workspace commands; the escape's key,
`C-x C-d`, in the workspace finder's prompt category alone; the jobs a
file's open starts to find its directory's workspace and its buffer's modes
on markers, the job that lists a mode's computed commands, the finder's
source's job and the picker's jobs; and the finder's source and the
picker's. -/
def package : Package :=
  { name := "workspace"
    setup := do
      Extension.add ({ name := "workspace", opened := attach } : FilesApi.Opened)
      Extension.add
          ({  name := ProjectApi.implementationName
              reach := fun continuation path git view carried =>
                Reach.reach continuation path git view carried
              work := Reach.work } : ProjectApi.Workspaces)
      commandWith currentName currentCommand
      commandWith FindFile.name FindFile.command
      commandWith FindInProject.name FindInProject.command
      commandWith FindInProject.escapeName FindInProject.escapeCommand
      bindKeys FindInProject.escapeKeys FindInProject.escapeName (desc :=
          some FindInProject.escapeDesc) (category := some FindFile.category)
      workJob findJob findWork (restarted := true)
      workJob markerJob markerWork (restarted := true)
      workJob Compile.listJob Compile.listWork (restarted := true)
      sourceJob FindFile.job FindFile.answer
      Extension.workJob VcApi.Backend FindInProject.job fun backends =>
          Completion.answering (FindInProject.answer (VcApi.connect? backends))
      Extension.workJob VcApi.Backend FindInProject.chooseJob fun backends =>
          FindInProject.chooseWork (VcApi.connect? backends)
      workJob FindInProject.findJob FindInProject.findWork
      defineSource FindFile.source
      defineSource FindInProject.source }

end Editor.Workspace
