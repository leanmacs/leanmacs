import Editor.Package
import Editor.Test.Ex

/-!
# The fake of `ex-api`

The core's test kit's ex line and its quit command
(`Editor.Test.exLinePackage`, `Editor.Test.quitPackage`, the core's
`lean/Editor/Test/Ex.lean`), as one package named `ex`: a hand-written ex
line over the core's ex line data, which parses a line and runs it through
its binding, hands a bang line to the shell's commands and asks for a line
when it is handed none, and a `quit` that runs the core's quit rule. A
names-only fake could not run a line, and the core's own tests need one
that does, so the fake is the kit's, and there is one implementation to
drift, not two: this package's tests run the contract over it, and the
package `ex` runs the same contract. A consumer's tests use it in place of
any implementation, so they import no implementation package.
-/

namespace ExApiTest

/-- The fake: a package named `ex` that registers what the core's test
kit's ex line registers (`Editor.Test.exLinePackage`) and then its quit
command (`Editor.Test.quitPackage`). -/
def fake : Editor.Package :=
  { name := "ex"
    setup := do
      Editor.Test.exLinePackage.setup
      Editor.Test.quitPackage.setup }

end ExApiTest
