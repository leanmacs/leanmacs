import Editor.Config.Packages
import GreetingApi

/-!
# The contract check of `greeting-api`

What every implementation of the interface runs over its package: it
registers a command under each name the interface declares, so a package
that reaches one of those names finds it. It collects the package's
`setup` with the pure collector (`Package.registered`), so nothing is
registered in an editor.
-/

namespace GreetingApiTest

open Editor

/-- The checks of the contract over `package`, one for each name the
interface declares, each with what must hold as a sentence. -/
def contractChecks (package : Package) : List (String × Bool) :=
  let registered := (Package.registered package).commands.map (·.name)
  GreetingApi.names.toList.map fun name =>
    (s!"`{package.name}` registers a command under `{name}`, a name `greeting-api` declares",
      registered.contains name)

end GreetingApiTest
