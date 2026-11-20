import Editor.Package
import Editor.ProjectSearch.Run

/-!
# The `project-search` package: project search's commands, mode and jobs

What a host registers, as the package `project-search`
(`ProjectSearch.package`, `Editor/Package.lean`), so that `project-search`
searches a workspace's files into an editable excerpt buffer
(`Editor/ProjectSearch/Run.lean`). A host registers it for the owner
`project-search` when its loop starts, before any config
(`Editor/Config/Packages.lean`), after the `workspace` package
(`Editor/Workspace/Compiled.lean`), whose rule of what is searched it
reads.

- **The commands**: `project-search`, and
  `project-search-found`, which the search's job posts with each delivery:
  it is registered because a post must name a registered command, and is
  not meant to be run by hand; `project-search-symbol`, which searches the
  word under the cursor; and `project-search-visit`, which shows the file's
  buffer at the match under the cursor.
- **The mode**: `project-search`, the results buffer's mode,
  whose activate key (`RET` in the Vim scheme's normal state) runs
  `project-search-visit`.
- **The jobs**: `project-search`, the search, keyed by its
  results buffer's name, reported: one running when the process ends is
  said stopped by the next start's restore; and `project-search-load`, which loads the files a
  delivery found that no buffer holds.

Pinned by `ModelTest.projectSearchRunChecks`, on the models, and by
`ConfigTest.shippedChecks` over the hosts' registry.
-/

namespace Editor.ProjectSearch

/-- The package `project-search`: project search's commands, its results
buffer's mode, and its jobs, the search and the load of the files it
found. -/
def package : Package :=
  { name := "project-search"
    setup := do
      commandWith name command
      commandWith foundName foundCommand
      commandWith symbolName symbolCommand
      commandWith visitName visitCommand
      defineMode mode
      workJob job searchWork (reported := true)
      workJob loadJob loadWork }

end Editor.ProjectSearch
