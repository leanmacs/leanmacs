import Editor.Compile.Compiled
import Editor.Config.Packages
import Editor.Config.Registry
import ModelTest.Check

/-!
# Model tests: `Editor/Compile/Compiled.lean`

The model tests of `Editor/Compile/Compiled.lean`: `compilePackageChecks`.
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the `compile` package (`Editor/Compile/Compiled.lean`):
the ex names it binds are its own to bind. What each is bound to in the
shipped set, and who owns the compile mode's commands, jobs and
contributions there, is `ConfigTest.shippedChecks`'. -/
def compilePackageChecks : List Check :=
  [{  name :=
        "the package compile binds the ex names compile, compile-command, recompile, kill-compilation, next-error and previous-error, in that order, each to a command it registers"
      run :=
        let registered := Compile.package.registered
        pure
          (registered.ex.map (·.name) ==
              #["compile", "compile-command", "recompile", "kill-compilation", "next-error",
                "previous-error"] &&
            registered.ex.all fun binding => registered.commands.any (·.name == binding.command)) }]

end ModelTest
