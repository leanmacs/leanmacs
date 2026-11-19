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
  not meant to be run by hand; `project-search-symbol`, which searches the
  word under the cursor; and `project-search-visit`, which shows the file's
  buffer at the match under the cursor.
- **`ProjectSearch.modes`**: `project-search`, the results buffer's mode,
  whose activate key (`RET` in the Vim scheme's normal state) runs
  `project-search-visit`.
- **`ProjectSearch.jobs`**: `project-search`, the search, keyed by its
  results buffer's name; and `project-search-load`, which loads the files a
  delivery found that no buffer holds.

Pinned by `ModelTest.projectSearchRunChecks`, on the models, and by
`ConfigTest.shippedChecks` over the hosts' registry.
-/

namespace Editor.ProjectSearch

/-- Project search's commands, as a host registers them for the owner
`compiled`. -/
def commands : Array Config.Registration :=
  #[{ name, action := .call command }, { name := foundName, action := .call foundCommand },
    { name := symbolName, action := .call symbolCommand },
    { name := visitName, action := .call visitCommand }]

/-- Project search's mode, as a host registers it for the owner `compiled`:
the results buffer's, whose activate key visits a match. -/
def modes : Array Mode :=
  #[mode]

/-- Project search's jobs, as a host registers them for the owner
`compiled`. -/
def jobs : Array Config.JobRegistration :=
  #[{ name := job, work := searchWork }, { name := loadJob, work := loadWork }]

end Editor.ProjectSearch
