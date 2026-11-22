import CompileApi
import Editor.Package

/-!
# The fake of `compile-api`

A package that registers a sample contribution at the interface's extension
point through `compileContribution`, as the compile package registers its
shipped modes. A consumer's tests use it in place of any implementation, so
they import no implementation package.
-/

namespace CompileApiTest

open Editor

/-- The fake's contribution: `fake-mode` on `fake.toml`, with the commands
`build` and `check`. -/
def sample : Compile.Contribution :=
  { mode := "fake-mode", markers := #["fake.toml"]
    commands :=
      #[{ name := "build", line := "fake build" }, { name := "check", line := "fake check" }] }

/-- The fake: a package named `compile-fake` that registers `sample`. -/
def fake : Package :=
  { name := "compile-fake", setup := compileContribution sample }

end CompileApiTest
