import ModelTest.Check
import VcApi
import VcApiTest.Contract
import VcApiTest.Fake

/-!
# Model tests: `VcApiTest/Contract.lean`

The model tests of the contract of the interface library `vc-api`
(`VcApiTest/Contract.lean`): `versionControlContractFailures`, the
version-control contract run against the model of a repository, `vc-api`'s
fake. The git implementation's status read of each property's repository
on the job model is version control's (`ModelTest.versionControlGitChecks`),
and the contract over real git `ContractTest.versionControlFailures`. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The names of the version-control contract's properties
(`VcApiTest/Contract.lean`) that do not hold of the model
(`Model.handle`). -/
def versionControlContractFailures : IO (List String) :=
  pure <|
    VersionControlContract.properties.flatMap fun property =>
      if (property.holds.run VersionControl.Model.handle property.repository).1 then []
      else [s!"the version-control model: {property.name}"]

end ModelTest
