import Editor.Completion.Later
import Editor.Config.Registry
import Editor.Workspace.Attach
import Editor.Workspace.FindFile
import Editor.Workspace.FindInProject

/-!
# The workspace commands, jobs and source, as compiled code registers them

What a host is handed so that a buffer's file finds its workspace, so
that `workspace-current` says it (`Editor/Workspace/Attach.lean`), so
that `find-file-in-workspace` lists the workspace's files
(`Editor/Workspace/FindFile.lean`), and so that `find-file-in-project`
picks a workspace of the project to find files in
(`Editor/Workspace/FindInProject.lean`). A host registers them for the owner
`compiled` when its loop starts, before any config
(`Editor/Config/Registry.lean`, "Compiled commands"), beside the file
commands and their jobs (`Editor/Files/Compiled.lean`).

- **`Workspace.commands`**: `workspace-current`, which says the workspace
  of the buffer of the window it was called with in the echo area
  (`Workspace.currentCommand`); `find-file-in-workspace`, which opens
  a prompt over the files of that workspace (`FindFile.command`); and
  `find-file-in-project`, which opens a prompt over the project's
  workspaces and then `find-file-in-workspace` in the one chosen
  (`FindInProject.command`); and `find-file-in-another-workspace`, which
  closes the open workspace finder and opens that picker, carrying the
  text typed in the finder to the finder the choice opens
  (`FindInProject.escapeCommand`).
- **`Workspace.bindings`**: `C-x C-d` runs `find-file-in-another-workspace`,
  in the prompt category `workspace-file` alone (`KeyBinding.category`), so
  it holds only while the workspace finder is open.
- **`Workspace.jobs`**: `find-workspace`, which a file's open starts for its
  directory when no answer is cached under the config generation
  (`Workspace.findWork`). A host that is not handed it finds no workspace,
  and says nothing about it. And `find-mode-markers`, which gives a buffer
  whose file opened the minor modes its markers turn on
  (`Workspace.markerWork`, `Editor/Workspace/Modes.lean`). And
  `workspace-files`, the job of the finder's source, which runs the
  workspace's lister and fzf (`FindFile.answer`). And the picker's three:
  `project-workspaces`, its source's job, which lists the repository's
  worktrees (`FindInProject.answer`); `project-workspace-choose`, which
  lists them again on accept and chooses (`FindInProject.chooseWork`);
  and `project-workspace-find`, which finds a worktree not yet found
  (`FindInProject.findWork`).
- **`Workspace.sources`**: `workspace-files`, in the category
  `workspace-file`, and `project-workspaces`, in the category
  `project-workspace`, which compiled code gives no style or display of
  their own: config picks them as for any category.

This module is apart from `Editor/Workspace/Attach.lean` because it names
the registry, which is the config session's.

Pinned by `ModelTest.workspaceChecks`, `ModelTest.compileHookChecks` and
`ModelTest.findFileChecks` and `ModelTest.findInProjectChecks`, on the models, and by
`ConfigTest.shippedChecks` over the hosts' registry.
-/

namespace Editor.Workspace

/-- The workspace commands, as a host registers them for the owner
`compiled`. -/
def commands : Array Config.Registration :=
  #[{ name := currentName, action := .call currentCommand },
    { name := FindFile.name, action := .call FindFile.command },
    { name := FindInProject.name, action := .call FindInProject.command },
    { name := FindInProject.escapeName, action := .call FindInProject.escapeCommand }]

/-- The workspace bindings, as a host registers them for the owner
`compiled`: the escape's key, `C-x C-d`, in the workspace finder's prompt
category alone. -/
def bindings : Array Config.KeyBinding :=
  #[{ keys := FindInProject.escapeKeys.map .key, command := FindInProject.escapeName
      category := some FindFile.category, desc := some FindInProject.escapeDesc }]

/-- The jobs a file's open starts to find its directory's workspace and its
buffer's modes on markers, the finder's source's job and the picker's
jobs, as a host registers them for the owner `compiled`. -/
def jobs : Array Config.JobRegistration :=
  #[{ name := findJob, work := findWork }, { name := markerJob, work := markerWork },
    { name := FindFile.job, work := Completion.answering FindFile.answer },
    { name := FindInProject.job, work := Completion.answering FindInProject.answer },
    { name := FindInProject.chooseJob, work := FindInProject.chooseWork },
    { name := FindInProject.findJob, work := FindInProject.findWork }]

/-- The finder's source and the picker's, as a host registers them for the
owner `compiled`. -/
def sources : Array Completion.Source :=
  #[FindFile.source, FindInProject.source]

end Editor.Workspace
