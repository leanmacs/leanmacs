import Editor.Completion.Later
import Editor.Config.Registry
import Editor.Workspace.Attach
import Editor.Workspace.FindFile

/-!
# The workspace commands, jobs and source, as compiled code registers them

What a host is handed so that a buffer's file finds its workspace, so
that `workspace-current` says it (`Editor/Workspace/Attach.lean`), and so
that `find-file-in-workspace` lists the workspace's files
(`Editor/Workspace/FindFile.lean`). A host registers them for the owner
`compiled` when its loop starts, before any config
(`Editor/Config/Registry.lean`, "Compiled commands"), beside the file
commands and their jobs (`Editor/Files/Compiled.lean`).

- **`Workspace.commands`**: `workspace-current`, which says the workspace
  of the buffer of the window it was called with in the echo area
  (`Workspace.currentCommand`); and `find-file-in-workspace`, which opens
  a prompt over the files of that workspace (`FindFile.command`).
- **`Workspace.jobs`**: `find-workspace`, which a file's open starts for its
  directory when no answer is cached under the config generation
  (`Workspace.findWork`). A host that is not handed it finds no workspace,
  and says nothing about it. And `find-mode-markers`, which gives a buffer
  whose file opened the minor modes its markers turn on
  (`Workspace.markerWork`, `Editor/Workspace/Modes.lean`). And
  `workspace-files`, the job of the finder's source, which runs the
  workspace's lister and fzf (`FindFile.answer`).
- **`Workspace.sources`**: `workspace-files`, in the category
  `workspace-file`, which compiled code gives no style or display of its
  own: config picks them as for any category.

This module is apart from `Editor/Workspace/Attach.lean` because it names
the registry, which is the config session's.

Pinned by `ModelTest.workspaceChecks`, `ModelTest.compileHookChecks` and
`ModelTest.findFileChecks`, on the models, and by
`ConfigTest.shippedChecks` over the hosts' registry.
-/

namespace Editor.Workspace

/-- The workspace commands, as a host registers them for the owner
`compiled`. -/
def commands : Array Config.Registration :=
  #[{ name := currentName, action := .call currentCommand },
    { name := FindFile.name, action := .call FindFile.command }]

/-- The jobs a file's open starts to find its directory's workspace and its
buffer's modes on markers, and the finder's source's job, as a host
registers them for the owner `compiled`. -/
def jobs : Array Config.JobRegistration :=
  #[{ name := findJob, work := findWork }, { name := markerJob, work := markerWork },
    { name := FindFile.job, work := Completion.answering FindFile.answer }]

/-- The finder's source, as a host registers it for the owner
`compiled`. -/
def sources : Array Completion.Source :=
  #[FindFile.source]

end Editor.Workspace
