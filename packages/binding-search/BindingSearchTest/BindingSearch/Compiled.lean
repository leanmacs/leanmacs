import BindingSearch.Compiled
import BindingSearchApiTest.Contract
import BindingSearchTest.Check

/-!
# Model tests: `BindingSearch/Compiled.lean`

The model tests of `BindingSearch/Compiled.lean`:
`bindingSearchPackageChecks`, the contract check of the interface package
this package implements, `binding-search-api`
(`BindingSearchApiTest.contractChecks`), over the `Package` value. The
test driver's root, `BindingSearchTest/Model.lean`, runs them.
-/

namespace BindingSearchTest

/-- The checks of the package `binding-search` against the contract of
`binding-search-api`: it registers a command under each name the
interface declares. The contract's checks are sentences with whether each
holds, and each is one check here. -/
def bindingSearchPackageChecks : List Check :=
  (BindingSearchApiTest.contractChecks Editor.BindingSearch.package).map fun (name, held) =>
    { name, run := pure held }

end BindingSearchTest
