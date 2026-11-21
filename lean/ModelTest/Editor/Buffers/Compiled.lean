import BuffersApiTest.Contract
import Editor.Buffers.Compiled
import ModelTest.Check

/-!
# Model tests: `Editor/Buffers/Compiled.lean`

The model tests of `Editor/Buffers/Compiled.lean`: `buffersPackageChecks`.
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the `buffers` package (`Editor/Buffers/Compiled.lean`): the
contract of the interface library `buffers-api`
(`BuffersApiTest.contractChecks`), each of its sentences one check, and a
check that it bites. -/
def buffersPackageChecks : List Check :=
  ((BuffersApiTest.contractChecks Buffers.package).map fun (name, held) =>
      { name, run := pure held }) ++
    [{  name :=
          "the contract of buffers-api this list runs bites: over a package of the buffers package's name that registers nothing, every check of it fails"
        run :=
          let broken : Package := { name := Buffers.package.name, setup := pure () }
          pure ((BuffersApiTest.contractChecks broken).all (!·.2)) }]

end ModelTest
