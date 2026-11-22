import Editor.Config.Packages
import WindowCommandsApi

/-!
# The contract check of `window-commands-api`

What every implementation of the interface runs over its package: it
registers a command under each name the interface declares, so whatever
reaches one of those names finds it. It collects the package's `setup`
with the pure collector (`Package.registered`), so nothing is registered
in an editor.

It is a list of sentences, each with whether it holds, the shape the
fixture interface package `greeting-api` gives its own
(`tests/packages/greeting-api`), so that it needs nothing of an
implementation's test driver: a driver whose checks are of another type
turns each pair into one of its checks.
-/

namespace WindowCommandsApiTest

open Editor

/-- The checks of the contract over `package`, one for each name the
interface declares, each with what must hold as a sentence. -/
def contractChecks (package : Package) : List (String × Bool) :=
  let registered := (Package.registered package).commands.map (·.name)
  WindowCommandsApi.names.toList.map fun name =>
    (s!"`{package.name}` registers a command under `{name}`, a name `window-commands-api` declares",
      registered.contains name)

end WindowCommandsApiTest
