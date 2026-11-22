import Editor.Package
import Evil.Compiled
import EvilApiTest.Contract
import EvilTest.Check

/-!
# Model tests: `Evil/Compiled.lean`

The model tests of `Evil/Compiled.lean`: `evilPackageChecks`. The root
module `EvilTest.Model` runs them; its module doc says what each shows.
-/

namespace EvilTest

open Editor

/-- The checks of the `evil` package (`Evil/Compiled.lean`): the contract
of the interface package `evil-api` (`EvilApiTest.contractChecks`), with a
check that it bites. What each command does is the checks' of the module
that defines it. -/
def evilPackageChecks : List Check :=
  -- The contract of `evil-api`, which evil implements, over its package,
  -- each of its sentences one check.
  ((EvilApiTest.contractChecks Evil.package).map fun (name, held) => { name, run := pure held }) ++
    [{  name :=
          "the contract of evil-api this list runs bites: over a package of the evil package's name that registers nothing, every check of it fails"
        run :=
          let broken : Package := { name := Evil.package.name, setup := pure () }
          pure ((EvilApiTest.contractChecks broken).all (!·.2)) }]

end EvilTest
