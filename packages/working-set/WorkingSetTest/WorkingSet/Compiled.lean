import Editor.Config.Packages
import WorkingSet.Compiled
import WorkingSetApiTest.Contract
import WorkingSetTest.Check

/-!
# Model tests: `WorkingSet/Compiled.lean`

The model tests of `WorkingSet/Compiled.lean`: `workingSetPackageChecks`.
The test driver's root, `WorkingSetTest/Model.lean`, runs them; its module
doc says what each shows.
-/

namespace WorkingSetTest

open Editor

/-- The registry the `working-set` package makes registered alone, as a
host of a set that holds it registers it. -/
def workingSetRegistry : Config.Registry :=
  let (state, _) : Config.State Unit Unit × Array String :=
    Config.State.ofPackages #[WorkingSet.package]
  state.registry

/-- The checks of the `working-set` package (`WorkingSet/Compiled.lean`):
the contract of the interface package `working-set-api`
(`WorkingSetApiTest.contractChecks`), with a check that it bites, and what
it registers, in the registry it makes alone (`workingSetRegistry`). -/
def workingSetPackageChecks : List Check :=
  -- The contract of `working-set-api`, which working-set implements, over
  -- its package, each of its sentences one check.
  ((WorkingSetApiTest.contractChecks WorkingSet.package).map fun (name, held) =>
      { name, run := pure held }) ++
    [{  name :=
          "the contract of working-set-api this list runs bites: over a package of the working-set package's name that registers nothing, every check of it fails"
        run :=
          let broken : Package := { name := WorkingSet.package.name, setup := pure () }
          pure ((WorkingSetApiTest.contractChecks broken).all (!·.2)) },
      { name :=
          "the working-set package registers working-set-add, working-set-open, working-set-visit, working-set-remove, working-set-note and working-set-refresh, the mode working-set, and the jobs working-set-files, working-set-load, working-set-write and working-set-save"
        run := do
          let registry := workingSetRegistry
          let owner := WorkingSet.package.owner
          return ["working-set-add", "working-set-open", "working-set-visit", "working-set-remove",
                    "working-set-note", "working-set-refresh"].all
                (fun name => (registry.find? name).any (·.owner == owner)) &&
              registry.modes.any
                (fun entry => entry.mode.name == "working-set" && entry.owner == owner) &&
              ["working-set-files", "working-set-load", "working-set-write", "working-set-save"].all
                fun name =>
                registry.jobs.any fun entry =>
                  entry.registration.name == name && entry.owner == owner }]

end WorkingSetTest
