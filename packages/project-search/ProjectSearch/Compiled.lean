import Editor.Package
import ProjectSearch.Run

/-!
# The `project-search` package: project search's commands, mode and jobs

What a host registers, as the package `project-search`
(`ProjectSearch.package`, `Editor/Package.lean`), so that `project-search`
searches a workspace's files into an editable excerpt buffer
(`ProjectSearch/Run.lean`). A host of a set that holds this Lake package
registers it for the owner `project-search` when its loop starts, before
any config (`Editor/Config/Packages.lean`), after the `workspace` package
(`packages/workspace/`). What is searched is the core's rule
(`Workspace.searchRoot`, `Editor/SearchRoot.lean`).

- **The commands**: `project-search`, under the name of the interface
  package `project-search-api` (`ProjectSearchApi.searchName`), and
  `project-search-found`, which the search's job posts with each delivery:
  it is registered because a post must name a registered command, and is
  not meant to be run by hand; `project-search-symbol`, which searches the
  word under the cursor, under `ProjectSearchApi.symbolName`; and `project-search-visit`, which shows the file's
  buffer at the match under the cursor.
- **The mode**: `project-search`, the results buffer's mode,
  whose activate key (`RET` in the Vim scheme's normal state) runs
  `project-search-visit`.
- **The jobs**: `project-search`, the search, keyed by its
  results buffer's name, reported: one running when the process ends is
  said stopped by the next start's restore; and `project-search-load`, which loads the files a
  delivery found that no buffer holds.

Pinned by `ProjectSearchTest.projectSearchRunChecks`, on the models, and by
`ProjectSearchTest.projectSearchPackageChecks`: `project-search-api`'s
contract over the package, and what it registers, over the registry it
makes alone.
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
