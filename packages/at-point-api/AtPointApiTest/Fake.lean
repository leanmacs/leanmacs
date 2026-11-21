import Editor.Test.AtPoint

/-!
# The fake of `at-point-api`

The core's test kit's implementation of completion at point's commands,
`Editor.Test.AtPoint.package` (the core's `lean/Editor/Test/AtPoint.lean`):
a package named `at-point` that registers a command under every name the
interface declares, written over the core's API. A names-only fake could
not complete at point, and the core's own tests need one that does, so
the fake is the kit's, and there is one implementation to drift, not two:
the Vim table's tests compare its text to the kit's names, this package's
tests run the contract over the kit's implementation, and the package
`at-point` runs the same contract. A consumer's tests use it in place of
any implementation, so they import no implementation package.
-/

namespace AtPointApiTest

/-- The fake: the core's test kit's at-point package
(`Editor.Test.AtPoint.package`). -/
def fake : Editor.Package :=
  Editor.Test.AtPoint.package

end AtPointApiTest
