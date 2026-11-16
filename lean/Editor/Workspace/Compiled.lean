import Editor.Config.Registry
import Editor.Workspace.Attach

/-!
# The workspace command and the find job, as compiled code registers them

What a host is handed so that a buffer's file finds its workspace, and so
that `workspace-current` says it (`Editor/Workspace/Attach.lean`). A host
registers both for the owner `compiled` when its loop starts, before any
config (`Editor/Config/Registry.lean`, "Compiled commands"), beside the file
commands and their jobs (`Editor/Files/Compiled.lean`).

- **`Workspace.commands`**: `workspace-current`, which says the workspace
  of the buffer of the window it was called with in the echo area
  (`Workspace.currentCommand`).
- **`Workspace.jobs`**: `find-workspace`, which a file's open starts for its
  directory when no answer is cached under the config generation
  (`Workspace.findWork`). A host that is not handed it finds no workspace,
  and says nothing about it.

This module is apart from `Editor/Workspace/Attach.lean` because it names
the registry, which is the config session's.

Pinned by `ModelTest.workspaceChecks`, on the models.
-/

namespace Editor.Workspace

/-- The workspace commands, as a host registers them for the owner
`compiled`. -/
def commands : Array Config.Registration :=
  #[{ name := currentName, action := .call currentCommand }]

/-- The job a file's open starts to find its directory's workspace, as a
host registers it for the owner `compiled`. -/
def jobs : Array Config.JobRegistration :=
  #[{ name := findJob, work := findWork }]

end Editor.Workspace
