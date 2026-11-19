import Editor.Config.Registry
import Editor.ProjectSearch.Run

/-!
# Project search's commands and jobs, as compiled code registers them

What a host is handed so that `project-search` searches a workspace's files
into an editable excerpt buffer (`Editor/ProjectSearch/Run.lean`). A host
registers them for the owner `compiled` when its loop starts, before any
config (`Editor/Config/Registry.lean`, "Compiled commands"), after the
workspace's (`Editor/Workspace/Compiled.lean`), whose rule of what is
searched it reads.

- **`ProjectSearch.commands`**: `project-search`, and
  `project-search-found`, which the search's job posts with each delivery:
  it is registered because a post must name a registered command, and is
  not meant to be run by hand.
- **`ProjectSearch.jobs`**: `project-search`, the search, keyed by its
  results buffer's name.

Pinned by `ModelTest.projectSearchRunChecks`, on the models, and by
`ConfigTest.shippedChecks` over the hosts' registry.
-/

namespace Editor.ProjectSearch

/-- Project search's commands, as a host registers them for the owner
`compiled`. -/
def commands : Array Config.Registration :=
  #[{ name, action := .call command }, { name := foundName, action := .call foundCommand }]

/-- Project search's jobs, as a host registers them for the owner
`compiled`. -/
def jobs : Array Config.JobRegistration :=
  #[{ name := job, work := searchWork }]

end Editor.ProjectSearch
