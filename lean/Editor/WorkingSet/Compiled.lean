import Editor.Config.Registry
import Editor.WorkingSet.Run

/-!
# The working sets' commands, mode and jobs, as compiled code registers them

What a host is handed so that a selection can be added to a named working
set and a set opened as an excerpt buffer of its ranges
(`Editor/WorkingSet/Run.lean`). A host registers them for the owner
`compiled` when its loop starts, before any config
(`Editor/Config/Registry.lean`, "Compiled commands").

- **`WorkingSet.commands`**: `working-set-add`, `working-set-open` and
  `working-set-visit`.
- **`WorkingSet.modes`**: `working-set`, a set's buffer's mode, whose
  activate key (`RET` in the Vim scheme's normal state) runs
  `working-set-visit`.
- **`WorkingSet.jobs`**: `working-set-files`, which loads the files of a
  set's ranges that no buffer holds, keyed by the set's buffer's name.

Pinned by `ModelTest.workingSetRunChecks`, on the models, and by
`ConfigTest.shippedChecks` over the hosts' registry.
-/

namespace Editor.WorkingSet

/-- The working sets' commands, as a host registers them for the owner
`compiled`. -/
def commands : Array Config.Registration :=
  #[{ name := addName, action := .call addCommand },
    { name := openName, action := .call openCommand },
    { name := visitName, action := .call visitCommand }]

/-- The working sets' mode, as a host registers it for the owner
`compiled`. -/
def modes : Array Mode :=
  #[mode]

/-- The working sets' jobs, as a host registers them for the owner
`compiled`. -/
def jobs : Array Config.JobRegistration :=
  #[{ name := filesJob, work := filesWork }]

end Editor.WorkingSet
