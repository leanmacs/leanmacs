import Editor.Config.Packages
import ProjectSearch.Compiled
import ProjectSearchApiTest.Contract
import ProjectSearchTest.Check

/-!
# Model tests: `ProjectSearch/Compiled.lean`

The model tests of `ProjectSearch/Compiled.lean`:
`projectSearchPackageChecks`. The test driver's root,
`ProjectSearchTest/Model.lean`, runs them; its module doc says what each
shows.
-/

namespace ProjectSearchTest

open Editor

/-- The registry the `project-search` package makes registered alone, as a
host of a set that holds it registers it. -/
def projectSearchRegistry : Config.Registry :=
  let (state, _) : Config.State Unit Unit × Array String :=
    Config.State.ofPackages #[ProjectSearch.package]
  state.registry

/-- The checks of the `project-search` package
(`ProjectSearch/Compiled.lean`): the contract of the interface package
`project-search-api` (`ProjectSearchApiTest.contractChecks`), with a check
that it bites, and what it registers, in the registry it makes alone
(`projectSearchRegistry`). -/
def projectSearchPackageChecks : List Check :=
  -- The contract of `project-search-api`, which project-search implements,
  -- over its package, each of its sentences one check.
  ((ProjectSearchApiTest.contractChecks ProjectSearch.package).map fun (name, held) =>
      { name, run := pure held }) ++
    [{  name :=
          "the contract of project-search-api this list runs bites: over a package of the project-search package's name that registers nothing, every check of it fails"
        run :=
          let broken : Package := { name := ProjectSearch.package.name, setup := pure () }
          pure ((ProjectSearchApiTest.contractChecks broken).all (!·.2)) },
      { name :=
          "the project-search package registers project-search, project-search-found, project-search-symbol and project-search-visit, the mode project-search, and the jobs project-search and project-search-load"
        run := do
          let registry := projectSearchRegistry
          let owner := ProjectSearch.package.owner
          return ["project-search", "project-search-found", "project-search-symbol",
                    "project-search-visit"].all
                (fun name => (registry.find? name).any (·.owner == owner)) &&
              registry.modes.any
                (fun entry => entry.mode.name == "project-search" && entry.owner == owner) &&
              ["project-search", "project-search-load"].all fun name =>
                registry.jobs.any fun entry =>
                  entry.registration.name == name && entry.owner == owner }]

end ProjectSearchTest
