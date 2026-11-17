import Editor.Config.Registry
import Editor.VersionControl.Status

/-!
# The status buffer's commands, its jobs and its mode, as compiled code registers them

What a host is handed so that `vc-status` runs
(`Editor/VersionControl/Status.lean`). A host registers them for the owner
`compiled` when its loop starts, before any config
(`Editor/Config/Registry.lean`, "Compiled commands"), beside the ex line's
(`Editor/Ex/Compiled.lean`), which binds the ex name `vc-status` to the
command of that name.

- **`VersionControl.commands`**: `vc-status`, which opens the status buffer
  of the focused buffer's workspace (`VersionControl.statusCommand`);
  `vc-status-refresh`, `vc-status-visit` and `vc-status-toggle`, the
  status buffer's mode's `refresh`, `activate` and `toggle`; and
  `vc-status-stage` and `vc-status-unstage`, its leader suffixes `s` and
  `u`.
- **`VersionControl.jobs`**: `vc-status-read`, which reads a repository's
  status and shows it (`VersionControl.readWork`), and `vc-status-apply`,
  which stages or unstages and then starts a read
  (`VersionControl.applyWork`). A host that is not handed them shows no
  status, and says so when one is asked for.
- **`VersionControl.modes`**: `vc-status`, the status buffer's major mode
  (`VersionControl.mode`).

This module is apart from `Editor/VersionControl/Status.lean` because it
names the registry, which is the config session's.

Pinned by `ModelTest.statusBufferChecks`, on the models, and
`ContractTest.statusBufferChecks`, over real git.
-/

namespace Editor.VersionControl

/-- The status buffer's commands, as a host registers them for the owner
`compiled`. -/
def commands : Array Config.Registration :=
  #[{ name := statusName, action := .call statusCommand },
    { name := refreshName, action := .call refreshCommand },
    { name := visitName, action := .call visitCommand },
    { name := toggleName, action := .call toggleCommand },
    { name := stageName, action := .call stageCommand },
    { name := unstageName, action := .call unstageCommand }]

/-- The status buffer's jobs, as a host registers them for the owner
`compiled`. -/
def jobs : Array Config.JobRegistration :=
  #[{ name := readJob, work := readWork }, { name := applyJob, work := applyWork }]

/-- The status buffer's mode, as a host registers it for the owner
`compiled`. -/
def modes : Array Mode :=
  #[mode]

end Editor.VersionControl
