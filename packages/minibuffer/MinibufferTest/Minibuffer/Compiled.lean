import Minibuffer.Compiled
import MinibufferApiTest.Contract
import MinibufferTest.Check

/-!
# Model tests: `Minibuffer/Compiled.lean`

The model tests of `Minibuffer/Compiled.lean`: `minibufferPackageChecks`,
the contract check of the interface package this package implements,
`minibuffer-api` (`MinibufferApiTest.contractChecks`), over the `Package`
value. The test driver's root, `MinibufferTest/Model.lean`, runs them.
-/

namespace MinibufferTest

open Editor

/-- The checks of the package `minibuffer` against the contract of
`minibuffer-api`: it registers a command under each name the interface
declares, and a mode under the mode name it declares. The contract's
checks are sentences with whether each holds, and each is one check
here. -/
def minibufferPackageChecks : List Check :=
  (MinibufferApiTest.contractChecks Editor.Minibuffer.package).map fun (name, held) =>
    { name, run := pure held }

end MinibufferTest
