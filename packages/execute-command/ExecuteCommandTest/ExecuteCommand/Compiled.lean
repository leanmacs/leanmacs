import ExecuteCommand.Compiled
import ExecuteCommandApiTest.Contract
import ExecuteCommandTest.Check

/-!
# Model tests: `ExecuteCommand/Compiled.lean`

The model tests of `ExecuteCommand/Compiled.lean`:
`executeCommandPackageChecks`, the contract check of the interface package
this package implements, `execute-command-api`
(`ExecuteCommandApiTest.contractChecks`), over the `Package` value. The
test driver's root, `ExecuteCommandTest/Model.lean`, runs them.
-/

namespace ExecuteCommandTest

/-- The checks of the package `execute-command` against the contract of
`execute-command-api`: it registers a command under each name the
interface declares. The contract's checks are sentences with whether each
holds, and each is one check here. -/
def executeCommandPackageChecks : List Check :=
  (ExecuteCommandApiTest.contractChecks Editor.ExecuteCommand.package).map fun (name, held) =>
    { name, run := pure held }

end ExecuteCommandTest
